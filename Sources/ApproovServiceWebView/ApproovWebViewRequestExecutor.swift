import Approov
import ApproovURLSessionPackage
import Foundation

/// Executes the native side of the protected request flow.
///
/// This actor owns the stateful transport concerns:
/// - lazy Approov initialization
/// - cookie synchronization between WebKit and the isolated native jar
/// - browser-context header reconstruction
/// - execution through `ApproovURLSession`
/// - mapping the result back into either JS response mode or navigation mode
final actor ApproovWebViewRequestExecutor {
    private static let maximumRedirectCount = 20

    private let configuration: ApproovWebViewConfiguration
    private let cookieBridge: ApproovWebViewCookieBridge
    private let nativeCookieJar: ApproovWebViewNativeCookieJar
    private let redirectDelegate: ApproovWebViewRedirectDelegate
    private let urlSession: ApproovURLSession
    private let logger: ApproovWebViewLogger
    private let scopeID = UUID().uuidString
    private var didInitializeApproov = false

    init(
        configuration: ApproovWebViewConfiguration,
        cookieBridge: ApproovWebViewCookieBridge
    ) throws {
        self.configuration = configuration
        self.cookieBridge = cookieBridge
        self.logger = ApproovWebViewLogger(configuration: configuration)

        let nativeCookieJar = try ApproovWebViewNativeCookieJar()
        let redirectDelegate = ApproovWebViewRedirectDelegate()
        self.nativeCookieJar = nativeCookieJar
        self.redirectDelegate = redirectDelegate
        self.urlSession = ApproovURLSession(
            configuration: nativeCookieJar.sessionConfiguration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        logger.debug("Created native request executor with scope \(scopeID)")
    }

    deinit {
        // Release this executor's scope policy so the static registry does not
        // grow unbounded as web views are created and destroyed.
        ApproovWebViewServiceMutator.removeScope(scopeID)
    }

    /// Executes a page-originated request natively.
    func execute(_ proxyRequest: ApproovWebViewProxyRequest) async throws -> ApproovWebViewExecutionResult {
        logger.debug("Starting native execution for \(proxyRequest.logDescription)")
        let requestContext = try makeRequestContext(from: proxyRequest)
        guard configuration.isProtectedEndpoint(requestContext.requestURL) else {
            logger.error(
                """
                Rejecting unprotected WebView request routed into native code: \
                \(ApproovWebViewLogger.redactedURLForLog(requestContext.requestURL))
                """
            )
            throw ApproovWebViewBridgeError.requestNotProtected(
                requestContext.requestURL.absoluteString
            )
        }

        await synchronizeCookiesIntoNativeStorage()
        try initializeApproovIfNeeded()

        var request = requestContext.request
        nativeCookieJar.prepare(&request, for: requestContext.requestURL)
        ApproovWebViewServiceMutator.setWebViewScope(scopeID, on: &request)

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await performPinnedRequestFollowingRedirects(
                request
            )
        } catch {
            // A successful redirect response may already have mutated the jar.
            // Mirror it even if a later hop fails, matching browser cookie
            // persistence across a partially completed redirect chain.
            await synchronizeCookiesBackIntoWebView()
            throw error
        }

        await synchronizeCookiesBackIntoWebView()
        logger.debug(
            """
            Native execution completed with status \(httpResponse.statusCode) \
            for \(ApproovWebViewLogger.redactedURLForLog(httpResponse.url ?? requestContext.requestURL)) \
            and \(data.count) bytes
            """
        )

        let finalURL = httpResponse.url ?? requestContext.requestURL
        let proxyResponse = ApproovWebViewProxyResponse(
            url: finalURL.absoluteString,
            status: httpResponse.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            headers: normalizeHeaders(httpResponse.allHeaderFields),
            bodyBase64: data.base64EncodedString()
        )

        switch proxyRequest.responseHandling {
        case .response:
            return .response(proxyResponse)
        case .navigation:
            // Simulated navigation should use the final response URL so the
            // page is interpreted relative to the post-redirect document URL.
            let simulatedRequest = URLRequest(url: finalURL)
            return .navigation(
                ApproovWebViewNavigationLoad(
                    request: simulatedRequest,
                    response: httpResponse,
                    data: data
                )
            )
        }
    }

    /// Executes one protected task per HTTP hop so redirect response cookies
    /// are accepted before the next request is constructed.
    ///
    /// URLSession still proposes the redirected request, preserving its normal
    /// method, body, and header transformations. The redirect delegate declines
    /// the automatic follow and returns that proposal here, where the stale
    /// Cookie header is rebuilt for the destination URL.
    private func performPinnedRequestFollowingRedirects(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        var currentRequest = request
        var redirectCount = 0

        while true {
            let (data, response, proposedRedirect) =
                try await performPinnedRequest(currentRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ApproovWebViewBridgeError.nonHTTPResponse
            }

            storeResponseCookies(from: httpResponse)

            guard var redirectRequest = proposedRedirect else {
                return (data, httpResponse)
            }

            guard redirectCount < Self.maximumRedirectCount else {
                throw URLError(.httpTooManyRedirects)
            }
            redirectCount += 1

            guard let redirectURL = redirectRequest.url,
                  Self.isHTTPScheme(redirectURL) else {
                throw ApproovWebViewBridgeError.unsupportedScheme(
                    redirectRequest.url?.absoluteString ?? "<missing>"
                )
            }

            nativeCookieJar.prepareRedirect(
                &redirectRequest,
                for: redirectURL
            )
            ApproovWebViewServiceMutator.setWebViewScope(
                scopeID,
                on: &redirectRequest
            )
            currentRequest = redirectRequest
        }
    }

    /// Builds the native `URLRequest` from the JavaScript payload.
    private func makeRequestContext(
        from proxyRequest: ApproovWebViewProxyRequest
    ) throws -> (requestURL: URL, request: URLRequest) {
        guard let requestURL = URL(string: proxyRequest.url) else {
            throw ApproovWebViewBridgeError.invalidURL(proxyRequest.url)
        }

        guard Self.isHTTPScheme(requestURL) else {
            throw ApproovWebViewBridgeError.unsupportedScheme(proxyRequest.url)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = proxyRequest.method.isEmpty ? "GET" : proxyRequest.method.uppercased()

        for (headerName, headerValue) in proxyRequest.headers {
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }

        if let bodyBase64 = proxyRequest.bodyBase64, !bodyBase64.isEmpty {
            guard let bodyData = Data(base64Encoded: bodyBase64) else {
                throw ApproovWebViewBridgeError.invalidRequestBody
            }

            request.httpBody = bodyData
        }

        if let sourcePageURL = proxyRequest.sourcePageURL,
           let pageURL = URL(string: sourcePageURL) {
            request.mainDocumentURL = pageURL
            applyBrowserContextHeaders(to: &request, pageURL: pageURL)
        }

        return (requestURL, request)
    }

    /// Mirrors browser-managed headers that matter for API compatibility.
    private func applyBrowserContextHeaders(to request: inout URLRequest, pageURL: URL) {
        if request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        }

        guard shouldApplyOriginHeader(forHTTPMethod: request.httpMethod),
              request.value(forHTTPHeaderField: "Origin") == nil,
              let origin = Self.originString(from: pageURL) else {
            return
        }

        request.setValue(origin, forHTTPHeaderField: "Origin")
    }

    /// Copies cookies from WebKit into native storage before each request.
    private func synchronizeCookiesIntoNativeStorage() async {
        let snapshotTicket = nativeCookieJar.beginWebKitSnapshot()
        let webCookies = await cookieBridge.allCookies()
        guard nativeCookieJar.synchronizeFromWebKit(
            webCookies,
            snapshotTicket: snapshotTicket
        ) else {
            logger.debug(
                "Ignoring stale WebKit cookie snapshot \(snapshotTicket)"
            )
            return
        }

        logger.debug(
            "Synchronized \(webCookies.count) cookies from WebKit into native storage"
        )
    }

    /// Stores cookies set by the native response into the isolated cookie jar.
    ///
    /// Every mutation recorded here is held behind a barrier until
    /// `synchronizeCookiesBackIntoWebView()` has mirrored it into WebKit, so a
    /// concurrent request's snapshot cannot resurrect a server deletion.
    private func storeResponseCookies(from response: HTTPURLResponse) {
        guard let url = response.url else {
            return
        }

        let outcome = nativeCookieJar.storeResponseCookies(
            fromResponseHeaders: response.allHeaderFields,
            url: url
        )
        guard !outcome.isEmpty else {
            return
        }

        logger.debug(
            """
            Applied native response cookies to the isolated jar: \
            stored \(outcome.storedCount), deleted \(outcome.deletedCount)
            """
        )
    }

    /// Pushes only cookies written by native responses back into WebKit.
    ///
    /// Cookies imported from the pre-request WebKit snapshot are deliberately
    /// not included. Replaying them here could overwrite a page-side deletion
    /// or replacement made while the network request was suspended.
    ///
    /// `completeWebKitFlush(_:)` must run once the bridge has applied this
    /// captured ordered delete/set pair. Completion acknowledges only the exact
    /// identity generations in that flush, so overlapping empty or older
    /// mirrors cannot release a newer response's barriers.
    private func synchronizeCookiesBackIntoWebView() async {
        let flush = nativeCookieJar.makeWebKitFlush()
        logger.debug(
            """
            Synchronizing \(flush.cookiesToSet.count) cookies from native storage back into WebKit \
            after deleting \(flush.cookiesToDelete.count) cookie(s)
            """
        )
        defer { nativeCookieJar.completeWebKitFlush(flush) }
        await cookieBridge.synchronize(
            deleting: flush.cookiesToDelete,
            setting: flush.cookiesToSet
        )
    }

    /// Initializes Approov lazily the first time protected traffic is sent.
    private func initializeApproovIfNeeded() throws {
        guard !didInitializeApproov else {
            logger.debug("Approov already initialized for scope \(scopeID)")
            return
        }

        let trimmedConfig = configuration.approovConfig
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedConfig.isEmpty else {
            throw ApproovWebViewBridgeError.approovConfigEmpty
        }

        logger.debug(
            """
            Initializing Approov for scope \(scopeID) with \
            \(configuration.protectedEndpoints.count) protected endpoint(s)
            """
        )
        ApproovWebViewServiceMutator.installOrUpdateScope(
            scopeID: scopeID,
            configuration: configuration
        )
        try ApproovService.initialize(config: trimmedConfig)
        ApproovService.setApproovHeader(
            header: configuration.approovTokenHeaderName,
            prefix: configuration.approovTokenHeaderPrefix
        )
        if let approovDevelopmentKey = configuration.approovDevelopmentKey,
           !approovDevelopmentKey.isEmpty {
            logger.debug("Applying Approov development key")
            ApproovService.setDevKey(devKey: approovDevelopmentKey)
        }
        logger.debug("Running host Approov configuration hook")
        try configuration.configureApproovService()

        didInitializeApproov = true
        logger.debug("Approov initialization completed for scope \(scopeID)")
    }

    /// Uses the completion-handler `dataTask(...)` path because the async
    /// convenience APIs are not protected by `ApproovURLSession`.
    private func performPinnedRequest(
        _ request: URLRequest
    ) async throws -> (Data, URLResponse, URLRequest?) {
        logger.debug("Executing protected request via ApproovURLSession: \(request.logDescription)")
        let redirectDelegate = redirectDelegate
        return try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<
                        (Data, URLResponse, URLRequest?),
                        Error
                    >
            ) in
            let taskReference = ApproovWebViewTaskReference()
            let task = urlSession.dataTask(with: request) { data, response, error in
                let proposedRedirect = taskReference.taskIdentifier.flatMap {
                    redirectDelegate.takeProposedRequest(
                        for: $0
                    )
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: ApproovWebViewBridgeError.nonHTTPResponse)
                    return
                }

                continuation.resume(
                    returning: (data, response, proposedRedirect)
                )
            }

            taskReference.taskIdentifier = task.taskIdentifier
            task.resume()
        }
    }

    /// Converts Foundation's heterogenous header map into JSON-safe values.
    ///
    /// `Set-Cookie` is deliberately withheld from the page-facing payload. Browsers
    /// strip it from `fetch`/`XMLHttpRequest` visible headers so that `HttpOnly`
    /// session cookies cannot be read by JavaScript; the bridge has already applied
    /// those cookies to the shared jar natively, so the page never needs them.
    private func normalizeHeaders(_ rawHeaders: [AnyHashable: Any]) -> [String: String] {
        var headers: [String: String] = [:]

        for (key, value) in rawHeaders {
            let name = String(describing: key)
            if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                continue
            }

            headers[name] = String(describing: value)
        }

        return headers
    }

    private func shouldApplyOriginHeader(forHTTPMethod method: String?) -> Bool {
        guard let method else {
            return false
        }

        switch method.uppercased() {
        case "POST", "PUT", "PATCH", "DELETE":
            return true
        default:
            return false
        }
    }

    private static func isHTTPScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "http" || scheme == "https"
    }

    private static func originString(from url: URL) -> String? {
        guard let scheme = url.scheme,
              let host = url.host else {
            return nil
        }

        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }

        return "\(scheme)://\(host)"
    }
}

/// Shares a task identifier with its completion handler without capturing a
/// mutable local variable across concurrency domains.
private final class ApproovWebViewTaskReference:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedTaskIdentifier: Int?

    var taskIdentifier: Int? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedTaskIdentifier
        }
        set {
            lock.lock()
            storedTaskIdentifier = newValue
            lock.unlock()
        }
    }
}

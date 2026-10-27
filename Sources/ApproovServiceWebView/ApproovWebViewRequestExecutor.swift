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
private enum ApproovWebViewInitializationError: LocalizedError {
    case incompatibleConfiguration, existingServiceRequired, serviceUnavailable
    var errorDescription: String? { "Approov service configuration is incompatible with this WebView." }
}

final actor ApproovWebViewRequestExecutor {
    private static let maximumRedirectCount = 20
    private static let initializationLock = NSLock()
    private struct SharedConfiguration: Equatable {
        let config, header, prefix: String
        let developmentKey: String?
        let usesExisting: Bool
    }
    private static var sharedConfiguration: SharedConfiguration?
    private static var ownedHookCompleted = false

    private let configuration: ApproovWebViewConfiguration
    private let cookieBridge: ApproovWebViewCookieBridge
    private let nativeCookieJar: ApproovWebViewNativeCookieJar
    private let redirectDelegate: ApproovWebViewRedirectDelegate
    private let urlSession: ApproovURLSession
    private let logger: ApproovWebViewLogger
    private let scopeID = UUID().uuidString
    private var didInitializeApproov = false
    private var activeRequests = 0

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
        urlSession.invalidateAndCancel()
        ApproovWebViewServiceMutator.removeScope(scopeID)
    }

    /// Executes a page-originated request natively.
    func execute(_ proxyRequest: ApproovWebViewProxyRequest, context: ApproovWebViewRequestContext) async throws -> ApproovWebViewExecutionResult {
        logger.debug("Starting native execution for \(proxyRequest.logDescription)")
        guard activeRequests < configuration.maximumConcurrentRequests else {
            throw URLError(.resourceUnavailable)
        }
        activeRequests += 1
        defer { activeRequests -= 1 }
        if let body = proxyRequest.bodyBase64 {
            let maxBytes = max(0, configuration.maximumRequestBodyBytes)
            guard body.utf8.count / 4 <= (maxBytes / 3 + 1) else { throw URLError(.dataLengthExceedsMaximum) }
        }
        let mode = proxyRequest.mode ?? (proxyRequest.requestSource == .form ? "navigate" : "cors")
        let credentialsMode = proxyRequest.credentials ?? "same-origin"
        try ApproovWebViewBrowserPolicy.validateOptions(mode: mode, credentials: credentialsMode,
            redirect: proxyRequest.redirect ?? "follow", cache: proxyRequest.cache ?? "default",
            integrity: proxyRequest.integrity ?? "")
        try ApproovWebViewBrowserPolicy.validatePageHeaders(proxyRequest.headers,
            tokenHeader: configuration.approovTokenHeaderName)
        let requestContext = try makeRequestContext(from: proxyRequest, context: context)
        if mode == "same-origin" && ApproovWebViewBrowserPolicy.isCrossOrigin(requestContext.requestURL, sourceOrigin: context.frameOrigin) {
            throw ApproovWebViewBrowserPolicyError.corsRejected
        }
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

        let credentials = proxyRequest.credentials ?? "same-origin"
        guard ["omit", "same-origin", "include"].contains(credentials) else {
            throw ApproovWebViewBrowserPolicyError.unsupportedPolicy
        }
        if credentials != "omit" { await synchronizeCookiesIntoNativeStorage() }
        try initializeApproovIfNeeded()

        var request = requestContext.request
        if allowsCookies(credentials: credentials, url: requestContext.requestURL, context: context) {
            nativeCookieJar.prepare(&request, for: requestContext.requestURL)
        }
        ApproovWebViewServiceMutator.setWebViewScope(scopeID, on: &request)

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await performPinnedRequestFollowingRedirects(
                request, credentials: credentials, context: context, mode: mode,
                pageHeaders: proxyRequest.headers, redirectMode: proxyRequest.redirect ?? "follow",
                requestedReferrer: proxyRequest.referrer, referrerPolicy: proxyRequest.referrerPolicy
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

        guard data.count <= configuration.maximumResponseBodyBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let finalURL = httpResponse.url ?? requestContext.requestURL
        let proxyResponse = ApproovWebViewProxyResponse(
            url: finalURL.absoluteString,
            status: httpResponse.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            headers: ApproovWebViewBrowserPolicy.exposedHeaders(
                normalizeHeaders(httpResponse.allHeaderFields),
                crossOrigin: mode != "navigate" && ApproovWebViewBrowserPolicy.isCrossOrigin(finalURL, sourceOrigin: context.frameOrigin),
                credentials: credentials),
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
        _ request: URLRequest, credentials: String, context: ApproovWebViewRequestContext,
        mode: String, pageHeaders: [String: String], redirectMode: String,
        requestedReferrer: String?, referrerPolicy: String?
    ) async throws -> (Data, HTTPURLResponse) {
        var currentRequest = request
        var redirectCount = 0

        while true {
            guard let currentURL = currentRequest.url else { throw URLError(.badURL) }
            let crossOrigin = ApproovWebViewBrowserPolicy.isCrossOrigin(currentURL, sourceOrigin: context.frameOrigin)
            if mode == "same-origin" && crossOrigin { throw ApproovWebViewBrowserPolicyError.corsRejected }
            let method = (currentRequest.httpMethod ?? "GET").uppercased()
            if mode == "cors" && crossOrigin && ApproovWebViewBrowserPolicy.needsPreflight(method: method, headers: pageHeaders) {
                var preflight = URLRequest(url: currentURL)
                preflight.httpMethod = "OPTIONS"
                preflight.setValue(context.frameOrigin, forHTTPHeaderField: "Origin")
                preflight.setValue(method, forHTTPHeaderField: "Access-Control-Request-Method")
                let names = ApproovWebViewBrowserPolicy.unsafeHeaderNames(pageHeaders)
                if !names.isEmpty { preflight.setValue(names.joined(separator: ","), forHTTPHeaderField: "Access-Control-Request-Headers") }
                preflight.httpShouldHandleCookies = false
                ApproovWebViewServiceMutator.setWebViewScope(scopeID, on: &preflight)
                let (_, preflightResponse, preflightRedirect) = try await performSignedRequest(preflight)
                guard preflightRedirect == nil, let response = preflightResponse as? HTTPURLResponse else {
                    throw ApproovWebViewBrowserPolicyError.corsRejected
                }
                try ApproovWebViewBrowserPolicy.checkPreflight(status: response.statusCode,
                    headers: normalizeHeaders(response.allHeaderFields), sourceOrigin: context.frameOrigin,
                    credentials: credentials, method: method, requestHeaders: pageHeaders)
            }
            let (data, response, proposedRedirect) = try await performSignedRequest(currentRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ApproovWebViewBridgeError.nonHTTPResponse
            }

            if mode == "cors" && crossOrigin {
                try ApproovWebViewBrowserPolicy.checkCORS(headers: normalizeHeaders(httpResponse.allHeaderFields),
                    sourceOrigin: context.frameOrigin, credentials: credentials)
            }
            if let responseURL = httpResponse.url,
               allowsCookies(credentials: credentials, url: responseURL, context: context) {
                storeResponseCookies(from: httpResponse)
            }

            guard var redirectRequest = proposedRedirect else {
                return (data, httpResponse)
            }

            guard redirectMode == "follow" else { throw URLError(.redirectToNonExistentLocation) }
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

            guard let sourceURL = httpResponse.url else {
                throw ApproovWebViewBridgeError.nonHTTPResponse
            }
            try ApproovWebViewRedirectPolicy.prepare(
                &redirectRequest, from: sourceURL,
                endpoints: configuration.protectedEndpoints
            )
            redirectRequest.setValue(nil, forHTTPHeaderField: "Referer")
            redirectRequest.setValue(try ApproovWebViewBrowserPolicy.referrer(
                pageURL: context.frameURL, sourceOrigin: context.frameOrigin, destination: redirectURL,
                requestedReferrer: requestedReferrer, policy: referrerPolicy), forHTTPHeaderField: "Referer")
            if ApproovWebViewBrowserPolicy.isCrossOrigin(redirectURL, sourceOrigin: context.frameOrigin)
                || shouldApplyOriginHeader(forHTTPMethod: redirectRequest.httpMethod) {
                redirectRequest.setValue(context.frameOrigin, forHTTPHeaderField: "Origin")
            } else {
                redirectRequest.setValue(nil, forHTTPHeaderField: "Origin")
            }
            redirectRequest.setValue(nil, forHTTPHeaderField: "Cookie")
            if allowsCookies(credentials: credentials, url: redirectURL, context: context) {
                nativeCookieJar.prepareRedirect(&redirectRequest, for: redirectURL)
            }
            ApproovWebViewServiceMutator.setWebViewScope(
                scopeID,
                on: &redirectRequest
            )
            currentRequest = redirectRequest
        }
    }

    private func performSignedRequest(_ request: URLRequest) async throws -> (Data, URLResponse, URLRequest?) {
        let tokenHeader = ApproovService.getApproovTokenHeader()
        var signed = try ApproovWebViewTokenPolicy.sign(request, header: tokenHeader,
            prefix: configuration.approovTokenHeaderPrefix,
            allowMissing: configuration.allowRequestsWithoutApproovToken,
            signer: { try ApproovService.signRequest($0) })
        ApproovWebViewServiceMutator.markAlreadySigned(&signed)
        return try await performPinnedRequest(signed)
    }

    /// Builds the native `URLRequest` from the JavaScript payload.
    private func makeRequestContext(
        from proxyRequest: ApproovWebViewProxyRequest,
        context: ApproovWebViewRequestContext
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
            // Browser-owned context and cookie headers cannot be asserted by page payloads.
            guard !["origin", "referer", "cookie", "host"].contains(headerName.lowercased()) else { continue }
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }

        if let bodyBase64 = proxyRequest.bodyBase64, !bodyBase64.isEmpty {
            guard let bodyData = Data(base64Encoded: bodyBase64) else {
                throw ApproovWebViewBridgeError.invalidRequestBody
            }

            guard bodyData.count <= configuration.maximumRequestBodyBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            request.httpBody = bodyData
        }

        request.mainDocumentURL = context.mainDocumentURL ?? context.frameURL
        if let referrer = try ApproovWebViewBrowserPolicy.referrer(
            pageURL: context.frameURL, sourceOrigin: context.frameOrigin,
            destination: requestURL, requestedReferrer: proxyRequest.referrer,
            policy: proxyRequest.referrerPolicy
        ) {
            request.setValue(referrer, forHTTPHeaderField: "Referer")
        }
        if ApproovWebViewBrowserPolicy.isCrossOrigin(requestURL, sourceOrigin: context.frameOrigin)
            || shouldApplyOriginHeader(forHTTPMethod: request.httpMethod) {
            request.setValue(context.frameOrigin, forHTTPHeaderField: "Origin")
        }

        return (requestURL, request)
    }

    /// Without an authoritative site-for-cookies signal, restrict cookies to
    /// same-origin frames and top-level documents. This is conservative for
    /// legitimate cross-origin credentials:include requests.
    private func allowsCookies(credentials: String, url: URL, context: ApproovWebViewRequestContext) -> Bool {
        guard ApproovWebViewBrowserPolicy.sendsCredentials(credentials, url: url, sourceOrigin: context.frameOrigin),
              !ApproovWebViewBrowserPolicy.isCrossOrigin(url, sourceOrigin: context.frameOrigin),
              let top = context.mainDocumentURL,
              ApproovWebViewBrowserPolicy.origin(of: top) == context.frameOrigin else { return false }
        return true
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
        let requested = SharedConfiguration(
            config: trimmedConfig, header: configuration.approovTokenHeaderName,
            prefix: configuration.approovTokenHeaderPrefix,
            developmentKey: configuration.approovDevelopmentKey,
            usesExisting: configuration.usesExistingApproovService
        )
        Self.initializationLock.lock()
        defer { Self.initializationLock.unlock() }
        if let current = Self.sharedConfiguration, current != requested {
            throw ApproovWebViewInitializationError.incompatibleConfiguration
        }
        if configuration.usesExistingApproovService {
            guard ApproovService.isApproovEnabled() else {
                throw ApproovWebViewInitializationError.serviceUnavailable
            }
            guard ApproovService.getApproovTokenHeader().caseInsensitiveCompare(configuration.approovTokenHeaderName) == .orderedSame else {
                throw ApproovWebViewInitializationError.incompatibleConfiguration
            }
        } else if Self.sharedConfiguration == nil {
            guard !ApproovService.isInitialized() else {
                throw ApproovWebViewInitializationError.existingServiceRequired
            }
            try ApproovService.initialize(config: trimmedConfig)
            ApproovService.setApproovHeader(header: configuration.approovTokenHeaderName,
                                            prefix: configuration.approovTokenHeaderPrefix)
            if let key = configuration.approovDevelopmentKey, !key.isEmpty {
                ApproovService.setDevKey(devKey: key)
            }
            // Preserve ownership even if the setup hook throws, so it can be retried
            // without resetting a successfully initialized shared service.
            Self.sharedConfiguration = requested
        }
        if !configuration.usesExistingApproovService && !Self.ownedHookCompleted {
            try configuration.configureApproovService()
            Self.ownedHookCompleted = true
        }
        Self.sharedConfiguration = requested
        ApproovWebViewServiceMutator.installOrUpdateScope(scopeID: scopeID, configuration: configuration)

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
        let taskReference = ApproovWebViewTaskReference()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<
                        (Data, URLResponse, URLRequest?),
                        Error
                    >
            ) in
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

            taskReference.register(task)
            task.resume()
            }
        }, onCancel: {
            taskReference.cancel()
        })
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
final class ApproovWebViewTaskReference:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedTaskIdentifier: Int?
    private var task: URLSessionTask?
    private var cancelled = false

    func register(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        storedTaskIdentifier = task.taskIdentifier
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

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

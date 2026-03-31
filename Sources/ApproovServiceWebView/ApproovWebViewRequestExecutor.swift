import Approov
import ApproovURLSessionPackage
import Foundation

/// Executes the native side of the protected request flow.
///
/// This actor owns the stateful transport concerns:
/// - lazy Approov initialization
/// - cookie synchronization between WebKit and `URLSession`
/// - browser-context header reconstruction
/// - execution through `ApproovURLSession`
/// - mapping the result back into either JS response mode or navigation mode
final actor ApproovWebViewRequestExecutor {
    private let configuration: ApproovWebViewConfiguration
    private let cookieBridge: ApproovWebViewCookieBridge
    private let cookieStorage = HTTPCookieStorage()
    private let urlSession: ApproovURLSessionPackage
    private let logger: ApproovWebViewLogger
    private let scopeID = UUID().uuidString
    private var didInitializeApproov = false

    init(
        configuration: ApproovWebViewConfiguration,
        cookieBridge: ApproovWebViewCookieBridge
    ) {
        self.configuration = configuration
        self.cookieBridge = cookieBridge
        self.logger = ApproovWebViewLogger(configuration: configuration)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = cookieStorage
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.urlSession = ApproovURLSessionPackage(configuration: sessionConfiguration)
        logger.debug("Created native request executor with scope \(scopeID)")
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

        try await synchronizeCookiesIntoNativeStorage()
        try initializeApproovIfNeeded()

        var request = requestContext.request
        ApproovWebViewServiceMutator.setWebViewScope(scopeID, on: &request)

        let (data, response) = try await performPinnedRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApproovWebViewBridgeError.nonHTTPResponse
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

        applyCookies(to: &request, for: requestURL)

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
    private func synchronizeCookiesIntoNativeStorage() async throws {
        let webCookies = await cookieBridge.allCookies()
        logger.debug("Synchronizing \(webCookies.count) cookies from WebKit into native storage")

        for cookie in cookieStorage.cookies ?? [] {
            cookieStorage.deleteCookie(cookie)
        }

        for cookie in webCookies {
            cookieStorage.setCookie(cookie)
        }
    }

    /// Pushes cookies written during the native request back into WebKit.
    private func synchronizeCookiesBackIntoWebView() async {
        let nativeCookies = cookieStorage.cookies ?? []
        logger.debug("Synchronizing \(nativeCookies.count) cookies from native storage back into WebKit")
        await cookieBridge.setCookies(nativeCookies)
    }

    /// Applies a `Cookie` header if JavaScript did not supply one already.
    private func applyCookies(to request: inout URLRequest, for url: URL) {
        guard request.value(forHTTPHeaderField: "Cookie") == nil,
              let cookies = cookieStorage.cookies(for: url),
              !cookies.isEmpty else {
            return
        }

        for (headerName, headerValue) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }
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
    /// convenience APIs are not protected by `ApproovURLSessionPackage`.
    private func performPinnedRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        logger.debug("Executing protected request via ApproovURLSession: \(request.logDescription)")
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = urlSession.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: ApproovWebViewBridgeError.nonHTTPResponse)
                    return
                }

                continuation.resume(returning: (data, response))
            }

            task.resume()
        }
    }

    /// Converts Foundation's heterogenous header map into JSON-safe values.
    private func normalizeHeaders(_ rawHeaders: [AnyHashable: Any]) -> [String: String] {
        var headers: [String: String] = [:]

        for (key, value) in rawHeaders {
            headers[String(describing: key)] = String(describing: value)
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

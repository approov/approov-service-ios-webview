import Foundation
import WebKit

/// Receives JavaScript bridge messages and delegates execution to the actor
/// that owns the native request pipeline.
@MainActor
public final class ApproovWebViewCoordinator: NSObject, WKScriptMessageHandlerWithReply {
    private let configuration: ApproovWebViewConfiguration
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let logger: ApproovWebViewLogger
    private weak var webView: WKWebView?
    private var hasAttachedWebView = false

    var canAttachWebView: Bool { !hasAttachedWebView && !isInvalidated }
    var configurationID: UUID { configuration.installationID }
    private(set) var storeLifetimeOwner: AnyObject?
    private var executor: ApproovWebViewRequestExecutor?
    private var didWarnAboutMissingOriginAllowlist = false
    typealias Execution = (ApproovWebViewProxyRequest, ApproovWebViewRequestContext) async throws ->
        ApproovWebViewExecutionResult
    private var executionOverride: Execution?
    private struct RequestKey: Hashable {
        let origin: String
        let requestID: String
    }
    private struct PendingRequest {
        let token: UUID
        let task: Task<Void, Never>
        let replyHandler: (Any?, String?) -> Void
    }
    private var pendingRequests: [RequestKey: PendingRequest] = [:]
    private var isInvalidated = false
    var activeRequestCount: Int { pendingRequests.count }

    deinit {
        for pending in pendingRequests.values { pending.task.cancel() }
    }

    // The production initializer always uses the protected native executor.
    // Tests replace execution to inspect real WKFrameInfo without network traffic.
    convenience init(configuration: ApproovWebViewConfiguration, execution: @escaping Execution) {
        self.init(configuration: configuration)
        self.executionOverride = execution
    }

    public init(configuration: ApproovWebViewConfiguration) {
        self.configuration = configuration
        self.logger = ApproovWebViewLogger(configuration: configuration)
    }

    /// Attaches the concrete `WKWebView` after construction so the
    /// request-execution pipeline can reuse the WebKit cookie store.
    func attach(webView: WKWebView, lifetimeOwner: AnyObject? = nil) {
        // Reinstallation on an already-attached web view must not rebuild the
        // executor: a fresh executor means a fresh cookie jar, which discards
        // any tombstone still waiting to be mirrored into WebKit and re-runs
        // lazy Approov initialization.
        if self.webView === webView, executor != nil {
            logger.debug(
                "Coordinator is already attached to this web view; keeping the existing executor"
            )
            return
        }

        logger.debug(
            """
            Attaching coordinator to web view with handler '\(configuration.bridgeHandlerName)' \
            and data store \(webView.configuration.websiteDataStore.isPersistent ? "persistent" : "non-persistent")
            """
        )
        hasAttachedWebView = true
        self.storeLifetimeOwner = lifetimeOwner
        self.webView = webView
        do {
            self.executor = try ApproovWebViewRequestExecutor(
                configuration: configuration,
                cookieBridge: ApproovWebViewCookieBridge(
                    store: webView.configuration.websiteDataStore.httpCookieStore,
                    lifetimeOwner: lifetimeOwner
                )
            )
        } catch {
            self.executor = nil
            logger.error(
                "Failed to initialize the native request executor."
            )
        }
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard !isInvalidated else {
            replyHandler(nil, "The native bridge has closed.")
            return
        }
        guard let body = message.body as? [String: Any] else {
            replyHandler(nil, "The WebView bridge payload was not a dictionary.")
            return
        }
        guard isAllowedFrame(message.frameInfo) else {
            logger.error("Rejecting bridge message from a frame outside the allowed origins")
            replyHandler(nil, "This origin is not allowed to use the Approov WebView bridge.")
            return
        }
        guard
            let context = Self.requestContext(
                frameURL: message.frameInfo.request.url,
                frameOrigin: Self.originString(from: message.frameInfo.securityOrigin),
                mainDocumentURL: webView?.url,
                isMainFrame: message.frameInfo.isMainFrame
            )
        else {
            replyHandler(nil, "The sending frame has no supported browser origin.")
            return
        }
        if body["kind"] as? String == "cancel" {
            guard let requestID = body["requestId"] as? String, Self.validRequestID(requestID) else {
                replyHandler(nil, "The cancellation request ID was not valid.")
                return
            }
            let cancelled = cancelRequest(withID: requestID, from: context.frameOrigin)
            replyHandler(["cancelled": cancelled], nil)
            return
        }
        if handleDiagnosticMessage(body, replyHandler: replyHandler) { return }
        guard executor != nil || executionOverride != nil else {
            replyHandler(nil, "The native bridge is not ready yet.")
            return
        }
        guard pendingRequests.count < configuration.maximumConcurrentRequests else {
            replyHandler(nil, "The native bridge has reached its request limit.")
            return
        }
        guard Self.isBoundedPayload(body, maximumBodyBytes: configuration.maximumRequestBodyBytes) else {
            replyHandler(nil, "The WebView request payload exceeds the supported shape or size.")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: body, options: [])
            let request = try decoder.decode(ApproovWebViewProxyRequest.self, from: data)
            guard request.responseHandling != .navigation || context.isMainFrame else {
                replyHandler(nil, "Protected form navigation is supported only in the main frame.")
                return
            }
            if let requestID = request.requestId, !Self.validRequestID(requestID) {
                replyHandler(nil, "The WebView request ID was not valid.")
                return
            }
            let key = RequestKey(origin: context.frameOrigin, requestID: request.requestId ?? UUID().uuidString)
            guard pendingRequests[key] == nil else {
                replyHandler(nil, "This WebView request ID is already active.")
                return
            }
            start(request, context: context, key: key, replyHandler: replyHandler)
        } catch {
            logger.error("Failed to decode the WebView bridge payload.")
            replyHandler(nil, "The WebView request payload was not valid.")
        }
    }

    /// Cancels this installation permanently. Create a fresh view to reopen it.
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        let requests = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for pending in requests {
            pending.task.cancel()
            pending.replyHandler(nil, Self.cancelledMessage)
        }
        executor = nil
        executionOverride = nil
        // Running executor/cookie tasks keep their own lease until they drain.
        storeLifetimeOwner = nil
        webView = nil
    }

    // The caller must derive origin from WKFrameInfo before reaching this method.
    func cancelRequest(withID requestID: String, from origin: String) -> Bool {
        let key = RequestKey(origin: origin, requestID: requestID)
        guard let pending = pendingRequests.removeValue(forKey: key) else { return false }
        pending.task.cancel()
        pending.replyHandler(nil, Self.cancelledMessage)
        return true
    }

    /// Error descriptions from SDKs, URLSession, and host callbacks can contain
    /// complete URLs or request data. Only fixed bridge messages reach logs or JS.
    static func safeErrorMessage(_ error: Error) -> String {
        let nativeError = error as NSError
        if error is CancellationError
            || (nativeError.domain == NSURLErrorDomain && nativeError.code == NSURLErrorCancelled)
        {
            return cancelledMessage
        }
        guard let bridgeError = error as? ApproovWebViewBridgeError else {
            return "The protected request failed."
        }
        switch bridgeError {
        case .invalidURL: return "The WebView requested an invalid URL."
        case .unsupportedScheme: return "The WebView requested an unsupported URL scheme."
        case .requestNotProtected: return "This request is outside the protected endpoints."
        case .invalidRequestBody: return "The WebView request body was not valid."
        case .webViewUnavailable: return "The native bridge has closed."
        default: return "The protected request failed."
        }
    }

    private static let cancelledMessage = "The protected request was cancelled."

    private static func validRequestID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
    }

    /// Reject nested/unknown values before JSONSerialization makes another copy.
    static func isBoundedPayload(_ body: [String: Any], maximumBodyBytes: Int) -> Bool {
        let stringFields: Set<String> = [
            "url", "method", "sourcePageURL", "responseHandling", "requestSource",
            "requestId", "credentials", "mode", "redirect", "cache", "integrity", "referrer", "referrerPolicy",
        ]
        guard body.count <= stringFields.count + 2, maximumBodyBytes >= 0 else { return false }
        for (name, value) in body {
            if name == "headers" {
                guard let headers = value as? [String: Any], headers.count <= 128 else { return false }
                var bytes = 0
                for (key, value) in headers {
                    guard let value = value as? String, key.utf8.count <= 256, value.utf8.count <= 64 * 1024 else {
                        return false
                    }
                    bytes += key.utf8.count + value.utf8.count
                    guard bytes <= 64 * 1024 else { return false }
                }
            } else if name == "bodyBase64" {
                if value is NSNull { continue }
                let (base, overflow) = (maximumBodyBytes / 3).multipliedReportingOverflow(by: 4)
                let (limit, remainderOverflow) = base.addingReportingOverflow(maximumBodyBytes % 3 == 0 ? 0 : 4)
                guard !overflow, !remainderOverflow, let text = value as? String, text.utf8.count <= limit else {
                    return false
                }
            } else {
                guard stringFields.contains(name) else { return false }
                if value is NSNull { continue }
                guard let text = value as? String, text.utf8.count <= 16 * 1024 else { return false }
            }
        }
        return true
    }

    private func start(
        _ request: ApproovWebViewProxyRequest,
        context: ApproovWebViewRequestContext,
        key: RequestKey,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let token = UUID()
        let executor = self.executor
        let executionOverride = self.executionOverride
        logger.debug("Received bridge request: \(request.logDescription)")
        // No strong coordinator or WebView reference crosses the suspension.
        // Releasing a raw WebView therefore releases its coordinator and cancels work.
        let task = Task { [weak self] in
            do {
                let result: ApproovWebViewExecutionResult
                if let executionOverride {
                    result = try await executionOverride(request, context)
                } else if let executor {
                    result = try await executor.execute(request, context: context)
                } else {
                    throw ApproovWebViewBridgeError.webViewUnavailable
                }
                try Task.checkCancellation()
                guard let self, let pending = self.takeRequest(key, token: token) else { return }
                do {
                    switch result {
                    case .response(let response):
                        pending.replyHandler(try self.makeReplyObject(from: response), nil)
                    case .navigation(let navigation):
                        try self.applyNavigationLoad(navigation)
                        pending.replyHandler(["navigationStarted": true], nil)
                    }
                } catch {
                    self.logger.error("WebView bridge request failed: \(Self.safeErrorMessage(error))")
                    pending.replyHandler(nil, Self.safeErrorMessage(error))
                }
            } catch {
                guard let self, let pending = self.takeRequest(key, token: token) else { return }
                self.logger.error("WebView bridge request failed: \(Self.safeErrorMessage(error))")
                pending.replyHandler(nil, Self.safeErrorMessage(error))
            }
        }
        pendingRequests[key] = PendingRequest(token: token, task: task, replyHandler: replyHandler)
    }

    private func takeRequest(_ key: RequestKey, token: UUID) -> PendingRequest? {
        guard pendingRequests[key]?.token == token else { return nil }
        return pendingRequests.removeValue(forKey: key)
    }

    /// Decides whether a frame is allowed to use the bridge.
    ///
    /// When no allowlist is configured the bridge stays backward compatible
    /// (allow-all) but logs a warning once so the gap is visible. When an
    /// allowlist is configured, the frame's security origin must match it.
    private func isAllowedFrame(_ frameInfo: WKFrameInfo) -> Bool {
        guard configuration.enforcesOriginAllowlist else {
            warnAboutMissingOriginAllowlistIfNeeded()
            return true
        }

        return configuration.isAllowedOrigin(Self.originString(from: frameInfo.securityOrigin))
    }

    private func warnAboutMissingOriginAllowlistIfNeeded() {
        guard !didWarnAboutMissingOriginAllowlist else {
            return
        }

        didWarnAboutMissingOriginAllowlist = true
        logger.error(
            """
            No allowedOrigins configured: the Approov WebView bridge will accept calls from any \
            frame, including third-party iframes. Set ApproovWebViewConfiguration.allowedOrigins to \
            the origin(s) that host your protected funnel.
            """
        )
    }

    private static func originString(from securityOrigin: WKSecurityOrigin) -> String {
        var components = URLComponents()
        components.scheme = securityOrigin.`protocol`.lowercased()
        components.host = securityOrigin.host.lowercased()
        if securityOrigin.port != 0 { components.port = securityOrigin.port }
        return components.string ?? ""
    }

    /// Builds context exclusively from WebKit's frame metadata. A frame URL
    /// such as about:blank may inherit an HTTPS origin without an HTTPS URL.
    static func requestContext(
        frameURL: URL?, frameOrigin: String, mainDocumentURL: URL?, isMainFrame: Bool
    ) -> ApproovWebViewRequestContext? {
        guard let originURL = URL(string: frameOrigin),
            let origin = normalizedOrigin(originURL)
        else { return nil }
        let verifiedURL: URL
        if let frameURL, normalizedOrigin(frameURL) == origin {
            verifiedURL = frameURL
        } else {
            verifiedURL = originURL
        }
        return ApproovWebViewRequestContext(
            frameURL: verifiedURL, frameOrigin: origin,
            mainDocumentURL: mainDocumentURL, isMainFrame: isMainFrame
        )
    }

    private static func normalizedOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port, port != (scheme == "https" ? 443 : 80) {
            components.port = port
        }
        return components.string
    }

    private func makeReplyObject(from response: ApproovWebViewProxyResponse) throws -> Any {
        let encodedResponse = try encoder.encode(response)
        return try JSONSerialization.jsonObject(with: encodedResponse, options: [])
    }

    private func handleDiagnosticMessage(
        _ bodyDictionary: [String: Any],
        replyHandler: @escaping (Any?, String?) -> Void
    ) -> Bool {
        guard let kind = bodyDictionary["kind"] as? String,
            kind == "diagnostic"
        else {
            return false
        }

        let event = bodyDictionary["event"] as? String ?? "unknown"
        switch event {
        case "unprotected-request-bypass":
            let suppliedSource = bodyDictionary["requestSource"] as? String ?? ""
            let requestSource =
                ["fetch", "xhr", "form"].contains(suppliedSource) ? suppliedSource.uppercased() : "UNKNOWN"
            let url = bodyDictionary["url"] as? String ?? "<missing-url>"
            logger.debug(
                """
                WebView bridge bypassed native handling for unprotected \(requestSource) \
                request: \(ApproovWebViewLogger.redactedURLForLog(url))
                """
            )
        default:
            logger.debug("Received an unknown WebView bridge diagnostic event")
        }

        replyHandler(["logged": true], nil)
        return true
    }

    /// Loads a native response back into the WebView as a real navigation.
    ///
    /// `loadSimulatedRequest(...)` is the public WebKit API that lets us
    /// render a native HTTP response as if it had been produced by a page
    /// navigation to the same URL.
    @MainActor
    private func applyNavigationLoad(_ navigationLoad: ApproovWebViewNavigationLoad) throws {
        guard let webView else {
            throw ApproovWebViewBridgeError.webViewUnavailable
        }

        webView.loadSimulatedRequest(
            navigationLoad.request,
            response: navigationLoad.response,
            responseData: navigationLoad.data
        )
    }
}

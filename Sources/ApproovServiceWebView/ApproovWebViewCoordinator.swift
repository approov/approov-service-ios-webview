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

    var canAttachWebView: Bool { !hasAttachedWebView }
    private var executor: ApproovWebViewRequestExecutor?
    private var executorInitializationError: Error?
    private var didWarnAboutMissingOriginAllowlist = false
    typealias Execution = (ApproovWebViewProxyRequest, ApproovWebViewRequestContext) async throws -> ApproovWebViewExecutionResult
    private var executionOverride: Execution?
    private struct RequestKey: Hashable { let origin: String; let requestID: String }
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
    func attach(webView: WKWebView) {
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
        self.webView = webView
        do {
            self.executor = try ApproovWebViewRequestExecutor(
                configuration: configuration,
                cookieBridge: ApproovWebViewCookieBridge(
                    store: webView.configuration.websiteDataStore.httpCookieStore
                )
            )
            self.executorInitializationError = nil
        } catch {
            self.executor = nil
            self.executorInitializationError = error
            logger.error(
                "Failed to initialize the native request executor: \(error.localizedDescription)"
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
        guard let context = Self.requestContext(
            frameURL: message.frameInfo.request.url,
            frameOrigin: Self.originString(from: message.frameInfo.securityOrigin),
            mainDocumentURL: webView?.url,
            isMainFrame: message.frameInfo.isMainFrame
        ) else {
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
            logger.error("Failed to decode the WebView bridge payload: \(error.localizedDescription)")
            replyHandler(nil, "Failed to decode the WebView request: \(error.localizedDescription)")
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

    private static let cancelledMessage = "The protected request was cancelled."

    private static func validRequestID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
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
                    case let .response(response):
                        pending.replyHandler(try self.makeReplyObject(from: response), nil)
                    case let .navigation(navigation):
                        try self.applyNavigationLoad(navigation)
                        pending.replyHandler(["navigationStarted": true], nil)
                    }
                } catch {
                    self.logger.error("WebView bridge request failed: \(error.localizedDescription)")
                    pending.replyHandler(nil, error.localizedDescription)
                }
            } catch {
                guard let self, let pending = self.takeRequest(key, token: token) else { return }
                self.logger.error("WebView bridge request failed: \(error.localizedDescription)")
                pending.replyHandler(nil, error.localizedDescription)
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
              let origin = normalizedOrigin(originURL) else { return nil }
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
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
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
              kind == "diagnostic" else {
            return false
        }

        let event = bodyDictionary["event"] as? String ?? "unknown"
        switch event {
        case "unprotected-request-bypass":
            let requestSource = (bodyDictionary["requestSource"] as? String ?? "unknown").uppercased()
            let url = bodyDictionary["url"] as? String ?? "<missing-url>"
            logger.debug(
                """
                WebView bridge bypassed native handling for unprotected \(requestSource) \
                request: \(ApproovWebViewLogger.redactedURLForLog(url))
                """
            )
        default:
            logger.debug("Received WebView bridge diagnostic event '\(event)'")
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

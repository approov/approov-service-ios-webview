import Foundation
import WebKit

/// Receives JavaScript bridge messages and delegates execution to the actor
/// that owns the native request pipeline.
public final class ApproovWebViewCoordinator: NSObject, WKScriptMessageHandlerWithReply {
    private let configuration: ApproovWebViewConfiguration
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let logger: ApproovWebViewLogger
    private weak var webView: WKWebView?
    private var executor: ApproovWebViewRequestExecutor?

    public init(configuration: ApproovWebViewConfiguration) {
        self.configuration = configuration
        self.logger = ApproovWebViewLogger(configuration: configuration)
    }

    /// Attaches the concrete `WKWebView` after construction so the
    /// request-execution pipeline can reuse the WebKit cookie store.
    func attach(webView: WKWebView) {
        logger.debug(
            """
            Attaching coordinator to web view with handler '\(configuration.bridgeHandlerName)' \
            and data store \(webView.configuration.websiteDataStore.isPersistent ? "persistent" : "non-persistent")
            """
        )
        self.webView = webView
        self.executor = ApproovWebViewRequestExecutor(
            configuration: configuration,
            cookieBridge: ApproovWebViewCookieBridge(
                store: webView.configuration.websiteDataStore.httpCookieStore
            )
        )
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let bodyDictionary = message.body as? [String: Any] else {
            logger.error("Received a bridge payload that was not a dictionary")
            replyHandler(nil, "The WebView bridge payload was not a dictionary.")
            return
        }

        if handleDiagnosticMessage(bodyDictionary, replyHandler: replyHandler) {
            return
        }

        guard let executor else {
            logger.error("Received bridge message before the native executor was attached")
            replyHandler(nil, "The native bridge is not ready yet.")
            return
        }

        do {
            let bodyData = try JSONSerialization.data(
                withJSONObject: bodyDictionary,
                options: []
            )
            let proxyRequest = try decoder.decode(
                ApproovWebViewProxyRequest.self,
                from: bodyData
            )
            logger.debug("Received bridge request: \(proxyRequest.logDescription)")

            Task {
                do {
                    let executionResult = try await executor.execute(proxyRequest)

                    switch executionResult {
                    case let .response(proxyResponse):
                        logger.debug(
                            """
                            Returning response to page: \(proxyResponse.status) \
                            \(ApproovWebViewLogger.redactedURLForLog(proxyResponse.url)) \
                            (\(proxyResponse.bodyBase64.count) base64 chars)
                            """
                        )
                        let replyObject = try makeReplyObject(from: proxyResponse)
                        replyHandler(replyObject, nil)

                    case let .navigation(navigationLoad):
                        logger.debug(
                            "Applying simulated navigation for \(navigationLoad.request.logDescription)"
                        )
                        try await MainActor.run {
                            try applyNavigationLoad(navigationLoad)
                        }
                        replyHandler(["navigationStarted": true], nil)
                    }
                } catch {
                    logger.error("WebView bridge request failed: \(error.localizedDescription)")
                    replyHandler(nil, error.localizedDescription)
                }
            }
        } catch {
            logger.error("Failed to decode the WebView bridge payload: \(error.localizedDescription)")
            replyHandler(
                nil,
                "Failed to decode the WebView request: \(error.localizedDescription)"
            )
        }
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

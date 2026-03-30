import Foundation
import OSLog
import WebKit

/// Receives JavaScript bridge messages and delegates execution to the actor
/// that owns the native request pipeline.
public final class ApproovWebViewCoordinator: NSObject, WKScriptMessageHandlerWithReply {
    private let configuration: ApproovWebViewConfiguration
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let logger: Logger
    private weak var webView: WKWebView?
    private var executor: ApproovWebViewRequestExecutor?

    public init(configuration: ApproovWebViewConfiguration) {
        self.configuration = configuration
        self.logger = Logger(
            subsystem: configuration.loggerSubsystem,
            category: configuration.loggerCategory
        )
    }

    /// Attaches the concrete `WKWebView` after construction so the
    /// request-execution pipeline can reuse the WebKit cookie store.
    func attach(webView: WKWebView) {
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
        guard let executor else {
            replyHandler(nil, "The native bridge is not ready yet.")
            return
        }

        guard let bodyDictionary = message.body as? [String: Any] else {
            replyHandler(nil, "The WebView bridge payload was not a dictionary.")
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

            Task {
                do {
                    let executionResult = try await executor.execute(proxyRequest)

                    switch executionResult {
                    case let .response(proxyResponse):
                        let replyObject = try makeReplyObject(from: proxyResponse)
                        replyHandler(replyObject, nil)

                    case let .navigation(navigationLoad):
                        try await MainActor.run {
                            try applyNavigationLoad(navigationLoad)
                        }
                        replyHandler(["navigationStarted": true], nil)
                    }
                } catch {
                    logger.error(
                        "WebView bridge request failed: \(error.localizedDescription, privacy: .public)"
                    )
                    replyHandler(nil, error.localizedDescription)
                }
            }
        } catch {
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

import ApproovServiceWebViewCore
import SwiftUI
import UIKit
import WebKit

/// Shared `WKWebView` builder used by both the SwiftUI and UIKit hosts.
private enum ApproovWebViewFactory {
    static func makeWebView(
        content: ApproovWebViewContent,
        configuration: ApproovWebViewConfiguration,
        coordinator: ApproovWebViewCoordinator
    ) -> WKWebView {
        let userContentController = WKUserContentController()

        // Inject the bridge before any page code runs so page scripts cannot
        // race Fetch, XHR, or form submission before the native wrappers exist.
        let bridgeScript = WKUserScript(
            source: ApproovServiceWebViewCore.ApproovWebViewJavaScriptBridge.scriptSource(
                handlerName: configuration.bridgeHandlerName,
                protectedEndpoints: configuration.protectedEndpoints
            ),
            injectionTime: .atDocumentStart,
            // Production pages often use iframes. Injecting into all frames
            // gives the bridge coverage there as well.
            forMainFrameOnly: false
        )

        userContentController.addUserScript(bridgeScript)
        userContentController.addScriptMessageHandler(
            coordinator,
            contentWorld: .page,
            name: configuration.bridgeHandlerName
        )

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController = userContentController
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webViewConfiguration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground

        coordinator.attach(webView: webView)

        switch content {
        case let .htmlString(html, baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        case let .fileURL(fileURL, readAccessURL):
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        case let .request(request):
            webView.load(request)
        }

        return webView
    }
}

/// SwiftUI wrapper around `WKWebView` that installs the Approov bridge.
public struct ApproovWebView: UIViewRepresentable {
    public let content: ApproovWebViewContent
    public let configuration: ApproovWebViewConfiguration

    public init(
        content: ApproovWebViewContent,
        configuration: ApproovWebViewConfiguration
    ) {
        self.content = content
        self.configuration = configuration
    }

    public func makeCoordinator() -> ApproovWebViewCoordinator {
        ApproovWebViewCoordinator(configuration: configuration)
    }

    public func makeUIView(context: Context) -> WKWebView {
        ApproovWebViewFactory.makeWebView(
            content: content,
            configuration: configuration,
            coordinator: context.coordinator
        )
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// UIKit host for the same protected `WKWebView`.
public final class ApproovWebViewController: UIViewController {
    private let content: ApproovWebViewContent
    private let configuration: ApproovWebViewConfiguration
    private lazy var coordinator = ApproovWebViewCoordinator(configuration: configuration)
    private lazy var webView = ApproovWebViewFactory.makeWebView(
        content: content,
        configuration: configuration,
        coordinator: coordinator
    )

    public init(
        content: ApproovWebViewContent,
        configuration: ApproovWebViewConfiguration
    ) {
        self.content = content
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        view = webView
    }
}

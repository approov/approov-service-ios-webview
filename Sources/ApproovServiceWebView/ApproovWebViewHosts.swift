import SwiftUI
import UIKit
import WebKit

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

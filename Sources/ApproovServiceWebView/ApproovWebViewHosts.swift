import SwiftUI
import UIKit
import WebKit

/// A container that replaces its WebView when its content or configuration changes.
@MainActor
public final class ApproovWebViewContainer: UIView {
    private var currentContent: ApproovWebViewContent?
    private var currentConfigurationID: UUID?
    private(set) var webView: WKWebView?

    func update(content: ApproovWebViewContent, configuration: ApproovWebViewConfiguration, onError: (Error) -> Void) {
        if currentConfigurationID == configuration.installationID,
           let currentContent, Self.sameContent(currentContent, content) { return }
        webView?.removeFromSuperview()
        webView = nil
        currentContent = nil
        currentConfigurationID = nil
        subviews.forEach { $0.removeFromSuperview() }
        do {
            let view = try ApproovWebViewFactory.makeWebView(content: content, configuration: configuration)
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
            webView = view
            currentContent = content
            currentConfigurationID = configuration.installationID
        } catch {
            let label = UILabel(frame: bounds)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.text = "Unable to open this page."
            label.numberOfLines = 0
            label.textAlignment = .center
            addSubview(label)
            onError(error)
        }
    }

    private static func sameContent(_ lhs: ApproovWebViewContent, _ rhs: ApproovWebViewContent) -> Bool {
        switch (lhs, rhs) {
        case let (.htmlString(a, b), .htmlString(c, d)): return a == c && b == d
        case let (.fileURL(a, b), .fileURL(c, d)): return a == c && b == d
        case let (.request(a), .request(b)): return a == b
        default: return false
        }
    }
}

/// SwiftUI host. A new view is created when content or configuration changes.
public struct ApproovWebView: UIViewRepresentable {
    public let content: ApproovWebViewContent
    public let configuration: ApproovWebViewConfiguration
    public let onError: (Error) -> Void

    public init(content: ApproovWebViewContent, configuration: ApproovWebViewConfiguration,
                onError: @escaping (Error) -> Void = { _ in }) {
        self.content = content
        self.configuration = configuration
        self.onError = onError
    }

    public func makeUIView(context: Context) -> ApproovWebViewContainer {
        let container = ApproovWebViewContainer()
        container.update(content: content, configuration: configuration, onError: onError)
        return container
    }

    public func updateUIView(_ view: ApproovWebViewContainer, context: Context) {
        view.update(content: content, configuration: configuration, onError: onError)
    }
}

/// UIKit host for the same protected WebView.
public final class ApproovWebViewController: UIViewController {
    private let content: ApproovWebViewContent
    private let configuration: ApproovWebViewConfiguration
    private let onError: (Error) -> Void

    public init(content: ApproovWebViewContent, configuration: ApproovWebViewConfiguration,
                onError: @escaping (Error) -> Void = { _ in }) {
        self.content = content
        self.configuration = configuration
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let container = ApproovWebViewContainer()
        container.update(content: content, configuration: configuration, onError: onError)
        view = container
    }
}

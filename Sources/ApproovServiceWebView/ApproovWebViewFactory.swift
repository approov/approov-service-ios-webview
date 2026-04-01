import ApproovServiceWebViewCore
import Foundation
import ObjectiveC
import UIKit
import WebKit

private final class ApproovWebViewInstallation: NSObject {
    let bridgeScriptSource: String
    let coordinator: ApproovWebViewCoordinator

    init(
        bridgeScriptSource: String,
        coordinator: ApproovWebViewCoordinator
    ) {
        self.bridgeScriptSource = bridgeScriptSource
        self.coordinator = coordinator
    }
}

/// Public entry point for creating or installing an Approov-protected WebView.
///
/// Use this type when the convenience SwiftUI and UIKit hosts are too
/// opinionated and your app needs to work with a raw `WKWebView`.
public enum ApproovWebViewFactory {
    private static var installationAssociationKey: UInt8 = 0

    /// Creates a reusable coordinator for a custom host integration.
    @MainActor
    public static func makeCoordinator(
        configuration: ApproovWebViewConfiguration
    ) -> ApproovWebViewCoordinator {
        ApproovWebViewCoordinator(configuration: configuration)
    }

    /// Creates a new Approov-protected `WKWebView`, or installs the bridge onto
    /// a caller-provided instance.
    ///
    /// - Important: If you provide `baseWebView`, call this before the first
    ///   protected page load, or reload the page after installation. The bridge
    ///   uses a `WKUserScript` with `.atDocumentStart`, so it cannot retrofit a
    ///   page that has already finished loading.
    /// - Important: Reinstallation on the same `WKWebView` is treated as a
    ///   no-op unless the bridge configuration matches exactly. To change the
    ///   bridge configuration, create a fresh `WKWebView`.
    @MainActor
    public static func makeWebView(
        content: ApproovWebViewContent? = nil,
        configuration: ApproovWebViewConfiguration,
        coordinator: ApproovWebViewCoordinator? = nil,
        baseWebView: WKWebView? = nil
    ) -> WKWebView {
        let logger = ApproovWebViewLogger(configuration: configuration)
        let coordinator = coordinator ?? makeCoordinator(configuration: configuration)
        let webView = baseWebView ?? makeBaseWebView()
        logger.debug(
            """
            Preparing Approov web view using \(baseWebView == nil ? "a new" : "an existing") \
            WKWebView instance
            """
        )

        installBridgeIfNeeded(
            on: webView,
            configuration: configuration,
            coordinator: coordinator
        )

        if let content {
            logger.debug("Loading initial content into protected web view: \(content.logDescription)")
            coordinator.loadInitialContent(content)
        } else {
            logger.debug("Protected web view created without initial content")
        }

        return webView
    }

    /// Installs the Approov bridge onto an existing `WKWebView`.
    ///
    /// - Important: The provided web view must already allow content
    ///   JavaScript. WebKit applies most configuration values only when the web
    ///   view is created, so this method does not attempt to mutate them after
    ///   the fact.
    @MainActor
    @discardableResult
    public static func install(
        on webView: WKWebView,
        configuration: ApproovWebViewConfiguration,
        coordinator: ApproovWebViewCoordinator? = nil
    ) -> WKWebView {
        let logger = ApproovWebViewLogger(configuration: configuration)
        let coordinator = coordinator ?? makeCoordinator(configuration: configuration)
        logger.debug("Installing Approov bridge on existing WKWebView")

        installBridgeIfNeeded(
            on: webView,
            configuration: configuration,
            coordinator: coordinator
        )

        return webView
    }

    @MainActor
    private static func makeBaseWebView() -> WKWebView {
        let userContentController = WKUserContentController()
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController = userContentController
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webViewConfiguration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        return webView
    }

    @MainActor
    private static func installBridgeIfNeeded(
        on webView: WKWebView,
        configuration: ApproovWebViewConfiguration,
        coordinator: ApproovWebViewCoordinator
    ) {
        let logger = ApproovWebViewLogger(configuration: configuration)
        let bridgeScriptSource =
            ApproovServiceWebViewCore.ApproovWebViewJavaScriptBridge.scriptSource(
                handlerName: configuration.bridgeHandlerName,
                protectedEndpoints: configuration.protectedEndpoints
            )

        if let installation = installation(for: webView) {
            logger.debug("Approov bridge already installed on this WKWebView; reusing existing installation")
            assert(
                installation.bridgeScriptSource == bridgeScriptSource,
                """
                ApproovWebViewFactory does not support reconfiguring an already-installed WKWebView.
                Create a fresh WKWebView to change the bridge handler or protected endpoints.
                """
            )
            installation.coordinator.attach(webView: webView)
            return
        }

        assert(
            webView.configuration.defaultWebpagePreferences.allowsContentJavaScript,
            """
            ApproovWebViewFactory.install(on:) requires a base WKWebView with content JavaScript enabled.
            """
        )

        let userContentController = webView.configuration.userContentController
        logger.debug(
            """
            Installing bridge handler '\(configuration.bridgeHandlerName)' with \
            \(configuration.protectedEndpoints.count) protected endpoint(s)

            Protected endpoints:
            \(ApproovWebViewLogger.protectedEndpointsLogDescription(configuration.protectedEndpoints))
            """
        )

        // Inject the bridge before any page code runs so page scripts cannot
        // race Fetch, XHR, or form submission before the native wrappers exist.
        let bridgeScript = WKUserScript(
            source: bridgeScriptSource,
            injectionTime: .atDocumentStart,
            // Production pages often use iframes. Injecting into all frames
            // gives the bridge coverage there as well.
            forMainFrameOnly: false
        )

        // The handler name must be unique within a single user content
        // controller. Removing the page-world handler first makes installation
        // deterministic when callers reuse their own controller instance.
        userContentController.removeScriptMessageHandler(
            forName: configuration.bridgeHandlerName,
            contentWorld: .page
        )
        userContentController.addUserScript(bridgeScript)
        userContentController.addScriptMessageHandler(
            coordinator,
            contentWorld: .page,
            name: configuration.bridgeHandlerName
        )

        coordinator.attach(webView: webView)

        setInstallation(
            ApproovWebViewInstallation(
                bridgeScriptSource: bridgeScriptSource,
                coordinator: coordinator
            ),
            on: webView
        )
    }
    @MainActor
    private static func installation(for webView: WKWebView) -> ApproovWebViewInstallation? {
        objc_getAssociatedObject(
            webView,
            &installationAssociationKey
        ) as? ApproovWebViewInstallation
    }

    @MainActor
    private static func setInstallation(
        _ installation: ApproovWebViewInstallation,
        on webView: WKWebView
    ) {
        objc_setAssociatedObject(
            webView,
            &installationAssociationKey,
            installation,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

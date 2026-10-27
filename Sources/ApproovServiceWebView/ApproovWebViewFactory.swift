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

/// Errors reported when a bridge cannot be installed safely.
public enum ApproovWebViewInstallationError: Error, Equatable {
    case alreadyInstalled
    case javaScriptDisabled
    case contentControllerAlreadyInstalled
}

/// Public entry point for creating or installing an Approov-protected WebView.
///
/// Use this type when the convenience SwiftUI and UIKit hosts are too
/// opinionated and your app needs to work with a raw `WKWebView`.
public enum ApproovWebViewFactory {
    private static var installationAssociationKey: UInt8 = 0
    private static var controllerAssociationKey: UInt8 = 0

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
    /// - Important: A WebView can only be installed once. Create a fresh view
    ///   to change its configuration.
    @MainActor
    public static func makeWebView(
        content: ApproovWebViewContent? = nil,
        configuration: ApproovWebViewConfiguration,
        coordinator: ApproovWebViewCoordinator? = nil,
        baseWebView: WKWebView? = nil
    ) throws -> WKWebView {
        let logger = ApproovWebViewLogger(configuration: configuration)
        let coordinator = coordinator ?? makeCoordinator(configuration: configuration)
        let webView = baseWebView ?? makeBaseWebView()
        logger.debug(
            """
            Preparing Approov web view using \(baseWebView == nil ? "a new" : "an existing") \
            WKWebView instance
            """
        )

        try installBridgeIfNeeded(
            on: webView,
            configuration: configuration,
            coordinator: coordinator
        )

        if let content {
            logger.debug("Loading initial content into protected web view: \(content.logDescription)")
            load(content, into: webView)
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
    ) throws -> WKWebView {
        let logger = ApproovWebViewLogger(configuration: configuration)
        let coordinator = coordinator ?? makeCoordinator(configuration: configuration)
        logger.debug("Installing Approov bridge on existing WKWebView")

        try installBridgeIfNeeded(
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
    ) throws {
        let logger = ApproovWebViewLogger(configuration: configuration)
        let bridgeScriptSource =
            ApproovServiceWebViewCore.ApproovWebViewJavaScriptBridge.scriptSource(
                handlerName: configuration.bridgeHandlerName,
                protectedEndpoints: configuration.protectedEndpoints,
                xhrBridgeEnabled: configuration.interceptXMLHttpRequests
            )

        guard installation(for: webView) == nil else {
            throw ApproovWebViewInstallationError.alreadyInstalled
        }
        guard webView.configuration.defaultWebpagePreferences.allowsContentJavaScript else {
            throw ApproovWebViewInstallationError.javaScriptDisabled
        }

        let userContentController = webView.configuration.userContentController
        guard objc_getAssociatedObject(userContentController, &controllerAssociationKey) == nil else {
            throw ApproovWebViewInstallationError.contentControllerAlreadyInstalled
        }
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
            // Production pages often use iframes, so the wrapper script is
            // injected into all frames to cover protected calls made there. The
            // security boundary is NOT this injection: it is the per-message
            // origin check in ApproovWebViewCoordinator, which rejects calls from
            // any frame outside configuration.allowedOrigins before a request is
            // executed. An untrusted subframe therefore gets the wrapper but
            // cannot obtain Approov-stamped responses.
            forMainFrameOnly: false
        )

        // The controller and its scripts belong to exactly one installation.
        userContentController.addUserScript(bridgeScript)
        userContentController.addScriptMessageHandler(
            coordinator,
            contentWorld: .page,
            name: configuration.bridgeHandlerName
        )

        coordinator.attach(webView: webView)
        objc_setAssociatedObject(userContentController, &controllerAssociationKey, true as NSNumber, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        setInstallation(
            ApproovWebViewInstallation(
                bridgeScriptSource: bridgeScriptSource,
                coordinator: coordinator
            ),
            on: webView
        )
    }

    @MainActor
    private static func load(
        _ content: ApproovWebViewContent,
        into webView: WKWebView
    ) {
        switch content {
        case let .htmlString(html, baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        case let .fileURL(fileURL, readAccessURL):
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        case let .request(request):
            webView.load(request)
        }
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

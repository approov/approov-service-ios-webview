import ApproovServiceWebViewCore
import Foundation
import ObjectiveC
import UIKit
import WebKit

private final class ApproovWebViewStoreLease: NSObject {}

private final class ApproovWebViewStoreOwner: NSObject {
    // The store cannot own its lease: the executor's cookie bridge owns the store.
    weak var lease: AnyObject?
    init(lease: AnyObject) { self.lease = lease }
}

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

    deinit {
        // A retained/autoreleased configuration can keep its message handler
        // alive after the raw WebView is gone. Close that installation promptly.
        let coordinator = coordinator
        Task { @MainActor in coordinator.invalidate() }
    }
}

/// Errors reported when a bridge cannot be installed safely.
public enum ApproovWebViewInstallationError: Error, Equatable {
    case alreadyInstalled
    case javaScriptDisabled
    case contentControllerAlreadyInstalled
    case coordinatorAlreadyAttached
    case dataStoreAlreadyInUse
    case invalidConfiguration(String)
    case coordinatorConfigurationMismatch
}

/// Public entry point for creating or installing an Approov-protected WebView.
///
/// Use this type when the convenience SwiftUI and UIKit hosts are too
/// opinionated and your app needs to work with a raw `WKWebView`.
public enum ApproovWebViewFactory {
    private static var installationAssociationKey: UInt8 = 0
    private static var controllerAssociationKey: UInt8 = 0
    private static var storeAssociationKey: UInt8 = 0

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

    /// Cancels outstanding bridge requests when a custom host closes the view.
    /// The installation remains closed; create a new view for another session.
    @MainActor
    public static func invalidate(on webView: WKWebView) {
        installation(for: webView)?.coordinator.invalidate()
        webView.stopLoading()
    }

    @MainActor
    private static func makeBaseWebView() -> WKWebView {
        let userContentController = WKUserContentController()
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController = userContentController
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webViewConfiguration.websiteDataStore = .nonPersistent()

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
        try validate(configuration)
        guard coordinator.configurationID == configuration.installationID else {
            throw ApproovWebViewInstallationError.coordinatorConfigurationMismatch
        }
        let logger = ApproovWebViewLogger(configuration: configuration)
        let bridgeScriptSource =
            ApproovServiceWebViewCore.ApproovWebViewJavaScriptBridge.scriptSource(
                handlerName: configuration.bridgeHandlerName,
                protectedEndpoints: configuration.protectedEndpoints,
                xhrBridgeEnabled: configuration.interceptXMLHttpRequests,
                maxRequestBodyBytes: configuration.maximumRequestBodyBytes,
                formBridgeEnabled: configuration.interceptForms
            )

        guard installation(for: webView) == nil else {
            throw ApproovWebViewInstallationError.alreadyInstalled
        }
        guard webView.configuration.defaultWebpagePreferences.allowsContentJavaScript else {
            throw ApproovWebViewInstallationError.javaScriptDisabled
        }

        guard coordinator.canAttachWebView else {
            throw ApproovWebViewInstallationError.coordinatorAlreadyAttached
        }
        let userContentController = webView.configuration.userContentController
        guard objc_getAssociatedObject(userContentController, &controllerAssociationKey) == nil else {
            throw ApproovWebViewInstallationError.contentControllerAlreadyInstalled
        }
        let dataStore = webView.configuration.websiteDataStore
        if let owner = objc_getAssociatedObject(dataStore, &storeAssociationKey) as? ApproovWebViewStoreOwner,
            owner.lease != nil
        {
            throw ApproovWebViewInstallationError.dataStoreAlreadyInUse
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

        let storeLease = ApproovWebViewStoreLease()
        coordinator.attach(webView: webView, lifetimeOwner: storeLease)
        objc_setAssociatedObject(
            userContentController, &controllerAssociationKey, true as NSNumber, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(
            dataStore, &storeAssociationKey, ApproovWebViewStoreOwner(lease: storeLease),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        setInstallation(
            ApproovWebViewInstallation(
                bridgeScriptSource: bridgeScriptSource,
                coordinator: coordinator
            ),
            on: webView
        )
    }

    /// Reject configuration errors before registering WebKit handlers or scripts.
    private static func validate(_ configuration: ApproovWebViewConfiguration) throws {
        func require(_ condition: Bool, _ field: String) throws {
            if !condition { throw ApproovWebViewInstallationError.invalidConfiguration(field) }
        }
        try require(configuration.maximumConcurrentRequests > 0, "maximumConcurrentRequests")
        try require(
            configuration.maximumRequestDuration.isFinite && configuration.maximumRequestDuration > 0,
            "maximumRequestDuration")
        try require(configuration.maximumRequestBodyBytes > 0, "maximumRequestBodyBytes")
        try require(configuration.maximumResponseBodyBytes > 0, "maximumResponseBodyBytes")
        try require(
            !configuration.bridgeHandlerName.isEmpty && configuration.bridgeHandlerName.utf8.count <= 256
                && !configuration.bridgeHandlerName.contains("\0"), "bridgeHandlerName")
        let headerToken = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        try require(
            !configuration.approovTokenHeaderName.isEmpty
                && configuration.approovTokenHeaderName.unicodeScalars.allSatisfy(headerToken.contains),
            "approovTokenHeaderName")
        try require(
            configuration.approovTokenHeaderPrefix.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7f
            }, "approovTokenHeaderPrefix")
        for endpoint in configuration.protectedEndpoints {
            try require(endpoint.port.map { (1...65535).contains($0) } ?? true, "protectedEndpoints.port")
            try require(endpoint.scheme == "https" || endpoint.scheme == "http", "protectedEndpoints.scheme")
            var components = URLComponents()
            components.scheme = endpoint.scheme
            components.host = endpoint.host
            try require(
                !endpoint.host.isEmpty && components.url?.host?.lowercased() == endpoint.host
                    && !endpoint.host.contains("*") && !endpoint.host.contains("@"), "protectedEndpoints.host")
        }
        for rule in configuration.allowedOrigins {
            if rule == "*" { continue }
            let candidate = rule.replacingOccurrences(of: "://*.", with: "://")
            guard let components = URLComponents(string: candidate) else {
                throw ApproovWebViewInstallationError.invalidConfiguration("allowedOrigins")
            }
            try require(
                (components.scheme == "https" || components.scheme == "http") && components.host?.isEmpty == false
                    && components.user == nil && components.password == nil
                    && (components.path.isEmpty || components.path == "/") && components.query == nil
                    && components.fragment == nil && !candidate.contains("*")
                    && (components.port.map { (1...65_535).contains($0) } ?? true), "allowedOrigins")
        }
    }

    @MainActor
    private static func load(
        _ content: ApproovWebViewContent,
        into webView: WKWebView
    ) {
        switch content {
        case .htmlString(let html, let baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        case .fileURL(let fileURL, let readAccessURL):
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        case .request(let request):
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

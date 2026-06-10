import Foundation

/// Describes the first content loaded into the protected WebView.
///
/// `.request` is appropriate when the app opens a hosted web experience.
/// `.htmlString` is useful for local demos or bundled HTML.
public enum ApproovWebViewContent {
    case htmlString(String, baseURL: URL?)
    case fileURL(URL, allowingReadAccessTo: URL)
    case request(URLRequest)
}

/// Declares a protected API surface that should be routed into native code.
///
/// Requests that do not match one of these entries stay on the normal WebKit
/// networking stack and are never proxied through `ApproovURLSession`.
public struct ApproovWebViewProtectedEndpoint: Sendable, Encodable {
    public let scheme: String
    public let host: String
    public let pathPrefix: String
    public let excludedPathPrefixes: [String]

    public init(
        scheme: String = "https",
        host: String,
        pathPrefix: String,
        excludedPathPrefixes: [String] = []
    ) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.pathPrefix = Self.normalizePathPrefix(pathPrefix)
        self.excludedPathPrefixes = excludedPathPrefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(Self.normalizePathPrefix)
    }

    public func matches(_ url: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(),
              let urlHost = url.host?.lowercased(),
              urlScheme == scheme,
              urlHost == host else {
            return false
        }

        let urlPath = url.path.isEmpty ? "/" : url.path
        guard Self.pathMatches(urlPath, pathPrefix: pathPrefix) else {
            return false
        }

        return !excludedPathPrefixes.contains { excludedPathPrefix in
            Self.pathMatches(urlPath, pathPrefix: excludedPathPrefix)
        }
    }

    private static func normalizePathPrefix(_ pathPrefix: String) -> String {
        let trimmed = pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }

        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    private static func pathMatches(_ urlPath: String, pathPrefix: String) -> Bool {
        if pathPrefix == "/" {
            return true
        }

        return urlPath == pathPrefix || urlPath.hasPrefix(pathPrefix + "/")
    }
}

/// Holds the generic policy for an Approov-protected WebView.
///
/// This type is the small, reusable integration surface. All app-specific
/// behavior should be driven through these properties instead of editing the
/// bridge internals.
public struct ApproovWebViewConfiguration: Sendable {
    /// Your Approov onboarding string.
    public let approovConfig: String

    /// The name used by JavaScript when calling
    /// `window.webkit.messageHandlers.<name>.postMessage(...)`.
    public let bridgeHandlerName: String

    /// The header that receives the Approov JWT.
    public let approovTokenHeaderName: String

    /// The prefix used when writing the Approov JWT header.
    public let approovTokenHeaderPrefix: String

    /// Optional Approov development key applied after initialization.
    public let approovDevelopmentKey: String?

    /// Controls fail-open versus fail-closed behavior.
    ///
    /// `true` means a request is still executed if Approov cannot produce a
    /// JWT. `false` means the bridge rejects the request instead.
    public let allowRequestsWithoutApproovToken: Bool

    /// The strict allowlist of page requests that should be proxied into native
    /// networking and protected by `ApproovURLSession`.
    public let protectedEndpoints: [ApproovWebViewProtectedEndpoint]

    /// The origins permitted to invoke the native bridge.
    ///
    /// The bridge script is injected into every frame of every page, so this
    /// list is the trust boundary that decides *who* may ask the native layer to
    /// produce Approov-stamped responses. Supported rule forms:
    /// - `https://example.com` — that exact origin on the default HTTPS port.
    /// - `https://example.com:8443` — that exact origin on port 8443.
    /// - `https://*.example.com` — any subdomain of `example.com`.
    /// - `*` — any origin (not recommended).
    ///
    /// This argument is required so the trust boundary is a conscious choice, as
    /// it is on Android (which rejects a build with no origin rules). Passing an
    /// empty list is the explicit escape hatch for the legacy allow-all behavior
    /// and logs a warning; pass `["*"]` if you genuinely intend any origin.
    public let allowedOrigins: [String]

    /// Enables JavaScript `XMLHttpRequest` interception for protected traffic.
    ///
    /// Set this to `false` if the host web app relies on native WebKit XHR
    /// behavior and only needs Approov interception for `fetch` or forms.
    public let interceptXMLHttpRequests: Bool

    /// Gives the host app one place to run one-time Approov setup.
    ///
    /// Typical uses include setting a development key or enabling additional
    /// Approov features after `ApproovService.initialize(...)`.
    public let configureApproovService: @Sendable () throws -> Void

    /// Gives the host app one place to apply native-only mutations.
    ///
    /// Typical uses include injecting API keys, tenant headers, or other
    /// values that must never be exposed to web content. The bridge applies
    /// this inside the composed `ApproovServiceMutator` so the request is
    /// mutated as part of the `ApproovURLSession` pipeline.
    public let mutateRequest: @Sendable (URLRequest) -> URLRequest

    /// Enables opt-in debug logging for the native bridge lifecycle.
    public let debugLoggingEnabled: Bool

    /// Logging metadata used by `OSLog`.
    public let loggerSubsystem: String
    public let loggerCategory: String

    public init(
        approovConfig: String,
        protectedEndpoints: [ApproovWebViewProtectedEndpoint],
        allowedOrigins: [String],
        bridgeHandlerName: String = "approovBridge",
        approovTokenHeaderName: String = "approov-token",
        approovTokenHeaderPrefix: String = "",
        approovDevelopmentKey: String? = nil,
        allowRequestsWithoutApproovToken: Bool = false,
        interceptXMLHttpRequests: Bool = true,
        configureApproovService: @escaping @Sendable () throws -> Void = {},
        mutateRequest: @escaping @Sendable (URLRequest) -> URLRequest = { $0 },
        debugLoggingEnabled: Bool = true,
        loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "ApproovWebView",
        loggerCategory: String = "ApproovWebViewBridge"
    ) {
        self.approovConfig = approovConfig
        self.protectedEndpoints = protectedEndpoints
        self.allowedOrigins = allowedOrigins
        self.bridgeHandlerName = bridgeHandlerName
        self.approovTokenHeaderName = approovTokenHeaderName
        self.approovTokenHeaderPrefix = approovTokenHeaderPrefix
        self.approovDevelopmentKey = approovDevelopmentKey
        self.allowRequestsWithoutApproovToken = allowRequestsWithoutApproovToken
        self.interceptXMLHttpRequests = interceptXMLHttpRequests
        self.configureApproovService = configureApproovService
        self.mutateRequest = mutateRequest
        self.debugLoggingEnabled = debugLoggingEnabled
        self.loggerSubsystem = loggerSubsystem
        self.loggerCategory = loggerCategory
    }

    public func isProtectedEndpoint(_ url: URL) -> Bool {
        protectedEndpoints.contains { $0.matches(url) }
    }

    /// Whether the bridge restricts callers to a configured origin allowlist.
    public var enforcesOriginAllowlist: Bool {
        !allowedOrigins.isEmpty
    }

    /// Returns `true` when a frame at `origin` is permitted to call the bridge.
    public func isAllowedOrigin(_ origin: String) -> Bool {
        ApproovWebViewOriginMatcher.matches(origin: origin, rules: allowedOrigins)
    }
}

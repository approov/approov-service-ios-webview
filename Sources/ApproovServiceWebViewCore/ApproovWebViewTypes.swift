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
        self.excludedPathPrefixes = excludedPathPrefixes.map(Self.normalizePathPrefix)
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
        bridgeHandlerName: String = "approovBridge",
        approovTokenHeaderName: String = "approov-token",
        approovTokenHeaderPrefix: String = "",
        approovDevelopmentKey: String? = nil,
        allowRequestsWithoutApproovToken: Bool = false,
        configureApproovService: @escaping @Sendable () throws -> Void = {},
        mutateRequest: @escaping @Sendable (URLRequest) -> URLRequest = { $0 },
        debugLoggingEnabled: Bool = true,
        loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "ApproovWebView",
        loggerCategory: String = "ApproovWebViewBridge"
    ) {
        self.approovConfig = approovConfig
        self.protectedEndpoints = protectedEndpoints
        self.bridgeHandlerName = bridgeHandlerName
        self.approovTokenHeaderName = approovTokenHeaderName
        self.approovTokenHeaderPrefix = approovTokenHeaderPrefix
        self.approovDevelopmentKey = approovDevelopmentKey
        self.allowRequestsWithoutApproovToken = allowRequestsWithoutApproovToken
        self.configureApproovService = configureApproovService
        self.mutateRequest = mutateRequest
        self.debugLoggingEnabled = debugLoggingEnabled
        self.loggerSubsystem = loggerSubsystem
        self.loggerCategory = loggerCategory
    }

    public func isProtectedEndpoint(_ url: URL) -> Bool {
        protectedEndpoints.contains { $0.matches(url) }
    }
}

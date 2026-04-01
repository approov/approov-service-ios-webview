import Foundation

/// Describes how the native layer should hand a response back to the page.
enum ApproovWebViewResponseHandling: String, Decodable {
    case response
    case navigation
}

/// Identifies which browser primitive originated the request.
enum ApproovWebViewRequestSource: String, Decodable {
    case fetch
    case xhr
    case form
}

/// Shape of the request payload sent from JavaScript into Swift.
///
/// Bodies are base64-encoded so binary and multipart payloads survive the
/// script message hop without lossy string conversion.
struct ApproovWebViewProxyRequest: Decodable {
    let url: String
    let method: String
    let headers: [String: String]
    let bodyBase64: String?
    let sourcePageURL: String?
    let responseHandling: ApproovWebViewResponseHandling
    let requestSource: ApproovWebViewRequestSource
}

/// Shape of the response payload sent back into JavaScript.
struct ApproovWebViewProxyResponse: Encodable {
    let url: String
    let status: Int
    let statusText: String
    let headers: [String: String]
    let bodyBase64: String
}

/// Native response payload used to render a WebView navigation.
struct ApproovWebViewNavigationLoad {
    let request: URLRequest
    let response: URLResponse
    let data: Data
}

/// Internal execution result used by the coordinator.
enum ApproovWebViewExecutionResult {
    case response(ApproovWebViewProxyResponse)
    case navigation(ApproovWebViewNavigationLoad)
}

/// Abstracts the execution of WebView requests for concurrent processing.
protocol ApproovWebViewRequestExecuting: Sendable {
    func execute(_ proxyRequest: ApproovWebViewProxyRequest) async throws -> ApproovWebViewExecutionResult
    func executeInitialNavigation(_ request: URLRequest) async throws -> ApproovWebViewNavigationLoad
}

/// Bridge-specific errors surfaced back to page JavaScript.
enum ApproovWebViewBridgeError: LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case invalidRequestBody
    case approovConfigEmpty
    case requestNotProtected(String)
    case nonHTTPResponse
    case unexpectedResult
    case webViewUnavailable

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return "The WebView requested an invalid URL: \(url)"
        case let .unsupportedScheme(url):
            return "Only HTTP and HTTPS requests can be proxied by the Approov WebView bridge: \(url)"
        case .invalidRequestBody:
            return "The WebView request body was not valid base64."
        case .approovConfigEmpty:
            return "The Approov config string is empty."
        case let .requestNotProtected(url):
            return "The WebView tried to proxy an unprotected request through native code: \(url)"
        case .nonHTTPResponse:
            return "Native networking returned a non-HTTP response."
        case .unexpectedResult:
            return "Native networking returned an unexpected execution result."
        case .webViewUnavailable:
            return "The WKWebView was released before a navigation response could be applied."
        }
    }
}

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
    let requestId: String?
    let credentials: String?
    let mode: String?
    let redirect: String?
    let cache: String?
    let integrity: String?
    let referrer: String?
    let referrerPolicy: String?
}

/// Trusted context comes from WKFrameInfo, never from the message body.
struct ApproovWebViewRequestContext: Sendable {
    let frameURL: URL
    let frameOrigin: String
    let mainDocumentURL: URL?
    let isMainFrame: Bool
}

/// Shape of the response payload sent back into JavaScript.
struct ApproovWebViewProxyResponse: Encodable {
    let url: String
    let status: Int
    let statusText: String
    let headers: [String: String]
    let bodyBase64: String
    var redirected = false
    var type = "basic"
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

/// Bridge-specific errors surfaced back to page JavaScript.
enum ApproovWebViewBridgeError: LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case invalidRequestBody
    case approovConfigEmpty
    case requestNotProtected(String)
    case nonHTTPResponse
    case webViewUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The WebView requested an invalid URL."
        case .unsupportedScheme:
            return "Only HTTP and HTTPS requests can use the native bridge."
        case .invalidRequestBody:
            return "The WebView request body was not valid base64."
        case .approovConfigEmpty:
            return "The Approov config string is empty."
        case .requestNotProtected:
            return "The request does not match a protected endpoint."
        case .nonHTTPResponse:
            return "Native networking returned a non-HTTP response."
        case .webViewUnavailable:
            return "The WKWebView was released before a navigation response could be applied."
        }
    }
}

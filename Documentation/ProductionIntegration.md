# Production integration

The host app owns session preparation and the retry interface. The bridge protects only requests that match `protectedEndpoints`.

## Prepare the release

- Keep development keys inside `#if DEBUG` code. Release builds must pass `nil` for `approovDevelopmentKey`.
- Register the protected API domains in Approov.
- List the trusted page origins in `allowedOrigins`.
- List the protected API paths and ports in `protectedEndpoints`.
- Make sure that the backend rejects missing, invalid, expired, and incorrectly bound Approov tokens.
- Remove response bodies, POST bodies, cookie values, and full URLs from application logs.
- Run the complete flow against a test environment before release.

Page origins permit bridge callers. API endpoints permit native destinations. These lists have different purposes.

## Prepare the WebView before loading

This example captures the User-Agent before protected traffic starts. The host supplies fresh session cookies through its authenticated session service.

```swift
import ApproovServiceWebView
import WebKit

enum HostedFlowPreparationError: Error {
    case missingUserAgent
}

@MainActor
func prepareHostedFlow(
    approovConfig: String,
    nativeAPIKey: String,
    refreshSessionCookies: () async throws -> [HTTPCookie]
) async throws -> WKWebView {
    let base = WKWebViewConfiguration()
    base.userContentController = WKUserContentController()
    base.websiteDataStore = .nonPersistent()
    base.defaultWebpagePreferences.allowsContentJavaScript = true
    let view = WKWebView(frame: .zero, configuration: base)

    guard let userAgent = try await view.evaluateJavaScript("navigator.userAgent") as? String,
          !userAgent.isEmpty else {
        throw HostedFlowPreparationError.missingUserAgent
    }

    #if DEBUG
    let developmentKey: String? = nil // Supply a test key through the debug build only.
    #else
    let developmentKey: String? = nil
    #endif

    let configuration = ApproovWebViewConfiguration(
        approovConfig: approovConfig,
        protectedEndpoints: [
            .init(host: "api.example.com", pathPrefix: "/v1/checkout")
        ],
        allowedOrigins: ["https://checkout.example.com"],
        approovDevelopmentKey: developmentKey,
        mutateRequest: { request in
            var request = request
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(nativeAPIKey, forHTTPHeaderField: "Api-Key")
            return request
        },
        debugLoggingEnabled: false
    )

    // The host session service returns current cookies for this user and flow.
    for cookie in try await refreshSessionCookies() {
        await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    }
    try ApproovWebViewFactory.install(on: view, configuration: configuration)
    return view
}
```

Keep the returned view alive for the complete flow. Load the trusted page only after preparation succeeds.

```swift
let view = try await prepareHostedFlow(
    approovConfig: appConfiguration,
    nativeAPIKey: currentAPIKey,
    refreshSessionCookies: refreshAuthenticatedSessionCookies
)
view.load(URLRequest(url: URL(string: "https://checkout.example.com/start")!))
```

The example uses application values and an application session callback. It does not contain a reusable session cookie or release development key.

If the app already initializes Approov, set `usesExistingApproovService: true`. The host must complete service configuration before the first protected request.

The library-managed mode runs `configureApproovService` during service preparation. Do not use that callback to replace another feature's global configuration.

## Provide a visible retry path

Handle installation, document navigation, and protected HTTP failures separately.

| Failure | Owner and response |
| --- | --- |
| Preparation or installation throws | Host: show a short error and a **Try again** button. |
| `WKNavigationDelegate.didFail` or `didFailProvisionalNavigation` | Host: show the navigation error and the retry button. |
| Document `WKNavigationResponse` has HTTP status 400 or greater | Host: show an HTTP error and decide whether to cancel the navigation. |
| Protected `fetch` returns HTTP status 400 or greater | Page: inspect `response.ok` and show a retry control. |
| Protected XHR completes with HTTP status 400 or greater | Page: inspect `status` and show a retry control. |
| Protected request promise rejects or XHR reports an error | Page: show a transport error and an appropriate retry control. |

The wrapper's `onError` callback reports host installation failures. It does not replace `WKNavigationDelegate` or page HTTP handling.

On **Try again**, refresh the authenticated session before opening a fresh view. Retain the navigation delegate for the complete flow.

Before closing or replacing a raw WebView, call `ApproovWebViewFactory.invalidate(on:)`. SwiftUI replacement and dismantling cancel outstanding bridge requests automatically.

Cancellation cannot undo a server operation that the server already accepted. For payment or booking retries, use the backend's idempotency mechanism.

## Supported browser behavior

The native route supports a defined subset of browser networking.
It uses verified frame context for origin and referrer policy.
Cross-origin calls require successful CORS permission checks.
Non-simple cross-origin calls also require a successful native preflight.
Native-only signing headers are separate from the page's requested CORS headers.

Same-origin requests can use the default `same-origin` credentials mode.
Same-site requests between subdomains require `credentials: 'include'` to send cookies.
For example, `shop.example.com` and `api.example.com` can share an eligible `.example.com` session cookie over HTTPS.

Credentialed cross-site requests are unsupported and reject.
The native route cannot reproduce WebKit's third-party tracking policy.
A trusted iframe also needs a same-site top-level document for cookie-bearing native requests.
Use an application authentication design that stays within these boundaries.

| Feature | Protected bridge behavior |
| --- | --- |
| `mode: 'no-cors'` | Unsupported. The bridge rejects the request. |
| `redirect: 'manual'` | Unsupported. The bridge rejects the request. |
| Nonempty `integrity` | Unsupported. The bridge rejects the request. |
| Streaming request body | Unsupported. Use a finite body within the configured limit. |
| Progressive response streaming | Unsupported. The complete response is buffered before delivery. |
| WebKit HTTP cache | Separate from native execution. The bridge does not read or populate this cache. |
| WebKit preflight cache | Separate from native execution. Native preflights do not reuse that cache. |

For predictable native execution, use `cache: 'default'` or `cache: 'no-store'`.
The bridge's default route bypasses the local HTTP cache.
Its default behavior therefore differs from an ordinary WebKit request with browser caching.
Browser cache-specific behavior is outside the supported contract.
Requests outside the protected rules retain their WebKit networking behavior.

## Navigation error handling

Retain a navigation delegate in a custom host.
Connect its failure callback to a visible message and a **Try again** button.
The retry action must prepare a fresh session and view before loading the page again.

```swift
@MainActor
final class HostedNavigationHandler: NSObject, WKNavigationDelegate {
    let showRetry: (String) -> Void

    init(showRetry: @escaping (String) -> Void) {
        self.showRetry = showRetry
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showRetry("The page could not open. Try again.")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showRetry("The page could not open. Try again.")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            showRetry("The service could not open this page. Try again.")
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
```

The page must still inspect protected fetch and XHR HTTP status codes.
A successful transport with status 400 or greater does not trigger the host's navigation delegate for an API request.
Keep full native error descriptions and response bodies out of the retry interface and application logs.

## Check the complete request path

- Make sure that each protected request matches its intended scheme, host, port, and path.
- Make sure that redirects remain inside the approved destination rules.
- Make sure that the backend permits the required CORS origin, methods, headers, and credentials.
- Make sure that the page handles HTTP errors without logging response bodies.
- Make sure that fresh cookies reach the isolated WebView store before the first protected request.
- Make sure that expired sessions return the user to authentication.
- Make sure that cancellation stops pending native work when the flow closes.
- Make sure that a release build contains no development key or sensitive diagnostic output.

Initial loads, links, assets, workers, and unsupported form targets need separate transport decisions. See [routing boundaries](../README.md#routing-boundaries-and-compatibility).

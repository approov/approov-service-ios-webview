# Approov Service for iOS WebView

Swift Package Manager library for protecting selected `WKWebView` traffic with Approov on iOS.

The package injects a JavaScript bridge into the page, intercepts protected `fetch`, optional `XMLHttpRequest`, and form submissions, executes those requests through `ApproovURLSession`, and returns the response to the page. Requests outside the configured allowlist stay on the normal WebKit networking stack.

> [!IMPORTANT]
> Only endpoints declared in `protectedEndpoints` are proxied through native networking and protected by Approov.

For an existing integration, see [migration to 0.6](Documentation/MigratingTo0.6.md).

## Requirements

| Item | Value |
| --- | --- |
| Platform | iOS 15+ |
| Package manager | Swift Package Manager |
| Library product | `ApproovServiceWebView` |

## Installation

### Xcode

1. Open your app project in Xcode.
2. Choose `File` -> `Add Package Dependencies...`
3. Enter `https://github.com/approov/approov-service-ios-webview.git`
4. Select the branch or version you want to pin.
5. Add the `ApproovServiceWebView` product to your app target.

### Package.swift

```swift
dependencies: [
    .package(
        url: "https://github.com/approov/approov-service-ios-webview.git",
        branch: "main"
    )
]
```

Then add the product dependency to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(
            name: "ApproovServiceWebView",
            package: "approov-service-ios-webview"
        )
    ]
)
```

Import the package in your app target:

```swift
import ApproovServiceWebView
```

## What the Package Provides

| Type | Purpose |
| --- | --- |
| `ApproovWebView` | SwiftUI host for a protected `WKWebView`. |
| `ApproovWebViewController` | UIKit host for the same bridge and request pipeline. |
| `ApproovWebViewFactory` | Low-level API for creating or installing an Approov bridge on a raw `WKWebView`. |
| `ApproovWebViewConfiguration` | Main integration surface for Approov setup, endpoint allowlisting, optional XHR interception, token header settings, fail-open policy, and native request mutation. |
| `ApproovWebViewProtectedEndpoint` | Scheme, host, path-prefix, and excluded-path-prefix matcher for protected traffic. |
| `ApproovWebViewContent` | Initial content source for the web view: request, HTML string, or file URL. |

`ApproovServiceWebView` re-exports the shared core types, so a single `import ApproovServiceWebView` is sufficient in app code.

## Request Model

Protected requests follow this path:

1. The package injects its bridge script at document start.
2. Matching page requests are serialized from JavaScript and passed to native code.
3. Native execution runs through `ApproovURLSession`, including your existing Approov mutator chain.
4. The response is marshalled back into the page runtime.

Unmatched requests continue through WebKit unchanged.

> [!IMPORTANT]
> Use only one Approov-protected `WKWebView` at a time for each
> `WKWebsiteDataStore`. Cookie reconciliation is owned by one request executor;
> two protected web views sharing a data store, including `.default()`, are not
> serialized against each other and are currently unsupported.

## Configuration

`ApproovWebViewConfiguration` is the main contract between the host app and the package.

| Property | Purpose |
| --- | --- |
| `approovConfig` | Approov onboarding string for `ApproovService.initialize(...)`. |
| `protectedEndpoints` | Strict allowlist for traffic that should be routed through native networking. |
| `allowedOrigins` | Required frame-origin allowlist for callers permitted to use the native bridge. |
| `approovTokenHeaderName` | Header name used for the Approov token. Default: `approov-token`. |
| `approovTokenHeaderPrefix` | Optional header prefix, for example `Bearer `. |
| `approovDevelopmentKey` | Optional development key applied after initialization. |
| `allowRequestsWithoutApproovToken` | Controls fail-open vs fail-closed behavior when Approov cannot produce a token. |
| `interceptXMLHttpRequests` | Enables or disables JavaScript `XMLHttpRequest` interception. Default: `true`. |
| `interceptForms` | Enables supported main-frame form interception. Default: `true`. |
| `maximumRequestBodyBytes` | Maximum buffered request body size. Default: 10 MiB. |
| `maximumRequestDuration` | Native request resource deadline in seconds. Default: 60. |
| `maximumResponseBodyBytes` | Maximum buffered response body size. Default: 10 MiB. |
| `maximumConcurrentRequests` | Maximum active native bridge requests per view. Default: 16. |
| `usesExistingApproovService` | Uses the service that the host already initialized. Default: `false`. |
| `configureApproovService` | Hook for one-time Approov setup beyond the default initialization path. |
| `mutateRequest` | Native-only request mutation point for secrets or headers that must not be exposed to page JavaScript. |
| `debugLoggingEnabled` | Enables opt-in debug `OSLog` output for the native bridge lifecycle. |
| `bridgeHandlerName` | WebKit message handler name used by the injected bridge. |

> [!IMPORTANT]
> Keep `protectedEndpoints` as narrow as possible. The bridge should route only
> endpoints that require an Approov token through native networking. Analytics,
> reporting, static assets, and other non-protected traffic should stay on the
> normal WebKit networking stack.

Prefer allowlisting only the protected API paths:

```swift
ApproovWebViewConfiguration(
    approovConfig: "<your-approov-config>",
    protectedEndpoints: [
        ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/v1/protected"
        )
    ],
    // The frame origin(s) allowed to use the bridge. Required: set this to the
    // origin that hosts your funnel so untrusted frames cannot call the bridge.
    allowedOrigins: ["https://app.example.com"]
)
```

Do not protect a whole host if only part of it needs Approov protection,
especially when the same page also sends analytics or reporting traffic:

```swift
// Avoid this unless every request on the host requires Approov protection.
ApproovWebViewProtectedEndpoint(
    host: "www.example.com",
    pathPrefix: "/"
)
```

If protected and non-protected paths share a host, use `excludedPathPrefixes` to
keep analytics, reporting, assets, and other public paths outside the bridge:

```swift
ApproovWebViewProtectedEndpoint(
    host: "www.example.com",
    pathPrefix: "/",
    excludedPathPrefixes: [
        "/analytics",
        "/metrics",
        "/assets"
    ]
)
```

## Quick Start

```swift
import ApproovServiceWebView
import SwiftUI

struct ProtectedWebExperience: View {
    private let configuration = ApproovWebViewConfiguration(
        approovConfig: "<your-approov-config>",
        protectedEndpoints: [
            ApproovWebViewProtectedEndpoint(
                host: "api.example.com",
                pathPrefix: "/v1/private"
            )
        ],
        allowedOrigins: ["https://app.example.com"],
        // Development keys belong in debug builds only.
        approovDevelopmentKey: nil,
        mutateRequest: { request in
            var request = request
            request.setValue("<api-key>", forHTTPHeaderField: "Api-Key")
            return request
        },
        debugLoggingEnabled: false
    )

    var body: some View {
        ApproovWebView(
            content: .request(
                URLRequest(url: URL(string: "https://app.example.com")!)
            ),
            configuration: configuration
        )
    }
}
```

## UIKit Host

```swift
import ApproovServiceWebView

let controller = ApproovWebViewController(
    content: .request(URLRequest(url: URL(string: "https://app.example.com")!)),
    configuration: configuration
)
```

## Raw WKWebView Integration

Use `ApproovWebViewFactory` when your app wants the protected `WKWebView`
instance directly instead of going through the SwiftUI or UIKit host wrappers.

### Create a Web View and Load Later

```swift
import ApproovServiceWebView
import WebKit

let configuration = ApproovWebViewConfiguration(
    approovConfig: "<your-approov-config>",
    protectedEndpoints: [
        ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/v1/private"
        )
    ],
    allowedOrigins: ["https://app.example.com"]
)

let webView = try ApproovWebViewFactory.makeWebView(
    configuration: configuration
)

// Load content whenever your app is ready.
webView.load(
    URLRequest(url: URL(string: "https://app.example.com")!)
)
```

### Install on an Existing Customized WKWebView

```swift
import ApproovServiceWebView
import WebKit

let baseConfiguration = WKWebViewConfiguration()
baseConfiguration.userContentController = WKUserContentController()
baseConfiguration.websiteDataStore = .nonPersistent()
baseConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true

let webView = WKWebView(frame: .zero, configuration: baseConfiguration)
webView.scrollView.bounces = true
webView.backgroundColor = .clear

try ApproovWebViewFactory.install(
    on: webView,
    configuration: configuration
)

webView.load(
    URLRequest(url: URL(string: "https://app.example.com")!)
)
```

> [!NOTE]
> If you attach Approov to an existing `WKWebView`, do it before the first
> protected page load, or reload after installation. The bridge is injected at
> document start and cannot retrofit a page that already finished loading.

## Debug Logging

Set `debugLoggingEnabled: true` in `ApproovWebViewConfiguration` to emit
debug-level `OSLog` entries for:

- bridge installation and reuse
- request receipt and native routing
- cookie synchronization boundaries
- lazy Approov initialization
- protected request execution and response handling

The debug logs intentionally avoid request bodies, cookie values, token values,
and URL query strings.

## Operational Notes

- Use `protectedEndpoints` to keep the native interception scope explicit and reviewable.
- Use `excludedPathPrefixes` when you want to protect an entire host or broad path while allowing static assets or other public subpaths to stay on the normal WebKit stack.
- Set `interceptXMLHttpRequests` to `false` if the host web app depends on native WebKit XHR behavior and only needs Approov protection for `fetch` or forms.
- Keep secrets, API keys, and tenant-specific headers inside `mutateRequest`, not in page JavaScript.
- Use `configureApproovService` if your app needs one-time Approov setup beyond a development key.
- For reused base web views, install the bridge before the first protected navigation, or reload after installation.
- Keep `bridgeHandlerName` unique if your app already registers page-world `WKScriptMessageHandler`s on the same `WKUserContentController`.
- Default behavior is fail-closed. Set `allowRequestsWithoutApproovToken` only when your use case explicitly requires fail-open handling.

## Related Dependencies

This package resolves and uses:

- [`approov-service-urlsession`](https://github.com/approov/approov-service-urlsession)
- [`approov-ios-sdk`](https://github.com/approov/approov-ios-sdk)

## Routing boundaries and compatibility

The bridge routes matching page `fetch`, enabled XHR, and supported form
submissions. Initial `WKWebView.load` requests, links, worker traffic and
ordinary subresources use WebKit networking. They are not automatically
stamped by the bridge. Protect an endpoint on the server and choose an
Approov-aware transport for every request that needs a token. A rule for a host
does not turn its image or script loads into bridged requests.

The bridge is a native networking integration with explicit origin and endpoint
rules. It should not be assumed to provide every browser networking semantic.
Test the actual application flow, including credentials, redirects, forms and
errors, with the deployed service version. Allowed page origins and protected
API destinations serve different purposes; enumerate both independently.

Factory installation throws when the view, content controller, coordinator, or
data store is already in use. Use one coordinator and content controller per
view and an isolated website data store. Factory-created views use a fresh
nonpersistent store. Install before loading and handle installation failures.

| Request | Native bridge behavior |
| --- | --- |
| Matching page `fetch` | Uses native execution within supported request policies. |
| Matching XHR | Uses native execution when `interceptXMLHttpRequests` is enabled. |
| Supported main-frame form targeting `_self` | Uses native execution when `interceptForms` is enabled. |
| Initial `load(_:)`, including POST | Uses WebKit. |
| Links and other document navigation | Use WebKit. |
| Images, scripts, styles, and other ordinary subresources | Use WebKit. |
| Workers and service workers | Use their browser networking context. |
| Iframe form navigation or another form target | Cannot use simulated main-frame navigation. |

For example, this initial document POST uses WebKit:

```swift
var initialRequest = URLRequest(url: URL(string: "https://app.example.com/start")!)
initialRequest.httpMethod = "POST"
initialRequest.httpBody = Data("session=temporary-bootstrap-value".utf8)
webView.load(initialRequest)
```

A matching endpoint rule does not add an Approov token to that initial POST.
If the initial document needs Approov, send it through a native Approov transport before displaying the response.
Handle document rendering and its cookies explicitly in that host integration.

A hosted page can send a protected API request through the supported bridge:

```javascript
const response = await fetch('https://api.example.com/v1/private/session', {
    method: 'POST',
    credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'start' })
});
if (!response.ok) {
    showRetry();
}
```

This example requires the API endpoint rule and the trusted page origin rule.
Its backend must also permit the required CORS origin, methods, headers, and credentials.
If a worker, asset, or another navigation needs Approov, use an explicit Approov-aware transport for that request.

Protected bridge messages require a verified HTTP or HTTPS frame origin.
For local demos, serve the page through HTTP localhost or HTTPS and configure its exact origin.
Opaque frames and `file:` pages cannot supply a protected browser context.

Each bridge response is buffered within the configured body limits.
Unsupported browser policies reject protected requests instead of silently changing their meaning.
Cross-site credentialed calls, `no-cors`, manual redirects, integrity checks, and streaming are unsupported.
Native execution uses separate cache behavior from WebKit.
See the [supported browser behavior](Documentation/ProductionIntegration.md#supported-browser-behavior) before choosing request policies.
Use a new view for a new installation policy.
Changes to the SwiftUI host's content or configuration replace its WebView and cancel pending requests.

## Production integration

See the [production integration guide](Documentation/ProductionIntegration.md) for User-Agent preparation, session refresh, release keys, HTTP errors, and retries.

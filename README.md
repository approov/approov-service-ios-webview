# Approov Service for iOS WebView

Swift Package Manager library for protecting selected `WKWebView` traffic with Approov on iOS.

The package injects a JavaScript bridge into the page, intercepts protected `fetch`, `XMLHttpRequest`, and form submissions, executes those requests through `ApproovURLSession`, and returns the response to the page. Requests outside the configured allowlist stay on the normal WebKit networking stack.

> [!IMPORTANT]
> Only endpoints declared in `protectedEndpoints` are proxied through native networking and protected by Approov.

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
| `ApproovWebViewConfiguration` | Main integration surface for Approov setup, endpoint allowlisting, token header settings, fail-open policy, and native request mutation. |
| `ApproovWebViewProtectedEndpoint` | Scheme, host, and path-prefix matcher for protected traffic. |
| `ApproovWebViewContent` | Initial content source for the web view: request, HTML string, or file URL. |

`ApproovServiceWebView` re-exports the shared core types, so a single `import ApproovServiceWebView` is sufficient in app code.

## Request Model

Protected requests follow this path:

1. The package injects its bridge script at document start.
2. Matching page requests are serialized from JavaScript and passed to native code.
3. Native execution runs through `ApproovURLSession`, including your existing Approov mutator chain.
4. The response is marshalled back into the page runtime.

Unmatched requests continue through WebKit unchanged.

## Configuration

`ApproovWebViewConfiguration` is the main contract between the host app and the package.

| Property | Purpose |
| --- | --- |
| `approovConfig` | Approov onboarding string for `ApproovService.initialize(...)`. |
| `protectedEndpoints` | Strict allowlist for traffic that should be routed through native networking. |
| `approovTokenHeaderName` | Header name used for the Approov token. Default: `approov-token`. |
| `approovTokenHeaderPrefix` | Optional header prefix, for example `Bearer `. |
| `approovDevelopmentKey` | Optional development key applied after initialization. |
| `allowRequestsWithoutApproovToken` | Controls fail-open vs fail-closed behavior when Approov cannot produce a token. |
| `configureApproovService` | Hook for one-time Approov setup beyond the default initialization path. |
| `mutateRequest` | Native-only request mutation point for secrets or headers that must not be exposed to page JavaScript. |
| `bridgeHandlerName` | WebKit message handler name used by the injected bridge. |

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
        approovDevelopmentKey: "<your-development-key>",
        mutateRequest: { request in
            var request = request
            request.setValue("<api-key>", forHTTPHeaderField: "Api-Key")
            return request
        }
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

## Operational Notes

- Use `protectedEndpoints` to keep the native interception scope explicit and reviewable.
- Keep secrets, API keys, and tenant-specific headers inside `mutateRequest`, not in page JavaScript.
- Use `configureApproovService` if your app needs one-time Approov setup beyond a development key.
- Default behavior is fail-closed. Set `allowRequestsWithoutApproovToken` only when your use case explicitly requires fail-open handling.

## Related Dependencies

This package resolves and uses:

- [`approov-service-urlsession`](https://github.com/approov/approov-service-urlsession)
- [`approov-ios-sdk`](https://github.com/approov/approov-ios-sdk)

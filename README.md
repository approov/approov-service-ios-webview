# Approov Service for iOS WebView

`approov-service-ios-webview` packages the reusable `WKWebView` protection bridge from this quickstart as a Swift Package Manager library.

## Installation

Add the package to your app. Inside this repo, the sample app consumes it as a
local package:

```swift
.package(path: "../approov-service-ios-webview")
```

Then depend on the `ApproovServiceWebView` product and import it:

```swift
import ApproovServiceWebView
```

## What It Provides

- `ApproovWebView`
  - SwiftUI host for a protected `WKWebView`
- `ApproovWebViewController`
  - UIKit host for the same protected bridge
- `ApproovWebViewConfiguration`
  - Allowlist, token header, fail-open policy, one-time Approov setup, and native request mutation
- `ApproovWebViewProtectedEndpoint`
  - Host and path allowlist entries for protected traffic

## Example

```swift
import ApproovServiceWebView

let configuration = ApproovWebViewConfiguration(
    approovConfig: "<your-approov-config>",
    protectedEndpoints: [
        ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/v1"
        )
    ],
    approovDevelopmentKey: "<your-dev-key>",
    mutateRequest: { request in
        var request = request
        request.setValue("<api-key>", forHTTPHeaderField: "Api-Key")
        return request
    }
)

let webView = ApproovWebView(
    content: .request(URLRequest(url: URL(string: "https://app.example.com")!)),
    configuration: configuration
)
```

If you need additional one-time Approov setup beyond a development key, use `configureApproovService` and import `Approov` in your app target.

# Migrate to 0.6

## Handle installation errors

`ApproovWebViewFactory.makeWebView` and `install` now throw installation errors. Add `try` and connect failures to the host's retry interface.

```swift
@MainActor
func openFlow(configuration: ApproovWebViewConfiguration) {
    do {
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration)
        showPreparedFlow(view)
    } catch {
        showRetryInterface()
    }
}
```

`showPreparedFlow` and `showRetryInterface` represent application functions.
The SwiftUI and UIKit wrappers show a fallback message and call `onError` after an installation failure.

A view accepts one installation. Repeated installation throws `alreadyInstalled`.
Create a new view to change its installed policy.

## Keep ownership separate

Use one coordinator, one content controller, and one website data store per active protected WebView.
Factory-created views use separate nonpersistent stores.
A custom view must enable content JavaScript before creation.

If you create a coordinator explicitly, pass the same configuration value to the coordinator and the factory.
A copied configuration retains its installation identity.

```swift
let coordinator = ApproovWebViewFactory.makeCoordinator(configuration: configuration)
let view = try ApproovWebViewFactory.makeWebView(
    configuration: configuration,
    coordinator: coordinator
)
```

Before closing or replacing a raw view, call `ApproovWebViewFactory.invalidate(on: view)`.
Invalidation cancels pending requests and closes the bridge permanently.

## Update SwiftUI hosts

The SwiftUI host replaces its WebView after a content or configuration change.
It cancels requests from the previous installation.
The underlying representable view is now an `ApproovWebViewContainer`.

Retain a configuration value across ordinary SwiftUI updates.
Create a new configuration only for an intended policy change.
Use `onError` to connect installation failures to the host's retry interface.

## Review request policies

Allowed page origins and protected API destinations remain independent configuration lists.
Protected messages require a verified HTTP or HTTPS frame origin.
For local demos, use HTTP localhost or HTTPS with an explicit origin rule.
Opaque frames and `file:` pages cannot initiate protected bridge requests.

Simulated form navigation is restricted to the main frame.
Iframe form navigation cannot replace the top-level document through the bridge.
The form bridge can be disabled with `interceptForms: false`.

Unsupported browser policies reject protected requests.
Cross-site credentialed requests, `no-cors`, manual redirects, nonempty integrity metadata, and streaming are unsupported.
The native route does not share WebKit's HTTP cache or preflight cache.
Its default request path bypasses the local HTTP cache.

The default limits are 10 MiB per request or response, 16 concurrent requests,
and a 60-second native resource deadline. Configure these limits for the API.
Event-stream responses reject rather than holding a bridge request open.

Fetch response headers support ordinary read methods and reject mutations.
Calls through `Headers.prototype` on the response header proxy fail the native
brand check. Parsed XHR documents do not reproduce WebKit document URL metadata.
XHR progress reports the buffered transfer, not incremental network delivery.
Scripts must not replace the bridge wrappers or retain native event methods
before bridge installation. Test the actual page libraries before migration.
Review the [routing boundaries](../README.md#routing-boundaries-and-compatibility) before migrating an initial POST or a worker request.

If the host already initializes Approov, use `usesExistingApproovService: true`.
Complete host service preparation before the first protected request.
See the [production integration guide](ProductionIntegration.md) for session refresh and retries.

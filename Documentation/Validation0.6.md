# 0.6 validation and ticket coverage

The 0.6 branch implements the review tasks in [#58](https://github.com/approov/approov-service-ios-webview/issues/58).
The table records the behavior and its regression coverage for each task.
Some tasks define explicit unsupported behavior instead of full browser parity.

## Simulator results

The complete application-hosted suite passed on October 27, 2026, with Xcode 27.1 (27A9275).
The tested implementation and harness are commit `b128739`.
The suite contains 195 regression tests and two checks of the application host.
Each run used a newly created simulator.

| Simulator | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| iPhone 18 Pro, iOS 27.0 (24A434) | 197 | 0 | 0 |
| iPhone 17 Pro, iOS 26.5 (23F77) | 197 | 0 | 0 |
| iPhone 16 Pro, iOS 18.6 (22G86) | 197 | 0 | 0 |

Each run includes 99 service tests and 98 core tests.
The JavaScript runtime class contains 43 tests in real WKWebViews.
These tests compare selected XHR and form behavior with native WebKit.
Three hosted-checkout fixtures exercise the bridge, executor, redirect cookies, form response, and cancellation together.
Seven transport tests cover real loopback sockets, the production delegate, bounded responses, cancellation, resource timeout, and signing-marker behavior.
Cookie tests also use real WebKit stores, concurrent mutations, and delayed teardown.

The tests run inside a UIKit app with a scene and window.
Two environment checks establish that each test bundle uses this app host.
Framework-only runs exposed intermittent WebKit document-startup failures before bridge messages arrived.
The harness provides an application context and isolated website stores.
Document loading has a bounded deadline and reports failures before JavaScript execution.
The UI fixtures use the host scene and observe actual view deallocation before testing store reuse.

Strict Swift formatting and `git diff --check` passed.
The SwiftUI README example passed compiler type checking against the simulator SDK.
An isolated customer example compiled with the local 0.6 package and the throwing installation API.
That build used synthetic configuration values and did not run against customer servers.

## Reproduce the run

Run the suite with an installed iOS simulator:

```sh
bash Scripts/test-simulator.sh <simulator-UDID>
```

Without a UDID, the script selects an available iPhone on the newest installed compatible iOS runtime.
The harness requires Xcode 16 or later and iOS 17 or later.
The library deployment requirement remains iOS 15.
The script builds before execution and retains the logs and `tests.xcresult` under `.build/simulator-results`.
The CI workflow runs the same script and uploads these files as `simulator-test-evidence`.
Xcode performs standard ad-hoc signing for the app, test bundles, and embedded frameworks.
No development team or manual SDK signing is required.
See the [test-host instructions](../Tests/SimulatorHost/README.md) for the project structure and regeneration command.

## What the results establish

The tests use synthetic cookies, tokens, request bodies, and deterministic signing responses.
The transport tests execute the production ApproovURLSession delegate path.
A separate test checks that the signing marker avoids duplicate signing without disabling the pinning callback.
These results do not establish live Approov cloud attestation or remote TLS pin validation.
The Approov SDK and URLSession dependency versions remain unchanged.

The authenticated customer MiniCart flow still needs a fresh session cookie and a live staging replay.
The simulator fixtures cannot establish behavior for every script or redirect in that flow.
Supported limits and migration changes appear in [the migration guide](MigratingTo0.6.md).

## Ticket coverage

Test paths link to the relevant suites. Documentation tasks link to their guidance.

| Ticket | Implemented behavior | Coverage |
| --- | --- | --- |
| [#13](https://github.com/approov/approov-service-ios-webview/issues/13) | Initialize the service once, then install each request hook. | [BootstrapTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewBootstrapTests.swift) |
| [#14](https://github.com/approov/approov-service-ios-webview/issues/14) | Reject unrelated cookie domains, public suffixes, and invalid secure prefixes. | [ResponseCookiesTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewResponseCookiesTests.swift), [SitePolicyTests](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewSitePolicyTests.swift) |
| [#15](https://github.com/approov/approov-service-ios-webview/issues/15) | Allow only protected HTTPS redirects. Remove cross-origin headers and reject preserved cross-origin bodies. | [RedirectPolicyTests](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewRedirectPolicyTests.swift), [ExecutorPolicyTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewExecutorPolicyTests.swift) |
| [#16](https://github.com/approov/approov-service-ios-webview/issues/16) | Remove caller tokens before signing. Require a fresh nonempty token under the strict policy. | [TokenPolicyTests](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewTokenPolicyTests.swift), [ScopedFailOpenTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewScopedFailOpenTests.swift) |
| [#17](https://github.com/approov/approov-service-ios-webview/issues/17) | Use WebKit frame identity and origin instead of page-supplied context. | [CoordinatorTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewCoordinatorTests.swift) |
| [#18](https://github.com/approov/approov-service-ios-webview/issues/18) | Enforce CORS preflight, response permissions, and exposed headers. | [BrowserPolicyTests](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewBrowserPolicyTests.swift), [ExecutorPolicyTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewExecutorPolicyTests.swift) |
| [#19](https://github.com/approov/approov-service-ios-webview/issues/19) | Apply credentials modes to cookie transfer. Reject credentialed cross-site requests explicitly. | [ExecutorPolicyTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewExecutorPolicyTests.swift), [CookieBridgeTests](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewCookieBridgeTests.swift) |
| [#20](https://github.com/approov/approov-service-ios-webview/issues/20) | Apply referrer policy using verified context on every hop. | [BrowserPolicyTests](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewBrowserPolicyTests.swift), [ExecutorPolicyTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewExecutorPolicyTests.swift) |
| [#21](https://github.com/approov/approov-service-ios-webview/issues/21) | Cancel native work and invalidate the session during teardown. | [CoordinatorTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewCoordinatorTests.swift), [StoreLeaseTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewStoreLeaseTests.swift) |
| [#22](https://github.com/approov/approov-service-ios-webview/issues/22) | Preserve fetch URL, redirect, type, and clone metadata. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift), [HostedCheckoutIntegrationTests](../Tests/ApproovServiceWebViewTests/HostedCheckoutIntegrationTests.swift) |
| [#23](https://github.com/approov/approov-service-ios-webview/issues/23) | Construct null bodies for HEAD and statuses 204, 205, and 304. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#24](https://github.com/approov/approov-service-ios-webview/issues/24) | Forward cancellation to native tasks and ignore late replies. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift), [TaskReferenceTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewTaskReferenceTests.swift), [HostedCheckoutIntegrationTests](../Tests/ApproovServiceWebViewTests/HostedCheckoutIntegrationTests.swift) |
| [#25](https://github.com/approov/approov-service-ios-webview/issues/25) | Enforce redirect:error. Reject unsupported redirect, cache, integrity, and no-cors policies. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift), [ExecutorPolicyTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewExecutorPolicyTests.swift) |
| [#26](https://github.com/approov/approov-service-ios-webview/issues/26) | Consume Request bodies and reject reuse. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#27](https://github.com/approov/approov-service-ios-webview/issues/27) | Bound payloads, concurrency, response accumulation, and native resource duration. Reject streaming. | [PayloadBudgetTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewPayloadBudgetTests.swift), [NativeTransportTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewNativeTransportTests.swift), [BoundedResponseTests](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewBoundedResponseTests.swift) |
| [#28](https://github.com/approov/approov-service-ios-webview/issues/28) | Reject protected fetch transport failures with TypeError. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#29](https://github.com/approov/approov-service-ios-webview/issues/29) | Apply XHR timeout, cancel work, and ignore late replies. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#30](https://github.com/approov/approov-service-ios-webview/issues/30) | Use request generations so reopened XHR objects ignore old replies. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#31](https://github.com/approov/approov-service-ios-webview/issues/31) | Reject duplicate XHR send calls synchronously. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#32](https://github.com/approov/approov-service-ios-webview/issues/32) | Keep XHR send return values and argument errors synchronous. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#33](https://github.com/approov/approov-service-ios-webview/issues/33) | Validate and combine XHR headers with browser-compatible rules. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#34](https://github.com/approov/approov-service-ios-webview/issues/34) | Preserve generated body Content-Type and UTF-8 serialization. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#35](https://github.com/approov/approov-service-ios-webview/issues/35) | Apply XHR response types, getter errors, charset decoding, and MIME overrides. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#36](https://github.com/approov/approov-service-ios-webview/issues/36) | Validate XHR methods, URLs, arguments, and authentication before dispatch. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#37](https://github.com/approov/approov-service-ios-webview/issues/37) | Match native WebKit event order for buffered success, empty responses, and abort. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#38](https://github.com/approov/approov-service-ios-webview/issues/38) | Resolve relative XHR URLs and form actions against document.baseURI. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#39](https://github.com/approov/approov-service-ios-webview/issues/39) | Use consistent canonical path matching. Reject ambiguous encoded separators and dot segments. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift), [URLPolicyTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewURLPolicyTests.swift) |
| [#40](https://github.com/approov/approov-service-ios-webview/issues/40) | Honor form cancellation and final field changes, including prototype event methods. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#41](https://github.com/approov/approov-service-ios-webview/issues/41) | Replace the action query for GET form submission. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#42](https://github.com/approov/approov-service-ios-webview/issues/42) | Reject unsupported iframe navigation without changing the top-level page. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift), [CoordinatorTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewCoordinatorTests.swift) |
| [#43](https://github.com/approov/approov-service-ios-webview/issues/43) | Include submitters in document order and preserve formdata events and image coordinates. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#44](https://github.com/approov/approov-service-ios-webview/issues/44) | Apply HTML defaults for invalid form methods and encodings. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#45](https://github.com/approov/approov-service-ios-webview/issues/45) | Honor the document base target and explicit form overrides. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#46](https://github.com/approov/approov-service-ios-webview/issues/46) | Keep direct form.submit independent of stale submitter state. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift) |
| [#47](https://github.com/approov/approov-service-ios-webview/issues/47) | Reject repeated installation before changing the existing bridge. | [FactoryTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewFactoryTests.swift) |
| [#48](https://github.com/approov/approov-service-ios-webview/issues/48) | Reject shared content controllers before handler or script mutation. | [FactoryTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewFactoryTests.swift) |
| [#49](https://github.com/approov/approov-service-ios-webview/issues/49) | Bind each coordinator to one view and one installation policy. | [FactoryTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewFactoryTests.swift) |
| [#50](https://github.com/approov/approov-service-ios-webview/issues/50) | Replace SwiftUI content and policy safely. Show installation failures through the host interface. | [HostTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewHostTests.swift) |
| [#51](https://github.com/approov/approov-service-ios-webview/issues/51) | Serialize custom handler names as JSON strings. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift), [JavaScriptBridgeTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewJavaScriptBridgeTests.swift) |
| [#52](https://github.com/approov/approov-service-ios-webview/issues/52) | Use fixed bridge errors, redact diagnostic URLs, and disable debug logs by default. | [LoggerTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewLoggerTests.swift), [CoordinatorTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewCoordinatorTests.swift) |
| [#53](https://github.com/approov/approov-service-ios-webview/issues/53) | Reject concurrent store sharing. Retain ownership until pending cookie mutations drain. | [StoreLeaseTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewStoreLeaseTests.swift), [FactoryTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewFactoryTests.swift) |
| [#54](https://github.com/approov/approov-service-ios-webview/issues/54) | Expose an independent form-interception switch. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift), [ConfigurationTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewConfigurationTests.swift) |
| [#55](https://github.com/approov/approov-service-ios-webview/issues/55) | Distinguish default and explicit ports in both matchers. | [WebKit runtime](../Tests/ApproovServiceWebViewCoreTests/ApproovWebViewJavaScriptRuntimeTests.swift), [URLPolicyTests](../Tests/ApproovServiceWebViewTests/ApproovWebViewURLPolicyTests.swift) |
| [#56](https://github.com/approov/approov-service-ios-webview/issues/56) | Document initial POST, navigation, asset, and worker boundaries. | [README](../README.md), [MigratingTo0.6](../Documentation/MigratingTo0.6.md) |
| [#57](https://github.com/approov/approov-service-ios-webview/issues/57) | Document session preparation, User-Agent capture, release keys, error handling, and retries. | [ProductionIntegration](../Documentation/ProductionIntegration.md) |

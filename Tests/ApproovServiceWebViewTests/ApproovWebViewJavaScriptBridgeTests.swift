import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewJavaScriptBridgeTests: XCTestCase {
    func testScriptSourceInjectsHandlerAndEndpoints() throws {
        let protectedEndpoint = ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/v1/private",
            excludedPathPrefixes: ["/v1/private/public-assets"]
        )
        let source = ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "nativeBridge",
            protectedEndpoints: [protectedEndpoint],
            xhrBridgeEnabled: true
        )
        let expectedEndpointJSON = try XCTUnwrap(
            String(
                data: JSONEncoder().encode([protectedEndpoint]),
                encoding: .utf8
            )
        )

        XCTAssertFalse(source.contains("__APPROOV_BRIDGE_HANDLER__"))
        XCTAssertFalse(source.contains("__APPROOV_PROTECTED_ENDPOINTS__"))
        XCTAssertTrue(source.contains("nativeBridge"))
        XCTAssertTrue(source.contains(expectedEndpointJSON))
    }

    func testScriptSourceKeepsExpectedFeaturesEnabled() {
        let source = ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "nativeBridge",
            protectedEndpoints: [],
            xhrBridgeEnabled: true
        )

        XCTAssertTrue(source.contains("window.__approovBridgeEnabled = true;"))
        XCTAssertTrue(source.contains("fetch: true"))
        XCTAssertTrue(source.contains("xhr: xhrBridgeEnabled"))
        XCTAssertTrue(source.contains("forms: true"))
        XCTAssertTrue(source.contains("cookieSync: true"))
        XCTAssertTrue(source.contains("simulatedNavigations: true"))
    }

    func testScriptSourceIncludesExcludedPathMatchingLogic() {
        let source = ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "nativeBridge",
            protectedEndpoints: [],
            xhrBridgeEnabled: true
        )

        XCTAssertTrue(source.contains("entry.excludedPathPrefixes"))
        XCTAssertTrue(source.contains("matchesPathPrefix(pathname, excludedPathPrefix)"))
    }

    func testScriptSourceIncludesUnprotectedRequestDiagnosticLogging() {
        let source = ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "nativeBridge",
            protectedEndpoints: [],
            xhrBridgeEnabled: true
        )

        XCTAssertTrue(source.contains("kind: \"diagnostic\""))
        XCTAssertTrue(source.contains("event: \"unprotected-request-bypass\""))
        XCTAssertTrue(source.contains("logUnprotectedRequestBypass(\"fetch\", request.url)"))
        XCTAssertTrue(source.contains("logUnprotectedRequestBypass(\"xhr\", resolvedURL)"))
        XCTAssertTrue(source.contains("logUnprotectedRequestBypass(\"form\", actionURL)"))
    }

    func testScriptSourceKeepsNativeXMLHttpRequestSurfaceForUnprotectedTraffic() {
        let source = ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "nativeBridge",
            protectedEndpoints: [],
            xhrBridgeEnabled: true
        )

        XCTAssertTrue(source.contains("function ApproovXMLHttpRequest()"))
        XCTAssertTrue(source.contains("const xhr = new OriginalXMLHttpRequest();"))
        XCTAssertTrue(source.contains("window.XMLHttpRequest.prototype = OriginalXMLHttpRequest.prototype;"))
        XCTAssertTrue(source.contains("if (!protectedState.active) {"))
    }

    func testScriptSourceCanDisableXMLHttpRequestBridgeInstallation() {
        let source = ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "nativeBridge",
            protectedEndpoints: [],
            xhrBridgeEnabled: false
        )

        XCTAssertTrue(source.contains("const xhrBridgeEnabled = false;"))
        XCTAssertTrue(source.contains("if (xhrBridgeEnabled) {"))
        XCTAssertTrue(source.contains("xhr: xhrBridgeEnabled"))
    }
}

import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewJavaScriptBridgeTests: XCTestCase {
    func testScriptSourceInjectsHandlerAndEndpoints() throws {
        let protectedEndpoint = ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/v1/private"
        )
        let source = ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "nativeBridge",
            protectedEndpoints: [protectedEndpoint]
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
            protectedEndpoints: []
        )

        XCTAssertTrue(source.contains("window.__approovBridgeEnabled = true;"))
        XCTAssertTrue(source.contains("fetch: true"))
        XCTAssertTrue(source.contains("xhr: true"))
        XCTAssertTrue(source.contains("forms: true"))
        XCTAssertTrue(source.contains("cookieSync: true"))
        XCTAssertTrue(source.contains("simulatedNavigations: true"))
    }
}

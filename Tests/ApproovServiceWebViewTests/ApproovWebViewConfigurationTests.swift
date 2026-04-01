import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewConfigurationTests: XCTestCase {
    func testDefaultConfigurationValuesAreStable() {
        let endpoint = ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/v1"
        )
        let configuration = ApproovWebViewConfiguration(
            approovConfig: "config",
            protectedEndpoints: [endpoint]
        )

        XCTAssertEqual(configuration.bridgeHandlerName, "approovBridge")
        XCTAssertEqual(configuration.approovTokenHeaderName, "approov-token")
        XCTAssertEqual(configuration.approovTokenHeaderPrefix, "")
        XCTAssertNil(configuration.approovDevelopmentKey)
        XCTAssertFalse(configuration.allowRequestsWithoutApproovToken)
        XCTAssertFalse(configuration.protectInitialNavigation)
        XCTAssertFalse(configuration.debugLoggingEnabled)
        XCTAssertEqual(configuration.protectedEndpoints.count, 1)
        XCTAssertTrue(configuration.isProtectedEndpoint(URL(string: "https://api.example.com/v1/items")!))
    }

    func testCustomConfigurationValuesAreExposed() {
        let endpoint = ApproovWebViewProtectedEndpoint(
            scheme: "http",
            host: "localhost",
            pathPrefix: "/api"
        )
        let configuration = ApproovWebViewConfiguration(
            approovConfig: "config",
            protectedEndpoints: [endpoint],
            bridgeHandlerName: "customBridge",
            approovTokenHeaderName: "x-approov-token",
            approovTokenHeaderPrefix: "Bearer ",
            approovDevelopmentKey: "dev-key",
            allowRequestsWithoutApproovToken: true,
            protectInitialNavigation: true,
            mutateRequest: { request in request },
            debugLoggingEnabled: true,
            loggerSubsystem: "test.subsystem",
            loggerCategory: "test.category"
        )

        XCTAssertEqual(configuration.bridgeHandlerName, "customBridge")
        XCTAssertEqual(configuration.approovTokenHeaderName, "x-approov-token")
        XCTAssertEqual(configuration.approovTokenHeaderPrefix, "Bearer ")
        XCTAssertEqual(configuration.approovDevelopmentKey, "dev-key")
        XCTAssertTrue(configuration.allowRequestsWithoutApproovToken)
        XCTAssertTrue(configuration.protectInitialNavigation)
        XCTAssertTrue(configuration.debugLoggingEnabled)
        XCTAssertEqual(configuration.loggerSubsystem, "test.subsystem")
        XCTAssertEqual(configuration.loggerCategory, "test.category")
    }
}

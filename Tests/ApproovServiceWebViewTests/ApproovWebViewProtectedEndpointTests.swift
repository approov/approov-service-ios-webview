import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewProtectedEndpointTests: XCTestCase {
    func testMatchesNormalizesSchemeHostAndPathPrefix() {
        let endpoint = ApproovWebViewProtectedEndpoint(
            scheme: "HTTPS",
            host: "API.EXAMPLE.COM",
            pathPrefix: "v1/private"
        )

        XCTAssertTrue(endpoint.matches(URL(string: "https://api.example.com/v1/private")!))
        XCTAssertTrue(endpoint.matches(URL(string: "https://api.example.com/v1/private/items")!))
        XCTAssertFalse(endpoint.matches(URL(string: "https://api.example.com/v1/public")!))
        XCTAssertFalse(endpoint.matches(URL(string: "http://api.example.com/v1/private")!))
    }

    func testMatchesRootPathPrefixCoversEntireHost() {
        let endpoint = ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: ""
        )

        XCTAssertTrue(endpoint.matches(URL(string: "https://api.example.com/")!))
        XCTAssertTrue(endpoint.matches(URL(string: "https://api.example.com/anything/here")!))
    }
}

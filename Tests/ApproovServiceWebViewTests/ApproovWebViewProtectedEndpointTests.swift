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

    func testMatchesExcludedPathPrefixesWithinIncludedHostScope() {
        let endpoint = ApproovWebViewProtectedEndpoint(
            host: "store.example.com",
            pathPrefix: "/",
            excludedPathPrefixes: [
                "assets/static"
            ]
        )

        XCTAssertTrue(endpoint.matches(URL(string: "https://store.example.com/checkout")!))
        XCTAssertFalse(endpoint.matches(URL(string: "https://store.example.com/assets/static/app-config/en-GB.json")!))
        XCTAssertFalse(endpoint.matches(URL(string: "https://store.example.com/assets/static/content/global.config.post.json")!))
    }

    func testMatchesExcludedPathPrefixesOnlyForFullPathSegments() {
        let endpoint = ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/",
            excludedPathPrefixes: [
                "/static"
            ]
        )

        XCTAssertFalse(endpoint.matches(URL(string: "https://api.example.com/static/file.json")!))
        XCTAssertTrue(endpoint.matches(URL(string: "https://api.example.com/statics/file.json")!))
    }

    func testIgnoresBlankExcludedPathPrefixes() {
        let endpoint = ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/v1",
            excludedPathPrefixes: [
                "",
                "   ",
                "\n\t",
            ]
        )

        XCTAssertEqual(endpoint.excludedPathPrefixes, [])
        XCTAssertTrue(endpoint.matches(URL(string: "https://api.example.com/v1/private")!))
    }
}

import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewOriginMatcherTests: XCTestCase {
    func testEmptyRulesAllowAllForBackwardCompatibility() {
        XCTAssertTrue(ApproovWebViewOriginMatcher.matches(origin: "https://anything.test", rules: []))
    }

    func testExactOriginMatching() {
        XCTAssertTrue(
            ApproovWebViewOriginMatcher.matches(origin: "https://example.com", rules: ["https://example.com"])
        )
        XCTAssertFalse(
            ApproovWebViewOriginMatcher.matches(origin: "https://evil.com", rules: ["https://example.com"])
        )
    }

    func testSchemeMustMatch() {
        XCTAssertFalse(
            ApproovWebViewOriginMatcher.matches(origin: "http://example.com", rules: ["https://example.com"])
        )
    }

    func testWildcardSubdomainMatchesSubdomainsOnly() {
        let rules = ["https://*.example.com"]
        XCTAssertFalse(ApproovWebViewOriginMatcher.matches(origin: "https://example.com", rules: rules))
        XCTAssertTrue(ApproovWebViewOriginMatcher.matches(origin: "https://www.example.com", rules: rules))
        XCTAssertTrue(ApproovWebViewOriginMatcher.matches(origin: "https://a.b.example.com", rules: rules))
    }

    func testWildcardSubdomainRejectsLookalikeHosts() {
        let rules = ["https://*.example.com"]
        XCTAssertFalse(ApproovWebViewOriginMatcher.matches(origin: "https://notexample.com", rules: rules))
        XCTAssertFalse(
            ApproovWebViewOriginMatcher.matches(origin: "https://example.com.evil.com", rules: rules)
        )
    }

    func testStarMatchesAnyOrigin() {
        XCTAssertTrue(ApproovWebViewOriginMatcher.matches(origin: "https://anything.test", rules: ["*"]))
    }

    func testPortSemantics() {
        // A rule without a port matches the scheme default port.
        XCTAssertTrue(
            ApproovWebViewOriginMatcher.matches(origin: "https://example.com:443", rules: ["https://example.com"])
        )
        XCTAssertTrue(
            ApproovWebViewOriginMatcher.matches(origin: "http://example.com:80", rules: ["http://example.com"])
        )
        XCTAssertFalse(
            ApproovWebViewOriginMatcher.matches(origin: "https://example.com:8443", rules: ["https://example.com"])
        )
        // A rule that pins a port only matches that port.
        XCTAssertTrue(
            ApproovWebViewOriginMatcher.matches(
                origin: "https://example.com:8443",
                rules: ["https://example.com:8443"]
            )
        )
        XCTAssertFalse(
            ApproovWebViewOriginMatcher.matches(
                origin: "https://example.com:8443",
                rules: ["https://example.com:443"]
            )
        )
        XCTAssertTrue(
            ApproovWebViewOriginMatcher.matches(
                origin: "http://localhost:3000",
                rules: ["http://localhost:3000"]
            )
        )
    }

    func testMalformedPortIsRejectedWhenAllowlistConfigured() {
        XCTAssertFalse(
            ApproovWebViewOriginMatcher.matches(origin: "https://example.com:0", rules: ["https://example.com"])
        )
        XCTAssertFalse(
            ApproovWebViewOriginMatcher.matches(origin: "https://example.com", rules: ["https://example.com:70000"])
        )
    }

    func testHostComparisonIsCaseInsensitive() {
        XCTAssertTrue(
            ApproovWebViewOriginMatcher.matches(origin: "https://EXAMPLE.com", rules: ["https://example.com"])
        )
    }

    func testMalformedOriginIsRejectedWhenAllowlistConfigured() {
        XCTAssertFalse(
            ApproovWebViewOriginMatcher.matches(origin: "garbage", rules: ["https://example.com"])
        )
    }

    func testConfigurationExposesAllowlist() {
        let configuration = ApproovWebViewConfiguration(
            approovConfig: "config",
            protectedEndpoints: [ApproovWebViewProtectedEndpoint(host: "api.example.com", pathPrefix: "/v1")],
            allowedOrigins: ["https://funnel.example.com"]
        )

        XCTAssertTrue(configuration.enforcesOriginAllowlist)
        XCTAssertTrue(configuration.isAllowedOrigin("https://funnel.example.com"))
        XCTAssertFalse(configuration.isAllowedOrigin("https://evil.example.org"))
    }

    func testConfigurationWithoutAllowlistDoesNotEnforce() {
        let configuration = ApproovWebViewConfiguration(
            approovConfig: "config",
            protectedEndpoints: [ApproovWebViewProtectedEndpoint(host: "api.example.com", pathPrefix: "/v1")],
            allowedOrigins: []
        )

        XCTAssertFalse(configuration.enforcesOriginAllowlist)
        XCTAssertTrue(configuration.isAllowedOrigin("https://anything.test"))
    }
}

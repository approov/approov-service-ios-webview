import XCTest
@testable import ApproovServiceWebView
@testable import ApproovServiceWebViewCore

final class ApproovWebViewURLPolicyTests: XCTestCase {
    func testDefaultAndNonDefaultPortsAreDistinct() {
        let standard = ApproovWebViewProtectedEndpoint(host: "api.example.com", pathPrefix: "/")
        let alternate = ApproovWebViewProtectedEndpoint(host: "api.example.com", pathPrefix: "/", port: 8443)
        XCTAssertTrue(standard.matches(URL(string: "https://api.example.com:443/data")!))
        XCTAssertFalse(standard.matches(URL(string: "https://api.example.com:8443/data")!))
        XCTAssertTrue(alternate.matches(URL(string: "https://api.example.com:8443/data")!))
        XCTAssertFalse(alternate.matches(URL(string: "https://api.example.com/data")!))
    }

    func testEncodedUnreservedExclusionMatchesBrowserPolicy() {
        let endpoint = ApproovWebViewProtectedEndpoint(host: "shop.example.com", pathPrefix: "/",
            excludedPathPrefixes: ["/lh/statics", "/cdn-cgi"])
        for path in ["/lh/statics/a", "/lh/%73tatics/a", "/cdn%2dcgi/a"] {
            XCTAssertFalse(endpoint.matches(URL(string: "https://shop.example.com" + path)!))
        }
        XCTAssertTrue(endpoint.matches(URL(string: "https://shop.example.com/api/%7euser")!))
    }

    func testAmbiguousPathsAreRejectedNatively() {
        let endpoint = ApproovWebViewProtectedEndpoint(host: "api.example.com", pathPrefix: "/private/")
        for path in ["/private%2fdata", "/private/%5cdata", "/private/%2e%2e/public", "/private/../public"] {
            XCTAssertFalse(endpoint.matches(URL(string: "https://api.example.com" + path)!))
        }
        XCTAssertTrue(endpoint.matches(URL(string: "https://api.example.com/private/data")!))
    }

    func testURLAssociatedErrorsDoNotDiscloseSensitiveParameters() {
        let raw = "https://user:password@example.com/path?session=synthetic#fragment"
        for error in [ApproovWebViewBridgeError.invalidURL(raw), .unsupportedScheme(raw), .requestNotProtected(raw)] {
            for secret in ["password", "synthetic", "fragment", "session="] {
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }
    }
}

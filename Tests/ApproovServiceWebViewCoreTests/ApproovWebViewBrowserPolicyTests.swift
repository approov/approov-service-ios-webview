import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewBrowserPolicyTests: XCTestCase {
    private let page = URL(string: "https://shop.example.com/private?session=synthetic#fragment")!

    func testCrossOriginReferrerIsReducedToVerifiedOrigin() throws {
        XCTAssertEqual(try ApproovWebViewBrowserPolicy.referrer(pageURL: page,
            sourceOrigin: "https://shop.example.com", destination: URL(string: "https://api.example.com/")!,
            requestedReferrer: "about:client", policy: ""), "https://shop.example.com/")
    }

    func testReferrerNeverIncludesFragmentsOrCredentials() throws {
        let value = try ApproovWebViewBrowserPolicy.referrer(pageURL: URL(string: "https://u:p@shop.example.com/a?q=ok#secret")!,
            sourceOrigin: "https://shop.example.com", destination: URL(string: "https://shop.example.com/api")!,
            requestedReferrer: nil, policy: nil)
        XCTAssertEqual(value, "https://shop.example.com/a?q=ok")
        XCTAssertThrowsError(try ApproovWebViewBrowserPolicy.referrer(pageURL: page,
            sourceOrigin: "https://shop.example.com", destination: page,
            requestedReferrer: "https://other.example.com/", policy: nil))
    }

    func testCredentialsAreNotAddedToOmitOrCrossOriginSameOriginRequests() {
        XCTAssertFalse(ApproovWebViewBrowserPolicy.sendsCredentials("omit", url: page, sourceOrigin: "https://shop.example.com"))
        XCTAssertFalse(ApproovWebViewBrowserPolicy.sendsCredentials("same-origin", url: page, sourceOrigin: "https://api.example.com"))
        XCTAssertTrue(ApproovWebViewBrowserPolicy.sendsCredentials("include", url: page, sourceOrigin: "https://api.example.com"))
    }

    func testCredentialedCORSRejectsWildcardAndMissingCredentialsPermission() {
        XCTAssertThrowsError(try ApproovWebViewBrowserPolicy.checkCORS(headers: ["Access-Control-Allow-Origin": "*"],
            sourceOrigin: "https://shop.example.com", credentials: "include"))
        XCTAssertThrowsError(try ApproovWebViewBrowserPolicy.checkCORS(headers: ["Access-Control-Allow-Origin": "https://shop.example.com"],
            sourceOrigin: "https://shop.example.com", credentials: "include"))
        XCTAssertNoThrow(try ApproovWebViewBrowserPolicy.checkCORS(headers: ["Access-Control-Allow-Origin": "https://shop.example.com", "Access-Control-Allow-Credentials": "true"],
            sourceOrigin: "https://shop.example.com", credentials: "include"))
    }

    func testPreflightChecksMethodAndAuthorizationExplicitly() {
        let headers = ["Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "PUT", "Access-Control-Allow-Headers": "*"]
        XCTAssertThrowsError(try ApproovWebViewBrowserPolicy.checkPreflight(status: 204, headers: headers,
            sourceOrigin: "https://shop.example.com", credentials: "omit", method: "PUT", requestHeaders: ["Authorization": "synthetic"]))
        XCTAssertNoThrow(try ApproovWebViewBrowserPolicy.checkPreflight(status: 204, headers: headers,
            sourceOrigin: "https://shop.example.com", credentials: "omit", method: "PUT", requestHeaders: ["X-Test": "synthetic"]))
    }

    func testResponseHeaderExposureDoesNotExposePrivateHeaders() {
        let headers = ["Content-Type":"application/json", "X-Private":"synthetic", "Set-Cookie":"synthetic=1", "Access-Control-Expose-Headers":"X-Public", "X-Public":"ok"]
        let visible = ApproovWebViewBrowserPolicy.exposedHeaders(headers, crossOrigin: true, credentials: "include")
        XCTAssertEqual(visible, ["Content-Type":"application/json", "X-Public":"ok"])
    }

    func testBrowserManagedHeadersAndUnsupportedPoliciesAreRejected() {
        XCTAssertThrowsError(try ApproovWebViewBrowserPolicy.validatePageHeaders(["Origin":"https://forged.invalid"], tokenHeader: "Approov-Token"))
        XCTAssertThrowsError(try ApproovWebViewBrowserPolicy.validatePageHeaders(["X-Test":"a\r\nb"], tokenHeader: "Approov-Token"))
        XCTAssertThrowsError(try ApproovWebViewBrowserPolicy.validateOptions(mode: "no-cors", credentials: "omit", redirect: "follow", cache: "default", integrity: ""))
    }
}

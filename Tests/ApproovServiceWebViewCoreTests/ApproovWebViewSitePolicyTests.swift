import XCTest

@testable import ApproovServiceWebViewCore

final class ApproovWebViewSitePolicyTests: XCTestCase {
    func testPublicSuffixWildcardAndExceptionRules() {
        let rules = ApproovWebViewSitePolicy.PublicSuffixRules(text: "com\nco.uk\ngithub.io\n*.ck\n!www.ck\n")
        XCTAssertEqual(rules.registrableDomain("api.example.co.uk"), "example.co.uk")
        XCTAssertNil(rules.registrableDomain("co.uk"))
        XCTAssertEqual(rules.registrableDomain("alice.github.io"), "alice.github.io")
        XCTAssertEqual(rules.registrableDomain("a.www.ck"), "www.ck")
        XCTAssertEqual(rules.registrableDomain("a.b.ck"), "a.b.ck")
        XCTAssertNil(rules.registrableDomain("b.ck"))
    }

    func testBundledRulesAllowSameSiteAPIHosts() {
        XCTAssertTrue(
            ApproovWebViewSitePolicy.isSameSite(
                frameURL: URL(string: "https://shop.example.com/")!,
                mainDocumentURL: URL(string: "https://www.example.com/")!,
                requestURL: URL(string: "https://api.example.com/")!))
    }

    func testPrivateSuffixTenantsAndMixedSchemesAreDifferentSites() {
        XCTAssertFalse(
            ApproovWebViewSitePolicy.sameSite(
                URL(string: "https://alice.github.io/")!, URL(string: "https://bob.github.io/")!))
        XCTAssertFalse(
            ApproovWebViewSitePolicy.sameSite(
                URL(string: "http://api.example.com/")!, URL(string: "https://shop.example.com/")!))
        XCTAssertFalse(
            ApproovWebViewSitePolicy.isSameSite(
                frameURL: URL(string: "https://shop.example.com/")!,
                mainDocumentURL: URL(string: "https://other.co.uk/")!,
                requestURL: URL(string: "https://api.example.com/")!))
    }
}

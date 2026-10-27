import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewResponseCookiesTests: XCTestCase {
    private let url = URL(string: "https://api.example.com/path/a")!

    func testParsesSingleCookieIncludingHttpOnly() {
        let cookies = ApproovWebViewResponseCookies.cookies(
            fromResponseHeaders: ["Set-Cookie": "session=abc123; Path=/; HttpOnly"],
            url: url
        )

        XCTAssertEqual(cookies.count, 1)
        let cookie = cookies[0]
        XCTAssertEqual(cookie.name, "session")
        XCTAssertEqual(cookie.value, "abc123")
        XCTAssertTrue(cookie.isHTTPOnly)
    }

    func testParsesMultipleCookiesFoldedIntoOneHeader() {
        // HTTPURLResponse folds multiple Set-Cookie headers into a single
        // comma-separated value; both cookies must still be recovered.
        let cookies = ApproovWebViewResponseCookies.cookies(
            fromResponseHeaders: ["Set-Cookie": "session=abc123; Path=/; HttpOnly, csrf=tok456; Path=/"],
            url: url
        )

        let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["session"], "abc123")
        XCTAssertEqual(byName["csrf"], "tok456")
    }

    func testRejectsUnrelatedAndPublicSuffixDomains() {
        for domain in ["evil.test", "com"] {
            let cookies = ApproovWebViewResponseCookies.cookies(
                fromResponseHeaders: ["Set-Cookie": "bad=1; Domain=\(domain); Path=/"], url: url)
            XCTAssertTrue(cookies.isEmpty, domain)
        }
    }

    func testAcceptsParentDomainAndValidHostPrefix() {
        for header in ["parent=1; Domain=example.com; Path=/", "__Host-id=1; Secure; Path=/"] {
            XCTAssertEqual(ApproovWebViewResponseCookies.cookies(fromResponseHeaders: ["Set-Cookie": header], url: url).count, 1, header)
        }
    }

    func testRejectsInvalidHostPrefix() {
        for header in ["__Host-id=1; Secure", "__Host-id=1; Secure; Domain=api.example.com; Path=/"] {
            XCTAssertTrue(ApproovWebViewResponseCookies.cookies(fromResponseHeaders: ["Set-Cookie": header], url: url).isEmpty, header)
        }
    }

    func testRejectsInsecureSecurePrefix() {
        let cookies = ApproovWebViewResponseCookies.cookies(
            fromResponseHeaders: ["Set-Cookie": "__Secure-id=1; Path=/"], url: url)
        XCTAssertTrue(cookies.isEmpty)
    }

    func testReturnsEmptyWhenNoSetCookieHeaderPresent() {
        let cookies = ApproovWebViewResponseCookies.cookies(
            fromResponseHeaders: ["Content-Type": "application/json"],
            url: url
        )

        XCTAssertTrue(cookies.isEmpty)
    }
    func testHostPrefixRejectsDomainAttributeWithWhitespaceOrEmptyValue() {
        for attribute in ["Domain = example.com", "DOMAIN\t=api.example.com", "Domain=", "domain"] {
            let header = "__Host-id=1; Secure; Path=/; \(attribute)"
            XCTAssertTrue(ApproovWebViewResponseCookies.cookies(fromResponseHeaders:["Set-Cookie":header],url:url).isEmpty, header)
        }
    }
    func testMixedCasePrefixesEnforceSecurity() {
        for header in ["__secure-id=1; Path=/", "__hOsT-id=1; Secure; Path=/; Domain=example.com"] {
            XCTAssertTrue(ApproovWebViewResponseCookies.cookies(fromResponseHeaders:["Set-Cookie":header],url:url).isEmpty, header)
        }
    }
    func testHostPrefixDuplicateNamesPreserveOrderAndDeletion() {
        let header="__Host-id=1; Secure; Path=/, __Host-id=2; Secure; Path=/, __Host-id=; Secure; Path=/; Max-Age=0"
        let cookies=ApproovWebViewResponseCookies.cookies(fromResponseHeaders:["sEt-CoOkIe":header],url:url)
        XCTAssertEqual(cookies.map(\.value),["1","2",""])
        XCTAssertLessThanOrEqual(cookies.last?.expiresDate ?? .distantFuture,Date())
    }
    func testCookieHeaderArrayRetainsOrder() {
        let cookies=ApproovWebViewResponseCookies.cookies(fromResponseHeaders:["Set-Cookie":["session=1; Path=/","session=2; Path=/"]],url:url)
        XCTAssertEqual(cookies.map(\.value),["1","2"])
    }
    func testFoldedExpiresAndHostPrefix() {
        let header="regular=1; Expires=Wed, 09 Jun 2038 10:18:14 GMT; Path=/, __Host-id=1; Secure; Path=/"
        let cookies=ApproovWebViewResponseCookies.cookies(fromResponseHeaders:["Set-Cookie":header],url:url)
        XCTAssertTrue(cookies.contains { $0.name == "__Host-id" })
    }
    func testExpiredDeletionIsPreservedForJar() {
        let cookies=ApproovWebViewResponseCookies.cookies(fromResponseHeaders:["Set-Cookie":"gone=; Max-Age=0; Path=/"],url:url)
        XCTAssertEqual(cookies.count,1)
        XCTAssertLessThanOrEqual(cookies[0].expiresDate ?? .distantFuture,Date())
    }
    func testRejectsICANNAndPrivatePublicSuffixDomains() {
        for (source,domain) in [("https://shop.example.co.uk/","co.uk"),("https://alice.github.io/","github.io")] {
            let cookies=ApproovWebViewResponseCookies.cookies(fromResponseHeaders:["Set-Cookie":"bad=1; Domain=\(domain); Path=/"],url:URL(string:source)!)
            XCTAssertTrue(cookies.isEmpty,domain)
        }
    }

}

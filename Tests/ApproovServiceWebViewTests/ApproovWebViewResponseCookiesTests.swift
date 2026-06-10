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

    func testReturnsEmptyWhenNoSetCookieHeaderPresent() {
        let cookies = ApproovWebViewResponseCookies.cookies(
            fromResponseHeaders: ["Content-Type": "application/json"],
            url: url
        )

        XCTAssertTrue(cookies.isEmpty)
    }
}

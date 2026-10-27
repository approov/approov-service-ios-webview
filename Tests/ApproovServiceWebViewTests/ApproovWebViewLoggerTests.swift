import XCTest

@testable import ApproovServiceWebView

final class ApproovWebViewLoggerTests: XCTestCase {
    func testBrowserOnlyURLsDoNotPutEmbeddedDataIntoLogs() {
        for raw in [
            "data:application/json,synthetic-secret", "file:///private/synthetic-secret", "javascript:synthetic-secret",
        ] {
            XCTAssertEqual(ApproovWebViewLogger.redactedURLForLog(raw), "<non-http-url>")
        }
    }

    func testHTTPDiagnosticsRemoveCredentialsQueryAndFragment() {
        XCTAssertEqual(
            ApproovWebViewLogger.redactedURLForLog(
                "https://user:password@example.com/api?session=synthetic#fragment"), "https://example.com/api")
    }
}

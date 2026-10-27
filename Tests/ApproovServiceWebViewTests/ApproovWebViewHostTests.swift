import XCTest
import WebKit
@testable import ApproovServiceWebView

final class ApproovWebViewHostTests: XCTestCase {
    @MainActor
    func testContentAndConfigurationChangesReplaceView() {
        let container = ApproovWebViewContainer()
        let config = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [])
        let firstContent = ApproovWebViewContent.htmlString("one", baseURL: nil)
        container.update(content: firstContent, configuration: config) { _ in XCTFail("unexpected error") }
        let first = container.webView
        container.update(content: firstContent, configuration: config) { _ in XCTFail("unexpected error") }
        XCTAssertTrue(first === container.webView)
        container.update(content: .htmlString("two", baseURL: nil), configuration: config) { _ in XCTFail("unexpected error") }
        XCTAssertFalse(first === container.webView)
        let second = container.webView
        let changed = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [])
        container.update(content: .htmlString("two", baseURL: nil), configuration: changed) { _ in XCTFail("unexpected error") }
        XCTAssertFalse(second === container.webView)
    }
}

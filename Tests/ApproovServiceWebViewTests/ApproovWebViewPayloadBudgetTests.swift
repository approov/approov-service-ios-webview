import Foundation
import XCTest

@testable import ApproovServiceWebView

@MainActor final class ApproovWebViewPayloadBudgetTests: XCTestCase {
    func testPayloadShapeAndBudgetsBeforeJSONEncoding() {
        XCTAssertTrue(
            ApproovWebViewCoordinator.isBoundedPayload(
                [
                    "url": "https://api.example.com/", "method": "POST", "headers": ["X-Test": "ok"],
                    "bodyBase64": "MTIzNA==", "requestSource": "fetch", "responseHandling": "response",
                ], maximumBodyBytes: 4))
        XCTAssertFalse(
            ApproovWebViewCoordinator.isBoundedPayload(["unknown": [["nested": "value"]]], maximumBodyBytes: 4))
        XCTAssertFalse(ApproovWebViewCoordinator.isBoundedPayload(["bodyBase64": "MTIzNDU2Nw=="], maximumBodyBytes: 4))
        XCTAssertFalse(
            ApproovWebViewCoordinator.isBoundedPayload(
                ["headers": ["X-Test": String(repeating: "a", count: 65537)]], maximumBodyBytes: 4))
        XCTAssertFalse(ApproovWebViewCoordinator.isBoundedPayload(["url": ["nested"]], maximumBodyBytes: 4))
        XCTAssertFalse(ApproovWebViewCoordinator.isBoundedPayload(["bodyBase64": ""], maximumBodyBytes: Int.max))
    }
}

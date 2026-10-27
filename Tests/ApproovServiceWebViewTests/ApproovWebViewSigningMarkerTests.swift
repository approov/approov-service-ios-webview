import Foundation
import XCTest

@testable import ApproovServiceWebView

final class ApproovWebViewSigningMarkerTests: XCTestCase {
    func testMarkerIsRemovedBeforeResigning() {
        var request = URLRequest(url: URL(string: "https://api.example.com/")!)
        ApproovWebViewServiceMutator.markAlreadySigned(&request)
        XCTAssertEqual(URLProtocol.property(forKey: "ApproovWebViewBridge.AlreadySigned", in: request) as? Bool, true)
        ApproovWebViewServiceMutator.clearAlreadySigned(&request)
        XCTAssertNil(URLProtocol.property(forKey: "ApproovWebViewBridge.AlreadySigned", in: request))
    }
}

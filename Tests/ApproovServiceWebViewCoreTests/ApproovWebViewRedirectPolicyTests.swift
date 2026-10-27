import Foundation
import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewRedirectPolicyTests: XCTestCase {
    let endpoints = [ApproovWebViewProtectedEndpoint(host: "one.example", pathPrefix: "/"),
                     ApproovWebViewProtectedEndpoint(host: "two.example", pathPrefix: "/")]
    func testCrossOriginRemovesSensitiveHeaders() throws {
        var request = URLRequest(url: URL(string: "https://two.example/path")!)
        request.setValue("token", forHTTPHeaderField: "Approov-Token")
        request.setValue("key", forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try ApproovWebViewRedirectPolicy.prepare(&request, from: URL(string: "https://one.example/")!, endpoints: endpoints)
        XCTAssertNil(request.value(forHTTPHeaderField: "Approov-Token"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }
    func testRejectsOutOfScopeAndDowngrade() {
        for url in ["https://other.example/", "http://one.example/"] {
            var request = URLRequest(url: URL(string: url)!)
            XCTAssertThrowsError(try ApproovWebViewRedirectPolicy.prepare(&request, from: URL(string: "https://one.example/")!, endpoints: endpoints))
        }
    }
}

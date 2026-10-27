import Foundation
import XCTest

@testable import ApproovServiceWebViewCore

final class ApproovWebViewRedirectPolicyTests: XCTestCase {
    let endpoints = [
        ApproovWebViewProtectedEndpoint(host: "one.example", pathPrefix: "/"),
        ApproovWebViewProtectedEndpoint(host: "two.example", pathPrefix: "/"),
    ]
    func testCrossOriginRemovesSensitiveHeaders() throws {
        var request = URLRequest(url: URL(string: "https://two.example/path")!)
        request.setValue("token", forHTTPHeaderField: "Approov-Token")
        request.setValue("key", forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try ApproovWebViewRedirectPolicy.prepare(
            &request, from: URL(string: "https://one.example/")!, endpoints: endpoints)
        XCTAssertNil(request.value(forHTTPHeaderField: "Approov-Token"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept"))
    }
    func testRejectsOutOfScopeAndDowngrade() {
        for url in ["https://other.example/", "http://one.example/"] {
            var request = URLRequest(url: URL(string: url)!)
            XCTAssertThrowsError(
                try ApproovWebViewRedirectPolicy.prepare(
                    &request, from: URL(string: "https://one.example/")!, endpoints: endpoints))
        }
    }
    func testCrossOriginRejectsPreservedBody() {
        var request = URLRequest(url: URL(string: "https://two.example/path")!)
        request.httpMethod = "POST"
        request.httpBody = Data("sensitive".utf8)
        XCTAssertThrowsError(
            try ApproovWebViewRedirectPolicy.prepare(
                &request, from: URL(string: "https://one.example/")!, endpoints: endpoints))
    }
    func testSameOriginKeepsBodyAndHeaders() throws {
        var request = URLRequest(url: URL(string: "https://one.example/next")!)
        request.httpBody = Data("body".utf8)
        request.setValue("value", forHTTPHeaderField: "X-Test")
        try ApproovWebViewRedirectPolicy.prepare(
            &request, from: URL(string: "https://one.example/")!, endpoints: endpoints)
        XCTAssertEqual(request.httpBody, Data("body".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "value")
    }

}

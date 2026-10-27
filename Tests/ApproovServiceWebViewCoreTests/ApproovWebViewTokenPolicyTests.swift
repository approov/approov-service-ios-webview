import Foundation
import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewTokenPolicyTests: XCTestCase {
    func testStrictPolicyRejectsCallerTokenWhenSignerReturnsNoToken() {
        var request = URLRequest(url: URL(string: "https://api.example.com/")!)
        request.setValue("caller", forHTTPHeaderField: "Approov-Token")
        XCTAssertThrowsError(try ApproovWebViewTokenPolicy.sign(request, header: "Approov-Token", prefix: "", allowMissing: false) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Approov-Token"))
            return request
        })
    }
    func testAcceptsSignerTokenAndExplicitMissingPolicy() throws {
        let request = URLRequest(url: URL(string: "https://api.example.com/")!)
        let signed = try ApproovWebViewTokenPolicy.sign(request, header: "Approov-Token", prefix: "Bearer ", allowMissing: false) { request in
            var request = request
            request.setValue("Bearer issued", forHTTPHeaderField: "Approov-Token")
            return request
        }
        XCTAssertEqual(signed.value(forHTTPHeaderField: "Approov-Token"), "Bearer issued")
        XCTAssertNoThrow(try ApproovWebViewTokenPolicy.sign(request, header: "Approov-Token", prefix: "", allowMissing: true) { $0 })
        XCTAssertThrowsError(try ApproovWebViewTokenPolicy.sign(request, header: "Approov-Token", prefix: "Bearer ", allowMissing: false) { request in
            var request = request
            request.setValue("Bearer ", forHTTPHeaderField: "Approov-Token")
            return request
        })
    }
}

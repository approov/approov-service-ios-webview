import Foundation
import XCTest

@testable import ApproovServiceWebView

final class ApproovWebViewTaskReferenceTests: XCTestCase {
    func testCancellationBeforeTaskRegistrationCancelsTask() {
        let reference = ApproovWebViewTaskReference()
        reference.cancel()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1/")!)
        reference.register(task)
        XCTAssertEqual(reference.taskIdentifier, task.taskIdentifier)
        XCTAssertNotEqual(task.state, .suspended)
    }
    func testCancellationAfterTaskRegistrationCancelsTask() {
        let reference = ApproovWebViewTaskReference()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1/")!)
        reference.register(task)
        reference.cancel()
        XCTAssertNotEqual(task.state, .suspended)
    }
}

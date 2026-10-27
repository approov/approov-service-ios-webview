import Foundation
import XCTest

@testable import ApproovServiceWebViewCore

final class ApproovWebViewBoundedResponseTests: XCTestCase {
    func testResponseAtLimitIsDelivered() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1/")!)
        let delegate = ApproovWebViewRedirectDelegate()
        let completed = expectation(description: "complete")
        delegate.register(taskID: task.taskIdentifier, maximumBytes: 3) { result in
            guard case .success((let data, _, _)) = result else {
                XCTFail("Expected success")
                completed.fulfill()
                return
            }
            XCTAssertEqual(data, Data("abc".utf8))
            completed.fulfill()
        }
        delegate.urlSession(
            session, dataTask: task,
            didReceive: HTTPURLResponse(
                url: task.originalRequest!.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        ) { _ in }
        delegate.urlSession(session, dataTask: task, didReceive: Data("abc".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        wait(for: [completed], timeout: 1)
    }
    func testOversizedResponseFailsWithoutAppendingChunk() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1/")!)
        let delegate = ApproovWebViewRedirectDelegate()
        let completed = expectation(description: "complete")
        delegate.register(taskID: task.taskIdentifier, maximumBytes: 2) { result in
            guard case .failure(let error) = result else {
                XCTFail("Expected failure")
                completed.fulfill()
                return
            }
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
            completed.fulfill()
        }
        delegate.urlSession(session, dataTask: task, didReceive: Data("abc".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        wait(for: [completed], timeout: 1)
    }
}

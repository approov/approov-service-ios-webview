import Foundation
import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewRedirectDelegateTests: XCTestCase {
    func testStopsAutomaticFollowAndRetainsProposedRequest() throws {
        let delegate = ApproovWebViewRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = try XCTUnwrap(
            URL(string: "https://api.example.com/start")
        )
        let destinationURL = try XCTUnwrap(
            URL(string: "https://login.example.net/complete")
        )
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destinationURL.absoluteString]
            )
        )
        var proposedRequest = URLRequest(url: destinationURL)
        proposedRequest.httpMethod = "GET"
        var automaticFollow: URLRequest? = proposedRequest

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposedRequest
        ) {
            automaticFollow = $0
        }

        XCTAssertNil(automaticFollow)
        let retainedRequest = try XCTUnwrap(
            delegate.takeProposedRequest(
                for: task.taskIdentifier
            )
        )
        XCTAssertEqual(retainedRequest.url, destinationURL)
        XCTAssertEqual(retainedRequest.httpMethod, "GET")
        XCTAssertNil(
            delegate.takeProposedRequest(
                for: task.taskIdentifier
            )
        )
    }

    func testKeepsConcurrentTaskRedirectsSeparate() throws {
        let delegate = ApproovWebViewRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let firstURL = try XCTUnwrap(
            URL(string: "https://api.example.com/first")
        )
        let secondURL = try XCTUnwrap(
            URL(string: "https://api.example.com/second")
        )
        let firstTask = session.dataTask(with: firstURL)
        let secondTask = session.dataTask(with: secondURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: firstURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )

        delegate.urlSession(
            session,
            task: firstTask,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: firstURL)
        ) { _ in }
        delegate.urlSession(
            session,
            task: secondTask,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: secondURL)
        ) { _ in }

        XCTAssertEqual(
            delegate.takeProposedRequest(
                for: secondTask.taskIdentifier
            )?.url,
            secondURL
        )
        XCTAssertEqual(
            delegate.takeProposedRequest(
                for: firstTask.taskIdentifier
            )?.url,
            firstURL
        )
    }

    func testCompletionHandlerCanSynchronouslyConsumeProposedRequest() throws {
        let delegate = ApproovWebViewRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = try XCTUnwrap(
            URL(string: "https://api.example.com/start")
        )
        let destinationURL = try XCTUnwrap(
            URL(string: "https://api.example.com/complete")
        )
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destinationURL.absoluteString]
            )
        )
        var retainedRequest: URLRequest?

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destinationURL)
        ) { automaticFollow in
            XCTAssertNil(automaticFollow)
            retainedRequest = delegate.takeProposedRequest(
                for: task.taskIdentifier
            )
        }

        XCTAssertEqual(retainedRequest?.url, destinationURL)
    }
}

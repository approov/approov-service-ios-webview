import XCTest
import WebKit
@testable import ApproovServiceWebView

@MainActor
final class ApproovWebViewCoordinatorTests: XCTestCase {
    func testContextUsesVerifiedFrameURLAndCanonicalOrigin() throws {
        let url = try XCTUnwrap(URL(string: "https://app.example.com/actual?context=verified"))
        let context = try XCTUnwrap(ApproovWebViewCoordinator.requestContext(
            frameURL: url, frameOrigin: "https://APP.example.com:443",
            mainDocumentURL: url, isMainFrame: true
        ))
        XCTAssertEqual(context.frameURL, url)
        XCTAssertEqual(context.frameOrigin, "https://app.example.com")
        XCTAssertTrue(context.isMainFrame)
    }

    func testInheritedOrMismatchedFrameURLFallsBackToVerifiedOrigin() throws {
        for candidate in ["about:blank", "about:srcdoc", "https://spoof.example.com/path"] {
            let context = try XCTUnwrap(ApproovWebViewCoordinator.requestContext(
                frameURL: URL(string: candidate), frameOrigin: "https://app.example.com",
                mainDocumentURL: nil, isMainFrame: false
            ))
            XCTAssertEqual(context.frameURL.absoluteString, "https://app.example.com")
            XCTAssertFalse(context.isMainFrame)
        }
        XCTAssertNil(ApproovWebViewCoordinator.requestContext(
            frameURL: URL(string: "file:///private/fixture.html"), frameOrigin: "file://",
            mainDocumentURL: nil, isMainFrame: true
        ))
    }

    func testRealMessageUsesWKFrameInsteadOfPayloadContext() async throws {
        let received = expectation(description: "verified main frame context")
        let configuration = makeConfiguration()
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { request, context in
            XCTAssertEqual(request.sourcePageURL, "https://spoof.example.com/forged")
            XCTAssertEqual(context.frameOrigin, "https://app.example.com")
            XCTAssertEqual(context.frameURL.host, "app.example.com")
            XCTAssertTrue(context.isMainFrame)
            received.fulfill()
            return Self.response()
        }
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        view.loadHTMLString("<script>" + Self.postMessageScript + "</script>", baseURL: URL(string: "https://app.example.com/real"))
        await fulfillment(of: [received], timeout: 5)
        withExtendedLifetime(view) {}
    }

    func testRealInheritedIframeUsesVerifiedOrigin() async throws {
        let received = expectation(description: "verified iframe context")
        let configuration = makeConfiguration()
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { _, context in
            XCTAssertEqual(context.frameOrigin, "https://app.example.com")
            XCTAssertEqual(context.frameURL.host, "app.example.com")
            XCTAssertFalse(context.isMainFrame)
            received.fulfill()
            return Self.response()
        }
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        let document = "<iframe srcdoc=\"<script>" + Self.postMessageScript.replacingOccurrences(of: "\"", with: "&quot;") + "</script>\"></iframe>"
        view.loadHTMLString(document, baseURL: URL(string: "https://app.example.com/main"))
        await fulfillment(of: [received], timeout: 5)
        withExtendedLifetime(view) {}
    }

    private func makeConfiguration() -> ApproovWebViewConfiguration {
        ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: ["https://app.example.com"])
    }

    private static func response() -> ApproovWebViewExecutionResult {
        .response(ApproovWebViewProxyResponse(url: "https://api.example.com/v1", status: 200,
            statusText: "OK", headers: [:], bodyBase64: ""))
    }

    private static let postMessageScript = """
    window.webkit.messageHandlers.approovBridge.postMessage({
        url: 'https://api.example.com/v1', method: 'GET', headers: {},
        sourcePageURL: 'https://spoof.example.com/forged',
        responseHandling: 'response', requestSource: 'fetch'
    }).catch(function () {});
    """
}

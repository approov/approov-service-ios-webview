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

    func testIframeNavigationIsRejectedWithoutChangingTopLevelPageOrHistory() async throws {
        let reported = expectation(description: "iframe navigation rejection")
        let configuration = makeConfiguration()
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { _, _ in
            XCTFail("An iframe navigation must not execute natively")
            return Self.response()
        }
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        let resultHandler = FixtureMessageHandler { message in
            guard let result = message.body as? [String: Any] else { return XCTFail("Missing fixture result") }
            XCTAssertTrue((result["error"] as? String)?.contains("main frame") == true)
            XCTAssertEqual(result["sameURL"] as? Bool, true)
            XCTAssertEqual(result["sameHistory"] as? Bool, true)
            reported.fulfill()
        }
        view.configuration.userContentController.add(resultHandler, name: "fixtureResult")
        let script = """
        var beforeURL = top.location.href, beforeHistory = top.history.length;
        window.webkit.messageHandlers.approovBridge.postMessage({
            url: 'https://api.example.com/v1', method: 'POST', headers: {},
            responseHandling: 'navigation', requestSource: 'form'
        }).then(function () { throw new Error('Unexpected navigation'); }).catch(function (error) {
            window.webkit.messageHandlers.fixtureResult.postMessage({error: String(error),
                sameURL: top.location.href === beforeURL, sameHistory: top.history.length === beforeHistory});
        });
        """
        let document = "<iframe srcdoc=\"<script>" + script.replacingOccurrences(of: "\"", with: "&quot;") + "</script>\"></iframe>"
        view.loadHTMLString(document, baseURL: URL(string: "https://app.example.com/main"))
        await fulfillment(of: [reported], timeout: 5)
        XCTAssertEqual(view.url?.host, "app.example.com")
        withExtendedLifetime(view) {}
    }

    func testMainFrameNavigationRendersNativeResponse() async throws {
        let navigated = expectation(description: "simulated main frame navigation")
        let configuration = makeConfiguration()
        let destination = URL(string: "https://app.example.com/complete")!
        let response = HTTPURLResponse(url: destination, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        let html = "<script>window.webkit.messageHandlers.fixtureResult.postMessage(location.href)</script>"
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { _, context in
            XCTAssertTrue(context.isMainFrame)
            return .navigation(ApproovWebViewNavigationLoad(request: URLRequest(url: destination),
                response: response, data: Data(html.utf8)))
        }
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        let resultHandler = FixtureMessageHandler { message in
            XCTAssertEqual(message.body as? String, destination.absoluteString)
            navigated.fulfill()
        }
        view.configuration.userContentController.add(resultHandler, name: "fixtureResult")
        let script = Self.postMessageScript.replacingOccurrences(of: "responseHandling: 'response'", with: "responseHandling: 'navigation'")
        view.loadHTMLString("<script>" + script + "</script>", baseURL: URL(string: "https://app.example.com/main"))
        await fulfillment(of: [navigated], timeout: 5)
        XCTAssertEqual(view.url, destination)
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

@MainActor
private final class FixtureMessageHandler: NSObject, WKScriptMessageHandler {
    private let receive: (WKScriptMessage) -> Void
    init(receive: @escaping (WKScriptMessage) -> Void) { self.receive = receive }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(message)
    }
}

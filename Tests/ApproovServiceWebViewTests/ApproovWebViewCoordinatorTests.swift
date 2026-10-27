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

    func testCancellationUsesVerifiedOriginAndCancelsNativeTask() async throws {
        let started = expectation(description: "native task started")
        let cancelled = expectation(description: "native task cancelled")
        let rejected = expectation(description: "page promise rejected once")
        let configuration = makeConfiguration()
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { _, _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { cancelled.fulfill(); throw error }
            return Self.response()
        }
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        let resultHandler = FixtureMessageHandler { message in
            XCTAssertTrue((message.body as? String)?.contains("cancelled") == true)
            rejected.fulfill()
        }
        view.configuration.userContentController.add(resultHandler, name: "fixtureResult")
        let script = Self.pendingRequestScript
        view.loadHTMLString("<script>" + script + "</script>", baseURL: URL(string: "https://app.example.com/main"))
        await fulfillment(of: [started], timeout: 5)
        XCTAssertFalse(coordinator.cancelRequest(withID: "pending-A", from: "https://other.example.com"))
        XCTAssertEqual(coordinator.activeRequestCount, 1)
        let result = try await view.callAsyncJavaScript("return await window.webkit.messageHandlers.approovBridge.postMessage({kind:'cancel', requestId:'pending-A'})", contentWorld: .page)
        XCTAssertEqual((result as? [String: Any])?["cancelled"] as? Bool, true)
        await fulfillment(of: [cancelled, rejected], timeout: 5)
        XCTAssertEqual(coordinator.activeRequestCount, 0)
        withExtendedLifetime(view) {}
    }

    func testInvalidationCancelsOutstandingRequestsAndClosesBridge() async throws {
        let started = expectation(description: "native task started")
        let cancelled = expectation(description: "native task cancelled on close")
        let configuration = makeConfiguration()
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { _, _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { cancelled.fulfill(); throw error }
            return Self.response()
        }
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        view.loadHTMLString("<script>" + Self.postMessageScript.replacingOccurrences(of: "method: 'GET'", with: "requestId: 'pending-A', method: 'GET'") + "</script>", baseURL: URL(string: "https://app.example.com/main"))
        await fulfillment(of: [started], timeout: 5)
        ApproovWebViewFactory.invalidate(on: view)
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(coordinator.activeRequestCount, 0)
        do {
            _ = try await view.callAsyncJavaScript("return await window.webkit.messageHandlers.approovBridge.postMessage({kind:'cancel', requestId:'pending-A'})", contentWorld: .page)
            XCTFail("Closed bridge must reject new messages")
        } catch {}
        withExtendedLifetime(view) {}
    }

    func testConcurrencyLimitRejectsAdditionalMessageBeforeExecution() async throws {
        let started = expectation(description: "one native task started")
        let limited = expectation(description: "second message limited")
        let configuration = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [],
            allowedOrigins: ["https://app.example.com"], maximumConcurrentRequests: 1)
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { _, _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return Self.response()
        }
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        let resultHandler = FixtureMessageHandler { message in
            XCTAssertTrue((message.body as? String)?.contains("request limit") == true)
            limited.fulfill()
        }
        view.configuration.userContentController.add(resultHandler, name: "fixtureResult")
        let script = Self.postMessageScript + Self.pendingRequestScript
        view.loadHTMLString("<script>" + script + "</script>", baseURL: URL(string: "https://app.example.com/main"))
        await fulfillment(of: [started, limited], timeout: 5)
        XCTAssertEqual(coordinator.activeRequestCount, 1)
        ApproovWebViewFactory.invalidate(on: view)
    }

    private static let pendingRequestScript = """
    window.webkit.messageHandlers.approovBridge.postMessage({
        url: 'https://api.example.com/v1', method: 'GET', headers: {}, requestId: 'pending-A',
        responseHandling: 'response', requestSource: 'fetch'
    }).catch(function (error) { window.webkit.messageHandlers.fixtureResult.postMessage(String(error)); });
    """

    func testFailureMessagesDoNotExposeSensitiveURLDetails() {
        let sensitive = "https://sensitive-user:sensitive-password@api.example.com/private?token=sensitive-query#sensitive-fragment"
        let errors: [Error] = [
            ApproovWebViewBridgeError.invalidURL(sensitive),
            ApproovWebViewBridgeError.unsupportedScheme(sensitive),
            ApproovWebViewBridgeError.requestNotProtected(sensitive),
            NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: sensitive])
        ]
        for error in errors {
            let message = ApproovWebViewCoordinator.safeErrorMessage(error)
            XCTAssertFalse(message.contains("sensitive"))
            XCTAssertFalse(message.contains("api.example.com"))
            XCTAssertFalse(message.contains("private"))
        }
        XCTAssertTrue(ApproovWebViewCoordinator.safeErrorMessage(URLError(.cancelled)).contains("cancelled"))
    }

    func testPageReceivesFixedMessageForArbitraryNativeFailure() async throws {
        let reported = expectation(description: "safe page failure")
        let configuration = makeConfiguration()
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { _, _ in
            throw NSError(domain: "Fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "https://sensitive-user:sensitive-password@api.example.com?token=sensitive-query#sensitive-fragment"])
        }
        let view = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        let resultHandler = FixtureMessageHandler { message in
            let text = message.body as? String ?? ""
            XCTAssertTrue(text.contains("The protected request failed."))
            XCTAssertFalse(text.contains("sensitive"))
            reported.fulfill()
        }
        view.configuration.userContentController.add(resultHandler, name: "fixtureResult")
        view.loadHTMLString("<script>" + Self.pendingRequestScript + "</script>", baseURL: URL(string: "https://app.example.com/main"))
        await fulfillment(of: [reported], timeout: 5)
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

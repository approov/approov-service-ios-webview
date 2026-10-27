import XCTest
import WebKit
@testable import ApproovServiceWebViewCore

@MainActor
final class ApproovWebViewJavaScriptRuntimeTests: XCTestCase {
    private final class Reply: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            let payload = message.body as? [String: Any] ?? [:]
            let url = payload["url"] as? String ?? ""
            let status = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "status" })?.value.flatMap(Int.init) ?? 200
            replyHandler(["url": "https://api.example.com/final", "redirected": true,
                          "status": status, "statusText": "OK", "headers": [:],
                          "bodyBase64": "e30="], nil)
        }
    }

    func testPunctuationHandlerNamesInstallBridge() async throws {
        for name in ["approov-test", "approov.test"] {
            let controller = WKUserContentController()
            let reply = Reply()
            controller.addScriptMessageHandler(reply, contentWorld: .page, name: name)
            let script = ApproovWebViewJavaScriptBridge.scriptSource(
                handlerName: name,
                protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")],
                xhrBridgeEnabled: true)
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = controller
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.loadHTMLString("<html></html>", baseURL: URL(string: "https://shop.example.com/"))
            try await Task.sleep(nanoseconds: 300_000_000)
            let result = try await view.callAsyncJavaScript("const r = await fetch('https://api.example.com/test'); return r.status;", arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(result as? Int, 200, "handler: \(name)")
        }
    }
    func testNullResponseBodies() async throws {
        let controller = WKUserContentController()
        let reply = Reply()
        controller.addScriptMessageHandler(reply, contentWorld: .page, name: "bridge")
        let script = ApproovWebViewJavaScriptBridge.scriptSource(handlerName: "bridge", protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")], xhrBridgeEnabled: true)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<html></html>", baseURL: URL(string: "https://shop.example.com/"))
        try await Task.sleep(nanoseconds: 300_000_000)
        let result = try await view.callAsyncJavaScript("""
            for (const status of [204, 205, 304]) {
                const response = await fetch(`https://api.example.com/?status=${status}`);
                if (response.status !== status || response.body !== null) return false;
            }
            const head = await fetch('https://api.example.com/', { method: 'HEAD' });
            return head.body === null;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testFetchResponseMetadataAndClone() async throws {
        let controller = WKUserContentController()
        let reply = Reply()
        controller.addScriptMessageHandler(reply, contentWorld: .page, name: "bridge")
        controller.addUserScript(WKUserScript(source: ApproovWebViewJavaScriptBridge.scriptSource(handlerName: "bridge", protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")], xhrBridgeEnabled: true), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<html></html>", baseURL: URL(string: "https://shop.example.com/"))
        try await Task.sleep(nanoseconds: 300_000_000)
        let result = try await view.callAsyncJavaScript("""
            const response = await fetch('https://api.example.com/test');
            const copy = response.clone();
            let immutable = false;
            try { response.headers.set('x-test', 'value'); } catch (e) { immutable = e instanceof TypeError; }
            return response.url === 'https://api.example.com/final' && response.redirected &&
                copy.url === response.url && copy.redirected && immutable &&
                await response.text() === '{}' && await copy.text() === '{}';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testFetchConsumesRequestBody() async throws {
        let controller = WKUserContentController()
        let reply = Reply()
        controller.addScriptMessageHandler(reply, contentWorld: .page, name: "bridge")
        controller.addUserScript(WKUserScript(source: ApproovWebViewJavaScriptBridge.scriptSource(handlerName: "bridge", protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")], xhrBridgeEnabled: true), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<html></html>", baseURL: URL(string: "https://shop.example.com/"))
        try await Task.sleep(nanoseconds: 300_000_000)
        let result = try await view.callAsyncJavaScript("""
            const request = new Request('https://api.example.com/', {method:'POST', body:'body'});
            await fetch(request);
            return request.bodyUsed;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testUnsupportedFetchOptionsReject() async throws {
        let controller = WKUserContentController()
        let reply = Reply()
        controller.addScriptMessageHandler(reply, contentWorld: .page, name: "bridge")
        controller.addUserScript(WKUserScript(source: ApproovWebViewJavaScriptBridge.scriptSource(handlerName: "bridge", protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")], xhrBridgeEnabled: true), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<html></html>", baseURL: URL(string: "https://shop.example.com/"))
        try await Task.sleep(nanoseconds: 300_000_000)
        let result = try await view.callAsyncJavaScript("""
            for (const options of [{mode:'no-cors'}, {redirect:'manual'}, {integrity:'sha256-AAAA'}]) {
                try { await fetch('https://api.example.com/', options); return false; }
                catch (error) { if (!(error instanceof TypeError)) return false; }
            }
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

}

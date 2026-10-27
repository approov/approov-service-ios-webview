import XCTest
import WebKit
@testable import ApproovServiceWebViewCore

@MainActor
final class ApproovWebViewJavaScriptRuntimeTests: XCTestCase {
    private final class Reply: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            replyHandler(["url": "https://api.example.com/final", "redirected": true,
                          "status": 200, "statusText": "OK", "headers": [:],
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
}

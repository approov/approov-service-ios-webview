import XCTest
import WebKit
@testable import ApproovServiceWebViewCore

@MainActor
final class ApproovWebViewJavaScriptRuntimeTests: XCTestCase {
    private final class Navigation: NSObject, WKNavigationDelegate {
        let completed: XCTestExpectation
        init(_ completed: XCTestExpectation) { self.completed = completed }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completed.fulfill() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completed.fulfill() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completed.fulfill() }
    }

    private func load(_ view: WKWebView, html: String = "<html></html>") async {
        let completed = expectation(description: "WKWebView document loaded")
        let navigation = Navigation(completed)
        view.navigationDelegate = navigation
        view.loadHTMLString(html, baseURL: URL(string: "https://shop.example.com/"))
        await fulfillment(of: [completed], timeout: 5)
        view.navigationDelegate = nil
    }

    private func fixture(maxRequestBodyBytes: Int = 10 * 1024 * 1024) async -> WKWebView {
        let controller = WKUserContentController()
        controller.addScriptMessageHandler(Reply(), contentWorld: .page, name: "bridge")
        controller.addUserScript(WKUserScript(source: ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "bridge", protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")],
            xhrBridgeEnabled: true, maxRequestBodyBytes: maxRequestBodyBytes), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        await load(view)
        return view
    }

    private final class Reply: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            let payload = message.body as? [String: Any] ?? [:]
            if (payload["url"] as? String)?.contains("failure") == true {
                replyHandler(nil, "fixture failure")
                return
            }
            let url = payload["url"] as? String ?? ""
            let status = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "status" })?.value.flatMap(Int.init) ?? 200
            let delay = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "delay" })?.value.flatMap(Double.init) ?? 0
            let responseBody = url.contains("/invalid-json") ? Data("invalid json".utf8).base64EncodedString() : url.contains("/echo")
                ? (try? JSONSerialization.data(withJSONObject: payload))?.base64EncodedString() ?? "e30=" : "e30="
            let respond = {
            replyHandler(["url": "https://api.example.com/final", "redirected": true,
                          "status": status, "statusText": "OK", "headers": ["content-type": "application/json"],
                          "bodyBase64": responseBody], nil)
            }
            if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000, execute: respond) }
            else { respond() }
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
            await load(view)
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
        await load(view)
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
        await load(view)
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
        await load(view)
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
        await load(view)
        let result = try await view.callAsyncJavaScript("""
            for (const options of [{mode:'no-cors'}, {redirect:'manual'}, {integrity:'sha256-AAAA'}]) {
                try { await fetch('https://api.example.com/', options); return false; }
                catch (error) { if (!(error instanceof TypeError)) return false; }
            }
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testAlreadyAbortedFetchRejects() async throws {
        let controller = WKUserContentController()
        let reply = Reply()
        controller.addScriptMessageHandler(reply, contentWorld: .page, name: "bridge")
        controller.addUserScript(WKUserScript(source: ApproovWebViewJavaScriptBridge.scriptSource(handlerName: "bridge", protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")], xhrBridgeEnabled: true), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        await load(view)
        let result = try await view.callAsyncJavaScript("""
            const controller = new AbortController(); controller.abort();
            try { await fetch('https://api.example.com/', {signal:controller.signal}); return false; }
            catch (error) { return error.name === 'AbortError'; }
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testFetchTransportFailureIsTypeError() async throws {
        let controller = WKUserContentController()
        let reply = Reply()
        controller.addScriptMessageHandler(reply, contentWorld: .page, name: "bridge")
        controller.addUserScript(WKUserScript(source: ApproovWebViewJavaScriptBridge.scriptSource(handlerName: "bridge", protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")], xhrBridgeEnabled: true), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        await load(view)
        let result = try await view.callAsyncJavaScript("""
            try { await fetch('https://api.example.com/failure'); return false; }
            catch (error) { return error instanceof TypeError; }
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testRequestBodyLimitRejectsBeforeNativeDispatch() async throws {
        let view = await fixture(maxRequestBodyBytes: 4)
        let result = try await view.callAsyncJavaScript("""
            const exact = await fetch('https://api.example.com/', {method:'POST', body:'1234'});
            try { await fetch('https://api.example.com/', {method:'POST', body:'12345'}); return false; }
            catch (error) { return exact.status === 200 && error instanceof TypeError; }
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRSendReturnsUndefined() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); xhr.open('GET', 'https://api.example.com/');
            const done = new Promise(resolve => xhr.onloadend = resolve);
            const result = xhr.send(); await done; return result === undefined;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRDuplicateSendThrowsSynchronously() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); xhr.open('GET', 'https://api.example.com/');
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send();
            let rejected = false;
            try { xhr.send(); } catch (error) { rejected = error.name === 'InvalidStateError'; }
            await done; return rejected;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRReopenIgnoresOldReply() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); let loads = 0; xhr.onload = () => loads++;
            xhr.open('GET', 'https://api.example.com/?status=201&delay=80'); xhr.send();
            await new Promise(resolve => setTimeout(resolve, 10));
            xhr.open('GET', 'https://api.example.com/?status=202');
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(); await done;
            await new Promise(resolve => setTimeout(resolve, 100));
            return xhr.status === 202 && loads === 1;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRTimeoutIgnoresLateReply() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); const events = [];
            for (const type of ['timeout','load','error','loadend']) xhr.addEventListener(type, () => events.push(type));
            xhr.open('GET', 'https://api.example.com/?delay=80'); xhr.timeout = 10;
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(); await done;
            await new Promise(resolve => setTimeout(resolve, 100));
            return xhr.status === 0 && xhr.readyState === 4 && events.join(',') === 'timeout,loadend';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRValidatesOpenArguments() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            for (const method of ['bad method', 'TRACE', 'CONNECT', 'TRACK']) {
                const xhr = new XMLHttpRequest();
                try { xhr.open(method, 'https://api.example.com/'); return false; }
                catch (error) { if (!['SyntaxError','SecurityError'].includes(error.name)) return false; }
            }
            try { new XMLHttpRequest().open('GET','https://api.example.com/',true,'user','pass'); return false; }
            catch (error) { return error.name === 'NotSupportedError'; }
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRHeadersCombineAndValidate() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); xhr.open('POST', 'https://api.example.com/echo');
            xhr.setRequestHeader('X-Test', ' one '); xhr.setRequestHeader('x-test', 'two');
            xhr.setRequestHeader('Cookie', 'secret'); let syntax = false;
            try { xhr.setRequestHeader('bad name','value'); } catch(e) { syntax = e.name === 'SyntaxError'; }
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(); await done;
            const headers = JSON.parse(xhr.responseText).headers;
            return syntax && headers['x-test'] === 'one, two' && !headers.cookie;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRBodyTypesRetainGeneratedContentType() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const form = new FormData(); form.append('field','value');
            for (const body of [form, new URLSearchParams({field:'value'}), new Blob(['abc'],{type:'application/test'})]) {
                const xhr = new XMLHttpRequest(); xhr.open('POST','https://api.example.com/echo');
                const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(body); await done;
                const payload = JSON.parse(xhr.responseText);
                const type = payload.headers['content-type'];
                if (!type || (body instanceof FormData && !type.includes('boundary='))) return false;
            }
            const xhr = new XMLHttpRequest(); xhr.open('GET','https://api.example.com/echo');
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send('ignored'); await done;
            return JSON.parse(xhr.responseText).bodyBase64 === null;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRResponseConversionAndGetterErrors() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); xhr.open('GET','https://api.example.com/invalid-json');
            xhr.responseType = 'json'; let failed = false; xhr.onerror = () => failed = true;
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(); await done;
            let getterError = false;
            try { void xhr.responseText; } catch(e) { getterError = e.name === 'InvalidStateError'; }
            const blob = new XMLHttpRequest(); blob.open('GET','https://api.example.com/'); blob.responseType = 'blob';
            const blobDone = new Promise(resolve => blob.onloadend = resolve); blob.send(); await blobDone;
            return !failed && xhr.status === 200 && xhr.response === null && getterError && blob.response.type === 'application/json';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRProgressLifecycleAndAbortStates() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); const events = []; let progress = false; let upload = false;
            for (const type of ['loadstart','progress','load','loadend']) xhr.addEventListener(type, event => {
                events.push(type); if (type === 'progress') progress = event instanceof ProgressEvent && event.loaded === 2;
            });
            xhr.upload.onload = event => upload = event instanceof ProgressEvent && event.loaded === 3;
            xhr.open('POST','https://api.example.com/');
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send('abc'); await done;
            const aborted = new XMLHttpRequest(); aborted.open('GET','https://api.example.com/?delay=80');
            let abortState = 0; aborted.onabort = () => abortState = aborted.readyState;
            aborted.send(); aborted.abort();
            return progress && upload && events.join(',') === 'loadstart,progress,load,loadend' && abortState === 4 && aborted.readyState === 0;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRUsesDocumentBaseURI() async throws {
        let view = await fixture()
        await load(view, html: "<html><head><base href='https://api.example.com/relative/'></head></html>")
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); xhr.open('GET','echo');
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(); await done;
            return JSON.parse(xhr.responseText).url === 'https://api.example.com/relative/echo';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

}

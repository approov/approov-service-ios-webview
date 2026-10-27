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

    private func fixture(maxRequestBodyBytes: Int = 10 * 1024 * 1024, formBridgeEnabled: Bool = true, preScript: String = "") async -> WKWebView {
        let controller = WKUserContentController()
        controller.addScriptMessageHandler(Reply(), contentWorld: .page, name: "bridge")
        if !preScript.isEmpty {
            controller.addUserScript(WKUserScript(source: preScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        controller.addUserScript(WKUserScript(source: ApproovWebViewJavaScriptBridge.scriptSource(
            handlerName: "bridge", protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")],
            xhrBridgeEnabled: true, maxRequestBodyBytes: maxRequestBodyBytes, formBridgeEnabled: formBridgeEnabled), injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
            let body = url.contains("/xml") ? Data("<root>value</root>".utf8).base64EncodedString()
                : url.contains("/latin1") ? Data([0x63, 0x61, 0x66, 0xe9]).base64EncodedString() : responseBody
            let contentType = url.contains("/xml") ? "application/xml" : url.contains("/latin1") ? "text/plain;charset=windows-1252" : "application/json"
            let respond = {
            replyHandler(["url": "https://api.example.com/final", "redirected": true,
                          "status": status, "statusText": "OK", "headers": ["content-type": contentType],
                          "bodyBase64": body], nil)
            }
            if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { respond() } }
            else { respond() }
        }
    }

    func testPunctuationHandlerNamesInstallBridge() async throws {
        for name in ["approov-test", "approov.test", "__APPROOV_PROTECTED_ENDPOINTS__", "__APPROOV_FORM_BRIDGE_ENABLED__"] {
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
            try { await fetch(request); return false; }
            catch(error) { return request.bodyUsed && error instanceof TypeError; }
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
            for (const options of [{mode:'no-cors'}, {redirect:'manual'}, {integrity:'sha256-AAAA'}, {cache:'reload'}, {cache:'no-cache'}, {cache:'force-cache'}]) {
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

    func testDefaultPortRuleDoesNotCaptureOtherPorts() async throws {
        let view = await fixture(preScript: "window.fetch = async () => new Response('browser');")
        let result = try await view.callAsyncJavaScript("""
            const native = await fetch('https://api.example.com:443/');
            const browser = await fetch('https://api.example.com:8443/');
            return await native.text() === '{}' && await browser.text() === 'browser';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testAmbiguousProtectedPathsRejectWithoutBrowserFallback() async throws {
        let view = await fixture(preScript: "window.fetch = async () => new Response('browser');")
        let result = try await view.callAsyncJavaScript("""
            for (const path of ['/private%2fpublic','/private%5cpublic','/private/%2e%2e/public','/invalid%zz']) {
                try { await fetch('https://api.example.com' + path); return false; }
                catch (error) { if (!(error instanceof TypeError)) return false; }
            }
            return (await fetch('https://api.example.com/%65cho')).status === 200;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testSubmitListenersCanCancelAndMutateProtectedForms() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const cancelled = document.createElement('form'); cancelled.action = 'https://api.example.com/echo';
            cancelled.dataset.approovSubmitMode = 'response'; document.body.append(cancelled);
            let responses = 0; cancelled.addEventListener('approov:form-response', () => responses++);
            cancelled.addEventListener('submit', event => event.preventDefault()); cancelled.requestSubmit();
            await new Promise(resolve => setTimeout(resolve, 20)); if (responses) return false;
            const form = document.createElement('form'); form.action = 'https://api.example.com/echo';
            form.dataset.approovSubmitMode = 'response'; form.method = 'post';
            const field = document.createElement('input'); field.name = 'field'; field.value = 'before'; form.append(field); document.body.append(form);
            form.addEventListener('submit', () => { field.value = 'after'; form.action += '?mutated'; });
            const done = new Promise(resolve => form.addEventListener('approov:form-response', event => resolve(JSON.parse(event.detail.bodyText)), {once:true}));
            form.requestSubmit(); const payload = await done;
            return payload.url.endsWith('?mutated') && atob(payload.bodyBase64) === 'field=after';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testGETFormReplacesActionQuery() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            document.body.innerHTML = '<form action="https://api.example.com/echo?old=1"><input name="field" value="value"></form>';
            const form = document.querySelector('form'); form.dataset.approovSubmitMode = 'response';
            const done = new Promise(resolve => form.addEventListener('approov:form-response', event => resolve(JSON.parse(event.detail.bodyText)), {once:true}));
            form.requestSubmit(); return (await done).url === 'https://api.example.com/echo?field=value';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testIframeNavigationFormFailsClearly() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const frame = document.createElement('iframe'); frame.srcdoc = '<form action="https://api.example.com/echo"></form>';
            const loaded = new Promise(resolve => frame.onload = resolve); document.body.append(frame); await loaded;
            const form = frame.contentDocument.querySelector('form');
            const done = new Promise(resolve => form.addEventListener('approov:form-error', event => resolve(event.detail.message), {once:true}));
            form.requestSubmit(); return (await done).includes('iframe');
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testFormSubmitterOrderDisabledControlsAndImageCoordinates() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            async function submit(markup, selector) {
                document.body.innerHTML = '<form method="post" action="https://api.example.com/echo">' + markup + '</form>';
                const form = document.querySelector('form'); form.dataset.approovSubmitMode = 'response';
                const done = new Promise(resolve => form.addEventListener('approov:form-response', event => resolve(JSON.parse(event.detail.bodyText)), {once:true}));
                form.requestSubmit(form.querySelector(selector)); return atob((await done).bodyBase64);
            }
            const ordered = await submit('<input name="first" value="1"><button name="button" value="2">Go</button><input name="last" value="3">','button');
            const disabled = await submit('<button disabled name="button" value="2">Go</button><input name="field" value="value">','button');
            const image = await submit('<input type="image" name="image">','input');
            return ordered === 'first=1&button=2&last=3' && disabled === 'field=value' && image === 'image.x=0&image.y=0';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testInvalidFormMethodsUseGET() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            for (const method of ['HEAD', 'PUT', 'invalid']) {
                document.body.innerHTML = '<form action="https://api.example.com/echo" method="' + method + '"><input name="field" value="value"></form>';
                const form = document.querySelector('form'); form.dataset.approovSubmitMode = 'response';
                const done = new Promise(resolve => form.addEventListener('approov:form-response', event => resolve(JSON.parse(event.detail.bodyText)), {once:true}));
                form.requestSubmit(); const payload = await done;
                if (payload.method !== 'GET' || payload.bodyBase64 !== null) return false;
            }
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testFormHonorsBaseTargetAndExplicitSelfOverride() async throws {
        let view = await fixture()
        await load(view, html: "<html><head><base target='_blank'></head><body></body></html>")
        let result = try await view.callAsyncJavaScript("""
            document.body.innerHTML = '<form action="https://api.example.com/echo"></form>';
            const form = document.querySelector('form'); form.dataset.approovSubmitMode = 'response';
            const failed = new Promise(resolve => form.addEventListener('approov:form-error', event => resolve(event.detail.message), {once:true}));
            form.requestSubmit(); if (!(await failed).includes('targets')) return false;
            form.target = '_self';
            const done = new Promise(resolve => form.addEventListener('approov:form-response', event => resolve(event.detail.status), {once:true}));
            form.requestSubmit(); return await done === 200;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testProgrammaticSubmitIgnoresCancelledClickSubmitter() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            document.body.innerHTML = '<form method="post" action="https://api.example.com/echo"><input name="field" value="value"><button name="stale" value="button" formaction="https://api.example.com/wrong">Go</button></form>';
            const form = document.querySelector('form'); form.dataset.approovSubmitMode = 'response';
            const button = form.querySelector('button'); button.addEventListener('click', event => event.preventDefault());
            const done = new Promise(resolve => form.addEventListener('approov:form-response', event => resolve(JSON.parse(event.detail.bodyText)), {once:true}));
            button.click(); form.submit(); const payload = await done;
            return payload.url === 'https://api.example.com/echo' && atob(payload.bodyBase64) === 'field=value';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testFormSwitchLeavesNativeMethodsIntact() async throws {
        let view = await fixture(formBridgeEnabled: false, preScript: "window.savedSubmit = HTMLFormElement.prototype.submit; window.savedRequestSubmit = HTMLFormElement.prototype.requestSubmit;")
        let result = try await view.callAsyncJavaScript("""
            return !window.__approovBridgeFeatures.forms && window.__approovBridgeFeatures.fetch &&
                HTMLFormElement.prototype.submit === window.savedSubmit &&
                HTMLFormElement.prototype.requestSubmit === window.savedRequestSubmit &&
                (await fetch('https://api.example.com/')).status === 200;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testFetchHeadersRejectPrototypeAndCallbackMutation() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const response = await fetch('https://api.example.com/'); let prototypeRejected = false; let callbackRejected = false;
            try { Headers.prototype.set.call(response.headers,'x-test','value'); }
            catch(error) { prototypeRejected = error instanceof TypeError; }
            response.headers.forEach((value, key, headers) => {
                try { headers.set('x-test','value'); } catch(error) { callbackRejected = error instanceof TypeError; }
            });
            const internal = Object.getOwnPropertyDescriptor(Response.prototype,'headers').get.call(response);
            internal.set('x-test','value');
            return prototypeRejected && callbackRejected && !response.headers.has('x-test') && !response.clone().headers.has('x-test');
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testInlineAndPropagationCancellationPreventsNativeSubmission() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            for (const mode of ['inline','window-inline','stopped-inline','capture','bubble']) {
                document.body.innerHTML = '<form action="https://api.example.com/echo"></form>';
                const form = document.querySelector('form'); form.dataset.approovSubmitMode = 'response';
                let responses = 0; form.addEventListener('approov:form-response', () => responses++);
                if (mode === 'inline' || mode === 'stopped-inline') form.onsubmit = () => false;
                if (mode === 'window-inline') window.onsubmit = () => false;
                if (mode === 'stopped-inline') form.addEventListener('submit', event => event.stopPropagation(), true);
                if (mode === 'capture') form.addEventListener('submit', event => event.preventDefault(), true);
                if (mode === 'bubble') form.addEventListener('submit', event => event.preventDefault());
                form.requestSubmit(); await new Promise(resolve => setTimeout(resolve, 20));
                window.onsubmit = null; if (responses) return false;
            }
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testClosedShadowFormsFailClearly() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const host = document.createElement('div'); document.body.append(host);
            const root = host.attachShadow({mode:'closed'}); root.innerHTML = '<form action="https://api.example.com/echo"></form>';
            const form = root.querySelector('form'); form.dataset.approovSubmitMode = 'response';
            const failed = new Promise(resolve => form.addEventListener('approov:form-error', event => resolve(event.detail.message), {once:true}));
            form.requestSubmit(); return (await failed).includes('closed shadow');
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRPropagatesCredentialModeAndRejectsLateChanges() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); xhr.open('GET','https://api.example.com/echo'); xhr.withCredentials = true;
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(); let rejected = false;
            try { xhr.withCredentials = false; } catch(error) { rejected = error.name === 'InvalidStateError'; }
            await done; const payload = JSON.parse(xhr.responseText);
            return rejected && payload.credentials === 'include' && payload.mode === 'cors';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testNativeToProtectedXHRReopenTerminatesOldTransport() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            const xhr = new XMLHttpRequest(); let loads = 0; xhr.onload = () => loads++;
            xhr.open('GET','data:text/plain,old'); xhr.send();
            xhr.open('GET','https://api.example.com/');
            const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(); await done;
            await new Promise(resolve => setTimeout(resolve, 20));
            return xhr.responseText === '{}' && loads === 1;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testXHRCharsetXMLArrayBufferAndMIMEOverride() async throws {
        let view = await fixture()
        let result = try await view.callAsyncJavaScript("""
            async function request(path, type = '', mime = null) {
                const xhr = new XMLHttpRequest(); xhr.open('GET','https://api.example.com/' + path); xhr.responseType = type;
                if (mime) xhr.overrideMimeType(mime);
                const done = new Promise(resolve => xhr.onloadend = resolve); xhr.send(); await done; return xhr;
            }
            const text = await request('latin1');
            const xml = await request('xml', 'document');
            const binary = await request('', 'arraybuffer');
            const blob = await request('', 'blob', 'text/plain;charset=UTF-8');
            let getterError = false;
            try { void binary.responseText; } catch(error) { getterError = error.name === 'InvalidStateError'; }
            return text.responseText === 'café' && xml.response.documentElement.tagName === 'root' &&
                xml.responseXML === xml.response && binary.response.byteLength === 2 && getterError &&
                blob.response.type === 'text/plain;charset=utf-8';
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testProtectedXHRLifecycleMatchesNativeWebKit() async throws {
        let view = await fixture(preScript: "window.NativeXHR = window.XMLHttpRequest;")
        let result = try await view.callAsyncJavaScript("""
            async function lifecycle(Constructor, url, abort) {
                const xhr = new Constructor(); const events = []; let valid = true;
                for (const type of ['loadstart','progress','load','abort','error','loadend']) xhr.addEventListener(type, event => {
                    events.push(type); valid &&= event instanceof ProgressEvent;
                    if (type === 'abort') valid &&= xhr.readyState === 4 && xhr.status === 0;
                });
                xhr.open('GET', url); const done = new Promise(resolve => xhr.onloadend = resolve);
                xhr.send(); if (abort) xhr.abort(); await done;
                return {events:events.join(','), valid, state:xhr.readyState};
            }
            const native = await lifecycle(window.NativeXHR, 'data:application/json,%7B%7D', false);
            const protectedResult = await lifecycle(XMLHttpRequest, 'https://api.example.com/', false);
            const nativeAbort = await lifecycle(window.NativeXHR, 'data:application/json,%7B%7D', true);
            const protectedAbort = await lifecycle(XMLHttpRequest, 'https://api.example.com/?delay=80', true);
            return native.valid && protectedResult.valid && native.events === protectedResult.events &&
                nativeAbort.valid && protectedAbort.valid && nativeAbort.events === protectedAbort.events &&
                nativeAbort.state === protectedAbort.state;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

}

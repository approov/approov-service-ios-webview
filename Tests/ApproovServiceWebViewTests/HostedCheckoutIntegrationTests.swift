import Foundation
import WebKit
import XCTest

@testable import ApproovServiceWebView
@testable import ApproovServiceWebViewCore

/// Exercises the shipped script, WebKit frame metadata, coordinator, executor,
/// browser policy, and cookie jar together. Only SDK signing and HTTP use fixtures.
@MainActor
final class HostedCheckoutIntegrationTests: XCTestCase {
    func testCartRedirectAndCheckoutPOSTPreserveSessionAndResponseMetadata() async throws {
        let trace = CheckoutTrace()
        let fixture = try await CheckoutFixture(trace: trace) { request in
            trace.recordSend(request)
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "approov-token"), "synthetic-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://shop.example.com")
            var headers = Self.corsHeaders
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/v1/cart"):
                XCTAssertTrue(
                    request.value(forHTTPHeaderField: "Cookie")?.contains("session=synthetic-session") == true)
                var redirect = URLRequest(url: URL(string: "https://api.example.com/v1/cart/current")!)
                redirect.httpMethod = "GET"
                return Self.reply(url: url, status: 302, headers: headers, redirect: redirect)
            case ("GET", "/v1/cart/current"):
                XCTAssertTrue(
                    request.value(forHTTPHeaderField: "Cookie")?.contains("session=synthetic-session") == true)
                headers["Set-Cookie"] =
                    "cart=synthetic-cart; Domain=.example.com; Path=/; Secure; HttpOnly; SameSite=Lax"
                headers["X-Cart-ID"] = "synthetic-cart"
                headers["Access-Control-Expose-Headers"] = "X-Cart-ID"
                return Self.reply(url: url, headers: headers, body: #"{"items":2}"#)
            case ("OPTIONS", "/v1/checkout"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertNil(request.httpBody)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Access-Control-Request-Method"), "POST")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Access-Control-Request-Headers"), "content-type,x-checkout")
                headers["Access-Control-Allow-Methods"] = "POST"
                headers["Access-Control-Allow-Headers"] = "Content-Type, X-Checkout"
                return Self.reply(url: url, headers: headers)
            case ("POST", "/v1/checkout"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Checkout"), "fixture-flow")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://shop.example.com/")
                XCTAssertTrue(
                    request.value(forHTTPHeaderField: "Cookie")?.contains("session=synthetic-session") == true)
                XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("cart=synthetic-cart") == true)
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(object["item"] as? String, "fixture-item")
                XCTAssertEqual(object["quantity"] as? Int, 2)
                return Self.reply(url: url, status: 201, headers: headers, body: #"{"order":"synthetic-order"}"#)
            default:
                XCTFail("Unexpected fixture request \(request.httpMethod ?? "GET") \(url.path)")
                throw URLError(.badURL)
            }
        }
        defer { fixture.close() }
        try await installSessionCookie(in: fixture.webView)
        await load("<main id='checkout'>Synthetic checkout</main>", in: fixture)

        let rawResult = try await fixture.webView.callAsyncJavaScript(
            """
            const cart = await fetch('https://api.example.com/v1/cart', { credentials: 'include' });
            const cartBody = await cart.json();
            const checkout = await fetch('https://api.example.com/v1/checkout', {
                method: 'POST', credentials: 'include',
                headers: { 'Content-Type': 'application/json', 'X-Checkout': 'fixture-flow' },
                body: JSON.stringify({ item: 'fixture-item', quantity: cartBody.items })
            });
            return { cartURL: cart.url, cartRedirected: cart.redirected, cartType: cart.type,
                cartHeader: cart.headers.get('X-Cart-ID'), cookieHeader: cart.headers.get('Set-Cookie'),
                checkoutURL: checkout.url, checkoutStatus: checkout.status,
                order: (await checkout.json()).order, pageCookies: document.cookie };
            """, contentWorld: .page)
        let result = try XCTUnwrap(rawResult as? [String: Any])
        XCTAssertEqual(result["cartURL"] as? String, "https://api.example.com/v1/cart/current")
        XCTAssertEqual(result["cartRedirected"] as? Bool, true)
        XCTAssertEqual(result["cartType"] as? String, "cors")
        XCTAssertEqual(result["cartHeader"] as? String, "synthetic-cart")
        XCTAssertTrue(result["cookieHeader"] is NSNull)
        XCTAssertEqual(result["checkoutURL"] as? String, "https://api.example.com/v1/checkout")
        XCTAssertEqual(result["checkoutStatus"] as? Int, 201)
        XCTAssertEqual(result["order"] as? String, "synthetic-order")
        XCTAssertFalse((result["pageCookies"] as? String ?? "").contains("cart="))
        let cookies = await fixture.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "cart" && $0.value == "synthetic-cart" && $0.isHTTPOnly })
        let sent = trace.snapshot()
        XCTAssertEqual(sent.requests.map { $0.httpMethod ?? "GET" }, ["GET", "GET", "OPTIONS", "POST"])
        XCTAssertEqual(sent.bootstrapCount, 2)
        XCTAssertEqual(sent.signedCount, 4)
        XCTAssertTrue(sent.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == fixture.userAgent })
        XCTAssertEqual(fixture.coordinator.activeRequestCount, 0)
    }

    func testMainFrameFormSubmissionRendersExecutorResponse() async throws {
        let trace = CheckoutTrace()
        let destination = URL(string: "https://shop.example.com/checkout/complete")!
        let fixture = try await CheckoutFixture(trace: trace) { request in
            trace.recordSend(request)
            XCTAssertEqual(request.url, destination)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://shop.example.com")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("session=synthetic-session") == true)
            let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
            XCTAssertEqual(body, "cart=synthetic-cart&confirm=yes")
            return Self.reply(
                url: destination, headers: ["Content-Type": "text/html; charset=utf-8"],
                body: "<title>Fixture confirmation</title><main id='confirmation'>Synthetic order confirmed</main>")
        }
        defer { fixture.close() }
        try await installSessionCookie(in: fixture.webView)
        await load(
            """
            <form id='checkout' method='post' action='/checkout/complete'>
              <input name='cart' value='synthetic-cart'>
              <button id='confirm' name='confirm' value='yes'>Confirm</button>
            </form>
            """, in: fixture)
        let navigated = expectation(description: "protected form completed real WebKit navigation")
        fixture.navigation.onFinish = { view in
            if view.url == destination { navigated.fulfill() }
        }
        fixture.navigation.onFailure = { error in
            XCTFail("Simulated checkout navigation failed: \(error)")
            navigated.fulfill()
        }
        _ = try await fixture.webView.evaluateJavaScript(
            "document.getElementById('checkout').requestSubmit(document.getElementById('confirm')); void 0")
        await fulfillment(of: [navigated], timeout: 5)
        XCTAssertEqual(fixture.webView.url, destination)
        let page =
            try await fixture.webView.evaluateJavaScript(
                "({title: document.title, confirmation: document.getElementById('confirmation').textContent})")
            as? [String: String]
        XCTAssertEqual(page?["title"], "Fixture confirmation")
        XCTAssertEqual(page?["confirmation"], "Synthetic order confirmed")
        XCTAssertEqual(trace.snapshot().requests.count, 1)
    }

    func testFetchAbortCancelsActualExecutorTransport() async throws {
        let started = expectation(description: "fixture HTTP transport started")
        let cancelled = expectation(description: "fixture HTTP transport received cancellation")
        let suspendedReply = SuspendedCheckoutReply(started: started, cancelled: cancelled)
        let trace = CheckoutTrace()
        let fixture = try await CheckoutFixture(trace: trace) { request in
            trace.recordSend(request)
            XCTAssertEqual(request.url?.path, "/v1/slow")
            return try await suspendedReply.wait()
        }
        defer {
            fixture.close()
            suspendedReply.cancel()
        }
        await load("<main>Abort checkout fixture</main>", in: fixture)
        _ = try await fixture.webView.evaluateJavaScript(
            """
            window.checkoutAbort = new AbortController();
            window.checkoutPending = fetch('https://api.example.com/v1/slow', {
                credentials: 'omit', signal: checkoutAbort.signal
            }).then(() => 'unexpected response', error => error.name);
            void 0;
            """)
        await fulfillment(of: [started], timeout: 5)
        let outcome = try await fixture.webView.callAsyncJavaScript(
            "checkoutAbort.abort(); return await checkoutPending;", contentWorld: .page)
        XCTAssertEqual(outcome as? String, "AbortError")
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(fixture.coordinator.activeRequestCount, 0)
        XCTAssertEqual(trace.snapshot().requests.count, 1)
    }

    private func load(_ html: String, in fixture: CheckoutFixture) async {
        let loaded = expectation(description: "synthetic hosted page loaded")
        fixture.navigation.onFinish = { _ in loaded.fulfill() }
        fixture.navigation.onFailure = { error in
            XCTFail("Fixture document navigation failed: \(error)")
            loaded.fulfill()
        }
        fixture.webView.loadHTMLString(html, baseURL: URL(string: "https://shop.example.com/checkout/start")!)
        await fulfillment(of: [loaded], timeout: 5)
        fixture.navigation.onFinish = nil
        fixture.navigation.onFailure = nil
        XCTAssertEqual(fixture.webView.url?.host, "shop.example.com")
    }

    private func installSessionCookie(in view: WKWebView) async throws {
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "session", .value: "synthetic-session", .domain: ".example.com",
                .path: "/", .secure: "TRUE", HTTPCookiePropertyKey(rawValue: "HttpOnly"): "TRUE",
            ]))
        await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    }

    private static let corsHeaders = [
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "https://shop.example.com",
        "Access-Control-Allow-Credentials": "true",
    ]

    private static func reply(
        url: URL, status: Int = 200, headers: [String: String],
        body: String = "", redirect: URLRequest? = nil
    ) -> (Data, URLResponse, URLRequest?) {
        (
            Data(body.utf8),
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, redirect
        )
    }
}

@MainActor
private final class CheckoutFixture {
    let webView: WKWebView
    let coordinator: ApproovWebViewCoordinator
    let executor: ApproovWebViewRequestExecutor
    let navigation = CheckoutNavigationObserver()
    let userAgent: String

    init(
        trace: CheckoutTrace,
        send: @escaping (URLRequest) async throws -> (Data, URLResponse, URLRequest?)
    ) async throws {
        let base = WKWebViewConfiguration()
        base.websiteDataStore = .nonPersistent()
        base.userContentController = WKUserContentController()
        base.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: base)
        let rawAgent = try await view.evaluateJavaScript("navigator.userAgent")
        let agent = try XCTUnwrap(rawAgent as? String)
        XCTAssertFalse(agent.isEmpty)
        let configuration = ApproovWebViewConfiguration(
            approovConfig: "synthetic-config",
            protectedEndpoints: [
                .init(host: "shop.example.com", pathPrefix: "/", excludedPathPrefixes: ["/lhstatics"]),
                .init(host: "api.example.com", pathPrefix: "/v1"),
            ],
            allowedOrigins: ["https://shop.example.com"],
            mutateRequest: { request in
                var request = request
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
                return request
            }, debugLoggingEnabled: false
        )
        let transport = ApproovWebViewRequestExecutor.TestTransport(
            bootstrap: { trace.recordBootstrap() },
            signer: { request in
                trace.recordSignature()
                var request = configuration.mutateRequest(request)
                request.setValue("synthetic-token", forHTTPHeaderField: "approov-token")
                return request
            }, send: send)
        let executor = try ApproovWebViewRequestExecutor(
            configuration: configuration,
            cookieBridge: ApproovWebViewCookieBridge(store: view.configuration.websiteDataStore.httpCookieStore),
            testTransport: transport)
        let coordinator = ApproovWebViewCoordinator(configuration: configuration) { request, context in
            XCTAssertEqual(context.frameOrigin, "https://shop.example.com")
            XCTAssertEqual(context.frameURL.host, "shop.example.com")
            XCTAssertTrue(context.isMainFrame)
            return try await executor.execute(request, context: context)
        }
        try ApproovWebViewFactory.install(on: view, configuration: configuration, coordinator: coordinator)
        self.webView = view
        self.executor = executor
        self.coordinator = coordinator
        self.userAgent = agent
        view.navigationDelegate = navigation
    }

    func close() {
        navigation.onFinish = nil
        navigation.onFailure = nil
        ApproovWebViewFactory.invalidate(on: webView)
        webView.navigationDelegate = nil
    }
}

@MainActor
private final class CheckoutNavigationObserver: NSObject, WKNavigationDelegate {
    var onFinish: ((WKWebView) -> Void)?
    var onFailure: ((Error) -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?(webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure?(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFailure?(error)
    }
}

private final class CheckoutTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var bootstrapCount = 0
    private var signedCount = 0
    func recordBootstrap() {
        lock.lock()
        bootstrapCount += 1
        lock.unlock()
    }
    func recordSignature() {
        lock.lock()
        signedCount += 1
        lock.unlock()
    }
    func recordSend(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
    func snapshot() -> (requests: [URLRequest], bootstrapCount: Int, signedCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, bootstrapCount, signedCount)
    }
}

private final class SuspendedCheckoutReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse, URLRequest?), Error>?
    private var isCancelled = false
    private let started: XCTestExpectation
    private let cancelled: XCTestExpectation
    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }
    func wait() async throws -> (Data, URLResponse, URLRequest?) {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.continuation = continuation
                        lock.unlock()
                        started.fulfill()
                    }
                }
            }, onCancel: { self.cancel() })
    }
    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
        cancelled.fulfill()
    }
}

extension WKHTTPCookieStore {
    fileprivate func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } }
    }
}

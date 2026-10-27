import SwiftUI
import UIKit
import XCTest
import WebKit
@testable import ApproovServiceWebView

final class ApproovWebViewHostTests: XCTestCase {
    @MainActor
    func testSwiftUIUpdatesReplaceContentPolicyAndShowInstallationFallback() async throws {
        let configuration = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: ["https://app.example.com"])
        let host = UIHostingController(rootView: ApproovWebView(
            content: .htmlString("first", baseURL: nil), configuration: configuration))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await waitUntil { Self.findContainer(in: host.view)?.webView != nil }
        let container = try XCTUnwrap(Self.findContainer(in: host.view))
        let first = try XCTUnwrap(container.webView)

        host.rootView = ApproovWebView(content: .htmlString("second", baseURL: nil), configuration: configuration)
        await waitUntil { container.webView != nil && container.webView !== first }
        let second = try XCTUnwrap(container.webView)
        XCTAssertFalse(first === second)

        let changed = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: ["https://different.example.com"])
        host.rootView = ApproovWebView(content: .htmlString("second", baseURL: nil), configuration: changed)
        await waitUntil { container.webView != nil && container.webView !== second }
        XCTAssertFalse(second === container.webView)

        let failed = expectation(description: "SwiftUI receives installation error")
        let invalid = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [], maximumConcurrentRequests: 0)
        host.rootView = ApproovWebView(content: .htmlString("third", baseURL: nil), configuration: invalid) { error in
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .invalidConfiguration("maximumConcurrentRequests"))
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertNil(container.webView)
        XCTAssertEqual((container.subviews.first as? UILabel)?.text, "Unable to open this page.")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("SwiftUI did not apply the expected view update")
    }

    @MainActor
    private static func findContainer(in view: UIView) -> ApproovWebViewContainer? {
        if let container = view as? ApproovWebViewContainer { return container }
        return view.subviews.lazy.compactMap { findContainer(in: $0) }.first
    }

    @MainActor
    func testRequestURLAndOriginPolicyChangesReplaceView() {
        let container = ApproovWebViewContainer()
        let config = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: ["https://first.example.com"])
        let firstContent = ApproovWebViewContent.request(URLRequest(url: URL(string: "about:blank#first")!))
        container.update(content: firstContent, configuration: config) { _ in XCTFail("unexpected error") }
        let first = container.webView
        container.update(content: firstContent, configuration: config) { _ in XCTFail("unexpected error") }
        XCTAssertTrue(first === container.webView)
        let nextContent = ApproovWebViewContent.request(URLRequest(url: URL(string: "about:blank#second")!))
        container.update(content: nextContent, configuration: config) { _ in XCTFail("unexpected error") }
        XCTAssertFalse(first === container.webView)
        let second = container.webView
        let policy = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: ["https://second.example.com"])
        container.update(content: nextContent, configuration: policy) { _ in XCTFail("unexpected error") }
        XCTAssertFalse(second === container.webView)
        container.invalidate()
        XCTAssertNil(container.webView)
    }

    @MainActor
    func testInstallationFailureShowsFallbackAndCallsOnError() {
        let container = ApproovWebViewContainer()
        let invalid = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [], maximumConcurrentRequests: 0)
        var errors = 0
        container.update(content: .htmlString("fixture", baseURL: nil), configuration: invalid) { error in
            errors += 1
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .invalidConfiguration("maximumConcurrentRequests"))
        }
        XCTAssertNil(container.webView)
        XCTAssertEqual(errors, 1)
        XCTAssertEqual((container.subviews.first as? UILabel)?.text, "Unable to open this page.")
    }

    @MainActor
    func testContentAndConfigurationChangesReplaceView() {
        let container = ApproovWebViewContainer()
        let config = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [])
        let firstContent = ApproovWebViewContent.htmlString("one", baseURL: nil)
        container.update(content: firstContent, configuration: config) { _ in XCTFail("unexpected error") }
        let first = container.webView
        container.update(content: firstContent, configuration: config) { _ in XCTFail("unexpected error") }
        XCTAssertTrue(first === container.webView)
        container.update(content: .htmlString("two", baseURL: nil), configuration: config) { _ in XCTFail("unexpected error") }
        XCTAssertFalse(first === container.webView)
        let second = container.webView
        let changed = ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [])
        container.update(content: .htmlString("two", baseURL: nil), configuration: changed) { _ in XCTFail("unexpected error") }
        XCTAssertFalse(second === container.webView)
    }
}

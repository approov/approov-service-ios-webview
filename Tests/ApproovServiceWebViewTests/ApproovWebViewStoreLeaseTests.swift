import Foundation
import ObjectiveC
import WebKit
import XCTest

@testable import ApproovServiceWebView
@testable import ApproovServiceWebViewCore

@MainActor
final class ApproovWebViewStoreLeaseTests: XCTestCase {
    private static var lifetimeProbeKey: UInt8 = 0

    func testStoreRemainsReservedAfterViewReleaseUntilCookieFlushDrains() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = ApproovWebViewConfiguration(
            approovConfig: "synthetic-config", protectedEndpoints: [],
            allowedOrigins: ["https://shop.example.com"], debugLoggingEnabled: false)
        var coordinator: ApproovWebViewCoordinator? = ApproovWebViewFactory.makeCoordinator(
            configuration: configuration)
        var first: WKWebView? = makeView(store: store)
        let releasedView = WeakReference(first)
        try ApproovWebViewFactory.install(
            on: try XCTUnwrap(first), configuration: configuration, coordinator: coordinator)
        let lease = WeakReference(coordinator?.storeLifetimeOwner)
        let leaseReleased = expectation(description: "store lease released after cookie work")
        objc_setAssociatedObject(
            try XCTUnwrap(coordinator?.storeLifetimeOwner), &Self.lifetimeProbeKey,
            LeaseReleaseProbe { leaseReleased.fulfill() }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let enteredFlush = expectation(description: "old cookie flush started")
        let adapter = SuspendedCookieStore(enteredFlush: enteredFlush)
        var flush: Task<Void, Never>? = try beginFlush(
            owner: XCTUnwrap(coordinator?.storeLifetimeOwner), adapter: adapter)
        await fulfillment(of: [enteredFlush], timeout: 5)

        // The view and its coordinator are gone, but the old asynchronous cookie
        // reconciliation still owns its store lease through the cookie bridge.
        first = nil
        coordinator = nil
        XCTAssertNil(releasedView.value)
        XCTAssertNotNil(lease.value)
        let replacement = makeView(store: store)
        XCTAssertThrowsError(try ApproovWebViewFactory.install(on: replacement, configuration: configuration)) {
            error in
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .dataStoreAlreadyInUse)
        }
        XCTAssertTrue(replacement.configuration.userContentController.userScripts.isEmpty)

        // Cancellation must not allow a second writer before the suspended
        // WebKit mutation finishes. Cookie reconciliation drains before release.
        flush?.cancel()
        XCTAssertThrowsError(try ApproovWebViewFactory.install(on: replacement, configuration: configuration)) {
            error in
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .dataStoreAlreadyInUse)
        }
        adapter.finishFlush()
        await flush?.value
        flush = nil
        await fulfillment(of: [leaseReleased], timeout: 5)
        XCTAssertNil(lease.value)

        try ApproovWebViewFactory.install(on: replacement, configuration: configuration)
        XCTAssertEqual(replacement.configuration.userContentController.userScripts.count, 1)
        ApproovWebViewFactory.invalidate(on: replacement)
    }

    private func makeView(store: WKWebsiteDataStore) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.userContentController = WKUserContentController()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func beginFlush(owner: AnyObject, adapter: SuspendedCookieStore) throws -> Task<Void, Never> {
        let bridge = ApproovWebViewCookieBridge(storeAdapter: adapter, lifetimeOwner: owner)
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "session", .value: "synthetic-session", .domain: "shop.example.com", .path: "/",
            ]))
        return Task { await bridge.synchronize(deleting: [], setting: [cookie]) }
    }
}

private final class WeakReference {
    weak var value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
}

@MainActor
private final class SuspendedCookieStore: ApproovWebViewCookieStoreAdapter {
    private let enteredFlush: XCTestExpectation
    private var pending: CheckedContinuation<Void, Never>?
    init(enteredFlush: XCTestExpectation) { self.enteredFlush = enteredFlush }
    func allCookies() async -> [HTTPCookie] { [] }
    func deleteCookie(_ cookie: HTTPCookie) async {}
    func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            pending = continuation
            enteredFlush.fulfill()
        }
    }
    func finishFlush() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}

private final class LeaseReleaseProbe: NSObject {
    private let onRelease: () -> Void
    init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

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
        var coordinator: ApproovWebViewCoordinator?
        var first: WKWebView?
        let releasedView = WeakReference(nil)
        let releasedCoordinator = WeakReference(nil)
        let releasedBridge = WeakReference(nil)
        let lease = WeakReference(nil)
        let leaseReleased = expectation(description: "store lease released after cookie work")
        let enteredFlush = expectation(description: "old cookie flush started")
        let adapter = SuspendedCookieStore(enteredFlush: enteredFlush)
        var flush: Task<Void, Never>?
        // WKWebView.configuration returns Objective-C objects. Keep its temporary
        // configuration/controller copies inside a pool, rather than the async test.
        try autoreleasepool {
            coordinator = ApproovWebViewFactory.makeCoordinator(configuration: configuration)
            first = makeView(store: store)
            releasedView.value = first
            releasedCoordinator.value = coordinator
            try ApproovWebViewFactory.install(
                on: XCTUnwrap(first), configuration: configuration, coordinator: coordinator)
            lease.value = coordinator?.storeLifetimeOwner
            objc_setAssociatedObject(
                try XCTUnwrap(coordinator?.storeLifetimeOwner), &Self.lifetimeProbeKey,
                LeaseReleaseProbe { leaseReleased.fulfill() }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            flush = try beginFlush(
                owner: XCTUnwrap(coordinator?.storeLifetimeOwner), adapter: adapter, bridgeProbe: releasedBridge)
        }
        await fulfillment(of: [enteredFlush], timeout: 5)

        // The view and its coordinator are gone, but the old asynchronous cookie
        // reconciliation still owns its store lease through the cookie bridge.
        autoreleasepool {
            first = nil
            coordinator = nil
            XCTAssertNil(releasedView.value)
            XCTAssertNil(releasedCoordinator.value, "The old coordinator still retains its installation lease")
            XCTAssertNotNil(releasedBridge.value, "The suspended flush must retain its cookie bridge")
            XCTAssertNotNil(lease.value)
        }
        let replacement = makeView(store: store)
        autoreleasepool {
            XCTAssertThrowsError(try ApproovWebViewFactory.install(on: replacement, configuration: configuration)) {
                error in
                XCTAssertEqual(error as? ApproovWebViewInstallationError, .dataStoreAlreadyInUse)
            }
        }
        XCTAssertTrue(replacement.configuration.userContentController.userScripts.isEmpty)

        // Cancellation must not allow a second writer before the suspended
        // WebKit mutation finishes. Cookie reconciliation drains before release.
        flush?.cancel()
        autoreleasepool {
            XCTAssertThrowsError(try ApproovWebViewFactory.install(on: replacement, configuration: configuration)) {
                error in
                XCTAssertEqual(error as? ApproovWebViewInstallationError, .dataStoreAlreadyInUse)
            }
        }
        adapter.finishFlush()
        await drain(&flush)
        autoreleasepool {
            XCTAssertNil(releasedCoordinator.value, "Coordinator survived the raw view")
            XCTAssertNil(releasedBridge.value, "Completed flush still retains its cookie bridge")
        }
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

    private func drain(_ task: inout Task<Void, Never>?) async {
        let running = task
        task = nil
        await running?.value
    }

    private func beginFlush(
        owner: AnyObject, adapter: SuspendedCookieStore,
        bridgeProbe: WeakReference
    ) throws -> Task<Void, Never> {
        let bridge = ApproovWebViewCookieBridge(storeAdapter: adapter, lifetimeOwner: owner)
        bridgeProbe.value = bridge
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

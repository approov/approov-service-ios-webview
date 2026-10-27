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
        let retainedController = WKUserContentController()
        defer { withExtendedLifetime(retainedController) {} }
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
            first = makeView(store: store, controller: retainedController)
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

        // The raw view is gone and the retained controller still owns its handler.
        // The old asynchronous cookie reconciliation must keep the lease reserved.
        autoreleasepool {
            first = nil
            coordinator = nil
            XCTAssertNil(releasedView.value)
            XCTAssertNotNil(releasedCoordinator.value, "The retained controller must keep its handler alive")
            XCTAssertNotNil(releasedBridge.value, "The suspended flush must retain its cookie bridge")
            XCTAssertNotNil(lease.value)
        }
        let replacement = makeView(store: store)
        try autoreleasepool {
            XCTAssertThrowsError(try ApproovWebViewFactory.install(on: replacement, configuration: configuration)) {
                error in
                XCTAssertEqual(error as? ApproovWebViewInstallationError, .dataStoreAlreadyInUse)
            }
        }
        XCTAssertTrue(replacement.configuration.userContentController.userScripts.isEmpty)

        // Cancellation must not allow a second writer before the suspended
        // WebKit mutation finishes. Cookie reconciliation drains before release.
        flush?.cancel()
        try autoreleasepool {
            XCTAssertThrowsError(try ApproovWebViewFactory.install(on: replacement, configuration: configuration)) {
                error in
                XCTAssertEqual(error as? ApproovWebViewInstallationError, .dataStoreAlreadyInUse)
            }
        }
        adapter.finishFlush()
        await drain(&flush)
        autoreleasepool {
            XCTAssertNotNil(releasedCoordinator.value, "The retained old controller keeps its handler alive")
            XCTAssertNil(releasedBridge.value, "Completed flush still retains its cookie bridge")
        }
        await fulfillment(of: [leaseReleased], timeout: 5)
        XCTAssertNil(lease.value)
        XCTAssertNil(
            (releasedCoordinator.value as? ApproovWebViewCoordinator)?.storeLifetimeOwner,
            "Closing the old view must release the coordinator's own lease")

        try ApproovWebViewFactory.install(on: replacement, configuration: configuration)
        XCTAssertEqual(replacement.configuration.userContentController.userScripts.count, 1)
        ApproovWebViewFactory.invalidate(on: replacement)
    }

    func testRawViewReleaseFreesStoreAfterCleanupEvenWhenOldControllerIsRetained() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let retainedController = WKUserContentController()
        let configuration = ApproovWebViewConfiguration(
            approovConfig: "synthetic-config", protectedEndpoints: [],
            allowedOrigins: ["https://shop.example.com"], debugLoggingEnabled: false)
        let coordinatorProbe = WeakReference(nil)
        let lease = WeakReference(nil)
        let leaseReleased = expectation(description: "closed installation releases its idle lease")
        var first: WKWebView?
        try autoreleasepool {
            let base = WKWebViewConfiguration()
            base.websiteDataStore = store
            base.userContentController = retainedController
            let coordinator = ApproovWebViewFactory.makeCoordinator(configuration: configuration)
            first = WKWebView(frame: .zero, configuration: base)
            try ApproovWebViewFactory.install(
                on: XCTUnwrap(first), configuration: configuration, coordinator: coordinator)
            coordinatorProbe.value = coordinator
            lease.value = coordinator.storeLifetimeOwner
            objc_setAssociatedObject(
                try XCTUnwrap(coordinator.storeLifetimeOwner), &Self.lifetimeProbeKey,
                LeaseReleaseProbe { leaseReleased.fulfill() }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        first = nil
        // The old controller deliberately keeps the coordinator alive. Closing
        // the WebView must still drop its idle executor and installation lease.
        XCTAssertNotNil(coordinatorProbe.value)
        await fulfillment(of: [leaseReleased], timeout: 5)
        XCTAssertNil(lease.value)
        XCTAssertNotNil(coordinatorProbe.value)
        let replacement = makeView(store: store)
        try ApproovWebViewFactory.install(on: replacement, configuration: configuration)
        ApproovWebViewFactory.invalidate(on: replacement)
        withExtendedLifetime(retainedController) {}
    }

    private func makeView(store: WKWebsiteDataStore, controller: WKUserContentController? = nil) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.userContentController = controller ?? WKUserContentController()
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

import Foundation
import WebKit
import XCTest
@testable import ApproovServiceWebViewCore

@available(macOS 10.15, *)
@MainActor
final class ApproovWebViewCookieBridgeTests: XCTestCase {
    func testRealWebKitStoreDeletesHttpOnlyCookie() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        // Not dead code: the data store owns the cookie store, so it has to
        // outlive the bridge or the cookies vanish mid-test.
        // `withExtendedLifetime` has no async overload, hence the defer.
        defer { _ = dataStore }
        let bridge = ApproovWebViewCookieBridge(
            store: dataStore.httpCookieStore
        )
        let cookie = makeCookie(
            name: "session",
            value: "authenticated",
            httpOnly: true
        )
        await bridge.synchronize(deleting: [], setting: [cookie])
        let storedCookies = await bridge.allCookies()
        let storedCookie = try XCTUnwrap(storedCookies.first)
        XCTAssertTrue(storedCookie.isHTTPOnly)

        await bridge.synchronize(deleting: [cookie], setting: [])

        let remainingCookies = await bridge.allCookies()
        XCTAssertTrue(remainingCookies.isEmpty)
    }

    func testRealWebKitStoreDeletesBeforeSettingReplacement() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        // See above: keeps the owning data store alive for the whole test.
        defer { _ = dataStore }
        let bridge = ApproovWebViewCookieBridge(
            store: dataStore.httpCookieStore
        )
        let oldCookie = makeCookie(name: "session", value: "old")
        let replacement = makeCookie(name: "session", value: "new")
        await bridge.synchronize(deleting: [], setting: [oldCookie])

        await bridge.synchronize(
            deleting: [oldCookie],
            setting: [replacement]
        )

        let cookies = await bridge.allCookies()
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies.first?.value, "new")
    }

    func testUnchangedNativeSnapshotDoesNotResurrectRealWebKitDeletion() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        defer { _ = dataStore }
        let bridge = ApproovWebViewCookieBridge(
            store: dataStore.httpCookieStore
        )
        let jar = try ApproovWebViewNativeCookieJar()
        let original = makeCookie(
            name: "session",
            value: "authenticated"
        )
        await bridge.synchronize(deleting: [], setting: [original])
        let snapshotTicket = jar.beginWebKitSnapshot()
        let snapshot = await bridge.allCookies()
        XCTAssertTrue(
            jar.synchronizeFromWebKit(
                snapshot,
                snapshotTicket: snapshotTicket
            )
        )

        // Models WebKit deleting the cookie while a native request that
        // produces no Set-Cookie response is suspended.
        await bridge.synchronize(deleting: [original], setting: [])
        let flush = jar.makeWebKitFlush()
        await bridge.synchronize(
            deleting: flush.cookiesToDelete,
            setting: flush.cookiesToSet
        )
        jar.completeWebKitFlush(flush)

        let cookies = await bridge.allCookies()
        XCTAssertTrue(cookies.isEmpty)
    }

    func testUnchangedNativeSnapshotDoesNotOverwriteNewerWebKitValue() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        defer { _ = dataStore }
        let bridge = ApproovWebViewCookieBridge(
            store: dataStore.httpCookieStore
        )
        let jar = try ApproovWebViewNativeCookieJar()
        let original = makeCookie(name: "session", value: "old")
        let replacement = makeCookie(name: "session", value: "new")
        await bridge.synchronize(deleting: [], setting: [original])
        let snapshotTicket = jar.beginWebKitSnapshot()
        let snapshot = await bridge.allCookies()
        XCTAssertTrue(
            jar.synchronizeFromWebKit(
                snapshot,
                snapshotTicket: snapshotTicket
            )
        )

        // Models WebKit replacing the cookie while a native request that
        // produces no Set-Cookie response is suspended.
        await bridge.synchronize(deleting: [], setting: [replacement])
        let flush = jar.makeWebKitFlush()
        await bridge.synchronize(
            deleting: flush.cookiesToDelete,
            setting: flush.cookiesToSet
        )
        jar.completeWebKitFlush(flush)

        let cookies = await bridge.allCookies()
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies.first?.value, "new")
    }

    func testReadsWaitForOrderedDeleteThenSetMutation() async throws {
        let oldCookie = makeCookie(name: "session", value: "old")
        let replacement = makeCookie(name: "session", value: "new")
        let store = ControllableCookieStore(cookies: [oldCookie])
        store.suspendNextDelete = true
        let bridge = ApproovWebViewCookieBridge(storeAdapter: store)

        let mutation = Task { @MainActor in
            await bridge.synchronize(
                deleting: [oldCookie],
                setting: [replacement]
            )
        }
        await waitUntil { store.operationLog == ["delete:session:start"] }

        let read = Task { @MainActor in
            await bridge.allCookies()
        }
        await Task.yield()
        XCTAssertEqual(store.operationLog, ["delete:session:start"])

        store.resumeDelete()
        await mutation.value
        let cookies = await read.value

        XCTAssertEqual(cookies.map(\.value), ["new"])
        XCTAssertEqual(
            store.operationLog,
            [
                "delete:session:start",
                "delete:session:finish",
                "set:session:new",
                "read"
            ]
        )
    }

    func testLateDeletionCannotRemoveNewerQueuedReplacement() async {
        let oldCookie = makeCookie(name: "session", value: "old")
        let replacement = makeCookie(name: "session", value: "new")
        let store = ControllableCookieStore(cookies: [oldCookie])
        store.suspendNextDelete = true
        let bridge = ApproovWebViewCookieBridge(storeAdapter: store)

        let deletion = Task { @MainActor in
            await bridge.synchronize(deleting: [oldCookie], setting: [])
        }
        await waitUntil { store.operationLog == ["delete:session:start"] }
        let replacementMutation = Task { @MainActor in
            await bridge.synchronize(deleting: [], setting: [replacement])
        }
        await Task.yield()

        store.resumeDelete()
        await deletion.value
        await replacementMutation.value

        let cookies = await bridge.allCookies()
        XCTAssertEqual(cookies.map(\.value), ["new"])
        XCTAssertEqual(
            store.operationLog,
            [
                "delete:session:start",
                "delete:session:finish",
                "set:session:new",
                "read"
            ]
        )
    }

    private func makeCookie(
        name: String,
        value: String,
        httpOnly: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: "api.example.com",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE"
        ]
        if httpOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        return HTTPCookie(properties: properties)!
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for controlled cookie operation")
    }
}

@available(macOS 10.15, *)
@MainActor
private final class ControllableCookieStore:
    ApproovWebViewCookieStoreAdapter {
    private struct Identity: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            domain = cookie.domain
            path = cookie.path
        }
    }

    private var cookiesByIdentity: [Identity: HTTPCookie]
    private var deleteContinuation: CheckedContinuation<Void, Never>?
    var operationLog: [String] = []
    var suspendNextDelete = false

    init(cookies: [HTTPCookie]) {
        cookiesByIdentity = Dictionary(
            uniqueKeysWithValues: cookies.map {
                (Identity($0), $0)
            }
        )
    }

    func allCookies() async -> [HTTPCookie] {
        operationLog.append("read")
        return Array(cookiesByIdentity.values)
    }

    func setCookie(_ cookie: HTTPCookie) async {
        operationLog.append("set:\(cookie.name):\(cookie.value)")
        cookiesByIdentity[Identity(cookie)] = cookie
    }

    func deleteCookie(_ cookie: HTTPCookie) async {
        operationLog.append("delete:\(cookie.name):start")
        if suspendNextDelete {
            suspendNextDelete = false
            await withCheckedContinuation { continuation in
                deleteContinuation = continuation
            }
        }
        cookiesByIdentity.removeValue(forKey: Identity(cookie))
        operationLog.append("delete:\(cookie.name):finish")
    }

    func resumeDelete() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }
}

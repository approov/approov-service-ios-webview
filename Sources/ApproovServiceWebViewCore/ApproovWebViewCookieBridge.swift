import Foundation
import WebKit

/// Package-internal adapter that makes WebKit cookie operations controllable
/// in the Core test target without linking the binary Approov framework.
///
/// The `@available(macOS 10.15, *)` annotations on this file exist only so the
/// Core module still compiles when the package is built for macOS tooling;
/// `Package.swift` ships iOS 15 as the only supported platform.
@available(macOS 10.15, *)
@MainActor
package protocol ApproovWebViewCookieStoreAdapter: AnyObject {
    func allCookies() async -> [HTTPCookie]
    func setCookie(_ cookie: HTTPCookie) async
    func deleteCookie(_ cookie: HTTPCookie) async
}

@available(macOS 10.15, *)
@MainActor
private final class WebKitCookieStoreAdapter:
    ApproovWebViewCookieStoreAdapter {
    private let store: WKHTTPCookieStore

    init(store: WKHTTPCookieStore) {
        self.store = store
    }

    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    func deleteCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) {
                continuation.resume()
            }
        }
    }
}

/// Serializes mutations of WebKit's cookie store while leaving protected
/// network requests concurrent.
///
/// Each reconciliation deletes response tombstones before setting response
/// cookie deltas. A read waits for every mutation already invoked when the read
/// began, so it cannot observe a half-applied delete/set sequence from those.
/// A mutation invoked *after* the read began can still interleave, because the
/// underlying store read is itself asynchronous; `ApproovWebViewNativeCookieJar`
/// covers that case with snapshot tickets and its pending-mirror barrier rather
/// than with a store-wide lock.
///
/// - Note: One bridge serializes only its own mutations. Two bridges over the
///   same `WKHTTPCookieStore` (one per protected web view sharing a
///   `WKWebsiteDataStore`) do not serialize against each other.
@available(macOS 10.15, *)
@MainActor
package final class ApproovWebViewCookieBridge {
    private let store: any ApproovWebViewCookieStoreAdapter
    private var mutationTail: Task<Void, Never>?
    private var mutationGeneration: UInt64 = 0

    package convenience init(store: WKHTTPCookieStore) {
        self.init(storeAdapter: WebKitCookieStoreAdapter(store: store))
    }

    package init(
        storeAdapter: any ApproovWebViewCookieStoreAdapter
    ) {
        self.store = storeAdapter
    }

    package func allCookies() async -> [HTTPCookie] {
        let pendingMutation = mutationTail
        await pendingMutation?.value
        return await store.allCookies()
    }

    package func synchronize(
        deleting cookiesToDelete: [HTTPCookie],
        setting cookiesToSet: [HTTPCookie]
    ) async {
        mutationGeneration &+= 1
        let generation = mutationGeneration
        let precedingMutation = mutationTail
        let store = store
        let mutation = Task { @MainActor in
            await precedingMutation?.value

            for cookie in cookiesToDelete {
                await store.deleteCookie(cookie)
            }

            for cookie in cookiesToSet {
                await store.setCookie(cookie)
            }
        }

        mutationTail = mutation
        await mutation.value

        if mutationGeneration == generation {
            mutationTail = nil
        }
    }
}

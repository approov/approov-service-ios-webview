import Foundation
import WebKit

/// Bridges cookies between WebKit and native networking.
///
/// WebKit keeps its own cookie store. Native `URLSession` keeps its own cookie
/// storage. The bridge keeps those stores aligned so session cookies, CSRF
/// cookies, and login state still work after a protected request is proxied
/// into native code.
@MainActor
final class ApproovWebViewCookieBridge {
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

    func setCookies(_ cookies: [HTTPCookie]) async {
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }
}

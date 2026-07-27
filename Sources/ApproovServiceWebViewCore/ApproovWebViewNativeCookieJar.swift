import Foundation

package enum ApproovWebViewNativeCookieJarError: LocalizedError, Equatable {
    case cookieStorageUnavailable

    package var errorDescription: String? {
        switch self {
        case .cookieStorageUnavailable:
            return "The Approov WebView bridge could not create isolated cookie storage."
        }
    }
}

/// Owns the native cookie state used by protected WebView requests.
///
/// The working storage is retained from an ephemeral configuration and then
/// deliberately detached from the configuration before it is supplied to
/// `URLSession`. This gives the request executor exclusive ownership of the jar:
/// CFNetwork neither reads from nor writes to the same `HTTPCookieStorage`.
package final class ApproovWebViewNativeCookieJar {
    private struct CookieIdentity: Hashable {
        let name: String
        let domain: String
        let path: String

        init(_ cookie: HTTPCookie) {
            self.name = cookie.name
            self.domain = cookie.domain
            self.path = cookie.path
        }
    }

    package let sessionConfiguration: URLSessionConfiguration

    private let storage: HTTPCookieStorage
    private var previousWebKitCookieIdentities: Set<CookieIdentity> = []
    private var nextWebKitSnapshotTicket: UInt64 = 0
    private var lastAppliedWebKitSnapshotTicket: UInt64 = 0

    package init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) throws {
        guard let storage = sessionConfiguration.httpCookieStorage else {
            throw ApproovWebViewNativeCookieJarError.cookieStorageUnavailable
        }

        storage.cookieAcceptPolicy = .always
        self.storage = storage

        // The bridge supplies Cookie request headers and accepts Set-Cookie
        // response headers explicitly. The transport must never share this jar.
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.sessionConfiguration = sessionConfiguration
    }

    package var allCookies: [HTTPCookie] {
        storage.cookies ?? []
    }

    /// Reserves ordering for a WebKit snapshot before its asynchronous read.
    package func beginWebKitSnapshot() -> UInt64 {
        nextWebKitSnapshotTicket += 1
        return nextWebKitSnapshotTicket
    }

    /// Reconciles a WebKit snapshot if no newer asynchronous read has already
    /// completed. This also avoids deleting response cookies that were added
    /// after the snapshot was requested.
    @discardableResult
    package func synchronizeFromWebKit(
        _ cookies: [HTTPCookie],
        snapshotTicket: UInt64
    ) -> Bool {
        guard snapshotTicket > lastAppliedWebKitSnapshotTicket else {
            return false
        }

        let currentIdentities = Set(cookies.map(CookieIdentity.init))
        let deletedIdentities = previousWebKitCookieIdentities
            .subtracting(currentIdentities)

        if !deletedIdentities.isEmpty {
            for cookie in storage.cookies ?? []
            where deletedIdentities.contains(CookieIdentity(cookie)) {
                storage.deleteCookie(cookie)
            }
        }

        for cookie in cookies {
            storage.setCookie(cookie)
        }

        previousWebKitCookieIdentities = currentIdentities
        lastAppliedWebKitSnapshotTicket = snapshotTicket
        return true
    }

    /// Applies the manually managed Cookie header and disables Foundation's
    /// per-request automatic cookie handling.
    package func prepare(_ request: inout URLRequest, for url: URL) {
        request.httpShouldHandleCookies = false

        guard request.value(forHTTPHeaderField: "Cookie") == nil,
              let cookies = storage.cookies(for: url),
              !cookies.isEmpty else {
            return
        }

        for (headerName, headerValue) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }
    }

    /// Explicitly accepts response cookies into the actor-owned jar.
    @discardableResult
    package func storeResponseCookies(
        fromResponseHeaders headers: [AnyHashable: Any],
        url: URL
    ) -> Int {
        let cookies = ApproovWebViewResponseCookies.cookies(
            fromResponseHeaders: headers,
            url: url
        )

        for cookie in cookies {
            if let expiresDate = cookie.expiresDate, expiresDate <= Date() {
                deleteCookie(withIdentity: CookieIdentity(cookie))
            } else {
                storage.setCookie(cookie)
            }
        }

        return cookies.count
    }

    private func deleteCookie(withIdentity identity: CookieIdentity) {
        for cookie in storage.cookies ?? []
        where CookieIdentity(cookie) == identity {
            storage.deleteCookie(cookie)
        }
    }
}

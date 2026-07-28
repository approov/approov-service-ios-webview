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
    private var responseMutationBarriers: [CookieIdentity: UInt64] = [:]
    private var pendingWebKitDeletions: [CookieIdentity: HTTPCookie] = [:]

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

    package var webKitCookiesToDelete: [HTTPCookie] {
        Array(pendingWebKitDeletions.values)
    }

    /// Reserves ordering for a WebKit snapshot before its asynchronous read.
    package func beginWebKitSnapshot() -> UInt64 {
        nextWebKitSnapshotTicket += 1
        return nextWebKitSnapshotTicket
    }

    /// Reconciles a WebKit snapshot if no newer asynchronous read has already
    /// completed.
    ///
    /// A response mutation establishes an identity-specific barrier at the
    /// latest snapshot ticket that had already been reserved. Values and
    /// absences from those snapshots are ignored for that identity, preventing
    /// a late WebKit callback from undoing a server deletion or replacement.
    /// The first later snapshot is read only after the bridge's ordered
    /// delete/set operation and therefore confirms the response mutation.
    @discardableResult
    package func synchronizeFromWebKit(
        _ cookies: [HTTPCookie],
        snapshotTicket: UInt64
    ) -> Bool {
        guard snapshotTicket > lastAppliedWebKitSnapshotTicket else {
            return false
        }

        let currentIdentities = Set(cookies.map(CookieIdentity.init))
        let protectedIdentities = Set(
            responseMutationBarriers.compactMap { identity, barrier in
                snapshotTicket <= barrier ? identity : nil
            }
        )
        let confirmedIdentities = responseMutationBarriers.compactMap {
            identity, barrier in
            snapshotTicket > barrier ? identity : nil
        }

        for identity in confirmedIdentities {
            responseMutationBarriers.removeValue(forKey: identity)
            pendingWebKitDeletions.removeValue(forKey: identity)
        }

        let deletedIdentities = previousWebKitCookieIdentities
            .subtracting(currentIdentities)
            .subtracting(protectedIdentities)

        if !deletedIdentities.isEmpty {
            for cookie in storage.cookies ?? []
            where deletedIdentities.contains(CookieIdentity(cookie)) {
                storage.deleteCookie(cookie)
            }
        }

        for cookie in cookies
        where !protectedIdentities.contains(CookieIdentity(cookie)) {
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
            let identity = CookieIdentity(cookie)
            responseMutationBarriers[identity] = nextWebKitSnapshotTicket

            if let expiresDate = cookie.expiresDate, expiresDate <= Date() {
                let deletionCookie = storedCookie(withIdentity: identity)
                    ?? cookie
                deleteCookie(withIdentity: identity)
                pendingWebKitDeletions[identity] = deletionCookie
            } else {
                storage.setCookie(cookie)
                pendingWebKitDeletions.removeValue(forKey: identity)
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

    private func storedCookie(
        withIdentity identity: CookieIdentity
    ) -> HTTPCookie? {
        (storage.cookies ?? []).first {
            CookieIdentity($0) == identity
        }
    }
}

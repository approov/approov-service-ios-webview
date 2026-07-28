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
///
/// - Important: This type is **not** thread-safe and holds mutable
///   reconciliation state. Every member must be reached from a single
///   serialized context; in the shipping bridge that context is
///   `ApproovWebViewRequestExecutor`'s actor isolation. Do not share an
///   instance across isolation domains.
///
/// - Note: One jar tracks one WebKit cookie store *as observed through one
///   executor*. Two protected web views backed by the same
///   `WKWebsiteDataStore` (for example the process-wide `.default()` store)
///   each get their own jar, so their reconciliation state and snapshot
///   tickets are independent and are not serialized against one another.
///   Concurrent protected traffic in two such web views can therefore still
///   observe each other's half-applied WebKit updates. Protecting a single web
///   view at a time is the supported configuration.
package final class ApproovWebViewNativeCookieJar {
    /// What a single response's `Set-Cookie` headers did to the jar.
    package struct ResponseCookieOutcome: Equatable {
        package var storedCount = 0
        package var deletedCount = 0

        package var isEmpty: Bool {
            storedCount == 0 && deletedCount == 0
        }
    }

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
    private var hasUnflushedResponseMutations = false

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

    /// Whether a response mutation is still waiting to be mirrored into WebKit.
    package var isAwaitingWebKitFlush: Bool {
        hasUnflushedResponseMutations
    }

    /// Reserves ordering for a WebKit snapshot before its asynchronous read.
    package func beginWebKitSnapshot() -> UInt64 {
        nextWebKitSnapshotTicket += 1
        return nextWebKitSnapshotTicket
    }

    /// Records that the bridge finished mirroring response mutations into
    /// WebKit, so snapshots taken from here on can be trusted for the mutated
    /// identities.
    ///
    /// Barriers are re-based onto the latest reserved ticket rather than
    /// cleared: a snapshot whose read was already in flight while the mirror
    /// was being applied must still be ignored, because it may have observed
    /// WebKit before the delete/set pair landed. Once a snapshot reserved after
    /// the mirror arrives, WebKit is authoritative for those identities again,
    /// so a cookie the page legitimately re-created is honoured instead of
    /// being suppressed indefinitely.
    package func completeWebKitFlush() {
        hasUnflushedResponseMutations = false
        for identity in responseMutationBarriers.keys {
            responseMutationBarriers[identity] = nextWebKitSnapshotTicket
        }
    }

    /// Reconciles a WebKit snapshot if no newer asynchronous read has already
    /// completed.
    ///
    /// A response mutation establishes an identity-specific barrier at the
    /// latest snapshot ticket that had already been reserved. Values and
    /// absences from those snapshots are ignored for that identity, preventing
    /// a late WebKit callback from undoing a server deletion or replacement.
    ///
    /// A barrier is released only by a snapshot reserved after
    /// `completeWebKitFlush()`, so trust never depends on where the caller
    /// happens to suspend between storing response cookies and mirroring them.
    /// While a mirror is outstanding every barriered identity is protected
    /// regardless of ticket, because a snapshot reserved after the response can
    /// still read WebKit before the mirror is applied.
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
                hasUnflushedResponseMutations || snapshotTicket <= barrier
                    ? identity
                    : nil
            }
        )
        let confirmedIdentities = hasUnflushedResponseMutations
            ? []
            : responseMutationBarriers.compactMap { identity, barrier in
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
    ///
    /// The result distinguishes cookies written from cookies the server
    /// expired, so callers do not report a logout as a store.
    @discardableResult
    package func storeResponseCookies(
        fromResponseHeaders headers: [AnyHashable: Any],
        url: URL
    ) -> ResponseCookieOutcome {
        let cookies = ApproovWebViewResponseCookies.cookies(
            fromResponseHeaders: headers,
            url: url
        )
        var outcome = ResponseCookieOutcome()

        for cookie in cookies {
            let identity = CookieIdentity(cookie)
            responseMutationBarriers[identity] = nextWebKitSnapshotTicket
            hasUnflushedResponseMutations = true

            if let expiresDate = cookie.expiresDate, expiresDate <= Date() {
                let deletionCookie = storedCookie(withIdentity: identity)
                    ?? cookie
                deleteCookie(withIdentity: identity)
                pendingWebKitDeletions[identity] = deletionCookie
                outcome.deletedCount += 1
            } else {
                storage.setCookie(cookie)
                pendingWebKitDeletions.removeValue(forKey: identity)
                outcome.storedCount += 1
            }
        }

        return outcome
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

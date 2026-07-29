import Foundation
import XCTest
@testable import ApproovServiceWebViewCore

final class ApproovWebViewNativeCookieJarTests: XCTestCase {
    private let apiURL = URL(string: "https://api.example.com/path")!

    func testRetainsFunctionalStorageButDetachesItFromTransport() throws {
        let jar = try ApproovWebViewNativeCookieJar()

        XCTAssertNil(jar.sessionConfiguration.httpCookieStorage)
        XCTAssertFalse(jar.sessionConfiguration.httpShouldSetCookies)
        XCTAssertEqual(jar.sessionConfiguration.httpCookieAcceptPolicy, .never)

        synchronize(jar, fromWebKit: [
            makeCookie(name: "session", value: "abc123")
        ])

        XCTAssertEqual(jar.allCookies.map(\.value), ["abc123"])
    }

    func testInitializationFailsWhenConfigurationHasNoCookieStorage() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil

        XCTAssertThrowsError(
            try ApproovWebViewNativeCookieJar(
                sessionConfiguration: configuration
            )
        ) { error in
            XCTAssertEqual(
                error as? ApproovWebViewNativeCookieJarError,
                .cookieStorageUnavailable
            )
        }
    }

    func testPrepareDisablesAutomaticHandlingAndAppliesManualCookieHeader() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        synchronize(jar, fromWebKit: [
            makeCookie(name: "session", value: "abc123"),
            makeCookie(name: "csrf", value: "token456")
        ])
        var request = URLRequest(url: apiURL)

        jar.prepare(&request, for: apiURL)

        XCTAssertFalse(request.httpShouldHandleCookies)
        let cookieHeader = try XCTUnwrap(
            request.value(forHTTPHeaderField: "Cookie")
        )
        XCTAssertTrue(cookieHeader.contains("session=abc123"))
        XCTAssertTrue(cookieHeader.contains("csrf=token456"))
    }

    func testPreparePreservesExplicitCookieHeader() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        synchronize(jar, fromWebKit: [
            makeCookie(name: "session", value: "native")
        ])
        var request = URLRequest(url: apiURL)
        request.setValue("explicit=value", forHTTPHeaderField: "Cookie")

        jar.prepare(&request, for: apiURL)

        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "explicit=value"
        )
    }

    func testPrepareRedirectRebuildsCookieHeaderForDestination() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        synchronize(jar, fromWebKit: [
            makeCookie(
                name: "source",
                value: "secret",
                domain: "api.example.com"
            ),
            makeCookie(
                name: "destination",
                value: "allowed",
                domain: "login.example.net"
            )
        ])
        let destinationURL = URL(
            string: "https://login.example.net/complete"
        )!
        var request = URLRequest(url: destinationURL)
        request.setValue("source=secret", forHTTPHeaderField: "Cookie")

        jar.prepareRedirect(&request, for: destinationURL)

        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "destination=allowed"
        )
    }

    func testRedirectResponseCookieIsAppliedToNextHop() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let redirectURL = URL(
            string: "https://api.example.com/login"
        )!
        let destinationURL = URL(
            string: "https://api.example.com/authenticated"
        )!

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=redirected; Path=/; HttpOnly"
            ],
            url: redirectURL
        )
        var proposedRequest = URLRequest(url: destinationURL)

        jar.prepareRedirect(
            &proposedRequest,
            for: destinationURL
        )

        XCTAssertEqual(
            proposedRequest.value(forHTTPHeaderField: "Cookie"),
            "session=redirected"
        )
    }

    func testStoresReplacesAndDeletesResponseCookies() throws {
        let jar = try ApproovWebViewNativeCookieJar()

        XCTAssertEqual(
            jar.storeResponseCookies(
                fromResponseHeaders: [
                    "Set-Cookie": "session=abc123; Path=/; HttpOnly"
                ],
                url: apiURL
            ),
            .init(storedCount: 1, deletedCount: 0)
        )
        XCTAssertEqual(jar.allCookies.first?.value, "abc123")
        XCTAssertTrue(try XCTUnwrap(jar.allCookies.first).isHTTPOnly)

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": """
                session=replaced; Path=/; \
                Expires=Wed, 09 Jun 2038 10:18:14 GMT; HttpOnly
                """
            ],
            url: apiURL
        )
        XCTAssertEqual(jar.allCookies.first?.value, "replaced")
        XCTAssertNotNil(jar.allCookies.first?.expiresDate)

        XCTAssertEqual(
            jar.storeResponseCookies(
                fromResponseHeaders: [
                    "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
                ],
                url: apiURL
            ),
            .init(storedCount: 0, deletedCount: 1)
        )
        XCTAssertTrue(jar.allCookies.isEmpty)
    }

    func testStaleWebKitSnapshotPreservesNewerResponseCookie() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let existingCookie = makeCookie(name: "existing", value: "one")
        synchronize(jar, fromWebKit: [existingCookie])

        let staleSnapshotTicket = jar.beginWebKitSnapshot()
        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "response=new; Path=/; HttpOnly"
            ],
            url: apiURL
        )

        // This snapshot was captured before the response cookie was written.
        XCTAssertTrue(
            jar.synchronizeFromWebKit(
                [existingCookie],
                snapshotTicket: staleSnapshotTicket
            )
        )
        XCTAssertEqual(
            Set(jar.allCookies.map(\.name)),
            Set(["existing", "response"])
        )

        let responseCookie = try XCTUnwrap(
            jar.allCookies.first { $0.name == "response" }
        )
        let olderSnapshotTicket = jar.beginWebKitSnapshot()
        synchronize(
            jar,
            fromWebKit: [existingCookie, responseCookie]
        )

        // A callback from an older snapshot cannot undo the newer one.
        XCTAssertFalse(
            jar.synchronizeFromWebKit(
                [existingCookie],
                snapshotTicket: olderSnapshotTicket
            )
        )
        XCTAssertEqual(
            Set(jar.allCookies.map(\.name)),
            Set(["existing", "response"])
        )

        // Once the bridge has mirrored the response cookie into WebKit, a new
        // snapshot that omits it propagates the deletion back to the native jar.
        completeWebKitFlush(jar)
        synchronize(jar, fromWebKit: [existingCookie])
        XCTAssertEqual(jar.allCookies.map(\.name), ["existing"])
    }

    func testServerDeletionRemovesNativeCookieAndCreatesWebKitTombstone() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let sessionCookie = makeCookie(
            name: "session",
            value: "authenticated"
        )
        synchronize(jar, fromWebKit: [sessionCookie])

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )

        XCTAssertTrue(jar.allCookies.isEmpty)
        let deletionCookie = try XCTUnwrap(
            jar.webKitCookiesToDelete.first
        )
        XCTAssertEqual(deletionCookie.name, "session")
        XCTAssertEqual(deletionCookie.value, "authenticated")
    }

    func testSnapshotStartedBeforeServerDeletionCannotResurrectCookie() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let sessionCookie = makeCookie(
            name: "session",
            value: "authenticated"
        )
        synchronize(jar, fromWebKit: [sessionCookie])
        let staleSnapshotTicket = jar.beginWebKitSnapshot()

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )

        XCTAssertTrue(
            jar.synchronizeFromWebKit(
                [sessionCookie],
                snapshotTicket: staleSnapshotTicket
            )
        )
        XCTAssertTrue(jar.allCookies.isEmpty)
        XCTAssertEqual(jar.webKitCookiesToDelete.map(\.name), ["session"])

        // This ordered post-mutation snapshot confirms that WebKit observed
        // the bridge deletion and releases the tombstone.
        completeWebKitFlush(jar)
        synchronize(jar, fromWebKit: [])
        XCTAssertTrue(jar.allCookies.isEmpty)
        XCTAssertTrue(jar.webKitCookiesToDelete.isEmpty)
    }

    /// A snapshot reserved *after* the response still cannot be trusted until
    /// the bridge has mirrored the mutation, because its WebKit read may have
    /// been served before the delete/set pair landed.
    func testSnapshotReservedAfterServerDeletionCannotResurrectBeforeFlush() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let sessionCookie = makeCookie(
            name: "session",
            value: "authenticated"
        )
        synchronize(jar, fromWebKit: [sessionCookie])

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        XCTAssertTrue(jar.isAwaitingWebKitFlush)

        // Reserved after the response, but read before the mirror was applied,
        // so WebKit still reports the cookie.
        XCTAssertTrue(
            jar.synchronizeFromWebKit(
                [sessionCookie],
                snapshotTicket: jar.beginWebKitSnapshot()
            )
        )
        XCTAssertTrue(jar.allCookies.isEmpty)
        XCTAssertEqual(jar.webKitCookiesToDelete.map(\.name), ["session"])

        // A snapshot still in flight when the mirror completed is also ignored.
        let inFlightTicket = jar.beginWebKitSnapshot()
        completeWebKitFlush(jar)
        XCTAssertFalse(jar.isAwaitingWebKitFlush)
        XCTAssertTrue(
            jar.synchronizeFromWebKit(
                [sessionCookie],
                snapshotTicket: inFlightTicket
            )
        )
        XCTAssertTrue(jar.allCookies.isEmpty)

        // Only a snapshot reserved after the mirror releases the barrier.
        synchronize(jar, fromWebKit: [])
        XCTAssertTrue(jar.allCookies.isEmpty)
        XCTAssertTrue(jar.webKitCookiesToDelete.isEmpty)
    }

    /// Once the mirror has been applied WebKit is authoritative again: a cookie
    /// the page legitimately re-created after the server deletion comes back
    /// rather than being suppressed forever.
    func testWebKitBecomesAuthoritativeAgainAfterTheFlush() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let sessionCookie = makeCookie(
            name: "session",
            value: "authenticated"
        )
        synchronize(jar, fromWebKit: [sessionCookie])
        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        completeWebKitFlush(jar)

        let recreated = makeCookie(name: "session", value: "recreated")
        synchronize(jar, fromWebKit: [recreated])

        XCTAssertEqual(jar.allCookies.map(\.value), ["recreated"])
        XCTAssertTrue(jar.webKitCookiesToDelete.isEmpty)
    }

    func testWebKitDeletionOfNewResponseCookieAfterFlushRemovesNativeCookie() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        synchronize(jar, fromWebKit: [])

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=new; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        XCTAssertEqual(jar.allCookies.map(\.value), ["new"])

        completeWebKitFlush(jar)
        synchronize(jar, fromWebKit: [])

        XCTAssertTrue(jar.allCookies.isEmpty)
        var request = URLRequest(url: apiURL)
        jar.prepare(&request, for: apiURL)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testEarlierFlushCannotReleaseLaterResponseMutation() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let firstCookie = makeCookie(name: "first", value: "old")
        let secondCookie = makeCookie(name: "second", value: "old")
        synchronize(jar, fromWebKit: [firstCookie, secondCookie])

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "first=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        let firstFlush = jar.makeWebKitFlush()

        // A second response lands while the first response's WebKit mirror is
        // suspended. Its mutation is not present in firstFlush.
        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "second=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )

        jar.completeWebKitFlush(firstFlush)

        // WebKit still contains the second cookie because its own mirror has
        // not completed. The earlier flush must not release this barrier.
        synchronize(jar, fromWebKit: [secondCookie])
        XCTAssertFalse(jar.allCookies.contains { $0.name == "second" })
        XCTAssertTrue(
            jar.webKitCookiesToDelete.contains { $0.name == "second" }
        )
        XCTAssertTrue(jar.isAwaitingWebKitFlush)

        completeWebKitFlush(jar)
        synchronize(jar, fromWebKit: [])
        XCTAssertFalse(jar.isAwaitingWebKitFlush)
        XCTAssertTrue(jar.allCookies.isEmpty)
        XCTAssertTrue(jar.webKitCookiesToDelete.isEmpty)
    }

    func testEarlierDeletionFlushCannotReleaseLaterReplacement() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let oldCookie = makeCookie(name: "session", value: "old")
        synchronize(jar, fromWebKit: [oldCookie])

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        let deletionFlush = jar.makeWebKitFlush()

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=new; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        let replacementCookie = try XCTUnwrap(jar.allCookies.first)

        // Completing the earlier delete does not release the replacement's
        // barrier. WebKit can still be empty until the queued replacement lands.
        jar.completeWebKitFlush(deletionFlush)
        synchronize(jar, fromWebKit: [])
        XCTAssertEqual(jar.allCookies.map(\.value), ["new"])
        XCTAssertTrue(jar.isAwaitingWebKitFlush)

        completeWebKitFlush(jar)
        synchronize(jar, fromWebKit: [replacementCookie])
        XCTAssertEqual(jar.allCookies.map(\.value), ["new"])
        XCTAssertFalse(jar.isAwaitingWebKitFlush)
    }

    func testStaleSnapshotCannotOverwriteResponseReplacement() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        let oldCookie = makeCookie(name: "session", value: "old")
        synchronize(jar, fromWebKit: [oldCookie])
        let staleSnapshotTicket = jar.beginWebKitSnapshot()

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=new; Path=/; HttpOnly"
            ],
            url: apiURL
        )

        XCTAssertTrue(
            jar.synchronizeFromWebKit(
                [oldCookie],
                snapshotTicket: staleSnapshotTicket
            )
        )
        XCTAssertEqual(jar.allCookies.first?.value, "new")

        let newCookie = try XCTUnwrap(jar.allCookies.first)
        synchronize(jar, fromWebKit: [newCookie])
        XCTAssertEqual(jar.allCookies.first?.value, "new")
    }

    func testLatestResponseWinsForDeleteAndReplacementSequences() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        synchronize(jar, fromWebKit: [
            makeCookie(name: "session", value: "initial")
        ])

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=replacement; Path=/; HttpOnly"
            ],
            url: apiURL
        )

        XCTAssertEqual(jar.allCookies.first?.value, "replacement")
        XCTAssertTrue(jar.webKitCookiesToDelete.isEmpty)

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=newer; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )

        XCTAssertTrue(jar.allCookies.isEmpty)
        XCTAssertEqual(jar.webKitCookiesToDelete.map(\.name), ["session"])
    }

    func testPreparedRequestExcludesServerDeletedCookie() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        synchronize(jar, fromWebKit: [
            makeCookie(name: "session", value: "authenticated")
        ])
        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )
        var request = URLRequest(url: apiURL)

        jar.prepare(&request, for: apiURL)

        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testDeletionLeavesIndependentDomainAndPathIdentitiesUntouched() throws {
        let jar = try ApproovWebViewNativeCookieJar()
        synchronize(jar, fromWebKit: [
            makeCookie(name: "session", value: "root"),
            makeCookie(
                name: "session",
                value: "scoped",
                path: "/account"
            ),
            makeCookie(
                name: "session",
                value: "other-domain",
                domain: "other.example.com"
            )
        ])

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
        )

        XCTAssertEqual(
            Set(jar.allCookies.map { "\($0.domain)\($0.path)=\($0.value)" }),
            Set([
                "api.example.com/account=scoped",
                "other.example.com/=other-domain"
            ])
        )
        XCTAssertEqual(jar.webKitCookiesToDelete.count, 1)
        XCTAssertEqual(jar.webKitCookiesToDelete.first?.path, "/")
    }

    func testConcurrentMixedResponsesDoNotResurrectDeletedCookies() async throws {
        CookieResponseURLProtocol.reset()
        let jar = try ApproovWebViewNativeCookieJar()
        let initialWebKitCookies = [
            makeCookie(name: "replacement", value: "initial"),
            makeCookie(name: "delete-me", value: "authenticated"),
            makeCookie(name: "expire-me", value: "authenticated")
        ]
        synchronize(jar, fromWebKit: initialWebKitCookies)
        let staleSnapshotTicket = jar.beginWebKitSnapshot()
        jar.sessionConfiguration.protocolClasses = [
            CookieResponseURLProtocol.self
        ]
        let session = URLSession(configuration: jar.sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let harness = NativeCookieHarness(jar: jar)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let url = URL(
                        string: "https://api.example.com/request/\(index)"
                    )!
                    var request = await harness.prepareRequest(for: url)
                    request.setValue(
                        request.value(forHTTPHeaderField: "Cookie") ?? "<none>",
                        forHTTPHeaderField: "X-Test-Expected-Cookie"
                    )
                    let (_, response) = try await session.data(for: request)
                    let httpResponse = try XCTUnwrap(
                        response as? HTTPURLResponse
                    )
                    await harness.storeResponse(httpResponse)
                }
            }

            try await group.waitForAll()
        }

        // A WebKit read that began before the responses cannot reintroduce
        // either deleted cookie or restore the old replacement value.
        let appliedStaleSnapshot = await harness.synchronizeFromWebKit(
            initialWebKitCookies,
            snapshotTicket: staleSnapshotTicket
        )
        XCTAssertTrue(appliedStaleSnapshot)
        var cookies = await harness.allCookies()
        XCTAssertEqual(cookies.count, 98)
        XCTAssertEqual(Set(cookies.map(\.name)).count, 98)
        XCTAssertEqual(
            cookies.first { $0.name == "replacement" }?.value,
            "value99"
        )
        XCTAssertFalse(cookies.contains { $0.name == "delete-me" })
        XCTAssertFalse(cookies.contains { $0.name == "expire-me" })
        let pendingDeletionNames = Set(
            await harness.webKitCookiesToDelete().map(\.name)
        )
        XCTAssertEqual(pendingDeletionNames, Set(["delete-me", "expire-me"]))

        // Simulate the ordered WebKit delete/set round trip and its following
        // snapshot. This confirms the barriers and tombstones are released
        // without resurrecting either server-deleted identity.
        await harness.completeWebKitFlush()
        let appliedConfirmation = await harness.synchronizeFromWebKit(cookies)
        XCTAssertTrue(appliedConfirmation)
        cookies = await harness.allCookies()
        XCTAssertEqual(cookies.count, 98)
        XCTAssertFalse(cookies.contains { $0.name == "delete-me" })
        XCTAssertFalse(cookies.contains { $0.name == "expire-me" })
        let pendingDeletionsAfterConfirmation =
            await harness.webKitCookiesToDelete()
        XCTAssertTrue(pendingDeletionsAfterConfirmation.isEmpty)

        let preparedRequest = await harness.prepareRequest(for: apiURL)
        let finalCookieHeader = preparedRequest.value(
            forHTTPHeaderField: "Cookie"
        ) ?? ""
        XCTAssertFalse(finalCookieHeader.contains("delete-me="))
        XCTAssertFalse(finalCookieHeader.contains("expire-me="))
        XCTAssertTrue(finalCookieHeader.contains("replacement=value99"))

        XCTAssertEqual(CookieResponseURLProtocol.requestCount, 100)
        XCTAssertGreaterThan(CookieResponseURLProtocol.maximumConcurrentCount, 1)
        XCTAssertTrue(
            CookieResponseURLProtocol.observedRequests.allSatisfy {
                let expectedCookieHeader = $0.value(
                    forHTTPHeaderField: "X-Test-Expected-Cookie"
                )
                let observedCookieHeader = $0.value(
                    forHTTPHeaderField: "Cookie"
                ) ?? "<none>"
                return !$0.httpShouldHandleCookies
                    && observedCookieHeader == expectedCookieHeader
            }
        )
    }

    private func makeCookie(
        name: String,
        value: String,
        domain: String = "api.example.com",
        path: String = "/"
    ) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
            .secure: "TRUE"
        ])!
    }

    private func synchronize(
        _ jar: ApproovWebViewNativeCookieJar,
        fromWebKit cookies: [HTTPCookie]
    ) {
        let snapshotTicket = jar.beginWebKitSnapshot()
        XCTAssertTrue(
            jar.synchronizeFromWebKit(
                cookies,
                snapshotTicket: snapshotTicket
            )
        )
    }

    private func completeWebKitFlush(
        _ jar: ApproovWebViewNativeCookieJar
    ) {
        let flush = jar.makeWebKitFlush()
        jar.completeWebKitFlush(flush)
    }
}

private actor NativeCookieHarness {
    private let jar: ApproovWebViewNativeCookieJar

    init(jar: ApproovWebViewNativeCookieJar) {
        self.jar = jar
    }

    func prepareRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        jar.prepare(&request, for: url)
        return request
    }

    func storeResponse(_ response: HTTPURLResponse) {
        guard let url = response.url else {
            return
        }

        jar.storeResponseCookies(
            fromResponseHeaders: response.allHeaderFields,
            url: url
        )
    }

    func allCookies() -> [HTTPCookie] {
        jar.allCookies
    }

    func webKitCookiesToDelete() -> [HTTPCookie] {
        jar.webKitCookiesToDelete
    }

    func completeWebKitFlush() {
        let flush = jar.makeWebKitFlush()
        jar.completeWebKitFlush(flush)
    }

    func synchronizeFromWebKit(
        _ cookies: [HTTPCookie],
        snapshotTicket: UInt64? = nil
    ) -> Bool {
        jar.synchronizeFromWebKit(
            cookies,
            snapshotTicket: snapshotTicket ?? jar.beginWebKitSnapshot()
        )
    }
}

private final class CookieResponseURLProtocol: URLProtocol {
    private static let stateLock = NSLock()
    private static var requests: [URLRequest] = []
    private static var activeRequestCount = 0
    private static var maximumActiveRequestCount = 0

    static var observedRequests: [URLRequest] {
        stateLock.withLock { requests }
    }

    static var requestCount: Int {
        stateLock.withLock { requests.count }
    }

    static var maximumConcurrentCount: Int {
        stateLock.withLock { maximumActiveRequestCount }
    }

    static func reset() {
        stateLock.withLock {
            requests = []
            activeRequestCount = 0
            maximumActiveRequestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.stateLock.withLock {
            Self.requests.append(request)
            Self.activeRequestCount += 1
            Self.maximumActiveRequestCount = max(
                Self.maximumActiveRequestCount,
                Self.activeRequestCount
            )
        }

        guard let url = request.url,
              let index = Int(url.lastPathComponent) else {
            Self.finishRequest()
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Set-Cookie": Self.responseCookieHeader(for: index)
            ]
        )!

        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(5 + index % 5)
        ) { [weak self] in
            guard let self else {
                return
            }

            Self.finishRequest()
            self.client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            self.client?.urlProtocol(self, didLoad: Data())
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func finishRequest() {
        stateLock.withLock {
            activeRequestCount -= 1
        }
    }

    private static func responseCookieHeader(for index: Int) -> String {
        switch index {
        case 96:
            return "delete-me=; Max-Age=0; Path=/; HttpOnly"
        case 97:
            return """
            expire-me=gone; Expires=Thu, 01 Jan 1970 00:00:00 GMT; \
            Path=/; HttpOnly
            """
        case 99:
            return "replacement=value99; Path=/; HttpOnly"
        default:
            return "cookie\(index)=value\(index); Path=/; HttpOnly"
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

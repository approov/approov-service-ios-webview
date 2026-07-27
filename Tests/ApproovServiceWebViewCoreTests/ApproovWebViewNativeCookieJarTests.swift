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

    func testStoresReplacesAndDeletesResponseCookies() throws {
        let jar = try ApproovWebViewNativeCookieJar()

        XCTAssertEqual(
            jar.storeResponseCookies(
                fromResponseHeaders: [
                    "Set-Cookie": "session=abc123; Path=/; HttpOnly"
                ],
                url: apiURL
            ),
            1
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

        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "session=; Max-Age=0; Path=/; HttpOnly"
            ],
            url: apiURL
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

        // Once WebKit has observed the response cookie, a new snapshot that
        // omits it propagates the deletion back to the native jar.
        synchronize(jar, fromWebKit: [existingCookie])
        XCTAssertEqual(jar.allCookies.map(\.name), ["existing"])
    }

    func testConcurrentTransportKeepsCookieJarOutOfCFNetwork() async throws {
        CookieResponseURLProtocol.reset()
        let jar = try ApproovWebViewNativeCookieJar()
        jar.storeResponseCookies(
            fromResponseHeaders: [
                "Set-Cookie": "replacement=initial; Path=/; HttpOnly"
            ],
            url: apiURL
        )
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

        let cookies = await harness.allCookies()
        XCTAssertEqual(cookies.count, 100)
        XCTAssertEqual(Set(cookies.map(\.name)).count, 100)
        XCTAssertEqual(
            cookies.first { $0.name == "replacement" }?.value,
            "value99"
        )
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
                "Set-Cookie": index == 99
                    ? "replacement=value99; Path=/; HttpOnly"
                    : "cookie\(index)=value\(index); Path=/; HttpOnly"
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
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

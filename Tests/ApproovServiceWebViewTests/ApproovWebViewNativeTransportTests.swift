import ApproovURLSessionPackage
import Foundation
import Network
import WebKit
import XCTest
@testable import ApproovServiceWebView
@testable import ApproovServiceWebViewCore

/// Real loopback sockets and the production ApproovURLSession delegate path.
/// Only bootstrap and signing are substituted. No account or cloud is used.
@MainActor
final class ApproovWebViewNativeTransportTests: XCTestCase {
    private func executor(_ server: LoopbackServer, limit: Int = 1024, duration: TimeInterval = 5) throws -> ApproovWebViewRequestExecutor {
        let configuration = ApproovWebViewConfiguration(approovConfig: "local-fixture",
            protectedEndpoints: [.init(scheme: "http", host: "127.0.0.1", pathPrefix: "/", port: Int(server.port))],
            allowedOrigins: [server.origin], maximumResponseBodyBytes: limit,
            maximumRequestDuration: duration, debugLoggingEnabled: false)
        return try ApproovWebViewRequestExecutor(configuration: configuration,
            cookieBridge: ApproovWebViewCookieBridge(store: WKWebsiteDataStore.nonPersistent().httpCookieStore),
            testTransport: .init(bootstrap: {}, signer: { request in
                var signed = request
                signed.setValue("synthetic-fixture-token", forHTTPHeaderField: "approov-token")
                return signed
            }, send: { _ in
                XCTFail("This fixture must use the production native transport")
                throw URLError(.unknown)
            }, usesNativeTransport: true))
    }

    private func request(_ server: LoopbackServer, path: String) throws -> ApproovWebViewProxyRequest {
        let body: [String: Any] = ["url": server.origin + path, "method": "GET", "headers": [:],
            "credentials": "omit", "mode": "same-origin", "responseHandling": "response", "requestSource": "fetch"]
        return try JSONDecoder().decode(ApproovWebViewProxyRequest.self,
            from: JSONSerialization.data(withJSONObject: body))
    }

    private func context(_ server: LoopbackServer) -> ApproovWebViewRequestContext {
        let page = URL(string: server.origin + "/page")!
        return .init(frameURL: page, frameOrigin: server.origin, mainDocumentURL: page, isMainFrame: true)
    }

    func testProductionDelegateDeliversResponseBytes() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let result = try await executor(server).execute(request(server, path: "/small"), context: context(server))
        guard case let .response(response) = result else { return XCTFail("Expected readable response") }
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(Data(base64Encoded: response.bodyBase64), Data("synthetic".utf8))
    }

    func testContentLengthRejectsOversizedResponseBeforeAccumulation() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        do {
            _ = try await executor(server).execute(request(server, path: "/large"), context: context(server))
            XCTFail("Expected the response limit")
        } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
    }

    func testChunkedResponseCannotExceedTheBufferLimit() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        do {
            _ = try await executor(server).execute(request(server, path: "/chunked"), context: context(server))
            XCTFail("Expected the streamed-byte limit")
        } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
    }

    func testCancellationReachesAnOutstandingNativeTask() async throws {
        let started = expectation(description: "loopback request arrived")
        let server = try await LoopbackServer.start(onStall: { started.fulfill() })
        defer { server.stop() }
        let executor = try executor(server)
        let request = try request(server, path: "/stall")
        let context = context(server)
        let work = Task { try await executor.execute(request, context: context) }
        await fulfillment(of: [started], timeout: 5)
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
    }

    func testResourceDeadlineTerminatesAStalledResponse() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        do {
            _ = try await executor(server, duration: 0.3).execute(request(server, path: "/stall"), context: context(server))
            XCTFail("Expected a resource timeout")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    }

    func testEventStreamsAreExplicitlyUnsupported() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        do {
            _ = try await executor(server).execute(request(server, path: "/events"), context: context(server))
            XCTFail("Expected refusal of an unbounded event stream")
        } catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
    }

    func testSigningMarkerSurvivesTaskConstructionWithoutDisablingPinning() throws {
        let previous = ApproovService.getServiceMutator()
        let configuration = ApproovWebViewConfiguration(approovConfig: "fixture",
            protectedEndpoints: [.init(host: "api.example.com", pathPrefix: "/")],
            allowedOrigins: ["https://shop.example.com"])
        ApproovWebViewServiceMutator.installOrUpdateScope(scopeID: "native-marker-fixture", configuration: configuration)
        defer {
            ApproovWebViewServiceMutator.removeScope("native-marker-fixture")
            ApproovService.setServiceMutator(previous)
        }
        var request = URLRequest(url: URL(string: "https://api.example.com/data")!)
        ApproovWebViewServiceMutator.setWebViewScope("native-marker-fixture", on: &request)
        ApproovWebViewServiceMutator.markAlreadySigned(&request)
        let session = ApproovURLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        defer { task.cancel() }
        let current = try XCTUnwrap(task.currentRequest)
        XCTAssertFalse(try ApproovService.getServiceMutator().handleInterceptorShouldProcessRequest(current))
        XCTAssertTrue(ApproovService.getServiceMutator().handlePinningShouldProcessRequest(current))
    }
}

private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ApproovWebView.loopback-test")
    private var connections: [NWConnection] = []
    private var ready: ((Result<Void, Error>) -> Void)?
    private let onStall: () -> Void
    var port: UInt16 { listener.port!.rawValue }
    var origin: String { "http://127.0.0.1:\(port)" }

    private init(onStall: @escaping () -> Void) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.onStall = onStall
    }

    static func start(onStall: @escaping () -> Void = {}) async throws -> LoopbackServer {
        let server = try LoopbackServer(onStall: onStall)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.ready = { continuation.resume(with: $0) }
            server.listener.stateUpdateHandler = { [weak server] state in
                guard let server else { return }
                switch state {
                case .ready:
                    let done = server.ready; server.ready = nil; done?(.success(()))
                case let .failed(error):
                    let done = server.ready; server.ready = nil; done?(.failure(error))
                default: break
                }
            }
            server.listener.newConnectionHandler = { [weak server] connection in
                guard let server else { connection.cancel(); return }
                server.connections.append(connection)
                connection.start(queue: server.queue)
                server.receive(connection, request: Data())
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func receive(_ connection: NWConnection, request: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = request
            if let data { accumulated.append(data) }
            guard accumulated.count <= 64 * 1024 else { connection.cancel(); return }
            if let text = String(data: accumulated, encoding: .utf8), text.contains("\r\n\r\n") {
                let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.respond(connection, path: path)
            } else if error == nil && !complete { self.receive(connection, request: accumulated) }
            else { connection.cancel() }
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        if path == "/stall" {
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in self.onStall() })
            return
        }
        if path == "/events" {
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            return
        }
        let body = path == "/small" ? Data("synthetic".utf8) : Data(repeating: 65, count: 32 * 1024)
        var response: Data
        if path == "/chunked" {
            response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
            response.append(Data(String(body.count, radix: 16).utf8)); response.append(Data("\r\n".utf8))
            response.append(body); response.append(Data("\r\n0\r\n\r\n".utf8))
        } else {
            response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
        }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

import WebKit
import XCTest
@testable import ApproovServiceWebView

final class ApproovWebViewFactoryTests: XCTestCase {
    @MainActor
    func testMakeWebViewWithoutInitialContentCreatesProtectedWebView() {
        let webView = ApproovWebViewFactory.makeWebView(
            configuration: makeConfiguration()
        )

        XCTAssertNil(webView.url)
        XCTAssertEqual(
            webView.configuration.userContentController.userScripts.count,
            1
        )
    }

    @MainActor
    func testMakeWebViewLoadsInitialRequestThroughWebKitWhenProtectionDisabled() async {
        let webView = makeRecordingWebView()
        let loadExpectation = expectation(description: "initial request loaded through WebKit")
        webView.onLoad = { loadExpectation.fulfill() }

        let request = URLRequest(url: URL(string: "https://api.example.com/v1/items")!)
        _ = ApproovWebViewFactory.makeWebView(
            content: .request(request),
            configuration: makeConfiguration(),
            baseWebView: webView
        )

        await fulfillment(of: [loadExpectation], timeout: 1.0)
        XCTAssertEqual(webView.loadedRequests.count, 1)
        XCTAssertEqual(webView.simulatedNavigationLoads.count, 0)
    }

    @MainActor
    func testMakeWebViewLoadsInitialRequestThroughWebKitWhenOutsideProtectedScope() async {
        let originalFactory = ApproovWebViewCoordinator.requestExecutorFactory
        let executor = StubRequestExecutor(
            result: .success(makeNavigationLoad(urlString: "https://api.example.com/v1/items"))
        )
        ApproovWebViewCoordinator.requestExecutorFactory = { _, _ in executor }
        defer {
            ApproovWebViewCoordinator.requestExecutorFactory = originalFactory
        }

        let webView = makeRecordingWebView()
        let loadExpectation = expectation(description: "unmatched initial request loaded through WebKit")
        webView.onLoad = { loadExpectation.fulfill() }

        let request = URLRequest(url: URL(string: "https://api.example.com/public")!)
        _ = ApproovWebViewFactory.makeWebView(
            content: .request(request),
            configuration: makeConfiguration(protectInitialNavigation: true),
            baseWebView: webView
        )

        await fulfillment(of: [loadExpectation], timeout: 1.0)
        XCTAssertEqual(webView.loadedRequests.count, 1)
        XCTAssertEqual(webView.simulatedNavigationLoads.count, 0)
        XCTAssertEqual(await executor.initialNavigationExecutionCount(), 0)
    }

    @MainActor
    func testMakeWebViewUsesProtectedInitialNavigationWhenEnabledAndMatched() async {
        let originalFactory = ApproovWebViewCoordinator.requestExecutorFactory
        let executor = StubRequestExecutor(
            result: .success(makeNavigationLoad(urlString: "https://api.example.com/v1/items"))
        )
        ApproovWebViewCoordinator.requestExecutorFactory = { _, _ in executor }
        defer {
            ApproovWebViewCoordinator.requestExecutorFactory = originalFactory
        }

        let webView = makeRecordingWebView()
        let simulatedLoadExpectation = expectation(description: "initial request loaded through simulated navigation")
        webView.onSimulatedLoad = { simulatedLoadExpectation.fulfill() }

        let request = URLRequest(url: URL(string: "https://api.example.com/v1/items")!)
        _ = ApproovWebViewFactory.makeWebView(
            content: .request(request),
            configuration: makeConfiguration(protectInitialNavigation: true),
            baseWebView: webView
        )

        await fulfillment(of: [simulatedLoadExpectation], timeout: 1.0)
        XCTAssertEqual(webView.loadedRequests.count, 0)
        XCTAssertEqual(webView.simulatedNavigationLoads.count, 1)
        XCTAssertEqual(await executor.initialNavigationExecutionCount(), 1)
    }

    @MainActor
    func testMakeWebViewFallsBackToWebKitWhenProtectedInitialNavigationFails() async {
        let originalFactory = ApproovWebViewCoordinator.requestExecutorFactory
        let executor = StubRequestExecutor(
            result: .failure(StubExecutorError.initialNavigationFailed)
        )
        ApproovWebViewCoordinator.requestExecutorFactory = { _, _ in executor }
        defer {
            ApproovWebViewCoordinator.requestExecutorFactory = originalFactory
        }

        let webView = makeRecordingWebView()
        let loadExpectation = expectation(description: "failed protected initial request fell back to WebKit")
        webView.onLoad = { loadExpectation.fulfill() }

        let request = URLRequest(url: URL(string: "https://api.example.com/v1/items")!)
        _ = ApproovWebViewFactory.makeWebView(
            content: .request(request),
            configuration: makeConfiguration(protectInitialNavigation: true),
            baseWebView: webView
        )

        await fulfillment(of: [loadExpectation], timeout: 1.0)
        XCTAssertEqual(webView.loadedRequests.count, 1)
        XCTAssertEqual(webView.simulatedNavigationLoads.count, 0)
        XCTAssertEqual(await executor.initialNavigationExecutionCount(), 1)
    }

    @MainActor
    func testMakeWebViewKeepsHTMLStringPathUnchangedWhenInitialProtectionEnabled() {
        let webView = makeRecordingWebView()
        _ = ApproovWebViewFactory.makeWebView(
            content: .htmlString("<html><body>hello</body></html>", baseURL: nil),
            configuration: makeConfiguration(protectInitialNavigation: true),
            baseWebView: webView
        )

        XCTAssertEqual(webView.loadedHTMLStrings.count, 1)
        XCTAssertEqual(webView.loadedRequests.count, 0)
        XCTAssertEqual(webView.simulatedNavigationLoads.count, 0)
    }

    @MainActor
    func testMakeWebViewKeepsFileURLPathUnchangedWhenInitialProtectionEnabled() {
        let webView = makeRecordingWebView()
        let fileURL = URL(fileURLWithPath: "/tmp/example.html")
        let readAccessURL = URL(fileURLWithPath: "/tmp")

        _ = ApproovWebViewFactory.makeWebView(
            content: .fileURL(fileURL, allowingReadAccessTo: readAccessURL),
            configuration: makeConfiguration(protectInitialNavigation: true),
            baseWebView: webView
        )

        XCTAssertEqual(webView.loadedFileURLs.count, 1)
        XCTAssertEqual(webView.loadedRequests.count, 0)
        XCTAssertEqual(webView.simulatedNavigationLoads.count, 0)
    }

    @MainActor
    func testMakeWebViewReusesProvidedBaseWebView() {
        let baseConfiguration = WKWebViewConfiguration()
        baseConfiguration.userContentController = WKUserContentController()
        baseConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true

        let baseWebView = WKWebView(
            frame: .zero,
            configuration: baseConfiguration
        )

        let configuredWebView = ApproovWebViewFactory.makeWebView(
            configuration: makeConfiguration(),
            baseWebView: baseWebView
        )

        XCTAssertTrue(configuredWebView === baseWebView)
        XCTAssertEqual(
            configuredWebView.configuration.userContentController.userScripts.count,
            1
        )
    }

    @MainActor
    func testInstallDoesNotDuplicateBridgeScriptOnSameWebView() {
        let configuration = makeConfiguration()
        let webView = ApproovWebViewFactory.makeWebView(
            configuration: configuration
        )

        XCTAssertEqual(
            webView.configuration.userContentController.userScripts.count,
            1
        )

        ApproovWebViewFactory.install(
            on: webView,
            configuration: configuration
        )

        XCTAssertEqual(
            webView.configuration.userContentController.userScripts.count,
            1
        )
    }

    private func makeConfiguration(
        protectInitialNavigation: Bool = false
    ) -> ApproovWebViewConfiguration {
        ApproovWebViewConfiguration(
            approovConfig: "config",
            protectedEndpoints: [
                ApproovWebViewProtectedEndpoint(
                    host: "api.example.com",
                    pathPrefix: "/v1"
                )
            ],
            protectInitialNavigation: protectInitialNavigation
        )
    }

    @MainActor
    private func makeRecordingWebView() -> RecordingWKWebView {
        let baseConfiguration = WKWebViewConfiguration()
        baseConfiguration.userContentController = WKUserContentController()
        baseConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true

        return RecordingWKWebView(
            frame: .zero,
            configuration: baseConfiguration
        )
    }

    private func makeNavigationLoad(urlString: String) -> ApproovWebViewNavigationLoad {
        let url = URL(string: urlString)!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        )!
        return ApproovWebViewNavigationLoad(
            request: URLRequest(url: url),
            response: response,
            data: Data("<html></html>".utf8)
        )
    }
}

private final class RecordingWKWebView: WKWebView {
    var onLoad: (() -> Void)?
    var onSimulatedLoad: (() -> Void)?
    private(set) var loadedRequests: [URLRequest] = []
    private(set) var loadedHTMLStrings: [String] = []
    private(set) var loadedFileURLs: [URL] = []
    private(set) var simulatedNavigationLoads: [
        (request: URLRequest, response: URLResponse, data: Data)
    ] = []

    override func load(_ request: URLRequest) -> WKNavigation? {
        loadedRequests.append(request)
        onLoad?()
        return nil
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        loadedHTMLStrings.append(string)
        return nil
    }

    override func loadFileURL(
        _ URL: URL,
        allowingReadAccessTo readAccessURL: URL
    ) -> WKNavigation? {
        loadedFileURLs.append(URL)
        return nil
    }

    override func loadSimulatedRequest(
        _ request: URLRequest,
        response: URLResponse,
        responseData data: Data
    ) -> WKNavigation? {
        simulatedNavigationLoads.append((request: request, response: response, data: data))
        onSimulatedLoad?()
        return nil
    }
}

private actor StubRequestExecutor: ApproovWebViewRequestExecuting {
    enum Result {
        case success(ApproovWebViewNavigationLoad)
        case failure(Error)
    }

    private let result: Result
    private var initialNavigationCount = 0

    init(result: Result) {
        self.result = result
    }

    func execute(_ proxyRequest: ApproovWebViewProxyRequest) async throws -> ApproovWebViewExecutionResult {
        throw StubExecutorError.unexpectedProxyExecution
    }

    func executeInitialNavigation(_ request: URLRequest) async throws -> ApproovWebViewNavigationLoad {
        initialNavigationCount += 1

        switch result {
        case let .success(navigationLoad):
            return navigationLoad
        case let .failure(error):
            throw error
        }
    }

    func initialNavigationExecutionCount() -> Int {
        initialNavigationCount
    }
}

private enum StubExecutorError: LocalizedError {
    case initialNavigationFailed
    case unexpectedProxyExecution

    var errorDescription: String? {
        switch self {
        case .initialNavigationFailed:
            return "Initial navigation failed"
        case .unexpectedProxyExecution:
            return "Unexpected proxy execution"
        }
    }
}

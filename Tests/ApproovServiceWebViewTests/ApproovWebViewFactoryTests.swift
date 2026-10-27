import WebKit
import XCTest
@testable import ApproovServiceWebView

final class ApproovWebViewFactoryTests: XCTestCase {
    @MainActor
    func testMakeWebViewWithoutInitialContentCreatesProtectedWebView() throws {
        let webView = try ApproovWebViewFactory.makeWebView(
            configuration: makeConfiguration()
        )

        XCTAssertNil(webView.url)
        XCTAssertEqual(
            webView.configuration.userContentController.userScripts.count,
            1
        )
    }

    @MainActor
    func testMakeWebViewReusesProvidedBaseWebView() throws {
        let baseConfiguration = WKWebViewConfiguration()
        baseConfiguration.userContentController = WKUserContentController()
        baseConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true

        let baseWebView = WKWebView(
            frame: .zero,
            configuration: baseConfiguration
        )

        let configuredWebView = try ApproovWebViewFactory.makeWebView(
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
    func testInstallRejectsReinstallationWithoutChangingScript() throws {
        let configuration = makeConfiguration()
        let webView = try ApproovWebViewFactory.makeWebView(
            configuration: configuration
        )

        XCTAssertEqual(
            webView.configuration.userContentController.userScripts.count,
            1
        )

        XCTAssertThrowsError(try ApproovWebViewFactory.install(
            on: webView, configuration: configuration
        )) { error in
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .alreadyInstalled)
        }

        XCTAssertEqual(
            webView.configuration.userContentController.userScripts.count,
            1
        )
    }

    @MainActor
    func testSharedContentControllerIsRejectedBeforeMutation() throws {
        let controller = WKUserContentController()
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let first = WKWebView(frame: .zero, configuration: config)
        let second = WKWebView(frame: .zero, configuration: config)
        try ApproovWebViewFactory.install(on: first, configuration: makeConfiguration())
        XCTAssertThrowsError(try ApproovWebViewFactory.install(on: second, configuration: makeConfiguration())) { error in
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .contentControllerAlreadyInstalled)
        }
        XCTAssertEqual(controller.userScripts.count, 1)
    }

    @MainActor
    func testCoordinatorCannotBeReusedAcrossViews() throws {
        let configuration = makeConfiguration()
        let coordinator = ApproovWebViewFactory.makeCoordinator(configuration: configuration)
        let first = try ApproovWebViewFactory.makeWebView(configuration: configuration, coordinator: coordinator)
        let second = WKWebView()
        XCTAssertThrowsError(try ApproovWebViewFactory.install(on: second, configuration: configuration, coordinator: coordinator)) { error in
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .coordinatorAlreadyAttached)
        }
        XCTAssertEqual(second.configuration.userContentController.userScripts.count, 0)
        withExtendedLifetime(first) {}
    }

    private func makeConfiguration() -> ApproovWebViewConfiguration {
        ApproovWebViewConfiguration(
            approovConfig: "config",
            protectedEndpoints: [
                ApproovWebViewProtectedEndpoint(
                    host: "api.example.com",
                    pathPrefix: "/v1"
                )
            ],
            allowedOrigins: ["https://app.example.com"]
        )
    }
}

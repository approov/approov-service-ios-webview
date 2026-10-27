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
        baseConfiguration.websiteDataStore = .nonPersistent()

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
        let firstConfiguration = WKWebViewConfiguration()
        firstConfiguration.userContentController = controller
        firstConfiguration.websiteDataStore = .nonPersistent()
        let secondConfiguration = WKWebViewConfiguration()
        secondConfiguration.userContentController = controller
        secondConfiguration.websiteDataStore = .nonPersistent()
        let first = WKWebView(frame: .zero, configuration: firstConfiguration)
        let second = WKWebView(frame: .zero, configuration: secondConfiguration)
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

    @MainActor
    func testSharedDataStoreRejectedAndFactoryStoresAreIsolated() throws {
        let first = try ApproovWebViewFactory.makeWebView(configuration: makeConfiguration())
        let second = try ApproovWebViewFactory.makeWebView(configuration: makeConfiguration())
        XCTAssertFalse(first.configuration.websiteDataStore === second.configuration.websiteDataStore)
        XCTAssertFalse(first.configuration.websiteDataStore.isPersistent)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = first.configuration.websiteDataStore
        let third = WKWebView(frame: .zero, configuration: config)
        XCTAssertThrowsError(try ApproovWebViewFactory.install(on: third, configuration: makeConfiguration())) { error in
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .dataStoreAlreadyInUse)
        }
        XCTAssertEqual(third.configuration.userContentController.userScripts.count, 0)
    }

    @MainActor
    func testInvalidConfigurationIsRejectedBeforeWebKitMutation() throws {
        let configurations = [
            ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [], maximumConcurrentRequests: 0),
            ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [], maximumRequestBodyBytes: -1),
            ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: [], approovTokenHeaderName: "bad\r\nheader"),
            ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: ["https://user:password@app.example.com"]),
            ApproovWebViewConfiguration(approovConfig: "fixture", protectedEndpoints: [], allowedOrigins: ["https://app.example.com/path"])
        ]
        for configuration in configurations {
            let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            XCTAssertThrowsError(try ApproovWebViewFactory.install(on: view, configuration: configuration)) { error in
                guard let installationError = error as? ApproovWebViewInstallationError,
                      case .invalidConfiguration = installationError else {
                    return XCTFail("Expected configuration error, got \(error)")
                }
            }
            XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        }
    }

    @MainActor
    func testCoordinatorPolicyCannotDifferFromInstalledScriptPolicy() throws {
        let coordinator = ApproovWebViewFactory.makeCoordinator(configuration: makeConfiguration())
        let view = WKWebView()
        XCTAssertThrowsError(try ApproovWebViewFactory.install(on: view, configuration: makeConfiguration(), coordinator: coordinator)) { error in
            XCTAssertEqual(error as? ApproovWebViewInstallationError, .coordinatorConfigurationMismatch)
        }
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
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

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

    private func makeConfiguration() -> ApproovWebViewConfiguration {
        ApproovWebViewConfiguration(
            approovConfig: "config",
            protectedEndpoints: [
                ApproovWebViewProtectedEndpoint(
                    host: "api.example.com",
                    pathPrefix: "/v1"
                )
            ]
        )
    }
}

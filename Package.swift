// swift-tools-version:5.10
import PackageDescription

let approovURLSessionVersion = "3.5.6"
let approovSDKVersion = "3.5.3"

let package = Package(
    name: "approov-service-ios-webview",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "ApproovServiceWebView",
            targets: ["ApproovServiceWebView"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/approov/approov-service-urlsession.git",
            exact: Version(stringLiteral: approovURLSessionVersion)
        ),
        .package(
            url: "https://github.com/approov/approov-ios-sdk.git",
            exact: Version(stringLiteral: approovSDKVersion)
        )
    ],
    targets: [
        .target(
            name: "ApproovServiceWebViewCore",
            path: "Sources/ApproovServiceWebViewCore"
        ),
        .target(
            name: "ApproovServiceWebView",
            dependencies: [
                "ApproovServiceWebViewCore",
                .product(
                    name: "ApproovURLSession",
                    package: "approov-service-urlsession"
                ),
                .product(
                    name: "Approov",
                    package: "approov-ios-sdk"
                )
            ],
            path: "Sources/ApproovServiceWebView"
        ),
        .testTarget(
            name: "ApproovServiceWebViewTests",
            dependencies: [
                "ApproovServiceWebView",
                "ApproovServiceWebViewCore"
            ],
            path: "Tests/ApproovServiceWebViewTests"
        )
    ]
)

import UIKit
import XCTest

@MainActor
final class HostedEnvironmentTests: XCTestCase {
    func testUIKitApplicationOwnsTheTestProcess() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.approov.tests.WebViewTestHost")
        XCTAssertEqual(Bundle.main.bundleURL.pathExtension, "app")
        XCTAssertNotNil(UIApplication.shared.delegate)
        XCTAssertFalse(UIApplication.shared.connectedScenes.isEmpty)
    }
}

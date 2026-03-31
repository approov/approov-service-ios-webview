import XCTest
@testable import ApproovServiceWebView

final class ApproovWebViewSDKInitializationCoordinatorTests: XCTestCase {
    func testInitializeIfNeededOnlyInitializesOnceForSameConfig() async throws {
        let initializer = MockApproovSDKInitializer()
        let coordinator = ApproovWebViewSDKInitializationCoordinator(
            initializer: initializer
        )

        XCTAssertTrue(try await coordinator.initializeIfNeeded(config: "config"))
        XCTAssertFalse(try await coordinator.initializeIfNeeded(config: "config"))

        await MainActor.run {
            XCTAssertEqual(initializer.attemptedConfigs, ["config"])
            XCTAssertTrue(initializer.didRunOnMainActor)
        }
    }

    func testInitializeIfNeededRejectsDifferentConfigAfterInitialization() async throws {
        let initializer = MockApproovSDKInitializer()
        let coordinator = ApproovWebViewSDKInitializationCoordinator(
            initializer: initializer
        )

        XCTAssertTrue(try await coordinator.initializeIfNeeded(config: "config-a"))

        do {
            _ = try await coordinator.initializeIfNeeded(config: "config-b")
            XCTFail("Expected a configuration mismatch error")
        } catch let error as ApproovWebViewBridgeError {
            guard case .approovConfigMismatch = error else {
                XCTFail("Unexpected bridge error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInitializeIfNeededCachesInitializationFailureForSameConfig() async {
        let initializer = MockApproovSDKInitializer()
        let coordinator = ApproovWebViewSDKInitializationCoordinator(
            initializer: initializer
        )
        let expectedError = TestError.initializationFailed

        await MainActor.run {
            initializer.errorToThrow = expectedError
        }

        do {
            _ = try await coordinator.initializeIfNeeded(config: "config")
            XCTFail("Expected initialization to fail")
        } catch let error as TestError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await coordinator.initializeIfNeeded(config: "config")
            XCTFail("Expected initialization failure to be cached")
        } catch let error as TestError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await MainActor.run {
            XCTAssertEqual(initializer.attemptedConfigs, ["config"])
        }
    }
}

private final class MockApproovSDKInitializer: ApproovWebViewSDKInitializing, @unchecked Sendable {
    private(set) var attemptedConfigs: [String] = []
    private(set) var didRunOnMainActor = false
    var errorToThrow: (any Error)?

    @MainActor
    func initialize(config: String) throws {
        didRunOnMainActor = Thread.isMainThread
        attemptedConfigs.append(config)
        if let errorToThrow {
            throw errorToThrow
        }
    }
}

private enum TestError: Error, Equatable {
    case initializationFailed
}

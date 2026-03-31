import ApproovURLSession
import Foundation

protocol ApproovWebViewSDKInitializing: Sendable {
    @MainActor
    func initialize(config: String) throws
}

struct ApproovWebViewLiveSDKInitializer: ApproovWebViewSDKInitializing {
    @MainActor
    func initialize(config: String) throws {
        try ApproovService.initialize(config: config)
    }
}

actor ApproovWebViewSDKInitializationCoordinator {
    private enum State {
        case idle
        case initialized(String)
        case failed(config: String, error: any Error)
    }

    private let initializer: any ApproovWebViewSDKInitializing
    private var state = State.idle

    init(initializer: some ApproovWebViewSDKInitializing = ApproovWebViewLiveSDKInitializer()) {
        self.initializer = initializer
    }

    func initializeIfNeeded(config: String) async throws -> Bool {
        switch state {
        case .initialized(let initializedConfig):
            guard initializedConfig == config else {
                throw ApproovWebViewBridgeError.approovConfigMismatch
            }

            return false
        case let .failed(failedConfig, error):
            guard failedConfig == config else {
                throw ApproovWebViewBridgeError.approovConfigMismatch
            }

            throw error
        case .idle:
            do {
                try await initializer.initialize(config: config)
                state = .initialized(config)
                return true
            } catch {
                state = .failed(config: config, error: error)
                throw error
            }
        }
    }
}

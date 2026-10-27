import Foundation

enum ApproovWebViewInitializationError: LocalizedError {
    case incompatibleConfiguration, existingServiceRequired, serviceUnavailable
    var errorDescription: String? { "Approov service configuration is incompatible with this WebView." }
}

/// Owns one serialized bootstrap of the process-wide URLSession service.
final class ApproovWebViewBootstrap: @unchecked Sendable {
    struct Configuration: Equatable {
        let config, header, prefix: String
        let developmentKey: String?
        let usesExisting: Bool
    }
    struct Service {
        let isInitialized: () -> Bool
        let isEnabled: () -> Bool
        let tokenHeader: () -> String
        let initialize: (String) throws -> Void
        let setHeader: (String, String) -> Void
        let setDevKey: (String) -> Void
    }
    private let lock = NSLock()
    private var configured: Configuration?
    private var hookCompleted = false

    func install(_ requested: Configuration, service: Service,
                 configure: () throws -> Void, installScope: () -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if let configured, configured != requested { throw ApproovWebViewInitializationError.incompatibleConfiguration }
        if requested.usesExisting {
            guard service.isEnabled() else { throw ApproovWebViewInitializationError.serviceUnavailable }
            guard service.tokenHeader().caseInsensitiveCompare(requested.header) == .orderedSame else {
                throw ApproovWebViewInitializationError.incompatibleConfiguration
            }
        } else if configured == nil {
            guard !service.isInitialized() else { throw ApproovWebViewInitializationError.existingServiceRequired }
            try service.initialize(requested.config)
            service.setHeader(requested.header, requested.prefix)
            if let key = requested.developmentKey, !key.isEmpty { service.setDevKey(key) }
            // Retain ownership on hook failure so retry does not reset the SDK.
            configured = requested
        }
        if !requested.usesExisting && !hookCompleted {
            try configure()
            hookCompleted = true
        }
        configured = requested
        installScope()
    }
}

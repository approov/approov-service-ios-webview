import ApproovServiceWebViewCore
import Foundation
import OSLog

struct ApproovWebViewLogger: Sendable {
    private let logger: Logger
    private let debugLoggingEnabled: Bool

    init(configuration: ApproovWebViewConfiguration) {
        self.logger = Logger(
            subsystem: configuration.loggerSubsystem,
            category: configuration.loggerCategory
        )
        self.debugLoggingEnabled = configuration.debugLoggingEnabled
    }

    func debug(_ message: @autoclosure () -> String) {
        guard debugLoggingEnabled else {
            return
        }

        let value = message()
        logger.debug("\(value, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        let value = message()
        logger.error("\(value, privacy: .public)")
    }
}

extension ApproovWebViewContent {
    var logDescription: String {
        switch self {
        case .htmlString:
            return "htmlString"
        case .fileURL:
            return "fileURL"
        case .request:
            return "request"
        }
    }
}

extension ApproovWebViewProxyRequest {
    var logDescription: String {
        let method = method.isEmpty ? "GET" : method.uppercased()
        return "\(requestSource.rawValue.uppercased()) \(method) \(ApproovWebViewLogger.redactedURLForLog(url)) [\(responseHandling.rawValue)]"
    }
}

extension URLRequest {
    var logDescription: String {
        let method = httpMethod?.uppercased() ?? "GET"
        return "\(method) \(ApproovWebViewLogger.redactedURLForLog(url))"
    }
}

extension ApproovWebViewLogger {
    static func redactedURLForLog(_ value: String) -> String {
        guard let url = URL(string: value) else {
            return "<invalid-url>"
        }

        return redactedURLForLog(url)
    }

    static func redactedURLForLog(_ url: URL?) -> String {
        guard let url else {
            return "<nil-url>"
        }

        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return "<invalid-url>"
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid-url>"
    }
}

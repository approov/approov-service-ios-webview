import Approov
import ApproovURLSession
import Foundation

/// Composes the host app's existing `ApproovServiceMutator` with the WebView
/// package's allowlist and request-tagging rules.
///
/// Only requests marked as originating from this bridge are constrained by the
/// package allowlist. Other `ApproovURLSession` usage in the host app keeps
/// flowing through the previously-installed mutator.
final class ApproovWebViewServiceMutator: ApproovServiceMutator {
    private struct ScopePolicy {
        let protectedEndpoints: [ApproovWebViewProtectedEndpoint]
        let allowRequestsWithoutApproovToken: Bool
        let mutateRequest: @Sendable (URLRequest) -> URLRequest
    }

    private static let requestScopeProperty = "ApproovWebViewBridge.ScopeID"
    private static let stateQueue = DispatchQueue(
        label: "ApproovWebViewServiceMutator.state",
        qos: .userInitiated
    )
    private static var scopePolicies: [String: ScopePolicy] = [:]

    private let baseMutator: ApproovServiceMutator

    init(baseMutator: ApproovServiceMutator) {
        self.baseMutator = baseMutator
    }

    static func installOrUpdateScope(
        scopeID: String,
        configuration: ApproovWebViewConfiguration
    ) {
        stateQueue.sync {
            scopePolicies[scopeID] = ScopePolicy(
                protectedEndpoints: configuration.protectedEndpoints,
                allowRequestsWithoutApproovToken: configuration.allowRequestsWithoutApproovToken,
                mutateRequest: configuration.mutateRequest
            )
        }

        let currentMutator = ApproovService.getServiceMutator()
        guard !(currentMutator is ApproovWebViewServiceMutator) else {
            return
        }

        ApproovService.setServiceMutator(
            ApproovWebViewServiceMutator(baseMutator: currentMutator)
        )
    }

    static func setWebViewScope(_ scopeID: String, on request: inout URLRequest) {
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(
            scopeID,
            forKey: requestScopeProperty,
            in: mutableRequest
        )
        request = mutableRequest as URLRequest
    }

    private static func scopeID(for request: URLRequest) -> String? {
        URLProtocol.property(
            forKey: requestScopeProperty,
            in: request
        ) as? String
    }

    private static func scopePolicy(for request: URLRequest) -> ScopePolicy? {
        guard let scopeID = scopeID(for: request) else {
            return nil
        }

        return stateQueue.sync {
            scopePolicies[scopeID]
        }
    }

    private static func policies(matching urlString: String) -> [ScopePolicy] {
        guard let url = URL(string: urlString) else {
            return []
        }

        return stateQueue.sync {
            scopePolicies.values.filter { policy in
                policy.protectedEndpoints.contains { $0.matches(url) }
            }
        }
    }

    private func isAllowedWebViewRequest(
        _ request: URLRequest,
        policy: ScopePolicy
    ) -> Bool {
        guard let url = request.url else {
            return false
        }

        return policy.protectedEndpoints.contains { $0.matches(url) }
    }

    func handlePrecheckResult(_ approovResults: ApproovTokenFetchResult) throws {
        try baseMutator.handlePrecheckResult(approovResults)
    }

    func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws {
        try baseMutator.handleFetchTokenResult(approovResults)
    }

    func handleFetchSecureStringResult(
        _ approovResults: ApproovTokenFetchResult,
        operation: String,
        key: String
    ) throws {
        try baseMutator.handleFetchSecureStringResult(
            approovResults,
            operation: operation,
            key: key
        )
    }

    func handleFetchCustomJWTResult(_ approovResults: ApproovTokenFetchResult) throws {
        try baseMutator.handleFetchCustomJWTResult(approovResults)
    }

    func handleInterceptorShouldProcessRequest(_ request: URLRequest) throws -> Bool {
        if let scopePolicy = Self.scopePolicy(for: request) {
            guard isAllowedWebViewRequest(request, policy: scopePolicy) else {
                return false
            }
        }

        return try baseMutator.handleInterceptorShouldProcessRequest(request)
    }

    func handleInterceptorFetchTokenResult(
        _ approovResults: ApproovTokenFetchResult,
        url: String
    ) throws -> Bool {
        do {
            return try baseMutator.handleInterceptorFetchTokenResult(
                approovResults,
                url: url
            )
        } catch let error as ApproovError {
            let matchingPolicies = Self.policies(matching: url)
            let canFailOpen = !matchingPolicies.isEmpty
                && matchingPolicies.allSatisfy(\.allowRequestsWithoutApproovToken)

            if canFailOpen {
                switch error {
                case .networkingError:
                    return false
                default:
                    break
                }
            }

            throw error
        }
    }

    func handleInterceptorHeaderSubstitutionResult(
        _ approovResults: ApproovTokenFetchResult,
        header: String
    ) throws -> Bool {
        try baseMutator.handleInterceptorHeaderSubstitutionResult(
            approovResults,
            header: header
        )
    }

    func handleInterceptorQueryParamSubstitutionResult(
        _ approovResults: ApproovTokenFetchResult,
        queryKey: String
    ) throws -> Bool {
        try baseMutator.handleInterceptorQueryParamSubstitutionResult(
            approovResults,
            queryKey: queryKey
        )
    }

    func handleInterceptorProcessedRequest(
        _ request: URLRequest,
        changes: ApproovRequestMutations
    ) throws -> URLRequest {
        let processedRequest = try baseMutator.handleInterceptorProcessedRequest(
            request,
            changes: changes
        )

        guard let scopePolicy = Self.scopePolicy(for: processedRequest) else {
            return processedRequest
        }

        return scopePolicy.mutateRequest(processedRequest)
    }

    func handlePinningShouldProcessRequest(_ request: URLRequest) -> Bool {
        if let scopePolicy = Self.scopePolicy(for: request),
           !isAllowedWebViewRequest(request, policy: scopePolicy) {
            return false
        }

        return baseMutator.handlePinningShouldProcessRequest(request)
    }
}

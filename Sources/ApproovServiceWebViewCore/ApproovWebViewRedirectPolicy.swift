import Foundation

/// Validates a redirect before another native request is dispatched.
package enum ApproovWebViewRedirectPolicy {
    package static func prepare(_ request: inout URLRequest, from source: URL,
                                endpoints: [ApproovWebViewProtectedEndpoint]) throws {
        guard let destination = request.url,
              source.scheme?.lowercased() == "https",
              destination.scheme?.lowercased() == "https",
              endpoints.contains(where: { $0.matches(destination) }) else {
            throw URLError(.unsupportedURL)
        }
        func port(_ url: URL) -> Int { url.port ?? 443 }
        let sameOrigin = source.host?.lowercased() == destination.host?.lowercased()
            && port(source) == port(destination)
        if !sameOrigin {
            // Do not assume arbitrary application headers are safe to disclose.
            // The destination is reprocessed by Approov after this step.
            let safe = Set(["accept", "accept-language", "content-type", "user-agent"])
            for name in request.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys {
                if !safe.contains(name.lowercased()) {
                    request.setValue(nil, forHTTPHeaderField: name)
                }
            }
        }
    }
}

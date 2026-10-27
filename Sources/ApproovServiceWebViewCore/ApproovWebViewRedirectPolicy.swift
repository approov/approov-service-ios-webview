import Foundation

/// Validates a redirect before another native request is dispatched.
package enum ApproovWebViewRedirectPolicy {
    package static func prepare(
        _ request: inout URLRequest, from source: URL,
        endpoints: [ApproovWebViewProtectedEndpoint]
    ) throws {
        guard let destination = request.url,
            source.scheme?.lowercased() == "https",
            destination.scheme?.lowercased() == "https",
            endpoints.contains(where: { $0.matches(destination) })
        else {
            throw URLError(.unsupportedURL)
        }
        func port(_ url: URL) -> Int { url.port ?? 443 }
        let sameOrigin =
            source.host?.lowercased() == destination.host?.lowercased()
            && port(source) == port(destination)
        if !sameOrigin {
            // A 307/308 may preserve a body containing secrets. No body or
            // original header is authorized for transfer to another origin.
            guard request.httpBody?.isEmpty ?? true, request.httpBodyStream == nil else {
                throw URLError(.unsupportedURL)
            }
            for name in Array(request.allHTTPHeaderFields?.keys ?? [String: String]().keys) {
                request.setValue(nil, forHTTPHeaderField: name)
            }
        }
    }
}

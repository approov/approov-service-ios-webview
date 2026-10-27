import Foundation

/// Clears caller-supplied tokens and checks the signer's actual result.
package enum ApproovWebViewTokenPolicy {
    package static func sign(_ request: URLRequest, header: String, prefix: String,
                             allowMissing: Bool,
                             signer: (URLRequest) throws -> URLRequest) throws -> URLRequest {
        var unsigned = request
        unsigned.setValue(nil, forHTTPHeaderField: header)
        let signed = try signer(unsigned)
        if !allowMissing {
            let value = signed.value(forHTTPHeaderField: header) ?? ""
            guard value.hasPrefix(prefix),
                  !value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw URLError(.userAuthenticationRequired)
            }
        }
        return signed
    }
}

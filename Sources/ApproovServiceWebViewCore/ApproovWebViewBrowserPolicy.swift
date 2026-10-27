import Foundation

package enum ApproovWebViewBrowserPolicyError: Error, LocalizedError {
    case invalidContext, unsupportedPolicy, corsRejected, invalidHeader

    package var errorDescription: String? {
        switch self {
        case .invalidContext: return "The request has no verified browser context."
        case .unsupportedPolicy: return "This browser request policy is not supported by the native bridge."
        case .corsRejected: return "The response does not permit access from this page origin."
        case .invalidHeader: return "The request contains an invalid or browser-managed header."
        }
    }
}

/// Browser policy uses the actual WKFrameInfo origin and the page's original
/// headers. Approov's native-only additions are not page-controlled headers.
package enum ApproovWebViewBrowserPolicy {
    package static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let suffix = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(formattedHost)\(suffix)"
    }

    package static func isCrossOrigin(_ url: URL, sourceOrigin: String) -> Bool {
        origin(of: url) != sourceOrigin
    }

    package static func validateOptions(mode: String, credentials: String, redirect: String,
                                        cache: String, integrity: String) throws {
        guard ["cors", "same-origin", "navigate"].contains(mode),
              ["omit", "same-origin", "include"].contains(credentials),
              ["follow", "error"].contains(redirect),
              ["default", "no-store"].contains(cache),
              integrity.isEmpty else { throw ApproovWebViewBrowserPolicyError.unsupportedPolicy }
    }

    package static func validateMethod(_ method: String) throws -> String {
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !method.isEmpty, method.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
              !["CONNECT", "TRACE", "TRACK"].contains(method.uppercased()) else {
            throw ApproovWebViewBrowserPolicyError.unsupportedPolicy
        }
        return ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"].contains(method.uppercased()) ? method.uppercased() : method
    }

    package static func validatePageHeaders(_ headers: [String: String], tokenHeader: String) throws {
        let forbidden: Set<String> = ["accept-charset", "accept-encoding", "access-control-request-headers",
            "access-control-request-method", "connection", "content-length", "cookie", "cookie2", "date",
            "dnt", "expect", "host", "keep-alive", "origin", "referer", "set-cookie", "te", "trailer",
            "transfer-encoding", "upgrade", "via", tokenHeader.lowercased()]
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var seen = Set<String>()
        for (name, value) in headers {
            let lower = name.lowercased()
            guard seen.insert(lower).inserted else { throw ApproovWebViewBrowserPolicyError.invalidHeader }
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
                  !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }),
                  !forbidden.contains(lower), !lower.hasPrefix("sec-"), !lower.hasPrefix("proxy-") else {
                throw ApproovWebViewBrowserPolicyError.invalidHeader
            }
        }
    }

    package static func sendsCredentials(_ mode: String, url: URL, sourceOrigin: String) -> Bool {
        mode == "include" || (mode == "same-origin" && !isCrossOrigin(url, sourceOrigin: sourceOrigin))
    }

    package static func referrer(pageURL: URL, sourceOrigin: String, destination: URL,
                                requestedReferrer: String?, policy: String?) throws -> String? {
        if requestedReferrer == "" || requestedReferrer == "no-referrer" { return nil }
        var source = pageURL
        if let requestedReferrer, requestedReferrer != "about:client" {
            guard let requested = URL(string: requestedReferrer), origin(of: requested) == sourceOrigin else {
                throw ApproovWebViewBrowserPolicyError.invalidContext
            }
            source = requested
        }
        guard var components = URLComponents(url: source, resolvingAgainstBaseURL: false),
              origin(of: source) == sourceOrigin else { return nil }
        components.user = nil; components.password = nil; components.fragment = nil
        let full = components.string
        let crossOrigin = isCrossOrigin(destination, sourceOrigin: sourceOrigin)
        let downgrade = source.scheme?.lowercased() == "https" && destination.scheme?.lowercased() != "https"
        let originReferrer = sourceOrigin + "/"
        switch policy.flatMap({ $0.isEmpty ? nil : $0 }) ?? "strict-origin-when-cross-origin" {
        case "no-referrer": return nil
        case "same-origin": return crossOrigin ? nil : full
        case "origin": return originReferrer
        case "strict-origin": return downgrade ? nil : originReferrer
        case "origin-when-cross-origin": return crossOrigin ? originReferrer : full
        case "strict-origin-when-cross-origin": return downgrade ? nil : crossOrigin ? originReferrer : full
        case "no-referrer-when-downgrade": return downgrade ? nil : full
        case "unsafe-url": return full
        default: throw ApproovWebViewBrowserPolicyError.unsupportedPolicy
        }
    }

    package static func unsafeHeaderNames(_ headers: [String: String]) -> [String] {
        headers.filter { !isSafelisted(name: $0.key, value: $0.value) }.map { $0.key.lowercased() }.sorted()
    }

    package static func needsPreflight(method: String, headers: [String: String]) -> Bool {
        !["GET", "HEAD", "POST"].contains(method) || !unsafeHeaderNames(headers).isEmpty
    }

    package static func checkCORS(headers: [String: String], sourceOrigin: String, credentials: String) throws {
        let headers = lowercased(headers)
        let allowedOrigin = headers["access-control-allow-origin"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowedOrigin == sourceOrigin || (allowedOrigin == "*" && credentials != "include") else {
            throw ApproovWebViewBrowserPolicyError.corsRejected
        }
        if credentials == "include" && headers["access-control-allow-credentials"] != "true" {
            throw ApproovWebViewBrowserPolicyError.corsRejected
        }
    }

    package static func checkPreflight(status: Int, headers: [String: String], sourceOrigin: String,
                                       credentials: String, method: String, requestHeaders: [String: String]) throws {
        guard (200..<300).contains(status) else { throw ApproovWebViewBrowserPolicyError.corsRejected }
        try checkCORS(headers: headers, sourceOrigin: sourceOrigin, credentials: credentials)
        let headers = lowercased(headers)
        let methods = tokens(headers["access-control-allow-methods"])
        let allowedHeaders = Set(tokens(headers["access-control-allow-headers"]).map { $0.lowercased() })
        guard ["GET", "HEAD", "POST"].contains(method) || methods.contains(method)
                || (methods.contains("*") && credentials != "include") else {
            throw ApproovWebViewBrowserPolicyError.corsRejected
        }
        for name in unsafeHeaderNames(requestHeaders) {
            guard allowedHeaders.contains(name)
                    || (allowedHeaders.contains("*") && credentials != "include" && name != "authorization") else {
                throw ApproovWebViewBrowserPolicyError.corsRejected
            }
        }
    }

    package static func exposedHeaders(_ headers: [String: String], crossOrigin: Bool,
                                       credentials: String) -> [String: String] {
        let normalized = lowercased(headers)
        let exposed = Set(tokens(normalized["access-control-expose-headers"]).map { $0.lowercased() })
        let safelist: Set<String> = ["cache-control", "content-language", "content-length", "content-type",
                                    "expires", "last-modified", "pragma"]
        return headers.filter { name, _ in
            let name = name.lowercased()
            guard name != "set-cookie", name != "set-cookie2" else { return false }
            return !crossOrigin || safelist.contains(name) || exposed.contains(name)
                || (exposed.contains("*") && credentials != "include")
        }
    }

    private static func lowercased(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, entry in result[entry.key.lowercased()] = entry.value }
    }

    private static func tokens(_ value: String?) -> [String] {
        value?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
    }

    private static func isSafelisted(name: String, value: String) -> Bool {
        guard value.utf8.count <= 128 else { return false }
        let unsafe: Set<UInt8> = [34, 40, 41, 58, 60, 62, 63, 64, 91, 92, 93, 123, 125, 127]
        let hasUnsafe = value.utf8.contains { ($0 < 32 && $0 != 9) || unsafe.contains($0) }
        switch name.lowercased() {
        case "accept": return !hasUnsafe
        case "accept-language", "content-language":
            return value.range(of: "^[0-9A-Za-z *,.;=\\-]*$", options: .regularExpression) != nil
        case "content-type":
            let essence = value.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return !hasUnsafe && ["application/x-www-form-urlencoded", "multipart/form-data", "text/plain"].contains(essence)
        case "range": return value.range(of: "^bytes=[0-9]+-[0-9]*$", options: .regularExpression) != nil
        default: return false
        }
    }
}

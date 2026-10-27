import Foundation

/// Parses and validates response cookies before they can reach either jar.
package enum ApproovWebViewResponseCookies {
    package static func cookies(fromResponseHeaders headers: [AnyHashable: Any], url: URL) -> [HTTPCookie] {
        let fields = headers.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        guard let host = url.host, !host.isEmpty,
              let storage = URLSessionConfiguration.ephemeral.httpCookieStorage else { return [] }
        let raw = fields.first { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame }?.value ?? ""
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).filter { cookie in
            guard !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
            if cookie.name.hasPrefix("__Secure-") && (!cookie.isSecure || url.scheme?.lowercased() != "https") { return false }
            if cookie.name.hasPrefix("__Host-") {
                // Prefix rules require an explicit Path=/ and no Domain. A
                // folded header is accepted only if this cookie can be isolated.
                let escaped = NSRegularExpression.escapedPattern(for: cookie.name)
                let pattern = "(?:^|,)\\s*" + escaped + "=[^,]*(?:,(?!\\s*[^;,=]+\\s*=)[^,]*)*"
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      regex.numberOfMatches(in: raw, range: NSRange(raw.startIndex..., in: raw)) == 1,
                      let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                      let range = Range(match.range, in: raw) else { return false }
                let attributes = raw[range].split(separator: ";").dropFirst().map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                guard cookie.isSecure, url.scheme?.lowercased() == "https",
                      attributes.contains("path=/"),
                      !attributes.contains(where: { $0 == "domain" || $0.hasPrefix("domain=") }) else { return false }
            }
            // Foundation validates domain and public suffix against the source
            // URL. Probe with a non-expiring copy so valid deletion cookies are
            // not discarded merely because they are expired.
            guard var properties = cookie.properties else { return false }
            properties.removeValue(forKey: .expires)
            properties.removeValue(forKey: .maximumAge)
            guard let probe = HTTPCookie(properties: properties) else { return false }
            storage.deleteCookie(probe)
            storage.setCookies([probe], for: url, mainDocumentURL: url)
            let accepted = (storage.cookies ?? []).contains {
                $0.name == probe.name && $0.domain == probe.domain && $0.path == probe.path
            }
            storage.deleteCookie(probe)
            return accepted
        }
    }
}

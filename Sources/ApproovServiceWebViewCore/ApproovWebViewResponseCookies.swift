import Foundation

/// Parses and validates response cookies before they can reach either jar.
package enum ApproovWebViewResponseCookies {
    package static func cookies(fromResponseHeaders headers: [AnyHashable: Any], url: URL) -> [HTTPCookie] {
        guard let host = url.host, !host.isEmpty,
            let storage = URLSessionConfiguration.ephemeral.httpCookieStorage
        else { return [] }
        let values: [String] = headers.flatMap { entry -> [String] in
            guard String(describing: entry.key).caseInsensitiveCompare("Set-Cookie") == .orderedSame else { return [] }
            if let strings = entry.value as? [String] { return strings }
            if let string = entry.value as? String { return [string] }
            return []
        }
        return values.flatMap(splitCombinedHeader).flatMap { segment -> [HTTPCookie] in
            let attributes = segment.split(separator: ";").dropFirst().map { part -> (String, String?) in
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
                return (name, value)
            }
            let domains = attributes.filter { $0.0 == "domain" }
            // Validate the raw attribute independently of Foundation's domain
            // representation, including private public suffix rules.
            if domains.contains(where: { item in
                guard let value = item.1, !value.isEmpty else { return true }
                return ApproovWebViewSitePolicy.isPublicSuffix(value)
            }) {
                return []
            }
            return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": segment], for: url).filter { cookie in
                guard !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
                let lowerName = cookie.name.lowercased()
                if lowerName.hasPrefix("__secure-") && (!cookie.isSecure || url.scheme?.lowercased() != "https") {
                    return false
                }
                if lowerName.hasPrefix("__host-") {
                    let paths = attributes.filter { $0.0 == "path" }
                    guard cookie.isSecure, url.scheme?.lowercased() == "https",
                        !paths.isEmpty, paths.allSatisfy({ $0.1 == "/" }), domains.isEmpty
                    else { return false }
                }
                // A non-expiring copy permits Foundation to validate source
                // domain and public-suffix acceptance even for deletions.
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

    /// HTTPURLResponse can fold Set-Cookie values with commas. A separator is
    /// a comma followed by a cookie-name token and '=' outside quotes, not the
    /// comma inside an Expires date or a quoted value.
    private static func splitCombinedHeader(_ header: String) -> [String] {
        let token = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var start = header.startIndex
        var index = start
        var quoted = false
        var escaped = false
        var result: [String] = []
        while index < header.endIndex {
            let character = header[index]
            if quoted && escaped {
                escaped = false
            } else if quoted && character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "," && !quoted {
                var next = header.index(after: index)
                while next < header.endIndex && (header[next] == " " || header[next] == "\t") {
                    next = header.index(after: next)
                }
                let nameStart = next
                while next < header.endIndex && header[next].unicodeScalars.allSatisfy({ token.contains($0) }) {
                    next = header.index(after: next)
                }
                if next > nameStart && next < header.endIndex && header[next] == "=" {
                    result.append(String(header[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    start = header.index(after: index)
                }
            }
            index = header.index(after: index)
        }
        result.append(String(header[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return result.filter { !$0.isEmpty }
    }
}

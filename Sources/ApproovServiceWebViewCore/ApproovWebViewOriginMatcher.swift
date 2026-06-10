import Foundation

/// Matches a frame's security origin against a configured allowlist.
///
/// The bridge is injected into every frame of every page the web view loads, so
/// the native side must decide which origins are actually permitted to invoke
/// it. Without this gate any third-party iframe (an ad, an embedded widget) or
/// any page the web view navigates to could call the bridge and obtain
/// Approov-stamped, secret-header-injected responses for protected endpoints.
///
/// Rule syntax mirrors the intent of Android's `allowedOriginRules`:
/// - `*` matches any origin.
/// - `https://example.com` matches that exact scheme/host (and port if given).
/// - `https://*.example.com` matches `example.com` and any subdomain of it.
package enum ApproovWebViewOriginMatcher {
    /// Returns `true` when `origin` is permitted by `rules`.
    ///
    /// An empty rule set is treated as "no allowlist configured" and returns
    /// `true`, preserving the previous allow-all behavior for callers that have
    /// not adopted the field yet. Callers should warn in that case.
    package static func matches(origin: String, rules: [String]) -> Bool {
        guard !rules.isEmpty else {
            return true
        }

        guard let candidate = Components(origin) else {
            return false
        }

        return rules.contains { rule in
            matches(candidate: candidate, rule: rule)
        }
    }

    private static func matches(candidate: Components, rule: String) -> Bool {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRule == "*" {
            return true
        }

        guard let ruleComponents = Components(trimmedRule, allowingHostWildcard: true) else {
            return false
        }

        guard candidate.scheme == ruleComponents.scheme else {
            return false
        }

        // A rule that pins a port only matches that port; a rule without a port
        // matches the candidate regardless of its port.
        if let rulePort = ruleComponents.port, rulePort != candidate.port {
            return false
        }

        return hostMatches(candidateHost: candidate.host, ruleHost: ruleComponents.host)
    }

    private static func hostMatches(candidateHost: String, ruleHost: String) -> Bool {
        guard ruleHost.hasPrefix("*.") else {
            return candidateHost == ruleHost
        }

        let baseDomain = String(ruleHost.dropFirst(2))
        guard !baseDomain.isEmpty else {
            return false
        }

        return candidateHost == baseDomain || candidateHost.hasSuffix("." + baseDomain)
    }

    /// Minimal origin parser. We avoid `URL`/`URLComponents` here because a host
    /// wildcard such as `*.example.com` is not a valid URL host.
    private struct Components {
        let scheme: String
        let host: String
        let port: Int?

        init?(_ value: String, allowingHostWildcard: Bool = false) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let schemeRange = trimmed.range(of: "://") else {
                return nil
            }

            let scheme = String(trimmed[trimmed.startIndex..<schemeRange.lowerBound]).lowercased()
            var remainder = String(trimmed[schemeRange.upperBound...])

            // Drop any path/query/fragment; an origin is scheme + authority only.
            if let pathStart = remainder.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                remainder = String(remainder[remainder.startIndex..<pathStart])
            }

            var host = remainder
            var port: Int?
            if let portSeparator = remainder.lastIndex(of: ":") {
                host = String(remainder[remainder.startIndex..<portSeparator])
                let portText = String(remainder[remainder.index(after: portSeparator)...])
                guard let parsedPort = Int(portText) else {
                    return nil
                }

                port = parsedPort
            }

            host = host.lowercased()
            guard !scheme.isEmpty, !host.isEmpty else {
                return nil
            }

            if host.contains("*") && !(allowingHostWildcard && host.hasPrefix("*.")) {
                return nil
            }

            self.scheme = scheme
            self.host = host
            self.port = port
        }
    }
}

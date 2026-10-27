import Foundation

/// Schemeful site comparison uses the Mozilla Public Suffix List, including
/// private suffixes. Comparing the last two labels alone is unsafe for co.uk
/// and hosting services such as github.io.
package enum ApproovWebViewSitePolicy {
    private static let rules: PublicSuffixRules? = {
        #if SWIFT_PACKAGE
            guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return PublicSuffixRules(text: text)
        #else
            return nil
        #endif
    }()

    package static func isSameSite(frameURL: URL, mainDocumentURL: URL?, requestURL: URL) -> Bool {
        guard sameSite(frameURL, requestURL), let top = mainDocumentURL else { return false }
        return sameSite(top, requestURL)
    }

    /// Domain attributes must never target a public suffix, including private rules.
    /// Fail closed when the bundled list cannot be loaded.
    package static func isPublicSuffix(_ host: String) -> Bool {
        guard let rules else { return true }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty else { return true }
        if !normalized.contains(".") { return true }
        return rules.registrableDomain(normalized) == nil
    }

    package static func sameSite(_ first: URL, _ second: URL) -> Bool {
        guard let firstScheme = first.scheme?.lowercased(), ["http", "https"].contains(firstScheme),
            firstScheme == second.scheme?.lowercased(),
            let firstHost = first.host?.lowercased(), let secondHost = second.host?.lowercased()
        else { return false }
        if firstHost == secondHost { return true }
        guard let rules, let a = rules.registrableDomain(firstHost), let b = rules.registrableDomain(secondHost) else {
            return false
        }
        return a == b
    }

    package struct PublicSuffixRules {
        private var exact = Set<String>()
        private var wildcard = Set<String>()
        private var exceptions = Set<String>()

        package init(text: String) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("//") else { continue }
                let exception = line.hasPrefix("!")
                let wild = line.hasPrefix("*.")
                let plain = exception ? String(line.dropFirst()) : wild ? String(line.dropFirst(2)) : line
                guard let host = URL(string: "https://" + plain)?.host?.lowercased() else { continue }
                if exception {
                    exceptions.insert(host)
                } else if wild {
                    wildcard.insert(host)
                } else {
                    exact.insert(host)
                }
            }
        }

        package func registrableDomain(_ rawHost: String) -> String? {
            let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !host.isEmpty else { return nil }
            if host.contains(":") || host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) { return host }
            let labels = host.split(separator: ".").map(String.init)
            if labels.count == 1 { return host }
            var suffixLength = 1
            for index in labels.indices {
                let suffix = labels[index...].joined(separator: ".")
                if exceptions.contains(suffix) {
                    suffixLength = labels.count - index - 1
                    break
                }
                if exact.contains(suffix) { suffixLength = max(suffixLength, labels.count - index) }
                if index > 0 && wildcard.contains(suffix) {
                    suffixLength = max(suffixLength, labels.count - index + 1)
                }
            }
            guard labels.count > suffixLength else { return nil }
            return labels.suffix(suffixLength + 1).joined(separator: ".")
        }
    }
}

import Foundation

/// Parses cookies from a native HTTP response so they can be stored in the
/// shared cookie jar.
///
/// `HTTPURLResponse.allHeaderFields` folds multiple `Set-Cookie` headers into a
/// single comma-separated string. `HTTPCookie.cookies(withResponseHeaderFields:for:)`
/// is the Foundation API that knows how to split that representation back into
/// individual cookies, including `HttpOnly` ones. Keeping this in the
/// platform-independent core module lets it be unit-tested without the Approov
/// binary framework.
package enum ApproovWebViewResponseCookies {
    package static func cookies(
        fromResponseHeaders headers: [AnyHashable: Any],
        url: URL
    ) -> [HTTPCookie] {
        let headerFields = headers.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }

        // A conservative host-only policy prevents a response from planting
        // cookies on an unrelated host or public suffix. Parent-domain cookies
        // require a public suffix database and are deliberately rejected.
        guard let host = url.host?.lowercased() else { return [] }
        return HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            .filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard domain == host else { return false }
                if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
                if cookie.name.hasPrefix("__Secure-") && (!cookie.isSecure || url.scheme?.lowercased() != "https") { return false }
                if cookie.name.hasPrefix("__Host-") {
                    // Foundation does not reliably retain whether Domain was
                    // present, so do not accept __Host- without raw validation.
                    return false
                }
                return true
            }
    }
}

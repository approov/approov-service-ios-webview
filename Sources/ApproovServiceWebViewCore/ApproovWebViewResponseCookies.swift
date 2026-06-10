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

        return HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
    }
}

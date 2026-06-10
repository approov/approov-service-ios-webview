# Changelog

All notable changes to this package are documented in this file.

The format is based on Keep a Changelog and this package follows Semantic Versioning.
Released versions are tagged in git.

## [0.5] - 2026-06-10
### Fixed
  * Response cookies issued by a protected request are now persisted and attached to subsequent
    protected requests. The request executor previously assigned a bare `HTTPCookieStorage()`
    instance to the `URLSession` configuration; an `HTTPCookieStorage` created through its
    initializer is inert (`setCookie` is a no-op and `Set-Cookie` responses are never captured), so
    session cookies returned by one XHR/fetch call were silently dropped and absent from the next
    call. The executor now uses the ephemeral configuration's own working cookie store and also
    harvests `Set-Cookie` from each response explicitly so behavior does not depend on
    `ApproovURLSession`'s internal session configuration.
### Security
  * `Set-Cookie` response headers are no longer forwarded to page JavaScript in the bridge response
    payload, matching browser behavior and keeping `HttpOnly` session cookies out of reach of page
    scripts. Cookies are still applied to the shared cookie jar and synchronized back into WebKit.

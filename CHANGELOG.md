# Changelog

All notable changes to this package are documented in this file.

The format is based on Keep a Changelog and this package follows Semantic Versioning.
Released versions are tagged in git.

## [Unreleased]
### Added
  * `ApproovWebViewConfiguration.allowedOrigins` restricts which frame origins may invoke the native
    bridge. The bridge script is injected into every frame of every page, so without this gate a
    third-party iframe or a navigated page could call the bridge and obtain Approov-stamped,
    secret-header-injected responses for protected endpoints. Rules support exact origins
    (`https://example.com`), exact origins with explicit ports (`https://example.com:8443`),
    subdomain wildcards (`https://*.example.com`), and `*`. Enforcement is in the coordinator
    against the calling frame's security origin; the matcher rejects lookalike hosts such as
    `notexample.com` and `example.com.evil.com`.
### Changed
  * **BREAKING:** `allowedOrigins` is now a required argument of `ApproovWebViewConfiguration.init`,
    so the bridge trust boundary is a conscious choice, matching Android (which rejects a build with
    no origin rules). Pass an empty list to keep the legacy allow-all behavior (a warning is logged),
    or `["*"]` to explicitly allow any origin.
### Fixed
  * The bridge no longer leaks scope state: `ApproovWebViewServiceMutator` entries are removed when
    the owning request executor is deallocated, so the static scope registry no longer grows for the
    lifetime of the process and no longer retains configurations and their closures indefinitely.

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

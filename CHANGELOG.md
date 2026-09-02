# Changelog

All notable changes to this package are documented in this file.

The format is based on Keep a Changelog and this package follows Semantic Versioning.
Released versions are tagged in git.

## [Unreleased]
### Fixed
  * Updated `approov-service-urlsession` to 3.5.12. Task-observer state now stays with each task,
    so tasks created by different sessions can use the same session-local identifier without
    overwriting each other's configuration or completion handler.

## [0.5.1] - 2026-07-27
### Fixed
  * Concurrent protected WebView requests no longer share their native `HTTPCookieStorage` with
    `URLSession`. The bridge now retains the ephemeral configuration's working cookie store but
    detaches it from `ApproovURLSession`, disables automatic cookie handling, and manages request
    and response cookies exclusively inside the request executor. This prevents a CFNetwork race
    in `CompactCookieArray::_mungeCookies` that could crash when overlapping requests updated the
    same cookie jar. Redirects are followed one protected hop at a time so cookies set by an
    intermediate response are available to the next hop without re-enabling shared automatic
    cookie handling.
  * WebKit cookies are synchronized before the protected request's `Cookie` header is constructed,
    so the request no longer uses the previous native snapshot. Snapshot reconciliation also
    preserves newer response cookies while propagating cookies deleted by WebKit. Server-driven
    expiration and deletion are now mirrored into WebKit explicitly, and per-cookie mutation
    barriers prevent late WebKit snapshots from resurrecting deletions or overwriting replacements.
    A barrier is held until the mirror has actually been applied rather than until the next
    snapshot ticket, so correctness no longer depends on where the request executor happens to
    suspend between storing response cookies and mirroring them. A post-flush WebKit snapshot that
    omits a newly introduced response cookie now removes it from the native jar even when WebKit
    deleted or rejected it before it was ever observed in a snapshot. WebKit snapshots are request
    input only and are no longer replayed wholesale after a native response; each flush mirrors only
    server response-cookie deltas, preventing an in-flight request from resurrecting a page-side
    deletion or overwriting a newer page-side replacement. Each delta is claimed by one flush, and
    flush completion acknowledges only the exact cookie identity generations it applied, so an
    overlapping empty or older flush cannot release a different response's reconciliation barrier.
  * Reinstalling the bridge on an already-attached `WKWebView` no longer rebuilds the request
    executor. A rebuild discarded the cookie jar along with any deletion still waiting to be
    mirrored into WebKit, and re-ran lazy Approov initialization.
  * Protected-endpoint JSON embedded in the bridge script now uses a deterministic key order.
    Reinstalling the same configuration could otherwise compare unequal generated scripts and
    trigger the factory's unsupported-reconfiguration assertion in debug builds.
  * Redirect handling no longer invokes URLSession's completion callback while holding its
    redirect-state lock, preventing a synchronous callback from deadlocking on re-entry.

### Known limitations
  * Cookie reconciliation state is per request executor, so two protected web views sharing a
    `WKWebsiteDataStore` (including the process-wide `.default()` store) are not serialized
    against each other and can observe each other's half-applied WebKit updates. Protect one web
    view at a time.

## [0.5] - 2026-06-10
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

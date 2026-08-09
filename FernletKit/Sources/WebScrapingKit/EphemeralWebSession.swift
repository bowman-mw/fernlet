import Foundation

/// The one `URLSession` any Fernlet web fetch is allowed to use: a private-browsing-tab session that
/// stores no cookies, no cache, and no credentials, so nothing a site sets during one import can be
/// read back during a later, unrelated one.
///
/// **Why this type exists.** Both web importers previously fetched through `URLSession.shared`, which
/// is backed by the process-wide `HTTPCookieStorage.shared`, `URLCache.shared`, and
/// `URLCredentialStorage.shared`. That is a shared, *persistent* jar: a recipe page imported on Monday
/// could set a cookie, and a product page on the same domain imported in June would send it back —
/// cross-request linkability the user never asked for. Routing every fetch through one deliberately
/// amnesiac session removes that channel. See `Docs/No-Tracking-Wall.md` §2a.
///
/// **What it does NOT change.** This type owns *transport privacy only*. Each caller keeps its own
/// timeout, `User-Agent`, `Accept`, redirect policy, content-type check, and size cap — those differ
/// between the two importers on purpose (the product importer spoofs Safari to get past bot walls and
/// throws on an oversized body; the recipe importer identifies itself honestly, re-validates every
/// redirect hop against its SSRF guard, and truncates). Nothing here inspects or rewrites a request.
///
/// **Concurrency.** `URLSession` is thread-safe and `Sendable`, so ``shared`` is an ordinary
/// `static let` in this nonisolated module and is safe to touch from any actor. The session lives for
/// the process lifetime and is never invalidated — a per-fetch session would have to be
/// `finishTasksAndInvalidate()`d after its `AsyncBytes` stream drained, and leaking one per import is
/// worse than reusing an amnesiac one.
public enum EphemeralWebSession {

    /// The shared private-browsing session every outbound fetch in the app goes through.
    ///
    /// Created once, lazily. Every knob that could retain cross-request state is disabled in
    /// ``makeConfiguration()``; see that method for the per-setting rationale.
    public static let shared: URLSession = makeSession()

    /// A fresh configuration with every state-retaining feature turned off.
    ///
    /// Each setting is listed with whether `.ephemeral` alone would already have covered it. The
    /// redundant ones are still set **explicitly and deliberately**: this is a privacy guarantee, and
    /// it must survive a future edit that swaps the base configuration (a `.default` here would
    /// silently re-enable the shared, on-disk cookie jar with no other visible change). A reviewer
    /// reading this function should be able to see the whole guarantee without knowing what
    /// `.ephemeral` implies.
    ///
    /// - `.ephemeral` — the base: no on-disk cookie, cache, or credential storage at all. Everything
    ///   an ephemeral session would otherwise keep lives in RAM for the session's lifetime, which for
    ///   a process-lifetime session is still long enough to link two imports. The settings below close
    ///   that remaining window.
    /// - `httpCookieAcceptPolicy = .never` — **not** redundant. An ephemeral session inherits the
    ///   default accept policy (`.onlyFromMainDocumentDomain`) and would happily accept first-party
    ///   cookies into its in-memory jar. `.never` means no `Set-Cookie` is ever honoured.
    /// - `httpCookieStorage = nil` — **not** redundant. `.ephemeral` supplies an in-memory
    ///   `HTTPCookieStorage`; `nil` means there is no jar to write to at all, so there is nothing for
    ///   a later request to read back even within one launch.
    /// - `httpShouldSetCookies = false` — redundant given the two above (there are no stored cookies
    ///   to attach to an outgoing request), and set anyway as the second, independent lock: it governs
    ///   the *send* direction where the other two govern the *store* direction.
    /// - `urlCache = nil` — **not** redundant. `.ephemeral` supplies an in-memory `URLCache`. A
    ///   response body cached in RAM is not a tracking vector by itself, but a cache *validator*
    ///   (`ETag` / `Last-Modified`) replayed on a later request is a well-known cookie substitute.
    /// - `requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData` — redundant with `urlCache =
    ///   nil` (there is no cache to consult), and set anyway so that re-adding a cache later cannot
    ///   quietly reintroduce validator-based tracking without also changing this line.
    /// - `urlCredentialStorage = nil` — **not** redundant. `.ephemeral` keeps an in-memory credential
    ///   store; `nil` means an auth challenge answered on one host can never be silently replayed.
    ///
    /// **Honest limit.** There is no public API to disable TLS session-ticket resumption or HTTP/2
    /// connection coalescing, so a server can still correlate two fetches that reuse one live
    /// connection within a session lifetime. That residual is documented in `Docs/No-Tracking-Wall.md`
    /// §6 rather than papered over.
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// A new session on a fresh ``makeConfiguration()``.
    ///
    /// Callers should use ``shared``; this exists so a test can build an equivalently configured
    /// session without touching the process-wide one, and so the configuration and the session are
    /// never constructed from different code paths.
    public static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }
}

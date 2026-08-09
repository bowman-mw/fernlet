import Foundation

/// Normalizes recipe source URLs so "the same page" matches across cosmetic spelling differences,
/// letting repeat imports of an already-saved URL skip the network entirely (owner decision
/// 2026-08-09).
///
/// The normalization is deliberately conservative — it only erases parts of a URL that can never
/// distinguish two recipe pages:
/// - **Scheme and host are case-insensitive** (`HTTPS://Example.COM` ≡ `https://example.com`),
///   per RFC 3986 §3.1/§3.2.2.
/// - **The fragment is stripped** (`…/recipe#comments` ≡ `…/recipe`) — fragments are client-side
///   and never reach the server.
/// - **The query is KEPT** — query strings genuinely distinguish recipes on some sites
///   (`…/recipe?id=1` vs `…/recipe?id=2`), so two URLs differing only in query never match.
/// - **Path, port, and everything else stay verbatim** (paths are case-sensitive on most hosts).
///
/// Used by `SavedRecipeService` (StoreCore) for the supersede-on-re-import match and the
/// saved-recipe duplicate lookup, and by `FernletStore` for the superseded-photo cleanup — all
/// three must agree on what "same source" means, which is why the rule lives here once.
public nonisolated enum RecipeSourceURLMatcher {
    /// The canonical match key for a source-URL string: scheme and host lowercased, fragment
    /// removed, query/path/port preserved. Returns `nil` when the trimmed string is empty, does
    /// not parse, or lacks a scheme or host (modern Foundation's lenient parser accepts almost any
    /// string as a *relative* reference, and normalizing a non-absolute string would let fragment
    /// stripping and percent-encoding conflate strings that are not URLs at all) — callers fall
    /// back to exact comparison via ``urlsMatch(_:_:)`` rather than treating "not a web URL" as
    /// "matches every other non-URL".
    public static func normalizedKey(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme.lowercased()
        // URLComponents exposes the host decoded; setting it back re-encodes consistently, so two
        // spellings of the same host land on one key.
        components.host = host.lowercased()
        components.fragment = nil
        return components.string
    }

    /// Whether two source-URL strings refer to the same page under ``normalizedKey(_:)``.
    ///
    /// Empty strings never match anything (a "no source" recipe must not collide with another
    /// "no source" recipe). When either side yields no ``normalizedKey(_:)`` (unparseable, or not
    /// an absolute scheme://host URL), the comparison falls back to exact trimmed equality — such
    /// a stored string can still be superseded by re-importing the identical string, but never by
    /// a lookalike.
    public static func urlsMatch(_ first: String, _ second: String) -> Bool {
        let trimmedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecond = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFirst.isEmpty, !trimmedSecond.isEmpty else { return false }
        if let firstKey = normalizedKey(trimmedFirst), let secondKey = normalizedKey(trimmedSecond) {
            return firstKey == secondKey
        }
        return trimmedFirst == trimmedSecond
    }
}

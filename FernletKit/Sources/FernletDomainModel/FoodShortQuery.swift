// FoodShortQuery.swift
// Roadmap G1, F9 (Docs/Handoff review 2026-11-09): one- and two-letter food queries. Pure value logic.
import Foundation

/// What a typed food search does with a query under ``FoodItemSearch/minimumQueryLength``.
///
/// A query that short used to answer "No catalog matches." on every typed field, which reads as
/// "the catalog has no such food" while the person is only halfway through a word, and it refused the
/// few real two-character foods people type ("pb", "oj", "v8"). Three answers now:
///
/// - **An abbreviation** (``expansions``) searches the words it stands for: "pb" is peanut butter,
///   "oj" orange juice, "eg" egg.
/// - **A short food word** (``shortWords``) searches as typed, below the floor: "v8" is the V8 drinks
///   the catalog names that way.
/// - **Anything else** is still too short to search, and ``isAwaitingMoreLetters(_:)`` lets a screen
///   say "Keep typing" instead of claiming there is no match. The floor stays: a two-letter prefix
///   ("ch") fetches and scores the whole 10,000-row cap.
///
/// Both tables are typed-surface only (``FoodCatalog`` reads them for ``FoodSearchContext/userTyped``)
/// and are FROZEN ENGLISH MATCHING INPUT (localization wall): they are compared with normalized typed
/// text and never displayed.
public nonisolated enum FoodShortQuery {
    /// Abbreviations, keyed by normalized query, and the words each stands for.
    nonisolated static let expansions: [String: String] = [
        "pb": "peanut butter",
        "oj": "orange juice",
        "eg": "egg"
    ]

    /// Two-character foods searched as typed, below the length floor.
    nonisolated static let shortWords: Set<String> = ["v8"]

    /// The text a typed query searches: the words a short abbreviation stands for, else the query.
    public static func expanded(_ query: String) -> String {
        expansions[FoodItemSearch.normalized(query)] ?? query
    }

    /// Whether `normalizedQuery` is a short food word allowed under the length floor.
    public static func isShortWord(_ normalizedQuery: String) -> Bool {
        shortWords.contains(normalizedQuery)
    }

    /// Whether `query` is too short to search yet (and is not one of the short foods above), so a
    /// screen should ask for more letters rather than report no match.
    public static func isAwaitingMoreLetters(_ query: String) -> Bool {
        let normalized = FoodItemSearch.normalized(query)
        guard !normalized.isEmpty, normalized.count < FoodItemSearch.minimumQueryLength else { return false }
        return expansions[normalized] == nil && !shortWords.contains(normalized)
    }

    /// The tables, for the freeze pin in tests.
    public static var expansionsForTesting: [String: String] { expansions }
    /// See ``expansionsForTesting``.
    public static var shortWordsForTesting: Set<String> { shortWords }
}

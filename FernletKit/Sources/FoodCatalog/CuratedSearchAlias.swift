import Foundation
import FernletDomainModel

/// A small, curated table of phrases a person types for a food whose catalog NAME does not say them
/// (ingredient-search round, F7 — Docs/Ingredient-Search-Deep-Research-2026-09-29.md §2.3, §8 F7).
///
/// USDA names semisweet chocolate chips "Candies, semisweet chocolate"; the word "chips" lives only in
/// that row's portion text. FTS indexes name, category and tags, and the name floor needs every typed
/// word in the NAME, so "chocolate chips" can never reach the row — the typed list is 24 chip cookies,
/// trail mixes and granola bars instead. The same holds for "garlic clove" ("Garlic, raw"), "red pepper
/// flakes" ("Spices, pepper, red or cayenne") and "vegetable oil" (USDA's soybean salad or cooking oil).
/// Indexing portion text in FTS would not help: the name floor and the scorer's own gate drop such
/// rows anyway (§8 F7). So a handful of phrases name their row directly.
///
/// The rules, all deliberate:
/// - **Typed search only.** ``FoodCatalog`` applies it inside `results(for:limit:stripsStopwords:context:)`
///   for ``FoodSearchContext/userTyped`` alone. It is NOT built on the correction memory's
///   `promotingCorrection`, which runs for every context — including the resolver's
///   `candidates(for:limit:)` and the web importer's limit-1 bind — and would inject these rows into
///   meal-resolution pools. The resolver and importer never see an alias.
/// - **Additive.** The target is inserted; nothing is filtered out of the ranked list (the list is
///   re-capped at the caller's limit, so the last row falls below the fold, exactly as a correction
///   does).
/// - **The person's own answers stay above it.** A user item, or a row this person has logged, keeps
///   its place ahead of the alias; a correction (an explicit "when I type this I mean that") is
///   prepended after the alias and so always wins. Curated text is a guess about everyone; the other
///   two are about this person.
/// - **Prefix-aware once the first word is complete**: a query of the phrase's word count whose
///   earlier words are the phrase's and whose last word begins the phrase's last word matches, so
///   "chocolate chi" finds the row while it is being typed. One word never matches (it is still being
///   typed), and a shorter query never matches a longer phrase ("red pepper" is not "red pepper flakes").
/// - **One spelling fold**: "semi sweet" reads as "semisweet" (``spellingFolds``), so "semi sweet
///   chocolate chips" and "semi-sweet chocolate chips" reach the same row.
///
/// Every phrase is a FROZEN ENGLISH MATCHING INPUT (localization wall): it is compared against
/// `FoodItemSearch.normalized` output of the typed text over a catalog baked in English. Never localize
/// one; a translated phrase matches nothing. `LocalizationBoundaryTests.frozenCuratedSearchAliases`
/// pins the table. The targets are the rows' deterministic FDC-derived catalog ids (never `food_id`,
/// which a rebuild renumbers); `CuratedSearchAliasTests` proves each resolves to the named row.
///
/// Bounded (Power-of-10 R2/R3): a fixed table of ``entries``, a query of more than twice
/// ``maxPhraseWords`` words is not read, and the fold is one pass over at most that many words.
nonisolated enum CuratedSearchAlias {
    /// One alias: a typed phrase (already in `FoodItemSearch.normalized` form) and the catalog row id
    /// it names.
    struct Entry: Sendable, Equatable {
        /// The phrase, lowercase words separated by single spaces — a frozen matching input.
        let phrase: String
        /// The target row's catalog id, as the committed SQLite `food.id` column stores it.
        let targetID: String

        /// The phrase's words.
        var words: [String] { phrase.split(separator: " ").map(String.init) }
    }

    /// "Candies, semisweet chocolate" — SR Legacy, FDC 167976 (report §2.4's row 818).
    static let semisweetChocolateID = "00000000-0000-5000-8000-000000167976"
    /// "Garlic, raw" — SR Legacy, FDC 169230, the twin that carries USDA's clove (3 g) and cup.
    static let rawGarlicID = "00000000-0000-5000-8000-000000169230"
    /// "Spices, pepper, red or cayenne" — SR Legacy, FDC 170932.
    static let redPepperID = "00000000-0000-5000-8000-000000170932"
    /// "Oil, soybean, salad or cooking" — SR Legacy, FDC 171411: the oil sold as "vegetable oil" in
    /// the US (not the partially hydrogenated twin, FDC 171012).
    static let soybeanOilID = "00000000-0000-5000-8000-000000171411"

    /// The table. Order decides only between phrases that both match a partial last word, and every
    /// such pair names one row.
    static let entries: [Entry] = [
        Entry(phrase: "chocolate chips", targetID: semisweetChocolateID),
        Entry(phrase: "chocolate chip", targetID: semisweetChocolateID),
        Entry(phrase: "choc chips", targetID: semisweetChocolateID),
        Entry(phrase: "choc chip", targetID: semisweetChocolateID),
        Entry(phrase: "semisweet chocolate chips", targetID: semisweetChocolateID),
        Entry(phrase: "semisweet chocolate chip", targetID: semisweetChocolateID),
        Entry(phrase: "semisweet chocolate", targetID: semisweetChocolateID),
        Entry(phrase: "garlic cloves", targetID: rawGarlicID),
        Entry(phrase: "garlic clove", targetID: rawGarlicID),
        Entry(phrase: "red pepper flakes", targetID: redPepperID),
        Entry(phrase: "red pepper flake", targetID: redPepperID),
        Entry(phrase: "crushed red pepper", targetID: redPepperID),
        Entry(phrase: "vegetable oil", targetID: soybeanOilID),
    ]

    /// Word pairs read as one word before matching. Frozen matching inputs.
    static let spellingFolds: [(first: String, second: String, folded: String)] = [
        (first: "semi", second: "sweet", folded: "semisweet")
    ]

    /// The longest phrase, in words; a longer query is not an alias query.
    static let maxPhraseWords = 3

    /// The row a typed query names, or nil. `query` is the raw field text.
    static func targetID(forTyped query: String) -> UUID? {
        let raw = FoodItemSearch.normalized(query).split(separator: " ").map(String.init)
        // A fold can only shorten the query, so twice the phrase limit is the most worth reading.
        guard raw.count >= 2, raw.count <= maxPhraseWords * 2 else { return nil }
        let typed = folded(raw)
        guard typed.count >= 2, typed.count <= maxPhraseWords,
              let entry = entries.first(where: { matches(typed, $0.words) }) else { return nil }
        return UUID(uuidString: entry.targetID)
    }

    /// Whether `typed` is `phrase` with its last word possibly still being typed.
    static func matches(_ typed: [String], _ phrase: [String]) -> Bool {
        guard typed.count == phrase.count, let last = typed.last, let phraseLast = phrase.last,
              !last.isEmpty else { return false }
        return typed.dropLast().elementsEqual(phrase.dropLast()) && phraseLast.hasPrefix(last)
    }

    /// `words` with every ``spellingFolds`` pair joined. One bounded pass.
    static func folded(_ words: [String]) -> [String] {
        var result: [String] = []
        var joinedIntoPrevious = false
        for (index, word) in words.enumerated() {
            guard !joinedIntoPrevious else {
                joinedIntoPrevious = false
                continue
            }
            let next = words.indices.contains(index + 1) ? words[index + 1] : nil
            if let next, let fold = spellingFolds.first(where: { $0.first == word && $0.second == next }) {
                result.append(fold.folded)
                joinedIntoPrevious = true
            } else {
                result.append(word)
            }
        }
        return result
    }
}

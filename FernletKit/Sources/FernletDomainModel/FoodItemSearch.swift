// FoodItemSearch.swift
// SPM carve-up: pure relevance-search value logic over `FoodItem`, carved out of the
// app-layer FoodDataCatalog. The catalog's SQLite/bundled-store path sits ABOVE this and
// uses it; this layer references only domain value types (FoodItem / FoodItemSource /
// FoodDataType), so it belongs in FernletDomainModel.

import Foundation

/// Restaurant-chain token lexicon for brand-aware food-search ranking.
///
/// Lets ``FoodItemSearch`` detect a brand-flavored query ("mcdonalds fries") and flip the data-type
/// priority so restaurant/branded entries outrank USDA reference foods only when a chain was
/// actually named.
public nonisolated enum FoodBrandLexicon {
    nonisolated private static let chains: Set<String> = [
        "mcdonalds", "wendys", "burger king", "taco bell", "chick fil a", "subway",
        "starbucks", "chipotle", "dominos", "pizza hut", "kfc", "popeyes", "five guys",
        "shake shack", "in n out", "whataburger", "sonic", "jack in the box",
        "panda express", "olive garden", "applebees", "chilis", "red lobster",
        "outback", "panera", "dunkin", "arbys", "dairy queen", "hardees", "carls jr",
        "del taco", "wingstop", "buffalo wild wings", "cracker barrel", "ihop",
        "dennys", "waffle house", "friendlys", "bojangles", "checkers", "rallys",
        "long john silvers", "captain d"
    ]

    nonisolated public static func isRestaurantChain(_ text: String) -> Bool {
        let n = FoodItemSearch.normalized(text)
        return chains.contains { n.contains($0) }
    }

    nonisolated public static func queryContainsBrandToken(_ query: String) -> Bool {
        let n = FoodItemSearch.normalized(query)
        return chains.contains { n.contains($0) }
    }
}

/// Pure relevance search over ``FoodItem``s: normalization, tokenization, scoring, and ranking.
///
/// The in-memory half of food search — the SQLite-backed `FoodCatalog` sits above it and reuses
/// the same normalization/token/variant helpers (`searchTokens`, `matchVariants`) so its FTS5
/// candidate query stays in lockstep with this scorer's hard match gate. Ranking sorts source
/// priority (manual > USDA > AI) and brand-aware data-type priority ABOVE the relevance score, then
/// applies preparation and form-specificity biases. `minimumBindScore`/`confidentBindScore` are the
/// confidence floors quick-log binding applies to `scoredResults`.
public nonisolated enum FoodItemSearch {
    nonisolated public static let minimumQueryLength = 3

    /// Minimum score for a query to be allowed to *bind* to a catalog item. Below this the top
    /// hit matched only via category/tags (no real name signal) and is treated as no match.
    nonisolated public static let minimumBindScore = 1
    /// At or above this score a single-item bind is considered confident (exact/prefix/substring
    /// name hit). Between `minimumBindScore` and this, the bind is kept but flagged low-confidence.
    nonisolated public static let confidentBindScore = 250

    /// A prebuilt search index over a food list: normalized names and token sets per item.
    ///
    /// Build once per catalog snapshot and reuse across queries — construction does the per-item
    /// normalization so each query only normalizes itself.
    public struct Index: Sendable {
        private let entries: [Entry]

        public init(foodItems: [FoodItem]) {
            self.entries = foodItems.map { foodItem in
                let name = FoodItemSearch.normalized(foodItem.name)
                let category = FoodItemSearch.normalized(foodItem.category)
                let tags = foodItem.tags.map { FoodItemSearch.normalized($0) }.joined(separator: " ")
                let searchable = [name, category, tags].joined(separator: " ")
                return Entry(
                    foodItem: foodItem,
                    normalizedName: name,
                    nameTokens: Set(name.split(separator: " ").map(String.init)),
                    searchableTokens: FoodItemSearch.tokens(in: searchable)
                )
            }
        }

        /// The immutable empty index. `Index`/`Entry` hold only `Sendable` values and `entries`
        /// is assigned once in `init`, so the constant is concurrency-safe by construction.
        public static let empty = Index(foodItems: [])

        fileprivate func matches(queryTokens: [String], normalizedQuery: String, limit: Int) -> [FoodItem] {
            scoredMatches(queryTokens: queryTokens, normalizedQuery: normalizedQuery, limit: limit).map(\.foodItem)
        }

        fileprivate func scoredMatches(queryTokens: [String], normalizedQuery: String, limit: Int) -> [(foodItem: FoodItem, score: Int)] {
            let isBrandQuery = FoodBrandLexicon.queryContainsBrandToken(normalizedQuery)
            return Array(
                entries
                    .compactMap { entry -> (foodItem: FoodItem, score: Int)? in
                        guard let score = FoodItemSearch.score(entry, queryTokens: queryTokens, normalizedQuery: normalizedQuery) else { return nil }
                        return (entry.foodItem, score)
                    }
                    .sorted { first, second in
                        if first.foodItem.source != second.foodItem.source {
                            return FoodItemSearch.sourcePriority(first.foodItem.source) > FoodItemSearch.sourcePriority(second.foodItem.source)
                        }
                        let firstType = FoodItemSearch.dataTypePriority(first.foodItem.dataType, brandQuery: isBrandQuery)
                        let secondType = FoodItemSearch.dataTypePriority(second.foodItem.dataType, brandQuery: isBrandQuery)
                        if firstType != secondType { return firstType > secondType }
                        if first.score != second.score { return first.score > second.score }
                        return first.foodItem.name.localizedStandardCompare(second.foodItem.name) == .orderedAscending
                    }
                    .prefix(limit)
            )
        }

        public func exactNameMatch(for normalizedName: String) -> FoodItem? {
            entries
                .filter { $0.normalizedName == normalizedName }
                .sorted {
                    if $0.foodItem.source != $1.foodItem.source {
                        return FoodItemSearch.sourcePriority($0.foodItem.source) > FoodItemSearch.sourcePriority($1.foodItem.source)
                    }
                    return $0.foodItem.name.localizedStandardCompare($1.foodItem.name) == .orderedAscending
                }
                .first?
                .foodItem
        }

        /// One indexed food with its precomputed normalized name and token sets.
        ///
        /// Internal to the index; exists so scoring never re-normalizes catalog text per query.
        fileprivate struct Entry: Sendable {
            var foodItem: FoodItem
            var normalizedName: String
            var nameTokens: Set<String>
            var searchableTokens: [String]
        }
    }

    public static func results(for query: String, in foodItems: [FoodItem], limit: Int = 6) -> [FoodItem] {
        results(for: query, in: Index(foodItems: foodItems), limit: limit)
    }

    public static func results(for query: String, in index: Index, limit: Int = 6) -> [FoodItem] {
        // R5: `limit` reaches `prefix(_:)`, which traps on a negative length. Asking for no results
        // is answered with no results.
        guard limit > 0 else { return [] }
        let normalizedQuery = normalized(query)
        guard normalizedQuery.count >= minimumQueryLength else { return [] }
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }
        return index.matches(queryTokens: queryTokens, normalizedQuery: normalizedQuery, limit: limit)
    }

    /// Like `results(for:in:limit:)` but returns the internal relevance score alongside each item
    /// so callers can apply a confidence floor (e.g. drop weak binds, flag low-confidence matches).
    public static func scoredResults(for query: String, in index: Index, limit: Int = 6) -> [(item: FoodItem, score: Int)] {
        guard limit > 0 else { return [] }
        let normalizedQuery = normalized(query)
        guard normalizedQuery.count >= minimumQueryLength else { return [] }
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }
        return index.scoredMatches(queryTokens: queryTokens, normalizedQuery: normalizedQuery, limit: limit)
            .map { (item: $0.foodItem, score: $0.score) }
    }

    /// Folds arbitrary text to the canonical form the food index is keyed by: diacritics stripped,
    /// case flattened, every non-alphanumeric run collapsed to a single space, trimmed.
    ///
    /// The `locale: nil` is load-bearing, and pinning it fixes a live bug rather than preparing for
    /// one. This same function bakes the 118,317-row `FoodCatalog.sqlite` index at build time, on an
    /// English machine — so the index is, permanently, whatever English folding produced. Passing
    /// `locale: .current` meant the QUERY side folded by the user's locale instead: on any locale
    /// whose case or diacritic rules differ from English (Turkish dotless ı is the classic — "I"
    /// folds to "ı", not "i") the query and the index stopped agreeing, and the search returned
    /// nothing with no error anywhere to say why. The two sides have to fold identically, and the
    /// index side cannot be re-baked per user, so both are pinned to the locale-independent rules.
    ///
    /// `nil` (not `en_US_POSIX`) because it is what `folding` documents for "use the non-localized,
    /// default Unicode rules" — the identical pin `ItemNameModeration` already uses. It is the same
    /// invariant `FernletDate` states for its `en_US_POSIX` day keys: a value that other stored data
    /// is matched against must never vary with the user's locale.
    nonisolated public static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : " "
            }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func score(_ entry: Index.Entry, queryTokens: [String], normalizedQuery: String) -> Int? {
        guard queryTokens.allSatisfy({ queryToken in
            let variants = matchVariants(for: queryToken)
            return entry.searchableTokens.contains { foodToken in
                variants.contains { variant in
                    foodToken == variant || foodToken.hasPrefix(variant)
                }
            }
        }) else {
            return nil
        }

        var score = 0
        let name = entry.normalizedName
        if name == normalizedQuery { score += 1_000 }
        if name.hasPrefix(normalizedQuery) { score += 500 }
        if name.contains(normalizedQuery) { score += 250 }
        score += queryTokens.reduce(0) { partial, queryToken in
            partial + (entry.nameTokens.contains(queryToken) ? 60 : 0)
        }
        score -= max(name.count - normalizedQuery.count, 0) / 8
        score += preparationBias(queryTokens: queryTokens, normalizedQuery: normalizedQuery, candidateName: entry.foodItem.name)
        score += formSpecificityBias(queryTokens: queryTokens, candidateName: entry.foodItem.name)
        return score
    }

    // Penalises candidates that are a derivative/sub-part *form* of a food the user named plainly.
    // e.g. query "egg" should resolve to whole egg, not "egg yolk", "egg white", or "egg powder";
    // "orange" should beat "orange juice"/"orange peel". Only fires when the candidate carries a
    // form qualifier the query did NOT ask for, so naming the part ("egg whites") keeps it neutral.
    private static func formSpecificityBias(queryTokens: [String], candidateName: String) -> Int {
        let querySet = Set(queryTokens)
        let candidateTokens = Set(normalized(candidateName).split(separator: " ").map(String.init))
        let extraneousForms = candidateTokens.intersection(formQualifierTokens).subtracting(querySet)
        return extraneousForms.isEmpty ? 0 : -130 * extraneousForms.count
    }

    // Tokens that mark a non-default form / derivative of a base food.
    nonisolated private static let formQualifierTokens: Set<String> = [
        "yolk", "yolks", "white", "whites", "powder", "powdered", "dried", "dehydrated",
        "concentrate", "paste", "juice", "extract", "substitute", "imitation", "peel",
        "skin", "skins", "flour", "flakes", "puree"
    ]

    // M1a: Additive preparation bias — rewards matching preparation, penalises conflicting ones.
    // Not a hard filter: a missing fresh entry still wins over nothing.
    private static func preparationBias(queryTokens: [String], normalizedQuery: String, candidateName: String) -> Int {
        let querySet = Set(queryTokens)
        let impliesRaw     = !querySet.isDisjoint(with: rawImpliedTokens)
        let impliesGrilled = !querySet.isDisjoint(with: grilledImpliedTokens)
        let impliesBaked   = !querySet.isDisjoint(with: bakedImpliedTokens)
        let impliesFried   = !querySet.isDisjoint(with: friedImpliedTokens)
        let impliesCanned  = !querySet.isDisjoint(with: cannedImpliedTokens)
            || normalizedQuery.contains("in water") || normalizedQuery.contains("in oil")
        let impliesSmoked  = querySet.contains("smoked")
        let impliesDried   = !querySet.isDisjoint(with: driedImpliedTokens)

        guard impliesRaw || impliesGrilled || impliesBaked || impliesFried
                || impliesCanned || impliesSmoked || impliesDried else { return 0 }

        let cand = normalized(candidateName)
        let isRaw     = cand.contains("raw") || cand.contains("fresh")
        let isGrilled = cand.contains("grilled")
        let isBaked   = cand.contains("baked") || cand.contains("roasted")
        let isFried   = cand.contains("fried") || cand.contains("breaded")
        let isCanned  = cand.contains("canned") || cand.contains("in water") || cand.contains("in oil")
        let isSmoked  = cand.contains("smoked")
        let isDried   = cand.contains("dried") || cand.contains("jerky")

        var bias = 0
        if impliesRaw {
            if isRaw                              { bias += 150 }
            else if isCanned || isDried || isSmoked { bias -= 200 }
        }
        if impliesGrilled {
            if isGrilled                    { bias += 150 }
            else if isCanned || isFried     { bias -= 200 }
        }
        if impliesBaked {
            if isBaked                      { bias += 150 }
            else if isCanned || isFried     { bias -= 150 }
        }
        if impliesFried {
            if isFried          { bias += 150 }
            else if isRaw       { bias -= 100 }
        }
        if impliesCanned {
            if isCanned                     { bias += 150 }
            else if isRaw || isGrilled      { bias -= 150 }
        }
        if impliesSmoked {
            if isSmoked                     { bias += 150 }
            else if isRaw || isCanned       { bias -= 100 }
        }
        if impliesDried {
            if isDried          { bias += 150 }
            else if isRaw       { bias -= 100 }
        }
        return bias
    }

    // Dish-context tokens that imply a preparation even without an explicit word
    nonisolated private static let rawImpliedTokens: Set<String>     = ["raw", "fresh", "sashimi", "sushi", "nigiri", "poke", "tartare", "ceviche"]
    nonisolated private static let grilledImpliedTokens: Set<String> = ["grilled", "grill", "bbq", "charbroiled"]
    nonisolated private static let bakedImpliedTokens: Set<String>   = ["baked", "roasted"]
    nonisolated private static let friedImpliedTokens: Set<String>   = ["fried", "breaded", "crispy", "tempura"]
    nonisolated private static let cannedImpliedTokens: Set<String>  = ["canned", "tinned"]
    nonisolated private static let driedImpliedTokens: Set<String>   = ["dried", "jerky", "dehydrated"]

    private static func sourcePriority(_ source: FoodItemSource) -> Int {
        switch source {
        case .manual: 3
        case .usda: 2
        case .aiResolved: 1
        }
    }

    public static func dataTypePriority(_ dataType: FoodDataType, brandQuery: Bool) -> Int {
        if brandQuery {
            switch dataType {
            case .restaurant: return 5
            case .branded: return 4
            case .foundation: return 3
            case .survey: return 2
            case .srLegacy: return 1
            }
        } else {
            switch dataType {
            case .foundation: return 5
            case .survey: return 4
            case .srLegacy: return 3
            case .branded: return 2
            case .restaurant: return 1
            }
        }
    }

    private static func tokens(in text: String) -> [String] {
        normalized(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    /// The query tokens used by the scorer's hard match gate (normalized, length ≥ 2). Exposed so the
    /// SQLite candidate source can build an FTS5 prefix-AND query that mirrors the gate exactly: a
    /// row passes FTS iff every token matches some indexed token by equality or prefix.
    nonisolated public static func searchTokens(in text: String) -> [String] {
        tokens(in: text)
    }

    /// Minimum token length before we attempt singular/plural normalization. Keeps short tokens
    /// ("as", "is", "gas") from being stemmed into over-broad 2-letter prefixes; the derived stem is
    /// always ≥ 3 characters.
    nonisolated private static let minimumStemTokenLength = 4

    /// The acceptable match forms for a single query token, used by BOTH the in-memory scorer gate
    /// (above) and the SQLite FTS5 candidate query (`BundledFoodStore.candidates`). Returns the token
    /// itself plus, when it looks like a regular English plural, its singular stem — so a plural query
    /// ("eggs", "oats", "grapes", "berries") can reach the singular canonical food ("egg", "oat",
    /// "grape", "berry") that the one-directional prefix gate would otherwise miss (`egg*` matches but
    /// `eggs*` doesn't). Each form is applied as an equality-or-prefix match by the scorer and as a
    /// `form*` prefix term by FTS, so the two paths stay in lockstep: a food token passes iff some
    /// variant is a prefix of it, exactly what `form*` matches in the index.
    nonisolated public static func matchVariants(for token: String) -> [String] {
        guard let stem = singularStem(token), stem != token else { return [token] }
        return [token, stem]
    }

    /// Conservative singular stem for a regular English plural. Only the two suffixes needed to reach
    /// the canonical singular foods are handled — `ies → y` (berries → berry) and a trailing `s`
    /// (eggs → egg, oats → oat, grapes → grape). We deliberately do NOT strip `es` wholesale (that
    /// would mangle non-plurals) since the trailing-`s` rule already recovers `grape`/`apple`/`banana`
    /// via the scorer's / FTS's prefix match. Possessive/mass `ss` endings ("grass") are left alone.
    nonisolated private static func singularStem(_ token: String) -> String? {
        guard token.count >= minimumStemTokenLength else { return nil }
        if token.hasSuffix("ies"), token.count >= 5 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("s"), !token.hasSuffix("ss") {
            return String(token.dropLast(1))
        }
        return nil
    }
}

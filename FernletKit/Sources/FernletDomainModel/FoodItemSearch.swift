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

    /// The token-level twin of ``queryContainsBrandToken``: every chain name (not just whether one
    /// exists) that `text` contains as a normalized substring, sorted for a deterministic order.
    ///
    /// Added for research §26 fix 1.5 — `DishTemplateLexicon` needs to name WHICH chain a description
    /// mentioned (to surface it as an unmatched item) rather than only a yes/no signal, and this reuses
    /// `chains` instead of a caller re-deriving its own copy.
    ///
    /// **Widened by the fix's adversarial review, finding F1 — THIS function only.**
    /// `FoodItemSearch.normalized` maps an apostrophe to a bare SPACE (it keeps only letters/numbers),
    /// so "McDonald's" normalizes to "mcdonald s" — two tokens — while the lexicon entry is spelled
    /// "mcdonalds", the already-collapsed possessive. 12 of `chains`' 43 entries are canonically
    /// possessive (McDonald's, Wendy's, Arby's, Applebee's, Chili's, Denny's, Hardee's, Friendly's,
    /// Rally's, Domino's, Carl's Jr., Long John Silver's), so the CORRECT spelling of each one used to
    /// be silently missed while the incidentally-already-collapsed spelling worked. This also checks a
    /// possessive-collapsed form of `text` (a lone "s" token folded back onto the word before it —
    /// "mcdonald" + "s" → "mcdonalds") in addition to the plain normalized form.
    /// ``queryContainsBrandToken`` is deliberately left BYTE-UNCHANGED: its token-boundary semantics
    /// are `Docs/Food-Search-And-Community-Database-Research-2026-08-22.md` §37 Q7's open owner
    /// question, and widening the wrong function would prejudge that decision.
    ///
    /// **Widened again, same review, the Lm-apostrophe finding.** U+2019/U+2018 (the curly "smart
    /// quote" apostrophes iOS text fields insert by default) already work with NO further change here:
    /// they are Unicode punctuation, not letters, so `FoodItemSearch.normalized` already treats them as
    /// a separator exactly like the ASCII `'` — "wendy’s" normalizes to "wendy s" and the possessive
    /// collapse above reunites it. U+02BC (MODIFIER LETTER APOSTROPHE) and U+02BB (MODIFIER LETTER
    /// TURNED COMMA) are different: Unicode category **Lm — letters** — so `Character.isLetter` is
    /// TRUE for them and `normalized()` keeps one fused INSIDE its word run instead of splitting on it:
    /// "wendyʼs" (U+02BC) normalizes to the single token "wendyʼs", which neither the raw substring
    /// check nor the possessive collapse (which needs a SEPARATE trailing "s" token to reunite) can
    /// ever match against the lexicon's "wendys". Reachable from third-party/locale keyboards and text-
    /// canonicalization pipelines that map the apostrophe to U+02BC. `apostropheNormalized` below
    /// pre-maps these to the ASCII apostrophe before normalization runs, so they fall through the SAME
    /// separator + collapse path U+2019/U+2018/`'` already use — `FoodItemSearch.normalized` itself is
    /// still not touched.
    nonisolated public static func matchedChainTokens(in text: String) -> [String] {
        let n = FoodItemSearch.normalized(apostropheNormalized(text))
        let possessive = possessiveCollapsed(n)
        return chains.filter { n.contains($0) || possessive.contains($0) }.sorted()
    }

    /// Replaces Unicode letter-class (Lm) apostrophe look-alikes with the plain ASCII apostrophe —
    /// see ``matchedChainTokens(in:)``'s Lm-apostrophe note. U+A78C (LATIN SMALL LETTER SALTILLO) is
    /// visually near-identical to U+02BC and included for the same reason, though its real source is
    /// different (some Mexican indigenous orthographies use it as a real letter). Deliberately local
    /// to this file: `FoodItemSearch.normalized` is not touched, so nothing outside brand-chain
    /// matching changes shape.
    nonisolated private static func apostropheNormalized(_ text: String) -> String {
        let lmApostrophes: Set<Character> = ["\u{02BC}", "\u{02BB}", "\u{A78C}"]
        return String(text.map { lmApostrophes.contains($0) ? "'" : $0 })
    }

    /// Reunites a normalized possessive split ("mcdonald s" → "mcdonalds") back into one token —
    /// see ``matchedChainTokens(in:)``'s F1 note. A lone single-character "s" token is folded onto
    /// the token immediately before it; every other token passes through unchanged. A standalone "s"
    /// arising from anything OTHER than a stripped apostrophe is not a realistic token in typed food
    /// text, so this is safe as a general collapse rather than a per-chain special case.
    nonisolated private static func possessiveCollapsed(_ normalizedText: String) -> String {
        let tokens = normalizedText.split(separator: " ").map(String.init)
        var collapsed: [String] = []
        for token in tokens {
            if token == "s", let last = collapsed.indices.last {
                collapsed[last] += "s"
            } else {
                collapsed.append(token)
            }
        }
        return collapsed.joined(separator: " ")
    }
}

/// Pure relevance search over ``FoodItem``s: normalization, tokenization, scoring, and ranking.
///
/// The in-memory half of food search — the SQLite-backed `FoodCatalog` sits above it and reuses
/// the same normalization/token/variant helpers (`searchTokens`, `matchVariants`) so its FTS5
/// candidate query stays in lockstep with this scorer's hard match gate.
///
/// **Ranking, in the order the keys are applied.** Research §26's coupled increment (fixes
/// 1.6/1.7a/1.8) changed steps 1 and 4 and added step 5; steps 2 and 3 are byte-unchanged, which is
/// what keeps this option (a) — data type still outranks the score everywhere.
/// 1. the hard match gate — every *search token* must equal-or-prefix some indexed token, where the
///    search tokens are stopword-filtered by position (fix 1.6, see ``searchTokens(in:)``);
/// 2. `sourcePriority` (manual > USDA > AI), then brand-aware `dataTypePriority`, ABOVE the score;
/// 3. the relevance score (exact/prefix/substring name hits, per-token coverage, length penalty,
///    preparation and form-specificity biases), then the name as a final tie-break;
/// 4. **the search floor** — a row whose NAME does not carry every search token is dropped rather
///    than presented undifferentiated beside real hits, AND it must clear ``minimumBindScore``
///    (fix 1.8's two halves — see ``nameCarriesQuery(_:query:)``). Applied during scoring, so a
///    floored row never enters the ranking at all;
/// 5. **prepared-dish demotion** — for a query whose head noun is not a dish word, assembled dishes
///    sink below the raw ingredients, but only below ingredients that match at least as well
///    (fix 1.7a, see ``PreparedDishHeuristic/demotingDishes(scored:forQuery:)``). Applied to a
///    bounded window (``demotionWindow``) BEFORE the caller's `limit`, so it can surface a row the
///    top-6 truncation would otherwise have hidden, without paying a per-keystroke cost over the
///    whole result set.
///
/// `minimumBindScore`/`confidentBindScore` are the confidence floors quick-log binding applies to
/// `scoredResults`.
public nonisolated enum FoodItemSearch {
    nonisolated public static let minimumQueryLength = 3

    /// Minimum score for a query to be allowed to *bind* to a catalog item. Below this the top
    /// hit matched only via category/tags (no real name signal) and is treated as no match.
    nonisolated public static let minimumBindScore = 1
    /// At or above this score a single-item bind is considered confident (exact/prefix/substring
    /// name hit). Between `minimumBindScore` and this, the bind is kept but flagged low-confidence.
    nonisolated public static let confidentBindScore = 250

    /// How many ranked rows the prepared-dish demotion considers before the caller's
    /// `limit` is applied.
    ///
    /// Bounded on purpose (Power-of-10 rule 2): a broad prefix hydrates up to `candidateFetchLimit`
    /// (10,000) rows, and `PreparedDishHeuristic.isPreparedDish` normalizes a name per row, so an
    /// unbounded pass would add a five-figure string fold to every typeahead keystroke. Ten times the
    /// default result limit is far more than any surface shows and leaves ample room for demotion to
    /// pull a raw ingredient up from below the fold.
    nonisolated static let demotionWindow = 60

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

        fileprivate func matches(_ query: SearchQuery, limit: Int) -> [FoodItem] {
            scoredMatches(query, limit: limit).map(\.foodItem)
        }

        /// Scores, ranks, floors and demotes — steps 1–5 of the ordering documented on
        /// ``FoodItemSearch``. `query` carries both the stopword-stripped tokens the gate and the
        /// scorer use and the full normalized text the brand lexicon and the dish heuristic read.
        fileprivate func scoredMatches(_ query: SearchQuery, limit: Int) -> [(foodItem: FoodItem, score: Int)] {
            let isBrandQuery = FoodBrandLexicon.queryContainsBrandToken(query.normalized)
            // Fix 1.8's BOTH floors, applied as part of scoring so a floored row never enters the
            // ranking: name-substring carriage (`carries`) and the score floor at `minimumBindScore`. Fix
            // 1.7a then reorders a bounded window of what survives (see `demotionWindow`), before
            // `limit`, so demotion can surface a row from below the fold.
            let ranked = entries
                .compactMap { entry -> (foodItem: FoodItem, score: Int)? in
                    guard FoodItemSearch.carries(query.tokens, nameTokens: entry.nameTokens, name: entry.normalizedName),
                          let score = FoodItemSearch.score(entry, query: query),
                          score >= FoodItemSearch.minimumBindScore else { return nil }
                    return (entry.foodItem, score)
                }
                .sorted { first, second in
                    FoodItemSearch.ranksAhead(first, second, isBrandQuery: isBrandQuery)
                }
            let window = ranked.prefix(max(limit, FoodItemSearch.demotionWindow))
            let ordered = PreparedDishHeuristic.demotingDishes(scored: Array(window), forQuery: query.normalized)
            return Array(ordered.prefix(limit))
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

    /// One prepared query: the tokens the gate and scorer work in, the text the score bonuses are
    /// measured against, and the full normalized text the brand lexicon and dish heuristic read.
    ///
    /// The three are NOT the same string once stopwords are stripped (research §26 fix 1.6), and
    /// which one each consumer gets is load-bearing:
    ///
    /// * `tokens` — stopword-stripped, so `bowl of oatmeal` reaches the 690 `oatmeal` rows instead of
    ///   AND-ing an `of*` term nothing satisfies. `BundledFoodStore` builds its FTS5 MATCH expression
    ///   from the same ``searchTokens(in:)``, so the retrieval gate and this scorer's gate stay the
    ///   identical set (the "FTS gate == scorer gate" invariant).
    /// * `effective` — the tokens rejoined, so the exact / prefix / substring name bonuses and the
    ///   length penalty are measured against what was actually searched for. Without it every row for
    ///   `bowl of oatmeal` would score a bare +60 and the tier would be resolved alphabetically.
    ///   Byte-identical to `normalized` whenever no stopword was dropped, so a query without one
    ///   scores exactly as it did before the fix.
    /// * `normalized` — the untouched fold of the typed text. Brand detection reads it so its
    ///   substring test is unchanged, and ``PreparedDishHeuristic`` reads it because a stripped word
    ///   is often the very word that reveals the intent: the head noun of `cheese pizza slice` is
    ///   "slice", which says a PIECE of something, not the assembled dish.
    fileprivate struct SearchQuery {
        let tokens: [String]
        let effective: String
        let normalized: String
    }

    /// Prepares `query`, or nil when it cannot search (too short, or no usable token).
    ///
    /// `stripsStopwords` is what confines fix 1.6 to the surface it was designed for — see
    /// ``results(for:in:limit:stripsStopwords:)``.
    private static func searchQuery(_ query: String, stripsStopwords: Bool) -> SearchQuery? {
        let normalizedQuery = normalized(query)
        guard normalizedQuery.count >= minimumQueryLength else { return nil }
        let rawTokens = tokens(in: query)
        let searchTokens = stripsStopwords ? stopWordFiltered(rawTokens) : rawTokens
        guard !searchTokens.isEmpty else { return nil }
        return SearchQuery(
            tokens: searchTokens,
            effective: searchTokens.count == rawTokens.count ? normalizedQuery : searchTokens.joined(separator: " "),
            normalized: normalizedQuery
        )
    }

    public static func results(for query: String, in foodItems: [FoodItem], limit: Int = 6, stripsStopwords: Bool = true) -> [FoodItem] {
        results(for: query, in: Index(foodItems: foodItems), limit: limit, stripsStopwords: stripsStopwords)
    }

    /// - Parameter stripsStopwords: Whether fix 1.6's position-based stopword filter applies.
    ///   **True only for a query a PERSON TYPED.** `FoodSelectionCandidateBuilder.searchPhrases`
    ///   already decomposes a description into overlapping 3/2/1-word sub-phrases, which is its own
    ///   way of un-sticking "bowl of oatmeal", and it keeps quantity words on purpose because in a
    ///   sub-phrase they are the DISCRIMINATOR, not leading noise. Stripping them again there was
    ///   measured to reintroduce §29's hazard on the resolver surface: the sub-phrase "slices pizza"
    ///   became "pizza", and `two slices of pizza` lost every sliced-pizza row from its candidate
    ///   pool. Callers that pass a sub-phrase pass `false`.
    public static func results(for query: String, in index: Index, limit: Int = 6, stripsStopwords: Bool = true) -> [FoodItem] {
        // R5: `limit` reaches `prefix(_:)`, which traps on a negative length. Asking for no results
        // is answered with no results.
        guard limit > 0, let prepared = searchQuery(query, stripsStopwords: stripsStopwords) else { return [] }
        return index.matches(prepared, limit: limit)
    }

    /// Like `results(for:in:limit:)` but returns the internal relevance score alongside each item
    /// so callers can apply a confidence floor (e.g. drop weak binds, flag low-confidence matches).
    ///
    /// Every returned row already carries every search token in its NAME (fix 1.8's floor,
    /// ``nameCarriesQuery(_:query:)``), so a caller's own `minimumBindScore` check now sits on top of
    /// a name-signal guarantee rather than being the only thing standing between a tag-only match and
    /// a logged meal.
    public static func scoredResults(for query: String, in index: Index, limit: Int = 6, stripsStopwords: Bool = true) -> [(item: FoodItem, score: Int)] {
        guard limit > 0, let prepared = searchQuery(query, stripsStopwords: stripsStopwords) else { return [] }
        return index.scoredMatches(prepared, limit: limit)
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

    /// The comparator: source priority, then brand-aware data-type priority, then score, then name.
    ///
    /// Extracted from `scoredMatches` unchanged — data type still outranks the score, which is
    /// research §26 fix 1.7 **option (b)**, NOT taken here. Fix 1.7a leaves this ordering alone and
    /// reorders afterwards, so no search surface silently changes its provenance preference.
    private static func ranksAhead(
        _ first: (foodItem: FoodItem, score: Int),
        _ second: (foodItem: FoodItem, score: Int),
        isBrandQuery: Bool
    ) -> Bool {
        if first.foodItem.source != second.foodItem.source {
            return sourcePriority(first.foodItem.source) > sourcePriority(second.foodItem.source)
        }
        let firstType = dataTypePriority(first.foodItem.dataType, brandQuery: isBrandQuery)
        let secondType = dataTypePriority(second.foodItem.dataType, brandQuery: isBrandQuery)
        if firstType != secondType { return firstType > secondType }
        if first.score != second.score { return first.score > second.score }
        return first.foodItem.name.localizedStandardCompare(second.foodItem.name) == .orderedAscending
    }

    /// Half of the search path's presentation floor — research §26 fix 1.8: **does this row's own
    /// NAME carry everything that was typed?** The other half is the score floor at
    /// ``minimumBindScore``, applied beside it in `scoredMatches`.
    ///
    /// **The two are complementary, not alternatives, and each one alone was measured wrong.**
    ///
    /// * Carriage alone keeps junk. Rows literally NAMED *Chili* and *Beef Chili* carry `chilis`
    ///   perfectly well and score **0**, because the +60 coverage bonus needs token EQUALITY and the
    ///   name token is the singular. Only the SCORE floor refuses them (§9(b)).
    /// * The score floor alone deletes correct answers, because the +60 coverage bonus requires a
    ///   query token to EQUAL a name token (§8's own defect list), so a stem-reached match earns
    ///   nothing and the length penalty carries it negative.
    /// * Carriage by whole-token prefix ALONE deletes canonical rows. `burger` loses *Hamburger, NFS*
    ///   and *Cheeseburger, NFS*, because "hamburger" does not START with "burger" — while keeping
    ///   *BURGER KING, Chicken Strips*, where the brand put the word at a token boundary. So carriage
    ///   also accepts a SUBSTRING hit anywhere in the name, which is not a loosening but an
    ///   alignment: it is the same notion of "the name says this" that the scorer's own +250
    ///   substring bonus uses, and it is what makes that bonus and this floor agree about `burger`.
    ///
    /// **Category and tags both stay OUT, and the category half was tried and measured wrong.**
    /// Admitting the category — an obvious reading of "the row's own taxonomy" — resurrected exactly
    /// the rows this fix exists to remove: *Calzone, with cheese, meatless* is categorised
    /// `Survey (FNDDS) - Pizza`, so `cheese pizza` handed its top-1 straight back to §29's calzone,
    /// and *Banquet Breakfast Chicken Sandwich* is categorised `Sandwiches/Filled Rolls/Wraps`, whose
    /// "Filled" satisfies the brand fragment "fil" and cost `chick fil a sandwich` its correct
    /// CHICK-FIL-A row. A category says what a food is FILED UNDER, not what it IS. The substring
    /// rule above recovers every canonical row the category was wanted for, without either.
    ///
    /// Token matching is the gate's own equality-or-prefix over ``matchVariants(for:)``, so the floor
    /// can never reject a row the gate accepted for a reason the gate would not recognise.
    nonisolated private static func carries(_ queryTokens: [String], nameTokens: Set<String>, name: String) -> Bool {
        queryTokens.allSatisfy { queryToken in
            let variants = matchVariants(for: queryToken)
            return variants.contains { variant in
                name.contains(variant) || nameTokens.contains { $0 == variant || $0.hasPrefix(variant) }
            }
        }
    }

    /// ``carries(_:nameTokens:name:)`` over a raw name, for callers that hold a food rather than an
    /// index entry (the corpus instrument asserts the RULE with this, not a pinned row list).
    ///
    /// - Parameter stripsStopwords: Must match the call that produced the row. It defaults to `true`
    ///   (the typed-query surface) and the default is a TRAP for anyone checking a row that came back
    ///   from a `stripsStopwords: false` search: tested with stripping on, "cheese pizza slice" asks
    ///   only whether the name carries "cheese pizza", which is a weaker question than the one the
    ///   floor actually asked. Parameterized rather than documented-around.
    nonisolated public static func nameCarriesQuery(_ name: String, query: String, stripsStopwords: Bool = true) -> Bool {
        let folded = normalized(name)
        return carries(searchTokens(in: query, stripsStopwords: stripsStopwords),
                       nameTokens: Set(folded.split(separator: " ").map(String.init)),
                       name: folded)
    }

    /// Scores one gate-passing entry, or nil when it does not pass the gate.
    ///
    /// The gate below is kept even though `scoredMatches` now applies the strictly narrower name
    /// floor first (a name token is a searchable token, so passing the floor implies passing this):
    /// `score` is the definition of "does this row match at all", and a function that answers that
    /// question by assuming its caller already did is a trap for the next caller.
    private static func score(_ entry: Index.Entry, query: SearchQuery) -> Int? {
        guard query.tokens.allSatisfy({ queryToken in
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
        score += max(phraseScore(name: name, phrase: query.normalized),
                     phraseScore(name: name, phrase: query.effective))
        score += query.tokens.reduce(0) { partial, queryToken in
            partial + (entry.nameTokens.contains(queryToken) ? 60 : 0)
        }
        score += preparationBias(queryTokens: query.tokens, normalizedQuery: query.effective, candidateName: entry.foodItem.name)
        score += formSpecificityBias(queryTokens: query.tokens, candidateName: entry.foodItem.name)
        return score
    }

    /// The whole-phrase half of the score — exact / prefix / substring name hits, less the length
    /// penalty — measured against one candidate phrasing of the query.
    ///
    /// Evaluated against BOTH the typed phrase and the stopword-stripped phrase, best wins, because
    /// each is right for a different caller and neither is right for both:
    ///
    /// * The typed phrase is what a long ENGINEERED search string needs. `DishTemplates.json` binds
    ///   its components with strings copied from catalog names — "soup tomato canned prepared with
    ///   equal volume water" — and the name it must reach contains "with". Scoring only the stripped
    ///   phrase costs that bind its +500 prefix AND +250 substring bonuses at once, which measurably
    ///   handed the tomato-soup component to a *bisque* row on a tie-break.
    /// * The stripped phrase is what a TYPED query needs. `bowl of oatmeal` is a substring of no
    ///   name, so scoring only the typed phrase leaves every candidate on a bare +60 and resolves the
    ///   whole tier alphabetically; against "oatmeal" the same bonuses fire and *Oatmeal, NFS* wins.
    ///
    /// When no stopword was dropped the two phrases are identical, so a query without one scores
    /// exactly as it did before fix 1.6 — bit for bit, including the length penalty.
    nonisolated private static func phraseScore(name: String, phrase: String) -> Int {
        var score = 0
        if name == phrase { score += 1_000 }
        if name.hasPrefix(phrase) { score += 500 }
        if name.contains(phrase) { score += 250 }
        return score - max(name.count - phrase.count, 0) / 8
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

    /// The query tokens used by the scorer's hard match gate (normalized, length ≥ 2, stopwords
    /// dropped unless `stripsStopwords` is false). Exposed so the SQLite candidate source can build
    /// an FTS5 prefix-AND query that mirrors the gate exactly: a row passes FTS iff every token
    /// matches some indexed token by equality or prefix.
    ///
    /// **Both sides call this function AND must pass the same `stripsStopwords`.** Sharing the
    /// function is necessary and not sufficient: while the flag existed only on the scorer side,
    /// retrieval stripped quantity words on the resolver path while scoring kept them, and the two
    /// gates silently described different row sets — see
    /// `SQLiteBundledFoodSource.candidates(forQuery:stripsStopwords:)` for the measured consequence.
    nonisolated public static func searchTokens(in text: String, stripsStopwords: Bool = true) -> [String] {
        stripsStopwords ? stopWordFiltered(tokens(in: text)) : tokens(in: text)
    }

    // MARK: - Stopwords (research §26 fix 1.6)

    /// Words that are never part of a food's name and only ever narrow the AND gate. Dropped wherever
    /// they appear.
    ///
    /// This is the function-word half of the 18-word set at `FoodSelectionCandidateBuilder`'s
    /// `searchPhrases` — which has stripped them for the RESOLVER since long before search did, which
    /// is exactly why the two surfaces disagree on `bowl of oatmeal` (nothing vs a full pool). "a" is
    /// absent because the length-2 filter already removes it.
    ///
    /// **Frozen English matching input** (localization wall): these are compared against
    /// `normalized()` output, which folds an index baked in English at build time. They must never be
    /// localized, and no display string is derived from them.
    nonisolated private static let functionStopWords: Set<String> = [
        "and", "with", "plus", "then", "for", "the", "an", "of", "my"
    ]

    /// Household-measure and count words — dropped only from the LEADING run of the query.
    ///
    /// The position rule is the whole safety margin, and §29 is why it exists. A measure word
    /// quantifies what FOLLOWS it: "bowl of oatmeal", "two scrambled eggs", "slice of toast" all name
    /// the food after the measure, so dropping the leading word recovers the food. A TRAILING one is
    /// part of the dish's name — "chicken burrito bowl", "chipotle chicken bowl", "cheese pizza
    /// slice" — and §29 demonstrates the cost of stripping it anyway: with "slice" gone, `cheese pizza
    /// slice` stops being a branded sliced-pizza query and the survey tier hands back a 1,655 kcal
    /// calzone. Leading-only strips nothing from those three queries at all.
    ///
    /// Frozen English matching input, as above.
    nonisolated private static let quantityStopWords: Set<String> = [
        "bowl", "bowls", "glass", "glasses", "plate", "plates", "cup", "cups",
        "handful", "handfuls", "piece", "pieces", "slice", "slices",
        "serving", "servings", "half", "two", "three", "four", "five", "six", "dozen"
    ]

    /// Meal-occasion words — dropped only from the TRAILING run, the mirror of the rule above.
    ///
    /// An occasion qualifies the food it follows ("pizza for dinner", "yogurt post workout"), while a
    /// LEADING occasion word is part of the food's name — "breakfast burrito", "breakfast sandwich",
    /// "dinner rolls", "snack mix" are all real catalog rows that a positionless strip would silently
    /// dissolve.
    ///
    /// Frozen English matching input, as above.
    nonisolated private static let occasionStopWords: Set<String> = [
        "meal", "breakfast", "lunch", "dinner", "snack", "pre", "post", "workout"
    ]

    /// The three sets, exposed read-only for the freeze pin in `FoodSearchCorpusTests`. They are
    /// frozen English matching inputs and the localization wall's own machinery cannot see them (it
    /// parses enum rawValues, and these are bare `Set<String>` literals), so a test asserts their
    /// contents instead.
    nonisolated public static var functionStopWordsForTesting: Set<String> { functionStopWords }
    /// See ``functionStopWordsForTesting``.
    nonisolated public static var quantityStopWordsForTesting: Set<String> { quantityStopWords }
    /// See ``functionStopWordsForTesting``.
    nonisolated public static var occasionStopWordsForTesting: Set<String> { occasionStopWords }

    /// Applies the three stopword rules, in order, and never returns empty.
    ///
    /// The never-empty guarantee is the second half of §29's rule ("never widen the pool without the
    /// floor and the demotion catching what floods in"): a query made only of stopwords — "a bowl",
    /// "pre workout" — must search for what was typed rather than for nothing at all, which would
    /// present an empty list for a query that has perfectly good matches.
    nonisolated private static func stopWordFiltered(_ tokens: [String]) -> [String] {
        let withoutFunctionWords = tokens.filter { !functionStopWords.contains($0) }
        let withoutLeadingMeasures = withoutFunctionWords.drop { quantityStopWords.contains($0) }
        var kept = Array(withoutLeadingMeasures)
        // R2: bounded — one pass, at most `kept.count` removals.
        while let last = kept.last, occasionStopWords.contains(last) { kept.removeLast() }
        return kept.isEmpty ? tokens : kept
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

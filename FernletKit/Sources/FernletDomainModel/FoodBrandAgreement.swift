// FoodBrandAgreement.swift
// FernletDomainModel
//
// Which rows agree with a brand the person TYPED — the targeted brand-search fixes of 2026-10-29
// (Docs/Food-Search-Phase0-Baseline-2026-10-29.md). Pure value logic over normalized text; the typed
// search surface reads it, no resolver or confidence gate does.

import Foundation

/// Decides whether a typed query names a brand, and which rows carry it.
///
/// **Two kinds of evidence, both whole words.**
/// - A restaurant chain from ``FoodBrandLexicon`` agrees with a row whose name or brand field says the
///   chain ("CHICK-FIL-A, chicken sandwich"), possessives folded ("McDONALD'S" says "mcdonalds").
/// - Any other brand is a LEADING run of the query's words ("quest" in "quest protein bar", "heinz" in
///   "heinz ketchup") that the row's BRAND FIELD states as whole words. The name counts only when the
///   row has no brand field of its own — a USDA reference row ("USDA FDC 170720") writes its brand into
///   the name ("CAMPBELL'S, Chicken Noodle Soup"), and a person's own food carries a label the app
///   wrote ("Custom ingredient"), so their "Heinz ketchup" agrees through its name too. A row that
///   names another brand in its brand field does not agree through its name: "Potato Chips, Heinz
///   Ketchup" names Heinz as a flavour, and its brand field says Herr.
///
/// **When a run counts as a brand at all.** A generic word can sit in a brand name too ("Campbell Soup
/// Company", "Jennie-O Turkey Store"), so two rules keep generic searches unchanged:
/// - only a LEADING run is read as a brand for ranking — the last word is usually the food itself, and
///   "chicken noodle soup" must not treat "soup" as Campbell's brand;
/// - the run must sit in the BRAND FIELD of at least one row and of ``minimumAgreeingShare`` of the
///   rows that HAVE a brand of their own, and ``minimumAgreeingRows`` rows must say it at all (a
///   reference row or a person's own food naming it counts toward that minimum, never the share). The rows counted are the ones
///   that already matched plus the brand-field rows of ``FoodItemSearch/BrandFieldPool`` (the brand's
///   products whose names never say it). Reference rows and a person's own foods have no brand of their
///   own and stay out of both sides, so "chobani yogurt" on the base catalog (4 Chobani rows beside 17
///   USDA reference rows) still qualifies. Only once a run qualifies does a name count toward
///   agreement — counting names while deciding would make "Syrups, maple" vote for "maple" as a brand.
/// A one-word query has no run (a brand needs a product word beside it), so single-word searches never
/// change. ``splits(of:)`` also offers TRAILING runs, but only to the zero-result brand-field route,
/// which runs when nothing else matched.
///
/// **Why most, not a fifth (2026-11-09).** The first rule asked for a fifth of the matched rows, and
/// "turkey burger" cleared it: "turkey" is in the brand field of 30 % of them (Jennie-O Turkey Store),
/// so that maker's rows led every other turkey burger, a logged one included. Measured on the shipped
/// catalogs, with the brand-field rows counted, every brand query reads 67 % or more (Starbucks
/// frappuccino is the lowest) and every generic one under 50 % (turkey breast 35 %, candy corn 33 %,
/// fresh salsa 47 %).
///
/// **A brand word is matched across its possessive.** "amys" states "Amy's Kitchen" and "kelloggs"
/// states "Kellogg Company": a run word and a brand word agree when either is the other's regular
/// singular (``FoodItemSearch/matchVariants(for:)``), see ``statesBrand(_:in:)``.
///
/// Bounded: at most ``maximumRunWords`` words from each end, each run tested once per row.
///
/// Known limit: a brand whose rows all name it only as an owner ("Frito-Lay" for Doritos) cannot be told
/// apart from a flavour naming it, and stays in the order it had.
public nonisolated enum FoodBrandAgreement {
    /// The longest brand run tried at each end of the query.
    public static let maximumRunWords = 2
    /// The fewest rows that must say a run — in a brand field, or in a name that speaks for the brand —
    /// for it to count as a brand.
    public static let minimumAgreeingRows = 2
    /// The smallest share of the rows with a brand of their own that must carry the run.
    public static let minimumAgreeingShare = 0.6

    /// One way to read a query as brand + product: the brand words and the remaining product words.
    public struct Split: Equatable, Sendable {
        /// The brand run, in query order.
        public let brand: [String]
        /// The product words left over (never empty).
        public let product: [String]
    }

    /// One matched row's text, as the agreement test reads it.
    public struct Row: Equatable, Sendable {
        /// The row's normalized name.
        public let normalizedName: String
        /// The row's normalized brand field.
        public let normalizedBrand: String
        /// Whether the row is the person's own food (made by hand or estimated for them). Its brand
        /// field is a label the app wrote ("Custom ingredient", "Imported recipe"), not a rival brand.
        public let isPersonal: Bool

        public init(normalizedName: String, normalizedBrand: String, isPersonal: Bool = false) {
            self.normalizedName = normalizedName
            self.normalizedBrand = normalizedBrand
            self.isPersonal = isPersonal
        }

        /// Whether the row's NAME speaks for its brand: a person's own food, or a reference row with
        /// no brand field of its own.
        public var nameSpeaksForBrand: Bool {
            isPersonal || FoodBrandAgreement.isReferenceBrand(normalizedBrand)
        }
    }

    /// The typed brand a query was found to name, and how a row is tested against it.
    public struct TypedBrand: Equatable, Sendable {
        /// Chain phrases from ``FoodBrandLexicon`` the query names (normalized, possessives folded).
        public let chains: [String]
        /// The leading brand run, when one qualified.
        public let run: [String]?

        /// Whether `row` agrees with the typed brand.
        public func agrees(_ row: Row) -> Bool {
            if let run, FoodBrandAgreement.carries(run, row) { return true }
            let name = FoodBrandLexicon.possessiveCollapsed(row.normalizedName)
            let brand = FoodBrandLexicon.possessiveCollapsed(row.normalizedBrand)
            return chains.contains { chain in
                let words = chain.split(separator: " ").map(String.init)
                return FoodBrandAgreement.states(words, in: name) || FoodBrandAgreement.states(words, in: brand)
            }
        }
    }

    /// Every brand + product reading of `tokens`: leading runs first, then trailing, shortest first.
    /// Empty for a one-word query.
    public static func splits(of tokens: [String]) -> [Split] {
        guard tokens.count >= 2 else { return [] }
        var splits: [Split] = []
        for length in 1...min(maximumRunWords, tokens.count - 1) {
            splits.append(Split(brand: Array(tokens.prefix(length)), product: Array(tokens.dropFirst(length))))
            splits.append(Split(brand: Array(tokens.suffix(length)), product: Array(tokens.dropLast(length))))
        }
        return splits
    }

    /// Whether `words` appear as a contiguous whole-word run in the normalized `text`.
    public static func states(_ words: [String], in text: String) -> Bool {
        guard !words.isEmpty, !text.isEmpty else { return false }
        return (" " + text + " ").contains(" " + words.joined(separator: " ") + " ")
    }

    /// Whether a brand field is a USDA reference marker or empty — no brand of the row's own, so its
    /// name speaks for the brand.
    public static func isReferenceBrand(_ normalizedBrand: String) -> Bool {
        normalizedBrand.isEmpty || normalizedBrand.hasPrefix("usda fdc")
    }

    /// Whether the normalized brand field `brand` states `run` as contiguous whole words, a possessive
    /// or regular plural apart: "amys" and "amy" both state "amy s kitchen", "kelloggs" states "kellogg
    /// company". Stricter than a prefix ("quest" does not state "questionable foods") and looser than
    /// ``states(_:in:)`` only by that one fold.
    ///
    /// R2: bounded by the brand field's words times the run's (at most ``maximumRunWords``).
    public static func statesBrand(_ run: [String], in brand: String) -> Bool {
        // The cheap refusal first: the rule runs once per matched row on every typed keystroke, and a
        // word and its singular always share their first two letters ("fries" / "fry").
        guard let first = run.first, !brand.isEmpty, brand.contains(first.prefix(2)) else { return false }
        if states(run, in: brand) { return true }
        let words = FoodBrandLexicon.possessiveCollapsed(brand).split(separator: " ").map(String.init)
        guard words.count >= run.count else { return false }
        return (0...(words.count - run.count)).contains { start in
            zip(run, words[start...]).allSatisfy { typed, stored in sameBrandWord(typed, stored) }
        }
    }

    /// Whether a typed word and a brand-field word are one word, a regular singular apart either way.
    private static func sameBrandWord(_ typed: String, _ stored: String) -> Bool {
        typed == stored
            || FoodItemSearch.matchVariants(for: typed).contains(stored)
            || FoodItemSearch.matchVariants(for: stored).contains(typed)
    }

    /// Whether `row` carries the brand `run`: in its brand field, or in its name when the name speaks
    /// for the brand (``Row/nameSpeaksForBrand``, possessives folded).
    public static func carries(_ run: [String], _ row: Row) -> Bool {
        if statesBrand(run, in: row.normalizedBrand) { return true }
        guard row.nameSpeaksForBrand else { return false }
        return states(run, in: row.normalizedName)
            || states(run, in: FoodBrandLexicon.possessiveCollapsed(row.normalizedName))
    }

    /// The brand `tokens` name, judged against the rows that matched, or nil when the query names none.
    ///
    /// - Parameters:
    ///   - tokens: The query's search tokens.
    ///   - normalizedQuery: The whole normalized query (chain phrases are read from it).
    ///   - matched: Every row that passed the gate.
    ///   - brandFieldOnly: For a leading run (keyed by its words), how many MORE rows state it in their
    ///     brand field without having matched by name — the brand-field pool's rows
    ///     (``FoodItemSearch/BrandFieldPool``). Empty when no pool was fetched.
    public static func typedBrand(
        tokens: [String], normalizedQuery: String, matched: [Row], brandFieldOnly: [[String]: Int] = [:]
    ) -> TypedBrand? {
        let chains = FoodBrandLexicon.matchedChainTokens(in: normalizedQuery)
        let run = qualifyingRun(tokens: tokens, matched: matched, brandFieldOnly: brandFieldOnly)
        guard !chains.isEmpty || run != nil else { return nil }
        return TypedBrand(chains: chains, run: run)
    }

    /// The leading run the most rows carry, when it clears both thresholds; ties go to the longer run.
    private static func qualifyingRun(tokens: [String], matched: [Row], brandFieldOnly: [[String]: Int]) -> [String]? {
        guard tokens.count >= 2 else { return nil }
        var best: (run: [String], count: Int)?
        for length in 1...min(maximumRunWords, tokens.count - 1) {
            let run = Array(tokens.prefix(length))
            let extra = max(0, brandFieldOnly[run] ?? 0)
            var stating = 0, rivals = 0, named = 0
            // R2: one bounded pass over the matched rows.
            for row in matched {
                // Brand FIELDS decide: a reference row's name says food words too ("Syrups, maple").
                // A row that states the run has a brand of its own whatever else it is.
                if statesBrand(run, in: row.normalizedBrand) {
                    stating += 1
                } else if !row.nameSpeaksForBrand {
                    rivals += 1
                } else if carries(run, row) {
                    // A name counts only toward the row minimum, and only beside a brand field that
                    // says the run: the base catalog holds one Chobani blueberry yogurt and one
                    // reference row naming it.
                    named += 1
                }
            }
            let count = stating + extra
            guard count >= 1, count + named >= minimumAgreeingRows,
                  Double(count) >= minimumAgreeingShare * Double(count + rivals),
                  count >= (best?.count ?? 0) else { continue }
            best = (run, count)
        }
        return best?.run
    }
}

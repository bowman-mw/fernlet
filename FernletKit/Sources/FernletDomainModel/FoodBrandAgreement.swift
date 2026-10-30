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
///   the name ("CAMPBELL'S, Chicken Noodle Soup"). A row that names another brand in its brand field
///   does not agree through its name: "Potato Chips, Heinz Ketchup" names Heinz as a flavour, and its
///   brand field says Herr.
///
/// **When a run counts as a brand at all.** A generic word can sit in a brand name too ("Campbell Soup
/// Company", "Jennie-O Turkey Store"), so two rules keep generic searches unchanged:
/// - only a LEADING run is read as a brand for ranking — the last word is usually the food itself, and
///   "chicken noodle soup" must not treat "soup" as Campbell's brand;
/// - the run must sit in the BRAND FIELD of at least ``minimumAgreeingRows`` of the rows that already
///   matched, and of ``minimumAgreeingShare`` of them. Only once it qualifies does a reference row's
///   name count toward agreement — counting names while deciding would make "Syrups, maple" vote for
///   "maple" as a brand.
/// A one-word query has no run (a brand needs a product word beside it), so single-word searches never
/// change. ``splits(of:)`` also offers TRAILING runs, but only to the zero-result brand-field route,
/// which runs when nothing else matched.
///
/// Bounded: at most ``maximumRunWords`` words from each end, each run tested once per row.
///
/// Known limit: a brand whose rows all name it only as an owner ("Frito-Lay" for Doritos) cannot be told
/// apart from a flavour naming it, and stays in the order it had.
public nonisolated enum FoodBrandAgreement {
    /// The longest brand run tried at each end of the query.
    public static let maximumRunWords = 2
    /// The fewest matching rows that must carry a run for it to count as a brand.
    public static let minimumAgreeingRows = 2
    /// The smallest share of the matching rows that must carry the run.
    public static let minimumAgreeingShare = 0.2

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

        public init(normalizedName: String, normalizedBrand: String) {
            self.normalizedName = normalizedName
            self.normalizedBrand = normalizedBrand
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

    /// Whether `row` carries the brand `run`: in its brand field, or in its name when it has no brand
    /// field of its own (possessives folded).
    public static func carries(_ run: [String], _ row: Row) -> Bool {
        if states(run, in: row.normalizedBrand) { return true }
        guard isReferenceBrand(row.normalizedBrand) else { return false }
        return states(run, in: row.normalizedName)
            || states(run, in: FoodBrandLexicon.possessiveCollapsed(row.normalizedName))
    }

    /// The brand `tokens` name, judged against the rows that matched, or nil when the query names none.
    ///
    /// - Parameters:
    ///   - tokens: The query's search tokens.
    ///   - normalizedQuery: The whole normalized query (chain phrases are read from it).
    ///   - matched: Every row that passed the gate.
    public static func typedBrand(tokens: [String], normalizedQuery: String, matched: [Row]) -> TypedBrand? {
        let chains = FoodBrandLexicon.matchedChainTokens(in: normalizedQuery)
        let run = qualifyingRun(tokens: tokens, matched: matched)
        guard !chains.isEmpty || run != nil else { return nil }
        return TypedBrand(chains: chains, run: run)
    }

    /// The leading run the most matched rows carry, when it clears both thresholds; ties go to the
    /// longer run.
    private static func qualifyingRun(tokens: [String], matched: [Row]) -> [String]? {
        guard tokens.count >= 2, !matched.isEmpty else { return nil }
        var best: (run: [String], count: Int)?
        for length in 1...min(maximumRunWords, tokens.count - 1) {
            let run = Array(tokens.prefix(length))
            // Brand FIELDS only: a reference row's name says food words too ("Syrups, maple").
            let count = matched.filter { states(run, in: $0.normalizedBrand) }.count
            guard count >= minimumAgreeingRows,
                  Double(count) >= minimumAgreeingShare * Double(matched.count),
                  count >= (best?.count ?? 0) else { continue }
            best = (run, count)
        }
        return best?.run
    }
}

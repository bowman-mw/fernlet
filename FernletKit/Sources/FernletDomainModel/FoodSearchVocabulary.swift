// FoodSearchVocabulary.swift
// FernletDomainModel
//
// The labelled spelling suggestion of the 2026-10-29 targeted brand fixes
// (Docs/Food-Search-Phase0-Baseline-2026-10-29.md): "chobanni yogurt" → "chobani yogurt". A suggestion is
// only ever OFFERED — the search a person typed is never rewritten, and nothing here reaches automatic
// meal binding.

import Foundation

/// One word the catalog's search index knows, with how many foods carry it.
public nonisolated struct FoodSearchTerm: Equatable, Sendable {
    /// The indexed word (normalized, as the index stores it).
    public let term: String
    /// How many foods carry the word.
    public let documents: Int

    public init(term: String, documents: Int) {
        self.term = term
        self.documents = documents
    }
}

/// The words the catalog can find, grouped for a bounded nearest-spelling lookup.
///
/// **What counts as a misspelling.** A query word of at least ``minimumWordLength`` letters that the
/// index does not know — neither as a word nor as the start of a common word, so a half-typed word is
/// never "corrected" — or knows only from a few rows while a word one or two edits away is
/// ``dominanceFactor`` times more common ("protien" sits in one misspelt product name; "protein" in
/// thousands). The replacement is the nearest such word by optimal-string-alignment distance (a swap
/// of two neighbouring letters is one edit), within one edit for a word up to five letters and two
/// beyond; ties go to the more common word. A run-together restaurant chain ("chickfila") is offered
/// as the chain's own spelling.
///
/// **Bounded.** Only words sharing the first letter and within the edit budget in length are compared,
/// and at most ``maximumComparisons`` comparisons run per query.
public nonisolated struct FoodSearchVocabulary: Sendable {
    /// Shortest query word ever corrected.
    public static let minimumWordLength = 4
    /// A known word with fewer foods than this may still be a misspelling.
    public static let rareDocuments = 3
    /// How much more common a neighbour must be than a rare known word to replace it.
    public static let dominanceFactor = 10
    /// The most word comparisons one suggestion may run.
    public static let maximumComparisons = 40_000

    private let documents: [String: Int]
    private let byFirstLetter: [Character: [FoodSearchTerm]]

    /// Builds the vocabulary, summing a word's counts across sources.
    public init(terms: [FoodSearchTerm]) {
        var documents: [String: Int] = [:]
        for term in terms where !term.term.isEmpty {
            documents[term.term, default: 0] += term.documents
        }
        self.documents = documents
        self.byFirstLetter = Dictionary(grouping: documents.map { FoodSearchTerm(term: $0.key, documents: $0.value) }) {
            $0.term.first ?? " "
        }
    }

    /// Whether the vocabulary holds no words (no index could be read).
    public var isEmpty: Bool { documents.isEmpty }

    /// The query with each misspelt word replaced, or nil when nothing would change.
    public func suggestion(for query: String) -> String? {
        let words = FoodItemSearch.normalized(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var budget = Self.maximumComparisons
        let corrected = words.map { word in correction(for: word, budget: &budget) ?? word }
        return corrected == words ? nil : corrected.joined(separator: " ")
    }

    private func correction(for word: String, budget: inout Int) -> String? {
        if let chain = FoodBrandLexicon.chainSpelling(forRunTogether: word) { return chain }
        guard word.count >= Self.minimumWordLength, word.allSatisfy(\.isLetter),
              let first = word.first, let pool = byFirstLetter[first] else { return nil }
        let known = documents[word] ?? 0
        guard known < Self.rareDocuments, !isCommonPrefix(word, in: pool) else { return nil }
        let limit = word.count <= 5 ? 1 : 2
        let floor = max(Self.rareDocuments, Self.dominanceFactor * max(known, 1))
        var best: (term: String, distance: Int, documents: Int)?
        for candidate in pool where budget > 0 && candidate.documents >= floor && candidate.term != word
            && abs(candidate.term.count - word.count) <= limit {
            budget -= 1
            guard let distance = Self.distance(word, candidate.term, limit: limit) else { continue }
            if let current = best, current.distance < distance
                || (current.distance == distance && current.documents >= candidate.documents) { continue }
            best = (candidate.term, distance, candidate.documents)
        }
        return best?.term
    }

    /// Whether some common word starts with `word` — the person may still be typing it.
    private func isCommonPrefix(_ word: String, in pool: [FoodSearchTerm]) -> Bool {
        pool.contains { $0.documents >= Self.rareDocuments && $0.term.count > word.count && $0.term.hasPrefix(word) }
    }

    /// Optimal-string-alignment distance between `a` and `b`, or nil once it exceeds `limit`.
    /// R2: bounded by the two words' lengths.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int? {
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= limit else { return nil }
        guard !x.isEmpty, !y.isEmpty else { return max(x.count, y.count) <= limit ? max(x.count, y.count) : nil }
        var previous2 = [Int](repeating: 0, count: y.count + 1)
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            current[0] = i
            var rowMinimum = current[0]
            for j in stride(from: 1, through: y.count, by: 1) {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    current[j] = min(current[j], previous2[j - 2] + 1)
                }
                rowMinimum = min(rowMinimum, current[j])
            }
            guard rowMinimum <= limit else { return nil }
            previous2 = previous
            previous = current
        }
        let result = previous[y.count]
        return result <= limit ? result : nil
    }
}

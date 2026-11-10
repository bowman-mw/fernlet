// FoodBrandInitialism.swift
// FernletDomainModel
//
// A typed query that opens with a brand spelt in single letters — "m&m's", "a&w root beer", "h-e-b
// tortillas", "a.1. sauce" (food-search review 2026-11-09, finding F5). Pure value logic over the
// normalized query; `FoodCatalog`'s typed path reads it, no resolver or confidence gate does.

import Foundation

/// Reads the single-letter brand a typed query opens with.
///
/// The search tokenizer drops one-character words: they prefix half the catalog, so "m*" can never be
/// a search term. That left "M&M's" unreachable — "m&m's" folds to "m m s" and has no token at all,
/// and "m&ms" folds to "m ms" and searched `ms*`, which answers with MSG soup bases. The catalog still
/// stores the letters as words ("m m s milk chocolate candies"), so they can be found as an exact
/// PHRASE even though none can be a prefix term. This type says what that phrase is.
///
/// A reading needs two or more single characters at the START of the query, the first a letter:
/// - "m&m", "m & m", "m and m" → letters `m m`;
/// - "m&m's" and "m&ms" → `m m` too: a possessive `s`, typed apart or onto the last letter, is dropped
///   so "M&M Peanut" and "M&M'S Peanut" both answer;
/// - "a.1. sauce" → letters `a 1`, product "sauce" (a digit may follow the first letter);
/// - "7 up", "5 hour energy" and "1/2 cup oats" have no reading (they open with a digit), and neither
///   does "a bagel" or "t bone steak" (one letter is an article or part of a word, not a brand).
///
/// Frozen English matching input (localization wall): "and" and the possessive "s" are compared
/// against normalized catalog text baked in English.
///
/// Bounded: at most ``maximumLetters`` letters are read, in one pass over the query's words.
public nonisolated enum FoodBrandInitialism {
    /// The longest initialism read ("h e b" is three; nothing in the catalog needs more than four).
    public static let maximumLetters = 4

    /// A query read as a single-letter brand and the product words after it.
    public struct Reading: Equatable, Sendable {
        /// The brand's letters, in order ("m", "m").
        public let letters: [String]
        /// The normalized words after the brand ("peanut butter"), empty when only the brand was typed.
        public let product: String

        public init(letters: [String], product: String) {
            self.letters = letters
            self.product = product
        }

        /// The letters as the phrase a normalized name states them in ("m m").
        public var phrase: String { letters.joined(separator: " ") }
    }

    /// The reading of `query`, or nil when it does not open with a single-letter brand.
    public static func reading(of query: String) -> Reading? {
        let words = FoodItemSearch.normalized(query).split(separator: " ").map(String.init)
        guard let first = words.first, first.count == 1, first.first?.isLetter == true else { return nil }
        var letters: [String] = []
        var index = 0
        // R2: bounded by `maximumLetters` letters, each step consuming at least one word.
        while index < words.count, letters.count < maximumLetters {
            let word = words[index]
            if word.count == 1 {
                letters.append(word)
            } else if word == "and", !letters.isEmpty, index + 1 < words.count, startsLikeALetter(words[index + 1]) {
                // "m and m": the spoken ampersand between two letters.
            } else if let letter = possessiveLetter(word), !letters.isEmpty {
                letters.append(letter)
                index += 1
                break
            } else {
                break
            }
            index += 1
        }
        if letters.count >= 3, letters.last == "s" { letters.removeLast() }
        guard letters.count >= 2 else { return nil }
        return Reading(letters: letters, product: words.dropFirst(index).joined(separator: " "))
    }

    /// Whether `word` is a single character or one with a possessive typed onto it ("m", "ms").
    private static func startsLikeALetter(_ word: String) -> Bool {
        word.count == 1 || possessiveLetter(word) != nil
    }

    /// The letter of a two-character word that ends in a possessive `s` ("ms" → "m"), or nil.
    private static func possessiveLetter(_ word: String) -> String? {
        guard word.count == 2, word.hasSuffix("s"), let letter = word.first, letter.isLetter else { return nil }
        return String(letter)
    }
}

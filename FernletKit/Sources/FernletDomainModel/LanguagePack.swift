//
//  LanguagePack.swift
//  FernletDomainModel
//
//  One language's MATCHING vocabulary, in one place (localization plan §5.2, §5.4).
//
//  Every table here is a matching input mapped onto the frozen English the engines already
//  understand — never display text, never translated copy. A pack does not change what Fernlet
//  stores or shows: "2 tazas" still stores the `cup` token.
//
//  The packs are data. The engines that read them: `RecipeUnit.normalized` (and through it every
//  unit reader), `RecipeWebImporter`'s recipe line reader, `MealItemSplitter`, and
//  `FoodItemSearch.matchVariants` — while the language is an input language — and, in every language
//  at once, the two keyword screens: `DiagnosticLanguage` and `ItemNameModeration`. The app target's Settings search keeps its own per-language
//  synonyms, because its keys are the app's screens, and AIContext keeps the prompt style
//  (`AIPromptLanguage`).
//

import Foundation

/// One language's matching vocabulary: the words Fernlet reads in that language's typed input, each
/// mapped onto the frozen English token an engine already understands.
///
/// Get one with ``pack(for:)`` (English has none: its words live in each engine's own frozen table)
/// or every one with ``all``. Every key is already in ``folded(_:)`` form — lowercase, diacritics
/// folded, single spaces — the form each engine folds its input to before looking a word up, so
/// "cucharadita", "Cucharadita" and "cucharadíta" read the same.
///
/// A new language is a new `LanguagePack+<Language>.swift` and one line in ``pack(for:)``;
/// `LanguagePackTests` checks every pack's tables are filled and well-formed, for every
/// ``FernletLanguage`` but English.
public nonisolated struct LanguagePack: Sendable {
    /// The language whose input these words are.
    public let language: FernletLanguage
    /// Unit words and abbreviations → the unit token they mean ("tazas" → `.cup`, "cda" → `.tablespoon`).
    /// Read by `RecipeUnit.normalized` and, through it, by every unit reader.
    public let unitSpellings: [String: RecipeUnit]
    /// Count and size words a recipe line puts where a unit goes ("2 dientes de ajo"): they bind
    /// `each`, like the English line reader's "cloves" and "large".
    public let countWords: Set<String>
    /// The word that joins an amount to its food ("2 tazas DE harina"), dropped from the front of a
    /// recipe line's food name, like English "of".
    public let quantityConnectors: [String]
    /// Words that join two foods, like English "and" ("y"): a meal splits at each one.
    public let mealJoiners: [String]
    /// Words that attach a second food, like English "with" ("con"): a meal splits at each one
    /// unless one of ``companionModifiers`` follows ("con doble queso" describes the food before it).
    public let mealCompanions: [String]
    /// Words after a companion that modify the food before it rather than adding a food
    /// ("dos", "extra", "doble"); a numeral always counts too.
    public let companionModifiers: [String]
    /// Dish names that carry a companion word as part of the NAME ("chili con carne"): a meal never
    /// splits inside one.
    public let joinedDishNames: [String]
    /// How a plural reaches its singular, tried in order (``singularForms(of:)``).
    public let pluralRules: [PluralRule]
    /// Clinical-language stems matched as a substring of the separator-free text (`DiagnosticLanguage`).
    public let clinicalStems: [String]
    /// Clinical words matched only as a whole word, because as substrings they sit inside ordinary
    /// words ("toc" in "tocino").
    public let clinicalWholeWords: Set<String>
    /// Blocked item-name stems matched as a substring of the normalized name (`ItemNameModeration`).
    public let blockedNameStems: [String]
    /// Blocked item-name words matched only as a whole word ("puta" sits inside "reputation").
    public let blockedNameWholeWords: Set<String>

    /// The pack for `language`, or nil for English (whose words are the engines' own tables).
    public static func pack(for language: FernletLanguage) -> LanguagePack? {
        switch language {
        case .english: nil
        case .spanish: .spanish
        }
    }

    /// Every pack, in ``FernletLanguage`` order — for the screens that hold in every language at
    /// once (clinical language, moderation), whatever the interface language: a person can journal in
    /// Spanish in an English app.
    public static let all: [LanguagePack] = FernletLanguage.allCases.compactMap(pack(for:))

    /// The singular forms `word` may be the plural of, by ``pluralRules`` in order, each once.
    /// `word` must already be folded. Empty for a word no rule reads as a plural.
    public func singularForms(of word: String) -> [String] {
        var forms: [String] = []
        // R2: bounded by the pack's rules, a handful.
        for rule in pluralRules {
            if let form = rule.singular(of: word), !forms.contains(form) { forms.append(form) }
        }
        return forms
    }

    /// `text` lowercased and diacritic-folded with the locale-independent rules, whitespace runs
    /// collapsed to one space and trimmed — the form every pack key is written in.
    ///
    /// `locale: nil` for the reason `FoodItemSearch.normalized` gives: a matching key must fold the
    /// same on every device, or a Turkish-cased "I" stops matching.
    public static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// One way a plural reaches its singular: strip ``suffix``, append ``replacement`` — when the stem
/// left is long enough and, if ``after`` is set, ends in one of its letters.
///
/// Spanish "limones" → "limon" is `PluralRule(suffix: "es", after: "lnrdjy")`; "nueces" → "nuez" is
/// `PluralRule(suffix: "ces", replacement: "z")`; "manzanas" → "manzana" is
/// `PluralRule(suffix: "s", after: "aeiou")`. Conservative on purpose: a rule that misses leaves the
/// word as typed, which still prefix-matches; a rule that over-strips manufactures a wrong word.
public nonisolated struct PluralRule: Sendable, Equatable {
    /// The plural ending, folded.
    public let suffix: String
    /// What replaces it ("" to just strip).
    public let replacement: String
    /// The letters the stem must end in for the rule to apply, or nil for any letter.
    public let after: Set<Character>?
    /// The shortest stem the rule leaves; shorter words are not read as plurals.
    public let minimumStemLength: Int

    /// A rule; see the type's doc for examples.
    public init(suffix: String, replacement: String = "", after: String? = nil, minimumStemLength: Int = 3) {
        self.suffix = suffix
        self.replacement = replacement
        self.after = after.map(Set.init)
        self.minimumStemLength = minimumStemLength
    }

    /// The singular this rule reads `word` as, or nil when it does not apply.
    public func singular(of word: String) -> String? {
        guard !suffix.isEmpty, word.hasSuffix(suffix) else { return nil }
        let stem = String(word.dropLast(suffix.count))
        guard stem.count >= minimumStemLength else { return nil }
        if let after {
            guard let last = stem.last, after.contains(last) else { return nil }
        }
        return stem + replacement
    }
}

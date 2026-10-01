// RecipeSearchPick.swift
// Fernlet
//
// Ingredient-search round F9b (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §8, the owner's
// "sure" of 2026-09-30): a pick in a recipe ingredient list teaches search, so the next recipe search
// for the same words puts that food first. The picks are kept in the existing correction memory
// (`FoodSearchCorrectionMemory`, origin `.recipePick`) — the same key, cap and wipe row — and answer
// only the recipe surfaces (`FoodCatalog.setRecipeSearchPicks`).

import Foundation
import FernletDomainModel

/// When a pick in a recipe ingredient list teaches search, and what it teaches (F9b).
///
/// Pure rules, shared by the recipe editor's typeahead (``RecipeIngredientEditor``) and the swap sheet
/// (``IngredientSubstitutionSheet``), and applied at the TAP — with the words the list answered and the
/// rows it showed — while the write happens at the recipe's save. A pick teaches only when all of these
/// hold, and each exclusion is deliberate:
///
/// - **It was not already first.** The first row is what search already says; remembering it would add
///   an entry that changes nothing and spends a slot of the capped memory.
/// - **The words are a search**: at least `FoodItemSearch.minimumQueryLength` after normalization, the
///   floor the searcher itself applies.
/// - **The last word is finished.** Typing passes through prefixes ("chocolate ch"); a key spelled like
///   one would fire only on that exact keystroke and never on the words spelled out, so a query whose
///   last word is a strict prefix of a word in any row the list showed, and is not itself a word of any
///   of them (plural-aware, `FoodIngredientIdentity.forms`), teaches nothing. The whole list is read,
///   not only the chosen row, because a curated alias puts a row whose name never says the typed word
///   first ("chocolate chi" shows "Candies, semisweet chocolate" above "Cookies, chocolate chip, …").
///   A last word no shown name contains at all ("evoo" for olive oil, a typo) is a finished word and
///   does teach — that is where learning helps most. The honest cost: an abbreviation that is also a
///   prefix ("parm" for parmesan) is indistinguishable from typing and is not learned.
/// - **In the swap sheet, the words are the person's own and are not the ingredient being replaced.**
///   The list is seeded with that ingredient's name, and a search for it (or for any of its words:
///   "butter" while swapping "Butter, salted") is a search for something to stand in for it, so the
///   pick answers "what can replace butter", not "what I mean by butter".
/// - **In the swap sheet, the chosen row says the words searched for** — or no row shown does (fix
///   round 1). That list pools four rows from each sub-phrase in turn ("coconut oil", then "coconut",
///   then "oil"), so most of it is rows that never say what was typed; choosing "Coconut" or
///   "Oil, canola" there picks a stand-in, and teaching it would put that row first on every recipe
///   search for "coconut oil". When no row says the words ("evoo", a typo), any pick teaches, as in
///   the editor.
///   The editor needs no such rule: its typed gate shows only rows carrying every word, plus the
///   curated alias row, which deliberately never says them.
///
/// Everything the memory then does with a pick — one answer per query, a later pick replacing an
/// earlier one, a correction always winning — is ``FoodSearchCorrectionMemory``'s.
enum RecipeSearchPick {
    /// The normalized search a pick of `picked` teaches, or nil when it teaches nothing.
    ///
    /// - Parameters:
    ///   - typed: the words the shown list answered — the text in the field when its results settled.
    ///   - picked: the food the person chose.
    ///   - shown: the rows shown, in order (the recipe editor's six, the swap sheet's list).
    ///   - seed: the swap sheet's seeded search (the replaced ingredient's name); nil in the editor.
    static func query(typed: String, picked: FoodItem, shown: [FoodItem], seededWith seed: String? = nil) -> String? {
        let key = FoodItemSearch.normalized(typed)
        guard key.count >= FoodItemSearch.minimumQueryLength,
              shown.contains(where: { $0.id == picked.id }), shown.first?.id != picked.id else { return nil }
        if let seed {
            guard !namesReplacedIngredient(key, seed: seed), saysTheSearchedWords(key, picked: picked, shown: shown)
            else { return nil }
        }
        guard !endsMidWord(key, names: shown.map(\.name)) else { return nil }
        return key
    }

    /// Whether the last word of the normalized `key` is still being typed: a strict prefix of a word in
    /// one of `names` (the rows shown) that is not itself a word of any of them, in either number.
    static func endsMidWord(_ key: String, names: [String]) -> Bool {
        guard let last = key.split(separator: " ").last.map(String.init) else { return false }
        // R2: bounded by the rows shown (at most the swap sheet's 12) and their words.
        let words = Set(names.flatMap { FoodItemSearch.normalized($0).split(separator: " ").map(String.init) })
        let lastForms = FoodIngredientIdentity.forms(of: last)
        let isShownWord = words.contains { !FoodIngredientIdentity.forms(of: $0).isDisjoint(with: lastForms) }
        guard !isShownWord else { return false }
        return words.contains { $0.count > last.count && $0.hasPrefix(last) }
    }

    /// The recipe picks a save of `inputs` teaches: every row still bound to the food it was picked
    /// for. A row the person unbound, removed or re-picked carries no stale key (the editor clears it),
    /// and a row bound any other way never had one.
    static func corrections(from inputs: [ManualRecipeIngredientInput]) -> [FoodSearchCorrection] {
        inputs.compactMap { input in
            guard let query = input.pickedForSearch, let foodItemID = input.selectedFoodItemId else { return nil }
            return FoodSearchCorrection(searchText: query, foodItemID: foodItemID, origin: .recipePick)
        }
    }

    /// Whether `key` searches for the ingredient the swap sheet is replacing: the seed itself, or only
    /// words the seed states.
    private static func namesReplacedIngredient(_ key: String, seed: String) -> Bool {
        FoodItemSearch.normalized(seed) == key || FoodItemSearch.nameStatesQueryAsWords(seed, query: key)
    }

    /// Whether a swap-sheet pick of `picked` answers `key`'s words: its name says every word the swap
    /// list searched for, or no shown row's name does.
    ///
    /// "The words searched for" are the swap list's own: the single words
    /// `FoodSelectionCandidateBuilder.searchPhrases` splits `key` into (three letters or more, not a
    /// number, not a stop word), so "2% milk" asks only for "milk" and "half and half" for "half" —
    /// the same reading that built the list, rather than the typed gate's. A name says a word when one
    /// of its words is that word in either number (`FoodIngredientIdentity.forms`, the mid-word rule's
    /// reading), so "Potatoes, red, raw" says "potato" and "Tomato, roma" says "tomatoes".
    private static func saysTheSearchedWords(_ key: String, picked: FoodItem, shown: [FoodItem]) -> Bool {
        let wordForms = FoodSelectionCandidateBuilder.searchPhrases(from: key)
            .filter { !$0.contains(" ") }
            .map(FoodIngredientIdentity.forms(of:))
        let says = { (item: FoodItem) -> Bool in
            // R2: bounded by the searched words × the name's words, for at most the shown rows.
            let nameForms = FoodItemSearch.normalized(item.name).split(separator: " ")
                .map { FoodIngredientIdentity.forms(of: String($0)) }
            return !wordForms.isEmpty && wordForms.allSatisfy { forms in
                nameForms.contains { !$0.isDisjoint(with: forms) }
            }
        }
        return says(picked) || !shown.contains(where: says)
    }
}

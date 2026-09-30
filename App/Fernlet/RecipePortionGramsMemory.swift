// RecipePortionGramsMemory.swift
// Fernlet
//
// Ingredient-search round F4b (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.3, §8 F4b): the
// person's own "grams in one" for a food. The recipe editor offers a USDA typical size where a food's
// own data states none ("fruit (136 g)" for a Hass avocado) and lets the person type their own grams
// instead; this memory keeps that answer so the next recipe using the same food offers it first, under
// "Your size".
//
// A NEW PERSISTED SURFACE, so it carries — in the same commit, as the wall requires — a disposition row
// in Docs/PrivacyWipeCoverage.md, a token in `PrivacyWipeCoverageTests.wipeManifest`, and a row in
// `PersistedSurfaceWipeBoundaryTests.dispositions`.

import Foundation
import FernletDomainModel

/// One remembered "grams in one": a food, what one of it is, and the grams the person said it weighs.
///
/// `label` is a frozen token (a USDA portion word or a typical-size label such as "fruit" or "medium"),
/// matched against the recipe editor's options, never localized. Nothing here is shown on its own.
struct RecipePortionGrams: Codable, Equatable, Sendable {
    /// The food — a catalog row's stable id (FDC-derived) or a user food's id.
    let foodItemID: UUID
    /// What one is.
    let label: String
    /// The person's grams for one.
    let grams: Double

    /// A remembered entry for `measure` of `foodItemID`, or nil when the measure is not a usable one.
    init?(foodItemID: UUID, measure: RecipeHouseholdMeasure) {
        guard measure.isValid else { return nil }
        self.foodItemID = foodItemID
        self.label = measure.label
        self.grams = measure.gramsPerUnit
    }

    /// The entry as the household measure the recipe editor offers.
    var measure: RecipeHouseholdMeasure {
        RecipeHouseholdMeasure(label: label, gramsPerUnit: grams)
    }
}

/// Device-local memory of the grams a person gave for one of a food in the recipe editor (F4b), keyed
/// by food and label.
///
/// Deliberately a `UserDefaults` sidecar in the shape of ``BarcodeServingMemory`` and
/// ``FoodSearchCorrectionMemory``, NOT a field on the synced blob: it is small, device-scoped
/// bookkeeping about how this person measures, and it stays off the sync path — it never enters the
/// synced snapshot or CloudKit. Like its siblings it lives in the app container's preferences plist, so
/// it rides an encrypted device backup and returns with a restore of this device. The recipe lines
/// themselves carry their grams (and the label beside them) on their own, so forgetting this memory
/// changes no saved recipe — only which sizes the editor offers next time.
///
/// Written only when a recipe is SAVED (``remember(from:defaults:)``, from the store's save paths): a
/// size typed into an editor the person then cancels teaches the app nothing.
///
/// **Bounded growth (Power-of-10 R3):** at most ``maxRememberedPortions`` entries, oldest evicted first
/// at the point of insertion, and the read side keeps only the newest that many.
enum RecipePortionGramsMemory {
    /// The single defaults key: a JSON array of ``RecipePortionGrams``, oldest first.
    static let defaultsKey = "fernlet.recipePortionGrams.v1"

    /// R3 growth cap: one entry per food and label the person gave their own grams for — a deliberate
    /// edit of an estimate, far rarer than a logged meal. Each entry encodes to about 90 bytes, so a
    /// full memory costs ~18 KB of the defaults plist.
    static let maxRememberedPortions = 200

    /// The person's own sizes for `foodItemID`, newest first.
    static func measures(for foodItemID: UUID, defaults: UserDefaults = .standard) -> [RecipeHouseholdMeasure] {
        stored(defaults: defaults).filter { $0.foodItemID == foodItemID }.reversed().map(\.measure)
    }

    /// Records every row of a saved recipe whose amount is counted in the person's own grams for one
    /// (a ``RecipePortionOption/Source/personal`` portion on a bound row).
    static func remember(from inputs: [ManualRecipeIngredientInput], defaults: UserDefaults = .standard) {
        let entries = inputs.compactMap { input -> RecipePortionGrams? in
            guard let foodItemID = input.selectedFoodItemId, let portion = input.portion,
                  portion.source == .personal, let measure = portion.householdMeasure else { return nil }
            return RecipePortionGrams(foodItemID: foodItemID, measure: measure)
        }
        remember(entries, defaults: defaults)
    }

    /// Records `entries` as the newest, replacing any earlier grams for the same food and label. No-ops
    /// on an empty list, and writes nothing when encoding fails (a corrupt write would be worse than a
    /// forgotten size — the memory is a convenience, never a source of truth).
    static func remember(_ entries: [RecipePortionGrams], defaults: UserDefaults = .standard) {
        guard !entries.isEmpty else { return }
        let replaced = Set(entries.map { "\($0.foodItemID.uuidString)|\($0.label)" })
        var kept = stored(defaults: defaults).filter { !replaced.contains("\($0.foodItemID.uuidString)|\($0.label)") }
        kept.append(contentsOf: entries)
        // R3: bounded at the point of insertion — oldest out, never append-only.
        if kept.count > maxRememberedPortions {
            kept.removeFirst(kept.count - maxRememberedPortions)
        }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Forgets every remembered size. Invoked from the store's wipe path (`resetAll`, which
    /// `deleteAllData` reaches) so this device-local sidecar is cleared with the others.
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// The stored list, oldest first; unreadable data reads as empty, and — R3 on the read side too — a
    /// list longer than the cap keeps only its newest ``maxRememberedPortions``.
    private static func stored(defaults: UserDefaults) -> [RecipePortionGrams] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([RecipePortionGrams].self, from: data) else { return [] }
        return Array(entries.suffix(maxRememberedPortions))
    }
}

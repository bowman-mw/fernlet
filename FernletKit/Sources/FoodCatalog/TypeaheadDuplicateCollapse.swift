import Foundation
import FernletDomainModel

/// Shows ONE row per catalog name in a typed search: identical-name catalog rows collapse to the one
/// worth tapping.
///
/// Docs/Ingredient-Search-Deep-Research-2026-09-29.md §2.5 / §8 F6. The catalog carries whole runs of
/// rows under one name — "Chocolate Chips, Chocolate" three times, "Extra Virgin Olive Oil" sixty — and
/// they tie on score and name, so the stable sort shows them in `food_id` order: the six rows the
/// recipe editor offers can be one product six times, and the one first in line was, for the chips,
/// the row whose nutrition could not exist. Collapsing them frees the list for other answers and
/// makes the tie land on a row that works.
///
/// The rules, all deliberate:
/// - Rows group by `FoodItemSearch.normalized(name)` (case, accents and punctuation folded) WITHIN one
///   data type: USDA's "Peanut butter, creamy" and a branded "Peanut Butter Creamy" fold to the same
///   words but are different kinds of record, and neither may hide the other.
/// - A group keeps ONE row, at the position of its highest-ranked member, so no ranking changes; the
///   row it keeps is the best by (nutrition physically possible, tap default converts, readable
///   household portions), compared in that order, with ties going to the higher-ranked row.
/// - A person's own rows are never touched: a user item, or a catalog row this person has logged
///   (any history weight), is neither hidden nor used to hide anything.
/// - Catalog rows only, on one device, from the read-only public catalog. This is NOT the
///   cross-device clustering of user-created records that `NutritionPlausibility`'s design boundary
///   forbids.
///
/// Bounded: it reads at most ``window`` rows plus the caller's `limit`, in one pass.
nonisolated enum TypeaheadDuplicateCollapse {
    /// How many ranked rows a typed search reads before collapsing — `FoodItemSearch.demotionWindow`
    /// (60, internal to its module): asking the scorer for up to that many rows changes no order,
    /// because its dish demotion already reads that window whatever the limit.
    static let window = 60

    /// The limit to ask the scorer for, so collapsing still leaves `limit` rows when it can.
    static func fetchLimit(for limit: Int) -> Int {
        max(limit, window)
    }

    /// `ranked`, with each group of identical catalog names reduced to its best row, then capped at
    /// `limit`. Rows for which `isProtected` holds pass through untouched and join no group.
    static func collapsing(_ ranked: [FoodItem], limit: Int, isProtected: (FoodItem) -> Bool) -> [FoodItem] {
        guard limit > 0 else { return [] }
        var kept: [FoodItem] = []
        var slotForName: [String: Int] = [:]   // "<dataType token>|<normalized name>"
        for item in ranked.prefix(max(limit, window)) {
            guard !isProtected(item) else {
                kept.append(item)
                continue
            }
            let name = item.dataType.rawValue + "|" + FoodItemSearch.normalized(item.name)
            guard let slot = slotForName[name] else {
                slotForName[name] = kept.count
                kept.append(item)
                continue
            }
            if quality(of: item) > quality(of: kept[slot]) { kept[slot] = item }
        }
        return Array(kept.prefix(limit))
    }

    /// (nutrition plausible, tap default converts, readable household portions) as integers, so the
    /// tuple compares lexicographically.
    static func quality(of item: FoodItem) -> (Int, Int, Int) {
        let unit = item.preferredRecipeUnit
        let tap = RecipeIngredient(foodItemId: item.id, quantity: item.defaultRecipeQuantity(for: unit), unit: unit.rawValue)
        let converts = tap.servingConversion(using: item) != nil
        let readablePortions = item.portions.prefix(window).filter { $0.recipeUnit != nil }.count
        return (isPlausible(item) ? 1 : 0, converts ? 1 : 0, readablePortions)
    }

    /// Whether a row's macros can exist in its serving: at most 900 kcal per 100 g and no more macro
    /// grams than the serving weighs. Only gram and milliliter servings are judged (a milliliter read
    /// as a gram); any other serving carries no weight to judge against and passes.
    static func isPlausible(_ item: FoodItem) -> Bool {
        guard let unit = RecipeUnit.normalized(item.servingUnit), unit == .gram || unit == .milliliter,
              item.servingSize > 0 else { return true }
        let macros = item.macros
        let kcalPer100 = Double(macros.calories) * 100 / item.servingSize
        return kcalPer100 <= 900 && Double(macros.protein + macros.carbs + macros.fat) <= item.servingSize
    }
}

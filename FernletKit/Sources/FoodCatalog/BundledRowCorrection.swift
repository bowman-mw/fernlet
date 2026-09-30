import Foundation
import FernletDomainModel

/// Load-time corrections applied to every row the SQLite read path hydrates, so a known defect in
/// the committed `FoodCatalog.sqlite` is fixed without regenerating (and re-committing) the binary.
///
/// Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.5 / §8 F2. Each correction is a pure,
/// per-row, O(1) function of the hydrated `FoodItem` — no lookups, no loops beyond a row's own
/// portion list — so it costs nothing measurable on the ~9,000-row broad-prefix fetches and cannot
/// change which rows a query retrieves, only what a retrieved row says.
///
/// **The branded per-100 g basis (F2).** The 59,227 rows that came from the repo's compact
/// `FoodDataSource/USDAFoodItems.json` with a branded origin (ids `00000000-0000-5000-…`, data type
/// `branded` or — for a chain's packaged product — `restaurant`) carry USDA's branded
/// `foodNutrients`, which are per 100 g (or 100 ml), next to the product's LABEL serving. The app read
/// the macros as belonging to the label serving: "String Cheese" said P29 for a 28 g stick (the label
/// says P8), "Organic Semi-Sweet Chocolate Chips" P7 C60 F33 for 15 g (3,767 kcal per 100 g). A
/// pairing test against the GTIN rows put 89% of the set on the per-100 g basis, so the whole set is
/// rebased: the serving becomes 100 g (100 ml), the macros and micronutrients are left exactly as
/// stored, and — for a gram label — the label serving is appended as a COUNT portion ("1 serving
/// (28 g)", unit `each`). The count portion is what keeps a bare count honest: quick-log turns
/// "2 string cheese" into `2 × defaultRecipeQuantity(for: preferredRecipeUnit)`, and with the portion
/// in place `preferredRecipeUnit` is `each`, so "2" means two 28 g sticks, not 2 × 100 g.
///
/// A milliliter label gets no count portion: the converter can only bridge a count to a volume
/// serving through a density, and a label volume carries none (inventing 1 g/ml is not source data),
/// so such a portion would make the row fail on tap. Those rows keep "100 ml" as their serving and a
/// bare count logs 100 ml per count — the same nutrition a count logged before, now with an honest
/// amount.
///
/// The attachable branded On-Demand-Resource catalog (`ODRAssets/FoodCatalogBranded.sqlite`) was
/// MEASURED on the label basis (its "String Cheese" says P8 for 28 g; 0.14% of its gram rows exceed
/// 900 kcal per 100 g, against 49% of the rows rebased here) and carries none of these ids, so the
/// id guard leaves it untouched.
nonisolated enum BundledRowCorrection {
    /// The id prefix the catalog generator mints for rows decoded from the compact USDA source JSON
    /// (`00000000-0000-5000-8000-<12-digit fdcId>`, see `USDAFoodItemRecord.stableUSDAID`). A frozen
    /// token: it is the stable-id scheme saved recipes resolve by.
    static let compactSourceIDPrefix = "00000000-0000-5000-"

    /// The basis the compact source's branded nutrients are stated on, in grams or milliliters.
    static let brandedNutrientBasis: Double = 100

    /// Every load-time correction, in order, applied to one hydrated row.
    static func corrected(_ item: FoodItem) -> FoodItem {
        rebasingBrandedNutrients(item)
    }

    /// F2: puts a compact-source branded row on the per-100 g (ml) basis its macros are stated on,
    /// keeping a gram label serving as a count portion. Every other row is returned unchanged.
    static func rebasingBrandedNutrients(_ item: FoodItem) -> FoodItem {
        guard item.dataType == .branded || item.dataType == .restaurant,
              item.id.uuidString.hasPrefix(compactSourceIDPrefix),
              let unit = RecipeUnit.normalized(item.servingUnit),
              unit == .gram || unit == .milliliter else { return item }
        let label = item.servingSize
        guard label.isFinite, label > 0, label != brandedNutrientBasis else { return item }
        var rebased = item
        rebased.servingSize = brandedNutrientBasis
        rebased.servingUnit = unit.rawValue
        if unit == .gram {
            rebased.portions.append(FoodPortion(
                amount: 1,
                unit: RecipeUnit.each.rawValue,
                gramWeight: label,
                description: "1 serving (\(String(format: "%g", label)) g)"
            ))
        }
        return rebased
    }
}

import Foundation
import FernletDomainModel

/// Load-time corrections applied to every row the SQLite read path hydrates, so a known defect in
/// the committed `FoodCatalog.sqlite` is fixed without regenerating (and re-committing) the binary.
///
/// Docs/Ingredient-Search-Deep-Research-2026-09-29.md §3.4, §6.5 / §8 F1(a), F2. Each correction is a pure,
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
///
/// **Raw FDC unit codes (F1(a)).** 14,600 rows (and 86,651 in the On-Demand-Resource catalog) carry
/// USDA's raw serving-unit codes — `GRM` and `GM` for grams, `MLT` for milliliters — which
/// `RecipeUnit.normalized` does not read, so those rows converted nothing, not even grams, and failed
/// the moment they were tapped. They are rewritten to the canonical `g` / `ml` tokens at load. `IU`,
/// `MC` and the survey units ("sandwich") name no mass or volume and are left as they are; the
/// converter now lets them resolve "1 serving" (`RecipeServingConversion`).
///
/// **Branded products filed as SR Legacy (F6).** 763 compact-source rows are typed `srLegacy` though
/// they are packaged products the source file carried without a brand owner — "Annies Hmgrwn Org
/// Cookie Bites Choc Chip", 718 of them with carbohydrate 0 — so they sat in the generic tier above
/// every real branded row and crowded plain answers out of the six (report §5, D2). None of them is
/// an SR Legacy food, and every one carries a branded-food category ("Confectionery Products",
/// "Cheese/Cheese Substitutes") rather than one of SR Legacy's 25 food groups, so they are retyped
/// `branded` BY CATEGORY — not by FDC-id range, which also holds real generics (FDC 746761, a beef
/// round). Retyped before the F2 rebase, so the 46 of them on a label serving are rebased too.
nonisolated enum BundledRowCorrection {
    /// The id prefix the catalog generator mints for rows decoded from the compact USDA source JSON
    /// (`00000000-0000-5000-8000-<12-digit fdcId>`, see `USDAFoodItemRecord.stableUSDAID`). A frozen
    /// token: it is the stable-id scheme saved recipes resolve by.
    static let compactSourceIDPrefix = "00000000-0000-5000-"

    /// The basis the compact source's branded nutrients are stated on, in grams or milliliters.
    static let brandedNutrientBasis: Double = 100

    /// USDA's raw FDC serving-unit codes and the canonical `RecipeUnit` token each one means. Both
    /// sides are FROZEN tokens (localization wall): the keys are matching inputs read from the
    /// committed files, the values are persisted `RecipeUnit` raw values.
    static let rawServingUnitAliases: [String: String] = [
        "GRM": RecipeUnit.gram.rawValue,
        "GM": RecipeUnit.gram.rawValue,
        "MLT": RecipeUnit.milliliter.rawValue
    ]

    /// SR Legacy's 25 food groups — the FDC `foodCategory.description` of every SR Legacy food, read
    /// from USDA's April 2018 SR Legacy file. FROZEN matching inputs (localization wall): they are
    /// compared with the English category strings stored in the catalog files.
    static let srLegacyFoodGroups: Set<String> = [
        "American Indian/Alaska Native Foods", "Baby Foods", "Baked Products", "Beef Products",
        "Beverages", "Breakfast Cereals", "Cereal Grains and Pasta", "Dairy and Egg Products",
        "Fast Foods", "Fats and Oils", "Finfish and Shellfish Products", "Fruits and Fruit Juices",
        "Lamb, Veal, and Game Products", "Legumes and Legume Products",
        "Meals, Entrees, and Side Dishes", "Nut and Seed Products", "Pork Products",
        "Poultry Products", "Restaurant Foods", "Sausages and Luncheon Meats", "Snacks",
        "Soups, Sauces, and Gravies", "Spices and Herbs", "Sweets",
        "Vegetables and Vegetable Products"
    ]

    /// Every load-time correction, in order, applied to one hydrated row.
    static func corrected(_ item: FoodItem) -> FoodItem {
        rebasingBrandedNutrients(retypingMisfiledBrandedProducts(aliasingRawServingUnit(item)))
    }

    /// F6: types a compact-source `srLegacy` row `branded` when its category is not an SR Legacy food
    /// group. Every other row is returned unchanged.
    static func retypingMisfiledBrandedProducts(_ item: FoodItem) -> FoodItem {
        guard item.dataType == .srLegacy,
              item.id.uuidString.hasPrefix(compactSourceIDPrefix),
              !srLegacyFoodGroups.contains(item.category) else { return item }
        var retyped = item
        retyped.dataType = .branded
        return retyped
    }

    /// F1(a): rewrites a raw FDC serving-unit code (`GRM`, `GM`, `MLT`) to the token it means.
    /// Every other row is returned unchanged.
    static func aliasingRawServingUnit(_ item: FoodItem) -> FoodItem {
        let code = item.servingUnit.trimmingCharacters(in: .whitespaces).uppercased()
        guard let canonical = rawServingUnitAliases[code] else { return item }
        var aliased = item
        aliased.servingUnit = canonical
        return aliased
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

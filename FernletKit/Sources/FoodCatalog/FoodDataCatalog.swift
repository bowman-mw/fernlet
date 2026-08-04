import Foundation
import FernletFoundation
import FernletDomainModel

/// One decoded row of USDA source JSON — either the compact bundled schema or a raw FDC envelope.
///
/// The generation-time decoding workhorse behind ``FoodDataCatalog``: its custom `init(from:)`
/// detects the schema by the presence of the compact `name` key. The compact branch reads the
/// pre-flattened fields directly; the raw-FDC branch flattens `foodNutrients` by nutrient id,
/// derives portions, and — for branded labels — rescales the per-100g nutrient values onto the
/// label's per-serving basis so macros and micronutrients share one basis. ``foodItem()`` then
/// produces the final `FoodItem`, minting a deterministic UUID from the FDC id
/// (`00000000-0000-5000-8000-<12-digit fdcId>`) so catalog regenerations keep stable ids.
/// Generation and test time only: the shipped app reads `FoodCatalog.sqlite`, never this decoder.
struct USDAFoodItemRecord: Decodable {
    var id: UUID?
    var fdcId: Int?
    var name: String
    var brandSource: String?
    var servingSize: Double
    var servingUnit: String
    var protein: Double
    var carbs: Double
    var fat: Double
    var category: String
    var dataType: String?
    var tags: [String]?
    var portions: [FoodPortion]?
    var gtinUpc: String?
    var fiber: Double?
    var sugar: Double?
    var saturatedFat: Double?
    var cholesterol: Double?
    var vitaminA: Double?
    var vitaminC: Double?
    var vitaminD: Double?
    var vitaminE: Double?
    var vitaminK: Double?
    var vitaminB6: Double?
    var vitaminB12: Double?
    var thiamin: Double?
    var riboflavin: Double?
    var niacin: Double?
    var folate: Double?
    var calcium: Double?
    var iron: Double?
    var magnesium: Double?
    var phosphorus: Double?
    var potassium: Double?
    var sodium: Double?
    var zinc: Double?
    var omega3: Double?

    /// JSON keys for both shapes ``USDAFoodItemRecord`` decodes: the curated catalog's compact keys
    /// and the raw USDA FDC export's keys (`description`, `foodNutrients`, `labelNutrients`, …).
    ///
    /// Renaming a compact case breaks the shipped catalog resource; the FDC-side cases must track
    /// the upstream USDA export format.
    private enum CodingKeys: String, CodingKey {
        case id, fdcId, name, brandSource, servingSize, servingUnit, protein, carbs, fat
        case category, tags, portions, fiber, sugar, saturatedFat, cholesterol
        case vitaminA, vitaminC, vitaminD, vitaminE, vitaminK, vitaminB6, vitaminB12
        case thiamin, riboflavin, niacin, folate, calcium, iron, magnesium, phosphorus
        case potassium, sodium, zinc, omega3
        case description, dataType, brandOwner, brandName, foodCategory, foodNutrients, foodPortions
        case servingSizeUnit, householdServingFullText, labelNutrients
        case gtinUpc
    }

    /// Decodes one record, branching on the compact `name` key: the compact bundled schema when it
    /// is present, the raw FDC envelope (with branded-label per-serving rescaling) otherwise.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        fdcId = try container.decodeIfPresent(Int.self, forKey: .fdcId)

        // Both branches: preserve a product barcode when the source data carries one (the current
        // compact JSON does not — UPCs arrive only via a future re-derivation from raw FDC branded data).
        gtinUpc = try container.decodeIfPresent(String.self, forKey: .gtinUpc)

        if let compactName = try container.decodeIfPresent(String.self, forKey: .name) {
            name = compactName
            brandSource = try container.decodeIfPresent(String.self, forKey: .brandSource)
            servingSize = try container.decodeIfPresent(Double.self, forKey: .servingSize) ?? 100
            servingUnit = try container.decodeIfPresent(String.self, forKey: .servingUnit) ?? RecipeUnit.gram.rawValue
            protein = try container.decodeIfPresent(Double.self, forKey: .protein) ?? 0
            carbs = try container.decodeIfPresent(Double.self, forKey: .carbs) ?? 0
            fat = try container.decodeIfPresent(Double.self, forKey: .fat) ?? 0
            category = try container.decodeIfPresent(String.self, forKey: .category) ?? "USDA"
            dataType = try container.decodeIfPresent(String.self, forKey: .dataType)
            tags = try container.decodeIfPresent([String].self, forKey: .tags)
            portions = try container.decodeIfPresent([FoodPortion].self, forKey: .portions)
            fiber = try container.decodeIfPresent(Double.self, forKey: .fiber)
            sugar = try container.decodeIfPresent(Double.self, forKey: .sugar)
            saturatedFat = try container.decodeIfPresent(Double.self, forKey: .saturatedFat)
            cholesterol = try container.decodeIfPresent(Double.self, forKey: .cholesterol)
            vitaminA = try container.decodeIfPresent(Double.self, forKey: .vitaminA)
            vitaminC = try container.decodeIfPresent(Double.self, forKey: .vitaminC)
            vitaminD = try container.decodeIfPresent(Double.self, forKey: .vitaminD)
            vitaminE = try container.decodeIfPresent(Double.self, forKey: .vitaminE)
            vitaminK = try container.decodeIfPresent(Double.self, forKey: .vitaminK)
            vitaminB6 = try container.decodeIfPresent(Double.self, forKey: .vitaminB6)
            vitaminB12 = try container.decodeIfPresent(Double.self, forKey: .vitaminB12)
            thiamin = try container.decodeIfPresent(Double.self, forKey: .thiamin)
            riboflavin = try container.decodeIfPresent(Double.self, forKey: .riboflavin)
            niacin = try container.decodeIfPresent(Double.self, forKey: .niacin)
            folate = try container.decodeIfPresent(Double.self, forKey: .folate)
            calcium = try container.decodeIfPresent(Double.self, forKey: .calcium)
            iron = try container.decodeIfPresent(Double.self, forKey: .iron)
            magnesium = try container.decodeIfPresent(Double.self, forKey: .magnesium)
            phosphorus = try container.decodeIfPresent(Double.self, forKey: .phosphorus)
            potassium = try container.decodeIfPresent(Double.self, forKey: .potassium)
            sodium = try container.decodeIfPresent(Double.self, forKey: .sodium)
            zinc = try container.decodeIfPresent(Double.self, forKey: .zinc)
            omega3 = try container.decodeIfPresent(Double.self, forKey: .omega3)
            return
        }

        let nutrients = try container.decodeIfPresent([FDCFoodNutrient].self, forKey: .foodNutrients) ?? []
        let nutrientValues = Dictionary(grouping: nutrients, by: \.nutrientId)
            .compactMapValues { $0.first?.amount }
        let fdcPortions = try container.decodeIfPresent([FDCFoodPortion].self, forKey: .foodPortions) ?? []
        let categoryDescription = try container.decodeIfPresent(FDCFoodCategory.self, forKey: .foodCategory)?.description
        dataType = try container.decodeIfPresent(String.self, forKey: .dataType)
        let labelNutrients = try container.decodeIfPresent(FDCLabelNutrients.self, forKey: .labelNutrients)
        let labelServingSize = try container.decodeIfPresent(Double.self, forKey: .servingSize)
        let labelServingUnit = try container.decodeIfPresent(String.self, forKey: .servingSizeUnit)
        let labelServingText = try container.decodeIfPresent(String.self, forKey: .householdServingFullText)

        name = try container.decodeIfPresent(String.self, forKey: .description) ?? "USDA food"
        brandSource = try container.decodeIfPresent(String.self, forKey: .brandOwner)
            ?? container.decodeIfPresent(String.self, forKey: .brandName)
        let isBrandedLabel = labelNutrients != nil && (brandSource != nil || dataType?.localizedCaseInsensitiveContains("branded") == true)
        // For a branded label, foodNutrients are per 100 g/ml while labelNutrients are per
        // serving; nutrientScale converts the former to the per-serving basis. Defined before
        // the macro block so the macro fallbacks share the same basis as the micronutrients —
        // otherwise a label missing a macro stored that macro per-100g but micros per-serving.
        let nutrientScale: Double = isBrandedLabel && (labelServingSize ?? 100) > 0
            ? (labelServingSize ?? 100) / 100.0
            : 1.0
        func scaled(_ v: Double?) -> Double? { v.map { $0 * nutrientScale } }
        if isBrandedLabel, let labelServingSize, labelServingSize > 0 {
            servingSize = labelServingSize
            servingUnit = labelServingUnit ?? RecipeUnit.gram.rawValue
            protein = labelNutrients?.protein?.value ?? scaled(nutrientValues[1003]) ?? 0
            carbs = labelNutrients?.carbohydrates?.value ?? scaled(nutrientValues[1005]) ?? 0
            fat = labelNutrients?.fat?.value ?? scaled(nutrientValues[1004]) ?? 0
        } else {
            servingSize = 100
            servingUnit = RecipeUnit.gram.rawValue
            protein = nutrientValues[1003] ?? 0
            carbs = nutrientValues[1005] ?? 0
            fat = nutrientValues[1004] ?? 0
        }
        category = categoryDescription ?? dataType ?? "USDA"
        tags = [dataType, categoryDescription, "usda"].compactMap { $0 }
        portions = Self.portions(from: fdcPortions, labelServingSize: labelServingSize, labelServingUnit: labelServingUnit, labelServingText: labelServingText)
        fiber = scaled(nutrientValues[1079])
        sugar = scaled(nutrientValues[2000] ?? nutrientValues[1063])
        saturatedFat = scaled(nutrientValues[1258])
        cholesterol = scaled(nutrientValues[1253])
        vitaminA = scaled(nutrientValues[1106])
        vitaminC = scaled(nutrientValues[1162])
        vitaminD = scaled(nutrientValues[1114])
        vitaminE = scaled(nutrientValues[1109])
        vitaminK = scaled(nutrientValues[1185])
        vitaminB6 = scaled(nutrientValues[1175])
        vitaminB12 = scaled(nutrientValues[1178])
        thiamin = scaled(nutrientValues[1165])
        riboflavin = scaled(nutrientValues[1166])
        niacin = scaled(nutrientValues[1167])
        folate = scaled(nutrientValues[1177])
        calcium = scaled(nutrientValues[1087])
        iron = scaled(nutrientValues[1089])
        magnesium = scaled(nutrientValues[1090])
        phosphorus = scaled(nutrientValues[1091])
        potassium = scaled(nutrientValues[1092])
        sodium = scaled(nutrientValues[1093])
        zinc = scaled(nutrientValues[1095])
        omega3 = scaled(nutrientValues[1272] ?? nutrientValues[1278] ?? nutrientValues[1270])
    }

    /// The finished catalog `FoodItem`: stable USDA UUID (when derivable from the FDC id), rounded
    /// integer macros, resolved micronutrients, classified data type, and normalized barcode.
    nonisolated func foodItem() -> FoodItem {
        FoodItem(
            id: id ?? stableUSDAID ?? UUID(),
            name: name,
            brandSource: brandSource ?? fdcDescription,
            servingSize: max(servingSize, 0.01),
            servingUnit: servingUnit,
            macros: Macros(
                protein: Int(protein.rounded()),
                carbs: Int(carbs.rounded()),
                fat: Int(fat.rounded())
            ),
            micronutrients: resolvedMicronutrients,
            category: category,
            source: .usda,
            dataType: classifiedDataType,
            lastVerified: nil,
            tags: tags ?? ["usda"],
            portions: portions ?? [],
            barcode: FoodBarcode.normalized(gtinUpc)
        )
    }

    /// Maps the record's FDC `dataType`/category/brand onto `FoodDataType` (foundation > survey >
    /// branded, with `srLegacy` as the unbranded fallback), using `FoodBrandLexicon` to split
    /// restaurant chains from packaged brands.
    nonisolated private var classifiedDataType: FoodDataType {
        let dataTypeLower = dataType?.lowercased()
        if dataTypeLower?.contains("foundation") == true { return .foundation }
        if dataTypeLower?.contains("survey") == true || dataTypeLower?.contains("fndds") == true { return .survey }
        if dataTypeLower?.contains("branded") == true { return .branded }

        let categoryLower = category.lowercased()
        if categoryLower.contains("foundation") { return .foundation }
        if categoryLower.contains("survey") || categoryLower.contains("fndds") { return .survey }
        guard let brand = brandSource else { return .srLegacy }
        return FoodBrandLexicon.isRestaurantChain(brand) ? .restaurant : .branded
    }

    /// The flattened micronutrient set, already on the record's serving basis (rescaled for
    /// branded labels during decoding).
    nonisolated private var resolvedMicronutrients: Micronutrients {
        Micronutrients(
            fiber: fiber,
            sugar: sugar,
            saturatedFat: saturatedFat,
            cholesterol: cholesterol,
            vitaminA: vitaminA,
            vitaminC: vitaminC,
            vitaminD: vitaminD,
            vitaminE: vitaminE,
            vitaminK: vitaminK,
            vitaminB6: vitaminB6,
            vitaminB12: vitaminB12,
            thiamin: thiamin,
            riboflavin: riboflavin,
            niacin: niacin,
            folate: folate,
            calcium: calcium,
            iron: iron,
            magnesium: magnesium,
            phosphorus: phosphorus,
            potassium: potassium,
            sodium: sodium,
            zinc: zinc,
            omega3: omega3
        )
    }

    /// Merges the FDC household portions with a label-serving portion (skipped when an equivalent
    /// portion already exists) and always appends a per-100 g anchor.
    private static func portions(
        from fdcPortions: [FDCFoodPortion],
        labelServingSize: Double?,
        labelServingUnit: String?,
        labelServingText: String?
    ) -> [FoodPortion] {
        var portions = fdcPortions.compactMap(\.foodPortion)
        guard let labelServingSize, labelServingSize > 0,
              let gramWeight = gramWeight(quantity: labelServingSize, unit: labelServingUnit) else {
            return portions
        }
        let labelPortion = FoodPortion(
            amount: labelServingSize,
            unit: labelServingUnit ?? RecipeUnit.gram.rawValue,
            gramWeight: gramWeight,
            description: labelServingText ?? "label serving"
        )
        if portions.contains(where: { $0.unit == labelPortion.unit && abs($0.gramWeight - labelPortion.gramWeight) < 0.1 }) == false {
            portions.append(labelPortion)
        }
        portions.append(FoodPortion(amount: 100, unit: RecipeUnit.gram.rawValue, gramWeight: 100, description: "per 100 g"))
        return portions
    }

    /// Gram weight for convertible units only (g/ml treated 1:1, oz, lb); nil for anything else,
    /// which drops the label portion rather than guessing.
    private static func gramWeight(quantity: Double, unit: String?) -> Double? {
        switch RecipeUnit.normalized(unit ?? RecipeUnit.gram.rawValue) {
        case .gram, .milliliter:
            return quantity
        case .ounce:
            return quantity * 28.3495
        case .pound:
            return quantity * 453.592
        default:
            return nil
        }
    }

    /// "USDA FDC <id>" — the brand-source fallback that preserves data provenance for unbranded rows.
    nonisolated private var fdcDescription: String? {
        guard let fdcId else { return nil }
        return "USDA FDC \(fdcId)"
    }

    /// Deterministic UUID minted from the FDC id (`00000000-0000-5000-8000-<12-digit fdcId>`), so a
    /// regenerated catalog keeps the same ids and saved recipes/curated pins stay resolvable.
    nonisolated private var stableUSDAID: UUID? {
        guard let fdcId, fdcId >= 0, fdcId <= 999_999_999_999 else { return nil }
        let suffix = String(format: "%012d", fdcId)
        return UUID(uuidString: "00000000-0000-5000-8000-\(suffix)")
    }
}

/// One entry of a raw FDC `foodNutrients` array — a nutrient id plus its amount.
///
/// Tolerates both raw-FDC shapes (a nested `nutrient` object or a flat `nutrientId` field) so one
/// record type serves every FDC data-type export; `USDAFoodItemRecord` groups these by id.
private struct FDCFoodNutrient: Decodable {
    let amount: Double?
    private let nutrient: FDCNutrient?
    private let nutrientIdValue: Int?

    var nutrientId: Int {
        nutrient?.id ?? nutrientIdValue ?? -1
    }

    /// JSON keys for a raw FDC nutrient entry; `nutrientIdValue` maps the flat `nutrientId` field
    /// so both FDC shapes decode through one record.
    private enum CodingKeys: String, CodingKey {
        case amount, nutrient, nutrientIdValue = "nutrientId"
    }
}

/// The nested `nutrient` object of a raw FDC nutrient entry — only the id is read.
///
/// Exists solely so `FDCFoodNutrient` can resolve a nutrient id from the nested shape.
private struct FDCNutrient: Decodable {
    let id: Int?
}

/// The raw FDC `foodCategory` object — only its human-readable description is read.
///
/// Feeds the `FoodItem.category` fallback chain in `USDAFoodItemRecord`.
private struct FDCFoodCategory: Decodable {
    let description: String?
}

/// The raw FDC `labelNutrients` object for branded foods — the per-serving macro values as printed
/// on the product label.
///
/// Its presence (together with a brand) is what flips `USDAFoodItemRecord` into the per-serving
/// branded-label decoding branch.
private struct FDCLabelNutrients: Decodable {
    let protein: FDCLabelNutrientValue?
    let carbohydrates: FDCLabelNutrientValue?
    let fat: FDCLabelNutrientValue?
}

/// One `labelNutrients` figure — FDC nests each label value in a `{ "value": … }` object.
///
/// Exists only to unwrap that nesting for `FDCLabelNutrients`.
private struct FDCLabelNutrientValue: Decodable {
    let value: Double?
}

/// One raw FDC `foodPortions` entry — household-measure metadata plus its gram weight.
///
/// `foodPortion` converts it to the app's `FoodPortion`, dropping entries without a positive gram
/// weight or any usable unit text.
private struct FDCFoodPortion: Decodable {
    let amount: Double?
    let gramWeight: Double?
    let modifier: String?
    let portionDescription: String?
    let measureUnit: FDCMeasureUnit?

    /// The app-model portion, or nil when the entry lacks a positive gram weight or unit text.
    var foodPortion: FoodPortion? {
        guard let gramWeight, gramWeight > 0 else { return nil }
        let unit = measureUnit?.abbreviation ?? measureUnit?.name ?? portionDescription ?? modifier
        guard let unit, unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return FoodPortion(
            amount: max(amount ?? 1, 0.01),
            unit: unit,
            gramWeight: gramWeight,
            description: [modifier, portionDescription].compactMap { $0 }.joined(separator: " ")
        )
    }
}

/// The raw FDC `measureUnit` object — a unit's name and abbreviation.
///
/// Supplies the preferred unit text when `FDCFoodPortion` builds a `FoodPortion`.
private struct FDCMeasureUnit: Decodable {
    let name: String?
    let abbreviation: String?
}

/// Generation-time entry point that turns the repo's USDA source JSON into the `FoodItem` set the
/// SQLite catalog is built from.
///
/// The app never touches the source JSON at runtime — `FoodCatalogDatabaseBuilder` (app target,
/// invoked via the gated `FoodCatalogGenerationTests`) calls ``sourceJSONFoodItems(directory:)`` to
/// produce the rows it writes into `FoodCatalog.sqlite`, and the decoder unit tests exercise
/// ``foodItems(from:)`` directly. Decoding is delegated to ``USDAFoodItemRecord`` (compact bundled
/// schema or raw FDC envelope), and a small canonical-alias pass adds a friendlier name for the
/// staple chicken-breast entry.
public enum FoodDataCatalog {
    /// Source JSON file names (repo-only, under `FoodDataSource/`). These are no longer bundled
    /// into the app — they are the build-time input to `FoodCatalogDatabaseBuilder`, which emits the
    /// read-only `FoodCatalog.sqlite` resource the app actually ships. See FoodCatalog.swift.
    public nonisolated static let sourceResourceNames = ["USDAFoodItems", "CuratedSurveyFoodItems", "BrandedCuratedFoodItems"]

    /// Decodes a single USDA JSON payload (compact bundled schema *or* raw FDC envelope) into
    /// `FoodItem`s. Used by both the database generator and the decoder unit tests.
    public nonisolated static func foodItems(from data: Data) -> [FoodItem] {
        StartupTiming.timed("FoodDataCatalog.foodItems.decode") {
            guard !data.isEmpty else { return [] }
            let decoder = JSONDecoder()
            guard let records = try? decoder.decode([USDAFoodItemRecord].self, from: data) else { return [] }
            return addingCanonicalAliases(to: records.map { $0.foodItem() })
        }
    }

    /// Reads every source JSON file from `directory` and returns the merged `FoodItem`s with the
    /// canonical aliases applied — the exact set the SQLite catalog is generated from. Generation
    /// time only; the app reads `FoodCatalog.sqlite` at runtime, never these files.
    public nonisolated static func sourceJSONFoodItems(directory: URL) -> [FoodItem] {
        let items = sourceResourceNames.flatMap { name -> [FoodItem] in
            let url = directory.appendingPathComponent(name).appendingPathExtension("json")
            guard let data = try? Data(contentsOf: url) else { return [] }
            return foodItems(from: data)
        }
        return addingCanonicalAliases(to: items)
    }

    /// Appends the "Chicken breast, roasted" alias (a copy of the braised USDA entry under a fixed
    /// alias UUID with extra tags) when the source set has the original but not the alias; the guard
    /// makes repeated application idempotent.
    nonisolated private static func addingCanonicalAliases(to items: [FoodItem]) -> [FoodItem] {
        guard !items.contains(where: { $0.name == "Chicken breast, roasted" }),
              let chickenBreast = items.first(where: {
                  $0.brandSource == "USDA FDC 331960"
                      || $0.name == "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, braised"
              }) else {
            return items
        }

        var aliased = chickenBreast
        aliased.id = UUID(uuidString: "00000000-0000-5000-8001-000000331960") ?? UUID()
        aliased.name = "Chicken breast, roasted"
        aliased.tags = Array(Set(aliased.tags + ["chicken", "breast", "roasted", "poultry"])).sorted()
        return items + [aliased]
    }
}

// `CompositeFoodLexicon` was removed here: its token-based "is this a composite word" check (which
// treated "burger patties" as a composite because it contained "burger") lost its only caller when the
// deterministic resolver switched to binding one food per split item. The authoritative dish list with
// component recipes is `DishTemplateLexicon` (DishTemplates.json); query-intent + dish demotion is
// `PreparedDishHeuristic` (FernletDomainModel), which is head-noun-aware rather than token-based.

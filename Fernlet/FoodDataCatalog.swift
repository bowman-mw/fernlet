import Foundation

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

    private enum CodingKeys: String, CodingKey {
        case id, fdcId, name, brandSource, servingSize, servingUnit, protein, carbs, fat
        case category, tags, portions, fiber, sugar, saturatedFat, cholesterol
        case vitaminA, vitaminC, vitaminD, vitaminE, vitaminK, vitaminB6, vitaminB12
        case thiamin, riboflavin, niacin, folate, calcium, iron, magnesium, phosphorus
        case potassium, sodium, zinc, omega3
        case description, dataType, brandOwner, brandName, foodCategory, foodNutrients, foodPortions
        case servingSizeUnit, householdServingFullText, labelNutrients
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        fdcId = try container.decodeIfPresent(Int.self, forKey: .fdcId)

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
            portions: portions ?? []
        )
    }

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

    nonisolated private var fdcDescription: String? {
        guard let fdcId else { return nil }
        return "USDA FDC \(fdcId)"
    }

    nonisolated private var stableUSDAID: UUID? {
        guard let fdcId, fdcId >= 0, fdcId <= 999_999_999_999 else { return nil }
        let suffix = String(format: "%012d", fdcId)
        return UUID(uuidString: "00000000-0000-5000-8000-\(suffix)")
    }
}

private struct FDCFoodNutrient: Decodable {
    let amount: Double?
    private let nutrient: FDCNutrient?
    private let nutrientIdValue: Int?

    var nutrientId: Int {
        nutrient?.id ?? nutrientIdValue ?? -1
    }

    private enum CodingKeys: String, CodingKey {
        case amount, nutrient, nutrientIdValue = "nutrientId"
    }
}

private struct FDCNutrient: Decodable {
    let id: Int?
}

private struct FDCFoodCategory: Decodable {
    let description: String?
}

private struct FDCLabelNutrients: Decodable {
    let protein: FDCLabelNutrientValue?
    let carbohydrates: FDCLabelNutrientValue?
    let fat: FDCLabelNutrientValue?
}

private struct FDCLabelNutrientValue: Decodable {
    let value: Double?
}

private struct FDCFoodPortion: Decodable {
    let amount: Double?
    let gramWeight: Double?
    let modifier: String?
    let portionDescription: String?
    let measureUnit: FDCMeasureUnit?

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

private struct FDCMeasureUnit: Decodable {
    let name: String?
    let abbreviation: String?
}

enum FoodDataCatalog {
    nonisolated static let resourceName = "USDAFoodItems"
    nonisolated static let curatedSurveyResourceName = "CuratedSurveyFoodItems"
    nonisolated private static let bundledResourceNames = [resourceName, curatedSurveyResourceName]

    nonisolated static func bundledFoodItems(bundle: Bundle = .main) -> [FoodItem] {
        StartupTiming.timed("FoodDataCatalog.bundledFoodItems") {
            if let cached = loadCachedItems(bundle: bundle) {
                return cached
            }
            let items = bundledDataFiles(bundle: bundle).flatMap { foodItems(from: $0) }
            saveCachedItems(items, bundle: bundle)
            return items
        }
    }

    nonisolated static func foodItems(from data: Data) -> [FoodItem] {
        StartupTiming.timed("FoodDataCatalog.foodItems.decode") {
            guard !data.isEmpty else { return [] }
            let decoder = JSONDecoder()
            guard let records = try? decoder.decode([USDAFoodItemRecord].self, from: data) else { return [] }
            return addingCanonicalAliases(to: records.map { $0.foodItem() })
        }
    }

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

    nonisolated private static func bundledDataFiles(bundle: Bundle) -> [Data] {
        bundledResourceNames.compactMap { resourceName in
            guard let url = bundle.url(forResource: resourceName, withExtension: "json") else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    // MARK: - Binary plist cache

    nonisolated private static func cacheURLs() -> (data: URL, key: URL) {
        let base = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0])
        return (
            data: base.appendingPathComponent("food_catalog_v2.bplist"),
            key: base.appendingPathComponent("food_catalog_v2.key")
        )
    }

    nonisolated private static func bundledCacheKey(bundle: Bundle) -> String? {
        let components = bundledResourceNames.compactMap { resourceName -> String? in
            guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { return nil }
            return "\(resourceName):\(size)-\(modified.timeIntervalSinceReferenceDate)"
        }
        return components.isEmpty ? nil : components.joined(separator: "|")
    }

    nonisolated private static func loadCachedItems(bundle: Bundle) -> [FoodItem]? {
        let urls = cacheURLs()
        guard let key = bundledCacheKey(bundle: bundle),
              let storedKey = try? String(contentsOf: urls.key, encoding: .utf8),
              key == storedKey,
              let data = try? Data(contentsOf: urls.data) else { return nil }
        return try? PropertyListDecoder().decode([FoodItem].self, from: data)
    }

    nonisolated private static func saveCachedItems(_ items: [FoodItem], bundle: Bundle) {
        let urls = cacheURLs()
        guard let key = bundledCacheKey(bundle: bundle) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: urls.data, options: .atomic)
        try? key.write(to: urls.key, atomically: true, encoding: .utf8)
    }
}

enum FoodBrandLexicon {
    nonisolated private static let chains: Set<String> = [
        "mcdonalds", "wendys", "burger king", "taco bell", "chick fil a", "subway",
        "starbucks", "chipotle", "dominos", "pizza hut", "kfc", "popeyes", "five guys",
        "shake shack", "in n out", "whataburger", "sonic", "jack in the box",
        "panda express", "olive garden", "applebees", "chilis", "red lobster",
        "outback", "panera", "dunkin", "arbys", "dairy queen", "hardees", "carls jr",
        "del taco", "wingstop", "buffalo wild wings", "cracker barrel", "ihop",
        "dennys", "waffle house", "friendlys", "bojangles", "checkers", "rallys",
        "long john silvers", "captain d"
    ]

    nonisolated static func isRestaurantChain(_ text: String) -> Bool {
        let n = FoodItemSearch.normalized(text)
        return chains.contains { n.contains($0) }
    }

    nonisolated static func queryContainsBrandToken(_ query: String) -> Bool {
        let n = FoodItemSearch.normalized(query)
        return chains.contains { n.contains($0) }
    }
}

enum CompositeFoodLexicon {
    nonisolated private static let singleTokenComposites: Set<String> = [
        "sandwich", "burger", "cheeseburger", "hamburger", "bowl", "taco", "tacos",
        "wrap", "burrito", "quesadilla", "enchilada", "fajita", "sub", "hoagie",
        "smoothie", "salad", "pizza", "stew", "casserole", "calzone", "gyro"
    ]

    nonisolated private static let multiWordComposites: [String] = [
        "grilled cheese", "stir fry", "fried rice", "lo mein", "pad thai",
        "french dip", "club sandwich", "egg salad", "tuna melt", "chicken parm"
    ]

    nonisolated static func isComposite(_ itemName: String) -> Bool {
        let normalized = FoodItemSearch.normalized(itemName)
        for term in multiWordComposites where normalized.contains(FoodItemSearch.normalized(term)) {
            return true
        }
        return normalized.split(separator: " ").map(String.init).contains { singleTokenComposites.contains($0) }
    }
}

enum FoodItemSearch {
    static let minimumQueryLength = 3

    /// Minimum score for a query to be allowed to *bind* to a catalog item. Below this the top
    /// hit matched only via category/tags (no real name signal) and is treated as no match.
    static let minimumBindScore = 1
    /// At or above this score a single-item bind is considered confident (exact/prefix/substring
    /// name hit). Between `minimumBindScore` and this, the bind is kept but flagged low-confidence.
    static let confidentBindScore = 250

    struct Index {
        private var entries: [Entry]

        init(foodItems: [FoodItem]) {
            self.entries = foodItems.map { foodItem in
                let name = FoodItemSearch.normalized(foodItem.name)
                let category = FoodItemSearch.normalized(foodItem.category)
                let tags = foodItem.tags.map { FoodItemSearch.normalized($0) }.joined(separator: " ")
                let searchable = [name, category, tags].joined(separator: " ")
                return Entry(
                    foodItem: foodItem,
                    normalizedName: name,
                    nameTokens: Set(name.split(separator: " ").map(String.init)),
                    searchableTokens: FoodItemSearch.tokens(in: searchable)
                )
            }
        }

        static let empty = Index(foodItems: [])

        fileprivate func matches(queryTokens: [String], normalizedQuery: String, limit: Int) -> [FoodItem] {
            scoredMatches(queryTokens: queryTokens, normalizedQuery: normalizedQuery, limit: limit).map(\.foodItem)
        }

        fileprivate func scoredMatches(queryTokens: [String], normalizedQuery: String, limit: Int) -> [(foodItem: FoodItem, score: Int)] {
            let isBrandQuery = FoodBrandLexicon.queryContainsBrandToken(normalizedQuery)
            return Array(
                entries
                    .compactMap { entry -> (foodItem: FoodItem, score: Int)? in
                        guard let score = FoodItemSearch.score(entry, queryTokens: queryTokens, normalizedQuery: normalizedQuery) else { return nil }
                        return (entry.foodItem, score)
                    }
                    .sorted { first, second in
                        if first.foodItem.source != second.foodItem.source {
                            return FoodItemSearch.sourcePriority(first.foodItem.source) > FoodItemSearch.sourcePriority(second.foodItem.source)
                        }
                        let firstType = FoodItemSearch.dataTypePriority(first.foodItem.dataType, brandQuery: isBrandQuery)
                        let secondType = FoodItemSearch.dataTypePriority(second.foodItem.dataType, brandQuery: isBrandQuery)
                        if firstType != secondType { return firstType > secondType }
                        if first.score != second.score { return first.score > second.score }
                        return first.foodItem.name.localizedStandardCompare(second.foodItem.name) == .orderedAscending
                    }
                    .prefix(limit)
            )
        }

        func exactNameMatch(for normalizedName: String) -> FoodItem? {
            entries
                .filter { $0.normalizedName == normalizedName }
                .sorted {
                    if $0.foodItem.source != $1.foodItem.source {
                        return FoodItemSearch.sourcePriority($0.foodItem.source) > FoodItemSearch.sourcePriority($1.foodItem.source)
                    }
                    return $0.foodItem.name.localizedStandardCompare($1.foodItem.name) == .orderedAscending
                }
                .first?
                .foodItem
        }

        fileprivate struct Entry {
            var foodItem: FoodItem
            var normalizedName: String
            var nameTokens: Set<String>
            var searchableTokens: [String]
        }
    }

    static func results(for query: String, in foodItems: [FoodItem], limit: Int = 6) -> [FoodItem] {
        results(for: query, in: Index(foodItems: foodItems), limit: limit)
    }

    static func results(for query: String, in index: Index, limit: Int = 6) -> [FoodItem] {
        let normalizedQuery = normalized(query)
        guard normalizedQuery.count >= minimumQueryLength else { return [] }
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }
        return index.matches(queryTokens: queryTokens, normalizedQuery: normalizedQuery, limit: limit)
    }

    /// Like `results(for:in:limit:)` but returns the internal relevance score alongside each item
    /// so callers can apply a confidence floor (e.g. drop weak binds, flag low-confidence matches).
    static func scoredResults(for query: String, in index: Index, limit: Int = 6) -> [(item: FoodItem, score: Int)] {
        let normalizedQuery = normalized(query)
        guard normalizedQuery.count >= minimumQueryLength else { return [] }
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }
        return index.scoredMatches(queryTokens: queryTokens, normalizedQuery: normalizedQuery, limit: limit)
            .map { (item: $0.foodItem, score: $0.score) }
    }

    nonisolated static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : " "
            }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func score(_ entry: Index.Entry, queryTokens: [String], normalizedQuery: String) -> Int? {
        guard queryTokens.allSatisfy({ queryToken in
            entry.searchableTokens.contains { foodToken in
                foodToken == queryToken || foodToken.hasPrefix(queryToken)
            }
        }) else {
            return nil
        }

        var score = 0
        let name = entry.normalizedName
        if name == normalizedQuery { score += 1_000 }
        if name.hasPrefix(normalizedQuery) { score += 500 }
        if name.contains(normalizedQuery) { score += 250 }
        score += queryTokens.reduce(0) { partial, queryToken in
            partial + (entry.nameTokens.contains(queryToken) ? 60 : 0)
        }
        score -= max(name.count - normalizedQuery.count, 0) / 8
        score += preparationBias(queryTokens: queryTokens, normalizedQuery: normalizedQuery, candidateName: entry.foodItem.name)
        score += formSpecificityBias(queryTokens: queryTokens, candidateName: entry.foodItem.name)
        return score
    }

    // Penalises candidates that are a derivative/sub-part *form* of a food the user named plainly.
    // e.g. query "egg" should resolve to whole egg, not "egg yolk", "egg white", or "egg powder";
    // "orange" should beat "orange juice"/"orange peel". Only fires when the candidate carries a
    // form qualifier the query did NOT ask for, so naming the part ("egg whites") keeps it neutral.
    private static func formSpecificityBias(queryTokens: [String], candidateName: String) -> Int {
        let querySet = Set(queryTokens)
        let candidateTokens = Set(normalized(candidateName).split(separator: " ").map(String.init))
        let extraneousForms = candidateTokens.intersection(formQualifierTokens).subtracting(querySet)
        return extraneousForms.isEmpty ? 0 : -130 * extraneousForms.count
    }

    // Tokens that mark a non-default form / derivative of a base food.
    private static let formQualifierTokens: Set<String> = [
        "yolk", "yolks", "white", "whites", "powder", "powdered", "dried", "dehydrated",
        "concentrate", "paste", "juice", "extract", "substitute", "imitation", "peel",
        "skin", "skins", "flour", "flakes", "puree"
    ]

    // M1a: Additive preparation bias — rewards matching preparation, penalises conflicting ones.
    // Not a hard filter: a missing fresh entry still wins over nothing.
    private static func preparationBias(queryTokens: [String], normalizedQuery: String, candidateName: String) -> Int {
        let querySet = Set(queryTokens)
        let impliesRaw     = !querySet.isDisjoint(with: rawImpliedTokens)
        let impliesGrilled = !querySet.isDisjoint(with: grilledImpliedTokens)
        let impliesBaked   = !querySet.isDisjoint(with: bakedImpliedTokens)
        let impliesFried   = !querySet.isDisjoint(with: friedImpliedTokens)
        let impliesCanned  = !querySet.isDisjoint(with: cannedImpliedTokens)
            || normalizedQuery.contains("in water") || normalizedQuery.contains("in oil")
        let impliesSmoked  = querySet.contains("smoked")
        let impliesDried   = !querySet.isDisjoint(with: driedImpliedTokens)

        guard impliesRaw || impliesGrilled || impliesBaked || impliesFried
                || impliesCanned || impliesSmoked || impliesDried else { return 0 }

        let cand = normalized(candidateName)
        let isRaw     = cand.contains("raw") || cand.contains("fresh")
        let isGrilled = cand.contains("grilled")
        let isBaked   = cand.contains("baked") || cand.contains("roasted")
        let isFried   = cand.contains("fried") || cand.contains("breaded")
        let isCanned  = cand.contains("canned") || cand.contains("in water") || cand.contains("in oil")
        let isSmoked  = cand.contains("smoked")
        let isDried   = cand.contains("dried") || cand.contains("jerky")

        var bias = 0
        if impliesRaw {
            if isRaw                              { bias += 150 }
            else if isCanned || isDried || isSmoked { bias -= 200 }
        }
        if impliesGrilled {
            if isGrilled                    { bias += 150 }
            else if isCanned || isFried     { bias -= 200 }
        }
        if impliesBaked {
            if isBaked                      { bias += 150 }
            else if isCanned || isFried     { bias -= 150 }
        }
        if impliesFried {
            if isFried          { bias += 150 }
            else if isRaw       { bias -= 100 }
        }
        if impliesCanned {
            if isCanned                     { bias += 150 }
            else if isRaw || isGrilled      { bias -= 150 }
        }
        if impliesSmoked {
            if isSmoked                     { bias += 150 }
            else if isRaw || isCanned       { bias -= 100 }
        }
        if impliesDried {
            if isDried          { bias += 150 }
            else if isRaw       { bias -= 100 }
        }
        return bias
    }

    // Dish-context tokens that imply a preparation even without an explicit word
    private static let rawImpliedTokens: Set<String>     = ["raw", "fresh", "sashimi", "sushi", "nigiri", "poke", "tartare", "ceviche"]
    private static let grilledImpliedTokens: Set<String> = ["grilled", "grill", "bbq", "charbroiled"]
    private static let bakedImpliedTokens: Set<String>   = ["baked", "roasted"]
    private static let friedImpliedTokens: Set<String>   = ["fried", "breaded", "crispy", "tempura"]
    private static let cannedImpliedTokens: Set<String>  = ["canned", "tinned"]
    private static let driedImpliedTokens: Set<String>   = ["dried", "jerky", "dehydrated"]

    private static func sourcePriority(_ source: FoodItemSource) -> Int {
        switch source {
        case .manual: 3
        case .usda: 2
        case .aiResolved: 1
        }
    }

    static func dataTypePriority(_ dataType: FoodDataType, brandQuery: Bool) -> Int {
        if brandQuery {
            switch dataType {
            case .restaurant: return 5
            case .branded: return 4
            case .foundation: return 3
            case .survey: return 2
            case .srLegacy: return 1
            }
        } else {
            switch dataType {
            case .foundation: return 5
            case .survey: return 4
            case .srLegacy: return 3
            case .branded: return 2
            case .restaurant: return 1
            }
        }
    }

    private static func tokens(in text: String) -> [String] {
        normalized(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 }
    }
}

import Foundation

struct USDAFoodItemRecord: Codable {
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
    var tags: [String]?
    var portions: [FoodPortion]?
    var micronutrients: Micronutrients?
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
            lastVerified: nil,
            tags: tags ?? ["usda"],
            portions: portions ?? []
        )
    }

    nonisolated private var resolvedMicronutrients: Micronutrients {
        micronutrients ?? Micronutrients(
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

enum FoodDataCatalog {
    nonisolated static let resourceName = "USDAFoodItems"

    nonisolated static func bundledFoodItems(bundle: Bundle = .main) -> [FoodItem] {
        StartupTiming.timed("FoodDataCatalog.bundledFoodItems") {
            guard let data = bundledData(bundle: bundle) else { return [] }
            return foodItems(from: data)
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

    nonisolated private static func bundledData(bundle: Bundle) -> Data? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
}

enum FoodItemSearch {
    static let minimumQueryLength = 3

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
            entries
                .compactMap { entry -> (foodItem: FoodItem, score: Int)? in
                    guard let score = FoodItemSearch.score(entry, queryTokens: queryTokens, normalizedQuery: normalizedQuery) else { return nil }
                    return (entry.foodItem, score)
                }
                .sorted { first, second in
                    if first.foodItem.source != second.foodItem.source {
                        return FoodItemSearch.sourcePriority(first.foodItem.source) > FoodItemSearch.sourcePriority(second.foodItem.source)
                    }
                    if first.score != second.score { return first.score > second.score }
                    return first.foodItem.name.localizedStandardCompare(second.foodItem.name) == .orderedAscending
                }
                .prefix(limit)
                .map(\.foodItem)
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

    static func normalized(_ text: String) -> String {
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
        return score
    }

    private static func sourcePriority(_ source: FoodItemSource) -> Int {
        switch source {
        case .manual: 3
        case .usda: 2
        case .aiResolved: 1
        }
    }

    private static func tokens(in text: String) -> [String] {
        normalized(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 }
    }
}

enum RecipeSearch {
    static func results(for query: String, recipes: [RecipeDefinition], foodItems: [FoodItem]) -> [RecipeDefinition] {
        let normalizedQuery = FoodItemSearch.normalized(query)
        guard !normalizedQuery.isEmpty else { return recipes }
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        guard !queryTokens.isEmpty else { return recipes }
        return recipes.filter { recipe in
            let haystack = searchableText(for: recipe, foodItems: foodItems)
            return queryTokens.allSatisfy { token in
                haystack.contains(token)
            }
        }
    }

    private static func searchableText(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> String {
        let ingredientText = recipe.ingredients.compactMap { ingredient in
            foodItems.first { $0.id == ingredient.foodItemId }.map { foodItem in
                "\(foodItem.name) \(foodItem.category) \(foodItem.tags.joined(separator: " "))"
            }
        }.joined(separator: " ")
        return FoodItemSearch.normalized("\(recipe.name) \(ingredientText)")
    }
}

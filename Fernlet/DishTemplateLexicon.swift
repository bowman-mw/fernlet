import Foundation

// MARK: - JSON types

struct DishTemplateComponent: Decodable {
    let search: String
    let gramsPerUnit: Double
    let preparation: String?
}

struct DishTemplate: Decodable {
    let name: String
    let aliases: [String]
    let isComposite: Bool
    let unit: String
    let defaultCount: Double
    let components: [DishTemplateComponent]
}

private struct DishTemplateFile: Decodable {
    let version: Int
    let dishes: [DishTemplate]
}

// MARK: - Lexicon

/// Loads DishTemplates.json once and provides deterministic dish lookup for the M2 fallback path.
enum DishTemplateLexicon {
    /// Single lazy load — both templates and the name index built together.
    private static let catalog: (templates: [DishTemplate], index: [String: DishTemplate]) = {
        guard
            let url = Bundle.main.url(forResource: "DishTemplates", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(DishTemplateFile.self, from: data)
        else { return ([], [:]) }

        var index: [String: DishTemplate] = [:]
        for template in file.dishes {
            for rawName in [template.name] + template.aliases {
                index[FoodItemSearch.normalized(rawName)] = template
            }
        }
        return (file.dishes, index)
    }()

    // MARK: Lookup

    /// Returns the best-matching template and the count extracted from the item name.
    /// e.g. "6 pieces salmon nigiri" → (nigiriTemplate, 6.0)
    static func matchWithCount(_ itemName: String) -> (DishTemplate?, Double) {
        let norm = FoodItemSearch.normalized(itemName)
        let count = extractLeadingCount(from: norm)

        // Exact key match
        if let template = catalog.index[norm] {
            return (template, count ?? template.defaultCount)
        }
        // Longest-substring match (avoids "roll" matching "roll" in "spring roll blend")
        var best: (length: Int, template: DishTemplate)?
        for (key, template) in catalog.index where norm.contains(key) {
            if best == nil || key.count > best!.length {
                best = (key.count, template)
            }
        }
        if let (_, template) = best {
            return (template, count ?? template.defaultCount)
        }
        return (nil, 1)
    }

    static func isComposite(_ itemName: String) -> Bool {
        matchWithCount(itemName).0?.isComposite == true
    }

    // MARK: Resolution

    /// Resolves `description` into `Meal`s using dish templates + the full food catalog.
    ///
    /// All items split from the description must be found in the lexicon for this to return non-nil;
    /// if any item is unrecognised the whole call returns nil so the next fallback tier can handle it.
    static func resolve(
        description: String,
        mealType: MealType?,
        foodItems: [FoodItem]
    ) -> [Meal]? {
        guard !foodItems.isEmpty else { return nil }
        let items = MealItemSplitter.items(from: description)
        guard !items.isEmpty else { return nil }

        let index = FoodItemSearch.Index(foodItems: foodItems)
        var resolvedMeals: [Meal] = []

        for itemName in items {
            let (template, count) = matchWithCount(itemName)
            guard let template = template else { return nil }  // require all items to match
            guard let meal = assemble(
                template: template, count: count, itemName: itemName,
                mealType: mealType, description: description, index: index
            ) else { return nil }
            resolvedMeals.append(meal)
        }

        return resolvedMeals.isEmpty ? nil : resolvedMeals
    }

    // MARK: Private assembly

    private static func assemble(
        template: DishTemplate,
        count: Double,
        itemName: String,
        mealType: MealType?,
        description: String,
        index: FoodItemSearch.Index
    ) -> Meal? {
        let resolvedIngredients: [(FoodSelectionIngredient, FoodItem)] = template.components.compactMap { component in
            let prep = component.preparation ?? ""
            let query = prep.isEmpty ? component.search : "\(prep) \(component.search)"
            guard let foodItem = FoodItemSearch.results(for: query, in: index, limit: 1).first else { return nil }
            let grams = component.gramsPerUnit * count
            let ingredient = FoodSelectionIngredient(
                candidateId: 0,
                foodName: foodItem.name,
                quantity: grams,
                unit: RecipeUnit.gram.rawValue
            )
            return (ingredient, foodItem)
        }
        guard !resolvedIngredients.isEmpty else { return nil }

        let resolvedType = mealType ?? MealParser.classifyMealType(description)
        let displayName = itemName.trimmingCharacters(in: .whitespaces).isEmpty
            ? template.name.capitalized
            : itemName.capitalized
        return MealBuilder.mealFromIngredients(
            itemName: displayName,
            resolvedIngredients: resolvedIngredients,
            mealType: resolvedType
        )
    }

    // MARK: Count extraction

    /// Extracts a leading numeric count from a normalised item name, e.g. "6 pieces" → 6.
    private static func extractLeadingCount(from normalized: String) -> Double? {
        guard let firstToken = normalized.split(separator: " ").first.map(String.init),
              let count = Double(firstToken), count > 0 else { return nil }
        return count
    }
}

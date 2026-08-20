import Foundation
import FernletDomainModel
import FernletFoundation
import FernletScoring
import FoodCatalog

// MARK: - JSON types

/// One ingredient line of a dish template as decoded from `DishTemplates.json`: a catalog search
/// term, the edible grams contributed per natural unit of the dish, and an optional preparation.
///
/// `search` (prefixed by `preparation` when present) becomes the ``DishTemplateLexicon`` catalog
/// query; `gramsPerUnit × count` gives the resolved quantity.
struct DishTemplateComponent: Decodable {
    let search: String
    let gramsPerUnit: Double
    let preparation: String?
}

/// A per-alias component substitution inside a dish template (e.g. "salmon nigiri" swapping the
/// generic fish for salmon).
///
/// When the alias matches, its `componentOverrides` are appended to the template's base components
/// during assembly.
struct DishTemplateAliasOverride: Decodable {
    let alias: String
    let componentOverrides: [DishTemplateComponent]
}

/// One dish entry decoded from `DishTemplates.json`: canonical name, lookup aliases, natural unit
/// ("piece", "roll"…), a default count, and its ingredient components.
///
/// The backing data for the M2 deterministic tier — ``DishTemplateLexicon`` indexes every name and
/// alias, and `MealBuilder.defaultRecipeServings` reads `defaultCount` as the auto-mint yield hint.
struct DishTemplate: Decodable {
    let name: String
    let aliases: [String]
    let aliasOverrides: [DishTemplateAliasOverride]?
    let isComposite: Bool
    let unit: String
    let defaultCount: Double
    let components: [DishTemplateComponent]
}

/// A lexicon index hit: the matched template plus any alias-specific component overrides that the
/// matched key carried.
///
/// Produced by ``DishTemplateLexicon``'s lookup and consumed by its assembly and gram-bound paths.
struct DishTemplateMatch {
    let template: DishTemplate
    let componentOverrides: [DishTemplateComponent]
}

/// The top-level shape of `DishTemplates.json` — a schema version plus the dish list.
///
/// Decoded once by ``DishTemplateLexicon``'s lazy catalog load; a decode failure degrades to an
/// empty lexicon rather than failing.
private struct DishTemplateFile: Decodable {
    let version: Int
    let dishes: [DishTemplate]
}

// MARK: - Lexicon

/// Loads DishTemplates.json once and provides deterministic dish lookup for the M2 fallback path.
///
/// The first deterministic tier of the quick-log cascade (``MealResolutionService``): when AI is off
/// or the AI tiers fall through, it matches composite dishes ("6 pieces salmon nigiri") by exact or
/// longest-substring name/alias, extracts a leading count, and assembles catalog-grounded meals via
/// ``MealBuilder``. It also supplies per-component gram bounds that ``MealDecompositionResolver``
/// uses to sanity-clamp the AI tier's estimates, and default yields for auto-minted recipes. A
/// missing or undecodable JSON degrades to an empty lexicon (every lookup misses).
enum DishTemplateLexicon {
    /// Single lazy load — both templates and the name index built together.
    private static let catalog: (templates: [DishTemplate], index: [String: DishTemplateMatch]) = {
        guard let url = Bundle.main.url(forResource: "DishTemplates", withExtension: "json") else {
            // Recovery: an empty lexicon — every lookup misses and the cascade falls to its next tier.
            FernletAuditLog.log("dishTemplates.load.failed", context: ["reason": "bundled resource missing"])
            return ([], [:])
        }
        let file: DishTemplateFile
        do {
            let data = try Data(contentsOf: url)
            file = try JSONDecoder().decode(DishTemplateFile.self, from: data)
        } catch {
            // A bundled resource that won't decode is a build error, not a runtime condition — name it
            // in DEBUG and log it in Release, then degrade to an empty lexicon (M2 tier disabled).
            assertionFailure("DishTemplates.json failed to load: \(error)")
            FernletAuditLog.log("dishTemplates.load.failed", context: ["error": error.localizedDescription])
            return ([], [:])
        }

        var index: [String: DishTemplateMatch] = [:]
        for template in file.dishes {
            for rawName in [template.name] + template.aliases {
                index[FoodItemSearch.normalized(rawName)] = DishTemplateMatch(
                    template: template,
                    componentOverrides: []
                )
            }
            for override in template.aliasOverrides ?? [] {
                index[FoodItemSearch.normalized(override.alias)] = DishTemplateMatch(
                    template: template,
                    componentOverrides: override.componentOverrides
                )
            }
        }
        return (file.dishes, index)
    }()

    /// Upper bound on a typed leading count ("6 pieces nigiri"): a plausible number of natural units of
    /// one dish. R5 — the count is user input and scales every component's grams.
    static let maxLeadingCount = 100.0

    // MARK: Lookup

    /// Returns the best-matching template and the count extracted from the item name.
    /// e.g. "6 pieces salmon nigiri" → (nigiriTemplate, 6.0)
    static func matchWithCount(_ itemName: String) -> (DishTemplate?, Double) {
        let (match, count) = matchDetailsWithCount(itemName)
        return (match?.template, count)
    }

    private static func matchDetailsWithCount(_ itemName: String) -> (DishTemplateMatch?, Double) {
        let norm = FoodItemSearch.normalized(itemName)
        let count = extractLeadingCount(from: norm)

        // Exact key match
        if let match = catalog.index[norm] {
            return (match, count ?? match.template.defaultCount)
        }
        // Longest-substring match (avoids "roll" matching "roll" in "spring roll blend")
        let best = catalog.index
            .filter { norm.contains($0.key) }
            .max { $0.key.count < $1.key.count }
        if let best {
            return (best.value, count ?? best.value.template.defaultCount)
        }
        return (nil, 1)
    }

    /// Whether the item name matches a template flagged as a composite dish (one made of several
    /// distinct components, like nigiri or a burrito).
    static func isComposite(_ itemName: String) -> Bool {
        matchWithCount(itemName).0?.isComposite == true
    }

    // MARK: Component bounds

    /// Plausible gram ranges (0.5×–1.75× of the template amount) for each component of every dish the
    /// description names, keyed by normalized search term. Used by `MealDecompositionResolver` to
    /// clamp the AI tier's per-component gram estimates toward template reality.
    static func componentGramBounds(description: String) -> [String: ClosedRange<Double>] {
        var bounds: [String: ClosedRange<Double>] = [:]
        for itemName in MealItemSplitter.items(from: description) {
            let (match, count) = matchDetailsWithCount(itemName)
            guard let match else { continue }
            for component in match.template.components + match.componentOverrides {
                let grams = max(component.gramsPerUnit * count, 1)
                let lower = max(1, grams * 0.5)
                let upper = max(lower, grams * 1.75)
                let prep = component.preparation ?? ""
                let query = prep.isEmpty ? component.search : "\(prep) \(component.search)"
                bounds[FoodItemSearch.normalized(component.search)] = lower...upper
                bounds[FoodItemSearch.normalized(query)] = lower...upper
            }
        }
        return bounds
    }

    // MARK: Resolution

    /// Resolves `description` into `Meal`s using dish templates + the full food catalog.
    ///
    /// All items split from the description must be found in the lexicon for this to return non-nil;
    /// if any item is unrecognised the whole call returns nil so the next fallback tier can handle it.
    static func resolve(
        description: String,
        mealType: MealType?,
        catalog: FoodCatalog
    ) -> [Meal]? {
        let items = MealItemSplitter.items(from: description)
        guard !items.isEmpty else { return nil }

        var resolvedMeals: [Meal] = []

        for itemName in items {
            let (match, count) = matchDetailsWithCount(itemName)
            guard let match = match else { return nil }  // require all items to match
            guard let meal = assemble(
                match: match, count: count, itemName: itemName,
                mealType: mealType, description: description, catalog: catalog
            ) else { return nil }
            resolvedMeals.append(meal)
        }

        return resolvedMeals.isEmpty ? nil : resolvedMeals
    }

    // MARK: Private assembly

    private static func assemble(
        match: DishTemplateMatch,
        count: Double,
        itemName: String,
        mealType: MealType?,
        description: String,
        catalog: FoodCatalog
    ) -> Meal? {
        let template = match.template
        let components = template.components + match.componentOverrides
        let resolvedIngredients: [(FoodSelectionIngredient, FoodItem)] = components.compactMap { component in
            let prep = component.preparation ?? ""
            let query = prep.isEmpty ? component.search : "\(prep) \(component.search)"
            guard let foodItem = catalog.results(for: query, limit: 1).first else { return nil }
            // R3/R5: no single template component may exceed the shared single-log gram cap, however
            // large a count the user typed.
            let grams = min(component.gramsPerUnit * count, MealPlausibility.maxSingleLogGrams)
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
    ///
    /// The value comes straight from typed user text and is multiplied by `gramsPerUnit` downstream,
    /// so it is validated (finite, positive) and clamped to ``maxLeadingCount`` at this boundary —
    /// unclamped, "99999999999999999999 nigiri" would overflow the `Int(Double)` conversion inside
    /// `Macros.scaled(by:)` and trap.
    private static func extractLeadingCount(from normalized: String) -> Double? {
        guard let firstToken = normalized.split(separator: " ").first.map(String.init),
              let count = LocaleTolerantNumber.double(from: firstToken),
              count.isFinite, count > 0 else { return nil }
        return min(count, maxLeadingCount)
    }
}

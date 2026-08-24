import Foundation
import FernletDomainModel
import FoodCatalog

/// A cold, catalog-grounded single-row probe run before any meal decomposition tier.
///
/// The typed household unit is routed to `FoodPortion` rather than discarded as a search stopword.
/// A row may short-circuit only when the existing resolver confidence floor and a compatible,
/// positive portion mapping both hold. Search is deliberately through `scoredResults`: that seam has
/// no history/correction input and preserves the position stopwords, guarded dish demotion, and both
/// search floors shipped by research items 1.6–1.9.
@MainActor
enum WholeDescriptionFoodProbe {
    struct Match {
        let item: FoodItem
        let grams: Double
        let score: Int
        let portion: FoodPortion
        let ingredientQuantity: Double
        let ingredientUnit: String
        let unmatchedItems: [String]
    }

    struct ServingBasis: Equatable {
        let quantity: Double
        let unit: String
        let grams: Double
    }

    private struct ParsedDescription {
        let searchText: String
        let quantity: Double
        let unit: String
    }

    /// Keeps an unsafe first compatible row distinct from a genuine miss. Only a genuine miss may
    /// retry after removing a retailer chip; an unsafe row aborts the entire probe.
    private enum CandidateOutcome {
        case noCompatibleCandidate
        case unsafeBasis
        case match(Match)
    }

    /// Same bounded ranking window used by the searcher's prepared-dish pass. This probe never walks
    /// the 118k-row catalog itself; SQLite/`FoodItemSearch` return at most this many scored candidates.
    private static let candidateLimit = 60
    private static let maximumTokens = 60
    private static let maximumDescriptionCharacters = 512
    private static let maximumPortionsPerFood = 60

    /// Corpus-calibrated high floor for this more powerful pre-decomposition short-circuit.
    ///
    /// The shared 250 floor remains necessary but is not sufficient here: the owning 57-query corpus
    /// and 32-query resolver bank contain portion-compatible wrong answers at 308–309 (`piece of
    /// chicken`, `slice of toast`, `cup of coffee`). The prescribed pizza target's first compatible
    /// row scores 368. Choosing that target score is the highest conservative floor that still admits
    /// the acceptance case; the population test pins all three exclusions and every query that fires.
    static let acceptanceScore = 368

    /// Count words are frozen English matching inputs, not display text. Numeric counts use the
    /// existing locale-tolerant decimal parser; item 12 still owns any new household-unit cases.
    private static let countWords: [String: Double] = [
        "half": 0.5, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "dozen": 12
    ]

    static func match(description: String, catalog: FoodCatalog) -> Match? {
        compatibleMatch(
            description: description,
            catalog: catalog,
            minimumScore: max(FoodItemSearch.confidentBindScore, acceptanceScore)
        )
    }

    /// Testable calibration seam: the same cold compatible-row walk with an injected score floor.
    /// Production always calls it with `acceptanceScore`; audit tests use 250 to pin the unsafe rows
    /// that justify the narrower gate.
    static func compatibleMatch(
        description: String,
        catalog: FoodCatalog,
        minimumScore: Int
    ) -> Match? {
        guard let parsed = parsedDescription(description) else { return nil }
        switch firstMatch(
            parsed: parsed, query: parsed.searchText, catalog: catalog, minimumScore: minimumScore
        ) {
        case .match(let direct): return direct
        case .unsafeBasis: return nil
        case .noCompatibleCandidate: break
        }

        let chips = DishTemplateLexicon.unaccountedBrandChips(itemName: description, matchedKey: "")
        guard !chips.isEmpty else { return nil }
        let stripped = brandStrippedQuery(parsed.searchText, chips: chips)
        guard stripped != parsed.searchText else { return nil }
        let outcome = firstMatch(
            parsed: parsed, query: stripped, catalog: catalog, minimumScore: minimumScore
        )
        guard case .match(let matched) = outcome else { return nil }
        return Match(
            item: matched.item,
            grams: matched.grams,
            score: matched.score,
            portion: matched.portion,
            ingredientQuantity: matched.ingredientQuantity,
            ingredientUnit: matched.ingredientUnit,
            unmatchedItems: chips
        )
    }

    private static func firstMatch(
        parsed: ParsedDescription,
        query: String,
        catalog: FoodCatalog,
        minimumScore: Int
    ) -> CandidateOutcome {
        guard !query.isEmpty else { return .noCompatibleCandidate }
        let rows = catalog.scoredResults(for: query, limit: candidateLimit)
        for row in rows {
            guard row.score >= minimumScore,
                  let portion = matchingPortion(in: row.item, unit: parsed.unit) else { continue }
            // A compatible row whose food basis cannot be represented safely terminates the probe:
            // choosing a later row would mask the unsafe top answer rather than fail closed.
            guard let match = safeMatch(
                item: row.item, score: row.score, portion: portion, quantity: parsed.quantity
            ) else { return .unsafeBasis }
            return .match(match)
        }
        return .noCompatibleCandidate
    }

    static func safeMatch(
        item: FoodItem,
        score: Int,
        portion: FoodPortion,
        quantity: Double,
        unmatchedItems: [String] = []
    ) -> Match? {
        guard let basis = servingBasis(item: item, portion: portion, quantity: quantity) else { return nil }
        return Match(
            item: item,
            grams: basis.grams,
            score: score,
            portion: portion,
            ingredientQuantity: basis.quantity,
            ingredientUnit: basis.unit,
            unmatchedItems: unmatchedItems
        )
    }

    /// Expresses the typed portion in the food's TRUE nutrition basis. Raw `slice`/`piece` bases are
    /// safe only when they are the food's own basis; otherwise an existing convertible RecipeUnit is
    /// required. Unsupported bases return nil so later resolution tiers can act.
    static func servingBasis(item: FoodItem, portion: FoodPortion, quantity: Double) -> ServingBasis? {
        guard quantity.isFinite, quantity > 0, quantity <= 100,
              portion.amount.isFinite, portion.amount > 0,
              portion.amount <= MealPlausibility.maxSingleLogGrams,
              portion.gramWeight.isFinite, portion.gramWeight > 0,
              portion.gramWeight <= MealPlausibility.maxSingleLogGrams,
              item.servingSize.isFinite, item.servingSize > 0,
              item.servingSize <= MealPlausibility.maxSingleLogGrams else { return nil }
        let gramsPerUnit = portion.gramWeight / portion.amount
        let grams = gramsPerUnit * quantity
        guard gramsPerUnit.isFinite, gramsPerUnit > 0,
              grams.isFinite, grams > 0, grams <= MealPlausibility.maxSingleLogGrams else { return nil }

        let portionUnit = normalizedUnit(portion.unit)
        let servingUnit = normalizedUnit(item.servingUnit)
        if let portionUnit, portionUnit == servingUnit {
            return ServingBasis(quantity: quantity, unit: item.servingUnit, grams: grams)
        }
        guard servingUnit != nil,
              let servingGrams = item.gramsEquivalent(
                quantity: item.servingSize, unit: item.servingUnit
              ), servingGrams.isFinite, servingGrams > 0 else { return nil }
        let basisQuantity = (grams / servingGrams) * item.servingSize
        guard basisQuantity.isFinite, basisQuantity > 0,
              basisQuantity <= MealPlausibility.maxSingleLogGrams else { return nil }
        return ServingBasis(quantity: basisQuantity, unit: item.servingUnit, grams: grams)
    }

    private static func parsedDescription(_ description: String) -> ParsedDescription? {
        guard description.count <= maximumDescriptionCharacters else { return nil }
        let tokens = description.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, tokens.count <= maximumTokens else { return nil }
        var unitIndex: Int?
        var unit: String?
        for (index, token) in tokens.enumerated() {
            let normalized = FoodItemSearch.normalized(token)
            guard !normalized.contains(" "), let candidate = normalizedUnit(normalized) else { continue }
            guard unitIndex == nil else { return nil }
            unitIndex = index
            unit = candidate
        }
        guard let index = unitIndex, let unit else { return nil }
        let countIndex = index > 0 ? index - 1 : nil
        let explicitCount = countIndex.flatMap { quantity(tokens[$0]) }
        let count = explicitCount ?? 1
        guard count.isFinite, count > 0, count <= 100 else { return nil }
        let removed = Set([index, explicitCount == nil ? nil : countIndex].compactMap { $0 })
        let search = tokens.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        guard !search.isEmpty else { return nil }
        let searchText = FoodItemSearch.normalized(search.joined(separator: " "))
        guard !searchText.isEmpty else { return nil }
        return ParsedDescription(searchText: searchText, quantity: count, unit: unit)
    }

    private static func normalizedUnit(_ token: String) -> String? {
        switch token {
        case "slice", "slices": return "slice"
        case "piece", "pieces": return "piece"
        default: return RecipeUnit.normalized(token)?.rawValue
        }
    }

    private static func quantity(_ token: String) -> Double? {
        countWords[FoodItemSearch.normalized(token)] ?? LocaleTolerantNumber.double(from: token)
    }

    private static func matchingPortion(in item: FoodItem, unit: String) -> FoodPortion? {
        for portion in item.portions.prefix(maximumPortionsPerFood) {
            let portionTokens = FoodItemSearch.normalized(portion.unit).split(separator: " ").map(String.init)
            guard let first = portionTokens.first else { continue }
            if normalizedUnit(first) == unit { return portion }
        }
        return nil
    }

    private static func brandStrippedQuery(_ query: String, chips: [String]) -> String {
        var padded = " \(FoodItemSearch.normalized(query)) "
        for chip in chips.prefix(maximumTokens) {
            let term = FoodItemSearch.normalized(chip)
            guard !term.isEmpty else { continue }
            padded = padded.replacingOccurrences(of: " \(term) ", with: " ")
        }
        return padded.split(separator: " ").joined(separator: " ")
    }
}

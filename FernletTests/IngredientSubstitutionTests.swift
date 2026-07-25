import Foundation
import Testing
import AIContext
import AIProviders
import FernletDomainModel
@testable import Fernlet

/// F4 ingredient substitution (decision §11.4): payload discipline, candidate-number binding, fork
/// provenance + source immutability, tolerant `parentRecipeID` decode, mesh wire-compat, deterministic
/// fallback, and code-side (never model-side) quantity/macro computation.
@Suite struct IngredientSubstitutionTests {

    // MARK: - Builders

    private func food(
        id: UUID = UUID(),
        name: String,
        servingSize: Double = 100,
        servingUnit: String = "g",
        macros: Macros = Macros(protein: 5, carbs: 10, fat: 2),
        portions: [FoodPortion] = []
    ) -> FoodItem {
        FoodItem(
            id: id,
            name: name,
            servingSize: servingSize,
            servingUnit: servingUnit,
            macros: macros,
            micronutrients: Micronutrients(),
            category: "test",
            source: .manual,
            tags: [],
            portions: portions
        )
    }

    private func recipe(ingredients: [RecipeIngredient], name: String = "Weeknight Pasta") -> RecipeDefinition {
        RecipeDefinition(
            name: name,
            servings: 4,
            ingredients: ingredients,
            notes: "gentle",
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    // MARK: - Payload field set

    @Test func payloadIncludedFieldsAreNamesOnly() {
        let payload = IngredientSubstitutionPayload(recipeName: "Pasta", ingredientToReplace: "butter")
        // World-knowledge substitution sends ONLY the two names — no local candidate pool, so the payload
        // is genuinely names-only (the model proposes names; code rebinds them through the catalog).
        #expect(payload.includedFieldNames == ["recipeName", "ingredientToReplace"])
        #expect(payload.payloadKind == "ingredient-substitution")
    }

    @Test func payloadCarriesNoForbiddenFields() {
        let payload = IngredientSubstitutionPayload(recipeName: "Pasta", ingredientToReplace: "butter")
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        for forbidden in ["journalText", "journalEntry", "periodData", "tierTwoMemories", "narrative", "symptoms", "healthMetrics", "notes", "candidates"] {
            #expect(!fields.contains(forbidden))
        }
    }

    @Test func substitutionPayloadNotInMemoryAllowlist() {
        // Conscious registration: the substitution prompt must receive ZERO TierTwo behavioral context.
        let record = TierTwoMemoryRecord(category: "movement", text: "Active user", evidence: "")
        let result = MemoryAgent.filteredContext(from: [record], destinedFor: "ingredient-substitution")
        #expect(result.isEmpty)
        #expect(!MemoryAgent.allowedPayloadKinds.contains("ingredient-substitution"))
    }

    // MARK: - Candidate-number binding

    @Test func bindDropsOutOfRangeNumbers() {
        let a = FoodSelectionCandidate(id: 1, foodItem: food(name: "Olive oil"))
        let b = FoodSelectionCandidate(id: 2, foodItem: food(name: "Margarine"))
        let bound = FoundationIngredientSubstitutionModel.bind(
            picks: [(candidateNumber: 2, reason: "close swap"), (candidateNumber: 99, reason: "nope"), (candidateNumber: 1, reason: nil)],
            candidates: [a, b]
        )
        #expect(bound.map(\.foodItem.name) == ["Margarine", "Olive oil"]) // 99 dropped, model order kept
        #expect(bound.first?.reason == "close swap")
        #expect(bound.last?.reason == nil)
    }

    @Test func bindDedupesAndCaps() {
        let candidates = (1...10).map { FoodSelectionCandidate(id: $0, foodItem: food(name: "Food \($0)")) }
        var picks: [(candidateNumber: Int, reason: String?)] = [(1, "a"), (1, "dup")]
        picks += (2...9).map { (candidateNumber: $0, reason: String?("r")) }
        let bound = FoundationIngredientSubstitutionModel.bind(picks: picks, candidates: candidates, limit: 6)
        #expect(bound.count == 6)
        #expect(Set(bound.map(\.foodItem.id)).count == 6) // no duplicate food
    }

    @Test func bindBlankReasonBecomesNil() {
        let a = FoodSelectionCandidate(id: 1, foodItem: food(name: "Oat milk"))
        let bound = FoundationIngredientSubstitutionModel.bind(picks: [(candidateNumber: 1, reason: "   ")], candidates: [a])
        #expect(bound.first?.reason == nil)
    }

    @Test func bindCapsOverlongReason() {
        let a = FoodSelectionCandidate(id: 1, foodItem: food(name: "Oat milk"))
        let long = String(repeating: "x", count: 500)
        let bound = FoundationIngredientSubstitutionModel.bind(picks: [(candidateNumber: 1, reason: long)], candidates: [a])
        #expect((bound.first?.reason?.count ?? 0) <= 120)
    }

    // MARK: - World-knowledge name rebinding (model names a food; code resolves it through the catalog)

    @Test func bindNamesResolvesModelNamesThroughCatalog() {
        // The model proposes butter substitutes BY NAME (world knowledge the catalog has no taxonomy for);
        // `resolve` stands in for FoodCatalog.candidates and CODE supplies the real food + its macros.
        let oliveOil = food(name: "Olive oil")
        let coconutOil = food(name: "Coconut oil")
        let table: [String: FoodItem] = ["olive oil": oliveOil, "coconut oil": coconutOil]
        let bound = FoundationIngredientSubstitutionModel.bindNames(
            picks: [(name: "olive oil", reason: "same fat role"), (name: "coconut oil", reason: nil)],
            resolve: { name in
                table[name.lowercased()].map { [FoodSelectionCandidate(id: 1, foodItem: $0)] } ?? []
            }
        )
        #expect(bound.map(\.foodItem.name) == ["Olive oil", "Coconut oil"]) // model order kept
        #expect(bound.first?.reason == "same fat role")
    }

    @Test func bindNamesDropsUnresolvableAndDedupesSameFood() {
        let oliveOil = food(name: "Olive oil")
        // "ghee" resolves to nothing (dropped); two different names that resolve to the SAME food dedupe.
        let table: [String: FoodItem] = ["olive oil": oliveOil, "extra virgin olive oil": oliveOil]
        let bound = FoundationIngredientSubstitutionModel.bindNames(
            picks: [
                (name: "ghee", reason: "nope"),
                (name: "olive oil", reason: "first"),
                (name: "extra virgin olive oil", reason: "dup food")
            ],
            resolve: { name in
                table[name.lowercased()].map { [FoodSelectionCandidate(id: 1, foodItem: $0)] } ?? []
            }
        )
        #expect(bound.map(\.foodItem.name) == ["Olive oil"]) // ghee dropped, duplicate food collapsed
        #expect(bound.first?.reason == "first")
    }

    @Test func bindNamesTakesFirstCatalogMatchOnly() {
        // resolve returns a ranked list; only the TOP match binds (code picks the food, not the model).
        let best = food(name: "Greek yogurt")
        let worse = food(name: "Yogurt drink")
        let bound = FoundationIngredientSubstitutionModel.bindNames(
            picks: [(name: "yogurt", reason: nil)],
            resolve: { _ in [FoodSelectionCandidate(id: 1, foodItem: best), FoodSelectionCandidate(id: 2, foodItem: worse)] }
        )
        #expect(bound.map(\.foodItem.name) == ["Greek yogurt"])
    }

    // MARK: - Deterministic fallback

    @Test func deterministicSuggestionsMapCandidatesInOrder() {
        let candidates = [
            FoodSelectionCandidate(id: 1, foodItem: food(name: "Greek yogurt")),
            FoodSelectionCandidate(id: 2, foodItem: food(name: "Silken tofu"))
        ]
        let suggestions = FoundationIngredientSubstitutionModel.deterministicSuggestions(candidates: candidates)
        #expect(suggestions.map(\.foodItem.name) == ["Greek yogurt", "Silken tofu"])
        #expect(suggestions.allSatisfy { $0.reason == nil })
    }

    // MARK: - Quantity via gram-equivalence (code, never the model)

    @Test func replacementQuantityGramMatchesByWeight() {
        let butter = food(name: "Butter", servingUnit: "g")
        let margarine = food(name: "Margarine", servingUnit: "g") // preferredRecipeUnit -> .gram
        let original = RecipeIngredient(foodItemId: butter.id, quantity: 50, unit: "g")
        let (qty, unit) = RecipeSubstitution.replacementQuantity(for: original, originalFoodItem: butter, substitute: margarine)
        #expect(unit == "g")
        #expect(abs(qty - 50) < 0.001) // 50 g butter -> 50 g margarine
    }

    @Test func replacementQuantityFallsBackWhenUnmappable() {
        let butter = food(name: "Butter", servingUnit: "g")
        // A serving-only substitute has no gram mapping -> fall back to its natural default, not a fake weight.
        let broth = food(name: "Broth", servingSize: 1, servingUnit: "serving")
        let original = RecipeIngredient(foodItemId: butter.id, quantity: 50, unit: "g")
        let (qty, unit) = RecipeSubstitution.replacementQuantity(for: original, originalFoodItem: butter, substitute: broth)
        #expect(unit == "serving")
        #expect(qty == 1) // defaultRecipeQuantity(for: .serving)
    }

    @Test func replacementQuantityFallsBackWhenOriginalUnresolved() {
        let margarine = food(name: "Margarine", servingUnit: "g")
        let original = RecipeIngredient(foodItemId: UUID(), quantity: 50, unit: "g")
        let (qty, unit) = RecipeSubstitution.replacementQuantity(for: original, originalFoodItem: nil, substitute: margarine)
        #expect(unit == "g")
        #expect(qty == margarine.defaultRecipeQuantity(for: .gram)) // 100 (serving grams), not a gram-match
    }

    @Test func substitutedIngredientBindsToSubstituteFood() {
        let butter = food(name: "Butter", servingUnit: "g", macros: Macros(protein: 1, carbs: 0, fat: 81))
        let margarine = food(name: "Margarine", servingUnit: "g", macros: Macros(protein: 0, carbs: 1, fat: 60))
        let original = RecipeIngredient(foodItemId: butter.id, quantity: 50, unit: "g")
        let replacement = RecipeSubstitution.substitutedIngredient(replacing: original, originalFoodItem: butter, with: margarine)
        #expect(replacement.foodItemId == margarine.id) // macros will recompute from THIS food, not carried over
        #expect(replacement.id != original.id)
        // Macros are derived from the bound food, never copied from the original ingredient.
        #expect(replacement.scaledMacros(using: margarine) != original.scaledMacros(using: butter))
    }

    // MARK: - Fork provenance + source immutability

    @Test func forkSetsProvenanceAndLeavesSourceUnchanged() {
        let butter = food(name: "Butter", servingUnit: "g")
        let flour = food(name: "Flour", servingUnit: "g")
        let margarine = food(name: "Margarine", servingUnit: "g")
        let butterIng = RecipeIngredient(foodItemId: butter.id, quantity: 50, unit: "g")
        let flourIng = RecipeIngredient(foodItemId: flour.id, quantity: 200, unit: "g")
        let source = recipe(ingredients: [butterIng, flourIng])
        let sourceSnapshot = source

        let newIng = RecipeSubstitution.substitutedIngredient(replacing: butterIng, originalFoodItem: butter, with: margarine)
        let fork = RecipeSubstitution.fork(source: source, replacing: butterIng.id, with: newIng, now: Date(timeIntervalSince1970: 2_000))

        let unwrapped = try! #require(fork)
        #expect(unwrapped.parentRecipeID == source.id)
        #expect(unwrapped.id != source.id)
        #expect(unwrapped.name == "Weeknight Pasta (adapted)")
        #expect(unwrapped.ingredients.count == 2)
        #expect(unwrapped.ingredients.contains { $0.foodItemId == margarine.id })
        #expect(!unwrapped.ingredients.contains { $0.foodItemId == butter.id })
        #expect(unwrapped.ingredients.contains { $0.foodItemId == flour.id }) // untouched ingredient preserved
        // Source recipe is byte-for-byte unchanged (never mutated).
        #expect(source == sourceSnapshot)
        #expect(source.parentRecipeID == nil)
    }

    @Test func forkReturnsNilForUnknownIngredient() {
        let source = recipe(ingredients: [RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "g")])
        let stray = RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "g")
        #expect(RecipeSubstitution.fork(source: source, replacing: UUID(), with: stray) == nil)
    }

    @Test func forkedNameDoesNotStackSuffix() {
        #expect(RecipeSubstitution.forkedName(from: "Chili") == "Chili (adapted)")
        #expect(RecipeSubstitution.forkedName(from: "Chili (adapted)") == "Chili (adapted)")
        #expect(RecipeSubstitution.forkedName(from: "  ") == "Recipe (adapted)")
    }

    // MARK: - Tolerant parentRecipeID decode round-trip

    @Test func parentRecipeIDRoundTripsWhenPresent() throws {
        let parent = UUID()
        let r = RecipeDefinition(name: "Fork", servings: 2, ingredients: [], source: "manual",
                                 createdAt: Date(timeIntervalSince1970: 3_000), updatedAt: Date(timeIntervalSince1970: 3_000),
                                 parentRecipeID: parent)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(RecipeDefinition.self, from: data)
        #expect(decoded.parentRecipeID == parent)
    }

    @Test func parentRecipeIDAbsentDecodesNil() throws {
        // A blob written before F4 (or re-encoded by an un-updated peer) has no parentRecipeID key.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Legacy","servings":1,"ingredients":[],"notes":"","source":"manual","createdAt":0,"updatedAt":0}
        """
        let decoded = try JSONDecoder().decode(RecipeDefinition.self, from: Data(json.utf8))
        #expect(decoded.parentRecipeID == nil)
    }

    @Test func unknownFutureKeyDoesNotBreakDecode() throws {
        // Mesh/blob tolerance: an older build must decode a recipe carrying a newer unknown key.
        let parent = UUID()
        let r = RecipeDefinition(name: "Fork", servings: 2, ingredients: [], source: "manual",
                                 createdAt: Date(timeIntervalSince1970: 4_000), updatedAt: Date(timeIntervalSince1970: 4_000),
                                 parentRecipeID: parent)
        let data = try JSONEncoder().encode(r)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict["someFutureField"] = ["nested": 7]
        let mutated = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(RecipeDefinition.self, from: mutated)
        #expect(decoded.parentRecipeID == parent)
        #expect(decoded.name == "Fork")
    }

    // MARK: - Mesh wire-compat (SharedRecipePayload never carries provenance)

    @Test func sharedRecipePayloadHasNoParentField() {
        let payload = SharedRecipePayload(name: "X", servings: 1, notes: "", ingredients: [])
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        #expect(!fields.contains("parentRecipeID"))
        #expect(fields.contains("version"))
    }

    @Test func forkSharesAsStandaloneRecipeMinusProvenance() throws {
        // An older peer receives the fork's ingredients fine and simply never learns it was derived.
        let margarine = food(name: "Margarine", servingUnit: "g")
        let ing = RecipeIngredient(foodItemId: margarine.id, quantity: 50, unit: "g")
        let fork = RecipeDefinition(name: "Sauce (adapted)", servings: 2, ingredients: [ing], source: "manual",
                                    createdAt: Date(), updatedAt: Date(), parentRecipeID: UUID())
        let wire = RecipeShareCodec.payload(for: fork, foodItems: [margarine])
        #expect(wire.name == "Sauce (adapted)")
        #expect(wire.ingredients.count == 1)
        #expect(wire.ingredients.first?.name == "Margarine")
        // Round-trips through the version-1 wire an older peer speaks.
        let data = try JSONEncoder().encode(wire)
        let back = try JSONDecoder().decode(SharedRecipePayload.self, from: data)
        #expect(back.version == 1)
        #expect(back.ingredients.count == 1)
    }
}

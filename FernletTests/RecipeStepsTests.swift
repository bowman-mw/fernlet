import Foundation
import Testing
import CoreData
import FernletDomainModel
import CloudKitSync
import AIProviders
import ProximityKit
import DiaryStore
@testable import Fernlet

/// F5 cooking-mode schema + wire tests (Docs/AI-Feature-Expansion-2026-07-23.md §6, decision §11.6):
/// the `RecipeStep` schema round-trips on both persistence paths, web-import steps survive ordered,
/// the mesh wire degrades gracefully to older peers, the manual editor path stores sanitized steps,
/// completion anchors to the start day-key, and the Cook action gates correctly.
@MainActor
struct RecipeStepsTests {

    // MARK: - Schema round-trip: synced blob (RecipeDefinition Codable)

    @Test func recipeStepsRoundTripThroughBlobCodable() throws {
        let recipe = makeSteppedRecipe()
        let data = try iso8601Encoder().encode(recipe)
        let decoded = try iso8601Decoder().decode(RecipeDefinition.self, from: data)
        #expect(decoded == recipe)
        #expect(decoded.steps?.count == 3)
        #expect(decoded.steps?[0].text == "Chop the onion")
        #expect(decoded.steps?[1].durationSeconds == 600)
        #expect(decoded.steps?[2].durationSeconds == nil)
    }

    @Test func recipeWithoutStepsDecodesStepsAsNil() throws {
        // A pre-F5 recipe JSON has no `steps` key — tolerant decode must yield nil, never a failure.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old Recipe","servings":2,"ingredients":[],
         "notes":"","source":"manual","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoded = try iso8601Decoder().decode(RecipeDefinition.self, from: Data(json.utf8))
        #expect(decoded.steps == nil)
    }

    @Test func recipeToleratesUnknownFutureKeyAlongsideSteps() throws {
        // Additive discipline: an unknown future key must be ignored, and steps still decode.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Future Recipe","servings":1,"ingredients":[],
         "notes":"","source":"manual","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
         "steps":[{"id":"\(UUID().uuidString)","text":"Stir"}],
         "someFutureFieldWeDoNotKnowYet":{"nested":true}}
        """
        let decoded = try iso8601Decoder().decode(RecipeDefinition.self, from: Data(json.utf8))
        #expect(decoded.steps?.count == 1)
        #expect(decoded.steps?.first?.text == "Stir")
    }

    // MARK: - Schema round-trip: per-row payloadData (SavedRecipeRecord, STEP 0)

    @Test func recipeStepsRoundTripThroughSavedRecipePayloadData() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = SavedRecipeRepository(
            controller: controller,
            legacyRepository: LegacySavedRecipeJSONRepository(fileURL: temporaryURL()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let recipe = makeSteppedRecipe()

        #expect(repository.upsert([recipe]))
        let reloaded = repository.load()

        // The payloadData path round-trips the whole RecipeDefinition per row, so steps survive intact —
        // the safe path (the legacy columns carry no steps, so the blob-strip landmine can't fire here).
        #expect(reloaded == [recipe])
        #expect(reloaded.first?.steps?.count == 3)
        #expect(reloaded.first?.steps?[1].durationSeconds == 600)
    }

    // MARK: - Web-import step preservation (ordered)

    @Test func webImportHowToStepArrayPreservesOrder() {
        let value: [Any] = [
            ["@type": "HowToStep", "text": "Preheat the oven"],
            ["@type": "HowToStep", "text": "Mix the batter"],
            ["@type": "HowToStep", "text": "Bake for 20 minutes"]
        ]
        let steps = RecipeWebImporter.orderedSteps(from: value)
        #expect(steps.map(\.text) == ["Preheat the oven", "Mix the batter", "Bake for 20 minutes"])
        #expect(steps.allSatisfy { $0.durationSeconds == nil })
    }

    @Test func webImportHowToSectionFlattensSectionBySectionInOrder() {
        let value: [Any] = [
            ["@type": "HowToSection", "name": "Prep", "itemListElement": [
                ["@type": "HowToStep", "text": "Dice vegetables"],
                ["@type": "HowToStep", "text": "Measure spices"]
            ]],
            ["@type": "HowToSection", "name": "Cook", "itemListElement": [
                ["@type": "HowToStep", "text": "Sauté aromatics"],
                ["@type": "HowToStep", "text": "Simmer"]
            ]]
        ]
        let steps = RecipeWebImporter.orderedSteps(from: value)
        // Sections flatten in order; the section NAME is never surfaced as a step.
        #expect(steps.map(\.text) == ["Dice vegetables", "Measure spices", "Sauté aromatics", "Simmer"])
    }

    @Test func webImportHowToSectionWithSingleObjectItemListFlattensNotSectionName() {
        // schema.org permits `itemListElement` to be a single object rather than an array. The section's
        // sub-step must still be surfaced, never the section NAME ("Prep").
        let value: [Any] = [
            ["@type": "HowToSection", "name": "Prep",
             "itemListElement": ["@type": "HowToStep", "text": "Dice vegetables"]]
        ]
        let steps = RecipeWebImporter.orderedSteps(from: value)
        #expect(steps.map(\.text) == ["Dice vegetables"])
    }

    @Test func webImportPlainStringArrayIsOneStepPerElement() {
        let value: [Any] = ["Boil water", "Add pasta", "Drain and serve"]
        let steps = RecipeWebImporter.orderedSteps(from: value)
        #expect(steps.map(\.text) == ["Boil water", "Add pasta", "Drain and serve"])
    }

    @Test func webImportSingleStringIsOneStep() {
        let steps = RecipeWebImporter.orderedSteps(from: "Combine everything and bake.")
        #expect(steps.map(\.text) == ["Combine everything and bake."])
    }

    @Test func webImportEmptyInstructionsYieldNoSteps() {
        #expect(RecipeWebImporter.orderedSteps(from: nil).isEmpty)
        #expect(RecipeWebImporter.orderedSteps(from: [Any]()).isEmpty)
    }

    // MARK: - Mesh wire-compat: old peer decodes minus steps (proof), new peer keeps them

    /// Mirror of the PRE-F5 `SharedRecipePayload` — deliberately has NO `steps` property. Decoding the
    /// new steps-carrying encoding into this proves an older peer tolerates the extra key.
    private struct OldSharedRecipePayload: Codable {
        var format = "fernlet.recipe"
        var version = 1
        var name: String
        var servings: Int
        var notes: String
        var ingredients: [SharedRecipeIngredient]
    }

    @Test func oldPeerDecodesNewStepsCarryingPayloadMinusSteps() throws {
        let payload = SharedRecipePayload(
            name: "Shared Bowl",
            servings: 2,
            notes: "Chill first.",
            ingredients: [SharedRecipeIngredient(name: "Oats", quantity: 80, unit: "g", protein: 10, carbs: 54, fat: 6)],
            steps: [RecipeStep(text: "Combine"), RecipeStep(text: "Rest 10 min", durationSeconds: 600)]
        )
        let data = try JSONEncoder().encode(payload)

        // The OLD decoder (no `steps` property) must still decode — ignoring the unknown key — and see v1.
        let old = try JSONDecoder().decode(OldSharedRecipePayload.self, from: data)
        #expect(old.version == 1)
        #expect(old.name == "Shared Bowl")
        #expect(old.ingredients.count == 1)

        // The NEW decoder keeps the steps.
        let new = try JSONDecoder().decode(SharedRecipePayload.self, from: data)
        #expect(new.steps?.count == 2)
        #expect(new.steps?[1].durationSeconds == 600)
    }

    /// Mirror of the PRE-F5 `SharedSavedRecipePayload` (no `steps`) for the web/saved proximity branch.
    private struct OldSharedSavedRecipePayload: Codable {
        var name: String
        var sourceURLString: String
        var ingredients: [String]
        var summary: String
        var servings: Int
        var protein: Int
        var carbs: Int
        var fat: Int
        var micronutrients: Micronutrients
    }

    @Test func oldPeerDecodesNewSavedPayloadMinusSteps() throws {
        let saved = SharedSavedRecipePayload(
            name: "Web Recipe",
            sourceURLString: "https://example.com/r",
            ingredients: ["Flour", "Sugar"],
            summary: "Tasty.",
            servings: 4,
            protein: 6, carbs: 40, fat: 10,
            micronutrients: Micronutrients(),
            steps: [RecipeStep(text: "Preheat"), RecipeStep(text: "Bake")]
        )
        let data = try JSONEncoder().encode(saved)
        let old = try JSONDecoder().decode(OldSharedSavedRecipePayload.self, from: data)
        #expect(old.name == "Web Recipe")
        #expect(old.ingredients == ["Flour", "Sugar"])
        let new = try JSONDecoder().decode(SharedSavedRecipePayload.self, from: data)
        #expect(new.steps?.count == 2)
    }

    @Test func decodePayloadStaysVersion1AndPreservesStepsForNewPeer() throws {
        let recipe = makeSteppedRecipe()
        let payload = RecipeShareCodec.payload(for: recipe, foodItems: [])
        // version pins at 1 so old peers accept it (decodePayload rejects any other version).
        #expect(payload.version == 1)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try RecipeShareCodec.decodePayload(from: json)
        #expect(decoded.version == 1)
        #expect(decoded.steps?.count == 3)
    }

    // MARK: - Import paths thread steps back into a RecipeDefinition

    @Test func importProximityLocalRecipePreservesSteps() throws {
        let fixture = makeLocalRecipeFixture()
        let store = makeTestStore()
        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)

        _ = try store.importProximityRecipeShare(payload)
        let imported = try #require(store.recipes.first)
        #expect(imported.steps?.map(\.text) == ["Mix", "Chill"])
    }

    @Test func importProximitySavedRecipePreservesSteps() throws {
        let store = makeTestStore()
        var recipe = makeWebRecipe()
        recipe.steps = [RecipeStep(text: "Preheat"), RecipeStep(text: "Bake 30 min", durationSeconds: 1800)]
        let payload = RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])

        _ = try store.importProximityRecipeShare(payload)
        let imported = try #require(store.savedRecipes.first)
        #expect(imported.steps?.count == 2)
        #expect(imported.steps?[1].durationSeconds == 1800)
    }

    @Test func importDropsBlankAndNonPositiveTimerSteps() throws {
        let store = makeTestStore()
        var recipe = makeWebRecipe()
        recipe.steps = [
            RecipeStep(text: "  ", durationSeconds: 60),        // blank text → dropped
            RecipeStep(text: "Real step", durationSeconds: 0),  // non-positive timer → nil
            RecipeStep(text: "  Trim me  ")
        ]
        let payload = RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])
        _ = try store.importProximityRecipeShare(payload)
        let imported = try #require(store.savedRecipes.first)
        #expect(imported.steps?.map(\.text) == ["Real step", "Trim me"])
        #expect(imported.steps?[0].durationSeconds == nil)
    }

    // MARK: - Manual editor path: add / reorder / delete via the store + sanitizer

    @Test func addRecipeStoresSanitizedSteps() {
        let store = makeTestStore()
        let steps = [
            RecipeStep(text: "First"),
            RecipeStep(text: "   "),                 // blank → dropped
            RecipeStep(text: "Second", durationSeconds: 300)
        ]
        let recipe = store.addRecipe(
            name: "Manual",
            servings: 1,
            notes: "",
            ingredients: [ManualRecipeIngredientInput(name: "Egg", quantity: 1, unit: "each", protein: 6, carbs: 0, fat: 5)],
            steps: steps
        )
        #expect(recipe.steps?.map(\.text) == ["First", "Second"])
        #expect(recipe.steps?[1].durationSeconds == 300)
    }

    @Test func updateRecipeReplacesSteps() {
        let store = makeTestStore()
        let recipe = store.addRecipe(
            name: "Manual",
            servings: 1,
            notes: "",
            ingredients: [ManualRecipeIngredientInput(name: "Egg", quantity: 1, unit: "each", protein: 6, carbs: 0, fat: 5)],
            steps: [RecipeStep(text: "One")]
        )
        // Simulate the editor's reorder+add: a fresh ordered list replaces the stored one.
        store.updateRecipe(
            recipe,
            name: "Manual",
            servings: 1,
            notes: "",
            ingredients: [ManualRecipeIngredientInput(name: "Egg", selectedFoodItemId: nil, quantity: 1, unit: "each", protein: 6, carbs: 0, fat: 5)],
            steps: [RecipeStep(text: "Two"), RecipeStep(text: "Three")]
        )
        let updated = store.recipes.first { $0.id == recipe.id }
        #expect(updated?.steps?.map(\.text) == ["Two", "Three"])
    }

    @Test func sanitizerYieldsNilWhenNothingSurvives() {
        #expect(RecipeStepSanitizer.sanitized(nil) == nil)
        #expect(RecipeStepSanitizer.sanitized([]) == nil)
        #expect(RecipeStepSanitizer.sanitized([RecipeStep(text: "   ")]) == nil)
    }

    // MARK: - Completion anchors the log to the day cooking STARTED

    @Test func loggingAnchorsToStartDayKeyNotToday() throws {
        // The completion leg passes the day-key captured at session start to logRecipe(date:). A session
        // that crosses midnight must log to the start day — proven by anchoring to a non-today key.
        let store = makeTestStore(date: Date(timeIntervalSince1970: 1_779_664_800))
        let today = store.todayKey
        let startDay = "2020-01-01"   // deliberately not today
        #expect(startDay != today)

        let recipe = store.addRecipe(
            name: "Overnight Stew",
            servings: 1,
            notes: "",
            ingredients: [ManualRecipeIngredientInput(name: "Beef", quantity: 100, unit: "g", protein: 26, carbs: 0, fat: 15)],
            steps: [RecipeStep(text: "Simmer", durationSeconds: 3600)]
        )
        _ = store.logRecipe(recipe, mealType: .dinner, date: startDay)

        #expect(store.day.meals.isEmpty)                                   // today got nothing
        #expect(store.diary.loadDay(for: startDay).meals.contains { $0.name == "Overnight Stew" })
    }

    // MARK: - Cook action gate

    @Test func cookActionGatesOnStepsOrIngredientsOrWebLines() {
        // Steps only.
        var stepsOnly = makeWebRecipe()
        stepsOnly.webImport = nil
        stepsOnly.steps = [RecipeStep(text: "Do it")]
        #expect(CookingModeAvailability.canCook(stepsOnly))

        // Structured ingredients only.
        let structured = makeLocalRecipeFixture().recipe
        #expect(CookingModeAvailability.canCook(structured))

        // Web free-text lines only.
        #expect(CookingModeAvailability.canCook(makeWebRecipe()))

        // Nothing to cook: no steps, no ingredients, no web lines.
        let bare = RecipeDefinition(
            name: "Empty",
            servings: 1,
            ingredients: [],
            notes: "just a note",
            source: MealLogSource.manual,
            createdAt: Date(),
            updatedAt: Date()
        )
        #expect(!CookingModeAvailability.canCook(bare))
    }

    // MARK: - Fixtures

    private func makeSteppedRecipe() -> RecipeDefinition {
        let at = Date(timeIntervalSince1970: 1_779_664_800)
        return RecipeDefinition(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000F5001")!,
            name: "Stepped Bowl",
            servings: 2,
            ingredients: [RecipeIngredient(foodItemId: UUID(), quantity: 100, unit: "g")],
            notes: "n",
            source: MealLogSource.manual,
            createdAt: at,
            updatedAt: at,
            steps: [
                RecipeStep(id: UUID(uuidString: "00000000-0000-0000-0000-0000000A5701")!, text: "Chop the onion"),
                RecipeStep(id: UUID(uuidString: "00000000-0000-0000-0000-0000000A5702")!, text: "Simmer", durationSeconds: 600),
                RecipeStep(id: UUID(uuidString: "00000000-0000-0000-0000-0000000A5703")!, text: "Serve")
            ]
        )
    }

    private func makeWebRecipe() -> RecipeDefinition {
        let at = Date(timeIntervalSince1970: 1_779_664_800)
        return RecipeDefinition(
            id: UUID(),
            name: "Web Bowl",
            servings: 3,
            ingredients: [],
            notes: "summary",
            source: MealLogSource.webImport,
            createdAt: at,
            updatedAt: at,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/web-bowl",
                ingredientLines: ["Oats", "Yogurt"],
                macros: Macros(protein: 20, carbs: 30, fat: 5),
                micronutrients: Micronutrients()
            )
        )
    }

    private func makeLocalRecipeFixture() -> (recipe: RecipeDefinition, foodItems: [FoodItem]) {
        let oats = FoodItem(
            name: "Rolled oats",
            brandSource: nil,
            servingSize: 40,
            servingUnit: "g",
            macros: Macros(protein: 5, carbs: 27, fat: 3),
            micronutrients: Micronutrients(),
            category: "test",
            source: .manual,
            tags: ["recipe"]
        )
        let at = Date(timeIntervalSince1970: 1_779_664_800)
        let recipe = RecipeDefinition(
            name: "Local Bowl",
            servings: 2,
            ingredients: [RecipeIngredient(foodItemId: oats.id, quantity: 80, unit: "g")],
            notes: "n",
            source: "manual",
            createdAt: at,
            updatedAt: at,
            steps: [RecipeStep(text: "Mix"), RecipeStep(text: "Chill")]
        )
        return (recipe, [oats])
    }

    private func iso8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeStepsTests-\(UUID().uuidString)")
            .appendingPathComponent("SavedRecipes.json")
    }
}

import Foundation
import Testing
import CoreData
import FernletDomainModel
import CloudKitSync
@testable import Fernlet

/// STEP 0 (Docs/AI-Feature-Expansion-2026-07-23.md §9.1): the additive `SavedRecipeRecord.payloadData`
/// migration. These guard the write-both / read-prefer-payload / legacy-fallback / staleness discipline
/// on the walled `CloudKitSync` module — structured ingredients and non-web-import provenance must now
/// round-trip, while an un-updated device's legacy-only rows and edits keep working indefinitely.
@MainActor
struct SavedRecipePayloadMigrationTests {

    // MARK: - Round-trip: structured ingredients + webImport == nil survive intact

    @Test func structuredRecipeWithoutWebImportRoundTripsThroughPayload() throws {
        let (repository, _) = makeRepository()
        let savedAt = Date(timeIntervalSince1970: 1_779_588_000)
        let updatedAt = savedAt.addingTimeInterval(3_600)
        let recipe = RecipeDefinition(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020A1")),
            name: "Structured Bowl",
            servings: 3,
            ingredients: [
                RecipeIngredient(foodItemId: UUID(), quantity: 150, unit: "g"),
                RecipeIngredient(foodItemId: UUID(), quantity: 2, unit: "cup")
            ],
            notes: "Combine and serve.",
            source: MealLogSource.manual,     // NOT webImport
            createdAt: savedAt,
            updatedAt: updatedAt,
            webImport: nil
        )

        #expect(repository.upsert([recipe]))
        let reloaded = repository.load()

        // Full equality: structured ingredients, real source, macros/servings/dates all intact — none of
        // which the legacy typed columns could represent (they hardcode ingredients:[] + source:webImport).
        #expect(reloaded == [recipe])
        let mapped = try #require(reloaded.first)
        #expect(mapped.ingredients.count == 2)
        #expect(mapped.source == MealLogSource.manual)
        #expect(mapped.webImport == nil)
        #expect(mapped.updatedAt == updatedAt)
    }

    // MARK: - Legacy row (payloadData nil) maps exactly as pre-STEP-0

    @Test func legacyRowWithoutPayloadMapsWithWebImportSemantics() throws {
        let (repository, controller) = makeRepository()
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020A2"))
        let savedAt = Date(timeIntervalSince1970: 1_779_588_000)

        // Simulate a row written by an un-updated device: only the legacy typed columns, no payloadData.
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "SavedRecipeRecord", into: context)
        record.setValue(id.uuidString, forKey: "idString")
        record.setValue("https://example.com/legacy", forKey: "sourceURLString")
        record.setValue("Legacy Only", forKey: "name")
        record.setValue("beans\ntomato", forKey: "ingredientsText")
        record.setValue("Old summary.", forKey: "summary")
        record.setValue(2, forKey: "servings")
        record.setValue(18, forKey: "protein")
        record.setValue(30, forKey: "carbs")
        record.setValue(7, forKey: "fat")
        record.setValue(savedAt, forKey: "savedAt")
        // payloadData intentionally left nil.
        try context.save()

        let mapped = try #require(repository.load().first)
        #expect(mapped.id == id)
        #expect(mapped.name == "Legacy Only")
        #expect(mapped.servings == 2)
        #expect(mapped.ingredients.isEmpty)                  // structured ingredients stay empty for legacy rows
        #expect(mapped.source == MealLogSource.webImport)    // legacy rows always map as web imports
        #expect(mapped.notes == "Old summary.")
        #expect(mapped.webImport?.ingredientLines == ["beans", "tomato"])
        #expect(mapped.webImport?.macros == Macros(protein: 18, carbs: 30, fat: 7))
        #expect(mapped.createdAt == savedAt)
    }

    // MARK: - Corrupt payloadData falls back to legacy columns without throwing

    @Test func corruptPayloadFallsBackToLegacyColumns() throws {
        let (repository, controller) = makeRepository()
        let recipe = makeWebImportRecipe(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020A3")))
        #expect(repository.upsert([recipe]))

        // Clobber the blob with non-JSON bytes, leaving the legacy columns intact.
        let record = try #require(try firstRecord(in: controller))
        record.setValue(Data([0x00, 0x01, 0x02, 0xFF, 0xFE]), forKey: "payloadData")
        try controller.container.viewContext.save()

        // Must not throw, and must return the legacy-column reconstruction (equal here since the source
        // recipe is itself a web import, so the legacy projection is lossless).
        let mapped = try #require(repository.load().first)
        #expect(mapped == recipe)
        #expect(mapped.source == MealLogSource.webImport)
    }

    // MARK: - Unknown extra key inside payloadData JSON is tolerated

    @Test func unknownKeyInsidePayloadIsTolerated() throws {
        let (repository, controller) = makeRepository()
        let recipe = makeStructuredRecipe(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020A4")))
        #expect(repository.upsert([recipe]))

        // Inject an unknown top-level key (and an unknown nested key inside the recipe) into the stored
        // blob — a future schema field an old build must ignore rather than fail on.
        let record = try #require(try firstRecord(in: controller))
        let blob = try #require(record.value(forKey: "payloadData") as? Data)
        var object = try #require(try JSONSerialization.jsonObject(with: blob) as? [String: Any])
        object["futureTopLevelField"] = ["nested": 42]
        if var recipeObject = object["recipe"] as? [String: Any] {
            recipeObject["futureRecipeField"] = "ignored"
            object["recipe"] = recipeObject
        }
        record.setValue(try JSONSerialization.data(withJSONObject: object), forKey: "payloadData")
        try controller.container.viewContext.save()

        // Decode still succeeds and the structured recipe survives intact.
        let mapped = try #require(repository.load().first)
        #expect(mapped == recipe)
        #expect(mapped.ingredients.count == recipe.ingredients.count)
    }

    // MARK: - Write-both: every legacy column is still fully populated after a save

    @Test func writeBothPopulatesEveryLegacyColumnAndTheBlob() throws {
        let (repository, controller) = makeRepository()
        let savedAt = Date(timeIntervalSince1970: 1_779_588_000)
        let recipe = RecipeDefinition(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020A5")),
            name: "Imported Chili",
            servings: 4,
            ingredients: [],
            notes: "Low and slow.",
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/chili",
                ingredientLines: ["beans", "tomato", "cumin"],
                macros: Macros(protein: 20, carbs: 44, fat: 9),
                micronutrients: Micronutrients(fiber: 11, iron: 4.2, potassium: 600)
            )
        )
        #expect(repository.upsert([recipe]))

        let record = try #require(try firstRecord(in: controller))
        // Legacy columns — assert each, exactly as pre-STEP-0.
        #expect(record.value(forKey: "idString") as? String == recipe.id.uuidString)
        #expect(record.value(forKey: "sourceURLString") as? String == "https://example.com/chili")
        #expect(record.value(forKey: "name") as? String == "Imported Chili")
        #expect(record.value(forKey: "ingredientsText") as? String == "beans\ntomato\ncumin")
        #expect(record.value(forKey: "summary") as? String == "Low and slow.")
        #expect((record.value(forKey: "servings") as? NSNumber)?.intValue == 4)
        #expect((record.value(forKey: "protein") as? NSNumber)?.intValue == 20)
        #expect((record.value(forKey: "carbs") as? NSNumber)?.intValue == 44)
        #expect((record.value(forKey: "fat") as? NSNumber)?.intValue == 9)
        let microsJSON = try #require(record.value(forKey: "micronutrientsJSON") as? String)
        let micros = try JSONDecoder().decode(Micronutrients.self, from: try #require(microsJSON.data(using: .utf8)))
        #expect(micros == Micronutrients(fiber: 11, iron: 4.2, potassium: 600))
        #expect(record.value(forKey: "savedAt") as? Date == savedAt)
        // And the additive blob is present alongside the legacy columns.
        #expect(record.value(forKey: "payloadData") as? Data != nil)
    }

    // MARK: - Staleness rule: legacy columns edited after the payload -> legacy wins

    @Test func legacyEditAfterPayloadWinsOverStaleBlob() throws {
        let (repository, controller) = makeRepository()
        let recipe = makeWebImportRecipe(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020A6")))
        #expect(repository.upsert([recipe]))

        // Simulate an un-updated device editing ONLY the legacy columns (it has no payloadData writer):
        // the name and ingredient lines change while the stale blob still holds the old values.
        let record = try #require(try firstRecord(in: controller))
        record.setValue("Edited By Old Device", forKey: "name")
        record.setValue("kale\nlentils", forKey: "ingredientsText")
        try controller.container.viewContext.save()

        // Divergence detected -> legacy columns win; we never resurrect the stale blob's old name/lines.
        let mapped = try #require(repository.load().first)
        #expect(mapped.name == "Edited By Old Device")
        #expect(mapped.webImport?.ingredientLines == ["kale", "lentils"])
        #expect(mapped.source == MealLogSource.webImport)
    }

    @Test func legacySavedAtChangeAloneIsDetectedAsDivergence() throws {
        let (repository, controller) = makeRepository()
        let recipe = makeWebImportRecipe(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020A7")))
        #expect(repository.upsert([recipe]))

        // A legacy write that changes ONLY savedAt still diverges from the blob (savedAt feeds createdAt,
        // which is part of RecipeDefinition equality) -> legacy wins. Guards the "savedAt is unreliable as
        // a lone freshness timestamp, so content divergence must cover it" reasoning in `recipe(from:)`.
        let record = try #require(try firstRecord(in: controller))
        let bumped = Date(timeIntervalSince1970: 1_800_000_000)
        record.setValue(bumped, forKey: "savedAt")
        try controller.container.viewContext.save()

        let mapped = try #require(repository.load().first)
        #expect(mapped.createdAt == bumped)      // the legacy savedAt won, not the blob's original createdAt
        #expect(mapped.source == MealLogSource.webImport)
    }

    @Test func unchangedLegacyColumnsKeepStructuredBlobAuthoritative() throws {
        let (repository, _) = makeRepository()
        // A structured recipe (no webImport) whose legacy columns were never independently edited: the
        // blob stays authoritative and the structured ingredients survive — the whole point of STEP 0.
        let recipe = makeStructuredRecipe(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020A8")))
        #expect(repository.upsert([recipe]))

        let mapped = try #require(repository.load().first)
        #expect(mapped == recipe)
        #expect(mapped.ingredients.count == recipe.ingredients.count)
    }

    // MARK: - Fractional-second dates (regression for the iso8601-vs-column precision false-positive)

    /// A structured recipe created with a real, fractional-second `Date()` (every runtime creation path
    /// does) must still round-trip its STRUCTURED payload. Before the precision-normalization fix, the
    /// full-precision `savedAt` column diverged from the blob's whole-second `createdAt` on every such
    /// recipe, so the staleness guard false-positived and returned the empty legacy web-import husk.
    @Test func structuredRecipeWithFractionalSecondDatesKeepsStructuredPayload() throws {
        let (repository, _) = makeRepository()
        let created = Date()                              // fractional sub-second component, like production
        #expect(created.timeIntervalSinceReferenceDate != created.timeIntervalSinceReferenceDate.rounded(.down))
        let recipe = RecipeDefinition(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020B1")),
            name: "Fractional Bowl",
            servings: 2,
            ingredients: [
                RecipeIngredient(foodItemId: UUID(), quantity: 100, unit: "g"),
                RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "cup")
            ],
            notes: "Real timestamp.",
            source: MealLogSource.manual,                  // NOT webImport
            createdAt: created,
            updatedAt: created,
            webImport: nil
        )
        #expect(repository.upsert([recipe]))

        let mapped = try #require(repository.load().first)
        // The blob won (no false divergence): structured ingredients + real source survive, not the husk.
        #expect(mapped.ingredients.count == 2)
        #expect(mapped.source == MealLogSource.manual)
        #expect(mapped.webImport == nil)
        // Dates read back at the blob's whole-second resolution (an accepted, now-consistent decision).
        #expect(mapped.createdAt == Date(timeIntervalSinceReferenceDate: created.timeIntervalSinceReferenceDate.rounded(.down)))
    }

    // MARK: - Update-in-place path (upsert over an existing row)

    /// Updating an existing row (upsert hits the fetched record, not a fresh insert) with a fractional
    /// `Date()` must also keep the blob authoritative — exercises the previously untested update branch
    /// of `apply` where the micronutrients-clearing fix lives.
    @Test func upsertOverExistingRowWithFractionalDatesKeepsBlobAuthoritative() throws {
        let (repository, controller) = makeRepository()
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020B2"))
        #expect(repository.upsert([makeWebImportRecipe(id: id)]))

        // Second upsert of the SAME id => update path. Now a structured recipe with a real timestamp.
        let created = Date()
        let updated = RecipeDefinition(
            id: id,
            name: "Now Structured",
            servings: 5,
            ingredients: [RecipeIngredient(foodItemId: UUID(), quantity: 250, unit: "g")],
            notes: "Converted to structured.",
            source: MealLogSource.manual,
            createdAt: created,
            updatedAt: created,
            webImport: nil
        )
        #expect(repository.upsert([updated]))

        // Exactly one row (updated in place, not duplicated).
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        #expect(try controller.container.viewContext.count(for: request) == 1)

        let mapped = try #require(repository.load().first)
        #expect(mapped.name == "Now Structured")
        #expect(mapped.ingredients.count == 1)
        #expect(mapped.source == MealLogSource.manual)
        #expect(mapped.webImport == nil)
    }

    /// The webImport -> nil transition on an UPDATE must clear the stale `micronutrientsJSON` column.
    /// Before the unconditional-write fix, the old micros survived, the legacy projection (empty micros)
    /// diverged from them, legacy won, and the user's structured edit was replaced by a chimera row.
    @Test func webImportToStructuredUpdateClearsStaleMicronutrients() throws {
        let (repository, controller) = makeRepository()
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020B3"))
        let savedAt = Date(timeIntervalSince1970: 1_779_588_000)   // whole-second: isolate the micros bug
        let webRecipe = RecipeDefinition(
            id: id, name: "Was Imported", servings: 2, ingredients: [], notes: "n",
            source: MealLogSource.webImport, createdAt: savedAt, updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/x", ingredientLines: ["a", "b"],
                macros: Macros(protein: 10, carbs: 20, fat: 5),
                micronutrients: Micronutrients(fiber: 9, iron: 3.3, potassium: 500)   // non-empty micros
            )
        )
        #expect(repository.upsert([webRecipe]))

        // Sanity: the column holds micros after the first write.
        let record = try #require(try firstRecord(in: controller))
        #expect(record.value(forKey: "micronutrientsJSON") as? String != nil)

        // Update the SAME row to structured (webImport == nil).
        let structured = RecipeDefinition(
            id: id, name: "Now Structured", servings: 3,
            ingredients: [RecipeIngredient(foodItemId: UUID(), quantity: 120, unit: "g")],
            notes: "edited", source: MealLogSource.manual, createdAt: savedAt, updatedAt: savedAt,
            webImport: nil
        )
        #expect(repository.upsert([structured]))

        // The stale micros column is cleared, so no false divergence: the structured blob wins.
        let updatedRecord = try #require(try firstRecord(in: controller))
        #expect(updatedRecord.value(forKey: "micronutrientsJSON") as? String == nil)
        let mapped = try #require(repository.load().first)
        #expect(mapped.name == "Now Structured")
        #expect(mapped.ingredients.count == 1)
        #expect(mapped.source == MealLogSource.manual)
        #expect(mapped.webImport == nil)
    }

    /// A legacy-only edit of the ONE conditionally-written column (`micronutrientsJSON`) must still be
    /// detected as divergence, so legacy wins. Guards that micronutrients participate in the content
    /// comparison (they feed `RecipeDefinition` equality via the webImport payload).
    @Test func legacyMicronutrientsEditAloneIsDetectedAsDivergence() throws {
        let (repository, controller) = makeRepository()
        let recipe = makeWebImportRecipe(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000020B4")))
        #expect(repository.upsert([recipe]))

        // An un-updated device rewrites ONLY the legacy micronutrients column; the blob is now stale.
        let record = try #require(try firstRecord(in: controller))
        let edited = Micronutrients(fiber: 99, iron: 42, potassium: 4000)
        let json = try #require(String(data: try JSONEncoder().encode(edited), encoding: .utf8))
        record.setValue(json, forKey: "micronutrientsJSON")
        try controller.container.viewContext.save()

        // Divergence -> legacy wins, carrying the edited micronutrients (not the blob's originals).
        let mapped = try #require(repository.load().first)
        #expect(mapped.webImport?.micronutrients == edited)
    }

    // MARK: - Helpers

    private func makeRepository() -> (SavedRecipeRepository, PersistenceController) {
        let controller = PersistenceController(inMemory: true)
        let repository = SavedRecipeRepository(
            controller: controller,
            legacyRepository: LegacySavedRecipeJSONRepository(fileURL: temporaryURL()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        return (repository, controller)
    }

    private func firstRecord(in controller: PersistenceController) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        return try controller.container.viewContext.fetch(request).first
    }

    private func makeWebImportRecipe(id: UUID) -> RecipeDefinition {
        let savedAt = Date(timeIntervalSince1970: 1_779_588_000)
        return RecipeDefinition(
            id: id,
            name: "Web Recipe",
            servings: 2,
            ingredients: [],
            notes: "Summary.",
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/web",
                ingredientLines: ["one", "two"],
                macros: Macros(protein: 12, carbs: 24, fat: 8),
                micronutrients: Micronutrients(fiber: 3, iron: 1.1)
            )
        )
    }

    private func makeStructuredRecipe(id: UUID) -> RecipeDefinition {
        let savedAt = Date(timeIntervalSince1970: 1_779_588_000)
        return RecipeDefinition(
            id: id,
            name: "Structured Recipe",
            servings: 4,
            ingredients: [
                RecipeIngredient(foodItemId: UUID(), quantity: 200, unit: "g"),
                RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "cup"),
                RecipeIngredient(foodItemId: UUID(), quantity: 3, unit: "tbsp")
            ],
            notes: "Mix.",
            source: MealLogSource.manual,
            createdAt: savedAt,
            updatedAt: savedAt.addingTimeInterval(120),
            webImport: nil
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedRecipePayloadMigrationTests-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }
}

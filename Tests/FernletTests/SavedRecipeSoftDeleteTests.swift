import Testing
import CoreData
import Foundation
@testable import CloudKitSync
import FernletDomainModel
import FernletFoundation

/// G9-1 soft delete for saved recipes (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md, Part 1,
/// S3 = A). Same contract as `CustomItemSoftDeleteTests`, on the `SavedRecipeRecord` entity with its
/// legacy typed columns: the tombstone row carries no recipe content in any column, a pre-G9 reader
/// (`SavedRecipeRepository.recipe(from:)`, unchanged) drops it, and the legacy-JSON migration cannot
/// bring a deleted recipe back.
@MainActor
@Suite(.serialized)
struct SavedRecipeSoftDeleteTests {
    private let stamp = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func deleteLeavesOnlyAContentFreeTombstone() throws {
        let (repo, controller) = try makeRepository()
        let doomed = makeRecipe(name: "Grandma's stew")
        let kept = makeRecipe(name: "Toast")
        #expect(repo.upsert([doomed, kept]))

        #expect(repo.delete(ids: [doomed.id]))

        #expect(repo.load().map(\.id) == [kept.id])
        let records = try allRecords(in: controller)
        #expect(records.count == 2)
        let tombstone = try #require(records.first {
            ($0.value(forKey: "idString") as? String) == RowTombstones.tombstoneIDString(for: doomed.id)
        })
        let payloadData = try #require(tombstone.value(forKey: "payloadData") as? Data)
        let payload = try RowPayloadCoders.makeDecoder().decode(RowTombstonePayload.self, from: payloadData)
        #expect(payload.id == doomed.id)
        #expect(payload.format == RowTombstonePayload.currentFormat)
        let keys = try #require(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]).keys
        #expect(Set(keys) == ["id", "deletedAt", "format"])
        for column in ["name", "sourceURLString", "ingredientsText", "summary", "micronutrientsJSON"] {
            #expect(tombstone.value(forKey: column) == nil, "legacy column \(column) must stay empty")
        }
        #expect(!records.contains { ($0.value(forKey: "idString") as? String) == doomed.id.uuidString })
    }

    @Test func liveRowFromAnotherPhoneIsHiddenAndHealed() throws {
        let (repo, controller) = try makeRepository()
        let recipe = makeRecipe(name: "Soup")
        #expect(repo.upsert([recipe]))
        #expect(repo.delete(ids: [recipe.id]))

        // Another phone edits the recipe before hearing of the delete; its plain-uuid row comes back.
        try insertLegacyRow(recipe, in: controller)
        #expect(try allRecords(in: controller).count == 2)

        #expect(repo.load().isEmpty)
        let ids = try allRecords(in: controller).compactMap { $0.value(forKey: "idString") as? String }
        #expect(ids == [RowTombstones.tombstoneIDString(for: recipe.id)])
    }

    @Test func upsertOfADeletedIDIsSkipped() throws {
        let (repo, controller) = try makeRepository()
        let recipe = makeRecipe(name: "Curry")
        let fresh = makeRecipe(name: "Salad")
        #expect(repo.upsert([recipe]))
        #expect(repo.delete(ids: [recipe.id]))

        #expect(repo.upsert([recipe, fresh]))
        #expect(repo.upsert([recipe]))

        #expect(repo.load().map(\.id) == [fresh.id])
        #expect(try allRecords(in: controller).count == 2)
    }

    @Test func deleteAllClearsTombstones() throws {
        let (repo, controller) = try makeRepository()
        let recipe = makeRecipe(name: "Pie")
        #expect(repo.upsert([recipe, makeRecipe(name: "Other")]))
        #expect(repo.delete(ids: [recipe.id]))

        #expect(repo.deleteAll())

        #expect(try allRecords(in: controller).isEmpty)
    }

    @Test func newerFormatTombstoneIsHonouredAndNeverRewritten() throws {
        let (repo, controller) = try makeRepository()
        let recipe = makeRecipe(name: "Future")
        let future = Data(#"{"deletedAt":"2026-11-15T00:00:00Z","format":7,"id":"\#(recipe.id.uuidString)","why":"x"}"#.utf8)
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "SavedRecipeRecord", into: context)
        record.setValue(RowTombstones.tombstoneIDString(for: recipe.id), forKey: "idString")
        record.setValue(future, forKey: "payloadData")
        record.setValue(stamp, forKey: "savedAt")
        try context.save()
        try insertLegacyRow(recipe, in: controller)

        #expect(repo.load().isEmpty)
        #expect(repo.upsert([recipe]))
        #expect(repo.delete(ids: [recipe.id]))

        let records = try allRecords(in: controller)
        #expect(records.count == 1)
        #expect(records.first?.value(forKey: "payloadData") as? Data == future)
    }

    @Test func oldShapeReaderDropsTheTombstoneRow() throws {
        let (repo, controller) = try makeRepository()
        let doomed = makeRecipe(name: "Gone")
        let kept = makeRecipe(name: "Here")
        #expect(repo.upsert([doomed, kept]))
        #expect(repo.delete(ids: [doomed.id]))

        // The pre-G9 row reader, run over every row with no tombstone filter, as an old build does.
        let records = try allRecords(in: controller)
        #expect(records.count == 2)
        let oldRead = records.compactMap(SavedRecipeRepository.recipe(from:))
        #expect(oldRead.map(\.id) == [kept.id])
    }

    @Test func legacyJSONMigrationCannotBringADeletedRecipeBack() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { _ = try? FileManager.default.removeItem(at: fileURL) }
        let legacy = LegacySavedRecipeJSONRepository(fileURL: fileURL)
        let recipe = makeRecipe(name: "Old file stew")
        #expect(legacy.save([recipe]))
        let (repo, controller) = try makeRepository(legacy: legacy)
        #expect(repo.delete(ids: [recipe.id]))      // tombstone only; the migration has not run yet

        #expect(repo.load().isEmpty)
        #expect(try allRecords(in: controller).count == 1)
    }

    // MARK: - Helpers

    private func makeRepository(
        legacy: LegacySavedRecipeJSONRepository? = nil
    ) throws -> (SavedRecipeRepository, PersistenceController) {
        let controller = PersistenceController(inMemory: true)
        return (try makeRepository(controller: controller, legacy: legacy), controller)
    }

    private func makeRepository(
        controller: PersistenceController,
        legacy: LegacySavedRecipeJSONRepository? = nil
    ) throws -> SavedRecipeRepository {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        return SavedRecipeRepository(
            controller: controller,
            legacyRepository: legacy ?? LegacySavedRecipeJSONRepository(fileURL: fileURL),
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
    }

    private func makeRecipe(name: String) -> RecipeDefinition {
        RecipeDefinition(
            name: name,
            servings: 2,
            ingredients: [],
            notes: "Notes for \(name).",
            source: MealLogSource.webImport,
            createdAt: stamp,
            updatedAt: stamp,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/\(UUID().uuidString)",
                ingredientLines: ["beans", "tomato"],
                macros: Macros(protein: 10, carbs: 20, fat: 5),
                micronutrients: Micronutrients()
            )
        )
    }

    /// A legacy-shape live row, as another (or an older) phone writes it.
    private func insertLegacyRow(_ recipe: RecipeDefinition, in controller: PersistenceController) throws {
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "SavedRecipeRecord", into: context)
        record.setValue(recipe.id.uuidString, forKey: "idString")
        record.setValue(recipe.name, forKey: "name")
        record.setValue("beans\ntomato", forKey: "ingredientsText")
        record.setValue(recipe.notes, forKey: "summary")
        record.setValue(recipe.createdAt, forKey: "savedAt")
        try context.save()
    }

    private func allRecords(in controller: PersistenceController) throws -> [NSManagedObject] {
        try controller.container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord"))
    }
}

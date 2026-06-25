import Foundation
import Testing
@testable import Fernlet

/// Guards the `SavedRecipe` → `RecipeDefinition` model merge: web-imported recipes saved by older
/// builds (legacy `SavedRecipes.json` + the `SavedRecipeRecord` Core Data entity) must migrate into
/// the canonical `RecipeDefinition` model without losing any field.
struct SavedRecipeMigrationTests {

    /// Faithfully reproduces an on-disk `SavedRecipes.json` written by a pre-merge build (the fixture
    /// mirrors the old `SavedRecipe` stored properties exactly, so the JSON keys + iso8601 dates are
    /// byte-equivalent to what the old app emitted) and asserts every field survives the migration.
    @Test func legacyOnDiskJSONMigratesToRecipeDefinitionWithoutLoss() throws {
        let micros = Micronutrients(fiber: 6, sugar: 12, calcium: 80, iron: 2.4, sodium: 350)
        let savedAt = Date(timeIntervalSince1970: 1_779_588_000)
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000001001"))
        let fixture = LegacySavedRecipeFixture(
            id: id,
            sourceURLString: "https://example.com/legacy-bowl",
            name: "Legacy Bowl",
            ingredients: ["1 cup rice", "200g chicken", "2 tbsp sauce"],
            summary: "Cook and combine.",
            servings: 3,
            protein: 38,
            carbs: 52,
            fat: 12,
            micronutrients: micros,
            savedAt: savedAt
        )
        let url = temporaryURL()
        try writeLegacyFile([fixture], to: url)

        let repository = LegacySavedRecipeJSONRepository(fileURL: url)
        let loaded = repository.load()
        let recipe = try #require(loaded.first)
        let webImport = try #require(recipe.webImport)

        #expect(loaded.count == 1)
        #expect(recipe.id == id)
        #expect(recipe.name == "Legacy Bowl")
        #expect(recipe.servings == 3)
        #expect(recipe.ingredients.isEmpty)                 // structured ingredients stay empty for imports
        #expect(recipe.notes == "Cook and combine.")        // summary → notes
        #expect(recipe.source == MealLogSource.webImport)
        #expect(recipe.createdAt == savedAt)                // savedAt → createdAt/updatedAt
        #expect(recipe.updatedAt == savedAt)
        #expect(recipe.isWebImport)
        #expect(webImport.sourceURLString == "https://example.com/legacy-bowl")
        #expect(webImport.sourceURL == URL(string: "https://example.com/legacy-bowl"))
        #expect(webImport.ingredientLines == ["1 cup rice", "200g chicken", "2 tbsp sauce"])
        #expect(webImport.macros == Macros(protein: 38, carbs: 52, fat: 12))
        #expect(webImport.micronutrients == micros)
    }

    /// A hand-authored legacy file missing the optional `micronutrients` key still migrates (the
    /// missing field defaults rather than dropping the recipe), proving the decode is defensive
    /// against the real range of legacy data on disk.
    @Test func legacyJSONWithoutMicronutrientsMigratesWithDefaults() throws {
        let json = """
        [
          {
            "id": "00000000-0000-0000-0000-000000001002",
            "sourceURLString": "https://example.com/no-micros",
            "name": "Sparse Recipe",
            "ingredients": ["water"],
            "summary": "",
            "servings": 1,
            "protein": 0,
            "carbs": 0,
            "fat": 0,
            "savedAt": "2026-05-23T10:00:00Z"
          }
        ]
        """
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(json.data(using: .utf8)).write(to: url)

        let recipe = try #require(LegacySavedRecipeJSONRepository(fileURL: url).load().first)

        #expect(recipe.name == "Sparse Recipe")
        #expect(recipe.isWebImport)
        #expect(recipe.webImport?.ingredientLines == ["water"])
        #expect(recipe.webImport?.macros == Macros(protein: 0, carbs: 0, fat: 0))
        #expect(recipe.webImport?.micronutrients == Micronutrients())
    }

    /// Saving a `RecipeDefinition` web-import through the Core Data repository and reloading it must
    /// be a lossless round trip — full `Equatable` equality across the legacy `SavedRecipeRecord`
    /// columns (id, url, free-text ingredients, summary, servings, macros, micronutrients, savedAt).
    @MainActor
    @Test func coreDataRoundTripPreservesWebImportRecipe() throws {
        let repository = SavedRecipeRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: LegacySavedRecipeJSONRepository(fileURL: temporaryURL()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let savedAt = Date(timeIntervalSince1970: 1_779_588_000)
        let recipe = RecipeDefinition(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000001003")),
            name: "Imported Stew",
            servings: 4,
            ingredients: [],
            notes: "Low and slow.",
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/stew",
                ingredientLines: ["beans", "tomato", "cumin"],
                macros: Macros(protein: 20, carbs: 44, fat: 9),
                micronutrients: Micronutrients(fiber: 11, iron: 4.2, potassium: 600)
            )
        )

        #expect(repository.save([recipe]))
        let reloaded = repository.load()

        #expect(reloaded == [recipe])
    }

    // MARK: - Legacy fixture

    /// Mirrors the pre-merge `SavedRecipe` stored properties exactly so the encoded JSON matches the
    /// schema an older build would have written to disk.
    private struct LegacySavedRecipeFixture: Encodable {
        var id: UUID
        var sourceURLString: String
        var name: String
        var ingredients: [String]
        var summary: String
        var servings: Int
        var protein: Int
        var carbs: Int
        var fat: Int
        var micronutrients: Micronutrients
        var savedAt: Date
    }

    private func writeLegacyFile(_ fixtures: [LegacySavedRecipeFixture], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(fixtures).write(to: url)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedRecipeMigrationTests-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }
}

import Foundation
import FernletFoundation
import CoreData
import FernletDomainModel
import FernletPersistence

// Web-imported recipes are now represented by the canonical `RecipeDefinition` model (carrying a
// `RecipeWebImport` payload). The legacy `SavedRecipe` struct has been removed; the repositories
// below load/save `RecipeDefinition`s while keeping the existing on-disk formats stable so that
// recipes saved by older builds migrate without loss.

/// Mirror of the legacy `SavedRecipe` JSON schema, used only to decode (and re-encode) the
/// pre-merge `SavedRecipes.json` file so older saved recipes survive the model merge. Maps
/// losslessly to/from `RecipeDefinition` via `webImport`.
nonisolated private struct LegacySavedRecipeDTO: Codable {
    var id: UUID?
    var sourceURLString: String?
    var name: String
    var ingredients: [String]?
    var summary: String?
    var servings: Int?
    var protein: Int?
    var carbs: Int?
    var fat: Int?
    var micronutrients: Micronutrients?
    var savedAt: Date?

    init(recipe: RecipeDefinition) {
        let webImport = recipe.webImport
        id = recipe.id
        sourceURLString = webImport?.sourceURLString ?? ""
        name = recipe.name
        ingredients = webImport?.ingredientLines ?? []
        summary = recipe.notes
        servings = recipe.servings
        protein = webImport?.macros.protein ?? 0
        carbs = webImport?.macros.carbs ?? 0
        fat = webImport?.macros.fat ?? 0
        micronutrients = webImport?.micronutrients ?? Micronutrients()
        savedAt = recipe.createdAt
    }

    func toRecipeDefinition() -> RecipeDefinition {
        SavedRecipeMapping.recipe(
            id: id ?? UUID(),
            sourceURLString: sourceURLString ?? "",
            name: name,
            ingredientLines: ingredients ?? [],
            summary: summary ?? "",
            servings: servings ?? 1,
            protein: protein ?? 0,
            carbs: carbs ?? 0,
            fat: fat ?? 0,
            micronutrients: micronutrients ?? Micronutrients(),
            savedAt: savedAt ?? Date()
        )
    }
}

/// Single source of truth for translating the legacy saved-recipe columns/fields (free-text
/// ingredients + precomputed nutrition + source URL) into a `RecipeDefinition` with a `webImport`
/// payload. Shared by the Core Data and legacy-JSON repositories so both migrate identically.
nonisolated enum SavedRecipeMapping {
    static func recipe(
        id: UUID,
        sourceURLString: String,
        name: String,
        ingredientLines: [String],
        summary: String,
        servings: Int,
        protein: Int,
        carbs: Int,
        fat: Int,
        micronutrients: Micronutrients,
        savedAt: Date
    ) -> RecipeDefinition {
        RecipeDefinition(
            id: id,
            name: name,
            servings: max(servings, 1),
            ingredients: [],
            notes: summary,
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: sourceURLString,
                ingredientLines: ingredientLines.filter { !$0.isEmpty },
                macros: Macros(
                    protein: max(protein, 0),
                    carbs: max(carbs, 0),
                    fat: max(fat, 0)
                ),
                micronutrients: micronutrients
            )
        )
    }
}

@MainActor
public struct SavedRecipeRepository {
    private let controller: PersistenceController
    private let legacyRepository: LegacySavedRecipeJSONRepository
    private let defaults: UserDefaults

    public init() {
        self.init(controller: .shared, legacyRepository: LegacySavedRecipeJSONRepository(), defaults: .standard)
    }

    public init(controller: PersistenceController, legacyRepository: LegacySavedRecipeJSONRepository, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.legacyRepository = legacyRepository
        self.defaults = defaults
    }

    private static let migrationCompletedKey = "com.fernlet.savedRecipeMigrationCompleted"

    public func load() -> [RecipeDefinition] {
        StartupTiming.timed("SavedRecipeRepository.load") {
            let recipes = loadCoreDataRecipes()
            if recipes.isEmpty && !defaults.bool(forKey: Self.migrationCompletedKey) {
                let migrated = legacyRepository.load()
                if !migrated.isEmpty {
                    _ = save(migrated)
                }
                defaults.set(true, forKey: Self.migrationCompletedKey)
                return migrated
            }
            return recipes
        }
    }

    public func loadAsync() async -> [RecipeDefinition] {
        StartupTiming.timed("SavedRecipeRepository.loadAsync") {
            let recipes = loadCoreDataRecipes()
            guard recipes.isEmpty && !defaults.bool(forKey: Self.migrationCompletedKey) else { return recipes }

            let signpostID = StartupTiming.begin("SavedRecipeRepository.legacyLoad.async")
            let migrated = legacyRepository.load()
            StartupTiming.end("SavedRecipeRepository.legacyLoad.async", signpostID: signpostID)
            if !migrated.isEmpty {
                _ = save(migrated)
            }
            defaults.set(true, forKey: Self.migrationCompletedKey)
            return migrated
        }
    }

    private func loadCoreDataRecipes() -> [RecipeDefinition] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "savedAt", ascending: false)]

        guard let records = try? context.fetch(request) else {
            assertionFailure("saved recipe fetch failed")
            return []
        }

        return records.compactMap(Self.recipe(from:))
    }

    @discardableResult public func save(_ recipes: [RecipeDefinition]) -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")

        do {
            let existing = try context.fetch(request)
            var existingByID: [String: NSManagedObject] = [:]
            for record in existing {
                if let idString = record.value(forKey: "idString") as? String {
                    existingByID[idString] = record
                }
            }
            let incomingIDs = Set(recipes.map { $0.id.uuidString })
            for (idString, record) in existingByID where !incomingIDs.contains(idString) {
                context.delete(record)
            }
            for recipe in recipes {
                let record = existingByID[recipe.id.uuidString]
                    ?? NSEntityDescription.insertNewObject(forEntityName: "SavedRecipeRecord", into: context)
                Self.apply(recipe, to: record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("saved recipe Core Data save failed")
            context.rollback()
            return false
        }
    }

    private static func recipe(from record: NSManagedObject) -> RecipeDefinition? {
        guard let idString = record.value(forKey: "idString") as? String,
              let id = UUID(uuidString: idString),
              let name = record.value(forKey: "name") as? String else {
            return nil
        }

        let ingredientsText = record.value(forKey: "ingredientsText") as? String ?? ""
        let micronutrients: Micronutrients
        if let json = record.value(forKey: "micronutrientsJSON") as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Micronutrients.self, from: data) {
            micronutrients = decoded
        } else {
            micronutrients = Micronutrients()
        }
        return SavedRecipeMapping.recipe(
            id: id,
            sourceURLString: record.value(forKey: "sourceURLString") as? String ?? "",
            name: name,
            ingredientLines: ingredientsText.components(separatedBy: "\n"),
            summary: record.value(forKey: "summary") as? String ?? "",
            servings: (record.value(forKey: "servings") as? NSNumber)?.intValue ?? 1,
            protein: (record.value(forKey: "protein") as? NSNumber)?.intValue ?? 0,
            carbs: (record.value(forKey: "carbs") as? NSNumber)?.intValue ?? 0,
            fat: (record.value(forKey: "fat") as? NSNumber)?.intValue ?? 0,
            micronutrients: micronutrients,
            savedAt: record.value(forKey: "savedAt") as? Date ?? Date.distantPast
        )
    }

    private static func apply(_ recipe: RecipeDefinition, to record: NSManagedObject) {
        let webImport = recipe.webImport
        record.setValue(recipe.id.uuidString, forKey: "idString")
        record.setValue(webImport?.sourceURLString ?? "", forKey: "sourceURLString")
        record.setValue(recipe.name, forKey: "name")
        record.setValue((webImport?.ingredientLines ?? []).joined(separator: "\n"), forKey: "ingredientsText")
        record.setValue(recipe.notes, forKey: "summary")
        record.setValue(recipe.servings, forKey: "servings")
        record.setValue(webImport?.macros.protein ?? 0, forKey: "protein")
        record.setValue(webImport?.macros.carbs ?? 0, forKey: "carbs")
        record.setValue(webImport?.macros.fat ?? 0, forKey: "fat")
        if let micros = webImport?.micronutrients,
           let data = try? JSONEncoder().encode(micros),
           let json = String(data: data, encoding: .utf8) {
            record.setValue(json, forKey: "micronutrientsJSON")
        }
        record.setValue(recipe.createdAt, forKey: "savedAt")
    }
}

extension SavedRecipeRepository: SavedRecipeRepositoring {}

nonisolated public struct LegacySavedRecipeJSONRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    public func load() -> [RecipeDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let recipes = try? decoder.decode([LegacySavedRecipeDTO].self, from: data) else {
            return []
        }
        return recipes.map { $0.toRecipeDefinition() }
    }

    @discardableResult public func save(_ recipes: [RecipeDefinition]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(recipes.map(LegacySavedRecipeDTO.init(recipe:)))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            assertionFailure("saved recipe write failed")
            return false
        }
    }

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (directory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Fernlet", isDirectory: true)
            .appendingPathComponent("SavedRecipes.json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

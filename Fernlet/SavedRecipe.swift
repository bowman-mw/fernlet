import Foundation
import CoreData

struct SavedRecipe: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var sourceURLString: String
    var name: String
    var ingredients: [String]
    var summary: String
    var servings: Int = 1
    var protein: Int = 0
    var carbs: Int = 0
    var fat: Int = 0
    var micronutrients: Micronutrients = Micronutrients()
    var savedAt: Date = Date()

    var sourceURL: URL {
        URL(string: sourceURLString) ?? URL(fileURLWithPath: "/")
    }

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        name: String,
        ingredients: [String],
        summary: String,
        servings: Int = 1,
        protein: Int = 0,
        carbs: Int = 0,
        fat: Int = 0,
        micronutrients: Micronutrients = Micronutrients(),
        savedAt: Date = Date()
    ) {
        self.id = id
        self.sourceURLString = sourceURL.absoluteString
        self.name = name
        self.ingredients = ingredients
        self.summary = summary
        self.servings = max(servings, 1)
        self.protein = max(protein, 0)
        self.carbs = max(carbs, 0)
        self.fat = max(fat, 0)
        self.micronutrients = micronutrients
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceURLString = try container.decode(String.self, forKey: .sourceURLString)
        name = try container.decode(String.self, forKey: .name)
        ingredients = try container.decodeIfPresent([String].self, forKey: .ingredients) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        servings = max(try container.decodeIfPresent(Int.self, forKey: .servings) ?? 1, 1)
        protein = max(try container.decodeIfPresent(Int.self, forKey: .protein) ?? 0, 0)
        carbs = max(try container.decodeIfPresent(Int.self, forKey: .carbs) ?? 0, 0)
        fat = max(try container.decodeIfPresent(Int.self, forKey: .fat) ?? 0, 0)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
    }
}

@MainActor
struct SavedRecipeRepository {
    private let controller: PersistenceController
    private let legacyRepository: LegacySavedRecipeJSONRepository
    private let defaults: UserDefaults

    init() {
        self.init(controller: .shared, legacyRepository: LegacySavedRecipeJSONRepository(), defaults: .standard)
    }

    init(controller: PersistenceController, legacyRepository: LegacySavedRecipeJSONRepository, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.legacyRepository = legacyRepository
        self.defaults = defaults
    }

    private static let migrationCompletedKey = "com.fernlet.savedRecipeMigrationCompleted"

    func load() -> [SavedRecipe] {
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

    func loadAsync() async -> [SavedRecipe] {
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

    private func loadCoreDataRecipes() -> [SavedRecipe] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "savedAt", ascending: false)]

        guard let records = try? context.fetch(request) else {
            assertionFailure("saved recipe fetch failed")
            return []
        }

        return records.compactMap(Self.recipe(from:))
    }

    @discardableResult func save(_ recipes: [SavedRecipe]) -> Bool {
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

    private static func recipe(from record: NSManagedObject) -> SavedRecipe? {
        guard let idString = record.value(forKey: "idString") as? String,
              let id = UUID(uuidString: idString),
              let sourceURLString = record.value(forKey: "sourceURLString") as? String,
              let sourceURL = URL(string: sourceURLString),
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
        return SavedRecipe(
            id: id,
            sourceURL: sourceURL,
            name: name,
            ingredients: ingredientsText.components(separatedBy: "\n").filter { !$0.isEmpty },
            summary: record.value(forKey: "summary") as? String ?? "",
            servings: (record.value(forKey: "servings") as? NSNumber)?.intValue ?? 1,
            protein: (record.value(forKey: "protein") as? NSNumber)?.intValue ?? 0,
            carbs: (record.value(forKey: "carbs") as? NSNumber)?.intValue ?? 0,
            fat: (record.value(forKey: "fat") as? NSNumber)?.intValue ?? 0,
            micronutrients: micronutrients,
            savedAt: record.value(forKey: "savedAt") as? Date ?? Date.distantPast
        )
    }

    private static func apply(_ recipe: SavedRecipe, to record: NSManagedObject) {
        record.setValue(recipe.id.uuidString, forKey: "idString")
        record.setValue(recipe.sourceURLString, forKey: "sourceURLString")
        record.setValue(recipe.name, forKey: "name")
        record.setValue(recipe.ingredients.joined(separator: "\n"), forKey: "ingredientsText")
        record.setValue(recipe.summary, forKey: "summary")
        record.setValue(recipe.servings, forKey: "servings")
        record.setValue(recipe.protein, forKey: "protein")
        record.setValue(recipe.carbs, forKey: "carbs")
        record.setValue(recipe.fat, forKey: "fat")
        if let data = try? JSONEncoder().encode(recipe.micronutrients),
           let json = String(data: data, encoding: .utf8) {
            record.setValue(json, forKey: "micronutrientsJSON")
        }
        record.setValue(recipe.savedAt, forKey: "savedAt")
    }
}

struct LegacySavedRecipeJSONRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    func load() -> [SavedRecipe] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let recipes = try? decoder.decode([SavedRecipe].self, from: data) else {
            return []
        }
        return recipes
    }

    @discardableResult func save(_ recipes: [SavedRecipe]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(recipes)
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

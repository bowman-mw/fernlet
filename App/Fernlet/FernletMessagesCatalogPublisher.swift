import FernletDomainModel
import FernletExchange
import FernletFoundation
import FoodCatalog
import Foundation

/// App-owned publisher for the extension's bounded picker catalog. It receives already-canonical
/// store values after a durable snapshot save; the extension never reaches back into a repository.
@MainActor
struct FernletMessagesCatalogPublisher {
    private let catalogStore: FernletMessagesCatalogFileStore?

    init(directory: URL? = nil) {
        if let directory {
            catalogStore = FernletMessagesCatalogFileStore(directory: directory)
        } else if let directory = FernletMessagesCatalogFileStore.productionDirectory() {
            catalogStore = FernletMessagesCatalogFileStore(directory: directory)
        } else {
            catalogStore = nil
        }
    }

    func publish(from store: FernletStore) -> Bool {
        guard let catalogStore else { return false }
        do {
            let catalog = try Self.catalog(from: store)
            try catalogStore.write(catalog)
            return true
        } catch {
            FernletAuditLog.log("messagesCatalog.publish.failed", context: ["errorType": "\(type(of: error))"])
            return false
        }
    }

    func clear() -> Bool {
        guard let catalogStore else { return false }
        return catalogStore.clear()
    }

    private static func catalog(from store: FernletStore) throws -> FernletMessagesCatalog {
        let recipes = try recipeEntries(from: store)
        let workouts = try workoutEntries(from: store)
        return try boundedCatalog(recipes: recipes, workouts: workouts)
    }

    private static func recipeEntries(from store: FernletStore) throws -> [FernletMessagesRecipeCatalogEntry] {
        var entries: [FernletMessagesRecipeCatalogEntry] = []
        var recipeIDs = Set<UUID>()
        try appendRecipes(store.recipes, from: store, into: &entries, recipeIDs: &recipeIDs)
        try appendRecipes(store.savedRecipes, from: store, into: &entries, recipeIDs: &recipeIDs)
        return entries
    }

    private static func appendRecipes(
        _ recipes: [RecipeDefinition],
        from store: FernletStore,
        into entries: inout [FernletMessagesRecipeCatalogEntry],
        recipeIDs: inout Set<UUID>
    ) throws {
        let remaining = FernletMessagesCatalogLimits.maxRecipes - entries.count
        guard remaining > 0 else { return }
        for recipe in recipes.prefix(remaining) {
            guard recipeIDs.insert(recipe.id).inserted else { continue }
            let foods = store.foodCatalog.items(forRecipe: recipe)
            let packet = try RecipeExchangePacket(recipe: recipe, foodItems: foods, includesNotes: false)
            entries.append(try FernletMessagesRecipeCatalogEntry(packet: packet))
        }
    }

    private static func workoutEntries(from store: FernletStore) throws -> [FernletMessagesWorkoutCatalogEntry] {
        let startDayKey = FernletDate.dayKey(for: Date())
        var entries: [FernletMessagesWorkoutCatalogEntry] = []
        for offset in 0..<FernletMessagesCatalogLimits.maxWorkoutDays {
            guard entries.count < FernletMessagesCatalogLimits.maxWorkouts,
                  let dayKey = FernletStore.dayKey(startingOn: startDayKey, offsetBy: offset) else { break }
            let remaining = FernletMessagesCatalogLimits.maxWorkouts - entries.count
            for workout in store.loadDay(for: dayKey).plannedWorkouts.prefix(remaining) {
                let plan = ExchangeWorkoutPlanBuilder.oneDayPlan(from: workout, dayKey: dayKey)
                let packet = try WorkoutPlanExchangePacket(plan: plan)
                entries.append(try FernletMessagesWorkoutCatalogEntry(dayKey: dayKey, packet: packet))
            }
        }
        return entries
    }

    private static func boundedCatalog(
        recipes: [FernletMessagesRecipeCatalogEntry],
        workouts: [FernletMessagesWorkoutCatalogEntry]
    ) throws -> FernletMessagesCatalog {
        var remainingRecipes = recipes
        var remainingWorkouts = workouts
        for _ in 0..<(FernletMessagesCatalogLimits.maxRecipes + FernletMessagesCatalogLimits.maxWorkouts) {
            let catalog = try FernletMessagesCatalog(recipes: remainingRecipes, workouts: remainingWorkouts)
            do {
                _ = try catalog.encodedData()
                return catalog
            } catch ExchangePacketError.tooLarge {
                if !remainingWorkouts.isEmpty {
                    remainingWorkouts.removeLast()
                } else if !remainingRecipes.isEmpty {
                    remainingRecipes.removeLast()
                } else {
                    throw ExchangePacketError.tooLarge
                }
            }
        }
        throw ExchangePacketError.tooLarge
    }
}

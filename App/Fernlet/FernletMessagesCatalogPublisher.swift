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

    /// Publishes every recipe and plan the exchange rules accept, and leaves out — rather than
    /// failing on — any single one they refuse.
    ///
    /// Only a successful publish rewrites the catalog, and the catalog is the extension's whole view
    /// of the library. Until 2026-09-23 one refused item (a web-imported recipe with more than 24
    /// servings — the importers accept up to 100 — or a plan named past the 120-character card
    /// bound) threw out of the whole publish, so the extension kept a stale catalog, recipes since
    /// deleted included, or had none at all. The skips are counted into the audit log; they carry
    /// no content.
    func publish(from store: FernletStore) -> Bool {
        guard let catalogStore else { return false }
        do {
            let recipes = Self.recipeEntries(from: store)
            let workouts = Self.workoutEntries(from: store)
            let skipped = recipes.skipped + workouts.skipped
            if skipped > 0 {
                FernletAuditLog.log("messagesCatalog.publish.skippedUnshareable", context: ["count": "\(skipped)"])
            }
            try catalogStore.write(Self.boundedCatalog(recipes: recipes.entries, workouts: workouts.entries))
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

    private static func recipeEntries(from store: FernletStore) -> (entries: [FernletMessagesRecipeCatalogEntry], skipped: Int) {
        var entries: [FernletMessagesRecipeCatalogEntry] = []
        var recipeIDs = Set<UUID>()
        var skipped = 0
        skipped += appendRecipes(store.recipes, from: store, into: &entries, recipeIDs: &recipeIDs)
        skipped += appendRecipes(store.savedRecipes, from: store, into: &entries, recipeIDs: &recipeIDs)
        return (entries, skipped)
    }

    /// Appends each shareable recipe until the catalog's recipe cap, and returns how many it had to
    /// leave out. Bounded by `recipes.count`, and stops at the cap.
    private static func appendRecipes(
        _ recipes: [RecipeDefinition],
        from store: FernletStore,
        into entries: inout [FernletMessagesRecipeCatalogEntry],
        recipeIDs: inout Set<UUID>
    ) -> Int {
        var skipped = 0
        for recipe in recipes {
            guard entries.count < FernletMessagesCatalogLimits.maxRecipes else { break }
            guard recipeIDs.insert(recipe.id).inserted else { continue }
            do {
                let foods = store.foodCatalog.items(forRecipe: recipe)
                let packet = try RecipeExchangePacket(recipe: recipe, foodItems: foods, includesNotes: true)
                entries.append(try FernletMessagesRecipeCatalogEntry(packet: packet))
            } catch {
                skipped += 1
            }
        }
        return skipped
    }

    private static func workoutEntries(from store: FernletStore) -> (entries: [FernletMessagesWorkoutCatalogEntry], skipped: Int) {
        let startDayKey = FernletDate.dayKey(for: Date())
        var entries: [FernletMessagesWorkoutCatalogEntry] = []
        var skipped = 0
        for offset in 0..<FernletMessagesCatalogLimits.maxWorkoutDays {
            guard entries.count < FernletMessagesCatalogLimits.maxWorkouts,
                  let dayKey = FernletStore.dayKey(startingOn: startDayKey, offsetBy: offset) else { break }
            for workout in store.loadDay(for: dayKey).plannedWorkouts {
                guard entries.count < FernletMessagesCatalogLimits.maxWorkouts else { break }
                do {
                    let plan = ExchangeWorkoutPlanBuilder.oneDayPlan(from: workout, dayKey: dayKey)
                    let packet = try WorkoutPlanExchangePacket(plan: plan)
                    entries.append(try FernletMessagesWorkoutCatalogEntry(dayKey: dayKey, packet: packet))
                } catch {
                    skipped += 1
                }
            }
        }
        return (entries, skipped)
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

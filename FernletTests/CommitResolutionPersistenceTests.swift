import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import CloudKitSync
@testable import Fernlet

/// Regression test for WI-10 (Docs/Security-Hardening-Plan-2026-06-27.md): `commitResolution` inserted
/// `createdRecipes` via a raw `diary.recipes.insert` with no snapshot save, relying on a following
/// `appendMeal` to persist. A resolution with created recipes but NO meals therefore lost the recipes on
/// the next reload. The fix schedules a save when recipes are created, independent of meals.
@MainActor
struct CommitResolutionPersistenceTests {

    @Test func commitResolutionPersistsCreatedRecipesEvenWithNoMeals() throws {
        let (store, repository, _) = makeTestStoreWithRepositories()

        let recipe = RecipeDefinition(
            name: "Test Bowl",
            servings: 1,
            ingredients: [],
            notes: "",
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )
        // A resolution that created a recipe but produced NO meals (the leak scenario).
        let resolution = MealResolution(meals: [], createdRecipes: [recipe], confidence: .high, isFallback: false)

        store.commitResolution(resolution)
        // Force the debounced save to write now. flushPending() is a no-op unless a save was scheduled —
        // so this assertion fails without the fix (no save scheduled → recipe never reaches the blob).
        store.flushPendingSnapshotSave()

        let persisted = repository.loadSnapshot(todayKey: store.todayKey).recipes
        #expect(persisted.contains { $0.id == recipe.id })
    }
}

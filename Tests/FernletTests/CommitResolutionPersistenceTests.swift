import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
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

    /// Day-rollover regression: `DiaryStore.todayKey` was pinned at construction and never advanced, so a
    /// process resident across local midnight filed a meal logged after 00:00 under YESTERDAY's key — it
    /// showed during the session but vanished from Today after the next cold launch re-keyed. The fix
    /// (`refreshCurrentDayIfNeeded`) re-keys the store in place: it flushes the outgoing day under its own
    /// key, then advances "today" so subsequent default-date logs land on the new day and survive a reload.
    /// The `now:` seam makes the rollover deterministic (the interactive commit path's internal auto-rollover
    /// uses the real clock, so it's exercised implicitly here — its filing goes through the same seam).
    @Test func rolloverFilesPostMidnightMealOnNewDayAndPreservesOutgoingDay() {
        let cal = Calendar(identifier: .gregorian)
        // Two adjacent local days, midday on each (far from any day boundary → unambiguous day keys).
        let day1Date = DateComponents(calendar: cal, year: 2026, month: 5, day: 19, hour: 12).date!
        let day2Date = DateComponents(calendar: cal, year: 2026, month: 5, day: 20, hour: 12).date!
        let day1Key = FernletDate.dayKey(for: day1Date)
        let day2Key = FernletDate.dayKey(for: day2Date)

        let (store, repository, _) = makeTestStoreWithRepositories(date: day1Date)
        #expect(store.todayKey == day1Key)

        // A meal logged on the launch day. Leave its debounced save PENDING (don't flush) so the rollover's
        // own flush is what must preserve it.
        // `MealParser.mealName` title-cases the description, so compare case-insensitively — this test
        // asserts WHICH meal lands on WHICH day, not the name formatting.
        store.addMeal(from: "oatmeal", type: .breakfast)
        #expect(store.day.meals.map { $0.name.lowercased() } == ["oatmeal"])

        // App stays resident; local midnight passes; foreground fires the rollover.
        #expect(store.refreshCurrentDayIfNeeded(now: day2Date))
        #expect(store.todayKey == day2Key)
        #expect(store.day.date == day2Key)
        #expect(store.day.meals.isEmpty)   // the new day starts empty

        // The rollover flushed yesterday under its own key, so it's already durable — and intact.
        #expect(repository.loadSnapshot(todayKey: day1Key).day.meals.map { $0.name.lowercased() } == ["oatmeal"])

        // A default-date meal logged after midnight now files on the NEW day, not yesterday.
        store.addMeal(from: "midnight snack", type: .snack)
        #expect(store.day.meals.map { $0.name.lowercased() } == ["midnight snack"])

        // Persist the new day, then load each day fresh from the repository (what a cold launch does):
        // the post-midnight meal survives on day 2, and day 1 still holds the breakfast.
        store.flushPendingSnapshotSave()
        #expect(repository.loadSnapshot(todayKey: day2Key).day.meals.map { $0.name.lowercased() } == ["midnight snack"])
        #expect(repository.loadSnapshot(todayKey: day1Key).day.meals.map { $0.name.lowercased() } == ["oatmeal"])

        // Idempotent: a second call on the same day is a no-op.
        #expect(store.refreshCurrentDayIfNeeded(now: day2Date) == false)
    }
}

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Store- and intent-level coverage for the cooking-run flow that backs the interactive Live Activity
/// + Siri navigation: starting a run (steps mapped + day-key anchored + mirrored to the app group),
/// advancing to a finish, the App-Intent transitions applied to the shared app-group state, the
/// resume-after-kill adoption, discard, and abandoned-run retirement.
///
/// Serialized: each test stands up real `FernletStore`s / the process-wide app-group cooking file, so
/// running in parallel would race that file. Each test clears it first (and after). Mirrors
/// GuidedWorkoutRunStoreTests exactly. Note: two `makeTestStore()` instances use SEPARATE in-memory
/// Core Data stacks, so a "relaunch" store shares the app-group run file but NOT the recipe book —
/// recipe-book resolution is asserted on the store that added the recipe.
@MainActor
@Suite(.serialized)
struct CookingRunStoreTests {

    private func clearSharedRun() {
        CookingRunStateStore().clear()
    }

    /// A manual recipe with three steps (one timed), added to the store's recipe book so `startCookingRun`
    /// and `recipeForActiveCookingRun` can resolve it.
    @discardableResult
    private func addSteppedRecipe(_ store: FernletStore, name: String = "Ragù") -> RecipeDefinition {
        store.addRecipe(
            name: name,
            servings: 2,
            notes: "",
            ingredients: [ManualRecipeIngredientInput(name: "Onion", quantity: 1, unit: "each", protein: 1, carbs: 9, fat: 0)],
            steps: [
                RecipeStep(text: "Chop the onion"),
                RecipeStep(text: "Simmer", durationSeconds: 600),
                RecipeStep(text: "Serve")
            ]
        )
    }

    // MARK: Start — mirrors + anchors the day key

    @Test func startCookingRunMapsStepsAndAnchorsTheStartDay() throws {
        clearSharedRun()
        defer { clearSharedRun() }
        let store = makeTestStore()
        let recipe = addSteppedRecipe(store)

        store.startCookingRun(recipe, startDayKey: "2026-07-20")
        let run = try #require(store.cookingRunState)
        #expect(run.recipeID == recipe.id)
        #expect(run.recipeName == "Ragù")
        #expect(run.startedDayKey == "2026-07-20")   // anchor survives, independent of "today"
        #expect(run.steps.count == 3)
        #expect(run.steps[1].durationSeconds == 600)
        #expect(run.stepIndex == 0)
        #expect(run.isFinished == false)
        #expect(store.recipeForActiveCookingRun()?.id == recipe.id)
        #expect(store.activeCookingRunIsSavedRecipe() == false)   // a manual recipe → logRecipe path

        // A stepless recipe never starts a run (the mise-only flow). Built directly — `addRecipe`
        // asserts ≥1 ingredient, which the stepless cooking gate does not require.
        clearSharedRun()
        let bare = RecipeDefinition(
            name: "Toast", servings: 1, ingredients: [], notes: "",
            source: MealLogSource.manual, createdAt: Date(), updatedAt: Date(), steps: nil
        )
        #expect(store.startCookingRun(bare) == nil)
    }

    // MARK: Advance → finish (file cleared, no resume)

    @Test func advancingToTheLastStepFinishesAndClearsTheFile() {
        clearSharedRun()
        defer { clearSharedRun() }
        let store = makeTestStore()
        let recipe = addSteppedRecipe(store)
        store.startCookingRun(recipe, startDayKey: store.todayKey)

        store.cookingAdvanceStep()   // → step 2 (index 1)
        store.cookingAdvanceStep()   // → step 3 (index 2, last)
        #expect(store.cookingRunState?.isFinished == false)
        store.cookingAdvanceStep()   // Next on the last step finishes
        #expect(store.cookingRunState?.isFinished == true)

        // A finished run clears the app-group file, so a fresh store's reconcile surfaces NO resume card.
        let relaunched = makeTestStore()
        relaunched.reconcileCookingRunFromAppGroup()
        #expect(relaunched.cookingRunState == nil)
    }

    // MARK: Resume after kill — a recent run is adopted at its saved step, day key preserved

    @Test func aRecentRunIsAdoptedByAFreshStoreAtItsSavedStep() throws {
        clearSharedRun()
        defer { clearSharedRun() }
        let store = makeTestStore()
        let recipe = addSteppedRecipe(store)
        store.startCookingRun(recipe, startDayKey: "2026-07-20")
        store.cookingAdvanceStep()   // now on step 2 (index 1)
        store.cookingStartTimer()    // "Simmer" — a running timer window mirrored to the group

        // Simulate a relaunch: a fresh store reconciles the surviving app-group run (the run file is
        // process-wide; only the recipe book differs between the two in-memory stores).
        let relaunched = makeTestStore()
        relaunched.reconcileCookingRunFromAppGroup()

        let run = try #require(relaunched.cookingRunState)
        #expect(run.recipeID == recipe.id)
        #expect(run.stepIndex == 1)                  // resumes exactly where it was left
        #expect(run.startedDayKey == "2026-07-20")   // day key preserved across the kill/resume
        #expect(run.hasRunningTimer == true)

        // The store that owns the recipe book can resolve the resume target from the run.
        #expect(store.recipeForActiveCookingRun()?.id == recipe.id)
    }

    // MARK: Discard clears state + no duplicate resume

    @Test func discardClearsTheRunAndNothingResumes() {
        clearSharedRun()
        defer { clearSharedRun() }
        let store = makeTestStore()
        let recipe = addSteppedRecipe(store)
        store.startCookingRun(recipe, startDayKey: store.todayKey)
        store.cookingAdvanceStep()

        store.endCookingRun()
        #expect(store.cookingRunState == nil)

        let relaunched = makeTestStore()
        relaunched.reconcileCookingRunFromAppGroup()
        #expect(relaunched.cookingRunState == nil)   // discarded → no resume card
    }

    // MARK: App-Intent transitions applied to the shared app-group state (Live Activity / Siri)

    @Test func nextIntentAdvancesTheSharedRunAndRepeatReFiresTheTimer() async throws {
        clearSharedRun()
        defer { clearSharedRun() }
        let shared = CookingRunStateStore()

        // Seed the shared file at the timed step, as if the Live Activity / Siri is about to act on it.
        let seed = CookingRunState(
            recipeID: UUID(),
            recipeName: "Ragù",
            startedDayKey: "2026-07-20",
            steps: [
                CookingRunState.Step(text: "Chop", durationSeconds: nil),
                CookingRunState.Step(text: "Simmer", durationSeconds: 600),
                CookingRunState.Step(text: "Serve", durationSeconds: nil)
            ],
            stepIndex: 1
        )
        shared.write(seed)

        // "Repeat step" re-fires the current step's timer without moving the cursor.
        await CookingIntentRunner.repeatStep()
        var reloaded = try #require(shared.read())
        #expect(reloaded.stepIndex == 1)
        #expect(reloaded.hasRunningTimer == true)

        // "Next" advances the cursor (and clears the timer).
        await CookingIntentRunner.advance()
        reloaded = try #require(shared.read())
        #expect(reloaded.stepIndex == 2)
        #expect(reloaded.hasRunningTimer == false)

        // "Next" on the last step finishes.
        await CookingIntentRunner.advance()
        reloaded = try #require(shared.read())
        #expect(reloaded.isFinished == true)
    }

    // MARK: Abandoned-run retirement

    @Test func aStaleRunIsRetiredOnReconcile() throws {
        clearSharedRun()
        defer { clearSharedRun() }
        // The store's `write()` re-stamps `updatedAt` (so a live run can be aged), so a genuinely stale
        // file must be written DIRECTLY at the same app-group path FernletStore reconciles from.
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.MBO.Fernlet")
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("FernletWidgets", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("CookingRunState.json")

        var stale = CookingRunState(
            recipeID: UUID(), recipeName: "Old", startedDayKey: "2026-07-01",
            steps: [CookingRunState.Step(text: "Stir")], stepIndex: 0
        )
        stale.updatedAt = Date().addingTimeInterval(-(CookingRunState.abandonedAfter + 3600))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stale).write(to: fileURL, options: .atomic)

        // Sanity: it's a valid, readable file — just old.
        #expect(CookingRunStateStore().read() != nil)

        let store = makeTestStore()
        store.reconcileCookingRunFromAppGroup()
        #expect(store.cookingRunState == nil)              // aged out → retired
        #expect(CookingRunStateStore().read() == nil)      // file cleared
    }
}

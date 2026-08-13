import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Store- and intent-level coverage for the cooking-run flow that backs the interactive Live Activity
/// + Siri navigation: starting a run (steps mapped + day-key anchored + mirrored to the app group),
/// advancing to a finish, the App-Intent transitions applied to the shared app-group state, the
/// resume-after-kill adoption, discard, and abandoned-run retirement.
///
/// Serialized: the tests within this suite mutate one cooking file in sequence. That file is redirected
/// to a per-test temp directory (`cookingDir`), so — unlike the earlier shape that hit the process-wide
/// real app-group file — a *different* suite running concurrently (e.g. a `deleteAllData` cooking wipe)
/// cannot race it. Each test still clears it first (and after). Note: two `makeStore()` instances use
/// SEPARATE in-memory Core Data stacks but the SAME per-test cooking file, so a "relaunch" store shares
/// the run file but NOT the recipe book — recipe-book resolution is asserted on the store that added it.
@MainActor
@Suite(.serialized)
struct CookingRunStoreTests {

    /// Per-test app-group cooking file, redirected to a unique temp dir so a PARALLEL suite (e.g. an
    /// `AIAuditLogTests.deleteAllData…` run, which wipes the real cooking file) can't race the file this
    /// suite reads. A fresh struct instance per test → a fresh directory per test. The store under test,
    /// the direct `CookingRunStateStore`, and the App-Intent runner are ALL pointed here.
    private let cookingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CookingRunTests-\(UUID().uuidString)", isDirectory: true)

    private func makeStore() -> FernletStore {
        makeTestStore(appGroupDirectory: cookingDir)
    }

    private func clearSharedRun() {
        CookingRunStateStore(directory: cookingDir).clear()
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
        let store = makeStore()
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
        let store = makeStore()
        let recipe = addSteppedRecipe(store)
        store.startCookingRun(recipe, startDayKey: store.todayKey)

        store.cookingAdvanceStep()   // → step 2 (index 1)
        store.cookingAdvanceStep()   // → step 3 (index 2, last)
        #expect(store.cookingRunState?.isFinished == false)
        store.cookingAdvanceStep()   // Next on the last step finishes
        #expect(store.cookingRunState?.isFinished == true)

        // A finished run clears the app-group file, so a fresh store's reconcile surfaces NO resume card.
        let relaunched = makeStore()
        relaunched.reconcileCookingRunFromAppGroup()
        #expect(relaunched.cookingRunState == nil)
    }

    // MARK: A Live-Activity / Siri Finish leaves the file finished — reconcile ADOPTS it (finish screen)

    /// When the cook taps "Finish" on the Live Activity (or says "next step" on the last step), the intent
    /// KEEPS the file marked `finished` (it can't retire it — only the app can). A subsequent reconcile
    /// must ADOPT that finished state (not nil it) so the foregrounded walker flips to its finish/log
    /// screen instead of dismissing — and so the run's authoritative `startedDayKey` survives for the log.
    /// The file is still retired (clear-BEFORE), and the resume card stays gated off (`!isFinished`).
    @Test func aFinishedRunLeftInTheFileIsAdoptedSoTheWalkerCanReachItsFinishScreen() throws {
        clearSharedRun()
        defer { clearSharedRun() }
        let shared = CookingRunStateStore(directory: cookingDir)

        // The state the intent leaves behind: advanced past the last step, file KEPT marked finished.
        let finished = CookingRunState(
            recipeID: UUID(),
            recipeName: "Ragù",
            startedDayKey: "2026-07-20",
            steps: [CookingRunState.Step(text: "Serve")],
            stepIndex: 0,
            finished: true
        )
        shared.write(finished)

        let store = makeStore()
        store.reconcileCookingRunFromAppGroup()

        let run = try #require(store.cookingRunState)   // adopted, NOT dropped
        #expect(run.isFinished == true)
        #expect(run.startedDayKey == "2026-07-20")      // day-key anchor preserved for a post-midnight log
        #expect(shared.read() == nil)                   // file retired (clear-BEFORE invariant)
    }

    // MARK: Resume after kill — a recent run is adopted at its saved step, day key preserved

    @Test func aRecentRunIsAdoptedByAFreshStoreAtItsSavedStep() throws {
        clearSharedRun()
        defer { clearSharedRun() }
        let store = makeStore()
        let recipe = addSteppedRecipe(store)
        store.startCookingRun(recipe, startDayKey: "2026-07-20")
        store.cookingAdvanceStep()   // now on step 2 (index 1)
        store.cookingStartTimer()    // "Simmer" — a running timer window mirrored to the group

        // Simulate a relaunch: a fresh store reconciles the surviving app-group run (the run file is
        // process-wide; only the recipe book differs between the two in-memory stores).
        let relaunched = makeStore()
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
        let store = makeStore()
        let recipe = addSteppedRecipe(store)
        store.startCookingRun(recipe, startDayKey: store.todayKey)
        store.cookingAdvanceStep()

        store.endCookingRun()
        #expect(store.cookingRunState == nil)

        let relaunched = makeStore()
        relaunched.reconcileCookingRunFromAppGroup()
        #expect(relaunched.cookingRunState == nil)   // discarded → no resume card
    }

    // MARK: App-Intent transitions applied to the shared app-group state (Live Activity / Siri)

    @Test func nextIntentAdvancesTheSharedRunAndRepeatReFiresTheTimer() async throws {
        clearSharedRun()
        defer { clearSharedRun() }
        let shared = CookingRunStateStore(directory: cookingDir)

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
        await CookingIntentRunner.repeatStep(directory: cookingDir)
        var reloaded = try #require(shared.read())
        #expect(reloaded.stepIndex == 1)
        #expect(reloaded.hasRunningTimer == true)

        // "Next" advances the cursor (and clears the timer).
        await CookingIntentRunner.advance(directory: cookingDir)
        reloaded = try #require(shared.read())
        #expect(reloaded.stepIndex == 2)
        #expect(reloaded.hasRunningTimer == false)

        // "Next" on the last step finishes.
        await CookingIntentRunner.advance(directory: cookingDir)
        reloaded = try #require(shared.read())
        #expect(reloaded.isFinished == true)
    }

    // MARK: Abandoned-run retirement

    @Test func aStaleRunIsRetiredOnReconcile() throws {
        clearSharedRun()
        defer { clearSharedRun() }
        // The store's `write()` re-stamps `updatedAt` (so a live run can be aged), so a genuinely stale
        // file must be written DIRECTLY at the same (per-test) path FernletStore reconciles from. When a
        // directory is injected, `CookingRunStateStore` puts the file at `<dir>/CookingRunState.json`.
        try FileManager.default.createDirectory(at: cookingDir, withIntermediateDirectories: true)
        let fileURL = cookingDir.appendingPathComponent("CookingRunState.json")

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
        #expect(CookingRunStateStore(directory: cookingDir).read() != nil)

        let store = makeStore()
        store.reconcileCookingRunFromAppGroup()
        #expect(store.cookingRunState == nil)              // aged out → retired
        #expect(CookingRunStateStore(directory: cookingDir).read() == nil)      // file cleared
    }
}

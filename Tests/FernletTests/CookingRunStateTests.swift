import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// F5 cooking-mode Live Activity / Siri / resume tests (Docs/AI-Feature-Expansion-2026-07-23.md §6.1/§6.4).
/// The cooking run is the exact analogue of GuidedWorkoutRunState: a flat app-group value the Live
/// Activity "Next" button and the "next step" / "repeat step" App Intents advance, and the app
/// reconciles on foreground / launch. These cover the pure state machine, the injectable-directory
/// store round-trip, and the Live Activity content mapping — none of which touch the process-wide
/// app-group file, so this suite is parallel-safe (it uses only injected temp directories + values).
struct CookingRunStateTests {

    private func step(_ text: String, _ duration: Int? = nil) -> CookingRunState.Step {
        CookingRunState.Step(text: text, durationSeconds: duration)
    }

    private func makeRun(stepIndex: Int = 0) -> CookingRunState {
        CookingRunState(
            recipeID: UUID(uuidString: "00000000-0000-0000-0000-0000000C0001")!,
            recipeName: "Weeknight ragù",
            startedDayKey: "2026-07-20",
            startedAt: Date(timeIntervalSince1970: 1_779_664_800),
            steps: [step("Chop the onion"), step("Simmer", 600), step("Serve")],
            stepIndex: stepIndex,
            // Whole-second timestamp so a codable round-trip through ISO-8601 (no fractional seconds)
            // compares equal.
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )
    }

    // MARK: - Injectable-directory store round-trip (mirrors GuidedWorkoutRunStateStore tests)

    @Test func storeRoundTripsThroughInjectedDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CookingRunStateStore(directory: dir)
        #expect(store.read() == nil)   // nothing written yet

        var run = makeRun(stepIndex: 1)
        run.startTimer(now: Date(timeIntervalSince1970: 1_779_664_900))
        store.write(run)

        let loaded = try #require(store.read())
        #expect(loaded.recipeID == run.recipeID)
        #expect(loaded.recipeName == "Weeknight ragù")
        #expect(loaded.startedDayKey == "2026-07-20")
        #expect(loaded.stepIndex == 1)
        #expect(loaded.stepCount == 3)
        #expect(loaded.currentStepText == "Simmer")
        #expect(loaded.timerStartedAt != nil)
        #expect(loaded.timerEndsAt != nil)
        #expect(loaded.isFinished == false)
    }

    @Test func storeClearRemovesTheRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CookingRunStateStore(directory: dir)
        store.write(makeRun())
        #expect(store.read() != nil)
        store.clear()
        #expect(store.read() == nil)
    }

    @Test func storeStampsUpdatedAtOnWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CookingRunStateStore(directory: dir)
        var run = makeRun()
        run.updatedAt = Date(timeIntervalSince1970: 0)   // deliberately stale
        store.write(run)
        let loaded = try #require(store.read())
        // The store stamps a fresh updatedAt so reconcile can age-out abandoned runs — never the caller's.
        #expect(loaded.updatedAt.timeIntervalSince1970 > 1)
    }

    // MARK: - Codable round-trip (byte-portable, ISO-8601 dates)

    @Test func codableRoundTripPreservesEveryField() throws {
        var run = makeRun(stepIndex: 2)
        run.startTimer(now: Date(timeIntervalSince1970: 1_779_664_900))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CookingRunState.self, from: encoder.encode(run))
        #expect(decoded == run)
    }

    // MARK: - Pure state machine (mirror the in-app walker + the intent transitions)

    @Test func advanceMovesTheCursorThenFinishesOnTheLastStep() {
        var run = makeRun(stepIndex: 0)
        #expect(run.stepNumber == 1)
        #expect(run.isLastStep == false)

        run.advance()
        #expect(run.stepIndex == 1)
        #expect(run.currentStepText == "Simmer")
        #expect(run.isFinished == false)

        run.advance()
        #expect(run.stepIndex == 2)
        #expect(run.isLastStep == true)
        #expect(run.isFinished == false)

        // Next on the last step ENDS the cook (the terminal the Live Activity reads to end the activity).
        run.advance()
        #expect(run.isFinished == true)
    }

    @Test func advanceClearsAnyRunningTimer() {
        var run = makeRun(stepIndex: 0)
        run.stepIndex = 1                       // the timed "Simmer" step
        run.startTimer(now: Date())
        #expect(run.hasRunningTimer == true)
        run.advance()
        #expect(run.timerStartedAt == nil)
        #expect(run.timerEndsAt == nil)
    }

    @Test func goBackStepsBackAndClampsAtZero() {
        var run = makeRun(stepIndex: 1)
        run.goBack()
        #expect(run.stepIndex == 0)
        run.goBack()                            // already at the first step — clamps, never negative
        #expect(run.stepIndex == 0)
    }

    @Test func startTimerHonorsTheStepDurationAndRepeatReFires() {
        var run = makeRun(stepIndex: 1)         // "Simmer", 600s
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        run.startTimer(now: t0)
        #expect(run.timerStartedAt == t0)
        #expect(run.timerEndsAt == t0.addingTimeInterval(600))

        // "Repeat step" re-fires the SAME step's timer from a later instant — new window, same cursor.
        let t1 = Date(timeIntervalSince1970: 1_000_120)
        run.startTimer(now: t1)
        #expect(run.stepIndex == 1)
        #expect(run.timerStartedAt == t1)
        #expect(run.timerEndsAt == t1.addingTimeInterval(600))
    }

    @Test func startTimerOnAStepWithoutADurationIsANoOpWindow() {
        var run = makeRun(stepIndex: 0)         // "Chop the onion" — no duration
        run.startTimer(now: Date())
        #expect(run.hasRunningTimer == false)
        #expect(run.timerStartedAt == nil)
    }

    // MARK: - Live Activity content mapping

    @Test func contentStateCarriesCursorTimerAndLastStepFlag() {
        var run = makeRun(stepIndex: 1)
        run.startTimer(now: Date(timeIntervalSince1970: 1_000_000))
        let content = run.contentState
        #expect(content.stepText == "Simmer")
        #expect(content.stepNumber == 2)
        #expect(content.stepCount == 3)
        #expect(content.isLastStep == false)
        #expect(content.timerStartedAt != nil)
        #expect(content.timerEndsAt != nil)

        run.advance()                            // → last step, timer cleared
        let last = run.contentState
        #expect(last.isLastStep == true)
        #expect(last.timerStartedAt == nil)
    }
}

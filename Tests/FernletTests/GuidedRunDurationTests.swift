import Foundation
import HealthKit
import Testing
import FernletDomainModel
import HealthKitGateway
@testable import Fernlet

/// A guided session logs how long it took (comparison report, idea 14): the run carries its own
/// start and finish, the logged row keeps the minutes where a hand-logged workout keeps them, a run
/// left open overnight is capped at three hours with a note, a run resumed after a relaunch still
/// counts from its first start, and the Apple Health copy is a strength workout spanning the session.
///
/// Serialized for the reason `GuidedWorkoutRunStoreTests` gives: each store test stands up a real
/// `FernletStore`, which reaches process-global state (the Live Activity registries, the exercise
/// catalog, `NotificationCenter.default`) that the per-test app-group directory does not cover.
@MainActor
@Suite(.serialized)
struct GuidedRunDurationTests {

    /// This test's app-group root, shared by every store one test makes (the relaunch fixture).
    private let appGroupDirectory = uniqueAppGroupDirectory()

    private func makeStore(healthKitService: (any HealthKitServicing)? = nil) -> FernletStore {
        makeTestStore(appGroupDirectory: appGroupDirectory, healthKitService: healthKitService)
    }

    private func session(_ name: String, sets: Int) -> WorkoutProgram.SessionSuggestion {
        let exercises = [PrescribedExercise(name: "Bench Press", sets: sets, reps: "5", role: .main, fromCatalog: true)]
        return WorkoutProgram.SessionSuggestion(
            title: name, timeLabel: "", kind: .strength, exercises: exercises,
            suggestion: WorkoutSuggestion(name: name, exercises: exercises.map(\.line).joined(separator: "\n"), notes: "")
        )
    }

    /// Commits today's plan with `s` as its only session (the generated one is weekday dependent).
    private func commitPlan(_ store: FernletStore, _ s: WorkoutProgram.SessionSuggestion) {
        let base = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let plan = WorkoutProgram.DayPlan(splitName: "Test", dayTitle: "Day", sessions: [s], droppedSlots: [], locationName: "Test")
        store.replaceGuidedWorkoutPlan(plan, replacing: Set(base.sessions.map(\.id)))
    }

    /// Starts `s` and moves the run's start `minutes` into the past, as if the session began then.
    @discardableResult
    private func startRun(_ store: FernletStore, _ s: WorkoutProgram.SessionSuggestion, minutesAgo minutes: Double) -> Date {
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)
        let start = Date().addingTimeInterval(-minutes * 60)
        store.editGuidedRun { $0.startedAt = start }
        return start
    }

    private func loggedRow(_ store: FernletStore, named name: String) -> Workout? {
        store.day.workouts.first { $0.name == name && $0.loggedFromGuidedSession == true }
    }

    // MARK: - The arithmetic

    @Test func theDurationIsStartToFinishInWholeMinutesLikeTheLogSheet() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let shortOfHalf = try #require(GuidedRunDuration.minutes(startedAt: start, finishedAt: start.addingTimeInterval(47 * 60 + 29)))
        #expect(shortOfHalf.minutes == 47)
        #expect(shortOfHalf.capped == false)
        #expect(GuidedRunDuration.minutes(startedAt: start, finishedAt: start.addingTimeInterval(47 * 60 + 31))?.minutes == 48)
        // A tap-through still logs a minute: a zero-length Health workout records nothing.
        #expect(GuidedRunDuration.minutes(startedAt: start, finishedAt: start.addingTimeInterval(12))?.minutes == 1)
        #expect(GuidedRunDuration.minutes(startedAt: start, finishedAt: start)?.minutes == 1)
    }

    @Test func missingOrBackwardTimestampsLogNoDuration() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(GuidedRunDuration.minutes(startedAt: nil, finishedAt: start)?.minutes == nil)   // a run from an older build
        #expect(GuidedRunDuration.minutes(startedAt: start, finishedAt: nil)?.minutes == nil)
        #expect(GuidedRunDuration.minutes(startedAt: start, finishedAt: start.addingTimeInterval(-60))?.minutes == nil)
    }

    @Test func theCapIsThreeHoursAndOnlyALongerRunIsCapped() throws {
        // `cappedNote` says "3 hours" in words; this pins the figure it names.
        #expect(GuidedRunDuration.capMinutes == 180)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let threeHours = try #require(GuidedRunDuration.minutes(startedAt: start, finishedAt: start.addingTimeInterval(180 * 60 + 29)))
        #expect(threeHours.minutes == 180)
        #expect(threeHours.capped == false)
        let overnight = try #require(GuidedRunDuration.minutes(startedAt: start, finishedAt: start.addingTimeInterval(11 * 3600)))
        #expect(overnight.minutes == 180)
        #expect(overnight.capped == true)
    }

    @Test func theCapNoteFollowsThePlanNotesOnlyWhenCapped() {
        let note = GuidedRunDuration.cappedNote
        #expect(!note.isEmpty)
        #expect(GuidedRunDuration.notes("Fitted to 30 min", capped: false) == "Fitted to 30 min")
        #expect(GuidedRunDuration.notes("", capped: true) == note)
        #expect(GuidedRunDuration.notes("Fitted to 30 min", capped: true) == "Fitted to 30 min\n\n" + note)
    }

    // MARK: - The run state stamps its own finish

    @Test func theFinishingTransitionStampsTheFinishAndAnAbandonDoesNot() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lift = GuidedWorkoutRunState.Exercise(name: "Bench Press", sets: 1, reps: "5", roleRaw: "main",
                                                  fromCatalog: true, restSeconds: 90)
        var run = GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: WorkoutIntensity.moderate.rawValue,
            title: "Push", suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: [lift], setStartedAt: start
        )
        var abandoned = run
        let tap = start.addingTimeInterval(40 * 60)
        run.markSetDone(now: tap)
        #expect(run.isFinishedNaturally)
        #expect(run.finishedAt == tap)

        abandoned.end()
        #expect(abandoned.finishedAt == nil)

        // Skipping the cool-down finishes (and logs) the run, stamped the same way.
        let coolDown = GuidedWorkoutRunState.Exercise(name: "Child's pose", sets: 1, reps: "30 s", roleRaw: "accessory",
                                                      fromCatalog: true, restSeconds: 0, holdSeconds: 30,
                                                      blockRaw: GuidedWorkoutRunState.BlockToken.coolDown)
        var cooling = GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: WorkoutIntensity.moderate.rawValue,
            title: "Push", suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: [coolDown], setStartedAt: start
        )
        cooling.skipBlock(now: tap)
        #expect(cooling.isFinishedNaturally)
        #expect(cooling.finishedAt == tap)
    }

    // MARK: - The logged row

    @Test func startingARunStampsItsStart() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Push", sets: 3)
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)
        let run = try #require(store.guidedRunState)
        #expect(run.startedAt != nil)
        #expect(run.startedAt == run.setStartedAt)
        #expect(run.finishedAt == nil)
        store.clearGuidedRun()
    }

    @Test func aGuidedFinishLogsTheSessionsDurationAndEndsAtTheFinish() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Timed", sets: 1)
        startRun(store, s, minutesAgo: 42)

        store.guidedMarkSetDone()   // 1 set, 1 exercise → finish → log

        let run = try #require(store.guidedRunState)
        let row = try #require(loggedRow(store, named: "Timed"))
        #expect(row.duration == 42)
        #expect(row.completedAt == run.finishedAt)
        #expect(row.notes.isEmpty, "an uncapped run adds no note")
        store.clearGuidedRun()
    }

    @Test func aRunLeftOpenOvernightLogsThreeHoursWithANote() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Overnight", sets: 1)
        startRun(store, s, minutesAgo: 11 * 60)

        store.guidedMarkSetDone()

        let row = try #require(loggedRow(store, named: "Overnight"))
        #expect(row.duration == GuidedRunDuration.capMinutes)
        #expect(row.notes.hasSuffix(GuidedRunDuration.cappedNote))
        store.clearGuidedRun()
    }

    /// The app relaunches mid-run: a fresh store adopts the run from the app group and finishes it.
    /// The duration still counts from the first start, not from the relaunch.
    @Test func aRunResumedAfterARelaunchCountsFromItsFirstStart() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Resumed", sets: 2)
        let start = startRun(store, s, minutesAgo: 35)
        store.guidedMarkSetDone()   // set 1 done → resting before set 2

        let relaunched = makeStore()
        relaunched.reconcileGuidedRunFromAppGroup()
        let adopted = try #require(relaunched.guidedRunState)
        let adoptedStart = try #require(adopted.startedAt)
        // The file stores whole seconds, so the adopted start is within a second of the original.
        #expect(abs(adoptedStart.timeIntervalSince(start)) < 1)

        relaunched.guidedSkipRest()
        relaunched.guidedMarkSetDone()   // set 2, the last → finish → log in the relaunched store

        let row = try #require(loggedRow(relaunched, named: "Resumed"))
        #expect(row.duration == 35)
        relaunched.clearGuidedRun()
    }

    /// Finished from the Lock Screen while the app was away, logged at the next reconcile: the row
    /// ends at the tap, and its length is the session's, not the time until the app came back.
    @Test func aLockScreenFinishLoggedLaterEndsAtTheTap() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let now = Date()
        let tap = max(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-20 * 60))
        let lift = GuidedWorkoutRunState.Exercise(name: "Bench Press", sets: 1, reps: "5", roleRaw: "main",
                                                  fromCatalog: true, restSeconds: 90)
        var finished = GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: store.todayKey, intensityRaw: WorkoutIntensity.moderate.rawValue,
            title: "Lock Screen", suggestionExercisesText: "Bench Press - 1 x 5", suggestionNotes: "",
            sessionKindRaw: "strength", exercises: [lift], setStartedAt: tap
        )
        finished.startedAt = tap.addingTimeInterval(-50 * 60)
        finished.markSetDone(now: tap)
        #expect(GuidedWorkoutRunStateStore(directory: appGroupDirectory).write(finished))

        store.reconcileGuidedRunFromAppGroup()

        let row = try #require(loggedRow(store, named: "Lock Screen"))
        #expect(row.duration == 50)
        #expect(abs(row.completedAt.timeIntervalSince(tap)) < 1, "the row ends at the tap, not at the reconcile")
        store.clearGuidedRun()
    }

    /// The Edit sheet's duration field corrects a guided row's minutes like any other row's.
    @Test func theEditSheetsDurationCorrectsAGuidedRow() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Edited", sets: 1)
        startRun(store, s, minutesAgo: 25)
        store.guidedMarkSetDone()
        var row = try #require(loggedRow(store, named: "Edited"))
        #expect(row.duration == 25)

        row.duration = WorkoutSheetRules.durationMinutes(from: "30")
        #expect(store.updateWorkout(row, date: store.todayKey))

        #expect(loggedRow(store, named: "Edited")?.duration == 30)
        store.clearGuidedRun()
    }

    // MARK: - The Apple Health copy

    /// The Health copy is a traditional strength workout ending at the run's finish and starting the
    /// logged minutes earlier, with no energy sample: the runner measures none, so none is invented.
    @Test func theHealthCopyIsAStrengthWorkoutSpanningTheSession() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [.workoutLogging])
        defer { harness.cleanup() }
        harness.controller.grantAllShareTypes()
        let store = makeStore(healthKitService: harness.service)
        store.clearGuidedRun()
        let s = session("Health copy", sets: 1)
        let start = startRun(store, s, minutesAgo: 45)

        store.guidedMarkSetDone()
        await Self.settle { loggedRow(store, named: "Health copy")?.healthKitUUID != nil }

        let row = try #require(loggedRow(store, named: "Health copy"))
        let end = try #require(harness.controller.lastSavedWorkoutEnd)
        let healthStart = try #require(harness.controller.lastSavedWorkoutStart)
        #expect(harness.controller.savedWorkoutCount == 1)
        #expect(harness.controller.lastSavedWorkoutActivityType == .traditionalStrengthTraining)
        #expect(end == row.completedAt)
        #expect(end == store.guidedRunState?.finishedAt)
        #expect(abs(end.timeIntervalSince(healthStart) - 45 * 60) < 0.001, "the logged 45 minutes")
        #expect(abs(healthStart.timeIntervalSince(start)) <= 30, "within half a minute of the real start")
        #expect(harness.controller.lastSavedWorkoutSampleCount == 0)
        store.clearGuidedRun()
    }

    /// Lets the store's detached tasks run; stops early once `until` holds.
    private static func settle(until: @MainActor () -> Bool = { false }) async {
        for _ in 0..<40 {
            if until() { return }
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return
            }
        }
    }
}

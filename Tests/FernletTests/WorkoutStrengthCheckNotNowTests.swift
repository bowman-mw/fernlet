// WorkoutStrengthCheckNotNowTests.swift
// FernletTests
//
// "Not now" on the monthly strength check (w4, 2026-11-10): the run's own transition past a check, what
// counts as a check skipped, and the device-local moment a check may be offered again
// (`WorkoutCalibrationDeferral`). The store's side — the tap, a finished run, "Delete everything" — is
// pinned in GuidedWorkoutRunStoreTests.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The strength check's "Not now": the run state's transition and the deferral value.
@MainActor
struct WorkoutStrengthCheckNotNowTests {

    // MARK: - Fixtures

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// One step of a bench press: a calibration step (`calibration`), a plain warm-up set before
    /// working sets (`.ramp` with `sets` 1), or the working sets themselves (nil).
    func step(_ name: String = "Bench press", calibration: String?, sets: Int = 1) -> GuidedWorkoutRunState.Exercise {
        let tracking = GuidedWorkoutRunState.Tracking(
            targetReps: 5, rangeLow: nil, rangeHigh: nil, suggested: 100, step: 5, unitRaw: "lb",
            equipmentRaw: "barbell", confidenceRaw: "medium", askReasonOnOverride: false,
            calibrationRaw: calibration, easierSession: false, compoundsBefore: 0, selected: 100
        )
        return GuidedWorkoutRunState.Exercise(name: name, sets: sets, reps: "5", roleRaw: "main", fromCatalog: true,
                                              restSeconds: 60, tracking: tracking)
    }

    func run(_ exercises: [GuidedWorkoutRunState.Exercise]) -> GuidedWorkoutRunState {
        GuidedWorkoutRunState(sessionID: UUID(), committedDayKey: "2026-11-10", intensityRaw: "moderate", title: "Push",
                              suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
                              exercises: exercises, setStartedAt: Self.t0)
    }

    func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "fernlet.tests.calibrationDeferral.\(UUID().uuidString)"))
    }

    // MARK: - The run

    @Test func notNowSkipsTheRestOfTheCheckAndMovesToWhatFollows() {
        var state = run([step(calibration: "ramp"), step(calibration: "ramp"), step(calibration: "test"),
                         step("Triceps pushdown", calibration: nil, sets: 3)])
        #expect(state.canPutOffStrengthCheck)
        state.markSetDone(now: Self.t0)   // the first ramp set
        #expect(state.exerciseIndex == 1 && state.canPutOffStrengthCheck)
        state.putOffStrengthCheck(now: Self.t0)
        #expect(state.exerciseIndex == 3 && state.currentSet == 1 && state.isWorking)
        #expect(state.exercises.map { $0.tracking?.skipped == true } == [false, true, true, false])
        #expect(!state.canPutOffStrengthCheck && state.strengthCheckWasSkipped)
        // Nothing but the check moved: off a check, "Not now" does nothing.
        let after = state
        state.putOffStrengthCheck(now: Self.t0)
        #expect(state == after)
    }

    @Test func aCheckWithNothingAfterItFinishesTheRunAndMaxAttemptsLeaveOneSkippedLine() throws {
        var state = run([step(calibration: "ramp"), step(calibration: "attempt"), step(calibration: "attempt"),
                         step(calibration: "attempt")])
        state.markSetDone(now: Self.t0)
        state.putOffStrengthCheck(now: Self.t0.addingTimeInterval(30))
        #expect(state.isFinishedNaturally && state.finishedAt == Self.t0.addingTimeInterval(30))
        #expect(state.strengthCheckWasSkipped)
        let log = try #require(GuidedRunLoadLog.log(for: state))
        #expect(log.text.components(separatedBy: "\n").filter { $0 == "Bench press - skipped" }.count == 1)
        #expect(log.results.map(\.calibration) == [.ramp])
    }

    @Test func aPlainWarmUpSetIsNotAStrengthCheck() {
        // A warm-up set is tagged as a ramp too, but it leads into ordinary working sets.
        var state = run([step(calibration: "ramp"), step(calibration: nil, sets: 3)])
        #expect(!state.canPutOffStrengthCheck && !state.strengthCheckWasSkipped)
        state.putOffStrengthCheck(now: Self.t0)
        #expect(state.exerciseIndex == 0 && state.exercises.allSatisfy { $0.tracking?.skipped != true })
        // A check of another lift further on is not the cursor's.
        let later = run([step("Squat", calibration: nil, sets: 3), step(calibration: "test")])
        #expect(!later.canPutOffStrengthCheck)
        // Done, a run offers nothing.
        var ended = run([step(calibration: "test")])
        ended.end()
        #expect(!ended.canPutOffStrengthCheck)
    }

    @Test func aCheckCountsAsSkippedOnlyWhenNoTestSetWasDone() {
        var missed = run([step(calibration: "attempt"), step(calibration: "attempt"), step(calibration: nil, sets: 1)])
        #expect(!missed.strengthCheckWasSkipped, "nothing skipped yet")
        missed.markSetDone(now: Self.t0)          // the first attempt, done
        missed.markCurrentSkipped()               // the second, skipped past
        #expect(!missed.strengthCheckWasSkipped, "one attempt was made, so the check was tested")
        var skipped = run([step(calibration: "ramp"), step(calibration: "test"), step(calibration: nil, sets: 1)])
        skipped.markSetDone(now: Self.t0)
        skipped.markCurrentSkipped()
        #expect(skipped.strengthCheckWasSkipped)
        #expect(!run([step(calibration: nil, sets: 3)]).strengthCheckWasSkipped, "a run with no check")
    }

    // MARK: - The deferral

    @Test func notNowAsksAgainTwoWeeksOnAndNeverEarlier() throws {
        let defaults = try defaults()
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == nil)
        #expect(!WorkoutCalibrationDeferral.isPutOff(asOf: Self.t0, in: defaults))
        let again = WorkoutCalibrationDeferral.putOff(from: Self.t0, in: defaults)
        #expect(again == Self.t0.addingTimeInterval(14 * 86_400))
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == again)
        #expect(defaults.object(forKey: "fernlet.workoutCalibration.askAgainFrom") as? Double == again.timeIntervalSince1970,
                "the stored token: seconds since 1970 under the frozen key")
        #expect(WorkoutCalibrationDeferral.isPutOff(asOf: Self.t0.addingTimeInterval(13.9 * 86_400), in: defaults))
        #expect(!WorkoutCalibrationDeferral.isPutOff(asOf: again, in: defaults), "on the day itself the check is back")
        // The planner may read from the start of the day the "Not now" was tapped on.
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0.addingTimeInterval(-0.9 * 86_400), in: defaults) == again)
        // A second "Not now" a week later moves it on; an earlier one never pulls it back.
        let later = WorkoutCalibrationDeferral.putOff(from: Self.t0.addingTimeInterval(7 * 86_400), in: defaults)
        #expect(later == Self.t0.addingTimeInterval(21 * 86_400))
        #expect(WorkoutCalibrationDeferral.putOff(from: Self.t0.addingTimeInterval(6.5 * 86_400), in: defaults) == later)
        WorkoutCalibrationDeferral.clear(in: defaults)
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == nil)
    }

    @Test func aStoredMomentNoNotNowCouldHaveWrittenIsNotRead() throws {
        let defaults = try defaults()
        // A clock set far forward and back: never more than two weeks (and a day's slack) ahead.
        defaults.set(Self.t0.addingTimeInterval(40 * 86_400).timeIntervalSince1970, forKey: WorkoutCalibrationDeferral.askAgainFromKey)
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == nil)
        #expect(!WorkoutCalibrationDeferral.isPutOff(asOf: Self.t0, in: defaults))
        #expect(WorkoutCalibrationDeferral.putOff(from: Self.t0, in: defaults) == Self.t0.addingTimeInterval(14 * 86_400))
        defaults.set("soon", forKey: WorkoutCalibrationDeferral.askAgainFromKey)
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == nil)
        defaults.set(Double.nan, forKey: WorkoutCalibrationDeferral.askAgainFromKey)
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == nil)
    }

    @Test func onlyAFinishedRunWithItsTestSkippedCountsAsNotNow() throws {
        let defaults = try defaults()
        var abandoned = run([step(calibration: "test"), step(calibration: nil, sets: 1)])
        abandoned.markCurrentSkipped()
        abandoned.end()
        #expect(!WorkoutCalibrationDeferral.noteFinished(abandoned, at: Self.t0, in: defaults), "an abandoned run logs nothing")
        var tested = run([step(calibration: "test")])
        tested.markSetDone(now: Self.t0)
        #expect(!WorkoutCalibrationDeferral.noteFinished(tested, at: Self.t0, in: defaults))
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == nil)
        var skipped = run([step(calibration: "test"), step(calibration: nil, sets: 1)])
        skipped.markCurrentSkipped()
        skipped.markSetDone(now: Self.t0)
        skipped.markSetDone(now: Self.t0.addingTimeInterval(600))
        #expect(skipped.isFinishedNaturally)
        #expect(WorkoutCalibrationDeferral.noteFinished(skipped, at: Self.t0.addingTimeInterval(3_600), in: defaults))
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == Self.t0.addingTimeInterval(600 + 14 * 86_400),
                "counted from the run's own finish, not from when it was logged")
    }
}

// MARK: - w4, the engine half: the lift falls back to its usual sets, and a hand log counts

extension WorkoutStrengthCheckNotNowTests {

    /// A check step carrying the lift's usual working sets, as the planner now writes it.
    func check(_ calibration: String) -> GuidedWorkoutRunState.Exercise {
        var checked = step(calibration: calibration)
        checked.tracking?.usual = GuidedWorkoutRunState.Tracking.UsualSets(
            sets: 3, reps: 8, rangeLow: 95, rangeHigh: 110, suggested: 105, confidenceRaw: "low", restSeconds: 120)
        return checked
    }

    @Test func notNowFallsBackToTheLiftsUsualWorkingSets() throws {
        var state = run([check("ramp"), check("ramp"), check("test"), step("Triceps pushdown", calibration: nil, sets: 3)])
        state.markSetDone(now: Self.t0)   // the first ramp set
        state.putOffStrengthCheck(now: Self.t0)
        // The lift is still trained today: its usual sets are the next step, straight after the check.
        #expect(state.exercises.count == 5)
        #expect(state.exerciseIndex == 3 && state.currentSet == 1 && state.isWorking)
        let usual = try #require(state.currentExercise)
        #expect((usual.name, usual.sets, usual.reps, usual.restSeconds) == ("Bench press", 3, "8", 120))
        let tracking = try #require(usual.tracking)
        #expect(tracking.calibrationRaw == nil && tracking.skipped != true && tracking.usual == nil)
        #expect((tracking.targetReps, tracking.rangeLow, tracking.rangeHigh) == (8, 95, 110))
        #expect((tracking.suggested, tracking.selected, tracking.confidenceRaw) == (105, 105, "low"))
        #expect((tracking.unitRaw, tracking.equipmentRaw, tracking.step) == ("lb", "barbell", 5))
        #expect(state.exercises[4].name == "Triceps pushdown")
        #expect(state.exercises.map { $0.tracking?.skipped == true } == [false, true, true, false, false])
        #expect(!state.canPutOffStrengthCheck && state.strengthCheckWasSkipped, "the check itself still went untested")

        // Finished, the log shows the lift done — not skipped — and the test never becomes a result.
        for _ in 0..<12 where !state.isDone {
            state.markSetDone(now: Self.t0)
            state.skipRest(now: Self.t0)
        }
        #expect(state.isFinishedNaturally)
        let log = try #require(GuidedRunLoadLog.log(for: state))
        #expect(!log.text.contains("Bench press - skipped"))
        #expect(log.text.contains("Bench press - 3 x 8 @ 105 lb"))
        #expect(log.results.filter { $0.name == "Bench press" }.map(\.calibration) == [.ramp, nil])
        let worked = try #require(log.results.first { $0.name == "Bench press" && $0.calibration == nil })
        #expect((worked.prescribedSets, worked.targetReps, worked.selectedWeight) == (3, 8, 105))
    }

    @Test func aCheckWithNothingAfterItStillGetsItsUsualSets() throws {
        var state = run([check("ramp"), check("attempt"), check("attempt"), check("attempt")])
        state.putOffStrengthCheck(now: Self.t0)
        #expect(!state.isDone, "the usual sets follow, so the run goes on")
        #expect(state.exerciseIndex == 4)
        #expect(state.currentExercise?.tracking?.calibrationRaw == nil && state.currentExercise?.sets == 3)
        // A run saved before checks carried their usual sets decodes, and moves on as it did.
        let old = run([step(calibration: "test"), step("Triceps pushdown", calibration: nil, sets: 3)])
        var decoded = try JSONDecoder().decode(GuidedWorkoutRunState.self, from: JSONEncoder().encode(old))
        #expect(decoded.exercises.first?.tracking?.usual == nil)
        decoded.putOffStrengthCheck(now: Self.t0)
        #expect(decoded.exercises.count == 2 && decoded.currentExercise?.name == "Triceps pushdown")
    }

    @Test func thePlannersCheckCarriesTheUsualSetsIntoTheRun() throws {
        let weight = WeightPrescription(low: 95, high: 110, suggested: 105, step: 5, unit: .lb, confidence: .low)
        var guidance = LoadGuidance(targetReps: 5, prescription: WeightPrescription(low: 110, high: 110, suggested: 110, step: 5, unit: .lb, confidence: .low),
                                    equipment: .barbell, unit: .lb, calibration: .test)
        guidance.usual = LoadGuidance.UsualSets(sets: 3, reps: 8, prescription: weight, restSeconds: 120)
        let test = PrescribedExercise(name: "Bench press", sets: 1, reps: "5", role: .main, fromCatalog: true, guidance: guidance)
        let tracking = try #require(GuidedRunLoadLog.tracking(for: test))
        #expect(tracking.usual == GuidedWorkoutRunState.Tracking.UsualSets(
            sets: 3, reps: 8, rangeLow: 95, rangeHigh: 110, suggested: 105, confidenceRaw: "low", restSeconds: 120))
        var plain = guidance
        plain.usual = nil
        let untouched = PrescribedExercise(name: "Bench press", sets: 1, reps: "5", role: .main, fromCatalog: true, guidance: plain)
        #expect(try #require(GuidedRunLoadLog.tracking(for: untouched)).usual == nil)
    }

    // MARK: Logging the due lift by hand

    func plan(checking lift: String) -> WorkoutProgram.DayPlan {
        let weight = WeightPrescription(low: 110, high: 110, suggested: 110, step: 5, unit: .lb, confidence: .medium)
        let test = PrescribedExercise(
            name: lift, sets: 1, reps: "5", role: .main, fromCatalog: true,
            guidance: LoadGuidance(targetReps: 5, prescription: weight, equipment: .barbell, unit: .lb, calibration: .test))
        let curl = PrescribedExercise(name: "Curl", sets: 3, reps: "12", role: .accessory, fromCatalog: true)
        let session = WorkoutProgram.SessionSuggestion(
            title: "Push", timeLabel: "", kind: .strength, exercises: [test, curl],
            suggestion: WorkoutSuggestion(name: "Push", exercises: "", notes: ""))
        return WorkoutProgram.DayPlan(splitName: "Test", dayTitle: "Day", sessions: [session], droppedSlots: [], locationName: "Test")
    }

    func hand(_ text: String, guided: Bool? = nil) -> Workout {
        Workout(name: "Push", type: .upper, exercises: text, rpe: nil, notes: "", duration: nil,
                loggedFromGuidedSession: guided, intensity: .moderate)
    }

    @Test func loggingTheDueLiftByHandCountsAsNotNow() throws {
        let defaults = try defaults()
        let plan = plan(checking: "Bench press")
        #expect(WorkoutCalibrationDeferral.strengthCheckLifts(in: plan) == ["bench press"])
        // Another lift, a guided row, or no plan at all changes nothing.
        #expect(!WorkoutCalibrationDeferral.noteHandLogged(hand("Curl 3x12 @ 25 lb"), plan: plan, at: Self.t0, in: defaults))
        #expect(!WorkoutCalibrationDeferral.noteHandLogged(hand("Bench press 3x8 @ 135 lb", guided: true), plan: plan, at: Self.t0, in: defaults))
        #expect(!WorkoutCalibrationDeferral.noteHandLogged(hand("Bench press 3x8 @ 135 lb"), plan: nil, at: Self.t0, in: defaults))
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == nil)
        // The lift the plan had turned into a check, logged by hand: two weeks.
        #expect(WorkoutCalibrationDeferral.noteHandLogged(hand("  bench  PRESS 3x8 @ 135 lb\nCurl 3x12"), plan: plan, at: Self.t0, in: defaults))
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: Self.t0, in: defaults) == Self.t0.addingTimeInterval(14 * 86_400))
        // A second hand log inside the two weeks does not push the check further off…
        let week = Self.t0.addingTimeInterval(7 * 86_400)
        #expect(!WorkoutCalibrationDeferral.noteHandLogged(hand("Bench press 3x8 @ 135 lb"), plan: plan, at: week, in: defaults))
        #expect(WorkoutCalibrationDeferral.askAgainFrom(asOf: week, in: defaults) == Self.t0.addingTimeInterval(14 * 86_400))
        // …and once it is offered again, passing it over by hand is "not now" again.
        let later = Self.t0.addingTimeInterval(15 * 86_400)
        #expect(WorkoutCalibrationDeferral.noteHandLogged(hand("Bench press 3x8 @ 135 lb"), plan: plan, at: later, in: defaults))
        // Entered set by set counts the same as a written line.
        let fresh = try self.defaults()
        let sets = try #require(ExerciseResult.handLogged(name: "Bench press", sets: [LoggedSet(reps: 8, weight: 135)], unit: .lb))
        var row = hand("")
        row.exerciseResults = [sets]
        #expect(WorkoutCalibrationDeferral.noteHandLogged(row, plan: plan, at: Self.t0, in: fresh))
    }
}

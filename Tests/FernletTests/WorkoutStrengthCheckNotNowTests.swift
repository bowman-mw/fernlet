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

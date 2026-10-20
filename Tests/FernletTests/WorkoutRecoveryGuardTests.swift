import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// Pins the 48-hour same-muscle guard (``WorkoutRecoveryGuard``) across splits: full body three
/// times a week logged on back-to-back days, upper/lower, and push/pull/legs — kept, moved or
/// lightened — plus the case where nothing is logged, the window itself, and the history the app
/// gathers for it (``WorkoutRecentTrainingBuilder``).
@MainActor
struct WorkoutRecoveryGuardTests {

    // MARK: - Fixtures

    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// The primary muscles a list of logged lifts worked hard.
    func hard(_ lifts: [String]) -> Set<MuscleGroup> {
        lifts.reduce(into: Set<MuscleGroup>()) { $0.formUnion(WorkoutRecoveryGuard.hardMuscles(ofLift: $1)) }
    }

    func plan(
        _ split: TrainingSplit, day: Int, recent: WorkoutRecoveryGuard.RecentTraining? = nil
    ) -> WorkoutProgram.DayPlan {
        WorkoutProgram.dayPlan(
            goal: .strength, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate),
            location: .fullGym, context: "", split: split, rotationIndex: day, recent: recent
        )
    }

    func lifting(_ plan: WorkoutProgram.DayPlan) -> [PrescribedExercise] {
        plan.sessions.flatMap(\.exercises).filter { $0.block == .lifting && $0.fromCatalog }
    }

    func notes(_ plan: WorkoutProgram.DayPlan) -> String {
        plan.sessions.map(\.suggestion.notes).joined(separator: " · ")
    }

    func primaries(_ name: String) -> Set<MuscleGroup> {
        WorkoutExerciseCatalog.exercise(named: name)?.primaryMuscles ?? []
    }

    /// Every lifting step that works a hard muscle gives up exactly one set; every other step —
    /// the warm-up, activation, cool-down and the lifts that spare those muscles — is unchanged.
    func expectLightened(_ guarded: WorkoutProgram.DayPlan, against baseline: WorkoutProgram.DayPlan, hard: Set<MuscleGroup>) {
        let before = baseline.sessions.flatMap(\.exercises)
        let after = guarded.sessions.flatMap(\.exercises)
        #expect(before.map(\.name) == after.map(\.name), "the guard changed the picks, not just the sets")
        for (old, new) in zip(before, after) {
            let shouldLighten = new.block == .lifting && new.fromCatalog && !primaries(new.name).isDisjoint(with: hard)
            let expected = shouldLighten ? max(WorkoutRecoveryGuard.minimumSets, old.sets - 1) : old.sets
            #expect(new.sets == expected, "\(new.name) (\(new.block)): \(old.sets) → \(new.sets)")
        }
    }

    // MARK: - The window and the rules

    @Test func theWindowIsYesterdayAtDayGranularity() {
        #expect(WorkoutRecoveryGuard.windowHours == 48)
        #expect(WorkoutRecoveryGuard.countsTowardWindow(daysAgo: 1))
        #expect(!WorkoutRecoveryGuard.countsTowardWindow(daysAgo: 0), "today's own sessions never count")
        #expect(!WorkoutRecoveryGuard.countsTowardWindow(daysAgo: 2), "a full rest day between is enough")
        #expect(WorkoutRecoveryGuard.lookbackDays == 1)
        #expect(WorkoutRecoveryGuard.lightenedSets(4) == 3)
        #expect(WorkoutRecoveryGuard.lightenedSets(1) == 1)
    }

    /// Mobility and cardio days, and core slots (the light activation block), are not hard work.
    @Test func recoveryDaysAndCoreSlotsAreExempt() {
        #expect(WorkoutRecoveryGuard.hardMuscles(of: WorkoutSplitCatalog.recoveryFlow.days[0]).isEmpty)
        #expect(WorkoutRecoveryGuard.hardMuscles(of: WorkoutSplitCatalog.dailyMove.days[1]).isEmpty)
        let fullBodyA = WorkoutRecoveryGuard.hardMuscles(of: WorkoutSplitCatalog.fullBody3.days[0])
        #expect(!fullBodyA.contains(.abs) && !fullBodyA.contains(.obliques))
        #expect(fullBodyA.contains(.quads) && fullBodyA.contains(.chest))
        // Stretches, holds and jumps never count as hard sets.
        #expect(WorkoutRecoveryGuard.hardMuscles(ofLift: "Low lunge stretch").isEmpty)
        #expect(WorkoutRecoveryGuard.hardMuscles(ofLift: "Plank").isEmpty)
        #expect(WorkoutRecoveryGuard.hardMuscles(ofLift: "Box jump").isEmpty)
        #expect(WorkoutRecoveryGuard.hardMuscles(ofLift: "Back squats") == [.glutes, .quads])
    }

    // MARK: - Nothing logged

    @Test func nothingLoggedPlansTheRotationsDayUnchanged() {
        for split in [WorkoutSplitCatalog.fullBody3, WorkoutSplitCatalog.upperLower4, WorkoutSplitCatalog.ppl3] {
            for day in split.days.indices {
                let baseline = plan(split, day: day)
                let guarded = plan(split, day: day, recent: WorkoutRecoveryGuard.RecentTraining.empty)
                #expect(guarded.dayTitle == baseline.dayTitle)
                #expect(guarded.recovery == WorkoutRecoveryGuard.Decision(dayIndex: day))
                expectLightened(guarded, against: baseline, hard: [])
                #expect(!notes(guarded).contains("48 hours"))
            }
        }
        #expect(plan(WorkoutSplitCatalog.fullBody3, day: 0).recovery == nil)
    }

    // MARK: - Full body three times a week, back to back

    /// Full Body A yesterday, B today: every other full-body day overlaps too, so B stays and its
    /// overlapping lifts lose a set, with the reason in the note.
    @Test func fullBodyOnBackToBackDaysLightensTheOverlap() {
        let hardMuscles = hard(["Back squat", "Bench press", "Barbell row", "Romanian deadlift"])
        let recent = WorkoutRecoveryGuard.RecentTraining(hardMuscles: hardMuscles, latestSessionNames: ["Full Body A"])
        let guarded = plan(WorkoutSplitCatalog.fullBody3, day: 1, recent: recent)
        #expect(guarded.dayTitle == "Day 2")
        #expect(guarded.recovery?.movedFrom == nil)
        #expect(guarded.recovery?.overlap.isEmpty == false)
        expectLightened(guarded, against: plan(WorkoutSplitCatalog.fullBody3, day: 1), hard: hardMuscles)
        #expect(notes(guarded).contains("One set fewer on"))
        #expect(notes(guarded).contains("worked hard in the last 48 hours"))
        // At least one lift spared those muscles and kept its sets (the overhead press).
        #expect(lifting(guarded).contains { primaries($0.name).isDisjoint(with: hardMuscles) })
    }

    /// The same, end to end: yesterday's guided run as the app logs it, read by the builder, with
    /// the rotation the app computes.
    @Test func fullBodyEndToEndFromTheLoggedRun() throws {
        let todayKey = FernletDate.dayKey(for: Self.base)
        let today = try #require(FernletDate.date(fromDayKey: todayKey))
        let yesterday = FernletDate.dayKey(for: try #require(Calendar.current.date(byAdding: .day, value: -1, to: today)))
        let run = Workout(
            name: "Full Body A", type: .fullBody, exercises: "", rpe: nil, notes: "", duration: nil,
            loggedFromGuidedSession: true, intensity: .moderate,
            exerciseResults: [
                ExerciseResult(name: "Back squat", prescribedSets: 4, targetReps: 5),
                ExerciseResult(name: "Bench press", prescribedSets: 4, targetReps: 5),
                ExerciseResult(name: "Barbell row", prescribedSets: 4, targetReps: 5),
            ]
        )
        let days = [yesterday: FernletDay(date: yesterday, workouts: [run])]
        let recent = WorkoutRecentTrainingBuilder.build(days: days, todayKey: todayKey)
        #expect(recent.hardMuscles == [.glutes, .quads, .chest, .lats, .upperBack])
        #expect(recent.latestSessionNames == ["Full Body A"])
        let rotation = WorkoutProgram.nextDayIndex(in: WorkoutSplitCatalog.fullBody3, recentSessionNames: [["Full Body A"]])
        #expect(rotation == 1)
        let guarded = plan(WorkoutSplitCatalog.fullBody3, day: rotation, recent: recent)
        #expect(guarded.recovery?.movedFrom == nil)
        expectLightened(guarded, against: plan(WorkoutSplitCatalog.fullBody3, day: rotation), hard: recent.hardMuscles)
    }

    // MARK: - Upper / lower

    /// Upper yesterday, Lower today: no overlap, nothing changes.
    @Test func upperThenLowerIsLeftAlone() {
        let recent = WorkoutRecoveryGuard.RecentTraining(
            hardMuscles: hard(["Bench press", "Barbell row", "Overhead press", "Lat pulldown", "Biceps curl", "Triceps pushdown"]),
            latestSessionNames: ["Upper"]
        )
        let guarded = plan(WorkoutSplitCatalog.upperLower4, day: 1, recent: recent)
        #expect(guarded.recovery == WorkoutRecoveryGuard.Decision(dayIndex: 1))
        expectLightened(guarded, against: plan(WorkoutSplitCatalog.upperLower4, day: 1), hard: recent.hardMuscles)
        #expect(!notes(guarded).contains("48 hours"))
    }

    /// An off-plan chest-and-back session yesterday, Upper due today: Lower trains none of those
    /// muscles, so Lower comes first and says why.
    @Test func anOffPlanUpperSessionMovesTheDayToLower() {
        let recent = WorkoutRecoveryGuard.RecentTraining(
            hardMuscles: hard(["Bench press", "Barbell row"]), latestSessionNames: ["Chest day"]
        )
        let guarded = plan(WorkoutSplitCatalog.upperLower4, day: 0, recent: recent)
        #expect(guarded.recovery == WorkoutRecoveryGuard.Decision(dayIndex: 1, movedFrom: 0))
        #expect(guarded.dayTitle == "Day 2")
        #expect(notes(guarded).hasPrefix("Lower today instead of Upper — those muscles worked hard in the last 48 hours."))
        #expect(!notes(guarded).contains("One set fewer"))
    }

    // MARK: - Push / pull / legs

    /// Pull yesterday (with its hinge), Legs today: the overlap is built into the split's order, so
    /// moving would push Legs back every pass. Legs stays, lighter where it repeats the hinge.
    @Test func pullThenLegsKeepsLegsAndLightensTheRepeatedMuscles() {
        let hardMuscles = hard(["Lat pulldown", "Barbell row", "Rear delt fly", "Biceps curl", "Romanian deadlift"])
        let recent = WorkoutRecoveryGuard.RecentTraining(hardMuscles: hardMuscles, latestSessionNames: ["Pull"])
        let guarded = plan(WorkoutSplitCatalog.ppl3, day: 2, recent: recent)
        #expect(guarded.dayTitle == "Legs")
        #expect(guarded.recovery?.movedFrom == nil)
        #expect(guarded.recovery?.overlap == [.glutes, .hamstrings])
        expectLightened(guarded, against: plan(WorkoutSplitCatalog.ppl3, day: 2), hard: hardMuscles)
        #expect(lifting(guarded).contains { primaries($0.name) == [.calves] }, "the calf work is untouched")
    }

    /// An off-plan leg session yesterday, Legs due today: Push spares those muscles, so Push comes
    /// first.
    @Test func anOffPlanLegSessionMovesLegsBackForPush() {
        let recent = WorkoutRecoveryGuard.RecentTraining(hardMuscles: hard(["Leg press"]), latestSessionNames: ["Gym"])
        let guarded = plan(WorkoutSplitCatalog.ppl3, day: 2, recent: recent)
        #expect(guarded.recovery == WorkoutRecoveryGuard.Decision(dayIndex: 0, movedFrom: 2))
        #expect(guarded.dayTitle == "Push")
        #expect(notes(guarded).hasPrefix("Push today instead of Legs"))
    }

    /// Push yesterday, Pull today: no overlap on a push/pull/legs rotation.
    @Test func pushThenPullIsLeftAlone() {
        let recent = WorkoutRecoveryGuard.RecentTraining(
            hardMuscles: hard(["Bench press", "Overhead press", "Lateral raise", "Triceps pushdown"]),
            latestSessionNames: ["Push"]
        )
        #expect(plan(WorkoutSplitCatalog.ppl3, day: 1, recent: recent).recovery == WorkoutRecoveryGuard.Decision(dayIndex: 1))
    }

    // MARK: - The history the app reads

    /// Yesterday's structured results and hand-logged lifts count; a calibration ramp, a hold, a
    /// stretch, an older day and today's own rows don't.
    @Test func theBuilderReadsOnlyYesterdaysHardSets() throws {
        let todayKey = FernletDate.dayKey(for: Self.base)
        let today = try #require(FernletDate.date(fromDayKey: todayKey))
        func key(_ daysAgo: Int) throws -> String {
            FernletDate.dayKey(for: try #require(Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)))
        }
        func row(_ name: String, _ lines: String, results: [ExerciseResult]? = nil) -> Workout {
            Workout(name: name, type: .fullBody, exercises: lines, rpe: nil, notes: "", duration: nil,
                    loggedFromGuidedSession: results == nil ? nil : true, intensity: .moderate, exerciseResults: results)
        }
        let guided = row("Full Body A", "", results: [
            ExerciseResult(name: "Bench press", prescribedSets: 3, targetReps: 8),
            ExerciseResult(name: "Deadlift", prescribedSets: 1, targetReps: 5, calibration: .ramp),
        ])
        let handLogged = row("Extra", "Leg curl 3x12\nPlank - 2 x 30 s\nLow lunge stretch - 20 s")
        let yesterday = try key(1)
        let twoDaysAgo = try key(2)
        let days = [
            yesterday: FernletDay(date: yesterday, workouts: [guided, handLogged]),
            twoDaysAgo: FernletDay(date: twoDaysAgo, workouts: [row("Legs", "Back squat 5x5")]),
            todayKey: FernletDay(date: todayKey, workouts: [row("Pull", "Barbell row 3x8")]),
        ]
        let recent = WorkoutRecentTrainingBuilder.build(days: days, todayKey: todayKey)
        #expect(recent.hardMuscles == [.chest, .hamstrings])
        #expect(recent.latestSessionNames == ["Full Body A", "Extra"])
        #expect(WorkoutRecentTrainingBuilder.build(days: [:], todayKey: todayKey) == .empty)
    }
}

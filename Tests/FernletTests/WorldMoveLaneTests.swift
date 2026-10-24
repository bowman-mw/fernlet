import Foundation
import SwiftUI
import Testing
import FernletDomainModel
@testable import Fernlet

/// The World build's Move lane logic (World Review Batch 3): the one-line set summary on the workout
/// sheets' lists (`b3-workout-log`, `b3-workout-edit`), and the runner's reps editor with a weight per
/// set and drop sets (`b3-edit-reps` draft 2), through to the line the finished run logs.
@MainActor
struct WorldMoveLaneTests {

    // MARK: - The list row's line

    private static func draft(_ rows: [(Int, String)], unit: LoadUnit = .lb) -> ExerciseSetsDraft {
        ExerciseSetsDraft(name: "Goblet squat", origin: .new,
                          rows: rows.map { SetRowDraft(reps: $0.0, weight: $0.1) }, unit: unit)
    }

    @Test func aListRowReadsItsSetsInOneLine() {
        let varied = WorkoutSetSummary.line(for: Self.draft([(10, "35"), (9, ""), (8, "")]))
        #expect(varied.contains("3"), "the set count")
        #expect(varied.contains("10, 9, 8"), "reps set by set when they differ")
        let thirtyFive = WorkoutActivityLoadText.weight(35, unit: .pounds, width: .abbreviated, locale: .current)
        let twentyFive = WorkoutActivityLoadText.weight(25, unit: .pounds, width: .abbreviated, locale: .current)
        #expect(varied.hasSuffix(thirtyFive), "a blank weight repeats the set above, so one weight: \(varied)")
        let same = WorkoutSetSummary.line(for: Self.draft([(8, "40"), (8, "40"), (8, "40")]))
        #expect(!same.contains(","), "one reps number when every set matched: \(same)")
        let drop = WorkoutSetSummary.weightText(Self.draft([(8, "35"), (8, "25")]))
        #expect(drop == "\(thirtyFive), \(twentyFive)", "each distinct weight, in order")
        #expect(WorkoutSetSummary.weightText(Self.draft([(8, "")])) == nil, "no weight typed, no weight shown")
        #expect(WorkoutSetSummary.line(for: Self.draft([])).isEmpty)
    }

    @Test func anAddedExerciseReadsItsLoggedSets() throws {
        let draft = Self.draft([(10, "35"), (9, ""), (8, "25")])
        var result = ExerciseResult(name: "Goblet squat", prescribedSets: 3, targetReps: 10)
        result.record(draft.rows.map { LoggedSet(reps: $0.reps, weight: $0.weightValue) }, unit: .lb)
        let line = try #require(WorkoutSetSummary.line(for: result))
        #expect(line == WorkoutSetSummary.line(for: draft), "the added row reads like the page it came from: \(line)")
    }

    // MARK: - The reps editor's rows

    private static func tracking(selected: Double? = 35, step: Double? = 5) -> GuidedWorkoutRunState.Tracking {
        GuidedWorkoutRunState.Tracking(
            targetReps: 10, rangeLow: 30, rangeHigh: 40, suggested: 35, step: step, unitRaw: "lb",
            equipmentRaw: "dumbbell", confidenceRaw: nil, askReasonOnOverride: false, calibrationRaw: nil,
            easierSession: false, compoundsBefore: 0, selected: selected
        )
    }

    @Test func theEditorOpensOnTheTargetAtTheSelectedWeight() {
        let rows = GuidedRepsRow.rows(for: Self.tracking(), sets: 3)
        #expect(rows.map(\.reps) == [10, 10, 10])
        #expect(rows.map(\.weight) == ["35", "35", "35"])
        #expect(rows.allSatisfy { !$0.isDrop })
    }

    @Test func aDropSetIsALighterSetUnderTheLastOne() {
        let rows = GuidedRepsRow.addingDrop(to: GuidedRepsRow.rows(for: Self.tracking(), sets: 3), step: 5)
        #expect(rows.count == 4)
        #expect(rows.last?.isDrop == true)
        #expect(rows.last?.reps == 10, "the drop set starts at the set above's reps")
        #expect(rows.last?.weight == "25", "about three quarters of 35, down to a 5 lb step")
        #expect(GuidedRepsRow.setNumber(at: 3, in: rows) == nil, "a drop set has no number of its own")
        #expect(GuidedRepsRow.setNumber(at: 2, in: rows) == 3)
        let afterDrop = rows + [GuidedRepsRow(reps: 8, weight: "35")]
        #expect(GuidedRepsRow.setNumber(at: 4, in: afterDrop) == 4, "the set after a drop set is Set 4, not 5")
        let more = GuidedRepsRow.addingDrop(to: rows, step: 5)
        let saved = GuidedRepsRow.saved(more)
        #expect(saved.reps.count == 5 && saved.weights.count == 5 && saved.drops == [false, false, false, true, true])
        let capped = (0..<GuidedWorkoutRunState.Tracking.maxSets).map { _ in GuidedRepsRow(reps: 8, weight: "20") }
        #expect(GuidedRepsRow.addingDrop(to: capped, step: 5).count == capped.count, "never past the set cap")
    }

    @Test func aBlankWeightRepeatsTheSetAbove() {
        let rows = [GuidedRepsRow(reps: 8, weight: "40"), GuidedRepsRow(reps: 8, weight: ""), GuidedRepsRow(reps: 6, weight: "30")]
        #expect(GuidedRepsRow.saved(rows).weights == [40, 40, 30])
        #expect(GuidedRepsRow.saved([GuidedRepsRow(reps: 80, weight: "")]).reps == [50], "reps stay in 0–50")
    }

    // MARK: - Saving, and the logged line

    private static func run(_ tracking: GuidedWorkoutRunState.Tracking) -> GuidedWorkoutRunState {
        let lift = GuidedWorkoutRunState.Exercise(
            name: "Goblet squat", sets: 3, reps: "10", roleRaw: "main", fromCatalog: true, restSeconds: 90,
            blockRaw: "lifting", tracking: tracking
        )
        return GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: "2026-10-24", intensityRaw: "moderate", title: "Full Body A",
            suggestionExercisesText: "", suggestionNotes: "", sessionKindRaw: "strength",
            exercises: [lift], setStartedAt: Date()
        )
    }

    @Test func theSameWeightEverywhereKeepsNoPerSetWeights() throws {
        var state = Self.run(Self.tracking())
        let id = try #require(state.exercises.first?.id)
        state.setActualSets(reps: [10, 9, 8], weights: [35, 35, 35], drops: [false, false, false], forExercise: id)
        let tracking = try #require(state.exercises.first?.tracking)
        #expect(tracking.actualReps == [10, 9, 8])
        #expect(tracking.actualWeights == nil && tracking.actualDrops == nil)
    }

    @Test func aDropSetIsLoggedSetBySetAtItsWeight() throws {
        var state = Self.run(Self.tracking())
        let id = try #require(state.exercises.first?.id)
        state.setActualSets(reps: [10, 9, 8, 8], weights: [35, 35, 35, 25], drops: [false, false, false, true],
                            forExercise: id)
        let tracking = try #require(state.exercises.first?.tracking)
        #expect(tracking.actualWeights == [35, 35, 35, 25])
        #expect(tracking.actualDrops == [false, false, false, true])
        let lift = try #require(state.exercises.first)
        let result = try #require(GuidedRunLoadLog.result(for: lift))
        #expect(result.loggedSets.map(\.reps) == [10, 9, 8, 8])
        #expect(result.loggedSets.map(\.weight) == [35, 35, 35, 25])
        #expect(result.workingWeight == 35, "a drop set never lowers the working weight")
        #expect(result.loggedLine.contains("8 @ 25"), "the line says the drop set: \(result.loggedLine)")
        // Reopening the editor marks the drop set again.
        let reopened = GuidedRepsRow.rows(for: tracking, sets: lift.sets)
        #expect(reopened.map(\.isDrop) == [false, false, false, true])
        #expect(reopened.last?.weight == "25")
    }

    // MARK: - The workout-space pin question

    @Test func thePinQuestionIsAskedOnceAndNeverInADecoy() {
        #expect(WorkoutSpacePinQuestion.asks(answer: nil, decoy: false), "unanswered: ask")
        #expect(!WorkoutSpacePinQuestion.asks(answer: true, decoy: false), "answered yes: never again")
        #expect(!WorkoutSpacePinQuestion.asks(answer: false, decoy: false), "answered not now: never again here")
        #expect(!WorkoutSpacePinQuestion.asks(answer: nil, decoy: true), "a decoy shows and keeps nothing real")
    }

    @Test func anUnloadedLiftNeverKeepsWeights() throws {
        var state = Self.run(Self.tracking(selected: nil, step: nil))
        let id = try #require(state.exercises.first?.id)
        state.setActualSets(reps: [10, 10, 9], weights: [0, 0, 0], drops: [false, false, false], forExercise: id)
        #expect(state.exercises.first?.tracking?.actualWeights == nil)
    }
}

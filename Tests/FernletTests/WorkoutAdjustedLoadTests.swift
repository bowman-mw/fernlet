// WorkoutAdjustedLoadTests.swift
// FernletTests
//
// Pins the load pass's re-run after "Adjust with AI" (round 2, R3, 2026-10-20). The on-device adjuster
// answers with names, sets and reps only; `WorkoutAdjustedLoad.reload` gives the adjusted lifting block
// back its guidance (a kept lift at the same reps keeps what it had; any other catalog lift is
// prescribed from its history), the compound count ahead of each lift, and the warm-up ramp before the
// first heavy main lift — on the setting and the committed day, as the planner does. The model call
// itself needs a device with Apple Intelligence and is owed there.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct WorkoutAdjustedLoadTests {

    // MARK: - Fixtures

    nonisolated static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    func key(_ name: String) -> String { WorkoutExerciseCatalog.normalizedName(name) }

    /// A completed session of a lift at `weight`, three sets of `reps`.
    func lifted(_ offset: Int, _ weight: Double, reps: Int = 8) -> LiftExposure {
        LiftExposure(date: day(offset), weight: weight, unit: .lb, targetReps: reps, repsPerSet: [reps, reps, reps],
                     effort: nil, rangeLow: weight - 10, rangeHigh: weight + 10, calibration: nil, structured: true)
    }

    func context(_ history: [String: [LiftExposure]] = [:], warmUpSets: Bool = true) -> WorkoutLoadContext {
        WorkoutLoadContext(exposures: history, today: day(30), defaultUnit: .lb,
                           calibration: CalibrationSettings(hasCoach: true), warmUpSets: warmUpSets)
    }

    /// What the adjuster hands back: a name, sets and reps — no guidance.
    func picked(_ name: String, sets: Int = 3, reps: String = "8", role: SlotRole = .main) -> PrescribedExercise {
        PrescribedExercise(name: name, sets: sets, reps: reps, role: role, fromCatalog: true)
    }

    func session(_ exercises: [PrescribedExercise]) -> WorkoutProgram.SessionSuggestion {
        WorkoutProgram.SessionSuggestion(
            title: "Legs", timeLabel: "", kind: .strength, exercises: exercises,
            suggestion: WorkoutSuggestion(name: "Legs", exercises: WorkoutSessionBlocks.planText(for: exercises), notes: "")
        )
    }

    /// The planner's back squat at 135 lb.
    func plannedSquat() -> PrescribedExercise {
        let prescription = WeightPrescription(low: 125, high: 145, suggested: 135, step: 5, unit: .lb, confidence: .medium)
        return PrescribedExercise(
            name: "Back squat", sets: 3, reps: "8", role: .main, fromCatalog: true,
            guidance: LoadGuidance(targetReps: 8, prescription: prescription, equipment: .barbell, unit: .lb)
        )
    }

    /// The planner's session: the squat's warm-up ramp, the squat, then a lateral raise.
    func original(ramped: Bool = true) -> WorkoutProgram.SessionSuggestion {
        let squat = plannedSquat()
        let ramp = ramped ? WorkoutWarmUpSets.steps(for: squat, pattern: .squat) : []
        return session(ramp + [squat, picked("Lateral raise", reps: "12", role: .accessory)])
    }

    /// `original` after the adjuster answered `exercises`, loaded again.
    func reloaded(
        _ exercises: [PrescribedExercise], original: WorkoutProgram.SessionSuggestion,
        load: WorkoutLoadContext, intensity: WorkoutIntensity? = .moderate
    ) -> [PrescribedExercise] {
        let applied = WorkoutProgram.applyAdjustment(to: original, exercises: exercises)
        let result = WorkoutAdjustedLoad.reload(applied, original: original, location: .fullGym, load: load,
                                                intensity: intensity)
        return result.exercises.filter { $0.block == .lifting }
    }

    func warmUps(_ steps: [PrescribedExercise]) -> [PrescribedExercise] {
        steps.filter { WorkoutWarmUpSets.isWarmUpSet($0) }
    }

    // MARK: - Guidance

    @Test func aKeptLiftAtTheSameRepsKeepsItsGuidance() throws {
        let load = context([key("Back squat"): [lifted(28, 200)]])
        let steps = reloaded([picked("Lateral raise", reps: "12", role: .accessory), picked("Back squat")],
                             original: original(), load: load)
        let squat = try #require(steps.last { $0.name == "Back squat" })
        let suggested = squat.guidance?.prescription?.suggested
        #expect(suggested == 135, "the planner's prescription, not a new one from history")
        let raise = try #require(steps.first)
        #expect(raise.name == "Lateral raise")
        let raiseHasGuidance = raise.guidance != nil
        #expect(raiseHasGuidance, "a catalog lift with no history still gets guidance, with no weight yet")
    }

    @Test func aNewOrChangedLiftIsPrescribedFromItsHistory() throws {
        let load = context([key("Bench press"): [lifted(21, 135), lifted(28, 135)], key("Back squat"): [lifted(28, 185)]])
        let steps = reloaded([picked("Bench press"), picked("Back squat", reps: "12")], original: original(), load: load)
        let bench = try #require(steps.last { $0.name == "Bench press" })
        let benchWeight = try #require(bench.guidance?.prescription?.suggested)
        #expect(benchWeight > 0)
        let squat = try #require(steps.last { $0.name == "Back squat" })
        let target = try #require(WorkoutExerciseCatalog.exercise(named: "Back squat"))
        let engine = WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: RepScheme(low: 12, high: 12), baseSets: 3, exposures: [lifted(28, 185)], equipment: target.equipment,
            isLowerBody: true, defaultUnit: .lb, today: day(30), inventory: WorkoutLocation.fullGym.weights
        ))
        let squatReps = squat.guidance?.targetReps
        let squatPrescription = squat.guidance?.prescription
        #expect(squatReps == engine.reps, "new reps: prescribed again from history for them")
        #expect(squatPrescription == engine.prescription)
        let benchBefore = bench.guidance?.compoundsBefore
        let squatBefore = squat.guidance?.compoundsBefore
        #expect(benchBefore == 0)
        #expect(squatBefore == 1, "counted again in the adjusted order")
    }

    @Test func liftsTheCatalogDoesNotKnowGetNoGuidance() throws {
        let steps = reloaded([picked("Mystery lift"), picked("Back squat")], original: original(), load: context())
        let mystery = try #require(steps.first { $0.name == "Mystery lift" })
        let none = mystery.guidance == nil
        #expect(none)
    }

    // MARK: - The ramp

    @Test func theRampComesBackBeforeTheFirstHeavyMainLift() throws {
        let steps = reloaded([picked("Lateral raise", reps: "12", role: .accessory), picked("Back squat")],
                             original: original(), load: context())
        let names = steps.map(\.name)
        #expect(names == ["Lateral raise", "Back squat", "Back squat", "Back squat", "Back squat"])
        let weights = warmUps(steps).map { $0.guidance?.prescription?.suggested }
        let expected: [Double?] = [45, 80, 110]
        #expect(weights == expected)
        let applied = WorkoutProgram.applyAdjustment(
            to: original(), exercises: [picked("Lateral raise", reps: "12", role: .accessory), picked("Back squat")]
        )
        let result = WorkoutAdjustedLoad.reload(applied, original: original(), location: .fullGym, load: context(),
                                                intensity: .moderate)
        #expect(result.suggestion.exercises.contains("Back squat - 1 x 8 (ramp-up)"))
    }

    @Test func theRampFollowsTheSettingAndTheCommittedDay() {
        let answer = [picked("Back squat")]
        let off = reloaded(answer, original: original(), load: context(warmUpSets: false))
        let light = reloaded(answer, original: original(), load: context(), intensity: .light)
        let unknownRamped = reloaded(answer, original: original(), load: context(), intensity: nil)
        let unknownPlain = reloaded(answer, original: original(ramped: false), load: context(), intensity: nil)
        #expect(warmUps(off).isEmpty)
        #expect(warmUps(light).isEmpty, "a light day keeps no ramp")
        #expect(warmUps(unknownRamped).count == 3, "no committed day known: as the planner had it")
        #expect(warmUps(unknownPlain).isEmpty)
    }

    @Test func oldWarmUpSetsNeverSurviveTheReRun() {
        let squat = plannedSquat()
        let stale = session(WorkoutWarmUpSets.steps(for: squat, pattern: .squat) + [squat])
        let result = WorkoutAdjustedLoad.reload(stale, original: stale, location: .fullGym,
                                                load: context(warmUpSets: false), intensity: .moderate)
        let lifting = result.exercises.filter { $0.block == .lifting }
        #expect(warmUps(lifting).isEmpty)
        #expect(lifting.count == 1)
        let again = WorkoutAdjustedLoad.reload(stale, original: stale, location: .fullGym, load: context(),
                                               intensity: .moderate)
        let rebuilt = again.exercises.filter { $0.block == .lifting }
        #expect(warmUps(rebuilt).count == 3, "rebuilt once, never doubled")
    }
}

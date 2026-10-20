// WorkoutProgressionTests.swift
// FernletTests
//
// Round 2's progression pieces (2026-10-20) that ride on the day plan and the runner: planned blocks for
// trained Strength lifters (G2), the harder variation offered at the heaviest weight a location has
// (N7), the runner stepping through the weights a location owns (R6), and the monthly strength check
// waiting for a day with more time (N3). The training-age pacing and the fixed steps (G3, G4, G8) are
// pinned beside the engine in WorkoutLoadEngineTests and WorkoutLoadPlanningTests.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// G2 blocks, N7 harder variation, R6 owned-weight stepping, N3 the strength check's roomier day.
@MainActor
struct WorkoutProgressionTests {

    // MARK: - Fixtures

    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    func key(_ name: String) -> String { WorkoutExerciseCatalog.normalizedName(name) }

    func session(_ offset: Int, _ weight: Double, reps: Int, target: Int) -> LiftExposure {
        LiftExposure(date: day(offset), weight: weight, unit: .lb, targetReps: target,
                     repsPerSet: [reps, reps, reps], rangeLow: weight - 10, rangeHigh: weight + 10, structured: true)
    }

    static func split(_ template: WorkoutSessionTemplate) -> TrainingSplit {
        TrainingSplit(id: "probe", name: "Probe", summary: "", specificity: .balanced, goalFit: [.wellness],
                      days: [WorkoutSplitDay(title: "Day", sessions: [template])])
    }

    /// One session's day plan, with the load context built straight from `history`.
    func plan(
        goal: GoalType = .wellness, template: WorkoutSessionTemplate = WorkoutSessions.push,
        location: WorkoutLocation = .fullGym, history: [String: [LiftExposure]] = [:], today: Int = 30,
        experience: ExperienceLevel? = nil, calibration: CalibrationSettings = CalibrationSettings(hasCoach: true),
        length: WorkoutSessionLength = .noLimit
    ) throws -> WorkoutProgram.SessionSuggestion {
        let load = WorkoutLoadContext(exposures: history, today: day(today), defaultUnit: .lb, calibration: calibration,
                                      experience: experience)
        let plan = WorkoutProgram.dayPlan(
            goal: goal, intensity: .moderate, profile: WorkoutProfile(experience: .beginner), location: location,
            context: "", split: Self.split(template), rotationIndex: 0, load: load,
            options: WorkoutSessionOptions(length: length)
        )
        return try #require(plan.sessions.first)
    }

    func lifting(_ session: WorkoutProgram.SessionSuggestion) -> [PrescribedExercise] {
        session.exercises.filter { $0.block == .lifting }
    }

    /// A garage with the fixed home dumbbell set (5–25 lb) and a bench.
    func garage() -> WorkoutLocation {
        var garage = WorkoutLocation(name: "Garage", ownedEquipment: [.dumbbells, .weightBench])
        var weights = WorkoutWeightInventory(unit: .lb)
        weights.setDumbbells(WorkoutWeightPresets.Dumbbells.homeSet.weights(in: .lb))
        garage.weights = weights
        return garage
    }

    static let squatOnly = WorkoutSessionTemplate(title: "Legs", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Squat", role: .main, movement: .squat, muscles: [.quads, .glutes]),
    ])

    // MARK: - G2 blocks

    @Test func theBlockCalendarAlternatesFourWeekVolumeAndHeavierPhases() {
        func week(_ days: Int) -> BlockWeek {
            WorkoutBlocks.week(on: WorkoutBlocks.epoch.addingTimeInterval(Double(days) * 86_400 + 3_600))
        }
        #expect(week(0) == BlockWeek(phase: .volume, week: 1))
        #expect(week(27) == BlockWeek(phase: .volume, week: 4))
        #expect(week(28) == BlockWeek(phase: .heavier, week: 1))
        #expect(week(55) == BlockWeek(phase: .heavier, week: 4))
        #expect(week(56) == BlockWeek(phase: .volume, week: 1))
        #expect(week(-10) == BlockWeek(phase: .volume, week: 1))
        #expect(BlockPhase.volume.reps == 6 && BlockPhase.heavier.reps == 3)
        #expect(WorkoutBlocks.sets(.heavier, energy: .light) == 4 && WorkoutBlocks.sets(.volume, energy: .hard) == 5)
        #expect(WorkoutBlocks.applies(goal: .strength, tier: .intermediate, role: .main))
        #expect(!WorkoutBlocks.applies(goal: .strength, tier: .beginner, role: .main))
        #expect(!WorkoutBlocks.applies(goal: .wellness, tier: .advanced, role: .main))
        #expect(!WorkoutBlocks.applies(goal: .strength, tier: .advanced, role: .accessory))
    }

    @Test func aTrainedStrengthLiftersMainLiftsFollowTheBlockCalendar() throws {
        let main = try #require(lifting(try plan(goal: .strength)).first).name
        let history = [key(main): [20, 24, 28].map { session($0, 135, reps: 5, target: 5) }]
        let week = WorkoutBlocks.week(on: day(30))
        let blocked = try plan(goal: .strength, history: history, experience: .intermediate)
        let blockedLifts = lifting(blocked)
        let lift = try #require(blockedLifts.first { $0.name == main })
        #expect(lift.reps == "\(week.phase.reps)")
        #expect(lift.sets == week.phase.sets)
        #expect(blocked.suggestion.notes.contains("block, week \(week.week) of 4: main lifts are"))
        // The phase switch rebaselines the lift; the block note says why, so no second line does.
        #expect(!blocked.suggestion.notes.contains("\(main): starting from a fresh estimate"))
        // A first-six-months lifter keeps the goal's fives.
        let novice = try plan(goal: .strength, history: history, experience: .beginner)
        let noviceLifts = lifting(novice)
        let noviceLift = try #require(noviceLifts.first { $0.name == main })
        #expect(noviceLift.reps == "5")
        #expect(!novice.suggestion.notes.contains("block, week"))
    }

    // MARK: - N7 a harder variation

    @Test func atTheHeaviestDumbbellAHarderVariationIsOfferedNeverForced() throws {
        let first = try plan(template: Self.squatOnly, location: garage())
        let squat = try #require(lifting(first).first)
        try #require(squat.name == "Goblet squat")
        let history = [key(squat.name): [24, 28].map { session($0, 25, reps: 12, target: 12) }]
        let session = try plan(template: Self.squatOnly, location: garage(), history: history)
        let lift = try #require(lifting(session).first)
        // The plan stays reps first at the heaviest pair; the harder step is only offered.
        #expect(lift.reps == "13")
        let suggested = lift.guidance?.prescription?.suggested
        #expect(suggested == 25)
        let harder = lift.guidance?.harderVariation
        #expect(harder == "Bulgarian split squat")
        #expect(session.suggestion.notes.contains(
            "If you'd like a harder step for Goblet squat, Bulgarian split squat works the same muscles"))
        // Below the heaviest pair nothing is offered.
        let lighter = try plan(template: Self.squatOnly, location: garage(),
                               history: [key(squat.name): [session(28, 15, reps: 12, target: 12)]])
        let offered = try #require(lifting(lighter).first).guidance?.harderVariation
        #expect(offered == nil)
    }

    @Test func thePlanEditorsSwapOffersTheHarderVariationFirst() {
        let store = makeTestStore()
        let plain = store.exerciseSwapOptions(for: "Goblet squat", excluding: []).map(\.name)
        #expect(!plain.contains("Bulgarian split squat"), "a lunge is no stand-in for a squat on its own")
        let offered = store.exerciseSwapOptions(for: "Goblet squat", excluding: [], harder: "Bulgarian split squat")
        let first = offered.first?.name
        #expect(first == "Bulgarian split squat")
        #expect(offered.count <= WorkoutExerciseSwapOptions.defaultLimit)
        let inSession = store.exerciseSwapOptions(for: "Goblet squat", excluding: ["Bulgarian split squat"],
                                                  harder: "Bulgarian split squat").map(\.name)
        #expect(!inSession.contains("Bulgarian split squat"))
    }

    // MARK: - R6 the runner steps through the weights owned

    func tracking(loads: [Double]?, selected: Double?) -> GuidedWorkoutRunState.Tracking {
        GuidedWorkoutRunState.Tracking(
            targetReps: 10, rangeLow: 15, rangeHigh: 25, suggested: 20, step: 5, unitRaw: "lb",
            equipmentRaw: "dumbbell", confidenceRaw: "low", askReasonOnOverride: false, calibrationRaw: nil,
            easierSession: false, compoundsBefore: 0, selected: selected, loads: loads
        )
    }

    @Test func theRunnersButtonsStepThroughTheWeightsOwned() {
        let owned = tracking(loads: [5, 12.5, 20, 35], selected: 20)
        #expect(owned.steppedWeight(direction: 1, start: 10) == 35)
        #expect(owned.steppedWeight(direction: -1, start: 10) == 12.5)
        #expect(tracking(loads: [5, 12.5, 20, 35], selected: 35).steppedWeight(direction: 1, start: 10) == 35)
        #expect(tracking(loads: [5, 12.5, 20, 35], selected: 5).steppedWeight(direction: -1, start: 10) == 5)
        #expect(owned.snapped(27) == 20 && owned.snapped(30) == 35)
        // With no weights set, one step either way, as before.
        let stepped = tracking(loads: nil, selected: 20)
        #expect(stepped.steppedWeight(direction: 1, start: 10) == 25)
        #expect(stepped.snapped(22) == 20)
        #expect(tracking(loads: nil, selected: nil).steppedWeight(direction: 1, start: 10) == 10)
    }

    @Test func aRunSavedBeforeOwnedLoadsStillDecodes() throws {
        let json = #"{"targetReps":10,"step":5,"unitRaw":"lb","askReasonOnOverride":false,"easierSession":false,"compoundsBefore":0,"selected":20}"#
        let old = try JSONDecoder().decode(GuidedWorkoutRunState.Tracking.self, from: Data(json.utf8))
        #expect(old.loads == nil)
        #expect(old.steppedWeight(direction: 1, start: 10) == 25)
        let round = try JSONDecoder().decode(GuidedWorkoutRunState.Tracking.self,
                                             from: JSONEncoder().encode(tracking(loads: [5, 10], selected: 5)))
        let expected: [Double] = [5, 10]
        #expect(round.loads == expected)
    }

    @Test func plannedLiftsCarryTheOwnedLoadsAroundTheSuggestion() throws {
        let session = try plan(template: Self.squatOnly, location: garage(),
                               history: [key("Goblet squat"): [session(28, 15, reps: 10, target: 10)]])
        let lift = try #require(lifting(session).first)
        let owned: [Double] = [5, 10, 15, 20, 25]
        let planned = lift.guidance?.loads
        #expect(planned == owned)
        let carried = GuidedRunLoadLog.tracking(for: lift)?.loads
        #expect(carried == owned)
        let ladder = try #require(LoadLadder((1...100).map { Double($0) }))
        let window = ladder.window(around: 50, count: 10)
        #expect(window.count == 10 && window.first == 45 && window.last == 54)
        #expect(ladder.window(around: 1, count: 10).first == 1)
        #expect(ladder.window(around: 100, count: 10).last == 100)
    }

    // MARK: - N3 the strength check's roomier day

    @Test func aStrengthCheckThatCannotFitTheBudgetWaitsForARoomierDay() throws {
        let main = try #require(lifting(try plan()).first).name
        let history = [key(main): [21, 28].map { session($0, 135, reps: 10, target: 10) }]
        let roomy = try plan(history: history, calibration: CalibrationSettings())
        let checked = lifting(roomy).contains { $0.guidance?.calibration == .test }
        #expect(checked)
        let short = try plan(history: history, calibration: CalibrationSettings(), length: .min20)
        let squeezed = lifting(short).contains { $0.guidance?.calibration != nil }
        #expect(!squeezed)
        #expect(short.suggestion.notes.contains("The monthly strength check moves to a day with more time"))
    }
}

// WorkoutProgressionTests.swift
// FernletTests
//
// Round 2's progression pieces (2026-10-20) that ride on the day plan and the runner: planned blocks for
// trained Strength lifters (G2), the harder variation offered at the heaviest weight a location has
// (N7), the runner stepping through the weights a location owns (R6), and the monthly strength check
// waiting for a day with more time (N3); what each goal hears (G7), the focus (G6) and the age-adjusted
// copy (G9); and the protein and body-weight lines of the trend story (G11, G13). The training-age
// pacing and the fixed steps (G3, G4, G8) are pinned beside the engine in WorkoutLoadEngineTests and
// WorkoutLoadPlanningTests, with the food question and the protein context's builder (G12, G11).

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
        length: WorkoutSessionLength = .noLimit, traits: LifterTraits = .unknown, focus: WorkoutStrengthFocus = .both,
        recovery: RecoverySummary = .unknown, foodAware: Bool = false, bodyWeights: [BodyWeightSample] = []
    ) throws -> WorkoutProgram.SessionSuggestion {
        let load = WorkoutLoadContext(exposures: history, today: day(today), defaultUnit: .lb, recovery: recovery,
                                      calibration: calibration, traits: traits, experience: experience, focus: focus,
                                      foodAware: foodAware, bodyWeights: bodyWeights)
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
        #expect(WorkoutBlocks.applies(goal: .strength, focus: .both, tier: .intermediate, role: .main))
        #expect(WorkoutBlocks.applies(goal: .strength, focus: .strength, tier: .advanced, role: .main))
        #expect(!WorkoutBlocks.applies(goal: .strength, focus: .size, tier: .advanced, role: .main))
        #expect(!WorkoutBlocks.applies(goal: .strength, focus: .both, tier: .beginner, role: .main))
        #expect(!WorkoutBlocks.applies(goal: .wellness, focus: .strength, tier: .advanced, role: .main))
        #expect(!WorkoutBlocks.applies(goal: .strength, focus: .both, tier: .advanced, role: .accessory))
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

    // MARK: - G7 what each goal hears

    /// Three sessions a week of fives: six weeks climbing 5 lb a week from 100 lb, then `flatWeeks`
    /// flat at 130 lb — with the age inferred, slowing after a few flat weeks and stalled after nine.
    func climbThenFlat(flatWeeks: Int) -> [LiftExposure] {
        (0..<(6 + flatWeeks)).flatMap { week in
            [0, 2, 4].map { session(week * 7 + $0, 100 + 5 * Double(min(week, 6)), reps: 5, target: 5) }
        }
    }

    /// Fourteen weeks of eights: six climbing 2.5 lb a week, then eight falling 1.5 lb a week — weeks
    /// of a line falling beyond noise (`Tools/plateau-sim/swift_mirror.py` replays it).
    func easing() -> [LiftExposure] {
        (0..<14).flatMap { week -> [LiftExposure] in
            let weight = week < 6 ? 100 + 2.5 * Double(week) : 112.5 - 1.5 * Double(week - 5)
            return [0, 2, 4].map { session(week * 7 + $0, weight, reps: 8, target: 8) }
        }
    }

    @Test func gentlerGoalsHearNoPlateauAndRunNoStrengthTest() throws {
        for goal in [GoalType.wellness, .mentalHealth, .recovery, .exploring] {
            let main = try #require(lifting(try plan(goal: goal)).first).name
            let session = try plan(goal: goal, history: [key(main): climbThenFlat(flatWeeks: 9)], today: 104,
                                   calibration: CalibrationSettings())
            let notes = session.suggestion.notes
            #expect(!notes.contains("held steady"), "\(goal) heard a plateau")
            let tested = lifting(session).contains { $0.guidance?.calibration != nil }
            #expect(!tested, "\(goal) ran a strength test")
        }
        #expect(PlateauTracking.forGoal(.recovery) == .off)
    }

    @Test func weightManagementHearsOnlyAQuietStrengthHeldCheck() throws {
        let main = try #require(lifting(try plan(goal: .weightManagement)).first).name
        let stalled = try plan(goal: .weightManagement, history: [key(main): climbThenFlat(flatWeeks: 9)], today: 104,
                               calibration: CalibrationSettings())
        #expect(!stalled.suggestion.notes.contains("held steady"))
        let tested = lifting(stalled).contains { $0.guidance?.calibration != nil }
        #expect(!tested)
        let eased = try plan(goal: .weightManagement, history: [key(main): easing()], today: 97)
        let notes = eased.suggestion.notes
        #expect(notes.contains("\(main) has eased a little over recent weeks. That can happen alongside a calorie deficit."))
        #expect(notes.contains("Today's plan keeps your usual weights and sets, which is what holds strength."))
        #expect(!notes.contains("eat more"))
        let deloaded = lifting(eased).contains { $0.guidance?.easierSession == true }
        #expect(!deloaded)
        #expect(!PlateauTracking.forGoal(.weightManagement).runsStrengthTest)
    }

    @Test func strengthAndSportsPrepFollowTheirMainLiftsOnly() throws {
        let lifts = lifting(try plan(goal: .strength))
        let accessory = try #require(lifts.first { $0.role == .accessory }).name
        let session = try plan(goal: .strength, history: [key(accessory): climbThenFlat(flatWeeks: 9)], today: 104)
        #expect(!session.suggestion.notes.contains("held steady"))
        #expect(PlateauTracking.forGoal(.sportsPrep) == .mainLifts)
        #expect(PlateauTracking.forGoal(.strength).runsStrengthTest)
    }

    // MARK: - The ladder's later steps, with a known training age

    /// Fives three times a week: six weeks climbing 5 lb a week, then `weeks` more at 130 lb less
    /// `drop` a week. With "6 months to 2 years" answered, twelve flat weeks sit nine sessions into a
    /// stall (the variant step) and sixteen falling half a pound a week, twenty-four (holding steady).
    func climbThen(weeks: Int, drop: Double) -> [LiftExposure] {
        (0..<(6 + weeks)).flatMap { week -> [LiftExposure] in
            let weight = 100 + 5 * Double(min(week, 6)) - drop * Double(max(0, week - 6))
            return [0, 2, 4].map { session(week * 7 + $0, weight, reps: 5, target: 5) }
        }
    }

    @Test func aLongStallAddsAVariantBesideTheLiftWhichStays() throws {
        let today = 17 * 7 + 6
        let baseline = lifting(try plan(goal: .strength, today: today, experience: .intermediate))
        let main = try #require(baseline.first)
        let session = try plan(goal: .strength, history: [key(main.name): climbThen(weeks: 12, drop: 0)],
                               today: today, experience: .intermediate)
        let lifts = lifting(session)
        let index = try #require(lifts.firstIndex { $0.name == main.name })
        try #require(index + 1 < lifts.count)
        let variant = lifts[index + 1]
        #expect(variant.name != main.name && variant.role == .accessory)
        #expect(lifts[index].sets == max(2, main.sets - 1))
        #expect(session.suggestion.notes.contains("For a few weeks, \(variant.name) joins \(main.name), which keeps going with one set fewer"))
    }

    @Test func pastTheVariantTheLiftIsHoldingSteadyWithCalmOptions() throws {
        let main = try #require(lifting(try plan(goal: .strength, experience: .intermediate)).first).name
        let session = try plan(goal: .strength, history: [key(main): climbThen(weeks: 16, drop: 0.5)],
                               today: 21 * 7 + 6, experience: .intermediate)
        #expect(session.suggestion.notes.contains("\(main) is holding steady, and steady is fine."))
        let names = lifting(session).map(\.name)
        #expect(names.contains(main))
        #expect(!session.suggestion.notes.contains("joins \(main)"))
    }

    // MARK: - G9 age-adjusted expectations

    @Test func anOlderLiftersSlowingNoteSaysHoldingStrengthIsProgress() throws {
        let main = try #require(lifting(try plan(goal: .strength)).first).name
        let history = [key(main): climbThenFlat(flatWeeks: 4)]
        let younger = try plan(goal: .strength, history: history, today: 69)
        #expect(younger.suggestion.notes.contains("\(main) is coming along more slowly now, which is the normal curve"))
        let older = try plan(goal: .strength, history: history, today: 69, traits: LifterTraits(ageYears: 66))
        #expect(older.suggestion.notes.contains("holding strength steady counts as progress too"))
    }

    // MARK: - G6 the training focus

    @Test func theFocusShapesRepsAndSets() throws {
        let both = lifting(try plan(goal: .strength))
        let size = lifting(try plan(goal: .strength, experience: .intermediate, focus: .size))
        let strength = lifting(try plan(goal: .strength, focus: .strength))
        let bothMain = try #require(both.first)
        let sizeMain = try #require(size.first)
        #expect(bothMain.reps == "5")
        #expect(sizeMain.reps == "6")
        #expect(sizeMain.sets == min(WorkoutStrengthFocus.maxSets, bothMain.sets + 1))
        let sizeAccessory = try #require(size.first { $0.role == .accessory })
        #expect(sizeAccessory.reps == "10")
        let strengthMain = try #require(strength.first)
        #expect(strengthMain.reps == "3")
        #expect(WorkoutStrengthFocus.both.reps(for: .main) == nil)
        #expect(WorkoutStrengthFocus.size.extraSets(.advanced) == 2 && WorkoutStrengthFocus.strength.extraSets(.advanced) == 0)
    }

    @Test func theFocusSyncsAsAFrozenTokenAndAnUnknownOneIsParked() throws {
        func object(_ settings: FernletSettings) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        }
        let fresh = FernletSettings()
        #expect(fresh.workoutStrengthFocus == .both)
        let freshHasKey = try object(fresh)["workoutStrengthFocus"] != nil
        #expect(!freshHasKey, "the default keeps every blob's old shape")
        var chosen = FernletSettings()
        chosen.workoutStrengthFocus = .size
        let back = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(chosen))
        #expect(back.workoutStrengthFocus == .size)
        let newer = try JSONDecoder().decode(FernletSettings.self, from: Data(#"{"workoutStrengthFocus":"power"}"#.utf8))
        #expect(newer.workoutStrengthFocus == .both)
        #expect(newer.unknownWorkoutStrengthFocusToken == "power")
        let parked = try object(newer)["unknownWorkoutStrengthFocusToken"] as? String
        #expect(parked == "power")
        let tokens = WorkoutStrengthFocus.allCases.map(\.rawValue)
        let frozen = ["strength", "size", "both"]
        #expect(tokens == frozen)
    }

    // MARK: - G11, G13 food and body weight in the trend story

    /// Protein logged at 0.8 g per kg a day on every day of the last two weeks: under the floor even
    /// allowing for under-logging.
    static let lowProtein = RecoverySummary(proteinGramsPerKg: 0.8, loggedDaysByWeek: [7, 7])

    /// A morning weigh-in on each of the 28 days before `today`, from 80 kg down 1 % a week.
    func falling(today: Int) -> [BodyWeightSample] {
        (1...28).reversed().map { back in
            BodyWeightSample(date: day(today - back), kilograms: 80 * pow(0.99, Double(28 - back) / 7))
        }
    }

    @Test func aStallUnderTheProteinFloorSaysSoOnlyWithFoodLogsOn() throws {
        let main = try #require(lifting(try plan(goal: .strength)).first).name
        let history = [key(main): climbThenFlat(flatWeeks: 9)]
        let said = try plan(goal: .strength, history: history, today: 104, recovery: Self.lowProtein, foodAware: true)
        let notes = said.suggestion.notes
        #expect(notes.contains("\(main) has held steady for"))
        #expect(notes.contains("Protein logged over the last two weeks has been under about 1.2 g per kg"))
        #expect(notes.contains("check with your doctor"))
        // It is context only: the plan is the same with or without it.
        let quiet = try plan(goal: .strength, history: history, today: 104, recovery: Self.lowProtein)
        #expect(!quiet.suggestion.notes.contains("Protein"))
        let same = lifting(said).map(\.line) == lifting(quiet).map(\.line)
        #expect(same)
        // Patchy logging says nothing.
        let patchy = RecoverySummary(proteinGramsPerKg: 0.5, loggedDaysByWeek: [7, 3])
        let unread = try plan(goal: .strength, history: history, today: 104, recovery: patchy, foodAware: true)
        #expect(!unread.suggestion.notes.contains("Protein"))
    }

    @Test func weightManagementNeverHearsAboutEatingMore() throws {
        let main = try #require(lifting(try plan(goal: .weightManagement)).first).name
        let eased = try plan(goal: .weightManagement, history: [key(main): easing()], today: 97,
                             recovery: Self.lowProtein, foodAware: true)
        let notes = eased.suggestion.notes
        #expect(notes.contains("\(main) has eased a little over recent weeks."))
        #expect(!notes.contains("Protein"))
        #expect(!notes.contains("eat more"))
    }

    @Test func aFallingBodyWeightExplainsASizeStallAndBringsAGentleCheckIn() throws {
        let main = try #require(lifting(try plan(goal: .strength)).first).name
        let history = [key(main): climbThenFlat(flatWeeks: 9)]
        let weights = falling(today: 104)
        #expect(WorkoutBodyWeightTrend.isFalling(weights, today: day(104)))
        let size = try plan(goal: .strength, history: history, today: 104, focus: .size, foodAware: true,
                            bodyWeights: weights)
        #expect(size.suggestion.notes.contains("Your logged body weight has been coming down over the last few weeks, and muscle size usually holds steady while it does"))
        // Only for the Size focus, and only with the food-logs switch on.
        let both = try plan(goal: .strength, history: history, today: 104, foodAware: true, bodyWeights: weights)
        #expect(!both.suggestion.notes.contains("body weight"))
        let off = try plan(goal: .strength, history: history, today: 104, focus: .size, bodyWeights: weights)
        #expect(!off.suggestion.notes.contains("body weight"))

        let wm = try #require(lifting(try plan(goal: .weightManagement)).first).name
        let checkIn = try plan(goal: .weightManagement, history: [key(wm): easing()], today: 97, foodAware: true,
                               bodyWeights: falling(today: 97))
        let notes = checkIn.suggestion.notes
        #expect(notes.contains("Your logged body weight has been coming down over the same weeks, and the two often happen together. How have you been feeling lately?"))
        #expect(!notes.contains("eat more") && !notes.contains("Protein"))
        // No weigh-ins, no word about weight.
        let unlogged = try plan(goal: .weightManagement, history: [key(wm): easing()], today: 97, foodAware: true)
        #expect(!unlogged.suggestion.notes.contains("body weight"))
    }

    // MARK: - N3 the strength check's roomier day

    @Test func aStrengthCheckThatCannotFitTheBudgetWaitsForARoomierDay() throws {
        let main = try #require(lifting(try plan(goal: .strength)).first).name
        let history = [key(main): [21, 28].map { session($0, 135, reps: 10, target: 10) }]
        let roomy = try plan(goal: .strength, history: history, calibration: CalibrationSettings())
        let checked = lifting(roomy).contains { $0.guidance?.calibration == .test }
        #expect(checked)
        let short = try plan(goal: .strength, history: history, calibration: CalibrationSettings(), length: .min20)
        let squeezed = lifting(short).contains { $0.guidance?.calibration != nil }
        #expect(!squeezed)
        #expect(short.suggestion.notes.contains("The monthly strength check moves to a day with more time"))
    }
}

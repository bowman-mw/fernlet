// WorkoutProgressionTests.swift
// FernletTests
//
// Round 2's progression pieces (2026-10-20) that ride on the day plan and the runner: planned blocks for
// trained Strength lifters (G2), the harder variation offered at the heaviest weight a location has
// (N7), the runner stepping through the weights a location owns (R6), and the monthly strength check
// waiting for a day with more time (N3); what each goal hears (G7), the focus (G6) and the age-adjusted
// copy (G9); and the protein line of the trend story (G11; no note reads body weight, w10). The training-age
// pacing and the fixed steps (G3, G4, G8) are pinned beside the engine in WorkoutLoadEngineTests and
// WorkoutLoadPlanningTests, with the food question and the protein context's builder (G12, G11).

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
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
        TrainingSplit(id: "probe", name: "Probe", specificity: .balanced, goalFit: [.wellness],
                      days: [WorkoutSplitDay(title: "Day", sessions: [template])])
    }

    /// One session's day plan, with the load context built straight from `history`.
    func plan(
        goal: GoalType = .wellness, template: WorkoutSessionTemplate = WorkoutSessions.push,
        location: WorkoutLocation = .fullGym, history: [String: [LiftExposure]] = [:], today: Int = 30,
        experience: ExperienceLevel? = nil, calibration: CalibrationSettings = CalibrationSettings(hasCoach: true),
        length: WorkoutSessionLength = .noLimit, traits: LifterTraits = .unknown, focus: WorkoutStrengthFocus = .both,
        recovery: RecoverySummary = .unknown, foodAware: Bool = false, deloadWeek: Bool = false
    ) throws -> WorkoutProgram.SessionSuggestion {
        let load = WorkoutLoadContext(exposures: history, today: day(today), defaultUnit: .lb, recovery: recovery,
                                      calibration: calibration, traits: traits, experience: experience, focus: focus,
                                      foodAware: foodAware, deloadWeek: deloadWeek)
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
        let planned = try plan(template: Self.squatOnly, location: garage(), history: history)
        let lift = try #require(lifting(planned).first)
        // The plan stays reps first at the heaviest pair; the harder step is only offered.
        #expect(lift.reps == "13")
        let suggested = lift.guidance?.prescription?.suggested
        #expect(suggested == 25)
        // The Gym Visual expansion (2026-10-21) added the Dumbbell front squat as the squat's own next
        // rung — the same pattern outranks the step to a lunge (Bulgarian split squat).
        let harder = lift.guidance?.harderVariation
        #expect(harder == "Dumbbell front squat")
        #expect(planned.suggestion.notes.contains(
            "If you'd like a harder step for Goblet squat, Dumbbell front squat works the same muscles"))
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

    // MARK: - w1 a first-time lift can be set light

    /// A barbell garage — a bar, a rack and a bench, so its lifts are barbell lifts — with three pairs of
    /// 45s and the smaller plates: far more than 48 totals, which is where the runner's window used to
    /// sit in the middle of the ladder.
    func plateRichGym() -> WorkoutLocation {
        var gym = WorkoutLocation(name: "Barbell garage", ownedEquipment: [.barbell, .weightPlates, .weightBench, .squatRack])
        var weights = WorkoutWeightInventory(unit: .lb)
        weights.setBar(45)
        for (count, plate) in [(3, 45.0), (1, 35.0), (1, 25.0), (2, 10.0), (1, 5.0), (1, 2.5)] {
            weights.setPairs(count, of: plate)
        }
        gym.weights = weights
        return gym
    }

    @Test func aFirstTimeLiftsPickerStartsAtTheLightestLoadOwnedAndOpensUpward() throws {
        let gym = plateRichGym()
        let ladder = try #require(gym.weights.ladder(for: .barbell, in: .lb))
        #expect(ladder.loads.count > LoadGuidance.maxRunnerLoads, "the fixture must overflow the runner's window")
        let session = try plan(location: gym)
        let lift = try #require(lifting(session).first { $0.guidance?.equipment == .barbell })
        #expect(lift.guidance?.prescription == nil, "no history, so no suggestion")
        let loads = try #require(lift.guidance?.loads)
        #expect(loads.count == LoadGuidance.maxRunnerLoads)
        #expect(loads.first == 45, "the window starts at the empty bar, not the middle of the ladder")
        #expect(loads == Array(ladder.loads.prefix(LoadGuidance.maxRunnerLoads)))

        // In the runner: nothing picked yet, the first tap either way lands on the empty bar…
        var picker = try #require(GuidedRunLoadLog.tracking(for: lift))
        #expect(picker.selected == nil)
        let start = GuidedLoadFormat.startWeight(picker)
        #expect(picker.steppedWeight(direction: 1, start: start) == 45)
        #expect(picker.steppedWeight(direction: -1, start: start) == 45)
        // …and from there it steps both ways through the loads owned.
        picker.selected = 45
        let heavier = try #require(picker.steppedWeight(direction: 1, start: start))
        #expect(heavier == loads[1] && heavier > 45)
        picker.selected = heavier
        #expect(picker.steppedWeight(direction: -1, start: start) == 45)
        picker.selected = 45
        #expect(picker.steppedWeight(direction: -1, start: start) == 45, "nothing is lighter than the bar")

        // The lightest dumbbell, not the 10 lb default start, when the pairs owned are known.
        #expect(tracking(loads: [5, 12.5, 20, 35], selected: nil).steppedWeight(direction: 1, start: 10) == 5)
    }

    @Test func aLiftWithASuggestionStillCarriesTheLoadsAroundIt() throws {
        let gym = plateRichGym()
        let baseline = try plan(location: gym)
        let name = try #require(lifting(baseline).first { $0.guidance?.equipment == .barbell }).name
        let session = try plan(location: gym, history: [key(name): [session(28, 225, reps: 10, target: 10)]])
        let lift = try #require(lifting(session).first { $0.name == name })
        let suggested = try #require(lift.guidance?.prescription?.suggested)
        let loads = try #require(lift.guidance?.loads)
        #expect(loads.count == LoadGuidance.maxRunnerLoads)
        #expect(try #require(loads.first) < suggested && suggested < (try #require(loads.last)))
        #expect(try #require(loads.first) > 45, "a lift with history keeps its window around the suggestion")
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
        let dayPlan = try plan(template: Self.squatOnly, location: garage(),
                               history: [key("Goblet squat"): [session(28, 15, reps: 10, target: 10)]])
        let lift = try #require(lifting(dayPlan).first)
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

    // MARK: - G11 food in the trend story

    /// Protein logged at 0.8 g per kg a day on every day of the last two weeks: under the floor even
    /// allowing for under-logging.
    static let lowProtein = RecoverySummary(proteinGramsPerKg: 0.8, loggedDaysByWeek: [7, 7])

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

    /// w10 (2026-11-10): the planner reads no body weight, so a note never mentions it — the context
    /// that claimed to (G13) was never fed a weigh-in and is gone.
    @Test func noNoteEverMentionsBodyWeight() throws {
        let main = try #require(lifting(try plan(goal: .strength)).first).name
        let stalled = try plan(goal: .strength, history: [key(main): climbThenFlat(flatWeeks: 9)], today: 104,
                               focus: .size, recovery: Self.lowProtein, foodAware: true)
        #expect(stalled.suggestion.notes.contains("\(main) has held steady for"))
        #expect(!stalled.suggestion.notes.contains("body weight has been"))
        let wm = try #require(lifting(try plan(goal: .weightManagement)).first).name
        let eased = try plan(goal: .weightManagement, history: [key(wm): easing()], today: 97, foodAware: true)
        #expect(eased.suggestion.notes.contains("\(wm) has eased a little over recent weeks."))
        #expect(!eased.suggestion.notes.contains("body weight"))
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

// MARK: - The 2026-11-10 fixes at the plan (w4, w5, w7, w8, w9) and the runner's window

extension WorkoutProgressionTests {

    /// Three main lifts, all upper body, so one history stalls them alike.
    static let threeMains = WorkoutSessionTemplate(title: "Upper", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Press", role: .main, movement: .push, muscles: [.chest]),
        WorkoutSlotSpec(label: "Pull", role: .main, movement: .pull, muscles: [.lats]),
        WorkoutSlotSpec(label: "Overhead", role: .main, movement: .push, muscles: [.frontDelts]),
    ])

    /// w4: a plan built while a check is put off holds the normal sets and says nothing about a check.
    @Test func aStrengthCheckPutOffIsNotPlannedAndThePlanSaysNothingAboutIt() throws {
        let main = try #require(lifting(try plan(goal: .strength)).first).name
        let history = [key(main): [21, 28].map { session($0, 135, reps: 10, target: 10) }]
        let normal = try plan(goal: .strength, history: history)
        let due = try plan(goal: .strength, history: history, calibration: CalibrationSettings())
        #expect(lifting(due).contains { $0.guidance?.calibration == .test })

        let putOff = try plan(goal: .strength, history: history, calibration: CalibrationSettings(askAgainFrom: day(35)))
        #expect(!lifting(putOff).contains { $0.guidance?.calibration != nil })
        #expect(lifting(putOff).map(\.line) == lifting(normal).map(\.line), "the normal sets")
        #expect(!putOff.suggestion.notes.localizedCaseInsensitiveContains("strength check"))
        // On the day it may be asked again, it is.
        let again = try plan(goal: .strength, history: history, today: 35,
                             calibration: CalibrationSettings(askAgainFrom: day(35)))
        #expect(lifting(again).contains { $0.guidance?.calibration == .test })

        // Every step of a planned check carries the lift's usual sets, for "Not now" in the runner.
        let usualLift = try #require(lifting(normal).first { $0.name == main })
        let checkSteps = lifting(due).filter { $0.name == main }
        #expect(!checkSteps.isEmpty)
        for step in checkSteps {
            let usual = try #require(step.guidance?.usual)
            #expect((usual.sets, usual.reps) == (usualLift.sets, Int(usualLift.reps)))
            #expect(usual.prescription == usualLift.guidance?.prescription)
            #expect(usual.restSeconds > 0)
        }
        #expect(lifting(normal).allSatisfy { $0.guidance?.usual == nil })
    }

    @Test func aCheckIsNeverDueWhilePutOffNorWithinAWeekOfTheLast() {
        func due(_ settings: CalibrationSettings, _ intensity: WorkoutIntensity = .moderate) -> Bool {
            WorkoutCalibration.isDue(settings, intensity: intensity, today: day(100))
        }
        #expect(due(CalibrationSettings()))
        #expect(!due(CalibrationSettings(askAgainFrom: day(101))))
        #expect(due(CalibrationSettings(askAgainFrom: day(100))), "on the day itself the check is back")
        #expect(due(CalibrationSettings(lastCalibration: day(72))))
        #expect(!due(CalibrationSettings(lastCalibration: day(73))))
        #expect(!due(CalibrationSettings(lastCalibration: day(60), askAgainFrom: day(110))))
        #expect(!due(CalibrationSettings(lastCalibration: day(95))), "never two checks in one week")
        #expect(WorkoutCalibration.minimumGapDays == 7)
        #expect(!due(CalibrationSettings(), .light) && !due(CalibrationSettings(hasCoach: true)))
    }

    /// w4: the app's builder hands the device's "Not now" to the planner as a day.
    @Test func theContextCarriesAPutOffCheckAsADay() {
        let todayKey = FernletDate.dayKey(for: day(100))
        func context(_ again: Date?) -> WorkoutLoadContext {
            WorkoutLoadContextBuilder.build(days: [:], today: FernletDay(date: todayKey), todayKey: todayKey,
                                            settings: FernletSettings(), strengthCheckAskAgainFrom: again)
        }
        #expect(context(nil).calibration.askAgainFrom == nil)
        let evening = Calendar.current.startOfDay(for: day(105)).addingTimeInterval(18 * 3_600)
        #expect(context(evening).calibration.askAgainFrom == Calendar.current.startOfDay(for: day(105)))
    }

    /// w5 (W6): a marked deload week was only a calendar label — "add weight now" could appear in it.
    @Test func aMarkedDeloadWeekLightensThePlanItself() throws {
        let main = try #require(lifting(try plan(goal: .strength)).first).name
        let history = [key(main): [26, 28].map { session($0, 135, reps: 5, target: 5) }]
        let normal = try plan(goal: .strength, history: history)
        let normalLift = try #require(lifting(normal).first { $0.name == main })
        #expect(normalLift.guidance?.prescription?.suggested == 140)
        #expect(normal.suggestion.notes.contains("\(main): up to 140 lb today."))

        let deload = try plan(goal: .strength, history: history, deloadWeek: true)
        let lift = try #require(lifting(deload).first { $0.name == main })
        #expect(lift.guidance?.prescription?.suggested == 135, "the same weight as last time")
        #expect(lift.reps == "5")
        #expect(lift.sets == WorkoutLoadEngine.deloadWeekSets(normalLift.sets))
        #expect(lift.sets < normalLift.sets)
        #expect(lift.guidance?.easierSession == true, "so it never becomes next week's starting point")
        let notes = deload.suggestion.notes
        #expect(notes.contains("Deload week: the same weights as last time and about half the sets."))
        #expect(!notes.contains("up to 140") && !notes.contains("add weight"))
        // Lifts with nothing logged lighten too.
        let others = zip(lifting(normal), lifting(deload)).filter { $0.0.name != main }
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { $0.0.name == $0.1.name && $0.1.sets == WorkoutLoadEngine.deloadWeekSets($0.0.sets) })
        // No strength check in a deload week, due or not.
        let ready = [key(main): [21, 28].map { session($0, 135, reps: 5, target: 5) }]
        let checked = try plan(goal: .strength, history: ready, calibration: CalibrationSettings(), deloadWeek: true)
        #expect(!lifting(checked).contains { $0.guidance?.calibration != nil })
        #expect(!checked.suggestion.notes.localizedCaseInsensitiveContains("strength check"))
    }

    /// w5: the builder reads the Bodybuilding calendar's marked week, only while that goal is on.
    @Test func theContextKnowsAMarkedDeloadWeek() throws {
        let calendar = BodybuildingWeeks.calendar()
        let todayKey = FernletDate.dayKey(for: day(100))
        let week = try #require(BodybuildingWeeks.weekStartKey(forDayKey: todayKey, calendar: calendar))
        var settings = FernletSettings()
        settings.selectedGoal = .bodybuilding
        #expect(!WorkoutLoadContextBuilder.isDeloadWeek(todayKey: todayKey, settings: settings))
        settings.bodybuildingCalendar.setDeload(weekStart: week, true)
        #expect(WorkoutLoadContextBuilder.isDeloadWeek(todayKey: todayKey, settings: settings))
        let context = WorkoutLoadContextBuilder.build(days: [:], today: FernletDay(date: todayKey), todayKey: todayKey,
                                                      settings: settings)
        #expect(context.deloadWeek)
        let nextWeek = try #require(BodybuildingWeeks.dayKey(todayKey, addingDays: 7, calendar: calendar))
        #expect(!WorkoutLoadContextBuilder.isDeloadWeek(todayKey: nextWeek, settings: settings))
        settings.selectedGoal = .strength
        #expect(!WorkoutLoadContextBuilder.isDeloadWeek(todayKey: todayKey, settings: settings),
                "the mark is only read while the calendar that shows it is on")
    }

    /// w7 (W13): at the heaviest pair, one extra set — then the harder variation, not the line again.
    @Test func atTheHeaviestLoadOneExtraSetThenTheHarderVariationIsNamed() throws {
        func planned(_ days: [Int]) throws -> WorkoutProgram.SessionSuggestion {
            try plan(template: Self.squatOnly, location: garage(),
                     history: [key("Goblet squat"): days.map { session($0, 25, reps: 15, target: 15) }])
        }
        let extraSet = try planned([28])
        #expect(extraSet.suggestion.notes.contains("Goblet squat: one more set today — 25 lb is your heaviest dumbbell."))
        let toppedOut = try planned([26, 28])
        let lift = try #require(lifting(toppedOut).first)
        #expect(lift.sets == (try #require(lifting(extraSet).first)).sets, "the one extra set is kept, never a second")
        #expect(lift.guidance?.harderVariation == "Dumbbell front squat")
        let notes = toppedOut.suggestion.notes
        #expect(notes.contains("Goblet squat: this is as far as reps and sets go here. Dumbbell front squat is the next step up"))
        #expect(!notes.contains("one more set today"))
        #expect(!notes.contains("Otherwise more reps, then a set"))
        let held = try planned([24, 26, 28])
        #expect(!held.suggestion.notes.contains("Goblet squat"), "said once; after that it holds quietly")
        #expect(lifting(held).first?.guidance?.harderVariation == "Dumbbell front squat", "the swap is still offered in the editor")
        #expect(lifting(held).first?.sets == lift.sets)
    }

    /// w8 (W14): the advanced pace stays 28 days, and the note says until when.
    @Test func aLongTrainedLiftersHoldSaysUntilWhen() throws {
        let main = try #require(lifting(try plan()).first).name
        let history = [key(main): [20, 24, 28].map { session($0, 135, reps: 9, target: 9) }]
        let held = try plan(history: history, experience: .advanced)
        let lift = try #require(lifting(held).first { $0.name == main })
        #expect(lift.reps == "9")
        #expect(lift.guidance?.prescription?.suggested == 135)
        let until = day(48).formatted(.dateTime.month(.wide).day())
        #expect(held.suggestion.notes.contains("\(main): holding this block until \(until)."))
    }

    /// w9 (W10): a second stalled lift changed silently.
    @Test func everyLiftTheTrendChangedIsNamedUpToTwoThenCounted() throws {
        let names = lifting(try plan(goal: .strength, template: Self.threeMains)).map(\.name)
        try #require(names.count == 3 && Set(names).count == 3)
        let stalled = Dictionary(uniqueKeysWithValues: names.map { (key($0), climbThenFlat(flatWeeks: 9)) })
        let all = try plan(goal: .strength, template: Self.threeMains, history: stalled, today: 104).suggestion.notes
        #expect(all.contains("\(names[0]) has held steady for"))
        #expect(all.contains("Today \(names[0]) goes first, with at least 3 minutes' rest between sets — a fair retest."))
        #expect(all.contains("\(names[1]) also gets at least 3 minutes' rest between sets — a fair retest."))
        #expect(all.contains("And 1 more changed today."))
        #expect(!all.contains("\(names[2]) also gets"), "two lifts are named; the rest are counted")

        let two = Dictionary(uniqueKeysWithValues: names.prefix(2).map { (key($0), climbThenFlat(flatWeeks: 9)) })
        let pair = try plan(goal: .strength, template: Self.threeMains, history: two, today: 104).suggestion.notes
        #expect(pair.contains("\(names[1]) also gets at least 3 minutes' rest between sets — a fair retest."))
        #expect(!pair.contains("more changed today"))
        let one = try plan(goal: .strength, template: Self.threeMains, history: [key(names[0]): climbThenFlat(flatWeeks: 9)],
                           today: 104).suggestion.notes
        #expect(one.contains("Today \(names[0]) goes first") && !one.contains("also gets") && !one.contains("more changed today"))
    }

    /// B1's follow-up: with no history the run carries the 48 lightest loads, and "Heavier" stopped at
    /// the 48th.
    @Test func steppingPastTheCarriedWindowGoesOnByTheStep() {
        #expect(GuidedWorkoutRunState.Tracking.carriedWindow == LoadGuidance.maxRunnerLoads)
        let window = (0..<LoadGuidance.maxRunnerLoads).map { 45 + 5 * Double($0) }   // 45 … 280
        var first = tracking(loads: window, selected: 280)
        first.suggested = nil
        first.rangeLow = nil
        first.rangeHigh = nil
        #expect(first.steppedWeight(direction: 1, start: 45) == 285, "a strong first-timer is not capped at the 48th load")
        #expect(first.snapped(285) == 285, "and the pick is not pulled back into the window")
        first.selected = 290
        #expect(first.steppedWeight(direction: 1, start: 45) == 295)
        #expect(first.steppedWeight(direction: -1, start: 45) == 280, "back down, it rejoins the loads owned")
        first.selected = 45
        #expect(first.steppedWeight(direction: -1, start: 45) == 45, "nothing is lighter than the lightest load owned")
        #expect(first.snapped(20) == 45)
        // A window taken around a suggestion may be cut at either end.
        let around = tracking(loads: window, selected: 45)
        #expect(around.steppedWeight(direction: -1, start: 45) == 40)
        #expect(around.snapped(40) == 40)
        // A short list is everything the location owns: its ends are real.
        #expect(tracking(loads: [5, 12.5, 20, 35], selected: 35).steppedWeight(direction: 1, start: 10) == 35)
        #expect(tracking(loads: [5, 12.5, 20, 35], selected: 35).snapped(60) == 35)
    }
}

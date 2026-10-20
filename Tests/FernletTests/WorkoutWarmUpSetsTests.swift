// WorkoutWarmUpSetsTests.swift
// FernletTests
//
// Pins warm-up ramp sets before heavy main lifts (comparison report idea 12, 2026-10-20; the owner's
// round-2 picks, R1): the ramp itself (a barbell's empty bar × 8, then about 60 % × 5 and 80 % × 3 on
// loadable plates; dumbbells at about 40, 60 and 80 % on the dumbbells owned; never at or over the
// working weight, no repeats), which lift gets one and when (the session's FIRST heavy main lift on a
// barbell or dumbbells, with a suggested weight, or none; never accessories, light days, a lift with no
// weight yet, or a lift the calibration already ramps into; the level default and the lifter's own
// choice), the run
// ("Warm-up set 1 of 3", "Skip warm-up sets", what VoiceOver and spoken cues say), and the record:
// logged "(ramp-up)", read by no estimate, no plateau check, no hand-log reader and no history rollup.
//
// What no test here can check — how the warm-up card, the skip and the Plates disclosure look and
// read on a device with VoiceOver and at the largest text sizes — is owed on a simulator or device.

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import FernletUI
@testable import Fernlet

@MainActor
struct WorkoutWarmUpSetsTests {

    // MARK: - Fixtures

    nonisolated static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    func key(_ name: String) -> String { WorkoutExerciseCatalog.normalizedName(name) }

    static let pushSplit = TrainingSplit(
        id: "probe", name: "Probe", summary: "", specificity: .balanced, goalFit: [.wellness],
        days: [WorkoutSplitDay(title: "Push", sessions: [WorkoutSessions.push])]
    )

    /// A Push day for an intermediate lifter at a full gym, with the given history and switches.
    func pushSession(
        history: [String: [LiftExposure]] = [:], warmUpSets: Bool = true, intensity: WorkoutIntensity = .moderate,
        calibrationDue: Bool = false, goal: GoalType = .wellness
    ) throws -> WorkoutProgram.SessionSuggestion {
        let calibration = calibrationDue ? CalibrationSettings() : CalibrationSettings(hasCoach: true)
        let load = WorkoutLoadContext(exposures: history, today: day(30), defaultUnit: .lb,
                                      calibration: calibration, warmUpSets: warmUpSets)
        let plan = WorkoutProgram.dayPlan(
            goal: goal, intensity: intensity, profile: WorkoutProfile(experience: .intermediate),
            location: .fullGym, context: "", split: Self.pushSplit, rotationIndex: 0, load: load
        )
        return try #require(plan.sessions.first)
    }

    func lifting(_ session: WorkoutProgram.SessionSuggestion) -> [PrescribedExercise] {
        session.exercises.filter { $0.block == .lifting }
    }

    /// The Push day's first main lift, planned with no history.
    func mainLift() throws -> PrescribedExercise {
        let steps = lifting(try pushSession(warmUpSets: false))
        let main = steps.first { $0.role == .main }
        return try #require(main)
    }

    /// A completed session of a lift at `weight`, three sets of `reps`, from a range.
    func lifted(_ offset: Int, _ weight: Double, reps: Int = 8, effort: ExerciseEffort? = nil,
                calibration: CalibrationStep? = nil) -> LiftExposure {
        LiftExposure(date: day(offset), weight: weight, unit: .lb, targetReps: reps, repsPerSet: [reps, reps, reps],
                     effort: effort, rangeLow: weight - 10, rangeHigh: weight + 10, calibration: calibration,
                     structured: true)
    }

    /// A planned barbell back squat (or another lift) with a suggested weight.
    func planned(
        _ name: String = "Back squat", role: SlotRole = .main, equipment: Equipment? = .barbell,
        suggested: Double? = 135, calibration: CalibrationStep? = nil, hold: Int? = nil
    ) -> PrescribedExercise {
        let prescription = suggested.map {
            WeightPrescription(low: $0 - 10, high: $0 + 10, suggested: $0, step: 5, unit: .lb, confidence: .medium)
        }
        return PrescribedExercise(
            name: name, sets: 3, reps: "8", role: role, fromCatalog: true, holdSeconds: hold,
            guidance: LoadGuidance(targetReps: 8, prescription: prescription, equipment: equipment, unit: .lb,
                                   calibration: calibration)
        )
    }

    func runState(_ steps: [PrescribedExercise]) -> GuidedWorkoutRunState {
        let exercises = steps.map {
            GuidedWorkoutRunState.Exercise(
                id: $0.id, name: $0.name, sets: $0.sets, reps: $0.reps, roleRaw: "main", fromCatalog: $0.fromCatalog,
                restSeconds: 90, holdSeconds: $0.holdSeconds, blockRaw: $0.block.rawValue,
                tracking: GuidedRunLoadLog.tracking(for: $0)
            )
        }
        return GuidedWorkoutRunState(sessionID: UUID(), committedDayKey: "2026-10-20", intensityRaw: "moderate",
                                     title: "Legs", suggestionExercisesText: "", suggestionNotes: "",
                                     sessionKindRaw: "strength", exercises: exercises)
    }

    /// Three warm-up sets, the squat at 135 lb, then a cable row.
    func squatSteps() -> [PrescribedExercise] {
        let squat = planned()
        return WorkoutWarmUpSets.steps(for: squat, pattern: .squat) + [squat, planned("Cable row", role: .accessory)]
    }

    func words(_ spoken: (kind: FernletAnnouncementKind, sentence: LocalizedStringResource)?) -> String? {
        spoken.map { String(localized: $0.sentence) }
    }

    func plain(_ text: String?) -> String? {
        text.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
    }

    // MARK: - The ramp

    @Test func aBarbellRampIsTheEmptyBarThenSixtyAndEightyOnThePlates() {
        let sets = WorkoutWarmUpSets.sets(working: 135, equipment: .barbell, unit: .lb)
        let weights = sets.map(\.weight)
        let reps = sets.map(\.reps)
        let expectedWeights: [Double] = [45, 80, 110]
        let expectedReps: [Int] = [8, 5, 3]
        #expect(weights == expectedWeights)
        #expect(reps == expectedReps)
        let heavy = WorkoutWarmUpSets.sets(working: 315, equipment: .barbell, unit: .lb).map(\.weight)
        let expectedHeavy: [Double] = [45, 190, 250]
        #expect(heavy == expectedHeavy)
    }

    @Test func aBarbellRampUsesTheLocationsOwnBarAndPlatesWhenSet() throws {
        var weights = WorkoutWeightInventory()
        weights.setBar(35)
        for plate in [25.0, 10, 5] { weights.setPairs(1, of: plate) }
        let ladder = try #require(weights.ladder(for: .barbell, in: .lb))
        // The bar alone, then 81 lb and 108 lb snapped onto 35 + one each of 25, 10 and 5 per side.
        let ramp = WorkoutWarmUpSets.sets(working: 135, equipment: .barbell, unit: .lb, ladder: ladder).map(\.weight)
        let expected: [Double] = [35, 85, 105]
        #expect(ramp == expected)
    }

    @Test func aDumbbellRampSnapsToTheDumbbellsOwned() throws {
        let ladder = try #require(LoadLadder([10, 25, 40, 55]))
        let owned = WorkoutWarmUpSets.sets(working: 60, equipment: .dumbbell, unit: .lb, ladder: ladder)
        let weights = owned.map(\.weight)
        let reps = owned.map(\.reps)
        let expectedWeights: [Double] = [25, 40, 55]
        let expectedReps: [Int] = [8, 5, 3]
        #expect(weights == expectedWeights)
        #expect(reps == expectedReps)
        let sparse = try #require(LoadLadder([20, 50]))
        let one = WorkoutWarmUpSets.sets(working: 50, equipment: .dumbbell, unit: .lb, ladder: sparse)
        #expect(one.isEmpty, "fewer than two distinct weights under the working one: no ramp")
    }

    @Test func theRampNeverGoesUnderTheBarRepeatsAWeightOrReachesTheWorkingWeight() {
        let light = WorkoutWarmUpSets.sets(working: 95, equipment: .barbell, unit: .lb).map(\.weight)
        let expectedLight: [Double] = [45, 55, 75]
        #expect(light == expectedLight)
        let barOnly = WorkoutWarmUpSets.sets(working: 50, equipment: .barbell, unit: .lb)
        let barWeights = barOnly.map(\.weight)
        let barReps = barOnly.map(\.reps)
        let expectedBar: [Double] = [45]
        #expect(barWeights == expectedBar)
        #expect(barReps == [8])
        #expect(WorkoutWarmUpSets.sets(working: 45, equipment: .barbell, unit: .lb).isEmpty)
        for working in stride(from: 50.0, through: 500.0, by: 5.0) {
            let weights = WorkoutWarmUpSets.sets(working: working, equipment: .barbell, unit: .lb).map(\.weight)
            let below = weights.filter { $0 < working }.count == weights.count
            let rising = zip(weights, weights.dropFirst()).filter { $0.0 < $0.1 }.count == max(0, weights.count - 1)
            let onPlates = weights.filter { PlateCalculator.isLoadable($0, on: .standard(.lb)) }.count == weights.count
            let atLeastBar = weights.filter { $0 >= 45 }.count == weights.count
            #expect(below, "working \(working): \(weights)")
            #expect(rising, "working \(working): \(weights)")
            #expect(onPlates, "working \(working): \(weights)")
            #expect(atLeastBar, "working \(working): \(weights)")
        }
    }

    @Test func kilogramLiftsRampOnKilogramPlates() {
        let barbell = WorkoutWarmUpSets.sets(working: 60, equipment: .barbell, unit: .kg).map(\.weight)
        let expectedBarbell: [Double] = [20, 35, 47.5]
        #expect(barbell == expectedBarbell)
        let dumbbell = WorkoutWarmUpSets.sets(working: 20, equipment: .dumbbell, unit: .kg).map(\.weight)
        let expectedDumbbell: [Double] = [8, 12, 16]
        #expect(dumbbell == expectedDumbbell)
    }

    @Test func offTheBarbellALightLiftHasNothingToRampThrough() {
        let heavy = WorkoutWarmUpSets.sets(working: 50, equipment: .dumbbell, unit: .lb).map(\.weight)
        let expectedHeavy: [Double] = [20, 30, 40]
        #expect(heavy == expectedHeavy)
        #expect(WorkoutWarmUpSets.sets(working: 10, equipment: .dumbbell, unit: .lb).isEmpty)
        #expect(WorkoutWarmUpSets.sets(working: 100, equipment: .bodyweight, unit: .lb).isEmpty)
        #expect(WorkoutWarmUpSets.sets(working: 100, equipment: .machine, unit: .lb).isEmpty, "barbell and dumbbell only")
        #expect(WorkoutWarmUpSets.sets(working: 100, equipment: .cable, unit: .lb).isEmpty, "barbell and dumbbell only")
        #expect(WorkoutWarmUpSets.sets(working: 53, equipment: .kettlebell, unit: .lb).isEmpty, "barbell and dumbbell only")
        for bad in [0.0, -20, .nan, .infinity] {
            #expect(WorkoutWarmUpSets.sets(working: bad, equipment: .barbell, unit: .lb).isEmpty)
        }
    }

    @Test func theStepsAreSingleFixedRampSetsOfTheLift() throws {
        let steps = WorkoutWarmUpSets.steps(for: planned(), pattern: .squat)
        #expect(WorkoutWarmUpSets.steps(for: planned(equipment: .machine), pattern: .squat).isEmpty)
        let names = steps.map(\.name)
        let sets = steps.map(\.sets)
        let reps = steps.map(\.reps)
        let weights = steps.map { $0.guidance?.prescription?.suggested }
        let fixed = steps.map { $0.guidance?.prescription?.low == $0.guidance?.prescription?.high }
        let tags = steps.map { $0.guidance?.calibration }
        let warmUps = steps.map { WorkoutWarmUpSets.isWarmUpSet($0) }
        let expectedWeights: [Double?] = [45, 80, 110]
        let expectedTags: [CalibrationStep?] = [.ramp, .ramp, .ramp]
        #expect(names == ["Back squat", "Back squat", "Back squat"])
        #expect(sets == [1, 1, 1])
        #expect(reps == ["8", "5", "3"])
        #expect(weights == expectedWeights)
        #expect(fixed == [true, true, true])
        #expect(tags == expectedTags)
        #expect(warmUps == [true, true, true])
        let first = try #require(steps.first)
        #expect(first.line == "Back squat - 1 x 8 (ramp-up)")
    }

    // MARK: - Which lifts, and when

    @Test func theSettingDefaultsByLevelAndAChoiceWins() {
        #expect(!WorkoutWarmUpSets.isOnByDefault(for: .beginner))
        #expect(WorkoutWarmUpSets.isOnByDefault(for: .intermediate))
        #expect(WorkoutWarmUpSets.isOnByDefault(for: .advanced))
        #expect(WorkoutWarmUpSets.isEnabled(preference: nil, experience: .advanced))
        #expect(!WorkoutWarmUpSets.isEnabled(preference: false, experience: .advanced))
        #expect(WorkoutWarmUpSets.isEnabled(preference: true, experience: .beginner))
    }

    @Test func thePlannerReadsTheSettingThroughTheLoadContext() {
        let todayKey = FernletDate.dayKey(for: day(30))
        func context(_ settings: FernletSettings) -> WorkoutLoadContext {
            WorkoutLoadContextBuilder.build(days: [:], today: FernletDay(date: todayKey), todayKey: todayKey,
                                            settings: settings, locale: Locale(identifier: "en_US"))
        }
        var settings = FernletSettings()
        #expect(!context(settings).warmUpSets, "a beginner by default")
        settings.workoutProfile.experience = .intermediate
        #expect(context(settings).warmUpSets)
        settings.workoutWarmUpSets = false
        #expect(!context(settings).warmUpSets)
    }

    @Test func onlyHeavyMainLiftsWithAWeightQualify() {
        #expect(WorkoutWarmUpSets.qualifies(planned(), pattern: .squat))
        #expect(WorkoutWarmUpSets.qualifies(planned(equipment: .dumbbell), pattern: .push))
        #expect(!WorkoutWarmUpSets.qualifies(planned(role: .accessory), pattern: .squat))
        #expect(!WorkoutWarmUpSets.qualifies(planned(), pattern: .isolation))
        #expect(!WorkoutWarmUpSets.qualifies(planned(equipment: .bodyweight), pattern: .push))
        #expect(!WorkoutWarmUpSets.qualifies(planned(equipment: .machine), pattern: .push), "barbell and dumbbell only")
        #expect(!WorkoutWarmUpSets.qualifies(planned(equipment: .cable), pattern: .pull), "barbell and dumbbell only")
        #expect(!WorkoutWarmUpSets.qualifies(planned(equipment: .kettlebell), pattern: .hinge), "barbell and dumbbell only")
        #expect(!WorkoutWarmUpSets.qualifies(planned(equipment: nil), pattern: .push))
        #expect(!WorkoutWarmUpSets.qualifies(planned(suggested: nil), pattern: .squat))
        #expect(!WorkoutWarmUpSets.qualifies(planned(calibration: .test), pattern: .squat))
        #expect(!WorkoutWarmUpSets.qualifies(planned(calibration: .ramp), pattern: .squat))
        #expect(!WorkoutWarmUpSets.qualifies(planned(hold: 30), pattern: .squat))
    }

    @Test func theRampGoesToTheFirstHeavyMainLiftOrToNone() {
        let press = planned("Leg press", equipment: .machine)
        let squat = planned("Back squat")
        let bench = planned("Bench press")
        let patterns: [MovementPattern?] = [.squat, .squat, .push]
        let first = WorkoutWarmUpSets.firstHeavyMainLift(in: [press, squat, bench], patterns: patterns)
        #expect(first == 1, "a machine main lift is not a heavy lift")
        let noWeight = planned("Back squat", suggested: nil)
        let unready = WorkoutWarmUpSets.firstHeavyMainLift(in: [noWeight, bench], patterns: [.squat, .push])
        #expect(unready == 0, "the first heavy lift is the one, even when it can't ramp")
        #expect(!WorkoutWarmUpSets.qualifies(noWeight, pattern: .squat))
        let unknown = WorkoutWarmUpSets.firstHeavyMainLift(in: [squat], patterns: [nil])
        #expect(unknown == nil)
    }

    @Test func onlyTheSessionsFirstHeavyMainLiftRampsUp() throws {
        let baseline = lifting(try pushSession(warmUpSets: false))
        let mains = baseline.filter { WorkoutWarmUpSets.isHeavyMainLift($0, pattern: .push) }
        #expect(mains.count >= 2, "the Push day at a full gym opens with two heavy presses")
        let firstMain = try #require(mains.first)
        var history: [String: [LiftExposure]] = [:]
        for step in baseline { history[key(step.name)] = [lifted(28, 135)] }
        let steps = lifting(try pushSession(history: history))
        let ramped = Set(steps.filter { WorkoutWarmUpSets.isWarmUpSet($0) }.map(\.name))
        let expected: Set<String> = [firstMain.name]
        #expect(ramped == expected)
    }

    @Test func aFirstHeavyLiftWithNoWeightYetHandsItsRampToNoOne() throws {
        let baseline = lifting(try pushSession(warmUpSets: false))
        let mains = baseline.filter { WorkoutWarmUpSets.isHeavyMainLift($0, pattern: .push) }
        let later = try #require(mains.dropFirst().first)
        let session = try pushSession(history: [key(later.name): [lifted(28, 135)]])
        let count = lifting(session).filter { WorkoutWarmUpSets.isWarmUpSet($0) }.count
        #expect(count == 0)
    }

    @Test func aHeavyMainLiftRampsUpRightBeforeItsWorkingSets() throws {
        let main = try mainLift()
        let session = try pushSession(history: [key(main.name): [lifted(28, 135)]])
        let steps = lifting(session)
        let workingIndex = steps.firstIndex { $0.name == main.name && !WorkoutWarmUpSets.isWarmUpSet($0) }
        let index = try #require(workingIndex)
        let working = steps[index]
        let prescription = try #require(working.guidance?.prescription)
        let equipment = try #require(working.guidance?.equipment)
        let expected = WorkoutWarmUpSets.sets(working: prescription.suggested, equipment: equipment, unit: prescription.unit)
        let warmUps = steps.filter { WorkoutWarmUpSets.isWarmUpSet($0) }
        #expect(!expected.isEmpty)
        #expect(warmUps.count == expected.count)
        let before = Array(steps[max(0, index - expected.count)..<index]).map(\.id)
        let warmUpIDs = warmUps.map(\.id)
        #expect(before == warmUpIDs, "the warm-ups sit right before the lift")
        let weights = warmUps.map { $0.guidance?.prescription?.suggested }
        let expectedWeights = expected.map { Optional($0.weight) }
        #expect(weights == expectedWeights)
        let names = Set(warmUps.map(\.name))
        let expectedNames: Set<String> = [main.name]
        #expect(names == expectedNames)
        let named = session.catalogExerciseNames.filter { $0 == main.name }.count
        #expect(named == 1, "the AI adjuster and the progression count see the lift once")
        #expect(session.suggestion.exercises.contains("\(main.name) - 1 x 8 (ramp-up)"))
    }

    @Test func warmUpSetsStayOffWhenSwitchedOffOnALightDayAndWithoutAWeight() throws {
        let main = try mainLift()
        let history = [key(main.name): [lifted(28, 135)]]
        let off = try pushSession(history: history, warmUpSets: false)
        let light = try pushSession(history: history, intensity: .light)
        let noWeightYet = try pushSession()
        for session in [off, light, noWeightYet] {
            let count = lifting(session).filter { WorkoutWarmUpSets.isWarmUpSet($0) }.count
            #expect(count == 0)
        }
    }

    @Test func accessoriesNeverRampUp() throws {
        let baseline = lifting(try pushSession(warmUpSets: false))
        var history: [String: [LiftExposure]] = [:]
        for step in baseline { history[key(step.name)] = [lifted(28, 100)] }
        let steps = lifting(try pushSession(history: history))
        let accessories = Set(baseline.filter { $0.role != .main }.map(\.name))
        let ramped = Set(steps.filter { WorkoutWarmUpSets.isWarmUpSet($0) }.map(\.name))
        #expect(!ramped.isEmpty)
        #expect(ramped.isDisjoint(with: accessories))
        let offMain = steps.filter { WorkoutWarmUpSets.isWarmUpSet($0) && $0.role != .main }
        #expect(offMain.isEmpty)
    }

    @Test func aCalibratedLiftKeepsItsOwnRampAndGetsNoSecond() throws {
        let main = try mainLift()
        let history = [key(main.name): [lifted(21, 135, reps: 10), lifted(28, 135, reps: 10)]]
        // The monthly strength check runs for strength and sports prep (G7).
        let session = try pushSession(history: history, calibrationDue: true, goal: .strength)
        let steps = lifting(session).filter { $0.name == main.name }
        let tags = steps.map { $0.guidance?.calibration }
        let expected: [CalibrationStep?] = [.ramp, .ramp, .ramp, .test]
        #expect(tags == expected)
        let warmUps = steps.filter { WorkoutWarmUpSets.isWarmUpSet($0) }
        #expect(warmUps.isEmpty)
    }

    // MARK: - Seams

    @Test func theEditorHidesWarmUpsAndPutsThemBackInFrontOfTheirLift() {
        let squat = planned()
        let bench = planned("Bench press")
        let row = planned("Cable row", role: .accessory)
        let original = WorkoutWarmUpSets.steps(for: squat, pattern: .squat) + [squat]
            + WorkoutWarmUpSets.steps(for: bench, pattern: .push) + [bench, row]
        let rows = WorkoutWarmUpSets.removingWarmUpSets(from: original).map(\.name)
        #expect(rows == ["Back squat", "Bench press", "Cable row"])
        let saved = WorkoutWarmUpSets.reattach([bench, squat], from: original)
        let names = saved.map(\.name)
        let flags = saved.map { WorkoutWarmUpSets.isWarmUpSet($0) }
        #expect(names == ["Bench press", "Bench press", "Bench press", "Bench press",
                          "Back squat", "Back squat", "Back squat", "Back squat"])
        #expect(flags == [true, true, true, false, true, true, true, false])
        let added = WorkoutWarmUpSets.reattach([planned("Deadlift")], from: original)
        #expect(added.count == 1, "a lift added in the editor gets none")
    }

    @Test func aCalibrationRampIsNotAWarmUpSetForTheBudget() {
        let calibrationRamp = planned(calibration: .ramp)
        #expect(!WorkoutWarmUpSets.isWarmUpSet(calibrationRamp))
        #expect(WorkoutWarmUpSets.removingWarmUpSets(from: [calibrationRamp]).count == 1)
    }

    // MARK: - The record

    @Test func aRunLogsWarmUpSetsAsRampUpsThatNoEstimateReads() throws {
        let squat = planned()
        let state = runState(WorkoutWarmUpSets.steps(for: squat, pattern: .squat) + [squat])
        let log = try #require(GuidedRunLoadLog.log(for: state))
        let tags = log.results.map(\.calibration)
        let expectedTags: [CalibrationStep?] = [.ramp, .ramp, .ramp, nil]
        #expect(tags == expectedTags)
        #expect(log.text.contains("Back squat - 1 x 8 @ 45 lb (ramp-up)"))
        #expect(log.text.contains("Back squat - 3 x 8 @ 135 lb"))
        let exposures = log.results.map { LiftExposure(date: day(0), result: $0) }
        let rampMaxes = exposures.prefix(3).compactMap { WorkoutLoadEngine.estimatedMax(of: $0, in: .lb) }
        #expect(rampMaxes.isEmpty)
        let withRamps = WorkoutLoadEngine.estimate(from: exposures, unit: .lb, today: day(1))
        let withoutRamps = WorkoutLoadEngine.estimate(from: Array(exposures.suffix(1)), unit: .lb, today: day(1))
        #expect(withRamps != nil)
        #expect(withRamps == withoutRamps)
        func next(_ history: [LiftExposure]) -> LiftPlan {
            WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
                scheme: RepScheme(low: 8, high: 12), baseSets: 3, exposures: history, equipment: .barbell,
                isLowerBody: true, defaultUnit: .lb, today: day(2)
            ))
        }
        let afterAll = next(exposures)
        let afterWorking = next(Array(exposures.suffix(1)))
        #expect(afterAll == afterWorking, "the next prescription anchors on the working sets")
    }

    @Test func warmUpSetsAreNeverPlateauEvidenceNorCrowdTheCap() {
        // Nine flat weeks, three sessions a week: a stall for a beginner whose age is known.
        let stalled = (0..<9).flatMap { week in [0, 2, 4].map { lifted(week * 7 + $0, 135) } }
        var ramped: [LiftExposure] = []
        for session in stalled {
            let offset = Int(session.date.timeIntervalSince(Self.base) / 86_400)
            ramped += [lifted(offset, 55, calibration: .ramp), lifted(offset, 80, reps: 5, calibration: .ramp),
                       lifted(offset, 110, reps: 3, calibration: .ramp), session]
        }
        // 108 exposures, over the 64 a lift keeps: the ramps leave before the cap, not after.
        #expect(ramped.count > WorkoutLoadEngine.maxExposuresPerLift)
        let profile = TrendProfile(trainingAge: TrainingAge(weeks: 1 + 60.0 / 7))
        let plain = WorkoutPlateau.status(of: stalled, unit: .lb, today: day(62), profile: profile)
        let withWarmUps = WorkoutPlateau.status(of: ramped, unit: .lb, today: day(62), profile: profile)
        let state = plain?.state
        #expect(state == .stalled)
        #expect(withWarmUps == plain)
    }

    @Test func handLoggedAndHistoryReadersSkipRampUpLines() throws {
        let ramp = WorkoutLoadContextBuilder.handLoggedExposure("Back squat - 1 x 8 @ 55 lb (ramp-up)", date: day(0))
        let working = WorkoutLoadContextBuilder.handLoggedExposure("Back squat - 3 x 8 @ 135 lb", date: day(0))
        let rampIsNil = ramp == nil
        let workingWeight = working?.exposure.weight
        #expect(rampIsNil)
        #expect(workingWeight == 135)
        #expect(WorkoutWarmUpSets.isRampLine("Back squat - 1 x 8 @ 55 lb (ramp-up)"))
        #expect(!WorkoutWarmUpSets.isRampLine("Back squat - 3 x 8 @ 135 lb"))

        var legs = FernletDay(date: "2026-10-20")
        legs.workouts = [Workout(
            name: "Legs", type: .lower,
            exercises: "Back squat - 1 x 8 @ 55 lb (ramp-up)\nBack squat - 1 x 5 @ 80 lb (ramp-up)\nBack squat - 3 x 8 @ 135 lb",
            rpe: nil, notes: "", duration: 40, intensity: .moderate
        )]
        let rollup = FernletStore.rollUpExerciseHistory(days: [legs])
        let squat = try #require(rollup.entries.first)
        #expect(rollup.entries.count == 1)
        #expect(squat.totalSets == 3, "warm-up sets are not working sets")
        #expect(squat.lastWeight == 135)
        #expect(rollup.unparsedLines == 0)
    }

    @Test func theSettingIsSyncedOnlyOnceChosen() throws {
        let fresh = FernletSettings()
        #expect(fresh.workoutWarmUpSets == nil)
        let freshObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        let freshHasKey = freshObject["workoutWarmUpSets"] != nil
        #expect(!freshHasKey, "an untouched setting leaves the blob's shape alone")
        var chosen = fresh
        chosen.workoutWarmUpSets = false
        let back = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(chosen))
        #expect(back.workoutWarmUpSets == false)
    }

    // MARK: - The run

    @Test func theRunnerCountsWarmUpSetsAndTheLiftsApart() throws {
        var state = runState(squatSteps())
        let first = try #require(state.warmUpPosition)
        #expect(first.index == 1)
        #expect(first.count == 3)
        #expect(state.blockPosition.index == 1)
        #expect(state.blockPosition.count == 2, "warm-up sets are not exercises")
        state.markSetDone(now: Date())
        let second = try #require(state.warmUpPosition)
        #expect(state.exerciseIndex == 1)
        #expect(state.isWorking, "a warm-up set is one set: no rest, straight on")
        #expect(second.index == 2)
        state.exerciseIndex = 3
        let onLift = state.warmUpPosition == nil
        #expect(onLift)
        #expect(state.blockPosition.index == 1)
        state.exerciseIndex = 4
        #expect(state.blockPosition.index == 2)
    }

    @Test func skipWarmUpSetsGoesStraightToTheWorkingSetsAndLeavesNoTrace() throws {
        var state = runState(squatSteps())
        state.markSetDone(now: Date())
        #expect(state.canSkipWarmUpSets)
        state.skipWarmUpSets(now: Date())
        #expect(state.exerciseIndex == 3)
        #expect(state.currentSet == 1)
        #expect(state.isWorking)
        #expect(!state.canSkipWarmUpSets)
        let skipped = state.exercises.prefix(3).map { $0.tracking?.skipped == true }
        #expect(skipped == [false, true, true])
        let log = try #require(GuidedRunLoadLog.log(for: state))
        #expect(!log.text.contains("skipped"))
        let rampLines = log.text.split(separator: "\n").filter { $0.contains("(ramp-up)") }.count
        #expect(rampLines == 1, "the one warm-up set done stays logged")
        let tags = log.results.map(\.calibration)
        let expected: [CalibrationStep?] = [.ramp, nil, nil]
        #expect(tags == expected)
    }

    @Test func voiceOverNamesEachWarmUpSetAndTheWorkingSets() {
        let start = runState(squatSteps())
        var second = start
        second.markSetDone(now: Date())
        #expect(words(GuidedRunAnnouncement.spoken(from: start, to: second)) == "Warm-up set 2 of 3: Back squat.")
        var lastWarmUp = start
        lastWarmUp.exerciseIndex = 2
        var working = lastWarmUp
        working.markSetDone(now: Date())
        #expect(words(GuidedRunAnnouncement.spoken(from: lastWarmUp, to: working)) == "Working sets: Back squat. Set 1 of 3.")
        var skipped = start
        skipped.skipWarmUpSets(now: Date())
        #expect(words(GuidedRunAnnouncement.spoken(from: start, to: skipped)) == "Working sets: Back squat. Set 1 of 3.")
    }

    @Test func spokenCuesNameTheWarmUpSetAndItsWeight() throws {
        let start = runState(squatSteps())
        var second = start
        second.markSetDone(now: Date())
        let line = try #require(plain(GuidedRunSpokenCue.move(from: start, to: second, cause: .setDone)))
        #expect(line.hasPrefix("Warm-up set 2 of 3: Back squat."))
        #expect(line.contains("80 pounds"))
    }

    @Test func planListsFoldALiftsWarmUpsIntoOneRow() {
        let steps = squatSteps()
        let rows = GuidedPlanRow.rows(steps)
        let counts = rows.map(\.warmUpCount)
        #expect(counts == [3, 0, 0])
        #expect(GuidedPlanRow.movementCount(steps) == 2)
    }
}

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins load-aware progression, the owner's spec of 2026-10-19: the estimate (Epley with reps in
/// reserve), confidence and the range it sets, the next prescription from the last result, the
/// override question, the plateau rule and its staged response, the monthly calibration, and the
/// persisted result's round trip.
@MainActor
struct WorkoutLoadEngineTests {

    // MARK: - Fixtures

    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    /// One structured session of a lift, inside a range around its weight unless told otherwise.
    func session(
        _ offset: Int, _ weight: Double?, reps: [Int], target: Int, range: (Double, Double)? = nil,
        effort: ExerciseEffort? = nil, reason: OverrideReason? = nil, calibration: CalibrationStep? = nil,
        easier: Bool = false, compounds: Int = 0, structured: Bool = true
    ) -> LiftExposure {
        let bounds = range ?? weight.map { ($0 - 10, $0 + 10) }
        return LiftExposure(
            date: day(offset), weight: weight, unit: weight == nil ? nil : .lb, targetReps: target, repsPerSet: reps,
            effort: effort, rangeLow: bounds?.0, rangeHigh: bounds?.1, overrideReason: reason,
            calibration: calibration, easierSession: easier, compoundsBefore: compounds, structured: structured
        )
    }

    func plan(
        _ history: [LiftExposure], scheme: RepScheme = RepScheme(low: 8, high: 12), sets: Int = 3,
        equipment: Equipment? = .barbell, lowerBody: Bool = false, today: Int = 30
    ) -> LiftPlan {
        WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: scheme, baseSets: sets, exposures: history, equipment: equipment,
            isLowerBody: lowerBody, defaultUnit: .lb, today: day(today)
        ))
    }

    /// Four weeks of 135 lb × 9 (target 10, missed) after a best of 135 × 10 — a stall.
    func stalledHistory() -> [LiftExposure] {
        [session(0, 135, reps: [10, 10, 10], target: 10)]
            + [7, 14, 21, 28].map { session($0, 135, reps: [9, 9, 9], target: 10) }
    }

    // MARK: - Estimate

    @Test func repSchemeReadsFixedAndRangedReps() {
        #expect(RepScheme("5") == RepScheme(low: 5, high: 5))
        #expect(RepScheme("8-12") == RepScheme(low: 8, high: 12))
        #expect(RepScheme("40 s") == nil)
        #expect(RepScheme("12-8") == nil)
    }

    @Test func estimatedMaxAddsRepsInReserveAndTrustsOnlyWorkingSets() throws {
        let good = try #require(WorkoutLoadEngine.estimatedMax(of: session(0, 100, reps: [8, 8, 8], target: 8), in: .lb))
        #expect(abs(good - 100 * (1 + 10.0 / 30)) < 0.001)
        let tough = try #require(WorkoutLoadEngine.estimatedMax(of: session(0, 100, reps: [8, 8, 8], target: 8, effort: .tough), in: .lb))
        #expect(abs(tough - 100 * (1 + 8.0 / 30)) < 0.001)
        // A missed set was a set to the limit: no reps in reserve.
        let missed = try #require(WorkoutLoadEngine.estimatedMax(of: session(0, 100, reps: [8, 8, 6], target: 8), in: .lb))
        #expect(abs(missed - tough) < 0.001)
        #expect(WorkoutLoadEngine.estimatedMax(of: session(0, 100, reps: [13], target: 13), in: .lb) == nil)
        #expect(WorkoutLoadEngine.estimatedMax(of: session(0, 100, reps: [8], target: 8, calibration: .ramp), in: .lb) == nil)
        #expect(WorkoutLoadEngine.estimatedMax(of: session(0, 100, reps: [8], target: 8, easier: true), in: .lb) == nil)
    }

    @Test func confidenceFollowsHowMuchAndHowConsistentTheHistoryIs() throws {
        let three = [14, 21, 28].map { session($0, 135, reps: [10, 10, 10], target: 10) }
        #expect(try #require(WorkoutLoadEngine.estimate(from: three, unit: .lb, today: day(30))).confidence == .high)
        #expect(try #require(WorkoutLoadEngine.estimate(from: Array(three.suffix(2)), unit: .lb, today: day(30))).confidence == .medium)
        #expect(try #require(WorkoutLoadEngine.estimate(from: [three[2]], unit: .lb, today: day(30))).confidence == .low)
        // Older than eight weeks: nothing to go on.
        #expect(WorkoutLoadEngine.estimate(from: three, unit: .lb, today: day(100)) == nil)
    }

    @Test func twoOverridesTheSameWayRecenterTheEstimateOnThePicks() throws {
        let picks = [21, 28].map { session($0, 150, reps: [10, 10, 10], target: 10, range: (125, 145)) }
        let history = [session(14, 135, reps: [10, 10, 10], target: 10)] + picks
        let estimate = try #require(WorkoutLoadEngine.estimate(from: history, unit: .lb, today: day(30)))
        #expect(estimate.recentered)
        #expect(estimate.confidence == .low)
        #expect(abs(estimate.oneRepMax - 150 * (1 + 12.0 / 30)) < 0.001)
    }

    // MARK: - Range

    @Test func rangeWidthFollowsConfidenceOnTheEquipmentSteps() throws {
        let low = try #require(WorkoutLoadEngine.prescription(suggested: 100, confidence: .low, step: 5, unit: .lb))
        #expect((low.low, low.high, low.suggested) == (90, 110, 100))
        let medium = try #require(WorkoutLoadEngine.prescription(suggested: 100, confidence: .medium, step: 5, unit: .lb))
        #expect((medium.low, medium.high) == (95, 105))
        let high = try #require(WorkoutLoadEngine.prescription(suggested: 100, confidence: .high, step: 5, unit: .lb))
        #expect((high.low, high.high) == (100, 105))
        let dumbbell = try #require(WorkoutLoadEngine.prescription(suggested: 20, confidence: .low, step: 2, unit: .kg))
        #expect((dumbbell.low, dumbbell.high) == (18, 22))
        #expect(high.rangeText == "100–105 lb")
        #expect(WorkoutLoadEngine.step(for: .dumbbell, unit: .kg) == 2)
        #expect(WorkoutLoadEngine.step(for: .bodyweight, unit: .lb) == nil)
    }

    // MARK: - Next prescription

    @Test func completedSetsAddARepThenWeightAtTheTop() throws {
        let midway = plan([session(28, 135, reps: [9, 9, 9], target: 9)])
        #expect((midway.reps, midway.change) == (10, .moreReps))
        #expect(midway.prescription?.suggested == 135)

        let top = plan([session(28, 135, reps: [12, 12, 12], target: 12)])
        #expect((top.reps, top.change) == (8, .backToBottom))
        #expect(top.prescription?.suggested == 140)

        let squat = plan([session(28, 225, reps: [5, 5, 5, 5], target: 5)], scheme: RepScheme(low: 5, high: 5), lowerBody: true)
        #expect(squat.change == .addWeight)
        #expect(squat.prescription?.suggested == 235)
    }

    @Test func toughOrSmallMissesRepeatAndRealMissesGoLighter() {
        let tough = plan([session(28, 135, reps: [10, 10, 10], target: 10, effort: .tough)])
        #expect((tough.reps, tough.change, tough.prescription?.suggested) == (10, .same, 135))

        let minor = plan([session(28, 135, reps: [10, 10, 8], target: 10)])
        #expect((minor.change, minor.prescription?.suggested) == (.same, 135))

        let real = plan([session(28, 135, reps: [10, 8, 7], target: 10)])
        #expect((real.change, real.prescription?.suggested) == (.lighter, 130))

        let third = plan([20, 24, 28].map { session($0, 135, reps: [10, 10, 9], target: 10) })
        #expect((third.change, third.sets, third.prescription?.suggested) == (.lighterFewerSets, 2, 120))
    }

    @Test func aLongBreakRestartsALittleLighter() {
        let back = plan([session(0, 135, reps: [10, 10, 10], target: 10)], today: 35)
        #expect((back.change, back.reps, back.prescription?.suggested) == (.afterBreak, 10, 120))
    }

    @Test func painHoldsAndEquipmentLimitsProgressOnReps() {
        let pain = plan([session(28, 135, reps: [10, 10, 10], target: 10, reason: .pain)])
        #expect((pain.change, pain.reps, pain.prescription?.suggested) == (.holdForPain, 10, 135))

        let capped = plan([session(28, 135, reps: [12, 12, 12], target: 12, reason: .equipment)])
        #expect((capped.change, capped.reps, capped.prescription?.suggested) == (.holdForEquipment, 13, 135))
    }

    @Test func liftsWithoutALoadProgressRepsThenSets() {
        let pushUps = plan([session(28, nil, reps: [12, 12, 12], target: 12)], equipment: nil)
        #expect((pushUps.change, pushUps.reps, pushUps.sets) == (.moreSets, 12, 4))
        #expect(pushUps.prescription == nil)
    }

    @Test func aFirstSessionAsksForAPickAndACalibrationRebaselines() {
        let first = plan([])
        #expect((first.change, first.reps) == (.firstTime, 8))
        #expect(first.prescription == nil)

        let calibrated = plan([
            session(20, 100, reps: [8, 8, 8], target: 8),
            session(28, 115, reps: [7], target: 5, calibration: .test),
        ])
        // Estimate: 100 × (1 + 10/30) and 115 × (1 + 8.5/30), weighted 1:2 ≈ 142.8; nine reps with
        // two in the tank ≈ 104.5, on the 5 lb step → 105.
        #expect(calibrated.change == .recalibrated)
        #expect(calibrated.reps == 9)
        #expect(calibrated.prescription?.suggested == 105)
    }

    @Test func aGoalChangeRebaselinesTheReps() {
        let switched = plan([session(28, 135, reps: [10, 10, 10], target: 10)], scheme: RepScheme(low: 5, high: 5))
        #expect((switched.change, switched.reps) == (.recalibrated, 5))
    }

    @Test func repeatedOverridesAskWhyOnceAMonth() {
        let overrides = [21, 28].map { session($0, 150, reps: [10, 10, 10], target: 10, range: (125, 145)) }
        #expect(WorkoutLoadEngine.askReasonOnOverride(overrides, today: day(30)))
        let answered = overrides + [session(29, 150, reps: [10], target: 10, range: (125, 145), reason: .preference)]
        #expect(!WorkoutLoadEngine.askReasonOnOverride(answered, today: day(30)))
        #expect(!WorkoutLoadEngine.askReasonOnOverride([overrides[0]], today: day(30)))
    }

    // MARK: - Plateau

    @Test func aStallAfterSteadyTrainingIsAPlateauStartingWithAnEasierSession() throws {
        let status = try #require(WorkoutPlateau.status(of: stalledHistory(), unit: .lb, today: day(30)))
        #expect(status.stage == .easierSession)
        #expect(status.sessionsSinceOnset == 0)
        #expect(status.weeksHeld == 4)
        let next = stalledHistory() + [session(32, 120, reps: [9, 9], target: 9, easier: true)]
        #expect(try #require(WorkoutPlateau.status(of: next, unit: .lb, today: day(33))).stage == .recover)
    }

    @Test func progressGapsOverridesAndFatigueAreNotPlateaus() {
        let climbing = [0, 7, 14, 21, 28].enumerated().map { session($1, 135, reps: [8 + $0, 8 + $0, 8 + $0], target: 8 + $0) }
        #expect(WorkoutPlateau.status(of: climbing, unit: .lb, today: day(30)) == nil)

        let gappy = [session(0, 135, reps: [10, 10, 10], target: 10)]
            + [10, 12, 30, 32].map { session($0, 135, reps: [9, 9, 9], target: 10) }
        #expect(WorkoutPlateau.status(of: gappy, unit: .lb, today: day(33)) == nil)

        var overridden = stalledHistory()
        overridden[3].weight = 160
        overridden[4].weight = 160
        #expect(WorkoutPlateau.status(of: overridden, unit: .lb, today: day(30)) == nil)

        let tired = [session(0, 135, reps: [10, 10, 10], target: 10)]
            + [7, 14, 21, 28].map { session($0, 135, reps: [9, 9, 9], target: 10, compounds: 2) }
        #expect(WorkoutPlateau.status(of: tired, unit: .lb, today: day(30)) == nil)

        #expect(WorkoutPlateau.status(of: stalledHistory(), unit: .lb, today: day(28 + 43)) == nil)
    }

    @Test func aLiftWithoutALoadPlateausOnReps() {
        let pushUps = [session(0, nil, reps: [20, 20], target: 20, structured: false)]
            + [7, 14, 21, 28].map { session($0, nil, reps: [18, 18], target: 18, structured: false) }
        #expect(WorkoutPlateau.status(of: pushUps, unit: .lb, today: day(30))?.stage == .easierSession)
    }

    @Test func theResponseWalksRestThenSupportThenAVariation() {
        let last = day(40)
        #expect(WorkoutPlateau.stage(sessionsSinceOnset: 1, lastSession: last, today: day(41)) == .recover)
        #expect(WorkoutPlateau.stage(sessionsSinceOnset: 2, lastSession: last, today: day(41)) == .supportWork)
        #expect(WorkoutPlateau.stage(sessionsSinceOnset: 5, lastSession: last, today: day(41)) == .supportWork)
        #expect(WorkoutPlateau.stage(sessionsSinceOnset: 6, lastSession: last, today: day(50)) == .variation)
        #expect(WorkoutPlateau.stage(sessionsSinceOnset: 6, lastSession: last, today: day(68)) == .afterVariation)
        #expect(WorkoutPlateau.stage(sessionsSinceOnset: 7, lastSession: last, today: day(41)) == .easierSession)
    }

    @Test func helperMusclesFollowTheOwnersListThenTheCatalog() throws {
        func helpers(_ name: String) throws -> [MuscleGroup] {
            WorkoutPlateau.helperMuscles(for: try #require(WorkoutExerciseCatalog.exercise(named: name)))
        }
        #expect(try Array(helpers("Bench press").prefix(3)) == [.triceps, .upperBack, .rearDelts])
        #expect(try Array(helpers("Back squat").prefix(4)) == [.glutes, .hamstrings, .abs, .upperBack])
        #expect(try Array(helpers("Deadlift").prefix(4)) == [.glutes, .hamstrings, .forearms, .lats])
        #expect(try Array(helpers("Overhead press").prefix(3)) == [.triceps, .sideDelts, .upperBack])
        #expect(try Array(helpers("Barbell row").prefix(3)) == [.biceps, .rearDelts, .forearms])
    }

    @Test func theRestCheckSpeaksOnlyWhenSleepOrProteinRanLow() {
        #expect(RecoverySummary(averageSleepHours: 6.2, sleepNights: 4).sleepIsLow)
        #expect(!RecoverySummary(averageSleepHours: 6.2, sleepNights: 2).sleepIsLow)
        #expect(!RecoverySummary(averageSleepHours: 7.5, sleepNights: 9).sleepIsLow)
        #expect(RecoverySummary(averageProteinRatio: 0.7, proteinDays: 5).proteinIsLow)
        #expect(!RecoverySummary(averageProteinRatio: 0.7, proteinDays: 3).proteinIsLow)
        #expect(!RecoverySummary.unknown.sleepIsLow && !RecoverySummary.unknown.proteinIsLow)
    }

    // MARK: - Calibration

    @Test func calibrationIsMonthlyAndNeverForCoachedOrLightDays() {
        #expect(WorkoutCalibration.isDue(CalibrationSettings(), intensity: .moderate, today: day(0)))
        #expect(!WorkoutCalibration.isDue(CalibrationSettings(hasCoach: true), intensity: .moderate, today: day(0)))
        #expect(!WorkoutCalibration.isDue(CalibrationSettings(), intensity: .light, today: day(0)))
        #expect(!WorkoutCalibration.isDue(CalibrationSettings(lastCalibration: day(0)), intensity: .hard, today: day(20)))
        #expect(WorkoutCalibration.isDue(CalibrationSettings(lastCalibration: day(0)), intensity: .hard, today: day(28)))
        #expect(!WorkoutCalibration.isEligible([session(0, 100, reps: [8], target: 8)]))
        #expect(WorkoutCalibration.isEligible([session(0, 100, reps: [8], target: 8), session(7, 100, reps: [8], target: 8)]))
    }

    @Test func calibrationKindRespectsTheOptInAndTheExperience() {
        var profile = WorkoutProfile(experience: .beginner, oneRepMaxTesting: true)
        #expect(WorkoutCalibration.kind(profile: profile, confidence: .medium) == .submaximal)
        profile.experience = .intermediate
        #expect(WorkoutCalibration.kind(profile: profile, confidence: .medium) == .oneRepMax)
        profile.oneRepMaxTesting = false
        #expect(WorkoutCalibration.kind(profile: profile, confidence: .high) == .strengthCheck)
    }

    @Test func calibrationSetsRampToATestOrToThreeSingles() {
        let submaximal = WorkoutCalibration.sets(kind: .submaximal, oneRepMax: 200, todaysSuggested: nil, todaysReps: 8, step: 5)
        #expect(submaximal.map(\.step) == [.ramp, .ramp, .ramp, .test])
        #expect(submaximal.map(\.reps) == [8, 4, 2, 5])
        #expect(submaximal.last?.weight == 165)
        #expect(zip(submaximal, submaximal.dropFirst()).allSatisfy { $0.weight < $1.weight })

        let check = WorkoutCalibration.sets(kind: .strengthCheck, oneRepMax: 200, todaysSuggested: 140, todaysReps: 8, step: 5)
        #expect(check == [CalibrationSet(step: .test, reps: 8, weight: 140, restSeconds: WorkoutCalibration.testRestSeconds)])

        let max = WorkoutCalibration.sets(kind: .oneRepMax, oneRepMax: 200, todaysSuggested: nil, todaysReps: 8, step: 5)
        #expect(max.filter { $0.step == .attempt }.map(\.weight) == [200, 205, 210])
        #expect(max.count == 7)
    }

    // MARK: - The persisted result

    @Test func aResultLogsALineTheHistoryParserReadsBack() throws {
        let done = ExerciseResult(name: "Bench press", prescribedSets: 3, targetReps: 8, selectedWeight: 105, unit: .lb)
        #expect(done.loggedLine == "Bench press - 3 x 8 @ 105 lb")
        let parsed = try #require(ExerciseLineParser.parse(done.loggedLine))
        #expect((parsed.sets, parsed.repsCount, parsed.weight, parsed.weightUnit) == (3, 8, 105, "lb"))

        let edited = ExerciseResult(name: "Bench press", prescribedSets: 3, targetReps: 8, selectedWeight: 62.5,
                                    unit: .kg, actualReps: [8, 8, 6])
        #expect(edited.loggedLine == "Bench press - 3 x 8 @ 62.5 kg (did 8, 8, 6)")
        #expect(try #require(ExerciseLineParser.parse(edited.loggedLine)).weight == 62.5)

        let test = ExerciseResult(name: "Squat", prescribedSets: 1, targetReps: 5, selectedWeight: 225, unit: .lb, calibration: .test)
        #expect(test.loggedLine == "Squat - 1 x 5 @ 225 lb (test set)")
    }

    @Test func resultsDecodeTolerantlyAndRoundTripOnTheWorkout() throws {
        let json = #"{"name":"Bench press","targetReps":8,"effortToken":"exhausted","actualReps":[8,7]}"#
        let result = try JSONDecoder().decode(ExerciseResult.self, from: Data(json.utf8))
        #expect(result.effort == nil)
        #expect(result.repsPerSet == [8, 7])
        #expect(result.prescribedSets == 0)

        let results = [ExerciseResult(name: "Bench press", prescribedSets: 3, targetReps: 8, selectedWeight: 105, unit: .lb)]
        let workout = Workout(name: "Push", type: .upper, exercises: "Bench press - 3 x 8 @ 105 lb", rpe: nil,
                              notes: "", duration: nil, intensity: .moderate, exerciseResults: results)
        let decoded = try JSONDecoder().decode(Workout.self, from: JSONEncoder().encode(workout))
        #expect(decoded.exerciseResults == results)

        let plain = Workout(name: "Push", type: .upper, exercises: "", rpe: nil, notes: "", duration: nil, intensity: .moderate)
        let encoded = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!encoded.contains("exerciseResults"))
        #expect(try JSONDecoder().decode(Workout.self, from: Data(encoded.utf8)).exerciseResults == nil)
    }
}

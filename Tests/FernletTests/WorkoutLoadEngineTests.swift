import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins load-aware progression, the owner's spec of 2026-10-19 with round 2's changes (2026-10-20):
/// the estimate (Epley with reps in reserve), confidence and the range it sets, the next prescription
/// from the last result (a flagged miss holds), the override question, the trend's plateau and dip
/// calls and the ladder they walk, the monthly calibration, and the persisted result's round trip.
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
        equipment: Equipment? = .barbell, lowerBody: Bool = false, today: Int = 30, tier: TrainingTier = .beginner
    ) -> LiftPlan {
        WorkoutLoadEngine.plan(WorkoutLoadEngine.LiftInputs(
            scheme: scheme, baseSets: sets, exposures: history, equipment: equipment,
            isLowerBody: lowerBody, defaultUnit: .lb, today: day(today), tier: tier
        ))
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

    @Test func theWeightStepIsFixedNotAPercentage() {
        // G4: one step on an upper-body lift however heavy (2.5 % of 300 lb would have been 10 lb).
        let bench = plan([session(28, 300, reps: [12, 12, 12], target: 12)])
        #expect((bench.change, bench.prescription?.suggested) == (.backToBottom, 305))
        // One or two steps on a lower-body lift: two once 5 % of the load rounds to two, never more.
        let fives = RepScheme(low: 5, high: 5)
        let heavy = plan([session(28, 400, reps: [5, 5, 5], target: 5)], scheme: fives, lowerBody: true)
        #expect(heavy.prescription?.suggested == 410)
        let light = plan([session(28, 100, reps: [5, 5, 5], target: 5)], scheme: fives, lowerBody: true)
        #expect(light.prescription?.suggested == 105)
    }

    @Test func progressionWaitsForTwoGoodSessionsPastSixMonthsAndForTheBlockPastTwoYears() {
        let novice = plan([session(28, 135, reps: [9, 9, 9], target: 9)])
        #expect((novice.change, novice.reps) == (.moreReps, 10))
        // G3: from six months, two successful sessions in a row at the same prescription (two-for-two).
        let once = plan([session(28, 135, reps: [9, 9, 9], target: 9)], tier: .intermediate)
        #expect((once.change, once.reps, once.prescription?.suggested) == (.confirming, 9, 135))
        let twice = plan([24, 28].map { session($0, 135, reps: [9, 9, 9], target: 9) }, tier: .intermediate)
        #expect((twice.change, twice.reps) == (.moreReps, 10))
        let afterTough = plan([session(24, 135, reps: [9, 9, 9], target: 9, effort: .tough),
                               session(28, 135, reps: [9, 9, 9], target: 9)], tier: .intermediate)
        #expect(afterTough.change == .confirming)
        // Past two years, once per block: the load held four weeks, the last two sessions good.
        let midBlock = plan([20, 24, 28].map { session($0, 135, reps: [9, 9, 9], target: 9) }, tier: .advanced)
        #expect((midBlock.change, midBlock.reps) == (.blockHold, 9))
        let blockDone = plan([0, 14, 28].map { session($0, 135, reps: [9, 9, 9], target: 9) }, tier: .advanced)
        #expect((blockDone.change, blockDone.reps) == (.moreReps, 10))
    }

    @Test func aMissRepeatsAndOnlyTwoUnflaggedMissesGoLighter() {
        let tough = plan([session(28, 135, reps: [10, 10, 10], target: 10, effort: .tough)])
        #expect((tough.reps, tough.change, tough.prescription?.suggested) == (10, .same, 135))

        let minor = plan([session(28, 135, reps: [10, 10, 8], target: 10)])
        #expect((minor.change, minor.prescription?.suggested) == (.same, 135))

        // One miss is mostly noise (G10): even a big one repeats the load.
        let real = plan([session(28, 135, reps: [10, 8, 7], target: 10)])
        #expect((real.change, real.prescription?.suggested) == (.same, 135))

        let second = plan([24, 28].map { session($0, 135, reps: [10, 8, 7], target: 10) })
        #expect((second.change, second.prescription?.suggested) == (.lighter, 130))

        let third = plan([20, 24, 28].map { session($0, 135, reps: [10, 10, 9], target: 10) })
        #expect((third.change, third.sets, third.prescription?.suggested) == (.lighterFewerSets, 2, 120))
    }

    @Test func aFlaggedMissHoldsTheLoadAndNeverCountsTowardACut() {
        func tired(_ offset: Int, light: Bool = false) -> LiftExposure {
            var miss = session(offset, 135, reps: [10, 8, 7], target: 10)
            miss.flag = light ? WorkoutSessionFlag(lightDay: true) : WorkoutSessionFlag(sleep: .shortNight)
            return miss
        }
        let missed = session(24, 135, reps: [10, 8, 7], target: 10)
        let afterShortNight = plan([missed, tired(28)])
        #expect((afterShortNight.change, afterShortNight.prescription?.suggested) == (.same, 135))
        let onALightDay = plan([missed, tired(28, light: true)])
        #expect(onALightDay.change == .same)
        // A flagged miss between two unflagged ones neither counts nor breaks the run.
        let between = plan([session(20, 135, reps: [10, 8, 7], target: 10), tired(24), session(28, 135, reps: [10, 8, 7], target: 10)])
        #expect((between.change, between.prescription?.suggested) == (.lighter, 130))
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

    // MARK: - Plateau (the trend, G1 and G5)

    /// Three sessions a week (days 0, 2 and 4 of each week) for `weeks` weeks, completed at 8 reps.
    func weekly(_ weeks: Int, weight: (Int) -> Double = { _ in 100 }) -> [LiftExposure] {
        (0..<weeks).flatMap { week in
            [0, 2, 4].map { session(week * 7 + $0, weight(week), reps: [8, 8, 8], target: 8) }
        }
    }

    /// A beginner whose known training age started with the history (step 2's setup answer).
    func knownAge(_ history: [LiftExposure]) -> TrendProfile {
        let weeks = 1 + (history.last?.date.timeIntervalSince(Self.base) ?? 0) / (7 * 86_400)
        return TrendProfile(trainingAge: TrainingAge(weeks: weeks))
    }

    @Test func aFlatLineAfterWeeksOfSteadyTrainingStallsAndStartsWithAFairRetest() throws {
        let eight = weekly(8)
        let slowing = try #require(WorkoutPlateau.status(of: eight, unit: .lb, today: day(55), profile: knownAge(eight)))
        #expect(slowing.state == .slowing)
        #expect(slowing.stage == nil)

        let nine = weekly(9)
        let status = try #require(WorkoutPlateau.status(of: nine, unit: .lb, today: day(62), profile: knownAge(nine)))
        #expect(status.state == .stalled)
        #expect(status.stage == .fairRetest)
        #expect(status.sessionsSinceOnset == 0)
        #expect(status.weeksHeld == 8)

        let ten = weekly(10)
        let next = try #require(WorkoutPlateau.status(of: ten, unit: .lb, today: day(69), profile: knownAge(ten)))
        #expect(next.stage == .loadingChange)
        #expect(next.sessionsSinceOnset == 3)
    }

    @Test func aStillClimbingLiftIsNoPlateauWhereTheOldRuleSawOne() {
        let climbing = weekly(9) { 100 + 5 * Double($0) }
        #expect(WorkoutPlateau.status(of: climbing, unit: .lb, today: day(62), profile: knownAge(climbing)) == nil)
    }

    @Test func aBreakOverridesAndBuriedSessionsAreNotPlateaus() {
        let flat = weekly(9)
        let profile = knownAge(flat)
        #expect(WorkoutPlateau.status(of: flat, unit: .lb, today: day(60 + 43), profile: profile) == nil)

        var overridden = flat
        overridden[25].weight = 130
        overridden[26].weight = 130
        #expect(WorkoutPlateau.status(of: overridden, unit: .lb, today: day(62), profile: profile) == nil)

        let buried = flat.map { exposure -> LiftExposure in
            var tired = exposure
            tired.compoundsBefore = 2
            return tired
        }
        #expect(WorkoutPlateau.status(of: buried, unit: .lb, today: day(62), profile: profile) == nil)
    }

    @Test func twoCleanSessionsWellUnderTheLineAreADipThatOneDeloadAnswers() throws {
        let history = weekly(6) { 100 + 5 * Double($0) } + [42, 44].map { session($0, 125, reps: [6, 6, 6], target: 8) }
        let status = try #require(WorkoutPlateau.status(of: history, unit: .lb, today: day(45), profile: knownAge(history)))
        #expect(status.state == .dipping)
        #expect(status.stage == nil)
        let deload = session(46, 125, reps: [8, 8], target: 8, easier: true)
        #expect(WorkoutPlateau.status(of: history + [deload], unit: .lb, today: day(47), profile: knownAge(history)) == nil)
    }

    @Test func lowSessionsAfterShortNightsOrOnLightDaysAreNeitherADipNorAStall() {
        for flag in [WorkoutSessionFlag(sleep: .shortNight), WorkoutSessionFlag(lightDay: true)] {
            let low = [42, 44].map { offset -> LiftExposure in
                var tired = session(offset, 125, reps: [6, 6, 6], target: 8)
                tired.flag = flag
                return tired
            }
            let history = weekly(6) { 100 + 5 * Double($0) } + low
            #expect(WorkoutPlateau.status(of: history, unit: .lb, today: day(45), profile: knownAge(history)) == nil)
        }
    }

    @Test func aLiftWithoutALoadStallsOnReps() throws {
        let pushUps = (0..<9).flatMap { week in
            [0, 2, 4].map { session(week * 7 + $0, nil, reps: [12, 12], target: 12, structured: false) }
        }
        let status = try #require(WorkoutPlateau.status(of: pushUps, unit: .lb, today: day(62), profile: knownAge(pushUps)))
        #expect(status.state == .stalled)
        #expect(status.stage == .fairRetest)
    }

    @Test func aSteadyLineInAnOlderLongTrainedLifterIsSuccessNeverAStall() {
        let older = LifterTraits(ageYears: 67)
        #expect(WorkoutTrend.expectedRate(age: .years(5), traits: older, lowerBody: false, levelKg: nil) == 0)
        #expect(WorkoutTrend.expectedRate(age: .years(5), traits: .unknown, lowerBody: false, levelKg: nil) == 0.025)
        let flat = weekly(16)
        let status = WorkoutPlateau.status(of: flat, unit: .lb, today: day(16 * 7),
                                           profile: TrendProfile(trainingAge: .years(5), traits: older))
        let state = status?.state
        #expect(state != .stalled)
    }

    @Test func theLadderWalksARetestALoadingChangeAVariantThenHoldsSteady() {
        let steps = [0, 1, 2, 7, 8, 15, 16, 40].map { WorkoutPlateau.stage(sessionsSinceOnset: $0) }
        let expected: [PlateauStage] = [
            .fairRetest, .fairRetest, .loadingChange, .loadingChange, .variant, .variant, .holdingSteady, .holdingSteady,
        ]
        #expect(steps == expected)
    }

    @Test func theOldLaddersTokensResolveToTheNearestNewStep() {
        #expect(PlateauStage(persistedToken: "easierSession") == .fairRetest)
        #expect(PlateauStage(persistedToken: "recover") == .fairRetest)
        #expect(PlateauStage(persistedToken: "supportWork") == .loadingChange)
        #expect(PlateauStage(persistedToken: "variation") == .variant)
        #expect(PlateauStage(persistedToken: "afterVariation") == .holdingSteady)
        #expect(PlateauStage(persistedToken: "variant") == .variant)
        #expect(PlateauStage(persistedToken: "deloadWeek") == nil)
        let unknown = PlateauStage.resolve(token: "deloadWeek", parkedToken: nil)
        #expect(unknown.value == .fairRetest)
        #expect(unknown.parkedToken == "deloadWeek")
        let legacy = PlateauStage.resolve(token: "supportWork", parkedToken: nil)
        #expect(legacy.value == .loadingChange)
        #expect(legacy.parkedToken == nil)
    }

    @Test func theProteinContextSpeaksOnlyWhenProteinRanLow() {
        #expect(RecoverySummary(averageProteinRatio: 0.7, proteinDays: 5).proteinIsLow)
        #expect(!RecoverySummary(averageProteinRatio: 0.7, proteinDays: 3).proteinIsLow)
        #expect(!RecoverySummary.unknown.proteinIsLow)
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

// WorkoutTrendTests.swift
// FernletTests
//
// Pins the plateau detector's parts (the owner's G1 and G10 picks, 2026-10-20) one by one: a session's
// score, when the trend restarts, the sleep flag's rule and its trims, the training-age tiers, the
// expected curve's b, and the too-early reading. The detector's behavior over many histories is
// WorkoutPlateauSimulationTests; what it does to a plan is WorkoutLoadPlanningTests.

import Foundation
import Testing
import FernletDomainModel

/// The trend detector's parts: session score, restarts, sleep flags, tiers, expected rate, too early.
struct WorkoutTrendTests {

    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    func day(_ offset: Int) -> Date { Self.base.addingTimeInterval(Double(offset) * 86_400) }

    func session(
        _ offset: Int, _ weight: Double?, reps: [Int], target: Int, effort: ExerciseEffort? = nil,
        calibration: CalibrationStep? = nil, flag: WorkoutSessionFlag? = nil
    ) -> LiftExposure {
        LiftExposure(date: day(offset), weight: weight, unit: weight == nil ? nil : .lb, targetReps: target,
                     repsPerSet: reps, effort: effort, calibration: calibration, structured: true, flag: flag)
    }

    // MARK: - The session score

    @Test func theScoreAveragesTheTopTwoSetsAtTenOrFewerRepsPlusReserve() throws {
        // 8 reps + 2 in reserve = 10: Epley 100 × (1 + 10/30).
        let both = try #require(WorkoutTrend.sessionScore(of: session(0, 100, reps: [8, 8, 8], target: 8), in: .lb))
        #expect(abs(both - 100 * (1 + 10.0 / 30)) < 0.001)
        // Two sets met the target (10 each), one fell short (6 + 0): the top two average.
        let mixed = try #require(WorkoutTrend.sessionScore(of: session(0, 100, reps: [8, 6, 8], target: 8), in: .lb))
        #expect(abs(mixed - 100 * (1 + 10.0 / 30)) < 0.001)
        // 10 and 11 reps plus 2 in reserve pass 10: only the 8-rep set is preferred.
        let preferred = try #require(WorkoutTrend.sessionScore(of: session(0, 100, reps: [10, 9, 8], target: 8), in: .lb))
        #expect(abs(preferred - 100 * (1 + 10.0 / 30)) < 0.001)
        // Past 12 reps plus reserve nothing qualifies.
        let tooMany = WorkoutTrend.sessionScore(of: session(0, 100, reps: [12, 12, 12], target: 12), in: .lb)
        #expect(tooMany == nil)
    }

    @Test func aTrueSingleScoresAtItsWeightAndRampSetsNeverScore() throws {
        let single = try #require(WorkoutTrend.sessionScore(of: session(0, 200, reps: [1], target: 1, calibration: .attempt), in: .lb))
        #expect(single == 200)
        let ramp = WorkoutTrend.sessionScore(of: session(0, 100, reps: [5], target: 5, calibration: .ramp), in: .lb)
        #expect(ramp == nil)
        let pushUps = try #require(WorkoutTrend.sessionScore(of: session(0, nil, reps: [15, 12, 10], target: 12), in: .lb))
        #expect(pushUps == 13.5)
    }

    @Test func theTrendRestartsWhenTheRepSchemeMovesOrAfterABreak() {
        let eights = (0..<5).map { session($0 * 3, 100, reps: [10, 10, 10], target: 10) }
        let fives = (5..<8).map { session($0 * 3, 130, reps: [5, 5, 5], target: 5) }
        #expect(WorkoutTrend.points(from: eights + fives, unit: .lb).count == 3)
        let back = [session(60, 100, reps: [10, 10, 10], target: 10), session(63, 100, reps: [10, 10, 10], target: 10)]
        #expect(WorkoutTrend.points(from: eights + back, unit: .lb).count == 2)
        let close = [session(15, 100, reps: [12, 12, 12], target: 12)]
        #expect(WorkoutTrend.points(from: eights + close, unit: .lb).count == 5, "12 reps beats the cap, so it scores nothing")
    }

    // MARK: - The sleep flag (G10)

    @Test func aShortNightIsSixHoursOrNinetyMinutesUnderTheMedian() {
        #expect(WorkoutSessionFlags.isShort(6.0, median: nil))
        #expect(!WorkoutSessionFlags.isShort(6.5, median: nil))
        #expect(WorkoutSessionFlags.isShort(7.0, median: 8.5))
        #expect(!WorkoutSessionFlags.isShort(7.1, median: 8.5))
        #expect(!WorkoutSessionFlags.isShort(0, median: 8.5))
        #expect(WorkoutSessionFlags.median(of: [8, 8, 8, 8]) == nil)
        #expect(WorkoutSessionFlags.median(of: [7, 8, 9, 8, 8]) == 8)
        #expect(WorkoutSessionFlags.median(of: [6, 7, 8, 9, 10, 11]) == 8.5)
    }

    @Test func twoShortNightsInARowMakeTheFirmerFlag() {
        let usual: [Double] = Array(repeating: 8, count: 14)
        #expect(WorkoutSessionFlags.sleepFlag(lastNight: 5.5, previousNight: 6, earlierNights: usual) == .shortNights)
        #expect(WorkoutSessionFlags.sleepFlag(lastNight: 5.5, previousNight: 7.5, earlierNights: usual) == .shortNight)
        #expect(WorkoutSessionFlags.sleepFlag(lastNight: 7.5, previousNight: 5, earlierNights: usual) == nil)
        #expect(WorkoutSessionFlags.sleepFlag(lastNight: nil, previousNight: 5, earlierNights: usual) == nil)
        // The firmer flag forgives the literature's full cost; one night or a light day, half of it.
        let firm = WorkoutSessionFlag(sleep: .shortNights)
        #expect(firm.trim(lowerBody: true) == 0.03 && firm.trim(lowerBody: false) == 0.015)
        let single = WorkoutSessionFlag(sleep: .shortNight)
        #expect(single.trim(lowerBody: true) == 0.015)
        #expect(WorkoutSessionFlag(lightDay: true).trim(lowerBody: false) == 0.0075)
        #expect(WorkoutSessionFlag.make(sleep: nil, lightDay: false) == nil)
    }

    // MARK: - Training age and the expected curve

    @Test func trainingAgeTiersAtSixMonthsAndTwoYears() {
        #expect(TrainingTier.tier(forWeeks: 25.9) == .beginner)
        #expect(TrainingTier.tier(forWeeks: 26) == .intermediate)
        #expect(TrainingTier.tier(forWeeks: 103.9) == .intermediate)
        #expect(TrainingTier.tier(forWeeks: 104) == .advanced)
        #expect(TrainingTier.beginner.minimumSessions == 5 && TrainingTier.intermediate.minimumSessions == 8)
        #expect(TrainingTier.advanced.minimumSessions == 12 && TrainingTier.advanced.minimumWeeks == 10)
        #expect(TrainingAge.years(2).tier == .advanced)
    }

    @Test func theExpectedRateFollowsTrainingAgeAndThePersonsTraits() {
        func rate(_ age: TrainingAge, _ traits: LifterTraits = .unknown, lowerBody: Bool = false, levelKg: Double? = nil) -> Double {
            WorkoutTrend.expectedRate(age: age, traits: traits, lowerBody: lowerBody, levelKg: levelKg)
        }
        #expect(rate(TrainingAge(weeks: 10)) == 0.10)
        #expect(rate(.years(1)) == 0.025)
        #expect(abs(rate(.years(1), LifterTraits(sex: .female)) - 0.025 * 1.15) < 1e-12)
        #expect(abs(rate(.years(1), LifterTraits(bodyWeightKg: 55)) - 0.025 * 1.1) < 1e-12)
        // A man pressing 1.4 × his body weight is strong; squatting 0.8 × it, weaker.
        #expect(abs(rate(.years(1), LifterTraits(sex: .male, bodyWeightKg: 80), levelKg: 112) - 0.025 * 0.8) < 1e-12)
        #expect(abs(rate(.years(1), LifterTraits(sex: .male, bodyWeightKg: 80), lowerBody: true, levelKg: 64) - 0.025 * 1.1) < 1e-12)
        // G9: long-trained and over 60, a steady line is the expected one.
        #expect(rate(.years(3), LifterTraits(ageYears: 64)) == 0)
        #expect(rate(TrainingAge(weeks: 10), LifterTraits(ageYears: 64)) == 0.10)
    }

    // MARK: - Too early

    @Test func halfTheWindowFlaggedIsTooEarlyToTell() {
        let points = (0..<10).map { index in
            TrendPoint(date: day(index * 3), score: 100,
                       flag: index.isMultiple(of: 2) ? WorkoutSessionFlag(sleep: .shortNight) : nil)
        }
        let reading = WorkoutTrend.reading(of: points, profile: TrendProfile(trainingAge: TrainingAge(weeks: 8)))
        #expect(reading.state == .tooEarly)
        #expect(reading.mostlyFlagged)
        #expect(reading.windowSessions == 10 && reading.shortNightSessions == 5 && reading.lightDaySessions == 0)
        let fewer = WorkoutTrend.reading(of: Array(points.prefix(3)), profile: TrendProfile())
        #expect(fewer.state == .tooEarly && fewer.slopePerWeek == nil)
    }
}

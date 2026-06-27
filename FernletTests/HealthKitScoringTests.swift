//
//  HealthKitScoringTests.swift
//  FernletTests
//
//  Covers Item 5 (Remaining-work doc): HealthKit activity/body/sleep-stage context flowing into
//  the scoring engine. All new scoring parameters are optional, so the headline guarantee is
//  backward compatibility — quality-only / workout-only scoring must be byte-identical to the
//  pre-HealthKit behaviour.
//

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

struct HealthKitScoringTests {

    // MARK: - sleepScore

    @Test func sleepScoreQualityOnlyMatchesLegacyMapping() {
        #expect(FernletScoring.sleepScore(.great) == 1)
        #expect(FernletScoring.sleepScore(.good) == 0.8)
        #expect(FernletScoring.sleepScore(.ok) == 0.6)
        #expect(FernletScoring.sleepScore(.poor) == 0.35)
        #expect(FernletScoring.sleepScore(nil) == 0.6)
    }

    @Test func sleepScoreBlendsDurationWhenHoursPresent() {
        // base 0.6 (ok) blended 70/30 with an ideal 8 h duration factor (1.0) → 0.72.
        let score = FernletScoring.sleepScore(.ok, sleepHours: 8)
        #expect(abs(score - 0.72) < 0.0001)
        #expect(score > FernletScoring.sleepScore(.ok))
    }

    @Test func sleepScoreShortNightIsPenalized() {
        // great (1.0) blended with a 5 h duration factor (0.65) → below a full-quality night.
        let score = FernletScoring.sleepScore(.great, sleepHours: 5)
        #expect(score < 1)
        #expect(abs(score - (1 * 0.7 + 0.65 * 0.3)) < 0.0001)
    }

    @Test func sleepStageBonusRewardsHealthyArchitecture() {
        let healthy = SleepStagesData(deepMinutes: 90, coreMinutes: 240, remMinutes: 120, awakeMinutes: 20, totalAsleepMinutes: 450)
        let poor = SleepStagesData(deepMinutes: 15, coreMinutes: 380, remMinutes: 40, awakeMinutes: 20, totalAsleepMinutes: 435)
        let withHealthy = FernletScoring.sleepScore(.good, sleepHours: 7.5, stages: healthy)
        let withPoor = FernletScoring.sleepScore(.good, sleepHours: 7.5, stages: poor)
        #expect(withHealthy > withPoor)
    }

    @Test func sleepStageBonusIgnoresBareAsleepTotal() {
        // A device that only reports an undifferentiated asleep total contributes no stage bonus.
        let bare = SleepStagesData(deepMinutes: nil, coreMinutes: nil, remMinutes: nil, awakeMinutes: nil, totalAsleepMinutes: 450)
        #expect(FernletScoring.sleepStageQualityBonus(bare) == nil)
        #expect(FernletScoring.sleepScore(.good, sleepHours: 8, stages: bare) == FernletScoring.sleepScore(.good, sleepHours: 8))
    }

    // MARK: - exerciseIntensityScore

    @Test func exerciseIntensityNoActivityMatchesLegacy() {
        #expect(FernletScoring.exerciseIntensityScore(workoutCount: 0) == 0.45)
        #expect(FernletScoring.exerciseIntensityScore(workoutCount: 2) == 0.9)
    }

    @Test func exerciseIntensityHighActivityLiftsUnloggedDay() {
        // A genuinely active day with no logged workout is no longer flattened to 0.45.
        let active = FernletScoring.exerciseIntensityScore(workoutCount: 0, steps: 12_000, activeEnergyKilocalories: 600, exerciseMinutes: 45)
        #expect(active == 0.7)
        let loggedAndActive = FernletScoring.exerciseIntensityScore(workoutCount: 1, steps: 12_000)
        #expect(loggedAndActive == 1.0)
    }

    @Test func exerciseIntensitySedentaryDayUnchanged() {
        // Low movement present but below thresholds → base score, no bonus.
        #expect(FernletScoring.exerciseIntensityScore(workoutCount: 0, steps: 1_500) == 0.45)
    }

    // MARK: - recoveryReadinessScore

    @Test func recoveryReadinessNilWithoutHeartData() {
        #expect(FernletScoring.recoveryReadinessScore(restingHeartRateBPM: nil, heartRateVariabilityMS: nil, sleepQuality: .great, sleepHours: 8) == nil)
    }

    @Test func recoveryReadinessHighWithGoodMetrics() throws {
        let good = try #require(FernletScoring.recoveryReadinessScore(restingHeartRateBPM: 50, heartRateVariabilityMS: 65, sleepQuality: .great, sleepHours: 8))
        let poor = try #require(FernletScoring.recoveryReadinessScore(restingHeartRateBPM: 80, heartRateVariabilityMS: 18, sleepQuality: .poor, sleepHours: 5))
        #expect(good > 0.7)
        #expect(poor < 0.45)
        #expect(good > poor)
    }

    // MARK: - computeBreakdown wiring

    @Test func computeBreakdownBackwardCompatibleWithoutHealthKit() {
        let weights = GoalWeights.forGoal(.wellness)
        let withoutHK = FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 3, workoutCount: 1, sleepQuality: .good,
            bottleCount: 4, hydrationTarget: 4, hygiene: [.teethAM, .shower], weights: weights
        )
        let explicitNils = FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 3, workoutCount: 1, sleepQuality: .good,
            bottleCount: 4, hydrationTarget: 4, hygiene: [.teethAM, .shower], weights: weights,
            sleepHours: nil, sleepStages: nil, activitySteps: nil, activeEnergyKilocalories: nil, exerciseMinutes: nil
        )
        #expect(withoutHK == explicitNils)
        #expect(withoutHK.components["workout"] == 0.9)
    }

    @Test func computeBreakdownConsumesActivityIntoWorkoutComponent() {
        let weights = GoalWeights.forGoal(.wellness)
        let breakdown = FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 3, workoutCount: 0, sleepQuality: .good,
            bottleCount: 4, hydrationTarget: 4, hygiene: [.teethAM, .shower], weights: weights,
            activitySteps: 12_000, activeEnergyKilocalories: 650, exerciseMinutes: 50
        )
        // No logged workout, but a very active day lifts the workout component above the 0.45 floor.
        #expect((breakdown.components["workout"] ?? 0) > 0.45)
    }

    @Test func computeBreakdownConsumesSleepHoursIntoSleepComponent() {
        let weights = GoalWeights.forGoal(.wellness)
        let base = FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 3, workoutCount: 1, sleepQuality: .ok,
            bottleCount: 4, hydrationTarget: 4, hygiene: [.teethAM], weights: weights
        )
        let withHours = FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 3, workoutCount: 1, sleepQuality: .ok,
            bottleCount: 4, hydrationTarget: 4, hygiene: [.teethAM], weights: weights,
            sleepHours: 8
        )
        #expect((withHours.components["sleep"] ?? 0) > (base.components["sleep"] ?? 0))
    }

    // MARK: - Store integration

    @MainActor
    @Test func storeScoreBreakdownConsumesHealthContext() {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryURL("hk-scoring")))
        let baseDay = FernletDay(
            date: "2026-06-20",
            meals: [],
            workouts: [],
            journals: [JournalEntry(text: "Quiet day.", tag: .neutral)],
            sleep: SleepLog(hours: nil, quality: .ok, note: "")
        )
        let activeContext = HealthDailyContext(
            activity: HealthActivitySummary(steps: 13_000, activeEnergyKilocalories: 700, exerciseMinutes: 55),
            body: HealthBodyContext(sleepHours: 8, restingHeartRateBPM: 52, heartRateVariabilityMS: 60, sleepStages: nil)
        )
        var activeDay = baseDay
        activeDay.healthContext = activeContext

        let baseWorkout = store.scoreBreakdown(for: baseDay).components["workout"] ?? 0
        let activeWorkout = store.scoreBreakdown(for: activeDay).components["workout"] ?? 0
        #expect(activeWorkout > baseWorkout)

        let baseSleep = store.scoreBreakdown(for: baseDay).components["sleep"] ?? 0
        let activeSleep = store.scoreBreakdown(for: activeDay).components["sleep"] ?? 0
        #expect(activeSleep > baseSleep)
    }

    @MainActor
    @Test func dailyHealthScoreRetainsHealthContextForAudit() {
        let store = FernletStore(repository: LocalFernletRepository(fileURL: temporaryURL("hk-audit")))
        var day = FernletDay(date: "2026-06-21", meals: [], workouts: [], journals: [], sleep: nil)
        day.healthContext = HealthDailyContext(
            activity: HealthActivitySummary(steps: 8_000, activeEnergyKilocalories: 300, exerciseMinutes: 20),
            body: HealthBodyContext(sleepHours: 7.5, restingHeartRateBPM: 58, heartRateVariabilityMS: 45, sleepStages: nil)
        )
        let score = store.dailyHealthScore(for: "2026-06-21", day: day)
        #expect(score.healthActivityContext?.steps == 8_000)
        #expect(score.healthBodyContext?.restingHeartRateBPM == 58)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fernlet-hkscoring-\(name)-\(UUID().uuidString).json")
    }
}

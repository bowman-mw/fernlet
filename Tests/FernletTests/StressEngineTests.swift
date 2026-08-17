//
//  StressEngineTests.swift
//  FernletTests
//
//  Batch A "Body signals": the pure StressEngine (cold start, band widening, z-score math,
//  EWMA smoothing, classification incl. the sustained-needsCare rule, confounder
//  annotation/capping), the capped scoring modifier (byte-identical when 0 / setting off),
//  the StressService device-local sidecar, and the FernletSettings decode default.
//

import Foundation
import Testing
import FernletDomainModel
import FernletScoring
import HealthKitGateway
@testable import Fernlet

@MainActor
struct StressEngineTests {

    // MARK: - Fixtures

    /// A deterministic HRV series: alternating 49/51 "base" days (healthy spread around 50)
    /// with `lowDays` trailing days at `lowValue` (clamped z of −3 against this baseline).
    private func hrvSeries(days: Int, lowDays: Int = 0, lowValue: Double = 30) -> [StressDaySample] {
        (0..<days).map { index in
            let isLow = index >= days - lowDays
            let value: Double = isLow ? lowValue : (index.isMultiple(of: 2) ? 49 : 51)
            return StressDaySample(dateKey: "day-\(index)", hrvSDNN: value)
        }
    }

    // MARK: - Cold start

    @Test func fewerThanSevenValidHRVDaysYieldsNoAssessment() {
        // 10 days, only 6 with HRV → nil ("still getting to know you").
        var samples = hrvSeries(days: 10)
        for index in 0..<4 { samples[index].hrvSDNN = nil }
        #expect(StressEngine.assess(samples: samples) == nil)
    }

    @Test func sevenValidHRVDaysProducesBuildingAssessment() {
        let samples = hrvSeries(days: 7)
        let assessment = StressEngine.assess(samples: samples)
        #expect(assessment != nil)
        #expect(assessment?.confidence == .building)
    }

    @Test func emptyAndRestingHROnlySeriesYieldNothing() {
        #expect(StressEngine.assess(samples: []) == nil)
        // Resting HR alone never produces output — HRV is the anchor metric.
        let rhrOnly = (0..<20).map { StressDaySample(dateKey: "day-\($0)", restingHR: 60 + Double($0 % 3)) }
        #expect(StressEngine.assess(samples: rhrOnly) == nil)
    }

    // MARK: - Baseline / z-score math

    @Test func baselineComputesMeanSDAndCV() throws {
        let baseline = try #require(StressEngine.baseline(from: [10, 20, nil, 30]))
        #expect(baseline.longMean == 20)
        #expect(abs(baseline.standardDeviation - 10) < 0.0001)
        #expect(abs(baseline.coefficientOfVariation - 0.5) < 0.0001)
        #expect(baseline.validDayCount == 3)
        #expect(baseline.shortMean == 20)
    }

    @Test func zScoreAgainstBaseline() throws {
        let baseline = try #require(StressEngine.baseline(from: [10, 20, 30]))
        #expect(abs(try #require(StressEngine.zScore(35, baseline: baseline)) - 1.5) < 0.0001)
    }

    @Test func degenerateSDYieldsNoZ() throws {
        let flat = try #require(StressEngine.baseline(from: [50, 50, 50, 50]))
        #expect(StressEngine.zScore(55, baseline: flat) == nil)
    }

    @Test func combinedZInvertsRestingHRAndClamps() throws {
        let hrv = try #require(StressEngine.baseline(from: [45, 50, 55, 50, 45, 55, 50]))     // mean 50
        let rhr = try #require(StressEngine.baseline(from: [55, 60, 65, 60, 55, 65, 60]))     // mean 60
        // Low HRV (negative z) and HIGH resting HR (positive raw z, inverted to negative)
        // must push the SAME direction: more load.
        let stressed = StressDaySample(dateKey: "d", hrvSDNN: 45, restingHR: 65)
        let stressedZ = try #require(StressEngine.combinedZ(sample: stressed, hrvBaseline: hrv, restingHRBaseline: rhr))
        #expect(stressedZ < 0)
        let calm = StressDaySample(dateKey: "d", hrvSDNN: 55, restingHR: 55)
        let calmZ = try #require(StressEngine.combinedZ(sample: calm, hrvBaseline: hrv, restingHRBaseline: rhr))
        #expect(calmZ > 0)
        #expect(abs(stressedZ + calmZ) < 0.0001) // symmetric fixture
        // A wild single sample is clamped to ±3 before smoothing.
        let wild = StressDaySample(dateKey: "d", hrvSDNN: 0)
        #expect(StressEngine.combinedZ(sample: wild, hrvBaseline: hrv, restingHRBaseline: rhr) == -StressEngine.dailyZClamp)
        // No usable metric → nil.
        #expect(StressEngine.combinedZ(sample: StressDaySample(dateKey: "d"), hrvBaseline: hrv, restingHRBaseline: rhr) == nil)
    }

    // MARK: - EWMA

    @Test func ewmaSeedsCarriesForwardAndSmooths() {
        let series = StressEngine.ewmaSeries([nil, 1, nil, 0], alpha: 0.3)
        #expect(series[0] == nil)
        #expect(series[1] == 1)
        #expect(series[2] == 1)                       // nil day carries the smoothed value forward
        #expect(abs((series[3] ?? 0) - 0.7) < 0.0001) // 0.3*0 + 0.7*1
    }

    // MARK: - Classification bands + widening

    @Test func thresholdScaleWidensUntilEstablished() {
        #expect(StressEngine.thresholdScale(validDays: 7) == StressEngine.wideningFactor)
        #expect(StressEngine.thresholdScale(validDays: 29) == StressEngine.wideningFactor)
        #expect(StressEngine.thresholdScale(validDays: 30) == 1.0)
        #expect(StressEngine.thresholdScale(validDays: 60) == 1.0)
    }

    @Test func classificationBands() {
        #expect(StressEngine.classify(smoothedZ: 0.5, scale: 1) == .calm)
        #expect(StressEngine.classify(smoothedZ: 0.49, scale: 1) == .okay)
        #expect(StressEngine.classify(smoothedZ: -0.49, scale: 1) == .okay)
        #expect(StressEngine.classify(smoothedZ: -0.5, scale: 1) == .tense)
        #expect(StressEngine.classify(smoothedZ: -1.49, scale: 1) == .tense)
        #expect(StressEngine.classify(smoothedZ: -1.5, scale: 1) == .needsCare)
    }

    @Test func wideningKeepsEarlyDeviationsOkay() {
        // The same smoothed z reads .okay while the baseline is still settling (<30 valid
        // days, thresholds ×1.5) but .tense once established.
        #expect(StressEngine.classify(smoothedZ: -0.6, scale: StressEngine.wideningFactor) == .okay)
        #expect(StressEngine.classify(smoothedZ: -0.6, scale: 1) == .tense)
    }

    @Test func confidenceFromValidDays() {
        #expect(StressEngine.confidence(validDays: 7) == .building)
        #expect(StressEngine.confidence(validDays: 14) == .settling)
        #expect(StressEngine.confidence(validDays: 30) == .established)
    }

    // MARK: - Smoothing + sustained rule end-to-end

    @Test func steadySeriesReadsOkay() throws {
        let assessment = try #require(StressEngine.assess(samples: hrvSeries(days: 60)))
        #expect(assessment.state == .okay)
        #expect(assessment.confidence == .established)
        #expect(assessment.annotation == nil)
    }

    @Test func singleDeepDayCannotFlipToNeedsCare() throws {
        // One extreme day (z clamped to −3) against 59 steady days: the EWMA only moves
        // ~0.3 of the way — tense at most, never needsCare.
        let assessment = try #require(StressEngine.assess(samples: hrvSeries(days: 60, lowDays: 1)))
        #expect(assessment.state == .tense)
    }

    @Test func deepDeviationNeedsSustainedDaysForNeedsCare() throws {
        // Three deep days: today's smoothed z crosses −1.5 but YESTERDAY's did not →
        // the sustained (≥2 day) rule holds it at .tense.
        let three = try #require(StressEngine.assess(samples: hrvSeries(days: 60, lowDays: 3)))
        #expect(three.state == .tense)
        // Four deep days: both today and yesterday are at/below −1.5 → .needsCare.
        let four = try #require(StressEngine.assess(samples: hrvSeries(days: 60, lowDays: 4)))
        #expect(four.state == .needsCare)
        #expect(four.smoothedZ <= StressEngine.needsCareThreshold)
    }

    // MARK: - Confounders

    @Test func workoutDayCapsNeedsCareAtTense() throws {
        var samples = hrvSeries(days: 60, lowDays: 4)
        samples[59].isWorkoutDay = true
        let assessment = try #require(StressEngine.assess(samples: samples))
        #expect(assessment.state == .tense)
        #expect(assessment.annotation == .workedOut)
    }

    @Test func previousDayWorkoutAlsoAnnotates() throws {
        var samples = hrvSeries(days: 60, lowDays: 4)
        samples[58].isWorkoutDay = true
        let assessment = try #require(StressEngine.assess(samples: samples))
        #expect(assessment.state == .tense)
        #expect(assessment.annotation == .workedOut)
    }

    @Test func sickDayAnnotatesPossiblyUnwellAndWinsOverWorkout() throws {
        var samples = hrvSeries(days: 60, lowDays: 4)
        samples[59].isWorkoutDay = true
        samples[59].isSickDay = true
        let assessment = try #require(StressEngine.assess(samples: samples))
        #expect(assessment.state == .tense)
        #expect(assessment.annotation == .possiblyUnwell)
    }

    @Test func warmWristTriggersPossiblyUnwell() throws {
        var samples = hrvSeries(days: 60, lowDays: 4)
        samples[59].wristTempDeltaC = 0.8
        let assessment = try #require(StressEngine.assess(samples: samples))
        #expect(assessment.state == .tense)
        #expect(assessment.annotation == .possiblyUnwell)
    }

    @Test func elevatedRespiratoryRateTriggersPossiblyUnwell() throws {
        var samples = hrvSeries(days: 60, lowDays: 4)
        for index in samples.indices { samples[index].respiratoryRate = 14 + Double(index % 2) * 0.4 }
        samples[59].respiratoryRate = 20
        let assessment = try #require(StressEngine.assess(samples: samples))
        #expect(assessment.state == .tense)
        #expect(assessment.annotation == .possiblyUnwell)
    }

    @Test func steadyStateGetsNoAnnotationEvenOnWorkoutDay() throws {
        var samples = hrvSeries(days: 60)
        samples[59].isWorkoutDay = true
        let assessment = try #require(StressEngine.assess(samples: samples))
        #expect(assessment.state == .okay)
        #expect(assessment.annotation == nil)
    }

    // MARK: - Scoring modifier mapping + clamp

    @Test func modifierMappingIsCappedAndGentle() {
        #expect(StressEngine.scoringModifier(for: .calm) == 0.02)
        #expect(StressEngine.scoringModifier(for: .okay) == 0)
        #expect(StressEngine.scoringModifier(for: .tense) == -0.02)
        #expect(StressEngine.scoringModifier(for: .needsCare) == -0.04)
        #expect(StressEngine.scoringModifier(for: nil) == 0)
    }

    @Test func modifierClampBoundsArbitraryInput() {
        #expect(StressEngine.clampScoringModifier(0.5) == 0.02)
        #expect(StressEngine.clampScoringModifier(-1) == -0.04)
        #expect(StressEngine.clampScoringModifier(0) == 0)
        #expect(StressEngine.clampScoringModifier(-0.03) == -0.03)
    }

    // MARK: - computeBreakdown threading

    private func breakdown(stressModifier: Double? = nil) -> ScoreBreakdown {
        let weights = GoalWeights.forGoal(.wellness)
        if let stressModifier {
            return FernletScoring.computeBreakdown(
                journalTag: .good, mealCount: 2, workoutCount: 1, sleepQuality: .good,
                bottleCount: 2, hydrationTarget: 4, hygiene: [], weights: weights,
                stressModifier: stressModifier
            )
        }
        return FernletScoring.computeBreakdown(
            journalTag: .good, mealCount: 2, workoutCount: 1, sleepQuality: .good,
            bottleCount: 2, hydrationTarget: 4, hygiene: [], weights: weights
        )
    }

    @Test func computeBreakdownByteIdenticalWithZeroModifier() {
        #expect(breakdown() == breakdown(stressModifier: 0))
    }

    @Test func computeBreakdownAppliesClampedModifierToOverallOnly() {
        let base = breakdown()
        let nudged = breakdown(stressModifier: -0.04)
        #expect(abs(nudged.overall - (base.overall - 0.04)) < 0.000_001)
        #expect(nudged.components == base.components) // never a component, only a capped nudge
        // Excessive input is re-clamped inside the engine call.
        let excessive = breakdown(stressModifier: -5)
        #expect(abs(excessive.overall - (base.overall - 0.04)) < 0.000_001)
        let lifted = breakdown(stressModifier: 0.5)
        #expect(abs(lifted.overall - min(base.overall + 0.02, 1)) < 0.000_001)
    }

    @Test func computeForwardsStressModifier() {
        let weights = GoalWeights.forGoal(.wellness)
        let base = FernletScoring.compute(
            journalTag: .good, mealCount: 2, workoutCount: 1, sleepQuality: .good,
            bottleCount: 2, hydrationTarget: 4, hygiene: [], weights: weights
        )
        let nudged = FernletScoring.compute(
            journalTag: .good, mealCount: 2, workoutCount: 1, sleepQuality: .good,
            bottleCount: 2, hydrationTarget: 4, hygiene: [], weights: weights,
            stressModifier: -0.02
        )
        #expect(abs(nudged - (base - 0.02)) < 0.000_001)
    }

    // MARK: - Store gate (setting off = byte-identical, today-only)

    private final class StubStressContext: StressScoringContextProviding {
        var currentStressAssessment: StressAssessment?
        var scrubbed = false
        init(_ assessment: StressAssessment?) { currentStressAssessment = assessment }
        func scrubStressLocalState() -> Bool { scrubbed = true; return true }
    }

    @Test func storeScoreUnchangedWhileSettingOff() {
        let store = makeTestStore()
        store.addMeal(from: "test oatmeal")
        let baseline = store.score
        store.attachStressScoringContext(StubStressContext(
            StressAssessment(state: .needsCare, smoothedZ: -2, confidence: .established)
        ))
        #expect(store.score == baseline) // default-off opt-in gates the modifier to 0
    }

    @Test func storeScoreAppliesModifierOnlyWhenOptedInAndOnlyToday() {
        let store = makeTestStore()
        store.addMeal(from: "test oatmeal")
        let baseline = store.score
        store.attachStressScoringContext(StubStressContext(
            StressAssessment(state: .needsCare, smoothedZ: -2, confidence: .established)
        ))
        store.setStressAwarenessEnabled(true)
        #expect(abs(store.score - max(baseline - 0.04, 0)) < 0.000_001)
        // Past days always get the identity 0 — the assessment describes TODAY's baseline
        // deviation, so a recomputed past day must not inherit it.
        let pastKey = "2020-01-01"
        let pastDay = FernletDay(date: pastKey, meals: [Meal(name: "toast", mealType: .breakfast, macros: Macros(protein: 5, carbs: 20, fat: 5), quality: .ok, confidence: "test", note: "", source: MealLogSource.manual)])
        let pastScore = store.dailyHealthScore(for: pastKey, day: pastDay).score
        store.setStressAwarenessEnabled(false)
        let pastScoreWithoutStress = store.dailyHealthScore(for: pastKey, day: pastDay).score
        #expect(pastScore == pastScoreWithoutStress)
    }

    @Test func disablingOptInScrubsSidecarViaStore() {
        let store = makeTestStore()
        let stub = StubStressContext(StressAssessment(state: .tense, smoothedZ: -1, confidence: .settling))
        store.attachStressScoringContext(stub)
        store.setStressAwarenessEnabled(true)
        #expect(!stub.scrubbed)
        store.setStressAwarenessEnabled(false)
        #expect(stub.scrubbed)
    }

    // MARK: - StressService sidecar (device-local JSON)

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stress-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 60 metric days matching the deterministic alternating fixture.
    private func metricDayFixture() -> [StressMetricDay] {
        (0..<60).map { index in
            StressMetricDay(dateKey: "day-\(index)", hrvSDNN: index.isMultiple(of: 2) ? 49 : 51)
        }
    }

    @Test func serviceRefreshAssessesAndPersistsSidecar() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeTestStore()
        store.setStressAwarenessEnabled(true)
        let service = StressService(stateDirectory: directory)
        service.attach(store: store, fetchMetricDays: { [fixture = metricDayFixture()] _ in fixture })

        await service.refresh()

        #expect(service.assessment?.state == .okay)
        let fileURL = directory.appendingPathComponent(StressService.stateFileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        // The sidecar round-trips: a fresh service instance restores the last assessment.
        let reloaded = StressService(stateDirectory: directory)
        #expect(reloaded.assessment == service.assessment)
    }

    @Test func serviceScrubsSidecarWhenOptedOutOrGateThrows() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeTestStore()
        store.setStressAwarenessEnabled(true)
        let service = StressService(stateDirectory: directory)
        service.attach(store: store, fetchMetricDays: { [fixture = metricDayFixture()] _ in fixture })
        await service.refresh()
        let fileURL = directory.appendingPathComponent(StressService.stateFileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        // Opt-out: the next refresh clears memory + disk promptly (no debounce).
        store.setStressAwarenessEnabled(false)
        await service.refreshIfNeeded()
        #expect(service.assessment == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        // Re-enable, then simulate the HealthKit gate throwing (master/capability off):
        // cached clinical derivatives are scrubbed rather than left behind.
        store.setStressAwarenessEnabled(true)
        service.attach(store: store, fetchMetricDays: { [fixture = metricDayFixture()] _ in fixture })
        await service.refresh()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        struct GateError: Error {}
        service.attach(store: store, fetchMetricDays: { _ in throw GateError() })
        await service.refresh()
        #expect(service.assessment == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Settings decode

    @Test func settingsDecodeDefaultsStressAwarenessToFalse() throws {
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: Data("{}".utf8))
        #expect(decoded.stressAwarenessEnabled == false)
    }

    @Test func settingsRoundTripPreservesStressAwareness() throws {
        var settings = FernletSettings()
        settings.stressAwarenessEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: data)
        #expect(decoded.stressAwarenessEnabled == true)
    }
}

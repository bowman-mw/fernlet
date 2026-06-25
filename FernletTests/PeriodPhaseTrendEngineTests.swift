import Testing
@testable import Fernlet

/// Pure, deterministic tests for the AI-free per-phase correlation engine.
struct PeriodPhaseTrendEngineTests {
    private typealias Obs = PeriodPhaseTrendEngine.DayObservation

    private func observations(luteralSleep: Double, follicularSleep: Double, count: Int) -> [Obs] {
        var result: [Obs] = []
        for _ in 0..<count {
            result.append(Obs(phase: .luteal, sleep: luteralSleep))
            result.append(Obs(phase: .follicular, sleep: follicularSleep))
        }
        return result
    }

    @Test func belowMinimumCyclesEmitsNothing() {
        let obs = observations(luteralSleep: 0.3, follicularSleep: 0.9, count: 12)
        #expect(PeriodPhaseTrendEngine.trends(from: obs, completedCycles: 2).isEmpty)
    }

    @Test func detectsWorseAndBetterSleepWithHighConfidence() {
        let obs = observations(luteralSleep: 0.3, follicularSleep: 0.9, count: 12)
        let trends = PeriodPhaseTrendEngine.trends(from: obs, completedCycles: 4)

        let lutealSleep = try? #require(trends.first { $0.phase == .luteal && $0.metric == .sleep })
        #expect(lutealSleep?.direction == .worse)
        #expect(lutealSleep?.confidence == .high)

        let follicularSleep = trends.first { $0.phase == .follicular && $0.metric == .sleep }
        #expect(follicularSleep?.direction == .better)
        #expect(follicularSleep?.confidence == .high)
    }

    @Test func smallDifferenceIsNeutral() {
        // 0.62 vs 0.58 → baseline 0.60, diffs of 0.02 are below the meaningful delta.
        let obs = observations(luteralSleep: 0.62, follicularSleep: 0.58, count: 12)
        let trends = PeriodPhaseTrendEngine.trends(from: obs, completedCycles: 4)
        let lutealSleep = trends.first { $0.phase == .luteal && $0.metric == .sleep }
        #expect(lutealSleep?.direction == .neutral)
    }

    @Test func symptomLoadHasInvertedPolarity() {
        // More symptoms in luteal → "worse"; fewer in follicular → "better".
        var obs: [Obs] = []
        for _ in 0..<12 {
            obs.append(Obs(phase: .luteal, symptomLoad: 0.8))
            obs.append(Obs(phase: .follicular, symptomLoad: 0.2))
        }
        let trends = PeriodPhaseTrendEngine.trends(from: obs, completedCycles: 4)
        let lutealSymptoms = trends.first { $0.phase == .luteal && $0.metric == .symptomLoad }
        #expect(lutealSymptoms?.direction == .worse)
        let follicularSymptoms = trends.first { $0.phase == .follicular && $0.metric == .symptomLoad }
        #expect(follicularSymptoms?.direction == .better)
    }

    @Test func tooFewPhaseSamplesEmitsNoTrendForThatMetric() {
        // Only 3 luteal sleep samples (< the 4-sample floor) → no sleep trend emitted at all.
        var obs: [Obs] = []
        for _ in 0..<3 { obs.append(Obs(phase: .luteal, sleep: 0.3)) }
        for _ in 0..<3 { obs.append(Obs(phase: .follicular, sleep: 0.9)) }
        let trends = PeriodPhaseTrendEngine.trends(from: obs, completedCycles: 4)
        #expect(trends.allSatisfy { $0.metric != .sleep })
    }

    @Test func unknownPhaseDaysAreExcludedFromBaseline() {
        // A pile of unknown-phase low-sleep days must not drag the baseline that the luteal comparison uses.
        var obs = observations(luteralSleep: 0.6, follicularSleep: 0.6, count: 12)
        for _ in 0..<40 { obs.append(Obs(phase: .unknown, sleep: 0.1)) }
        let trends = PeriodPhaseTrendEngine.trends(from: obs, completedCycles: 4)
        // Luteal (0.6) vs a baseline that ignores the unknown 0.1s (still 0.6) → neutral, not "better".
        let lutealSleep = trends.first { $0.phase == .luteal && $0.metric == .sleep }
        #expect(lutealSleep?.direction == .neutral)
    }

    @Test func confidenceComparableOrdering() {
        #expect(PeriodHealthTrend.Confidence.low < .medium)
        #expect(PeriodHealthTrend.Confidence.medium < .high)
        #expect(PeriodHealthTrend.Confidence.high >= .medium)
    }
}

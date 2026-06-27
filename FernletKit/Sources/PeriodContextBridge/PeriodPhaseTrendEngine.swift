import Foundation
import FernletDomainModel
import PrivateHealthStore

/// An abstract, per-phase wellbeing trend derived from the user's own history. This is a *device-sealed*
/// statistical output (spec §4: "Period health trends use statistical correlations … not AI"). It carries
/// only a coarse direction + confidence **band** — never the underlying means, counts, dates, or raw
/// confidence doubles, so it can be reasoned about by scoring without re-exposing private cycle data.
public nonisolated struct PeriodHealthTrend: Equatable {
    public enum Metric: String, CaseIterable, Equatable {
        case sleep, mood, exercise, nutrition, symptomLoad
    }

    /// Whether the user historically fares *worse*, *better*, or about the same in this phase versus
    /// their own all-phase baseline. For `symptomLoad`, "worse" means *more* symptoms.
    public enum Direction: String, Equatable {
        case worse, neutral, better
    }

    /// Abstract confidence band. Raw statistics (sample size, effect size) stay inside the engine; only
    /// this band crosses out, so no inference-model confidence value is ever exported.
    public enum Confidence: String, Equatable, Comparable {
        case low, medium, high

        private var rank: Int {
            switch self { case .low: 0; case .medium: 1; case .high: 2 }
        }
        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
    }

    public var phase: CyclePhase
    public var metric: Metric
    public var direction: Direction
    public var confidence: Confidence

    public init(phase: CyclePhase, metric: Metric, direction: Direction, confidence: Confidence) {
        self.phase = phase
        self.metric = metric
        self.direction = direction
        self.confidence = confidence
    }
}

/// Deterministic, AI-free per-phase correlation engine. Given one observation per logged day (cycle phase
/// joined with that day's wellbeing component scores + symptom load), it reports, for each (phase, metric)
/// pair, whether the user historically trends worse/better than their own baseline and with what confidence.
///
/// Pure and stateless — like `CyclePredictionEngine`, it recomputes from scratch every call and persists
/// nothing. Requires at least `minimumCompletedCycles` *completed* cycles before emitting anything, matching
/// the spec's "minimum 3 completed cycles" floor. (A completed cycle is the interval between two period
/// starts, so this is one fewer than the count of detected starts.)
public nonisolated enum PeriodPhaseTrendEngine {
    /// One day of joined signals. Every wellbeing metric is optional (a day may be missing sleep, etc.).
    /// All wellbeing values are 0–1 component scores; `symptomLoad` is 0–1 (fraction of symptoms flagged).
    public struct DayObservation: Equatable {
        public var phase: CyclePhase
        public var sleep: Double? = nil
        public var mood: Double? = nil
        public var exercise: Double? = nil
        public var nutrition: Double? = nil
        public var symptomLoad: Double? = nil

        public init(
            phase: CyclePhase,
            sleep: Double? = nil,
            mood: Double? = nil,
            exercise: Double? = nil,
            nutrition: Double? = nil,
            symptomLoad: Double? = nil
        ) {
            self.phase = phase
            self.sleep = sleep
            self.mood = mood
            self.exercise = exercise
            self.nutrition = nutrition
            self.symptomLoad = symptomLoad
        }

        func value(for metric: PeriodHealthTrend.Metric) -> Double? {
            switch metric {
            case .sleep: sleep
            case .mood: mood
            case .exercise: exercise
            case .nutrition: nutrition
            case .symptomLoad: symptomLoad
            }
        }
    }

    public static let minimumCompletedCycles = 3

    /// Minimum within-phase observations for a metric before any trend is emitted for it.
    private static let minimumPhaseSamples = 4
    /// A phase mean must differ from the baseline by at least this (on the 0–1 scale) to be non-neutral.
    private static let meaningfulDelta = 0.06
    /// Floor on the standard deviation used in the effect-size denominator, so a near-constant series
    /// can't manufacture an enormous (and misleading) effect size.
    private static let minimumStdDev = 0.08

    /// `symptomLoad` has inverted polarity: a *higher* value is worse. Everything else: lower is worse.
    private static func isWorseWhenAbove(_ metric: PeriodHealthTrend.Metric) -> Bool {
        metric == .symptomLoad
    }

    public static func trends(from observations: [DayObservation], completedCycles: Int) -> [PeriodHealthTrend] {
        guard completedCycles >= minimumCompletedCycles else { return [] }

        var results: [PeriodHealthTrend] = []
        let knownPhases: [CyclePhase] = [.menstrual, .follicular, .ovulatory, .luteal]

        for metric in PeriodHealthTrend.Metric.allCases {
            // Baseline = mean across all *known*-phase days that have this metric. Unknown-phase days
            // are excluded so an unclassified stretch can't skew the per-phase comparison.
            let baselineValues = observations.compactMap { obs -> Double? in
                obs.phase == .unknown ? nil : obs.value(for: metric)
            }
            guard baselineValues.count >= minimumPhaseSamples else { continue }
            let baseline = mean(baselineValues)

            for phase in knownPhases {
                let phaseValues = observations
                    .filter { $0.phase == phase }
                    .compactMap { $0.value(for: metric) }
                guard phaseValues.count >= minimumPhaseSamples else { continue }

                let phaseMean = mean(phaseValues)
                let diff = phaseMean - baseline
                guard abs(diff) >= meaningfulDelta else {
                    results.append(PeriodHealthTrend(phase: phase, metric: metric, direction: .neutral, confidence: .low))
                    continue
                }

                let above = diff > 0
                let worse = isWorseWhenAbove(metric) ? above : !above
                let direction: PeriodHealthTrend.Direction = worse ? .worse : .better

                let effect = abs(diff) / max(minimumStdDev, standardDeviation(phaseValues, mean: phaseMean))
                let confidence = confidenceBand(sampleCount: phaseValues.count, effect: effect)
                results.append(PeriodHealthTrend(phase: phase, metric: metric, direction: direction, confidence: confidence))
            }
        }

        return results
    }

    private static func confidenceBand(sampleCount: Int, effect: Double) -> PeriodHealthTrend.Confidence {
        if sampleCount >= 10 && effect >= 1.0 { return .high }
        if sampleCount >= 5 && effect >= 0.6 { return .medium }
        return .low
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}

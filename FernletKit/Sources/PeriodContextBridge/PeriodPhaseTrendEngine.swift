import Foundation
import FernletDomainModel
import PrivateHealthStore

/// An abstract, per-phase wellbeing trend derived from the user's own history.
///
/// This is a *device-sealed* statistical output (spec §4: "Period health trends use statistical
/// correlations … not AI"). It carries only a coarse direction + confidence **band** — never the
/// underlying means, counts, dates, or raw confidence doubles, so it can be reasoned about by
/// scoring without re-exposing private cycle data. Produced by ``PeriodPhaseTrendEngine``, held on
/// ``PeriodContextBridge`` (which consults it for scoring softening), and shown in the app's
/// in-hub trends surface. Never persisted; rebuilt on every bridge refresh.
public nonisolated struct PeriodHealthTrend: Equatable {
    /// The wellbeing component a trend describes.
    ///
    /// The first four mirror ``PeriodWellbeingSample``'s non-sensitive 0–1 component scores;
    /// `symptomLoad` is derived inside the bridge from sealed narrative symptom flags and has
    /// inverted polarity (higher = worse).
    public enum Metric: String, CaseIterable, Equatable {
        case sleep, mood, exercise, nutrition, symptomLoad
    }

    /// Whether the user historically fares *worse*, *better*, or about the same in this phase versus
    /// their own all-phase baseline.
    ///
    /// For `symptomLoad`, "worse" means *more* symptoms — the engine folds each metric's polarity in
    /// before choosing a direction, so consumers never need to. `.worse` at medium/high confidence is
    /// what makes a phase "historically hard" for scoring softening.
    public enum Direction: String, Equatable {
        case worse, neutral, better
    }

    /// Abstract confidence band for a trend.
    ///
    /// Raw statistics (sample size, effect size) stay inside the engine; only this band crosses out,
    /// so no inference-model confidence value is ever exported. `Comparable` (low < medium < high) so
    /// gates can be written as `confidence >= .medium`.
    public enum Confidence: String, Equatable, Comparable {
        case low, medium, high

        private var rank: Int {
            switch self { case .low: 0; case .medium: 1; case .high: 2 }
        }
        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
    }

    /// The cycle phase the trend applies to (never `.unknown` in engine output).
    public var phase: CyclePhase
    /// Which wellbeing component this trend describes.
    public var metric: Metric
    /// Worse / neutral / better versus the user's own all-phase baseline, polarity already folded in.
    public var direction: Direction
    /// The coarse confidence band derived from sample count and effect size.
    public var confidence: Confidence

    public init(phase: CyclePhase, metric: Metric, direction: Direction, confidence: Confidence) {
        self.phase = phase
        self.metric = metric
        self.direction = direction
        self.confidence = confidence
    }
}

/// Deterministic, AI-free per-phase correlation engine.
///
/// Given one observation per logged day (cycle phase joined with that day's wellbeing component
/// scores + symptom load), it reports, for each (phase, metric) pair, whether the user historically
/// trends worse/better than their own baseline and with what confidence. The comparison is always
/// self-relative: each phase mean against the user's own all-known-phase mean, with a
/// meaningful-delta floor and a std-dev-floored effect size, so a near-constant series can't
/// manufacture a trend. ``PeriodContextBridge/refresh(unlocked:wellbeingByDay:)`` is the sole caller.
///
/// Pure and stateless — like `CyclePredictionEngine`, it recomputes from scratch every call and persists
/// nothing. Requires at least ``minimumCompletedCycles`` *completed* cycles before emitting anything,
/// matching the spec's "minimum 3 completed cycles" floor. (A completed cycle is the interval between two
/// period starts, so this is one fewer than the count of detected starts.) A namespace enum: all members
/// are static and `nonisolated`.
public nonisolated enum PeriodPhaseTrendEngine {
    /// One day of joined signals — the engine's sole input row.
    ///
    /// Every wellbeing metric is optional (a day may be missing sleep, etc.); a missing value drops
    /// the day from that metric's sample rather than counting as zero. All wellbeing values are 0–1
    /// component scores; `symptomLoad` is 0–1 (fraction of symptoms flagged). Built by the bridge's
    /// private observation join, never persisted.
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

        /// The observation's value for `metric`, or nil when that signal is missing for the day.
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

    /// Spec floor: no trends are emitted below this many *completed* cycles (detected starts − 1).
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

    /// Computes the per-(phase, metric) trend list from joined daily observations.
    ///
    /// Baseline per metric = the mean across all known-phase days carrying that metric (unknown-phase
    /// days are excluded so an unclassified stretch can't skew the comparison). Each phase with enough
    /// samples is then compared against that baseline: within `meaningfulDelta` → `.neutral`/`.low`;
    /// beyond it, direction follows the metric's polarity and confidence follows sample count +
    /// effect size.
    /// - Parameters:
    ///   - observations: One ``DayObservation`` per logged day, already phase-resolved by the caller.
    ///   - completedCycles: Detected period starts − 1; below ``minimumCompletedCycles`` the result
    ///     is `[]`.
    /// - Returns: One ``PeriodHealthTrend`` per (known phase, metric) pair that clears the per-phase
    ///   sample floor; pairs without enough data are simply absent.
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

    /// Maps raw sample count + effect size onto the exported band; the raw doubles never leave here.
    private static func confidenceBand(sampleCount: Int, effect: Double) -> PeriodHealthTrend.Confidence {
        if sampleCount >= 10 && effect >= 1.0 { return .high }
        if sampleCount >= 5 && effect >= 0.6 { return .medium }
        return .low
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Population standard deviation (divides by n); 0 for fewer than two values. Used only inside
    /// the effect-size denominator, where `minimumStdDev` floors it anyway.
    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}

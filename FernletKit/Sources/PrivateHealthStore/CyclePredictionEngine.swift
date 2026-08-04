import Foundation
import HealthKit
import FernletDomainModel

/// The output of a ``CyclePredictionEngine`` fit: the projected next period plus the statistics behind it.
///
/// Produced only when ``PeriodTrackerStore`` loads with a content key while cycle tracking is visible,
/// and published through ``PeriodTrackerStore/prediction``. Consumed read-only by the period-tracker
/// calendar, the Home outlook card, and — via its cycle-source seam — the `PeriodContextBridge` phase
/// resolver; the engine recomputes the whole value from scratch on every load.
public nonisolated struct CyclePrediction: Equatable {
    /// Most likely start date of the next period (day resolution).
    public let nextStart: Date
    /// Window the next start plausibly falls in: ``nextStart`` plus/minus a robust-spread half-width of 1–10 days.
    public let likelyStartRange: ClosedRange<Date>
    /// Projected length in days of the cycle now in progress (weighted-median/EWMA blend, rounded).
    public let predictedCycleLength: Int
    /// Recency-weighted median of the recent usable cycle lengths, in days.
    public let averageCycleLength: Int
    /// Median absolute deviation of recent cycle lengths from that median, in whole days.
    public let variationDays: Int
    /// Overall confidence in ``nextStart``, clamped to 0.15...0.95 — grows with sample count and
    /// regularity, decays with suspected missed logs and staleness past the expected start.
    public let confidence: Double
    /// Number of detected period *starts* the fit observed (period count, not completed-cycle count —
    /// `PeriodContextBridge` subtracts one to count completed cycles).
    public let cyclesObserved: Int
    /// Day-by-day flow forecast for the predicted period; see ``PredictedFlowDay``.
    public let predictedFlow: [PredictedFlowDay]

    public init(
        nextStart: Date,
        likelyStartRange: ClosedRange<Date>,
        predictedCycleLength: Int,
        averageCycleLength: Int,
        variationDays: Int,
        confidence: Double,
        cyclesObserved: Int,
        predictedFlow: [PredictedFlowDay]
    ) {
        self.nextStart = nextStart
        self.likelyStartRange = likelyStartRange
        self.predictedCycleLength = predictedCycleLength
        self.averageCycleLength = averageCycleLength
        self.variationDays = variationDays
        self.confidence = confidence
        self.cyclesObserved = cyclesObserved
        self.predictedFlow = predictedFlow
    }
}

/// Fernlet-only prediction/UI levels. `spotting` is intentionally not mapped back to a HealthKit menstrual-flow value.
///
/// Used only on the forecast surface (``PredictedFlowDay`` and the calendar's projected-flow marks);
/// observed flow keeps using ``PeriodFlowLevel``, which round-trips to HealthKit. Raw values order
/// by intensity so the engine can fit levels as 0–4 scores.
public nonisolated enum PredictedFlowLevel: Int, CaseIterable, Codable {
    case none = 0, spotting = 1, light = 2, medium = 3, heavy = 4
}

/// One day of the predicted-flow forecast attached to a ``CyclePrediction``.
///
/// Emitted by ``CyclePredictionEngine`` in `dayIndex` order starting at the predicted period start;
/// the period calendar uses it to draw projected flow intensity on future days.
public nonisolated struct PredictedFlowDay: Equatable {
    /// The forecast calendar day.
    public let date: Date
    /// Zero-based offset from the predicted period start.
    public let dayIndex: Int
    /// Predicted flow intensity for this day.
    public let level: PredictedFlowLevel
    /// Per-day confidence: the overall prediction confidence discounted by this day's bleed
    /// probability and by how concentrated past observations are on ``level``.
    public let confidence: Double

    public init(date: Date, dayIndex: Int, level: PredictedFlowLevel, confidence: Double) {
        self.date = date
        self.dayIndex = dayIndex
        self.level = level
        self.confidence = confidence
    }
}

/// Pure, stateless cycle-prediction engine: fits recent period starts and flow patterns to project
/// the next period, its likely window, and a day-by-day flow profile.
///
/// A caseless namespace of static functions — no state, no side effects, `nonisolated` so it may run
/// from any executor. ``PeriodTrackerStore`` is its only production caller: it invokes
/// ``predict(from:today:calendar:)`` after a key-carrying load (never while hidden or locked, so
/// prediction work is itself downstream of the visibility and lock gates), and `PeriodContextBridge`'s
/// phase resolver reuses ``detectedPeriodStarts(from:calendar:)`` to anchor calendar-math phases.
///
/// The fit is deliberately robust rather than clever: observed flow days are grouped into periods
/// (gaps of up to 2 days bridge one period), start-to-start intervals outside 15–90 days are
/// discarded, intervals near 2× or 3× the running median are classified as suspected missed logs
/// (excluded from the fit but charged against confidence), and the projected length blends a
/// recency-weighted median with an EWMA. Everything degrades quietly: fewer than 3 detected periods
/// (or 2 usable intervals) yields `nil` and the UI shows no forecast, and a thin flow history falls
/// back to a canonical 5-day profile capped at 0.4 confidence.
public nonisolated enum CyclePredictionEngine {
    /// Fits the observed cycle history and projects the next period.
    ///
    /// - Parameters:
    ///   - entries: Day-resolution cycle entries to fit; only their observed flow levels matter.
    ///   - today: Anchor for the staleness penalty — how far past the expected start today already is.
    ///   - calendar: Calendar used for all day math.
    /// - Returns: The prediction, or `nil` when fewer than 3 periods (or 2 usable intervals) are
    ///   detected — callers show no forecast rather than a wild one.
    public static func predict(
        from entries: [CycleDayEntry],
        today: Date,
        calendar: Calendar = .current
    ) -> CyclePrediction? {
        let periods = detectPeriods(from: entries, calendar: calendar)
        guard periods.count >= 3 else { return nil }

        let starts = periods.map(\.start)
        let intervals = zip(starts.dropFirst(), starts).compactMap { newer, older in
            calendar.dateComponents([.day], from: older, to: newer).day
        }
        guard intervals.count >= 2 else { return nil }

        let classified = classify(intervals: intervals)
        let usableIntervals = classified.filter(\.useForFit).map(\.days)
        guard usableIntervals.count >= 2 else { return nil }

        let recentIntervals = Array(usableIntervals.suffix(8)).map(Double.init)
        let weights = recencyWeights(count: recentIntervals.count, halfLife: 3.0)
        let wm = weightedMedian(recentIntervals, weights: weights)
        let ewmaValue = ewma(recentIntervals, alpha: 0.35)
        let predictedLength = Int((0.65 * wm + 0.35 * ewmaValue).rounded())

        let residuals = recentIntervals.map { abs($0 - wm) }
        let mad = weightedMedian(residuals, weights: weights)
        let robustSigma = 1.4826 * mad

        let lastStart = starts[starts.count - 1]
        guard let nextStart = calendar.date(byAdding: .day, value: predictedLength, to: lastStart) else { return nil }

        let missedLogCount = classified.filter(\.suspectedMissedLog).count
        let samplePenalty = usableIntervals.count <= 2 ? 2.0 : (usableIntervals.count <= 4 ? 1.0 : 0.0)
        let missedLogPenalty = min(2.0, 0.8 * Double(missedLogCount))
        let daysSinceLastStart = Double(calendar.dateComponents([.day], from: lastStart, to: today).day ?? predictedLength)
        let staleDays = max(0.0, daysSinceLastStart - Double(predictedLength))
        let stalePenalty = min(2.0, staleDays / 14.0)
        let rangeHalfWidth = clamp(Int(ceil(0.9 * robustSigma + samplePenalty + missedLogPenalty + stalePenalty)), min: 1, max: 10)

        guard
            let lower = calendar.date(byAdding: .day, value: -rangeHalfWidth, to: nextStart),
            let upper = calendar.date(byAdding: .day, value: rangeHalfWidth, to: nextStart)
        else { return nil }

        let sampleScore = min(0.95, 0.45 + 0.14 * Double(usableIntervals.count - 2))
        let regularityScore = max(0.35, 1.0 - robustSigma / max(1.0, Double(predictedLength)))
        let qualityPenalty = pow(0.85, Double(missedLogCount))
        let stalenessPenalty = max(0.70, 1.0 - (staleDays / 14.0) * 0.10)
        let confidence = clamp(sampleScore * regularityScore * qualityPenalty * stalenessPenalty, min: 0.15, max: 0.95)

        return CyclePrediction(
            nextStart: nextStart,
            likelyStartRange: lower...upper,
            predictedCycleLength: predictedLength,
            averageCycleLength: Int(wm.rounded()),
            variationDays: Int(mad.rounded()),
            confidence: confidence,
            cyclesObserved: starts.count,
            predictedFlow: predictFlowProfile(
                from: periods,
                nextStart: nextStart,
                overallConfidence: confidence,
                calendar: calendar
            )
        )
    }

    /// The detected period **start** dates (day-resolution, ascending). Exposes just the starts from the
    /// internal period-detection pass so the phase resolver can anchor calendar-math phases without
    /// duplicating the grouping logic. Returns `[]` when no flow days are observed.
    public static func detectedPeriodStarts(from entries: [CycleDayEntry], calendar: Calendar = .current) -> [Date] {
        detectPeriods(from: entries, calendar: calendar).map(\.start)
    }

    /// Groups observed flow days into discrete periods, bridging gaps of up to 2 days, recording each
    /// day's flow score by its offset from the period start.
    private static func detectPeriods(from entries: [CycleDayEntry], calendar: Calendar) -> [DetectedPeriod] {
        let observedDays = entries.compactMap { entry -> ObservedFlowDay? in
            guard let score = predictionScore(for: entry.flowLevel), score > 0 else { return nil }
            return ObservedFlowDay(date: calendar.startOfDay(for: entry.date), score: score)
        }
        .sorted { $0.date < $1.date }

        var periods: [DetectedPeriod] = []
        var currentStart: Date?
        var currentEnd: Date?
        var scoresByDayIndex: [Int: Int] = [:]

        for day in observedDays {
            if let start = currentStart, let end = currentEnd {
                let gap = calendar.dateComponents([.day], from: end, to: day.date).day ?? 0
                if gap <= 2 {
                    currentEnd = day.date
                    let index = calendar.dateComponents([.day], from: start, to: day.date).day ?? 0
                    scoresByDayIndex[index] = day.score
                } else {
                    periods.append(DetectedPeriod(start: start, end: end, scoresByDayIndex: scoresByDayIndex, calendar: calendar))
                    currentStart = day.date
                    currentEnd = day.date
                    scoresByDayIndex = [0: day.score]
                }
            } else {
                currentStart = day.date
                currentEnd = day.date
                scoresByDayIndex = [0: day.score]
            }
        }

        if let start = currentStart, let end = currentEnd {
            periods.append(DetectedPeriod(start: start, end: end, scoresByDayIndex: scoresByDayIndex, calendar: calendar))
        }

        return periods
    }

    /// Builds the day-by-day flow forecast from the last 6 detected periods, falling back to the
    /// canonical profile when history is too thin; stops after two consecutive low-probability tail
    /// days once past day 2.
    private static func predictFlowProfile(
        from periods: [DetectedPeriod],
        nextStart: Date,
        overallConfidence: Double,
        calendar: Calendar
    ) -> [PredictedFlowDay] {
        let recentPeriods = Array(periods.suffix(6))
        guard recentPeriods.count >= 3, recentPeriods.filter({ $0.length >= 2 && $0.scoresByDayIndex.count >= 2 }).count >= 3 else {
            return fallbackFlowProfile(nextStart: nextStart, overallConfidence: overallConfidence, calendar: calendar)
        }

        let weights = recencyWeights(count: recentPeriods.count, halfLife: 3.0)
        let longest = recentPeriods.map(\.length).max() ?? 5
        let maxLen = clamp(longest, min: 5, max: 10)
        let totalWeight = weights.reduce(0.0, +)
        var result: [PredictedFlowDay] = []
        var lowProbTailCount = 0

        for dayIndex in 0..<maxLen {
            var observations: [(score: Int, weight: Double)] = []
            var activeWeight = 0.0

            for (period, weight) in zip(recentPeriods, weights) where dayIndex < period.length {
                activeWeight += weight
                if let score = period.scoresByDayIndex[dayIndex] {
                    observations.append((score, weight))
                }
            }

            let bleedProbability = totalWeight > 0 ? activeWeight / totalWeight : 0.0
            let medianScore = observations.isEmpty ? 0 : Int(weightedMedian(observations.map { Double($0.score) }, weights: observations.map(\.weight)).rounded())
            let level: PredictedFlowLevel

            if bleedProbability < 0.25 {
                level = .none
                lowProbTailCount += 1
            } else if bleedProbability < 0.45 && medianScore <= 2 {
                level = .spotting
                lowProbTailCount = 0
            } else {
                let modeScore = weightedMode(observations.map(\.score), weights: observations.map(\.weight), tieBreaker: medianScore) ?? medianScore
                level = PredictedFlowLevel(rawValue: clamp(modeScore, min: 0, max: 4)) ?? .medium
                lowProbTailCount = 0
            }

            let concentration = observations.isEmpty ? 0.0 : categoryConcentration(chosenScore: level.rawValue, observations: observations)
            let dayConfidence = clamp(overallConfidence * max(0.25, bleedProbability) * max(0.4, concentration), min: 0.0, max: 1.0)
            guard let date = calendar.date(byAdding: .day, value: dayIndex, to: nextStart) else { continue }
            result.append(PredictedFlowDay(date: date, dayIndex: dayIndex, level: level, confidence: dayConfidence))

            if dayIndex >= 2 && lowProbTailCount >= 2 { break }
        }

        return result
    }

    /// The canonical medium–heavy–medium–light–spotting 5-day profile used when flow history is too
    /// thin to fit, with per-day confidence capped at 0.4.
    private static func fallbackFlowProfile(nextStart: Date, overallConfidence: Double, calendar: Calendar) -> [PredictedFlowDay] {
        let levels: [PredictedFlowLevel] = [.medium, .heavy, .medium, .light, .spotting]
        return levels.enumerated().compactMap { index, level in
            guard let date = calendar.date(byAdding: .day, value: index, to: nextStart) else { return nil }
            return PredictedFlowDay(date: date, dayIndex: index, level: level, confidence: min(overallConfidence, 0.4))
        }
    }

    /// Tags each start-to-start interval as usable for the fit, out of range (outside 15–90 days), or
    /// a suspected missed log (within 15% of 2× or 3× the running median of usable intervals).
    private static func classify(intervals: [Int]) -> [ClassifiedInterval] {
        var result: [ClassifiedInterval] = []
        var usable: [Double] = []

        for interval in intervals {
            guard (15...90).contains(interval) else {
                result.append(ClassifiedInterval(days: interval, useForFit: false, suspectedMissedLog: false))
                continue
            }

            let runningMedian = usable.isEmpty ? nil : weightedMedian(usable, weights: Array(repeating: 1.0, count: usable.count))
            let isMissedLog = runningMedian.map { median in
                [2.0, 3.0].contains { multiple in
                    let expected = multiple * median
                    return abs(Double(interval) - expected) <= expected * 0.15
                }
            } ?? false

            if isMissedLog {
                result.append(ClassifiedInterval(days: interval, useForFit: false, suspectedMissedLog: true))
            } else {
                result.append(ClassifiedInterval(days: interval, useForFit: true, suspectedMissedLog: false))
                usable.append(Double(interval))
            }
        }

        return result
    }

    /// Maps an observed flow level to the 0–4 intensity score the fit runs on (`unspecified` counts
    /// as medium; `none` or absent as 0, which the detection pass then drops).
    private static func predictionScore(for flowLevel: PeriodFlowLevel?) -> Int? {
        switch flowLevel {
        case .some(.heavy): 4
        case .some(.medium): 3
        case .some(.light): 2
        case .some(.unspecified): 3
        case .some(.none), nil: 0
        }
    }
}

/// A single day with nonzero observed flow, reduced to its start-of-day date and 0–4 intensity score.
///
/// Intermediate value of ``CyclePredictionEngine``'s period-detection pass; never leaves this file.
private nonisolated struct ObservedFlowDay {
    let date: Date
    let score: Int
}

/// One detected period: its start and end days plus each day's flow score keyed by offset from the start.
///
/// Built by ``CyclePredictionEngine``'s grouping pass and consumed by both the interval fit (via
/// `start`) and the flow-profile fit (via `scoresByDayIndex` and `length`).
private nonisolated struct DetectedPeriod {
    let start: Date
    let end: Date
    let scoresByDayIndex: [Int: Int]
    let length: Int

    init(start: Date, end: Date, scoresByDayIndex: [Int: Int], calendar: Calendar) {
        self.start = start
        self.end = end
        self.scoresByDayIndex = scoresByDayIndex
        self.length = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }
}

/// A start-to-start cycle interval tagged with how the fit should treat it.
///
/// `useForFit` excludes out-of-range and suspected-missed-log intervals from the length fit;
/// `suspectedMissedLog` intervals additionally count against prediction confidence.
private nonisolated struct ClassifiedInterval {
    let days: Int
    let useForFit: Bool
    let suspectedMissedLog: Bool
}

/// Weighted median (the first value whose cumulative weight crosses half the total); zero and
/// negative weights are ignored.
private nonisolated func weightedMedian(_ values: [Double], weights: [Double]) -> Double {
    guard !values.isEmpty, values.count == weights.count else { return 0 }
    let pairs = zip(values, weights).sorted { $0.0 < $1.0 }
    let totalWeight = pairs.reduce(0.0) { $0 + max(0.0, $1.1) }
    guard totalWeight > 0 else { return pairs[pairs.count / 2].0 }

    var cumulative = 0.0
    for (value, weight) in pairs {
        cumulative += max(0.0, weight)
        if cumulative >= totalWeight / 2.0 { return value }
    }

    return pairs[pairs.count - 1].0
}

/// Weighted mode; ties break toward the value nearest `tieBreaker`.
private nonisolated func weightedMode(_ values: [Int], weights: [Double], tieBreaker: Int) -> Int? {
    guard values.count == weights.count, !values.isEmpty else { return nil }
    var totals: [Int: Double] = [:]
    for (value, weight) in zip(values, weights) {
        totals[value, default: 0.0] += max(0.0, weight)
    }

    return totals.sorted { lhs, rhs in
        if lhs.value == rhs.value {
            return abs(lhs.key - tieBreaker) < abs(rhs.key - tieBreaker)
        }
        return lhs.value > rhs.value
    }.first?.key
}

/// Exponentially weighted moving average seeded with the first value.
private nonisolated func ewma(_ values: [Double], alpha: Double) -> Double {
    guard var current = values.first else { return 0 }
    for value in values.dropFirst() {
        current = alpha * value + (1.0 - alpha) * current
    }
    return current
}

/// Exponential-decay recency weights, oldest first (the newest element weighs 1.0), with the given half-life.
private nonisolated func recencyWeights(count: Int, halfLife: Double) -> [Double] {
    guard count > 0 else { return [] }
    return (0..<count).map { index in
        let lag = Double(count - 1 - index)
        return exp(-log(2.0) * lag / halfLife)
    }
}

/// Fraction of total observation weight that landed exactly on the chosen score — how unanimous
/// history is about a forecast day's level.
private nonisolated func categoryConcentration(chosenScore: Int, observations: [(score: Int, weight: Double)]) -> Double {
    let totalWeight = observations.reduce(0.0) { $0 + max(0.0, $1.weight) }
    guard totalWeight > 0 else { return 0 }
    let chosenWeight = observations.reduce(0.0) { partial, observation in
        partial + (observation.score == chosenScore ? max(0.0, observation.weight) : 0.0)
    }
    return chosenWeight / totalWeight
}

/// Clamps `value` into `lower...upper`.
private nonisolated func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
    Swift.min(Swift.max(value, lower), upper)
}

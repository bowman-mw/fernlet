import Foundation
import HealthKit
import FernletDomainModel

struct CyclePrediction: Equatable {
    let nextStart: Date
    let likelyStartRange: ClosedRange<Date>
    let predictedCycleLength: Int
    let averageCycleLength: Int
    let variationDays: Int
    let confidence: Double
    let cyclesObserved: Int
    let predictedFlow: [PredictedFlowDay]
}

/// Fernlet-only prediction/UI levels. `spotting` is intentionally not mapped back to a HealthKit menstrual-flow value.
enum PredictedFlowLevel: Int, CaseIterable, Codable {
    case none = 0, spotting = 1, light = 2, medium = 3, heavy = 4
}

struct PredictedFlowDay: Equatable {
    let date: Date
    let dayIndex: Int
    let level: PredictedFlowLevel
    let confidence: Double
}

enum CyclePredictionEngine {
    static func predict(
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
    static func detectedPeriodStarts(from entries: [CycleDayEntry], calendar: Calendar = .current) -> [Date] {
        detectPeriods(from: entries, calendar: calendar).map(\.start)
    }

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

    private static func fallbackFlowProfile(nextStart: Date, overallConfidence: Double, calendar: Calendar) -> [PredictedFlowDay] {
        let levels: [PredictedFlowLevel] = [.medium, .heavy, .medium, .light, .spotting]
        return levels.enumerated().compactMap { index, level in
            guard let date = calendar.date(byAdding: .day, value: index, to: nextStart) else { return nil }
            return PredictedFlowDay(date: date, dayIndex: index, level: level, confidence: min(overallConfidence, 0.4))
        }
    }

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

private struct ObservedFlowDay {
    let date: Date
    let score: Int
}

private struct DetectedPeriod {
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

private struct ClassifiedInterval {
    let days: Int
    let useForFit: Bool
    let suspectedMissedLog: Bool
}

private func weightedMedian(_ values: [Double], weights: [Double]) -> Double {
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

private func weightedMode(_ values: [Int], weights: [Double], tieBreaker: Int) -> Int? {
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

private func ewma(_ values: [Double], alpha: Double) -> Double {
    guard var current = values.first else { return 0 }
    for value in values.dropFirst() {
        current = alpha * value + (1.0 - alpha) * current
    }
    return current
}

private func recencyWeights(count: Int, halfLife: Double) -> [Double] {
    guard count > 0 else { return [] }
    return (0..<count).map { index in
        let lag = Double(count - 1 - index)
        return exp(-log(2.0) * lag / halfLife)
    }
}

private func categoryConcentration(chosenScore: Int, observations: [(score: Int, weight: Double)]) -> Double {
    let totalWeight = observations.reduce(0.0) { $0 + max(0.0, $1.weight) }
    guard totalWeight > 0 else { return 0 }
    let chosenWeight = observations.reduce(0.0) { partial, observation in
        partial + (observation.score == chosenScore ? max(0.0, observation.weight) : 0.0)
    }
    return chosenWeight / totalWeight
}

private func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
    Swift.min(Swift.max(value, lower), upper)
}

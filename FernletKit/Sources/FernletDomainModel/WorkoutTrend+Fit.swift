// WorkoutTrend+Fit.swift
// FernletDomainModel
//
// The arithmetic under ``WorkoutTrend``: a weighted least-squares line with bounded Huber reweighting
// (robust to the odd great or awful day), the two-pass flag weighting, the noise estimate, the
// dipping check, and the expected curve with the person's traits applied. Every loop runs over a
// window of at most ``WorkoutLoadEngine/maxExposuresPerLift`` points, a fixed number of times.

import Foundation

extension WorkoutTrend {

    /// Huber reweighting passes, and the residual (in noise units) past which a point is down-weighted.
    static let huberPasses = 3
    public static let huberK = 1.5

    /// A fitted line and what its standard errors need.
    struct Fit: Equatable {
        var slope: Double
        var intercept: Double
        /// Weighted sum of squared deviations of x from its weighted mean.
        var sxx: Double
        var xMean: Double
        var weightSum: Double

        func value(at x: Double) -> Double { intercept + slope * x }
    }

    /// A window's line with the x (weeks from its first point) and y (log score) it was fitted to.
    struct WindowFit: Equatable {
        var fit: Fit
        var xs: [Double]
        var ys: [Double]
    }

    /// The expected curve and windows the reading uses for one lift.
    struct ResolvedProfile: Equatable {
        var tier: TrainingTier
        /// The expected curve's b; 0 expects no gain (G9).
        var rate: Double
        /// Training weeks at `lastDate`.
        var weeksAtLast: Double
        var lastDate: Date
        var inferred: Bool
        var lowerBody: Bool
    }

    // MARK: Lines

    /// Weighted least squares, or nil when the weights or the x spread are degenerate.
    static func line(_ xs: [Double], _ ys: [Double], _ weights: [Double]) -> Fit? {
        guard !xs.isEmpty, xs.count == ys.count, xs.count == weights.count else { return nil }
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else { return nil }
        var xMean = 0.0
        var yMean = 0.0
        for index in xs.indices {
            xMean += weights[index] * xs[index]
            yMean += weights[index] * ys[index]
        }
        xMean /= weightSum
        yMean /= weightSum
        var sxx = 0.0
        var sxy = 0.0
        for index in xs.indices {
            let dx = xs[index] - xMean
            sxx += weights[index] * dx * dx
            sxy += weights[index] * dx * (ys[index] - yMean)
        }
        guard sxx > 1e-9 else { return nil }
        let slope = sxy / sxx
        return Fit(slope: slope, intercept: yMean - slope * xMean, sxx: sxx, xMean: xMean, weightSum: weightSum)
    }

    /// The weighted line after ``huberPasses`` rounds of Huber reweighting at ``huberK`` × `sigma`.
    static func robustLine(_ xs: [Double], _ ys: [Double], _ weights: [Double], sigma: Double) -> Fit? {
        guard sigma > 0, sigma.isFinite else { return line(xs, ys, weights) }
        let cutoff = huberK * sigma
        var robust = Array(repeating: 1.0, count: xs.count)
        for _ in 0..<huberPasses {
            guard let fit = line(xs, ys, zip(weights, robust).map { $0 * $1 }) else { return nil }
            robust = zip(xs, ys).map { x, y in
                let residual = abs(y - fit.value(at: x))
                return residual <= cutoff ? 1 : cutoff / residual
            }
        }
        return line(xs, ys, zip(weights, robust).map { $0 * $1 })
    }

    /// The two-pass fit over a window: flagged sessions start at ``flaggedWeight``; one that meets the
    /// line within its flag's trim then counts fully, one that falls short keeps `shortWeight`
    /// (half for the trend, zero for the stall test — a short flagged day never counts toward a stall).
    static func fitWindow(_ window: [TrendPoint], sigma: Double, shortWeight: Double, lowerBody: Bool) -> WindowFit? {
        guard let origin = window.first?.date else { return nil }
        let xs = window.map { weeks(from: origin, to: $0.date) }
        let ys = window.map { log(max($0.score, 1e-6)) }
        let initialWeights = window.map { $0.flag == nil ? 1.0 : flaggedWeight }
        guard let initial = robustLine(xs, ys, initialWeights, sigma: sigma) else { return nil }
        var weights: [Double] = []
        for (index, point) in window.enumerated() {
            guard let flag = point.flag else {
                weights.append(1)
                continue
            }
            let residual = ys[index] - initial.value(at: xs[index])
            weights.append(residual >= -flag.trim(lowerBody: lowerBody) ? 1 : shortWeight)
        }
        guard let fit = robustLine(xs, ys, weights, sigma: sigma) else { return nil }
        return WindowFit(fit: fit, xs: xs, ys: ys)
    }

    /// The tier's prior, or — with ``personalNoiseAfter`` clean sessions in the window — the person's
    /// own scatter around the line, never under ``personalNoiseFloor`` of the prior.
    static func noise(_ window: [TrendPoint], tier: TrainingTier, trend: WindowFit) -> Double {
        var squares: [Double] = []
        for (index, point) in window.enumerated() where point.flag == nil && index < trend.xs.count {
            let residual = trend.ys[index] - trend.fit.value(at: trend.xs[index])
            squares.append(residual * residual)
        }
        guard squares.count >= personalNoiseAfter else { return tier.noisePrior }
        let personal = (squares.reduce(0, +) / Double(max(1, squares.count - 2))).squareRoot()
        return max(personal, personalNoiseFloor * tier.noisePrior)
    }

    // MARK: Dipping and earlier slopes

    /// The newest two sessions, both unflagged, each more than ``dipErrors`` typical errors under the
    /// line's level at the session before them. The level is never extrapolated — a rising curve can
    /// only lift the newest sessions, so a beginner's bending curve never reads as a dip — and the
    /// typical error counts the level's own uncertainty.
    static func isDipping(_ window: [TrendPoint], sigma: Double, lowerBody: Bool) -> Bool {
        guard window.count >= 4, window[window.count - 1].flag == nil, window[window.count - 2].flag == nil else {
            return false
        }
        let base = Array(window.dropLast(2))
        guard let fit = fitWindow(base, sigma: sigma, shortWeight: flaggedWeight, lowerBody: lowerBody),
              let end = fit.xs.last else { return false }
        let level = fit.fit.value(at: end)
        let spread = end - fit.fit.xMean
        let levelVariance = sigma * sigma * (1 / fit.fit.weightSum + spread * spread / fit.fit.sxx)
        let typical = (sigma * sigma + levelVariance).squareRoot()
        for point in window.suffix(2) {
            guard log(max(point.score, 1e-6)) - level < -dipErrors * typical else { return false }
        }
        return true
    }

    /// The slope of the tier's trend window just before `start`, when it has enough clean sessions.
    static func previousSlope(
        _ points: [TrendPoint], before start: Date, tier: TrainingTier, sigma: Double, lowerBody: Bool
    ) -> Double? {
        let prior = points.filter { $0.date < start && weeks(from: $0.date, to: start) <= tier.trendWeeks }
        guard prior.filter({ $0.flag == nil }).count >= tier.minimumSessions,
              let fit = fitWindow(prior, sigma: sigma, shortWeight: flaggedWeight, lowerBody: lowerBody) else { return nil }
        return fit.fit.slope
    }

    /// With an inferred training age, the expected slope is the lift's own earlier progress: the
    /// lower 80 % bound of the slope over the ``ownProgressWeeks`` before the stall window, never
    /// below zero. Nil without ``ownProgressSessions`` clean sessions there (too early).
    static func ownExpectedSlope(_ points: [TrendPoint], before start: Date, sigma: Double, lowerBody: Bool) -> Double? {
        let prior = points.filter { $0.date < start && weeks(from: $0.date, to: start) <= ownProgressWeeks }
        guard prior.filter({ $0.flag == nil }).count >= ownProgressSessions,
              let fit = fitWindow(prior, sigma: sigma, shortWeight: flaggedWeight, lowerBody: lowerBody) else { return nil }
        return max(0, fit.fit.slope - upperBoundZ * sigma / fit.fit.sxx.squareRoot())
    }

    // MARK: The expected curve

    /// The expected curve's average slope from `start` to `end`: b·ln(t₂/t₁)/(t₂ − t₁), t in
    /// training weeks (b/t at a single instant).
    static func expectedSlope(_ resolved: ResolvedProfile, from start: Date, to end: Date) -> Double {
        guard resolved.rate > 0 else { return 0 }
        let late = max(1, resolved.weeksAtLast - weeks(from: end, to: resolved.lastDate))
        let early = max(1, resolved.weeksAtLast - weeks(from: start, to: resolved.lastDate))
        guard late - early > 1e-6 else { return resolved.rate / late }
        return resolved.rate * log(late / early) / (late - early)
    }

    /// The profile with its training age settled (inferred from the history when not given) and the
    /// expected curve's b set from the tier and the person's traits.
    static func resolve(_ profile: TrendProfile, first: Date, last: Date, levelKg: Double?) -> ResolvedProfile {
        let age = profile.trainingAge ?? TrainingAge.inferred(from: first, to: last)
        let rate = expectedRate(age: age, traits: profile.traits, lowerBody: profile.lowerBody, levelKg: levelKg)
        return ResolvedProfile(tier: age.tier, rate: rate, weeksAtLast: age.weeks, lastDate: last,
                               inferred: age.isInferred, lowerBody: profile.lowerBody)
    }

    /// The expected curve's b: the tier's base, slightly higher for women and for lighter or weaker
    /// lifters, lower for strong men, and zero for lifters over 60 with two years or more of training.
    public static func expectedRate(age: TrainingAge, traits: LifterTraits, lowerBody: Bool, levelKg: Double?) -> Double {
        if let years = traits.ageYears, years >= olderAdultYears, age.weeks >= advancedWeeks { return 0 }
        var rate = age.tier.baseRate
        if traits.sex == .female { rate *= femaleRateFactor }
        let ratio = traits.bodyWeightKg.flatMap { body in levelKg.map { $0 / body } }
        let weaker = ratio.map { $0 < (lowerBody ? weakerRatioLower : weakerRatioUpper) } ?? false
        let lighter = (traits.bodyWeightKg ?? .infinity) < lightBodyWeightKg
        if weaker || lighter {
            rate *= lighterRateFactor
        } else if traits.sex == .male, let ratio, ratio >= (lowerBody ? strongRatioLower : strongRatioUpper) {
            rate *= strongRateFactor
        }
        return rate
    }
}

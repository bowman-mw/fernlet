// WorkoutBodyWeightTrend.swift
// FernletDomainModel
//
// Whether body weight has been coming down (G13, 2026-10-20) — said in the plateau story only for
// someone who already logs their weight, never asked for: beside a Size lifter's stall (muscle size
// usually holds steady through a deficit), and beside weight management's quiet "strength held"
// check as a gentle check-in. It is context only: it never cuts a load or speeds progress, and with
// too few weigh-ins it says nothing.
//
// The rule is a least-squares line through the log of each weigh-in in the last ``windowDays`` days,
// spanning at least ``minimumSpanDays``: falling when the line comes down by at least
// ``minimumWeeklyDrop`` a week and sits ``fallingZ`` standard errors under flat — on each of the last
// ``persistence`` weigh-ins, each read on its own day. Day-to-day water moves a morning weight by
// about 1 %, so a single reading, or a small slope, is not a fall. `Tools/plateau-sim/body_weight_sim.py`
// settled the thresholds on seeded weigh-ins (7, 3 or 2 a week, water noise 0.6–1 % with some days
// carried over), and `WorkoutBodyWeightTrendTests` pins its counts against this code: a steady weight
// is called falling in 13 of 400 histories over 8 weeks; a 0.5 %-a-week deficit is found in 68 % of
// histories within six weeks (median day 25), a 1 %-a-week one in 96 % (median day 21).

import Foundation

/// One weigh-in the person logged.
public nonisolated struct BodyWeightSample: Equatable, Sendable {
    public var date: Date
    public var kilograms: Double

    public init(date: Date, kilograms: Double) {
        self.date = date
        self.kilograms = kilograms
    }
}

/// The body-weight trend the plateau story may mention (G13).
public nonisolated enum WorkoutBodyWeightTrend {

    /// Days of weigh-ins one reading looks at: four weeks.
    public static let windowDays = 28.0
    /// The weigh-ins read must span at least this many days: two weeks.
    public static let minimumSpanDays = 14.0
    /// Fewest weigh-ins in the window.
    public static let minimumSamples = 6
    /// How far under flat, in standard errors, the line must sit.
    public static let fallingZ = 1.645
    /// The smallest fall that counts, as a fraction of body weight a week (0.5 %).
    public static let minimumWeeklyDrop = 0.005
    /// The fall must be read on this many weigh-ins in a row.
    public static let persistence = 3
    /// The newest weigh-in must be at most this many days old for the trend to speak.
    public static let staleDays = 7
    /// Most weigh-ins read, newest kept: bounds every loop below.
    public static let maxSamples = 240

    /// The weekly change in body weight, as a fraction (−0.005 is 0.5 % lighter a week), and its
    /// standard error, from the weigh-ins in the ``windowDays`` days up to `end`; nil without
    /// ``minimumSamples`` of them spanning ``minimumSpanDays``.
    public static func weeklyChange(_ samples: [BodyWeightSample], asOf end: Date) -> (change: Double, standardError: Double)? {
        var xs: [Double] = []
        var ys: [Double] = []
        for sample in samples.suffix(maxSamples) {
            let age = end.timeIntervalSince(sample.date) / 86_400
            guard age >= 0, age < windowDays, sample.kilograms > 0, sample.kilograms.isFinite else { continue }
            xs.append(-age)
            ys.append(log(sample.kilograms))
        }
        guard xs.count >= minimumSamples, let first = xs.min(), let last = xs.max(),
              last - first >= minimumSpanDays else { return nil }
        let count = Double(xs.count)
        let meanX = xs.reduce(0, +) / count
        let meanY = ys.reduce(0, +) / count
        var sxx = 0.0
        var sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
        }
        let slope = sxy / sxx
        var residual = 0.0
        for (x, y) in zip(xs, ys) {
            let r = y - meanY - slope * (x - meanX)
            residual += r * r
        }
        let error = (residual / (count - 2) / sxx).squareRoot()
        return (slope * 7, error * 7)
    }

    /// The fall test on the window ending at `end`.
    static func fallsAt(_ samples: [BodyWeightSample], end: Date) -> Bool {
        guard let reading = weeklyChange(samples.filter { $0.date <= end }, asOf: end) else { return false }
        return reading.change <= -minimumWeeklyDrop && reading.change + fallingZ * reading.standardError < 0
    }

    /// Whether body weight has been coming down as of `today`: the fall read on each of the last
    /// ``persistence`` weigh-ins, the newest at most ``staleDays`` old. False with too few weigh-ins.
    public static func isFalling(_ samples: [BodyWeightSample], today: Date) -> Bool {
        let kept = Array(samples.filter { $0.date <= today }.sorted { $0.date < $1.date }.suffix(maxSamples))
        let days = kept.reduce(into: [Date]()) { found, sample in
            if found.last != sample.date { found.append(sample.date) }
        }
        guard days.count >= persistence, let newest = days.last,
              WorkoutLoadEngine.days(from: newest, to: today) <= staleDays else { return false }
        return days.suffix(persistence).allSatisfy { fallsAt(kept, end: $0) }
    }
}

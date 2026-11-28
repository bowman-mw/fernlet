import Foundation

// AmbientShortDays.swift
//
// The "Short days" gentle reminder (owner's picks S1-C, S2-A, S3-A; 2026-11-27): it shows only when
// the day is short (under 10 hours of daylight, worked out on the phone) and sleep has run short (most
// of the last week's nights well under the person's usual total). Pure, with the clock injected.
//
// - Day length comes from a sunrise/sunset formula and the weather's coarse latitude, rounded to 1°:
//   no network, nothing stored, and no card at all without a location (Home never asks for one).
// - Sleep is the diary's nightly totals only, never wake times or anything sealed.

/// The length of daylight at a latitude on a day of the year. Pure and bounded: one formula, no loops.
nonisolated enum AmbientDaylight {
    /// The sun's centre this far below the horizon counts as sunrise and sunset (refraction and the
    /// sun's radius), in degrees.
    static let horizonDegrees = -0.833
    /// The Earth's axial tilt, in degrees.
    static let tiltDegrees = 23.44
    /// Latitudes are held inside this, so the poles never divide by zero.
    static let maxLatitude = 89.5

    /// Hours of daylight at `latitude` (degrees, north positive) on `dayOfYear` (1–366): 0 in the polar
    /// night, 24 in the midnight sun. Accurate to a few minutes away from the poles.
    static func hours(latitude: Double, dayOfYear: Int) -> Double {
        guard latitude.isFinite else { return 12 }
        let day = Double(min(max(dayOfYear, 1), 366))
        let phi = min(max(latitude, -maxLatitude), maxLatitude) * .pi / 180
        // The sun's declination: −23.44° at the December solstice (day 355), +23.44° at the June one.
        let delta = -tiltDegrees * cos(2 * .pi / 365 * (day + 10)) * .pi / 180
        let horizon = horizonDegrees * .pi / 180
        let cosine = (sin(horizon) - sin(phi) * sin(delta)) / (cos(phi) * cos(delta))
        let hourAngle = acos(min(max(cosine, -1), 1)) * 180 / .pi
        return 2 * hourAngle / 15
    }

    /// Hours of daylight on `date`'s day at `latitude`.
    static func hours(latitude: Double, on date: Date, calendar: Calendar) -> Double {
        hours(latitude: latitude, dayOfYear: calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
    }
}

/// Whether sleep has run short lately, from the diary's nightly totals. Pure.
///
/// The person's usual total is the median of the nights one to five weeks ago (at least
/// ``minimumUsualNights`` of them); a night is short when it is at least ``shortByHours`` under it; sleep
/// has run short when at least ``minimumShortNights`` of the last ``recentNights`` nights were short.
nonisolated enum AmbientShortNights {
    /// The recent window, in nights (today's total is last night's).
    static let recentNights = 7
    /// How many recent nights must be short.
    static let minimumShortNights = 4
    /// The usual total is read from this many nights before the recent window.
    static let usualNights = 28
    /// The fewest nights the usual total may come from.
    static let minimumUsualNights = 14
    /// How far under the usual total a night must be to count as short, in hours.
    static let shortByHours = 0.5
    /// A total outside this is not a night's sleep (a mistyped or a broken reading), in hours.
    static let plausibleHours = 0.5...16.0

    /// Whether at least ``minimumShortNights`` of the last ``recentNights`` nights in `nights` (one entry
    /// per diary day, its amount the hours) were short against the person's usual total.
    static func haveRunShort(_ nights: [AmbientDatedAmount], now: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        var recent: [Double] = []
        var usual: [Double] = []
        for night in nights.prefix(AmbientHistory.lookbackDays) where plausibleHours.contains(night.amount) {
            let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: night.date), to: today).day ?? -1
            if (0..<recentNights).contains(age) {
                recent.append(night.amount)
            } else if (recentNights..<(recentNights + usualNights)).contains(age) {
                usual.append(night.amount)
            }
        }
        guard usual.count >= minimumUsualNights, let typical = median(usual) else { return false }
        return recent.filter { $0 <= typical - shortByHours }.count >= minimumShortNights
    }

    /// The median of `values`, or nil when there are none.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// The "Short days" card's rule: both a short day and short nights.
nonisolated enum AmbientShortDaysFinder {
    /// Daylight under this many hours makes a short day.
    static let shortDayHours = 10.0

    /// The "Short days" reminder for today, or nil: none without a latitude (`latitude` is the weather's,
    /// rounded to 1°), none on a day with ``shortDayHours`` of daylight or more, none unless sleep has run
    /// short (``AmbientShortNights``).
    static func reminder(latitude: Int?, nights: [AmbientDatedAmount], now: Date,
                         calendar: Calendar = .current) -> AmbientReminder? {
        guard let latitude else { return nil }
        guard AmbientDaylight.hours(latitude: Double(latitude), on: now, calendar: calendar) < shortDayHours else { return nil }
        guard AmbientShortNights.haveRunShort(nights, now: now, calendar: calendar) else { return nil }
        return AmbientReminder(kind: .shortDays, subject: .shortDays)
    }
}

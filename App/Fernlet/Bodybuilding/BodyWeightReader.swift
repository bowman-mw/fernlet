//
//  BodyWeightReader.swift
//  Fernlet
//
//  The Day calendar's weight (World round 7, piece C; spec §2 and §3): one value a day, read from Apple
//  Health's body-mass samples under the body-profile read Fernlet already holds. Read-only: it never asks
//  for a new type and never writes. Nothing is read in a decoy session or while Health is off, and the
//  values live only in the calendar's view state (a Health value never reaches synced state).
//

import FernletDomainModel
import FernletFoundation
import Foundation
import HealthKit
import HealthKitGateway

/// Where the calendar's weight readings (``BodyWeightSample``, the domain model's weigh-in) come from: Health on a device, a fixture in a DEBUG
/// screenshot run, a canned list in a test.
protocol BodyWeightSampleSource {
    /// The readings taken from `start` up to `end`; empty when there are none or nothing may be read.
    func samples(from start: Date, through end: Date) async -> [BodyWeightSample]
}

/// Health's body-mass samples, one average a day, under the body-profile read the person already
/// granted. A transient gateway built for the one read and dropped (``HealthKitLifecycleBoundaryTests``
/// lists it): no observer, no authorization request, no write.
struct HealthBodyWeightSource: BodyWeightSampleSource {
    func samples(from start: Date, through end: Date) async -> [BodyWeightSample] {
        let service = HealthKitService()
        guard service.isCapabilityRequestedAndEnabled(.bodyProfile) else { return [] }
        let stats: [HKStatistics]
        do {
            stats = try await service.statistics(for: HKQuantityType(.bodyMass), options: .discreteAverage,
                                                 interval: DateComponents(day: 1), anchor: start)
        } catch {
            // Named, not swallowed: the calendar simply draws no weight line.
            FernletAuditLog.log("bodybuilding.weightReadFailed", context: ["error": String(describing: type(of: error))])
            return []
        }
        return stats.prefix(BodyWeightReader.maxDays).compactMap { entry in
            guard entry.startDate < end,
                  let kilograms = entry.averageQuantity()?.doubleValue(for: .gramUnit(with: .kilo)) else { return nil }
            return BodyWeightSample(date: entry.startDate, kilograms: kilograms)
        }
    }
}

/// Turns readings into the calendar's one weight a day.
nonisolated enum BodyWeightReader {
    /// The most days one read covers: a month grid plus a week, with room to spare.
    static let maxDays = 62
    /// The plausible range of a reading in kilograms; anything outside is a typo, never drawn.
    static let plausibleKilograms: ClosedRange<Double> = 20...400

    #if DEBUG
    /// DEBUG screenshot runs only: weights by day key the demo seed hands the calendar in place of Health.
    @MainActor static var fixtureKilograms: [String: Double]?
    #endif

    /// One weight a day for the days `startKey...endKey`: each day's readings averaged and rounded to a
    /// tenth; implausible readings dropped.
    static func dailyKilograms(_ samples: [BodyWeightSample], from startKey: String, through endKey: String,
                               calendar: Calendar) -> [String: Double] {
        var sums: [String: (total: Double, count: Int)] = [:]
        for sample in samples.prefix(maxDays * 48) {
            guard sample.kilograms.isFinite, plausibleKilograms.contains(sample.kilograms) else { continue }
            let key = BodybuildingWeeks.dayKey(for: sample.date, calendar: calendar)
            guard key >= startKey, key <= endKey else { continue }
            let running = sums[key] ?? (0, 0)
            sums[key] = (running.total + sample.kilograms, running.count + 1)
        }
        return sums.mapValues { (($0.total / Double($0.count)) * 10).rounded() / 10 }
    }

    /// The weights for `startKey...endKey`: nothing in a decoy session, the DEBUG fixture when a
    /// screenshot run set one, else `source`'s readings bucketed by day.
    @MainActor static func load(from startKey: String, through endKey: String, isDecoy: Bool,
                     source: any BodyWeightSampleSource,
                     calendar: Calendar) async -> [String: Double] {
        guard !isDecoy else { return [:] }
        #if DEBUG
        if let fixture = fixtureKilograms { return fixture.filter { $0.key >= startKey && $0.key <= endKey } }
        #endif
        guard let start = BodybuildingWeeks.date(fromDayKey: startKey, calendar: calendar),
              let last = BodybuildingWeeks.date(fromDayKey: endKey, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [:] }
        let samples = await source.samples(from: start, through: end)
        return dailyKilograms(samples, from: startKey, through: endKey, calendar: calendar)
    }
}

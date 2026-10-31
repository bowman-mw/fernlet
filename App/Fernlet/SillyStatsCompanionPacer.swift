//
//  SillyStatsCompanionPacer.swift
//  Fernlet
//
//  Decides when the companion brings up a silly stat: about once every two or three days, never
//  the same stat twice in a row, never a stat whose number hasn't moved since it was last
//  mentioned, and never on a quiet day (a rest or sick day, or a stretch that needs gentleness).
//

import Foundation
import FernletFoundation

/// Paces the companion's silly-stat mentions.
///
/// State lives in device-local `UserDefaults` (injectable for tests, like
/// ``PetInteractionGovernor``) and never in `FernletSettings`: some stats are computed from Apple
/// Health, and a Health-derived number must not reach synced state. The stored values are the
/// last mention's day, kind and number per kind, plus the next day a mention is due.
///
/// A mention is chosen once per day and then repeated for the rest of that day, so relaunching
/// the app does not reshuffle what the companion said this morning.
final class SillyStatsCompanionPacer {
    /// The `UserDefaults` keys the pacer persists under — device-local, never synced.
    private enum Key {
        static let lastDay = "fernlet.sillyStats.lastMentionDay"
        static let lastKind = "fernlet.sillyStats.lastMentionKind"
        static let nextDueDay = "fernlet.sillyStats.nextMentionDay"
        static let lastValues = "fernlet.sillyStats.lastMentionValues"
    }

    /// The shortest and longest gaps, in days, between two mentions.
    static let gapDays = 2...3

    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    /// The stat to mention today, or nil. Records the choice, so the rest of today repeats it.
    ///
    /// - Parameters:
    ///   - candidates: revealed stats with their current numbers, in page order.
    ///   - todayKey: today's `yyyy-MM-dd` key.
    ///   - isQuietDay: a rest, sick or needs-gentleness day — nothing is said and nothing is used
    ///     up, so the mention waits for a better day.
    func mention(from candidates: [(kind: SillyStatKind, value: Double)], todayKey: String, isQuietDay: Bool) -> SillyStatKind? {
        guard !isQuietDay, !candidates.isEmpty, FernletDate.date(fromDayKey: todayKey) != nil else { return nil }
        if defaults.string(forKey: Key.lastDay) == todayKey {
            let kind = defaults.string(forKey: Key.lastKind).flatMap(SillyStatKind.init(rawValue:))
            return candidates.contains { $0.kind == kind } ? kind : nil
        }
        if let due = defaults.string(forKey: Key.nextDueDay), todayKey < due { return nil }
        let lastKind = defaults.string(forKey: Key.lastKind)
        let lastValues = storedValues()
        let fresh = candidates.filter { candidate in
            guard candidate.kind.rawValue != lastKind else { return false }
            guard let previous = lastValues[candidate.kind.rawValue] else { return true }
            return abs(candidate.value - previous) > 0.0001
        }
        guard !fresh.isEmpty else { return nil }
        let seed = GentleOfferEngine.rotationSeed(dateKey: todayKey)
        let pick = fresh[seed % fresh.count]
        record(pick, todayKey: todayKey, seed: seed, values: lastValues)
        return pick.kind
    }

    /// Clears the pacer's state (the DEBUG appearance seed hook and tests).
    static func clearPersistentState(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.lastDay)
        defaults.removeObject(forKey: Key.lastKind)
        defaults.removeObject(forKey: Key.nextDueDay)
        defaults.removeObject(forKey: Key.lastValues)
    }

    private func record(_ pick: (kind: SillyStatKind, value: Double), todayKey: String, seed: Int, values: [String: Double]) {
        var updated = values
        updated[pick.kind.rawValue] = pick.value
        defaults.set(updated, forKey: Key.lastValues)
        defaults.set(todayKey, forKey: Key.lastDay)
        defaults.set(pick.kind.rawValue, forKey: Key.lastKind)
        let gap = Self.gapDays.lowerBound + seed % Self.gapDays.count
        guard let today = FernletDate.date(fromDayKey: todayKey),
              let due = calendar.date(byAdding: .day, value: gap, to: today) else { return }
        defaults.set(FernletDate.dayKey(for: due), forKey: Key.nextDueDay)
    }

    /// The last-mentioned number per kind token, keeping only kinds this build knows (bounded by
    /// the twenty kinds, whatever an older or newer build left behind).
    private func storedValues() -> [String: Double] {
        let raw = defaults.dictionary(forKey: Key.lastValues) ?? [:]
        var values: [String: Double] = [:]
        for kind in SillyStatKind.allCases {
            guard let number = raw[kind.rawValue] as? Double else { continue }
            values[kind.rawValue] = number
        }
        return values
    }
}

//
//  SillyStamps.swift
//  Fernlet
//
//  Stamps: each silly stat earns one the first time it appears, under the engine's
//  hide-until-meaningful rule ("Your first cookie earns the Crumb Goblin"). Stamps only ever add up:
//  a stamp is never taken back, whatever the tally does later, and there are none for streaks, body
//  weight or calories — the twenty stats count none of those, and a stamp is one per stat.
//
//  This file holds the row (``SillyStampEntry``), the rule for when a stamp is earned and whether it
//  is announced (``SillyStampRules``), and the device-local book it is kept in (``SillyStampStore``).
//  The names and the companion's lines are in `SillyStampCopy`; the banner and the book's card are
//  in `SillyStampViews`.
//

import Foundation
import FernletFoundation

/// One stamp in the stamp book: the stat that earned it and the day it was earned.
///
/// Shaped after the milestone ledger's rows (`MilestoneLedgerEntry`): append-only, with an id that is
/// deterministic from the thing it records (`stamp:<kind token>`), so recording the same stamp twice
/// collapses to one row and the first-earned row always wins. `kind` persists as its frozen
/// ``SillyStatKind`` token and the id embeds it — both are tokens, never display text; the stamp's
/// name is display copy the owner may rename (``SillyStampCopy``).
struct SillyStampEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: SillyStatKind
    /// The day (`yyyy-MM-dd`) the stamp was earned: the day its stat first had enough behind it to
    /// show, when the diary can say, otherwise the day it was noticed.
    let dayKey: String
    let createdAt: Date

    init(kind: SillyStatKind, dayKey: String, createdAt: Date) {
        self.id = Self.id(for: kind)
        self.kind = kind
        self.dayKey = dayKey
        self.createdAt = createdAt
    }

    /// The deterministic row id for `kind`'s stamp — the key to "one stamp per stat, never two".
    static func id(for kind: SillyStatKind) -> String {
        "stamp:\(kind.rawValue)"
    }
}

/// When a stat earns its stamp, and whether the banner and the companion mark it.
///
/// Pure and clock-free. A revealed stat with no stamp yet earns one, dated the day the diary says
/// it first appeared (``SillyStatsTallier/firstRevealDays(_:calendar:)``) or, when the diary cannot say
/// (Apple Health's lifetime step total and the pat count carry no dates), today.
///
/// Only a stamp earned since the book began on this device is announced. The book begins at its
/// first check (``SillyStampStore/begin(on:)``), and that check records everything already revealed
/// silently: an update that brings stamps to someone with months of history, or a new phone whose
/// diary arrives from iCloud a minute after launch, files those stamps under the days they were
/// earned instead of raising a dozen banners for things done long ago. After that, a stamp dated
/// on or after the book's first day is news — a cookie logged today, or one logged to yesterday.
enum SillyStampRules {
    /// What one check found.
    struct Award: Equatable {
        /// New rows for the book, in page order.
        var entries: [SillyStampEntry] = []
        /// The kinds among ``entries`` earned just now, in page order — the banner and the
        /// companion mark these. The rest is history the book is catching up on.
        var announced: [SillyStatKind] = []
    }

    /// The stamps `revealed` earns that `held` does not have yet.
    ///
    /// - Parameters:
    ///   - revealed: the stats showing now, in page order.
    ///   - held: the kinds already in the book. Never shrinks: a held stamp whose stat has stopped
    ///     showing stays held, so it is neither lost nor earned (and announced) a second time.
    ///   - bookStartDay: the book's first day on this device, or nil when this check begins it.
    ///   - firstRevealDays: the day each stat first showed, read from the diary. Called only when
    ///     there is a stamp to date, because it replays the whole diary.
    ///   - todayKey: today's `yyyy-MM-dd` key.
    ///   - now: the rows' `createdAt`.
    static func award(
        revealed: [SillyStatKind],
        held: Set<SillyStatKind>,
        bookStartDay: String?,
        firstRevealDays: () -> [SillyStatKind: String],
        todayKey: String,
        now: Date
    ) -> Award {
        let fresh = revealed.filter { !held.contains($0) }
        guard !fresh.isEmpty, FernletDate.date(fromDayKey: todayKey) != nil else { return Award() }
        let dated = firstRevealDays()
        var award = Award()
        for kind in fresh {
            // Never later than today: a stat cannot have first shown on a day still to come.
            let day = dated[kind].map { min($0, todayKey) } ?? todayKey
            award.entries.append(SillyStampEntry(kind: kind, dayKey: day, createdAt: now))
            if let bookStartDay, day >= bookStartDay {
                award.announced.append(kind)
            }
        }
        return award
    }
}

/// The stamp book on this device, in `UserDefaults` and never synced.
///
/// **Device-local, by the milestone ledger's own rule.** Milestone rows sync because they are
/// derived from the synced diary, and the ledger keeps everything else off them: Health-imported
/// workouts are never counted, and worry counts stay on the device to keep the Worry Box's promise.
/// A stamp is a fact about a total, and five of the totals can come from Apple Health (lifetime
/// steps, sleep, dream stages) or from this device's pat count — so "earned To Step or Not to Step
/// on 3 May" says something about the user's Health data, and the silly stats promise that a
/// Health-derived number never reaches synced state (the same reason ``SillyStatsCompanionPacer``
/// keeps its state here). Splitting the book by where each stamp's numbers came from would make a
/// stamp's sync depend on how it happened to be earned, so the whole book stays on the device.
/// A new phone is not a lost book: the diary arrives from iCloud, the stats appear again, and the
/// book's first check files their stamps under the days the diary says they were earned.
///
/// **Append-only and forward-compatible, after the milestone ledger.** Each row is its own JSON
/// value under its id. Recording an id already present is a no-op, so the first-earned row wins and
/// a stamp's day never moves. A row this build cannot read — a stat a newer build added — is kept
/// byte for byte and written back untouched, never dropped. Nothing removes a row except "Delete
/// everything" (``clearPersistentState(in:)``), which takes the book's dated trail with the diary
/// it came from, as the milestone wipe does.
final class SillyStampStore {
    /// The `UserDefaults` keys the book persists under — device-local, never synced.
    private enum Key {
        static let rows = "fernlet.sillyStats.stamps"
        static let startDay = "fernlet.sillyStats.stampBookStartDay"
    }

    /// The most rows the book keeps (R3). Nineteen stats today; the headroom is for kinds a newer
    /// build adds, whose rows this build keeps without reading.
    static let maxRows = 256

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The book's first day on this device, or nil before its first check.
    var startDay: String? {
        defaults.string(forKey: Key.startDay)
    }

    /// Records the book's first day, once. Later calls keep the first.
    func begin(on dayKey: String) {
        guard startDay == nil, FernletDate.date(fromDayKey: dayKey) != nil else { return }
        defaults.set(dayKey, forKey: Key.startDay)
    }

    /// The stamps this build can read, oldest first (day, then the order they were recorded).
    func entries() -> [SillyStampEntry] {
        var read: [SillyStampEntry] = []
        for (id, data) in storedRows() {
            // A row this build cannot read (an unknown stat token, a damaged value) is left where it
            // is — not shown, not dropped — which is the forward-compatible half of the contract.
            guard let entry = try? decoder.decode(SillyStampEntry.self, from: data),
                  entry.id == id, entry.id == SillyStampEntry.id(for: entry.kind) else { continue }
            read.append(entry)
        }
        return read.sorted { ($0.dayKey, $0.createdAt, $0.id) < ($1.dayKey, $1.createdAt, $1.id) }
    }

    /// Appends `entries`, keeping any row already recorded under the same id.
    ///
    /// - Returns: the rows actually added. One whose id is already present, or that would take
    ///   the book past ``maxRows``, is not.
    func record(_ entries: [SillyStampEntry]) -> [SillyStampEntry] {
        var rows = storedRows()
        var added: [SillyStampEntry] = []
        for entry in entries where rows[entry.id] == nil && rows.count < Self.maxRows {
            do {
                rows[entry.id] = try encoder.encode(entry)
                added.append(entry)
            } catch {
                // R7: named, not swallowed. The stat stays unstamped and the next check tries again.
                FernletAuditLog.log("sillyStats.stampEncodeFailed", context: ["kind": entry.kind.rawValue])
            }
        }
        guard !added.isEmpty else { return [] }
        defaults.set(rows, forKey: Key.rows)
        return added
    }

    /// Forgets the whole book ("Delete everything", the DEBUG appearance seed hook and tests).
    static func clearPersistentState(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.rows)
        defaults.removeObject(forKey: Key.startDay)
    }

    /// Every stored row by id, readable or not, capped at ``maxRows`` whatever was written.
    private func storedRows() -> [String: Data] {
        let raw = defaults.dictionary(forKey: Key.rows) ?? [:]
        var rows: [String: Data] = [:]
        for (id, value) in raw.sorted(by: { $0.key < $1.key }) where rows.count < Self.maxRows {
            guard let data = value as? Data else { continue }
            rows[id] = data
        }
        return rows
    }
}

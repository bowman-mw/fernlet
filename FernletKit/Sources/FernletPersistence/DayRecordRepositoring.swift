// DayRecordRepositoring.swift
// FernletPersistence
//
// The persistence contract for per-day storage, kept in its own per-row store (separate from the snapshot
// blob) so each day union-merges across devices instead of the whole history being one last-writer-wins
// CloudKit record. The Core Data + iCloud implementation lives in `CloudKitSync`. Mirrors
// `CoinLedgerRepositoring`: `upsert` touches only the days it is handed and NEVER deletes rows it didn't
// receive, so one device can't clobber another device's synced days. Splitting days into rows is what lets
// the 370-day blob-size cap be removed (one day is far under CloudKit's per-record limit).

import Foundation
import FernletDomainModel

/// One day to persist, with its per-day last-writer-wins stamp. `dateKey` is the day's own `date`.
public nonisolated struct DayRecordUpsert {
    public var day: FernletDay
    public var updatedAt: Date

    public init(day: FernletDay, updatedAt: Date) {
        self.day = day
        self.updatedAt = updatedAt
    }

    public var dateKey: String { day.date }
}

@MainActor
public protocol DayRecordRepositoring {
    /// Every stored day, keyed by `dateKey`, duplicate rows collapsed by most-recent `updatedAt`.
    func loadAll() -> [String: FernletDay]
    /// Only the requested days (one-or-few-row predicate fetch), collapsed like `loadAll`.
    func load(dateKeys: [String]) -> [String: FernletDay]
    /// The most recent `limit` days, newest-first — for bounded derived-table rebuilds that must not load
    /// the whole history.
    func loadRecent(limit: Int) -> [FernletDay]
    /// Inserts or replaces (by `dateKey`) each day. Rows not listed are left untouched — never deleted.
    @discardableResult func upsert(_ days: [DayRecordUpsert]) -> Bool
    /// Removes only the rows whose `dateKey`s are listed; other rows are left untouched.
    @discardableResult func delete(dateKeys: [String]) -> Bool
    /// Removes every row (used only by a full account reset).
    @discardableResult func deleteAll() -> Bool
}

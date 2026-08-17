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
///
/// A `DayRecord` row is CloudKit-synced and uncapped, so — exactly like the aggregate-blob write boundary
/// (`SanitizedSnapshot`/`SanitizedDay`) — no *unstripped* day may reach it: a raw `FernletDay` can still
/// carry sealed-journal plaintext or cycle/intimate `healthContext`. The preferred production mint is
/// `init(sanitized:updatedAt:)`, which takes a `SanitizedDay` that has already passed the same privacy
/// strip the blob path enforces. The raw `init(day:updatedAt:)` is retained for two callers only:
/// (1) `saveSnapshot`/`updateDay`, which pass a day sourced from an already-minted
/// `SanitizedSnapshot`/`SanitizedDay`, and (2) tests. It MUST NOT be used to serialize a raw,
/// app-sourced day into a synced row — go through `SanitizedDay.sanitizing(...)` first.
public nonisolated struct DayRecordUpsert {
    /// The day payload to persist — in production, one that has already passed the privacy strip.
    public var day: FernletDay
    /// The per-day last-writer-wins stamp; duplicate rows collapse to the most recent.
    public var updatedAt: Date

    /// Raw mint: wraps `day` without any strip. Reserved for the two sanctioned callers named in the
    /// type discussion (days already sourced from a minted `Sanitized*` wrapper, and tests) — never
    /// for a raw, app-sourced day.
    public init(day: FernletDay, updatedAt: Date) {
        self.day = day
        self.updatedAt = updatedAt
    }

    /// The sanitize-barrier mint: the only way a synced day row should be built from app-sourced data. The
    /// wrapped `SanitizedDay.day` has already had sealed-journal text blanked and cycle/intimate nil'd.
    public init(sanitized: SanitizedDay, updatedAt: Date) {
        self.day = sanitized.day
        self.updatedAt = updatedAt
    }

    /// The row key — the day's own `date`.
    public var dateKey: String { day.date }
}

/// The persistence contract for the per-day row store that replaced the capped in-blob day history.
///
/// Each day is its own CloudKit-synced row keyed by `dateKey`, so days union-merge across devices
/// instead of the whole history riding one last-writer-wins CloudKit record — and splitting days into
/// rows is what let the 370-day blob-size cap be removed (one day is far under CloudKit's per-record
/// limit). ``upsert(_:)`` touches only the days it is handed and never deletes rows it didn't receive,
/// so one device can't clobber another device's synced days. Writes go through ``DayRecordUpsert``,
/// which carries the same sanitize-barrier obligation as the blob path (see its discussion). The Core
/// Data + iCloud conformer is `DayRecordRepository` (in `CloudKitSync`); `CoreDataFernletRepository`
/// and the store's history/derived-table rebuild paths load through it. `@MainActor`.
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
    func upsert(_ days: [DayRecordUpsert]) -> Bool
    /// Removes only the rows whose `dateKey`s are listed; other rows are left untouched.
    func delete(dateKeys: [String]) -> Bool
    /// Removes every row (used only by a full account reset).
    func deleteAll() -> Bool
}

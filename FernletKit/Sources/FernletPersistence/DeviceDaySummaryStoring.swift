// DeviceDaySummaryStoring.swift
// FernletPersistence
//
// Day summaries stay on the device that wrote them (owner decision 2026-10-15; spec: `DaySummaryText`
// is excluded from sync). `FernletSnapshot.storedDailyScores` strips `DailyHealthScore.daySummaryText`
// from every persisted copy of the score history, so neither the local blob nor the iCloud-mirrored one
// carries it; this protocol is the contract for the device-local store that keeps it instead. Another
// device, or a restore, writes its own: the launch backfill regenerates a summary for every logged day
// that has none.

import Foundation

/// The device-local store of the on-device AI day summaries — non-synced, excluded from device
/// backup, bounded — that keeps this device's `DailyHealthScore.daySummaryText` once
/// `FernletSnapshot.storedDailyScores` has stripped it from every persisted copy.
///
/// The same shape as ``DeviceHealthResidueStoring``, and deliberately a separate store: the HealthKit
/// opt-out empties the residue cache, and it must not take this device's summaries with it. The
/// file-backed conformer lives in the app target (never in a module the walled `CloudKitSync`
/// imports); `DiaryStore` reaches it only through this protocol — it overlays the summaries on every
/// score history it installs and records each summary it stores or invalidates. Keyed by `yyyy-MM-dd`
/// day key. `@MainActor`, like the per-row store contracts.
@MainActor
public protocol DeviceDaySummaryStoring: AnyObject {
    /// Every summary this device holds, keyed by day, or nil when the store cannot be read right now
    /// (the device is locked, a protection error) — a caller then keeps what it already shows rather
    /// than blanking it.
    func allSummaries() -> [String: String]?
    /// Records (or, for nil / empty text, removes) the summary for `dateKey`.
    ///
    /// - Returns: `false` when the change could not be persisted; the in-memory view may still hold
    ///   it. A success/failure signal, so not discardable (R7).
    func record(_ summary: String?, for dateKey: String) -> Bool
    /// Removes every summary and the capture marker below — "Delete everything". Returns `false`
    /// when something could not be removed.
    func clearAll() -> Bool
    /// Whether this device has kept the summaries a build before 2026-10-15 left in its persisted
    /// score history (the one-time capture `DiaryStore` runs when the store is attached).
    var legacySummariesCaptured: Bool { get }
    /// Records that the one-time capture completed. Returns `false` when that could not be persisted
    /// (the capture is idempotent, so the cost is one more pass next launch).
    func markLegacySummariesCaptured() -> Bool
}

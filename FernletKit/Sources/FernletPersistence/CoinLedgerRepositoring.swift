// CoinLedgerRepositoring.swift
// FernletPersistence
//
// The persistence contract for the coin ledger, kept in its own per-row store (separate from the
// snapshot blob) so it union-merges across devices instead of last-writer-wins. The Core Data + iCloud
// implementation lives in `CloudKitSync`. Mirrors `CustomItemRepositoring`, but the ledger is
// APPEND-ONLY: `append` upserts by id and NEVER deletes rows it didn't receive, so one device can't
// clobber another device's synced rows (the property the spend ledger relies on for correctness).

import Foundation
import FernletDomainModel

/// The persistence contract for the coin (care-currency) ledger's per-row synced store.
///
/// The ledger lives beside — not inside — the snapshot blob so its rows union-merge across devices
/// instead of last-writer-wins: ``append(_:)`` upserts by `id` and never deletes rows it didn't
/// receive, the property the spend ledger relies on for cross-device correctness (one device can't
/// clobber another device's synced spends or earnings). The Core Data + iCloud conformer is
/// `CoinLedgerRepository` (in `CloudKitSync`); `CoinLedgerService` (in `StoreCore`) owns the loaded
/// rows and computes the balance over them. `@MainActor`, like its sibling per-row contracts
/// ``CustomItemRepositoring`` and ``MilestoneLedgerRepositoring``.
@MainActor
public protocol CoinLedgerRepositoring {
    /// Loads every persisted ledger entry synchronously.
    func load() -> [CoinLedgerEntry]
    /// Awaitable variant of ``load()`` for callers off the blocking startup path.
    func loadAsync() async -> [CoinLedgerEntry]
    /// Inserts or replaces (by `id`) each entry. Rows not in `entries` are left untouched — never deleted.
    func append(_ entries: [CoinLedgerEntry]) -> Bool
    /// Removes every ledger row (used only by a full account reset).
    func deleteAll() -> Bool
    /// The reset-boundary markers minted on THIS device whose append to the synced store is not yet
    /// confirmed, read from the store's device-local, never-synced sidecar — oldest first, empty once
    /// every boundary has landed.
    ///
    /// The sidecar is what makes a wipe's boundary survive a process death between a failed marker
    /// append and its retry (tracker §3.6): `CoinLedgerService.reset()` records the marker here BEFORE
    /// a single row is deleted, every load merges these markers into the in-memory ledger — so rows
    /// another device syncs back stay void even while the synced marker is missing — and retries
    /// their append, and the sidecar is retired once the append lands.
    func pendingResetBoundaries() -> [CoinLedgerEntry]
    /// Durably replaces the pending set; an empty set retires the sidecar. Returns `false` when the
    /// markers did not reach durable storage.
    func savePendingResetBoundaries(_ markers: [CoinLedgerEntry]) -> Bool
}

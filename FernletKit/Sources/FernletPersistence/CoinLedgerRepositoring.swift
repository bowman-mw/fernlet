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
    @discardableResult func append(_ entries: [CoinLedgerEntry]) -> Bool
    /// Removes every ledger row (used only by a full account reset).
    @discardableResult func deleteAll() -> Bool
}

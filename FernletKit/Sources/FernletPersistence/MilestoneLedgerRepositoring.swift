// MilestoneLedgerRepositoring.swift
// FernletPersistence
//
// The persistence contract for the milestone (cumulative achievements) ledger — its own per-row
// store beside the coin ledger, union-merging across devices instead of last-writer-wins. The
// Core Data + iCloud implementation lives in `CloudKitSync`. Mirrors `CoinLedgerRepositoring` with
// one deliberate difference: there is NO delete API at all. Milestone rows are lifetime memories of
// care and survive `FernletStore.resetAll` by design — the contract makes that structural rather
// than a call-site convention. (The rows carry no content, only kind + day of a counted event;
// that metadata retention is the accepted cost of "your history of showing up can't be lost".)

import Foundation
import FernletDomainModel

/// The persistence contract for the milestone (cumulative achievements) ledger's per-row synced store.
///
/// Sits beside the coin ledger as its own union-merging row store — ``append(_:)`` upserts by `id` and
/// never deletes rows it didn't receive — with one deliberate difference from
/// ``CoinLedgerRepositoring``: there is NO delete API at all. Milestone rows are lifetime memories of
/// care and survive `FernletStore.resetAll` by design; the contract makes that structural rather than
/// a call-site convention. The rows carry no content, only the kind and day of a counted event — that
/// metadata retention is the accepted cost of "your history of showing up can't be lost". The Core
/// Data + iCloud conformer is `MilestoneLedgerRepository` (in `CloudKitSync`);
/// `MilestoneLedgerService` (in `StoreCore`) computes lifetime counts over the loaded rows. `@MainActor`.
@MainActor
public protocol MilestoneLedgerRepositoring {
    /// Loads every persisted milestone entry synchronously.
    func load() -> [MilestoneLedgerEntry]
    /// Awaitable variant of ``load()`` for callers off the blocking startup path.
    func loadAsync() async -> [MilestoneLedgerEntry]
    /// Inserts or replaces (by `id`) each entry. Rows not in `entries` are left untouched — never deleted.
    @discardableResult func append(_ entries: [MilestoneLedgerEntry]) -> Bool
}

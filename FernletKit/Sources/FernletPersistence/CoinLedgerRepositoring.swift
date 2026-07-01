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

@MainActor
public protocol CoinLedgerRepositoring {
    func load() -> [CoinLedgerEntry]
    func loadAsync() async -> [CoinLedgerEntry]
    /// Inserts or replaces (by `id`) each entry. Rows not in `entries` are left untouched — never deleted.
    @discardableResult func append(_ entries: [CoinLedgerEntry]) -> Bool
    /// Removes every ledger row (used only by a full account reset).
    @discardableResult func deleteAll() -> Bool
}

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

@MainActor
public protocol MilestoneLedgerRepositoring {
    func load() -> [MilestoneLedgerEntry]
    func loadAsync() async -> [MilestoneLedgerEntry]
    /// Inserts or replaces (by `id`) each entry. Rows not in `entries` are left untouched — never deleted.
    @discardableResult func append(_ entries: [MilestoneLedgerEntry]) -> Bool
}

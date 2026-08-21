// MilestoneLedgerRepositoring.swift
// FernletPersistence
//
// The persistence contract for the milestone (cumulative achievements) ledger — its own per-row
// store beside the coin ledger, union-merging across devices instead of last-writer-wins. The
// Core Data + iCloud implementation lives in `CloudKitSync`. Mirrors `CoinLedgerRepositoring` with
// one deliberate difference: this contract carries NO delete API. The one row delete —
// `deleteAll()`, added 2026-08-20 when "delete everything" stopped keeping the milestone trail
// (reversing the earlier survive-a-reset product rule) — lives only on the concrete CloudKitSync
// conformer, so the app's deletion funnel, which narrows to that type, is the only caller that can
// remove rows; every protocol-typed caller stays append-only, structurally. (The rows carry no
// content, only kind + day of a counted event — a dated metadata trail of the very content the
// wipe destroys, which is why the wipe now clears it.)

import Foundation
import FernletDomainModel

/// The persistence contract for the milestone (cumulative achievements) ledger's per-row synced store.
///
/// Sits beside the coin ledger as its own union-merging row store — ``append(_:)`` upserts by `id` and
/// never deletes rows it didn't receive — with one deliberate difference from
/// ``CoinLedgerRepositoring``: this contract carries NO delete API. The one row delete, `deleteAll()`,
/// lives only on the concrete conformer (added 2026-08-20, when `FernletStore.resetAll` started
/// clearing the ledger — reversing the earlier "milestone rows survive a reset" product rule), so
/// only the deletion funnel's `as?` narrowing can reach it and protocol-typed callers stay
/// append-only, structurally. The rows carry no content, only the kind and day of a counted event —
/// a dated metadata trail of the content the wipe destroys. The Core
/// Data + iCloud conformer is `MilestoneLedgerRepository` (in `CloudKitSync`);
/// `MilestoneLedgerService` (in `StoreCore`) computes lifetime counts over the loaded rows. `@MainActor`.
@MainActor
public protocol MilestoneLedgerRepositoring {
    /// Loads every persisted milestone entry synchronously.
    func load() -> [MilestoneLedgerEntry]
    /// Awaitable variant of ``load()`` for callers off the blocking startup path.
    func loadAsync() async -> [MilestoneLedgerEntry]
    /// Inserts or replaces (by `id`) each entry. Rows not in `entries` are left untouched — never deleted.
    func append(_ entries: [MilestoneLedgerEntry]) -> Bool
}

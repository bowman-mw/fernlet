// CustomItemRepositoring.swift
// FernletPersistence
//
// The persistence contract for user-designed custom items, kept in its own per-row store separate from
// the snapshot blob so a large closet never bloats the frequently-written character/day state. Mirrors
// `CoinLedgerRepositoring`: the store is APPEND/UPSERT-ONLY — `upsert` touches only the rows it is given
// and `delete` removes only the listed ids, so a stale in-memory set on one device can't clobber rows
// that synced in from another device. (This replaces an earlier full-replace `save(_:)` that deleted
// every row not in the passed set — a latent cross-device clobber the in-person clothing shop would
// trigger on every buy.) The Core Data + iCloud implementation lives in `CloudKitSync`.

import Foundation
import FernletDomainModel

/// The persistence contract for user-designed customization items' per-row synced store.
///
/// Kept separate from the snapshot blob so a large closet never bloats the frequently-written
/// character/day state. The store is append/upsert-only — ``upsert(_:)`` touches only the rows it is
/// given and ``delete(ids:)`` removes only the listed ids — so a stale in-memory set on one device
/// can't clobber rows that synced in from another (the earlier full-replace `save(_:)` had exactly that
/// latent cross-device clobber). The Core Data + iCloud conformer is `CustomItemRepository` (in
/// `CloudKitSync`); `CustomItemService` (in `StoreCore`) is the owning caller. `@MainActor`, like its
/// sibling per-row contracts ``CoinLedgerRepositoring`` and ``SavedRecipeRepositoring``.
@MainActor
public protocol CustomItemRepositoring {
    /// Loads every persisted custom item synchronously.
    func load() -> [CustomizationItem]
    /// Awaitable variant of ``load()`` for callers off the blocking startup path.
    func loadAsync() async -> [CustomizationItem]
    /// Inserts or replaces (by `id`) each item. Rows not in `items` are left untouched — never deleted.
    func upsert(_ items: [CustomizationItem]) -> Bool
    /// Removes only the rows whose ids are listed; other rows are left untouched.
    func delete(ids: [UUID]) -> Bool
    /// Removes every row (used only by a full account reset).
    func deleteAll() -> Bool
    /// Lifts an earlier deletion of `ids`, so the next ``upsert(_:)`` of them is written (G9-1: a
    /// deleted item's tombstone otherwise makes upserts of its id skip). Only for an item the person
    /// deliberately gets back.
    func restore(ids: [UUID]) -> Bool
}

public extension CustomItemRepositoring {
    // A store with no tombstones has nothing to lift.
    func restore(ids: [UUID]) -> Bool { true }
}

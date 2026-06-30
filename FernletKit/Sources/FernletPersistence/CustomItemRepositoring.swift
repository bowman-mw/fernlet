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

@MainActor
public protocol CustomItemRepositoring {
    func load() -> [CustomizationItem]
    func loadAsync() async -> [CustomizationItem]
    /// Inserts or replaces (by `id`) each item. Rows not in `items` are left untouched — never deleted.
    @discardableResult func upsert(_ items: [CustomizationItem]) -> Bool
    /// Removes only the rows whose ids are listed; other rows are left untouched.
    @discardableResult func delete(ids: [UUID]) -> Bool
    /// Removes every row (used only by a full account reset).
    @discardableResult func deleteAll() -> Bool
}

// CustomItemRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for user-designed custom items, separate from the snapshot blob so a
// growing closet never bloats the character/day state and items sync row by row. The load/upsert
// machinery is the shared `AppendOnlyRowStore` engine (also behind `CoinLedgerRepository` and
// `MilestoneLedgerRepository`): APPEND/UPSERT-ONLY — `upsert` touches only the rows it is given and
// `delete` soft-deletes only the listed ids (G9-1: a separate `RowTombstones` row per id, so another
// phone's stale edit cannot undo the delete), so a stale in-memory set on one device can't clobber rows synced
// in from another (the cross-device clobber the in-person clothing shop's buy would otherwise trigger).
// Each item is stored as a JSON `payloadData` blob keyed by its UUID.
//
// NOTE: like the coin ledger, this store does NOT collapse duplicate-id rows — CloudKit mirrors by record
// identity, not the `idString` attribute, so two devices that buy the same friend's item (which keeps its
// original id) can produce two rows. The dedup-by-id happens in `CustomItemService` on load.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Upsert-only per-row Core Data + iCloud store for user-designed `CustomizationItem`s.
///
/// The `CustomItemRepositoring` conformer under Core Data storage: each item is one
/// `CustomItemRecord` row (a JSON `payloadData` blob via `RowPayloadCoders`, keyed by the
/// item's UUID) so a growing closet never bloats the snapshot blob and items sync row by row.
/// Load and `upsert` delegate to the shared `AppendOnlyRowStore` engine: `upsert` touches only
/// the rows it is handed and `delete` removes only the listed ids — the discipline that stops a
/// stale in-memory set on one device from clobbering rows synced in from another (the
/// cross-device wipe the in-person clothing shop's buy would otherwise trigger). Both delete
/// methods stay local to this type (the engine has none). `delete(ids:)` is a SOFT delete (G9-1):
/// a content-free ``RowTombstones`` row per id (kept for good) plus a hard delete of the live row;
/// reads hide and heal tombstoned ids and `upsert` skips them, so a delete on one phone survives
/// another phone's stale edit. `deleteAll()` removes tombstones with everything else. Duplicate-id rows from two devices
/// buying the same friend's item are NOT collapsed here (CloudKit mirrors by record identity);
/// `CustomItemService` dedups on load. Failed saves assert in Debug builds, roll the context
/// back, and return `false`. MainActor-isolated by the module default, working on
/// ``PersistenceController``'s view context.
public struct CustomItemRepository: CustomItemRepositoring {
    private let controller: PersistenceController
    private let store: AppendOnlyRowStore<CustomizationItem>
    private let tombstones: RowTombstones

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
        self.store = AppendOnlyRowStore(
            controller: controller,
            entityName: "CustomItemRecord",
            loadTimingLabel: "CustomItemRepository.load",
            loadAsyncTimingLabel: "CustomItemRepository.loadAsync",
            auditStore: "customItem",
            idString: { $0.id.uuidString },
            createdAt: { $0.createdAt },
            loadPredicate: RowTombstones.liveRowsPredicate
        )
        self.tombstones = RowTombstones(
            controller: controller,
            entityName: "CustomItemRecord",
            dateKey: "createdAt",
            auditStore: "customItem"
        )
    }

    /// Loads every custom item that has not been deleted, oldest first; undecodable rows are
    /// dropped per row, and a live row for a deleted id (another phone's stale edit) is hidden and
    /// healed.
    public func load() -> [CustomizationItem] {
        visible(store.load())
    }

    /// Async-signature variant of `load()` (the fetch itself still runs on the main actor).
    public func loadAsync() async -> [CustomizationItem] {
        visible(await store.loadAsync())
    }

    /// Inserts or updates the given items by UUID, never deleting rows it wasn't handed. Items whose
    /// id has a tombstone are skipped (and audited by count): a deleted design is never re-created.
    ///
    /// - Returns: `false` when the tombstone lookup or the Core Data save fails (the context is
    ///   rolled back).
    public func upsert(_ items: [CustomizationItem]) -> Bool {
        guard !items.isEmpty else { return true }
        let deleted: Set<UUID>
        do {
            deleted = try tombstones.tombstonedIDs(among: items.map(\.id), in: controller.container.viewContext)
        } catch {
            PersistenceFailureAudit.record("customItem.upsert.failed", error: error)
            return false
        }
        let live = items.filter { !deleted.contains($0.id) }
        if live.count < items.count {
            FernletAuditLog.log("customItem.upsert.skippedDeleted", context: ["count": "\(items.count - live.count)"])
        }
        return store.append(live)
    }

    /// Soft-deletes the listed ids (G9-1): writes one content-free tombstone row per id and
    /// hard-deletes the live rows, in one save. A no-op write for ids already tombstoned.
    public func delete(ids: [UUID]) -> Bool {
        tombstones.softDelete(ids: ids, at: Date())
    }

    /// Drops tombstoned items from `items` and heals any live row that came back for one.
    private func visible(_ items: [CustomizationItem]) -> [CustomizationItem] {
        let deleted: Set<UUID>
        do {
            deleted = try tombstones.allTombstonedIDs(in: controller.container.viewContext)
        } catch {
            // Environmental (locked/unavailable store), like the engine's own fetch failure: serve
            // the empty list rather than risk showing deleted designs.
            PersistenceFailureAudit.record("rowStore.fetch.failed", error: error, context: ["store": "customItem"])
            return []
        }
        guard !deleted.isEmpty else { return items }
        tombstones.heal(ids: Set(items.map(\.id)).intersection(deleted))
        return items.filter { !deleted.contains($0.id) }
    }

    /// Removes every custom-item row — the delete-all/reset path.
    public func deleteAll() -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "CustomItemRecord")
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            PersistenceFailureAudit.record("customItem.deleteAll.failed", error: error)
            context.rollback()
            return false
        }
    }
}

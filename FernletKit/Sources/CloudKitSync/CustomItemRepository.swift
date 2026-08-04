// CustomItemRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for user-designed custom items, separate from the snapshot blob so a
// growing closet never bloats the character/day state and items sync row by row. Mirrors
// `CoinLedgerRepository`: APPEND/UPSERT-ONLY — `upsert` touches only the rows it is given and `delete`
// removes only the listed ids, so a stale in-memory set on one device can't clobber rows synced in from
// another (the cross-device clobber the in-person clothing shop's buy would otherwise trigger). Each item
// is stored as a JSON `payloadData` blob keyed by its UUID.
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
/// `CustomItemRecord` row (a JSON `payloadData` blob via ``RowPayloadCoders``, keyed by the
/// item's UUID) so a growing closet never bloats the snapshot blob and items sync row by row.
/// `upsert` touches only the rows it is handed and `delete` removes only the listed ids — the
/// discipline that stops a stale in-memory set on one device from clobbering rows synced in from
/// another (the cross-device wipe the in-person clothing shop's buy would otherwise trigger).
/// Duplicate-id rows from two devices buying the same friend's item are NOT collapsed here
/// (CloudKit mirrors by record identity); `CustomItemService` dedups on load. Failed saves
/// assert in Debug builds, roll the context back, and return `false`. MainActor-isolated by the
/// module default, working on ``PersistenceController``'s view context.
public struct CustomItemRepository: CustomItemRepositoring {
    private let controller: PersistenceController

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
    }

    /// Loads every custom item, oldest first; undecodable rows are dropped per row.
    public func load() -> [CustomizationItem] {
        StartupTiming.timed("CustomItemRepository.load") { loadRecords() }
    }

    /// Async-signature variant of `load()` (the fetch itself still runs on the main actor).
    public func loadAsync() async -> [CustomizationItem] {
        StartupTiming.timed("CustomItemRepository.loadAsync") { loadRecords() }
    }

    private func loadRecords() -> [CustomizationItem] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "CustomItemRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? context.fetch(request) else {
            assertionFailure("custom item fetch failed")
            return []
        }
        return records.compactMap(Self.item(from:))
    }

    /// Inserts or updates the given items by UUID, never deleting rows it wasn't handed.
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    @discardableResult public func upsert(_ items: [CustomizationItem]) -> Bool {
        guard !items.isEmpty else { return true }
        let context = controller.container.viewContext
        do {
            // Fetch ONLY the rows we're about to touch (predicate IN), then upsert by idString. We never
            // delete rows we weren't handed (unlike the old full-replace `save`), so flushing a stale set
            // can't wipe rows synced in from another device.
            let incomingIDs = items.map { $0.id.uuidString }
            let request = NSFetchRequest<NSManagedObject>(entityName: "CustomItemRecord")
            request.predicate = NSPredicate(format: "idString IN %@", incomingIDs)
            var existingByID: [String: NSManagedObject] = [:]
            for record in try context.fetch(request) {
                if let idString = record.value(forKey: "idString") as? String {
                    existingByID[idString] = record
                }
            }
            let encoder = RowPayloadCoders.makeEncoder()
            for item in items {
                guard let payload = try? encoder.encode(item) else {
                    assertionFailure("custom item encode failed")
                    continue
                }
                let record = existingByID[item.id.uuidString]
                    ?? NSEntityDescription.insertNewObject(forEntityName: "CustomItemRecord", into: context)
                record.setValue(item.id.uuidString, forKey: "idString")
                record.setValue(payload, forKey: "payloadData")
                record.setValue(item.createdAt, forKey: "createdAt")
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("custom item Core Data upsert failed")
            context.rollback()
            return false
        }
    }

    /// Deletes only the rows with the listed ids (a no-op for ids with no row).
    @discardableResult public func delete(ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { return true }
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "CustomItemRecord")
        request.predicate = NSPredicate(format: "idString IN %@", ids.map { $0.uuidString })
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("custom item delete failed")
            context.rollback()
            return false
        }
    }

    /// Removes every custom-item row — the delete-all/reset path.
    @discardableResult public func deleteAll() -> Bool {
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
            assertionFailure("custom item delete-all failed")
            context.rollback()
            return false
        }
    }

    private static func item(from record: NSManagedObject) -> CustomizationItem? {
        guard let data = record.value(forKey: "payloadData") as? Data else { return nil }
        return try? RowPayloadCoders.makeDecoder().decode(CustomizationItem.self, from: data)
    }
}

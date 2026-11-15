// RowTombstones.swift
// CloudKitSync
//
// G9-1 soft delete (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md, Part 1, S3 = A): the shared
// deletion-record helper for the per-row `idString + payloadData` entities (`CustomItemRecord`,
// `SavedRecipeRecord`; G9-3 reuses it for `MemoryRecord`).
//
// Why a SEPARATE row: NSPersistentCloudKitContainer mirrors each row as one CloudKit record, and two
// phones' writes to one record are last-writer-wins. A `deletedAt` written INTO the live row is lost
// the moment another phone (that has not yet heard of the delete) edits the item — a price change
// overwrites the whole record and the deleted design comes back. So a delete writes a tombstone row of
// its own, keyed `idString = "tombstone:" + uuid`, and hard-deletes the live row. A phone editing the
// live item upserts by the plain uuid, so it never touches the tombstone record. Readers hide every
// tombstoned id and heal (hard-delete) a live row that came back from another phone's stale edit.
//
// Tombstones are kept for good (S4 = C: no pruning, no window a long-offline phone could slip through);
// "Delete everything" removes them with the rest of the entity. The payload carries only the id, the
// date and a `format` number (S5 = C) — nothing of the deleted item.

import Foundation
import CoreData
import FernletFoundation

/// The JSON payload of one tombstone row: the deleted item's id, when it was deleted, and the row
/// format number.
///
/// Holds nothing of the deleted item's content (no name, no design, no recipe text), so a deletion
/// still erases the content from the phone and iCloud; a tombstone is about 100 bytes. `format` is
/// `decodeIfPresent` (missing = 0) and the decode ignores unknown keys, so a tombstone written by a
/// LATER build still reads here — and is still honoured as a delete. Readers never rewrite a tombstone,
/// whatever its format.
nonisolated struct RowTombstonePayload: Codable, Equatable, Sendable {
    /// The format this build writes. A tombstone with a higher number came from a later build.
    static let currentFormat = 1

    /// The deleted item's id.
    var id: UUID
    /// When the item was deleted.
    var deletedAt: Date
    /// The payload format number (S5 = C); 0 when the key is missing.
    var format: Int

    init(id: UUID, deletedAt: Date, format: Int = RowTombstonePayload.currentFormat) {
        self.id = id
        self.deletedAt = deletedAt
        self.format = format
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        deletedAt = try container.decode(Date.self, forKey: .deletedAt)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? 0
    }
}

/// Soft-delete helper for one per-row Core Data + iCloud entity keyed by `idString`.
///
/// Writes, reads and honours tombstone rows (`idString = "tombstone:" + uuid`, a
/// ``RowTombstonePayload`` in `payloadData`) beside the entity's live rows. ``softDelete(ids:at:)``
/// inserts the tombstone and hard-deletes the live row in one save; ``tombstonedIDs(among:in:)`` and
/// ``allTombstonedIDs(in:)`` are what readers and upserts filter by; ``heal(ids:)`` hard-deletes live
/// rows that came back for a tombstoned id. The tombstoned id is read from the row's `idString`, not
/// its payload, so a tombstone from a later build whose payload this build cannot decode is still a
/// delete. Tombstone rows are never rewritten or pruned here; the owning repository's `deleteAll()`
/// removes them with everything else. Failures are environmental and audited under
/// `"<auditStore>.delete.failed"` / `"<auditStore>.tombstone.*"` (frozen tokens). MainActor-isolated
/// by the module default, working on ``PersistenceController``'s view context.
struct RowTombstones {
    /// The FROZEN `idString` prefix that marks a tombstone row. A token, never display text.
    static let idPrefix = "tombstone:"

    /// The persistence controller whose view context all reads and writes run on.
    let controller: PersistenceController
    /// The Core Data entity the tombstones live in, beside its live rows.
    let entityName: String
    /// The date attribute the entity sorts by (`createdAt`, `savedAt`); set to the deletion date.
    let dateKey: String
    /// The FROZEN English store token audit events are prefixed with (`"customItem"`, `"savedRecipe"`).
    let auditStore: String

    /// The predicate that excludes tombstone rows, for a load fetch that wants live rows only.
    static var liveRowsPredicate: NSPredicate {
        NSPredicate(format: "NOT (idString BEGINSWITH %@)", idPrefix)
    }

    /// The tombstone `idString` for an item id.
    static func tombstoneIDString(for id: UUID) -> String {
        idPrefix + id.uuidString
    }

    /// The item id a tombstone `idString` names, or `nil` when it is not a tombstone.
    static func tombstonedID(fromIDString idString: String) -> UUID? {
        guard idString.hasPrefix(idPrefix) else { return nil }
        return UUID(uuidString: String(idString.dropFirst(idPrefix.count)))
    }

    /// Every tombstoned id in the entity.
    func allTombstonedIDs(in context: NSManagedObjectContext) throws -> Set<UUID> {
        try fetchTombstonedIDs(NSPredicate(format: "idString BEGINSWITH %@", Self.idPrefix), in: context)
    }

    /// The subset of `ids` that has a tombstone.
    func tombstonedIDs(among ids: [UUID], in context: NSManagedObjectContext) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let idStrings = ids.map(Self.tombstoneIDString(for:))
        return try fetchTombstonedIDs(NSPredicate(format: "idString IN %@", idStrings), in: context)
    }

    /// Soft-deletes `ids`: one tombstone row per id that has none yet, and every live row for those
    /// ids hard-deleted, in one save.
    ///
    /// - Returns: `false` when the fetch or save fails (the context is rolled back and the failure is
    ///   audited as `"<auditStore>.delete.failed"`).
    func softDelete(ids: [UUID], at deletedAt: Date) -> Bool {
        guard !ids.isEmpty else { return true }
        let context = controller.container.viewContext
        do {
            let existing = try tombstonedIDs(among: ids, in: context)
            let encoder = RowPayloadCoders.makeEncoder()
            for id in Set(ids) where !existing.contains(id) {
                let payload = try encoder.encode(RowTombstonePayload(id: id, deletedAt: deletedAt))
                let record = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
                record.setValue(Self.tombstoneIDString(for: id), forKey: "idString")
                record.setValue(payload, forKey: "payloadData")
                record.setValue(deletedAt, forKey: dateKey)
            }
            try deleteLiveRows(ids: ids, in: context)
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            PersistenceFailureAudit.record("\(auditStore).delete.failed", error: error)
            context.rollback()
            return false
        }
    }

    /// Hard-deletes the live rows for tombstoned `ids` — rows another phone's stale edit brought
    /// back. Audit-logged by count only. A failed save is rolled back and audited; the rows stay
    /// hidden by the read filter either way, so the next read retries.
    func heal(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let context = controller.container.viewContext
        do {
            let removed = try deleteLiveRows(ids: Array(ids), in: context)
            if context.hasChanges {
                try context.save()
            }
            FernletAuditLog.log("\(auditStore).tombstone.healed", context: ["count": "\(removed)"])
        } catch {
            PersistenceFailureAudit.record("\(auditStore).tombstone.heal.failed", error: error)
            context.rollback()
        }
    }

    /// Deletes (without saving) every live row whose `idString` is one of `ids`; returns the count
    /// (a count, not a success flag — failure is the thrown error).
    @discardableResult
    private func deleteLiveRows(ids: [UUID], in context: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "idString IN %@", ids.map { $0.uuidString })
        let records = try context.fetch(request)
        for record in records {
            context.delete(record)
        }
        return records.count
    }

    private func fetchTombstonedIDs(_ predicate: NSPredicate, in context: NSManagedObjectContext) throws -> Set<UUID> {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = predicate
        var ids: Set<UUID> = []
        for record in try context.fetch(request) {
            if let idString = record.value(forKey: "idString") as? String,
               let id = Self.tombstonedID(fromIDString: idString) {
                ids.insert(id)
            }
        }
        return ids
    }
}

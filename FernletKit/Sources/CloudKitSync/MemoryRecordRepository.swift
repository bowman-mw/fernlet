// MemoryRecordRepository.swift
// CloudKitSync
//
// G9-3 (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md, Part 3, owner call M1 = A): Core memories
// leave the aggregate blob for one `MemoryRecord` row each. Before this, a forget on phone A could be
// undone the moment phone B (which still had the memory) wrote the whole blob back. Each memory is now
// its own CloudKit record, and a forget writes a separate tombstone record (`RowTombstones`, shared with
// custom items and saved recipes) that a stale write of the memory can never overwrite.
//
// The load/upsert engine is the shared `AppendOnlyRowStore`; this type adds the soft delete, the
// blob-to-row adoption that never overwrites, and the wipe.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Upsert-only per-row Core Data + iCloud store for Core memories (`MemoryNote`), with soft delete.
///
/// The ``MemoryRepositoring`` conformer under Core Data storage, owned by
/// ``CoreDataFernletRepository``. Each memory is one `MemoryRecord` row (a JSON `payloadData` blob via
/// `RowPayloadCoders`, keyed by the memory's UUID, stamped `updatedAt`). ``load()`` hides every
/// tombstoned id and heals (hard-deletes) a live row another phone's stale write brought back;
/// ``upsert(_:)`` skips tombstoned ids; ``delete(ids:)`` writes a content-free tombstone per id and
/// hard-deletes the live row in one save; ``adoptMissing(_:)`` writes only memories with no row and no
/// tombstone (the blob-to-row copy); ``deleteAll()`` removes everything, tombstones included. Unlike
/// custom items there is no `restore`: nothing brings a forgotten memory back. Failures are
/// environmental and audited under the FROZEN store token `"memory"`; a failed save rolls back and
/// returns `false`. MainActor-isolated by the module default, on ``PersistenceController``'s view context.
public struct MemoryRecordRepository: MemoryRepositoring {
    /// The Core Data entity name (a frozen token: it is the CloudKit record type `CD_MemoryRecord`).
    static let entityName = "MemoryRecord"

    private let controller: PersistenceController
    private let store: AppendOnlyRowStore<MemoryNote>
    private let tombstones: RowTombstones

    /// A repository on the shared persistence controller.
    public init() {
        self.init(controller: .shared)
    }

    /// A repository on `controller` (tests pass an in-memory one).
    public init(controller: PersistenceController) {
        self.controller = controller
        var store = AppendOnlyRowStore<MemoryNote>(
            controller: controller,
            entityName: Self.entityName,
            loadTimingLabel: "MemoryRecordRepository.load",
            loadAsyncTimingLabel: "MemoryRecordRepository.loadAsync",
            auditStore: "memory",
            idString: { $0.id.uuidString },
            createdAt: { _ in Date() },
            loadPredicate: RowTombstones.liveRowsPredicate
        )
        store.dateKey = "updatedAt"
        self.store = store
        self.tombstones = RowTombstones(
            controller: controller,
            entityName: Self.entityName,
            dateKey: "updatedAt",
            auditStore: "memory"
        )
    }

    /// Every live memory, oldest `sourceDate` first; tombstoned ids are hidden and their live rows
    /// healed. A duplicate-id pair (two phones adopting the same blob memory before they synced)
    /// collapses to the copy read last.
    public func load() -> [MemoryNote] {
        // Environmental (locked/unavailable store): serve nothing rather than risk showing a
        // forgotten memory.
        loadIfReadable() ?? []
    }

    /// ``load()``, or nil when the rows or their tombstones could not be read (audited). The caller
    /// that soft-deletes by absence (`CoreDataFernletRepository`) reads through this, so a failed
    /// fetch is never taken for "every memory was forgotten".
    public func loadIfReadable() -> [MemoryNote]? {
        guard let rows = store.loadIfReadable() else { return nil }
        let deleted: Set<UUID>
        do {
            deleted = try tombstones.allTombstonedIDs(in: controller.container.viewContext)
        } catch {
            PersistenceFailureAudit.record("rowStore.fetch.failed", error: error, context: ["store": "memory"])
            return nil
        }
        if !deleted.isEmpty {
            tombstones.heal(ids: Set(rows.map(\.id)).intersection(deleted))
        }
        var byID: [UUID: MemoryNote] = [:]
        for memory in rows where !deleted.contains(memory.id) {
            byID[memory.id] = memory
        }
        return byID.values.sorted { ($0.sourceDate, $0.id.uuidString) < ($1.sourceDate, $1.id.uuidString) }
    }

    /// Inserts or updates the given memories by id, never touching rows it was not handed. Tombstoned
    /// ids are skipped (audited by count): a forgotten memory is never written again.
    ///
    /// - Returns: `false` when the tombstone lookup or the save fails (rolled back).
    public func upsert(_ memories: [MemoryNote]) -> Bool {
        guard !memories.isEmpty else { return true }
        let deleted: Set<UUID>
        do {
            deleted = try tombstones.tombstonedIDs(among: memories.map(\.id), in: controller.container.viewContext)
        } catch {
            PersistenceFailureAudit.record("memory.upsert.failed", error: error)
            return false
        }
        let live = memories.filter { !deleted.contains($0.id) }
        if live.count < memories.count {
            FernletAuditLog.log("memory.upsert.skippedDeleted", context: ["count": "\(memories.count - live.count)"])
        }
        return store.append(live)
    }

    /// Writes only the memories that have neither a live row nor a tombstone — the blob-to-row copy.
    /// A memory another phone already wrote (perhaps edited) keeps its row, and a forgotten one stays
    /// forgotten.
    ///
    /// - Returns: `false` when a lookup or the save fails (rolled back).
    public func adoptMissing(_ memories: [MemoryNote]) -> Bool {
        guard !memories.isEmpty else { return true }
        let context = controller.container.viewContext
        let present: Set<UUID>
        do {
            let ids = memories.map(\.id)
            present = try liveIDs(among: ids, in: context)
                .union(tombstones.tombstonedIDs(among: ids, in: context))
        } catch {
            PersistenceFailureAudit.record("memory.adopt.failed", error: error)
            return false
        }
        var seen: Set<UUID> = []
        let missing = memories.filter { !present.contains($0.id) && seen.insert($0.id).inserted }
        FernletAuditLog.log("memory.adopt", context: ["written": "\(missing.count)", "skipped": "\(memories.count - missing.count)"])
        return store.append(missing)
    }

    /// Soft-deletes the listed ids: one content-free tombstone per id and the live rows removed, in one
    /// save. Already-tombstoned ids are a no-op write.
    public func delete(ids: [UUID]) -> Bool {
        tombstones.softDelete(ids: ids, at: Date())
    }

    /// Removes every memory row and every tombstone — the "delete everything" path.
    public func deleteAll() -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            PersistenceFailureAudit.record("memory.deleteAll.failed", error: error)
            context.rollback()
            return false
        }
    }

    /// The subset of `ids` that has a live (non-tombstone) row.
    private func liveIDs(among ids: [UUID], in context: NSManagedObjectContext) throws -> Set<UUID> {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.predicate = NSPredicate(format: "idString IN %@", ids.map(\.uuidString))
        var found: Set<UUID> = []
        for record in try context.fetch(request) {
            if let idString = record.value(forKey: "idString") as? String, let id = UUID(uuidString: idString) {
                found.insert(id)
            }
        }
        return found
    }
}

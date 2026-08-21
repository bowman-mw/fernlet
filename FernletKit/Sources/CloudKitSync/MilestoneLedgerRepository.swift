// MilestoneLedgerRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for the milestone ledger, separate from the snapshot blob so
// each device's event rows sync independently instead of last-writer-wins on a shared blob. The
// load/upsert machinery is the shared `AppendOnlyRowStore` engine (also behind
// `CoinLedgerRepository` and `CustomItemRepository` — append/upsert-only, JSON `payloadData` keyed
// by id); like the coin store, the one delete is `deleteAll()`, kept local to this type because the
// engine has none.
//
// `deleteAll()` is the wipe path, and it is not optional: the rows are a dated METADATA TRAIL of the
// content "delete everything" destroys — a journal entry happened on this day, a worry was let go on
// that one — held in Core Data AND, mirrored, in the user's CloudKit private database. The delete
// walks the rows through the view context object by object, exactly like `CoinLedgerRepository`: an
// `NSBatchDeleteRequest` bypasses NSPersistentCloudKitContainer's mirror, which would drop the local
// rows and leave the cloud copies to sync straight back.
//
// NOTE: like the coin store, this does NOT collapse duplicate-id rows across devices — CloudKit
// mirrors by record identity, so two devices that mint the same deterministic id produce two rows.
// The dedup-by-id ("union-merge") happens in `MilestoneEconomy` aggregation, not here.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Append-only per-row Core Data + iCloud store for `MilestoneLedgerEntry` rows, plus the
/// delete-all wipe path.
///
/// The `MilestoneLedgerRepositoring` conformer under Core Data storage: the shared
/// `AppendOnlyRowStore` engine (JSON `payloadData` via `RowPayloadCoders`, keyed by the
/// entry's deterministic `idString`) with ``deleteAll()`` added on top — normal operation never
/// deletes a row, and only "delete everything" does. One device upserts by id so re-mints are
/// no-ops; duplicate-id rows across devices are not collapsed here (CloudKit mirrors by record
/// identity) — `MilestoneEconomy` union-merges them on aggregation. Rows whose payload an older
/// build can't decode (an unknown newer `MilestoneEventKind`) are dropped per row on read.
/// MainActor-isolated by the module default, working on ``PersistenceController``'s view context.
///
/// Invariant of ``deleteAll()``: it deletes objects through the view context, never with an
/// `NSBatchDeleteRequest` — a batch delete skips the CloudKit mirror, so the rows would go here
/// and stay in the user's private database, which is the half of this trail the wipe most needs.
public struct MilestoneLedgerRepository: MilestoneLedgerRepositoring {
    private let controller: PersistenceController
    private let store: AppendOnlyRowStore<MilestoneLedgerEntry>

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
        self.store = AppendOnlyRowStore(
            controller: controller,
            entityName: "MilestoneLedgerRecord",
            loadTimingLabel: "MilestoneLedgerRepository.load",
            loadAsyncTimingLabel: "MilestoneLedgerRepository.loadAsync",
            debugLabel: "milestone ledger",
            saveFailureMessage: "milestone ledger Core Data save failed",
            idString: { $0.id },
            createdAt: { $0.createdAt }
        )
    }

    /// Loads every milestone entry, oldest first; undecodable rows are dropped per row.
    public func load() -> [MilestoneLedgerEntry] {
        store.load()
    }

    /// Async-signature variant of `load()` (the fetch itself still runs on the main actor).
    public func loadAsync() async -> [MilestoneLedgerEntry] {
        await store.loadAsync()
    }

    /// Upserts the given entries by `idString`; rows not in `entries` are never touched — the only
    /// row removal anywhere is ``deleteAll()``.
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    public func append(_ entries: [MilestoneLedgerEntry]) -> Bool {
        store.append(entries)
    }

    /// Removes every milestone row — the delete-all/reset path only (normal operation never deletes).
    ///
    /// Object-by-object through the view context, so the deletes reach the CloudKit mirror and the
    /// user's private database loses the trail too (see the type's invariant).
    ///
    /// - Returns: `false` when the fetch or the save fails (the context is rolled back). Not
    ///   discardable (R7): the wipe must be able to name a milestone trail it failed to remove
    ///   instead of reporting a complete deletion.
    public func deleteAll() -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MilestoneLedgerRecord")
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("milestone ledger delete-all failed")
            context.rollback()
            return false
        }
    }
}

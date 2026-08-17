// CoinLedgerRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for the coin ledger, separate from the snapshot blob so each device's
// earn/spend rows sync independently instead of last-writer-wins on a shared blob. The load/upsert
// machinery is the shared `AppendOnlyRowStore` engine (also behind `MilestoneLedgerRepository` and
// `CustomItemRepository`); this store is APPEND-ONLY — `append` upserts the rows it is given and never
// deletes others, so a stale in-memory set on one device can't wipe rows that synced in from another
// device. Each entry is a JSON `payloadData` blob keyed by its id. The only delete is the local
// `deleteAll()` reset path.
//
// NOTE: this store does NOT collapse duplicate-id rows across devices — CloudKit mirrors by record
// identity, not by the `idString` attribute, so two devices that mint the same deterministic id produce
// two rows. The dedup-by-id ("union-merge") happens in `CoinEconomy` aggregation, not here.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Append-only per-row Core Data + iCloud store for `CoinLedgerEntry` rows.
///
/// The `CoinLedgerRepositoring` conformer used under Core Data storage. Each entry is one
/// `CoinLedgerRecord` row — a JSON `payloadData` blob (encoded via `RowPayloadCoders`) keyed
/// by the entry's stable deterministic `idString` — so each device's earn/spend rows sync
/// independently instead of last-writer-wins on the snapshot blob. Load and `append` delegate
/// to the shared `AppendOnlyRowStore` engine: `append` upserts only the rows it is handed and
/// never deletes others, so a stale in-memory set on one device cannot wipe rows synced in from
/// another. Duplicate-id rows minted by two devices are NOT collapsed here (CloudKit mirrors by
/// record identity, not `idString`); the union-merge dedup lives in `CoinEconomy` aggregation.
/// Failed saves assert in Debug builds, roll the context back, and return `false`. The one
/// delete path is `deleteAll()`, kept local to this type (the engine has none). MainActor-isolated
/// by the module default, working on ``PersistenceController``'s view context.
public struct CoinLedgerRepository: CoinLedgerRepositoring {
    private let controller: PersistenceController
    private let store: AppendOnlyRowStore<CoinLedgerEntry>

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
        self.store = AppendOnlyRowStore(
            controller: controller,
            entityName: "CoinLedgerRecord",
            loadTimingLabel: "CoinLedgerRepository.load",
            loadAsyncTimingLabel: "CoinLedgerRepository.loadAsync",
            debugLabel: "coin ledger",
            saveFailureMessage: "coin ledger Core Data save failed",
            idString: { $0.id },
            createdAt: { $0.createdAt }
        )
    }

    /// Loads every ledger entry, oldest first; undecodable rows are dropped per row.
    public func load() -> [CoinLedgerEntry] {
        store.load()
    }

    /// Async-signature variant of `load()` (the fetch itself still runs on the main actor).
    public func loadAsync() async -> [CoinLedgerEntry] {
        await store.loadAsync()
    }

    /// Upserts the given entries by `idString`, never deleting rows it wasn't handed.
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    // R7 exception: the attribute stays only because out-of-slice callers in Tests/FernletTests
    // still discard this result on the CONCRETE type; removing it here would break their build.
    @discardableResult public func append(_ entries: [CoinLedgerEntry]) -> Bool {
        store.append(entries)
    }

    /// Removes every ledger row — the delete-all/reset path only (normal operation never deletes).
    public func deleteAll() -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "CoinLedgerRecord")
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("coin ledger delete-all failed")
            context.rollback()
            return false
        }
    }
}

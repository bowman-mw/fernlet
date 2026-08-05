// MilestoneLedgerRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for the milestone ledger, separate from the snapshot blob so
// each device's event rows sync independently instead of last-writer-wins on a shared blob. The
// load/upsert machinery is the shared `AppendOnlyRowStore` engine (also behind
// `CoinLedgerRepository` and `CustomItemRepository` — append/upsert-only, JSON `payloadData` keyed
// by id), and unlike its siblings this type adds no delete path at all: milestone rows survive a
// full data reset by design (see `MilestoneLedgerRepositoring`).
//
// NOTE: like the coin store, this does NOT collapse duplicate-id rows across devices — CloudKit
// mirrors by record identity, so two devices that mint the same deterministic id produce two rows.
// The dedup-by-id ("union-merge") happens in `MilestoneEconomy` aggregation, not here.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Append-only per-row Core Data + iCloud store for `MilestoneLedgerEntry` rows — with no delete path.
///
/// The `MilestoneLedgerRepositoring` conformer under Core Data storage: the shared
/// ``AppendOnlyRowStore`` engine (JSON `payloadData` via ``RowPayloadCoders``, keyed by the
/// entry's deterministic `idString`) with no deletion added on top — milestone rows are lifetime
/// memories of care that survive a full data reset by design, a guarantee the contract makes
/// structural (the engine itself has no delete method, and this type adds none).
/// One device upserts by id so re-mints are no-ops; duplicate-id rows across devices are not
/// collapsed here (CloudKit mirrors by record identity) — `MilestoneEconomy` union-merges them
/// on aggregation. Rows whose payload an older build can't decode (an unknown newer
/// `MilestoneEventKind`) are dropped per row on read. MainActor-isolated by the module default,
/// working on ``PersistenceController``'s view context.
public struct MilestoneLedgerRepository: MilestoneLedgerRepositoring {
    private let store: AppendOnlyRowStore<MilestoneLedgerEntry>

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
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

    /// Upserts the given entries by `idString`; rows not in `entries` are never touched, and
    /// there is no delete counterpart at all.
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    @discardableResult public func append(_ entries: [MilestoneLedgerEntry]) -> Bool {
        store.append(entries)
    }
}

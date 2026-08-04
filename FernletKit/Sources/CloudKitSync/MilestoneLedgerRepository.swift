// MilestoneLedgerRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for the milestone ledger, separate from the snapshot blob so
// each device's event rows sync independently instead of last-writer-wins on a shared blob. A
// direct clone of `CoinLedgerRepository` (append/upsert-only, JSON `payloadData` keyed by id) with
// no delete path at all: milestone rows survive a full data reset by design (see
// `MilestoneLedgerRepositoring`).
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
/// The `MilestoneLedgerRepositoring` conformer under Core Data storage: a direct clone of
/// ``CoinLedgerRepository`` (JSON `payloadData` via ``RowPayloadCoders``, keyed by the entry's
/// deterministic `idString`) minus deletion entirely — milestone rows are lifetime memories of
/// care that survive a full data reset by design, a guarantee the contract makes structural.
/// One device upserts by id so re-mints are no-ops; duplicate-id rows across devices are not
/// collapsed here (CloudKit mirrors by record identity) — `MilestoneEconomy` union-merges them
/// on aggregation. Rows whose payload an older build can't decode (an unknown newer
/// `MilestoneEventKind`) are dropped per row on read. MainActor-isolated by the module default,
/// working on ``PersistenceController``'s view context.
public struct MilestoneLedgerRepository: MilestoneLedgerRepositoring {
    private let controller: PersistenceController

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
    }

    /// Loads every milestone entry, oldest first; undecodable rows are dropped per row.
    public func load() -> [MilestoneLedgerEntry] {
        StartupTiming.timed("MilestoneLedgerRepository.load") { loadRecords() }
    }

    /// Async-signature variant of `load()` (the fetch itself still runs on the main actor).
    public func loadAsync() async -> [MilestoneLedgerEntry] {
        StartupTiming.timed("MilestoneLedgerRepository.loadAsync") { loadRecords() }
    }

    private func loadRecords() -> [MilestoneLedgerEntry] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "MilestoneLedgerRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? context.fetch(request) else {
            assertionFailure("milestone ledger fetch failed")
            return []
        }
        return records.compactMap(Self.entry(from:))
    }

    /// Upserts the given entries by `idString`; rows not in `entries` are never touched, and
    /// there is no delete counterpart at all.
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    @discardableResult public func append(_ entries: [MilestoneLedgerEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        let context = controller.container.viewContext
        do {
            // Look up the rows we're about to touch in ONE fetch, then upsert by idString. We never
            // delete rows we weren't handed — the ledger is append-only, so flushing a stale set
            // can't clobber rows synced from another device.
            let incomingIDs = entries.map(\.id)
            let request = NSFetchRequest<NSManagedObject>(entityName: "MilestoneLedgerRecord")
            request.predicate = NSPredicate(format: "idString IN %@", incomingIDs)
            var existingByID: [String: NSManagedObject] = [:]
            for record in try context.fetch(request) {
                if let idString = record.value(forKey: "idString") as? String {
                    existingByID[idString] = record
                }
            }
            let encoder = RowPayloadCoders.makeEncoder()
            for entry in entries {
                guard let payload = try? encoder.encode(entry) else {
                    assertionFailure("milestone ledger encode failed")
                    continue
                }
                let record = existingByID[entry.id]
                    ?? NSEntityDescription.insertNewObject(forEntityName: "MilestoneLedgerRecord", into: context)
                record.setValue(entry.id, forKey: "idString")
                record.setValue(payload, forKey: "payloadData")
                record.setValue(entry.createdAt, forKey: "createdAt")
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("milestone ledger Core Data save failed")
            context.rollback()
            return false
        }
    }

    private static func entry(from record: NSManagedObject) -> MilestoneLedgerEntry? {
        guard let data = record.value(forKey: "payloadData") as? Data else { return nil }
        // Per-row `try?`: an old app version that doesn't know a newer `MilestoneEventKind` drops
        // just that row — graceful forward-compat, same as the coin ledger.
        return try? RowPayloadCoders.makeDecoder().decode(MilestoneLedgerEntry.self, from: data)
    }
}

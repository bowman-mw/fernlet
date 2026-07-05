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

public struct MilestoneLedgerRepository: MilestoneLedgerRepositoring {
    private let controller: PersistenceController

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
    }

    public func load() -> [MilestoneLedgerEntry] {
        StartupTiming.timed("MilestoneLedgerRepository.load") { loadRecords() }
    }

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

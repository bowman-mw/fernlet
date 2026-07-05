// CoinLedgerRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for the coin ledger, separate from the snapshot blob so each device's
// earn/spend rows sync independently instead of last-writer-wins on a shared blob. Mirrors
// `CustomItemRepository`, with one deliberate difference: this store is APPEND-ONLY — `append` upserts
// the rows it is given and never deletes others, so a stale in-memory set on one device can't wipe rows
// that synced in from another device. Each entry is a JSON `payloadData` blob keyed by its id.
//
// NOTE: this store does NOT collapse duplicate-id rows across devices — CloudKit mirrors by record
// identity, not by the `idString` attribute, so two devices that mint the same deterministic id produce
// two rows. The dedup-by-id ("union-merge") happens in `CoinEconomy` aggregation, not here.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

public struct CoinLedgerRepository: CoinLedgerRepositoring {
    private let controller: PersistenceController

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
    }

    public func load() -> [CoinLedgerEntry] {
        StartupTiming.timed("CoinLedgerRepository.load") { loadRecords() }
    }

    public func loadAsync() async -> [CoinLedgerEntry] {
        StartupTiming.timed("CoinLedgerRepository.loadAsync") { loadRecords() }
    }

    private func loadRecords() -> [CoinLedgerEntry] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "CoinLedgerRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? context.fetch(request) else {
            assertionFailure("coin ledger fetch failed")
            return []
        }
        return records.compactMap(Self.entry(from:))
    }

    @discardableResult public func append(_ entries: [CoinLedgerEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        let context = controller.container.viewContext
        do {
            // Look up the rows we're about to touch in ONE fetch, then upsert by idString. We do NOT
            // delete rows we weren't handed (unlike CustomItemRepository's full-replace save) — the
            // ledger is append-only, so flushing a stale set can't clobber rows synced from another device.
            let incomingIDs = entries.map(\.id)
            let request = NSFetchRequest<NSManagedObject>(entityName: "CoinLedgerRecord")
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
                    assertionFailure("coin ledger encode failed")
                    continue
                }
                let record = existingByID[entry.id]
                    ?? NSEntityDescription.insertNewObject(forEntityName: "CoinLedgerRecord", into: context)
                record.setValue(entry.id, forKey: "idString")
                record.setValue(payload, forKey: "payloadData")
                record.setValue(entry.createdAt, forKey: "createdAt")
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("coin ledger Core Data save failed")
            context.rollback()
            return false
        }
    }

    @discardableResult public func deleteAll() -> Bool {
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

    private static func entry(from record: NSManagedObject) -> CoinLedgerEntry? {
        guard let data = record.value(forKey: "payloadData") as? Data else { return nil }
        return try? RowPayloadCoders.makeDecoder().decode(CoinLedgerEntry.self, from: data)
    }
}

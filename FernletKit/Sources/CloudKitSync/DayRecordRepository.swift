// DayRecordRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for day history, separate from the snapshot blob so each day syncs as
// its own CloudKit record. Mirrors `CoinLedgerRepository` (upsert-only: `upsert` touches only the days it
// is handed and never deletes rows it wasn't, so a stale in-memory set on one device can't wipe days that
// synced in from another). One FernletDay per row keeps every record far under CloudKit's ~1 MB limit —
// the reason this split removes the 370-day cap the single blob needed.
//
// Unlike the coin ledger, days MUST collapse duplicate rows here: CloudKit mirrors by record identity, not
// the `dateKey` attribute, so two devices that first-write the same day before import settles can produce
// two rows for one `dateKey`. The read path returns `[String: FernletDay]` (a dict can't hold two rows for
// one key), so `loadAll`/`load` keep the most-recently-updated row per `dateKey` and actively delete the
// losers to self-heal — the same duplicate cleanup the aggregate record does in `fetchRecordResult`.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

public struct DayRecordRepository: DayRecordRepositoring {
    private let controller: PersistenceController

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
    }

    public func loadAll() -> [String: FernletDay] {
        StartupTiming.timed("DayRecordRepository.loadAll") {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
            return dedupedDays(fetching: request)
        }
    }

    public func load(dateKeys: [String]) -> [String: FernletDay] {
        guard !dateKeys.isEmpty else { return [:] }
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        request.predicate = NSPredicate(format: "dateKey IN %@", dateKeys)
        return dedupedDays(fetching: request)
    }

    public func loadRecent(limit: Int) -> [FernletDay] {
        guard limit > 0 else { return [] }
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "dateKey", ascending: false)]
        // Fetch a small buffer above `limit` so duplicate rows for the newest days can't shrink the window
        // below `limit` distinct days; dedup, then take the newest `limit`.
        request.fetchLimit = limit + 64
        let byKey = dedupedDays(fetching: request)
        return byKey.keys.sorted(by: >).prefix(limit).compactMap { byKey[$0] }
    }

    @discardableResult public func upsert(_ days: [DayRecordUpsert]) -> Bool {
        guard !days.isEmpty else { return true }
        let context = controller.container.viewContext
        do {
            // Fetch ONLY the rows we're about to touch (predicate IN), then upsert by dateKey. We never
            // delete rows we weren't handed, so flushing a stale set can't wipe days synced from another
            // device. If duplicate rows already exist for a key, all of them are updated (harmless — they
            // collapse to one on the next read).
            let incomingKeys = days.map(\.dateKey)
            let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
            request.predicate = NSPredicate(format: "dateKey IN %@", incomingKeys)
            var existingByKey: [String: NSManagedObject] = [:]
            for record in try context.fetch(request) {
                if let key = record.value(forKey: "dateKey") as? String {
                    existingByKey[key] = record
                }
            }
            let encoder = Self.makeEncoder()
            for entry in days {
                guard let payload = try? encoder.encode(entry.day) else {
                    assertionFailure("day record encode failed")
                    continue
                }
                let record = existingByKey[entry.dateKey]
                    ?? NSEntityDescription.insertNewObject(forEntityName: "DayRecord", into: context)
                record.setValue(entry.dateKey, forKey: "dateKey")
                record.setValue(payload, forKey: "payloadData")
                record.setValue(entry.updatedAt, forKey: "updatedAt")
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("day record Core Data upsert failed")
            context.rollback()
            return false
        }
    }

    @discardableResult public func delete(dateKeys: [String]) -> Bool {
        guard !dateKeys.isEmpty else { return true }
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        request.predicate = NSPredicate(format: "dateKey IN %@", dateKeys)
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("day record delete failed")
            context.rollback()
            return false
        }
    }

    @discardableResult public func deleteAll() -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("day record delete-all failed")
            context.rollback()
            return false
        }
    }

    /// Fetches the given request and collapses duplicate `dateKey` rows, keeping the most-recently-updated
    /// one and deleting the losers in-context so the store self-heals.
    private func dedupedDays(fetching request: NSFetchRequest<NSManagedObject>) -> [String: FernletDay] {
        let context = controller.container.viewContext
        guard let records = try? context.fetch(request) else {
            assertionFailure("day record fetch failed")
            return [:]
        }
        var bestByKey: [String: (record: NSManagedObject, day: FernletDay, updatedAt: Date)] = [:]
        var duplicatesToDelete: [NSManagedObject] = []
        let decoder = Self.makeDecoder()
        for record in records {
            guard let key = record.value(forKey: "dateKey") as? String,
                  let payload = record.value(forKey: "payloadData") as? Data,
                  let day = try? decoder.decode(FernletDay.self, from: payload) else {
                continue
            }
            let updatedAt = record.value(forKey: "updatedAt") as? Date ?? .distantPast
            if let existing = bestByKey[key] {
                // Keep the newer row; mark the older one for deletion.
                if updatedAt > existing.updatedAt {
                    duplicatesToDelete.append(existing.record)
                    bestByKey[key] = (record, day, updatedAt)
                } else {
                    duplicatesToDelete.append(record)
                }
            } else {
                bestByKey[key] = (record, day, updatedAt)
            }
        }
        if !duplicatesToDelete.isEmpty {
            duplicatesToDelete.forEach { context.delete($0) }
            if context.hasChanges { try? context.save() }
        }
        return bestByKey.mapValues(\.day)
    }

    nonisolated private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

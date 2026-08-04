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
// one key), so `loadAll`/`load` keep the most-recently-updated row per `dateKey`. Self-heal deletion of the
// loser is CONSERVATIVE — it only fires on a STRICT `updatedAt` winner. On an equal-`updatedAt` tie nothing
// is deleted (see `dedupedDays`): two devices' migration-backfilled rows share the blob's single global
// `updatedAt`, so an on-tie delete would let each device delete the OTHER's row and lose both. The dict
// value is still made deterministic by a stable per-row tiebreak.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Per-row Core Data + iCloud store for day history: one `DayRecord` per calendar day.
///
/// The `DayRecordRepositoring` conformer that ``CoreDataFernletRepository`` writes through.
/// Splitting each `FernletDay` into its own row (a JSON `payloadData` blob via
/// ``RowPayloadCoders``, keyed by `dateKey`) keeps every record far under CloudKit's ~1 MB
/// limit — the reason the old 370-day blob cap could be removed — and lets CloudKit merge
/// different-day edits from different devices per record. Upsert-only: `upsert` touches only
/// the days it is handed and never deletes rows it wasn't, so a stale in-memory set can't wipe
/// days synced in from another device.
///
/// Unlike the ledger stores, reads MUST collapse duplicates: CloudKit mirrors by record
/// identity, not `dateKey`, so two devices first-writing the same day before import settles can
/// produce two rows for one key. `loadAll`/`load` return the most-recently-updated row per key,
/// and self-heal deletion of the losers is deliberately conservative — only rows STRICTLY older
/// than the top `updatedAt` are ever deleted, never ties (two devices' migration-backfilled rows
/// share one stamp, and an on-tie delete would let each device wipe the other's row, losing
/// both). MainActor-isolated by the module default, working on ``PersistenceController``'s view
/// context.
public struct DayRecordRepository: DayRecordRepositoring {
    private let controller: PersistenceController

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
    }

    /// Loads the whole (uncapped) day history, duplicate-collapsed to one day per `dateKey`.
    public func loadAll() -> [String: FernletDay] {
        StartupTiming.timed("DayRecordRepository.loadAll") {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
            return dedupedDays(fetching: request)
        }
    }

    /// Loads only the listed days (duplicate-collapsed); keys with no row are simply absent.
    public func load(dateKeys: [String]) -> [String: FernletDay] {
        guard !dateKeys.isEmpty else { return [:] }
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        request.predicate = NSPredicate(format: "dateKey IN %@", dateKeys)
        return dedupedDays(fetching: request)
    }

    /// Loads the newest `limit` distinct days for the derived-table window, over-fetching a small
    /// buffer so duplicate rows can't shrink the window below `limit` days.
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

    /// Inserts or updates the given sanitized days by `dateKey`, never deleting rows it wasn't
    /// handed; existing duplicate rows for a key are all updated (they collapse on the next read).
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
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
            let encoder = RowPayloadCoders.makeEncoder()
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

    /// Deletes the rows for the listed days (a no-op, returning `true`, when none exist) — used
    /// when a day's last logged entry is removed so an emptied day doesn't linger.
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

    /// Removes every day row — the delete-all/reset path.
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

    /// Fetches the given request and collapses duplicate `dateKey` rows down to one per key in the returned
    /// dict. Self-heal deletion of losers is CONSERVATIVE:
    ///  - When exactly ONE row for a key has the maximum `updatedAt` (a STRICT winner), that row wins and
    ///    every strictly-older row is deleted (they are genuinely superseded).
    ///  - When SEVERAL rows share the maximum `updatedAt` (a tie at the top), NONE of the tied rows is
    ///    deleted — only rows strictly below the max are. The dict value is chosen deterministically among
    ///    the tied rows by a stable per-row tiebreak.
    ///
    /// The tie rule is load-bearing: two devices that both ran migration stamp their backfilled rows with
    /// the SAME blob `updatedAt`. An "on-tie delete the other" rule would have each device delete the OTHER
    /// device's row; both deletes then sync and both rows are lost with no backfill (the blob's days are
    /// cleared post-migration). Keeping every top-stamped row on disk makes a mutual wipe impossible;
    /// CloudKit's later merge and any subsequent real (strictly newer) edit collapse them safely.
    private func dedupedDays(fetching request: NSFetchRequest<NSManagedObject>) -> [String: FernletDay] {
        let context = controller.container.viewContext
        guard let records = try? context.fetch(request) else {
            assertionFailure("day record fetch failed")
            return [:]
        }
        // Group every decodable row by `dateKey` (a stable per-row tiebreak accompanies each).
        /// One decodable fetched row: its managed object, decoded day, `updatedAt` stamp, and tiebreak.
        ///
        /// Local to the dedup pass; the tiebreak (the object-ID URI) makes the in-dict winner
        /// deterministic across reads when several rows tie at the top `updatedAt`.
        struct Row { let record: NSManagedObject; let day: FernletDay; let updatedAt: Date; let tiebreak: String }
        var rowsByKey: [String: [Row]] = [:]
        let decoder = RowPayloadCoders.makeDecoder()
        for record in records {
            guard let key = record.value(forKey: "dateKey") as? String,
                  let payload = record.value(forKey: "payloadData") as? Data,
                  let day = try? decoder.decode(FernletDay.self, from: payload) else {
                continue
            }
            let updatedAt = record.value(forKey: "updatedAt") as? Date ?? .distantPast
            let tiebreak = record.objectID.uriRepresentation().absoluteString
            rowsByKey[key, default: []].append(Row(record: record, day: day, updatedAt: updatedAt, tiebreak: tiebreak))
        }

        var result: [String: FernletDay] = [:]
        var duplicatesToDelete: [NSManagedObject] = []
        for (key, rows) in rowsByKey {
            guard let maxUpdatedAt = rows.map(\.updatedAt).max() else { continue }
            let topRows = rows.filter { $0.updatedAt == maxUpdatedAt }
            // Deterministic dict winner among the top-stamped rows (stable across reads).
            let winner = topRows.min { $0.tiebreak < $1.tiebreak }!
            result[key] = winner.day
            // Delete ONLY rows strictly older than the top stamp. Rows tied at the top are all kept on disk
            // (the mutual-delete guard) — including the ones that lost the in-dict tiebreak.
            for row in rows where row.updatedAt < maxUpdatedAt {
                duplicatesToDelete.append(row.record)
            }
        }
        if !duplicatesToDelete.isEmpty {
            duplicatesToDelete.forEach { context.delete($0) }
            if context.hasChanges { try? context.save() }
        }
        return result
    }
}

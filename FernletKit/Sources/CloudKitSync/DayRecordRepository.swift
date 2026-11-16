// DayRecordRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for day history, separate from the snapshot blob so each day syncs as
// its own CloudKit record. One FernletDay per row keeps every record far under CloudKit's ~1 MB limit —
// the reason this split removed the 370-day cap the single blob needed.
//
// Since G9-1 (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md, Part 1) each DEVICE writes its own row
// per day (the `deviceKey` attribute), with a stamp per element and a tombstone per removed element, and a
// read merges every device's row for the day element by element (`DayRowMerge`). Two devices therefore
// never write the same CloudKit record, so CloudKit's whole-record last-writer-wins cannot drop what the
// other device logged, and a deletion on one device is not undone by the other. Pre-G9 rows (no device
// key) and rows in a newer row format are read as legacy rows and never rewritten or deleted.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Per-row Core Data + iCloud store for day history: one `DayRecord` per calendar day per device.
///
/// The `DayRecordRepositoring` conformer that ``CoreDataFernletRepository`` writes through. Each
/// `FernletDay` is a JSON ``DayRowPayload`` (the day plus its element stamps) in a row keyed by
/// `dateKey` and `deviceKey`. ``upsert(_:)`` writes only THIS device's row for each day it is handed —
/// never another device's row and never a day it wasn't handed — and an emptied day keeps a row of
/// tombstones instead of being deleted. Every read returns the element-by-element merge of a day's rows
/// (``DayRowMerge``): the newest stamp wins per element, so a later deletion beats an earlier entry and
/// a later edit beats an earlier value, the same on every device. A day whose elements were all removed
/// reads absent. Reads never write. Pre-G9 rows and newer-format rows are merged as legacy rows (every
/// element live at the row's `updatedAt`) and never rewritten. MainActor-isolated by the module default,
/// working on ``PersistenceController``'s view context.
public struct DayRecordRepository: DayRecordRepositoring {
    private let controller: PersistenceController
    /// A device key fixed by the caller (tests that play two devices over one store), or nil for this
    /// install's own key from the store's device-local defaults.
    private let fixedDeviceKey: String?

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.init(controller: controller, deviceKey: nil)
    }

    /// A repository over `controller` that writes as `deviceKey` (tests: two devices, one store), or as
    /// this install's own key when nil.
    public init(controller: PersistenceController, deviceKey: String?) {
        self.controller = controller
        self.fixedDeviceKey = deviceKey
    }

    /// Loads the whole (uncapped) day history, duplicate-collapsed to one day per `dateKey`.
    public func loadAll() -> [String: FernletDay] {
        loadAllWithUnreadable().days
    }

    /// The whole day history like ``loadAll()``, naming what it could not read: the date key of every
    /// row whose payload would not decode (that day reads absent from `days`), and whether every row was
    /// accounted for — false when the fetch failed (the history then reads empty) or a row has no date
    /// key. The read the journal Sealed backup's snapshot takes (review B3 fix rounds 1 and 2).
    public func loadAllWithUnreadable() -> DayHistoryRead {
        StartupTiming.timed("DayRecordRepository.loadAll") {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
            return dedupedRead(fetching: request)
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

    /// Writes this device's own row for each given sanitized day (G9-1), never touching another
    /// device's row or a day it wasn't handed.
    ///
    /// The row holds the day as this device's copy now has it, with a stamp per element and a
    /// tombstone per element the person removed (``DayRowMerge/ownRow(incoming:own:merged:deviceKey:now:)``),
    /// so an emptied day keeps a row of tombstones instead of being deleted. A day with nothing to
    /// record (no elements, no tombstones, no earlier row) writes nothing, and a row whose bytes would
    /// not change is not rewritten. A day whose payload will not encode is SKIPPED and audited, and the
    /// batch still reports `true` (a `false` would retry the same value forever). This device's own row
    /// in a NEWER row format is left alone and audited (owner call S5 = C).
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    ///   Not discardable (R7): a dropped save silently loses the day the caller just wrote.
    public func upsert(_ days: [DayRecordUpsert]) -> Bool {
        guard !days.isEmpty else { return true }
        let context = controller.container.viewContext
        let me = deviceKey()
        do {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
            request.predicate = NSPredicate(format: "dateKey IN %@", days.map(\.dateKey))
            var rowsByKey: [String: [FetchedDayRow]] = [:]
            for record in try context.fetch(request) {
                guard let row = fetchedRow(record) else { continue }
                rowsByKey[row.dateKey, default: []].append(row)
            }
            for entry in days {
                writeOwnRow(entry, existing: rowsByKey[entry.dateKey] ?? [], deviceKey: me, in: context)
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            PersistenceFailureAudit.record("dayRecord.upsert.failed", error: error)
            context.rollback()
            return false
        }
    }

    /// Stages this device's row for one day in `context` (see ``upsert(_:)``).
    private func writeOwnRow(_ entry: DayRecordUpsert, existing: [FetchedDayRow], deviceKey me: String,
                             in context: NSManagedObjectContext) {
        let own = existing.filter { $0.deviceKey == me }
        guard !own.contains(where: { $0.isNewerFormat }) else {
            FernletAuditLog.log("dayRecord.ownRowNewerFormat")
            return
        }
        let merged = DayRowMerge.merge(date: entry.dateKey, rows: existing.compactMap(\.view))
        let payload: Data
        do {
            let row = try DayRowMerge.ownRow(incoming: entry.day, own: own.first?.view, merged: merged,
                                             deviceKey: me, now: entry.updatedAt.timeIntervalSince1970)
            guard !row.stamps.isEmpty || !own.isEmpty else { return }
            payload = try RowPayloadCoders.makeEncoder().encode(row)
        } catch {
            // A day whose payload will not encode (a non-finite number reaching JSON) is skipped
            // and audited — never a DEBUG trap on a runtime data condition.
            PersistenceFailureAudit.record("dayRecord.encode.failed", error: error)
            return
        }
        let targets = own.isEmpty
            ? [NSEntityDescription.insertNewObject(forEntityName: "DayRecord", into: context)]
            : own.map(\.record)
        // R2: bounded by this device's rows for one day (one, barring a duplicate).
        for record in targets where record.value(forKey: "payloadData") as? Data != payload {
            record.setValue(entry.dateKey, forKey: "dateKey")
            record.setValue(me, forKey: "deviceKey")
            record.setValue(payload, forKey: "payloadData")
            record.setValue(entry.updatedAt, forKey: "updatedAt")
        }
    }

    /// Hard-deletes every row (every device's) for the listed days (a no-op, returning `true`, when none
    /// exist). No longer on the save path — since G9-1 an emptied day keeps a row of tombstones — and
    /// kept for the protocol's callers that remove a day outright.
    ///
    /// - Returns: `false` when the Core Data delete/save fails. Not discardable (R7): the emptied
    ///   day is still on disk (and still syncing) when it does.
    public func delete(dateKeys: [String]) -> Bool {
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
            PersistenceFailureAudit.record("dayRecord.delete.failed", error: error)
            context.rollback()
            return false
        }
    }

    /// Removes every day row (every device's, tombstones included) and this install's device key —
    /// the delete-all/reset path.
    public func deleteAll() -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        do {
            for record in try context.fetch(request) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
            // The wipe forgets this install's device key too; the next write mints a fresh one.
            controller.localDefaults.removeObject(forKey: "fernlet.sync.dayRowDeviceKey")
            return true
        } catch {
            PersistenceFailureAudit.record("dayRecord.deleteAll.failed", error: error)
            context.rollback()
            return false
        }
    }

    /// The merged day per date key for the given request (``dedupedRead(fetching:)``).
    private func dedupedDays(fetching request: NSFetchRequest<NSManagedObject>) -> [String: FernletDay] {
        dedupedRead(fetching: request).days
    }

    /// One fetched row: its managed object, date key, writing device, and (when it decoded) its
    /// merge view. A row whose payload will not decode has no view.
    private struct FetchedDayRow {
        let record: NSManagedObject
        let dateKey: String
        let deviceKey: String?
        let view: DayRowView?
        let isNewerFormat: Bool
    }

    /// `record` as a ``FetchedDayRow``, or nil when it has no date key.
    private func fetchedRow(_ record: NSManagedObject) -> FetchedDayRow? {
        guard let key = record.value(forKey: "dateKey") as? String else { return nil }
        let device = record.value(forKey: "deviceKey") as? String
        let updatedAt = record.value(forKey: "updatedAt") as? Date ?? .distantPast
        let tiebreak = record.objectID.uriRepresentation().absoluteString
        guard let data = record.value(forKey: "payloadData") as? Data else {
            return FetchedDayRow(record: record, dateKey: key, deviceKey: device, view: nil, isNewerFormat: false)
        }
        let payload: DayRowPayload
        do {
            payload = try RowPayloadCoders.makeDecoder().decode(DayRowPayload.self, from: data)
        } catch {
            // Corruption, or another iPhone's newer build: the caller names the day as unreadable.
            return FetchedDayRow(record: record, dateKey: key, deviceKey: device, view: nil, isNewerFormat: false)
        }
        let newer = payload.format > DayRowPayload.currentFormat
        // A pre-G9 row, a row with no writing device, or a newer-format row is read as a legacy row:
        // its day, every element live at its `updatedAt` — never its stamps, never rewritten.
        let view = (payload.format == 0 || device == nil || newer)
            ? DayRowView.legacy(day: payload.day, updatedAt: updatedAt, tiebreak: tiebreak)
            : DayRowView.stamped(payload: payload, updatedAt: updatedAt, tiebreak: tiebreak)
        return FetchedDayRow(record: record, dateKey: key, deviceKey: device, view: view, isNewerFormat: newer)
    }

    /// The merged day per date key (``DayRowMerge/merge(date:rows:)``) over every row the request
    /// fetches, naming what it could not read: the date key of every row whose payload would not
    /// decode, and — not accounted for — a failed fetch (empty days) or a row with no date key. A day
    /// whose every element was removed reads absent. Nothing is written or deleted: each device's row
    /// is its own, and the merge is the same on every device.
    private func dedupedRead(fetching request: NSFetchRequest<NSManagedObject>) -> DayHistoryRead {
        let context = controller.container.viewContext
        let records: [NSManagedObject]
        do {
            records = try context.fetch(request)
        } catch {
            // Environmental (locked/unavailable store), not a programmer error: audit and serve
            // the empty dictionary this function already documents as its failure result — and say
            // it is not the history.
            PersistenceFailureAudit.record("dayRecord.fetch.failed", error: error)
            return DayHistoryRead(days: [:], accountsForEveryRow: false)
        }
        var viewsByKey: [String: [DayRowView]] = [:]
        var unreadableKeys = Set<String>()
        var undated = 0
        var unreadable = 0
        for record in records {
            guard let row = fetchedRow(record) else {
                // No writer leaves a row without its day, so which day this one holds is unknown.
                undated += 1
                continue
            }
            guard let view = row.view else {
                unreadable += 1
                unreadableKeys.insert(row.dateKey)
                continue
            }
            viewsByKey[row.dateKey, default: []].append(view)
        }
        var result: [String: FernletDay] = [:]
        for (key, views) in viewsByKey {
            guard let merge = DayRowMerge.merge(date: key, rows: views), !merge.isEmpty else { continue }
            result[key] = merge.day
        }
        auditSkippedRows(unreadable + undated, undated: undated, fetched: records.count)
        return DayHistoryRead(days: result, unreadableDayKeys: unreadableKeys, accountsForEveryRow: undated == 0)
    }

    /// This install's device key: a random id minted on first use and kept in the store's
    /// device-local defaults, never synced, never the proximity identity or a hardware id. Every
    /// row this device writes carries it; Delete Everything (``deleteAll()``) forgets it.
    private func deviceKey() -> String {
        if let fixed = fixedDeviceKey { return fixed }
        if let data = controller.localDefaults.data(forKey: "fernlet.sync.dayRowDeviceKey"),
           let stored = String(data: data, encoding: .utf8), !stored.isEmpty {
            return stored
        }
        let minted = UUID().uuidString
        controller.localDefaults.set(Data(minted.utf8), forKey: "fernlet.sync.dayRowDeviceKey")
        return minted
    }

    /// Reports once per fetch the rows a read skipped — counts only, never a date key (a day key is
    /// user-derived).
    private func auditSkippedRows(_ skipped: Int, undated: Int, fetched: Int) {
        guard skipped > 0 else { return }
        FernletAuditLog.log("dayRecord.undecodableRows", context: [
            "count": "\(skipped)",
            "undated": "\(undated)",
            "fetched": "\(fetched)"
        ])
    }
}

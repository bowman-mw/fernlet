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
// one key), so `loadAll`/`load` MERGE the rows for a `dateKey` by entry id (bug confirmation 2026-10-15
// §3, the read-side stop-gap): meals, workouts, planned workouts and journals union, the newer row's copy
// of an id winning; water takes the larger count; hygiene and tasks union. Self-heal deletion of the
// older rows is CONSERVATIVE — it only fires below a STRICT `updatedAt` maximum, and only after the merged
// day has been written into the newest row in the same save, so what the other device logged that day is
// kept rather than deleted. On an equal-`updatedAt` tie nothing is deleted (see `dedupedDays`): two
// devices' migration-backfilled rows share the blob's single global `updatedAt`, so an on-tie delete
// would let each device delete the OTHER's row and lose both. The merge is deterministic by a stable
// per-row tiebreak.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Per-row Core Data + iCloud store for day history: one `DayRecord` per calendar day.
///
/// The `DayRecordRepositoring` conformer that ``CoreDataFernletRepository`` writes through.
/// Splitting each `FernletDay` into its own row (a JSON `payloadData` blob via
/// `RowPayloadCoders`, keyed by `dateKey`) keeps every record far under CloudKit's ~1 MB
/// limit — the reason the old 370-day blob cap could be removed — and lets CloudKit merge
/// different-day edits from different devices per record. Upsert-only: `upsert` touches only
/// the days it is handed and never deletes rows it wasn't, so a stale in-memory set can't wipe
/// days synced in from another device.
///
/// Unlike the ledger stores, reads MUST collapse duplicates: CloudKit mirrors by record
/// identity, not `dateKey`, so two devices first-writing the same day before import settles can
/// produce two rows for one key. `loadAll`/`load` return the rows for a key MERGED by entry id
/// (``DuplicateDayRows``; bug confirmation 2026-10-15 §3) — so a meal logged on one device and a
/// journal entry written on the other the same day both survive — and self-heal deletion of the
/// older rows is deliberately conservative: only rows STRICTLY older than the top `updatedAt` are
/// ever deleted, never ties (two devices' migration-backfilled rows share one stamp, and an on-tie
/// delete would let each device wipe the other's row, losing both), and only in the same save that
/// writes the merged day into the top rows. What this read cannot fix is ONE row both devices
/// rewrite: each save replaces the whole day, so the later writer's day wins (the write-side merge
/// is still owed). MainActor-isolated by the module default, working on ``PersistenceController``'s
/// view context.
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

    /// Inserts or updates the given sanitized days by `dateKey`, never deleting rows it wasn't
    /// handed; existing duplicate rows for a key are all updated (they collapse on the next read).
    ///
    /// A day whose payload will not encode (a non-finite number reaching JSON) is SKIPPED and
    /// audited, and the batch still reports `true` — so `SnapshotSaveCoordinator` marks the
    /// snapshot durable and the audit record is the only trace of the dropped day. `false` is
    /// reserved for the save itself failing; returning it for an un-encodable value would make
    /// every subsequent save retry the same value forever.
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    ///   Not discardable (R7): a dropped save silently loses the day the caller just wrote.
    public func upsert(_ days: [DayRecordUpsert]) -> Bool {
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
                let payload: Data
                do {
                    payload = try encoder.encode(entry.day)
                } catch {
                    // A day whose payload will not encode (a non-finite number reaching JSON) is
                    // skipped and audited — never a DEBUG trap on a runtime data condition.
                    PersistenceFailureAudit.record("dayRecord.encode.failed", error: error)
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
            PersistenceFailureAudit.record("dayRecord.upsert.failed", error: error)
            context.rollback()
            return false
        }
    }

    /// Deletes the rows for the listed days (a no-op, returning `true`, when none exist) — used
    /// when a day's last logged entry is removed so an emptied day doesn't linger.
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

    /// Removes every day row — the delete-all/reset path.
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
            return true
        } catch {
            PersistenceFailureAudit.record("dayRecord.deleteAll.failed", error: error)
            context.rollback()
            return false
        }
    }

    /// Fetches the given request and collapses duplicate `dateKey` rows down to one per key in the returned
    /// dict: the rows MERGED by entry id (``DuplicateDayRows/merged(newestFirst:)``), newest first, so no
    /// row's entries are dropped by the collapse. Self-heal deletion of the older rows is CONSERVATIVE:
    ///  - When some rows are STRICTLY older than the maximum `updatedAt`, the merged day is written into
    ///    every top-stamped row (its stamp kept) and the strictly-older rows are deleted, in ONE save — so
    ///    a delete that syncs never outruns the merged copy of what it deletes.
    ///  - When every row shares the maximum `updatedAt` (a tie at the top), NONE is deleted and nothing is
    ///    written; the read still returns their merge.
    ///
    /// The tie rule is load-bearing: two devices that both ran migration stamp their backfilled rows with
    /// the SAME blob `updatedAt`. An "on-tie delete the other" rule would have each device delete the OTHER
    /// device's row; both deletes then sync and both rows are lost with no backfill (the blob's days are
    /// cleared post-migration). Keeping every top-stamped row on disk makes a mutual wipe impossible;
    /// CloudKit's later merge and any subsequent real (strictly newer) edit collapse them safely.
    private func dedupedDays(fetching request: NSFetchRequest<NSManagedObject>) -> [String: FernletDay] {
        dedupedRead(fetching: request).days
    }

    /// One decodable fetched row: its managed object, decoded day, `updatedAt` stamp, and tiebreak (the
    /// object-ID URI, which makes the merge order deterministic across reads when rows tie).
    private struct DecodedDayRow {
        let record: NSManagedObject
        let day: FernletDay
        let updatedAt: Date
        let tiebreak: String
    }

    /// ``dedupedDays(fetching:)`` naming what it could not read: the date key of every row whose
    /// payload would not decode, and — not accounted for — a failed fetch (empty days) or a row with no
    /// date key, whose day is unknown.
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
        var rowsByKey: [String: [DecodedDayRow]] = [:]
        var unreadableKeys = Set<String>()
        var skipped = 0
        var undated = 0
        let decoder = RowPayloadCoders.makeDecoder()
        for record in records {
            guard let key = record.value(forKey: "dateKey") as? String else {
                // No writer leaves a row without its day, so which day this one holds is unknown.
                undated += 1
                skipped += 1
                continue
            }
            guard let payload = record.value(forKey: "payloadData") as? Data,
                  let day = try? decoder.decode(FernletDay.self, from: payload) else {
                // Corruption, or (iCloud sync on) another iPhone's newer build — count it and report
                // once per fetch rather than losing a whole day of the user's history silently, and
                // NAME the day, so a caller that must not drop it can keep what it may hold.
                unreadableKeys.insert(key)
                skipped += 1
                continue
            }
            let updatedAt = record.value(forKey: "updatedAt") as? Date ?? .distantPast
            let tiebreak = record.objectID.uriRepresentation().absoluteString
            rowsByKey[key, default: []].append(DecodedDayRow(record: record, day: day, updatedAt: updatedAt, tiebreak: tiebreak))
        }
        var result: [String: FernletDay] = [:]
        var heal = false
        for (key, rows) in rowsByKey {
            let merge = mergeDuplicates(rows, in: context)
            result[key] = merge.day
            heal = heal || merge.healed
        }
        if heal { saveDuplicateHeal(in: context) }
        auditSkippedRows(skipped, undated: undated, fetched: records.count)
        return DayHistoryRead(days: result, unreadableDayKeys: unreadableKeys, accountsForEveryRow: undated == 0)
    }

    /// Collapses one key's rows to their merge and, when some rows are strictly older than the top
    /// stamp, STAGES the self-heal in the context: the merged payload into every top-stamped row, then
    /// the strictly-older rows deleted. Nothing is staged when the rows tie at the top, or when the
    /// merged day will not encode (every row is then kept, and the next read merges them again).
    ///
    /// - Returns: the merged day, and whether a heal was staged (the caller saves once for all keys).
    private func mergeDuplicates(_ rows: [DecodedDayRow], in context: NSManagedObjectContext) -> (day: FernletDay?, healed: Bool) {
        // Newest first; the object-ID tiebreak orders equal stamps the same way on every read (R5:
        // an empty `rows` cannot reach here — a key is only grouped with a row — and merges to nil).
        let ordered = rows.sorted { ($0.updatedAt, $1.tiebreak) > ($1.updatedAt, $0.tiebreak) }
        let merged = DuplicateDayRows.merged(newestFirst: ordered.map(\.day))
        guard let top = ordered.first?.updatedAt, let merged,
              ordered.contains(where: { $0.updatedAt < top }) else { return (merged, false) }
        let payload: Data
        do {
            payload = try RowPayloadCoders.makeEncoder().encode(merged)
        } catch {
            PersistenceFailureAudit.record("dayRecord.duplicateMerge.encodeFailed", error: error)
            return (merged, false)
        }
        // R2: bounded by the rows fetched for this key.
        for row in ordered {
            if row.updatedAt == top {
                row.record.setValue(payload, forKey: "payloadData")
            } else {
                context.delete(row.record)
            }
        }
        return (merged, true)
    }

    /// Saves the staged duplicate heals (merged payloads + deletions) as ONE transaction, rolling the
    /// context back on failure.
    private func saveDuplicateHeal(in context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            // The rollback is the load-bearing half: without it the staged writes and deletes stay
            // pending in the SHARED view context, and the next unrelated save (a day-row upsert)
            // would commit them as a side effect.
            context.rollback()
            PersistenceFailureAudit.record("dayRecord.duplicateHeal.failed", error: error)
        }
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

/// The read-side merge of a day's duplicate `DayRecord` rows (bug confirmation 2026-10-15 §3, the S
/// stop-gap): two devices that each first-wrote the same day before import settled hold one row each,
/// and the collapse used to keep the newer row WHOLE and delete the other — losing everything the other
/// device logged that day. The merge keeps every entry either row holds instead.
///
/// The rule, newest row first: meals, workouts, planned workouts and journal entries union by id, the
/// newer row's copy of an id winning (an entry carries no stamp of its own); water takes the larger
/// bottle count; hygiene, parked hygiene tokens and completed tasks union; the planned-recipe ids and
/// typed plan union (by recipe id); sleep and the device-local health context take the newer row's
/// when it has one.
///
/// What it cannot do — the write-side merge the report sizes M–L, still owed: tell a deletion from an
/// entry the other row never had (an entry deleted on one device while a duplicate row still holds it
/// comes back once, at the next merge), or protect a day held in ONE row that both devices rewrite whole.
///
/// `nonisolated`: pure value arithmetic over `FernletDay`, callable from any executor.
nonisolated enum DuplicateDayRows {
    /// The merge of `newestFirst` — the rows' days ordered newest first — or nil for no rows.
    static func merged(newestFirst days: [FernletDay]) -> FernletDay? {
        guard var merged = days.first else { return nil }
        // R2: bounded by the rows fetched for one date key.
        for older in days.dropFirst() {
            merged.meals = unionByID(merged.meals, older.meals)
            merged.workouts = unionByID(merged.workouts, older.workouts)
            merged.plannedWorkouts = unionByID(merged.plannedWorkouts, older.plannedWorkouts)
            merged.journals = unionByID(merged.journals, older.journals)
            merged.sleep = merged.sleep ?? older.sleep
            merged.bottleCount = max(merged.bottleCount, older.bottleCount)
            merged.hygiene.formUnion(older.hygiene)
            merged.unknownHygieneTokens = appendingMissing(older.unknownHygieneTokens, to: merged.unknownHygieneTokens)
            merged.completedPersonalCareTaskIDs.formUnion(older.completedPersonalCareTaskIDs)
            merged.healthContext = merged.healthContext ?? older.healthContext
            merged.plannedRecipeIDs = appendingMissing(older.plannedRecipeIDs, to: merged.plannedRecipeIDs)
            merged.plannedMeals = mergedPlan(merged.plannedMeals, older.plannedMeals)
        }
        assert(merged.date == days[0].date, "a merge keeps the newest row's date key")
        return merged
    }

    /// `newer` followed by every element of `older` whose id `newer` does not hold.
    static func unionByID<Entry: Identifiable>(_ newer: [Entry], _ older: [Entry]) -> [Entry] {
        let held = Set(newer.map(\.id))
        return newer + older.filter { !held.contains($0.id) }
    }

    /// `base` followed by every element of `extra` it does not already hold, in `extra`'s order.
    static func appendingMissing<Element: Hashable>(_ extra: [Element], to base: [Element]) -> [Element] {
        let held = Set(base)
        return base + extra.filter { !held.contains($0) }
    }

    /// The typed meal plans' union by recipe id (the newer entry winning), nil only when both are nil —
    /// so a day neither row planned stays the pre-field shape.
    static func mergedPlan(_ newer: [PlannedMealEntry]?, _ older: [PlannedMealEntry]?) -> [PlannedMealEntry]? {
        guard newer != nil || older != nil else { return nil }
        return unionByID(newer ?? [], older ?? [])
    }
}

// AppendOnlyRowStore.swift
// CloudKitSync
//
// The shared upsert-only per-row Core Data engine behind `CoinLedgerRepository`,
// `MilestoneLedgerRepository`, and `CustomItemRepository`. Each of those stores is one
// Core Data + iCloud entity whose rows are JSON `payloadData` blobs (encoded via the shared
// `RowPayloadCoders`) keyed by a stable `idString` and sorted by `createdAt`; the load and
// upsert bodies were byte-for-byte clones, parameterized here by entity name, timing labels,
// and Debug assert text. The engine deliberately exposes NO delete path — deletion policy is
// per-repository (the milestone ledger has none at all, by design), so each wrapper keeps its
// own delete methods (or none) next to its contract.

import Foundation
import CoreData
import FernletFoundation

/// Shared upsert-only per-row Core Data engine for the JSON-payload row stores
/// (coin ledger, milestone ledger, custom items).
///
/// Each row of the configured entity carries the entry's stable `idString`, its JSON
/// `payloadData` blob (encoded via ``RowPayloadCoders`` — sorted keys + ISO-8601
/// whole-second dates, so persisted bytes are deterministic), and its `createdAt`
/// (the load sort key). `append` upserts only the rows it is handed and never deletes
/// others, so a stale in-memory set on one device cannot wipe rows synced in from
/// another; the engine intentionally has **no delete method** — deletion policy stays
/// per-repository (`MilestoneLedgerRepository` has none at all, structurally). Failed
/// saves assert in Debug builds, roll the context back, and return `false`; undecodable
/// rows are dropped per row on read. MainActor-isolated by the module default, working
/// on ``PersistenceController``'s view context.
struct AppendOnlyRowStore<Entry: Codable> {
    /// The persistence controller whose view context all reads and writes run on.
    let controller: PersistenceController
    /// The Core Data entity name the rows live in (e.g. `"CoinLedgerRecord"`).
    let entityName: String
    /// The `StartupTiming` signpost label for `load()` (a `StaticString`, as `os_signpost` requires —
    /// e.g. `"CoinLedgerRepository.load"`).
    let loadTimingLabel: StaticString
    /// The `StartupTiming` signpost label for `loadAsync()` (e.g. `"CoinLedgerRepository.loadAsync"`).
    let loadAsyncTimingLabel: StaticString
    /// The human label used in Debug `assertionFailure` messages (`"<label> fetch failed"`,
    /// `"<label> encode failed"`).
    let debugLabel: String
    /// The full Debug `assertionFailure` message for a failed Core Data save (threaded through
    /// whole because the wrappers' historical texts differ in more than the label).
    let saveFailureMessage: String
    /// Maps an entry to the stable `idString` attribute value it is keyed by.
    let idString: (Entry) -> String
    /// Maps an entry to its `createdAt` attribute value (the load sort key).
    let createdAt: (Entry) -> Date

    /// Loads every entry, oldest first; undecodable rows are dropped per row.
    func load() -> [Entry] {
        StartupTiming.timed(loadTimingLabel) { loadRecords() }
    }

    /// Async-signature variant of `load()` (the fetch itself still runs on the main actor).
    func loadAsync() async -> [Entry] {
        StartupTiming.timed(loadAsyncTimingLabel) { loadRecords() }
    }

    private func loadRecords() -> [Entry] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? context.fetch(request) else {
            assertionFailure("\(debugLabel) fetch failed")
            return []
        }
        return records.compactMap { entry(from: $0) }
    }

    /// Upserts the given entries by `idString`, never deleting rows it wasn't handed.
    ///
    /// - Returns: `false` when the Core Data save fails (the context is rolled back).
    @discardableResult func append(_ entries: [Entry]) -> Bool {
        guard !entries.isEmpty else { return true }
        let context = controller.container.viewContext
        do {
            // Look up the rows we're about to touch in ONE fetch, then upsert by idString. We do NOT
            // delete rows we weren't handed — these stores are append/upsert-only, so flushing a
            // stale set can't clobber rows synced from another device.
            let incomingIDs = entries.map(idString)
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = NSPredicate(format: "idString IN %@", incomingIDs)
            var existingByID: [String: NSManagedObject] = [:]
            for record in try context.fetch(request) {
                if let id = record.value(forKey: "idString") as? String {
                    existingByID[id] = record
                }
            }
            let encoder = RowPayloadCoders.makeEncoder()
            for entry in entries {
                guard let payload = try? encoder.encode(entry) else {
                    assertionFailure("\(debugLabel) encode failed")
                    continue
                }
                let record = existingByID[idString(entry)]
                    ?? NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
                record.setValue(idString(entry), forKey: "idString")
                record.setValue(payload, forKey: "payloadData")
                record.setValue(createdAt(entry), forKey: "createdAt")
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure(saveFailureMessage)
            context.rollback()
            return false
        }
    }

    private func entry(from record: NSManagedObject) -> Entry? {
        guard let data = record.value(forKey: "payloadData") as? Data else { return nil }
        // Per-row `try?`: an older build that can't decode a newer payload (e.g. an unknown
        // `MilestoneEventKind`) drops just that row — graceful forward-compat.
        return try? RowPayloadCoders.makeDecoder().decode(Entry.self, from: data)
    }
}

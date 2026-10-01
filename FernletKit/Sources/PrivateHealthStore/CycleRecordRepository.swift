import CoreData
import CryptoKit
import FernletCrypto
import FernletFoundation
import Foundation
import PrivateStoreCore

// CycleRecordRepository.swift — sealed at-rest CRUD for `CycleRecord` (period-data design
// 2026-09-30, §5.2, §6.1). Unit 3 lands it INERT: nothing in the app reads or writes a record yet
// beyond the keyless count and delete the wipe and the "entries this iPhone can't open" check use.

/// One page of stored cycle records, classified without keeping anything that did not open.
///
/// A row is in ``records`` when it opened under the key AND its decrypted id matched the row's id;
/// in ``deadIDs`` when it can never open (a CryptoKit authentication failure, a retired format, an
/// empty or missing blob, an install binding that is gone, bytes that do not decode, or an id
/// mismatch — `ColumnCrypto`'s AAD is `purpose ‖ binding`, so it does not bind the row id and the
/// check after the decrypt does, §5.2 R1-F9); and counted in ``transientCount`` when this attempt
/// could not decide (the install-binding read did not answer, or the row was written by a newer
/// build). A caller must never call a row unopenable while `transientCount > 0`.
///
/// `Sendable`: a plain value crossing `performAndWait`'s `@Sendable` closure.
public nonisolated struct CycleRecordPage: Equatable, Sendable {
    /// Rows that opened, in store order (by id).
    public var records: [CycleRecord]
    /// Rows that can never open under this key.
    public var deadIDs: [UUID]
    /// Rows this attempt could not decide (retryable).
    public var transientCount: Int

    /// Creates a page.
    public init(records: [CycleRecord] = [], deadIDs: [UUID] = [], transientCount: Int = 0) {
        self.records = records
        self.deadIDs = deadIDs
        self.transientCount = transientCount
    }

    /// Whether every row on the page opened.
    public var isFullyOpen: Bool { deadIDs.isEmpty && transientCount == 0 }

    /// Appends another page's classification to this one.
    mutating func absorb(_ other: CycleRecordPage) {
        records += other.records
        deadIDs += other.deadIDs
        transientCount += other.transientCount
    }
}

/// What one ``CycleRecordRepository/upsertMerged(_:retiringNarrativeIDs:contentKey:)`` changed.
///
/// `Sendable`: returned out of `performAndWait`.
public nonisolated struct CycleRecordUpsertResult: Equatable, Sendable {
    /// Ids that were absent and are now stored.
    public var inserted = 0
    /// Ids whose stored copy was merged with the incoming one and changed.
    public var merged = 0
    /// Ids whose stored rows were all dead and were replaced by the incoming copy.
    public var replaced = 0
    /// Ids the call left exactly as they were (nothing new, or nothing storable).
    public var unchanged = 0
    /// Legacy `MenstrualNarrative` rows deleted in the same save.
    public var retiredNarratives = 0

    /// Creates an empty result.
    public init() {}

    /// Whether the save changed anything on disk.
    public var changedAnything: Bool { inserted + merged + replaced + retiredNarratives > 0 }
}

/// A cycle-record write the repository refused, with nothing written.
///
/// `Sendable`: thrown out of `performAndWait`.
public nonisolated enum CycleRecordRepositoryError: Error, Equatable, Sendable {
    /// The store already holds ``CycleRecordRepository/maxStoredRecords`` records (R3); the insert
    /// would pass the bound.
    case storeFull(limit: Int)
    /// An insert named an id that is already stored.
    case recordExists(UUID)
    /// An update named an id that is not stored.
    case recordNotFound(UUID)
    /// The record carries nothing (no clinical field, no narrative) — it is never stored; an emptied
    /// edit deletes instead.
    case recordNotStorable(UUID)
    /// A stored row with an id this write touches could not be decided (the install binding did not
    /// answer, or a newer build wrote it). Nothing was written; the write is retryable.
    case undecidedRows(count: Int)
    /// A call named more ids or records than one call accepts.
    case batchTooLarge(count: Int, limit: Int)
}

/// Sealed at-rest CRUD for ``CycleRecord`` — one `ColumnCrypto` blob per row under
/// `FernletCryptoPurpose.KeyDerivation.cycleRecordV1`, in `PrivatePersistenceController`'s
/// local-only store (period-data design 2026-09-30, §6.1).
///
/// **The one write path is ``upsertMerged(_:retiringNarrativeIDs:contentKey:)``.** The entity has no
/// uniqueness constraint (the view context's property-object-trump merge policy would silently
/// overwrite a stored row on a conflict), so uniqueness lives here: the batch is reduced by id, each
/// id's stored rows are fetched (indexed), decrypted and classified, and — in ONE save —
/// - absent → inserted;
/// - present and opens → ``CycleRecord/merged(_:_:)`` with the incoming copy, re-sealed only when it
///   changed (stray duplicate rows of the id are merged in and deleted);
/// - present and every row dead → replaced by the incoming copy (a dead blob can never be read, so an
///   openable copy of the same id loses nothing);
/// - present and undecided → the WHOLE call throws ``CycleRecordRepositoryError/undecidedRows(count:)``
///   and nothing is saved.
/// The named `MenstrualNarrative` rows are deleted in the same save, so the legacy import retires a
/// narrative atomically with the record that replaces it.
///
/// Key discipline as the other sealed repositories: the hub key is passed per call and never kept;
/// writes throw `FernletLockError.locked` without it; reads degrade to an empty page; a failed seal
/// or save rolls the context back so no half-built row survives. Keyless and ungated by design:
/// ``recordCount()``, ``allIDs()``, ``delete(ids:)``, ``deleteAll()`` — deletion never needs the
/// ability to read. No divergence latch: the period backup's restore is gated by its own marker
/// (§5.3). Every mutation prunes persistent history (best-effort after a write; rethrown after a
/// delete, whose promise includes the history).
///
/// Bounded (R3): at most ``maxStoredRecords`` rows (an insert past it throws
/// ``CycleRecordRepositoryError/storeFull(limit:)``); pages of at most ``maxPageSize``.
///
/// A `nonisolated` final class serializing all Core Data access through the view context's
/// `performAndWait`, hence `Sendable` (checked): every stored property is a `let` of a `Sendable`
/// type — the context (`Sendable` in the iOS 26 SDK, touched only inside its own `performAndWait`)
/// and the stateless `ColumnCrypto`. The app target never constructs one (grep-walled in
/// `SensitiveSurfaceGateTests`); it goes through the gated `CycleRecordStore`.
public nonisolated final class CycleRecordRepository: Sendable {
    /// The most records one install keeps (R3).
    public static let maxStoredRecords = 20_000
    /// The most rows one page decrypts, and the most ids one keyed fetch names.
    public static let maxPageSize = 500
    /// The entity's name in the sealed model.
    static let entityName = "CycleRecord"
    /// The payload format written into the plaintext `schemaVersion` column.
    private static let storedSchemaVersion = Int16(truncatingIfNeeded: CycleRecord.schemaVersion)

    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.cycleRecordV1)

    /// Creates a repository on a sealed-store stack; `nil` selects the shared on-device one.
    public init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    /// Creates a repository on an explicit context — the seam tests use.
    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Whether the context's coordinator has a persistent store attached. False when the sealed store
    /// failed to load (the controller then runs against an empty coordinator) or is between a failed
    /// rebuild and its heal — every write throws then, and an empty read would be a lie. Keyless.
    public var isStoreHealthy: Bool {
        context.performAndWait {
            !(context.persistentStoreCoordinator?.persistentStores.isEmpty ?? true)
        }
    }

    // MARK: - Writes

    /// THE write path — see the type's documentation for the per-id rules.
    ///
    /// - Parameters:
    ///   - records: Incoming copies; reduced by id with ``CycleRecord/merged(_:_:)`` first.
    ///   - retiringNarrativeIDs: Legacy `MenstrualNarrative` row ids deleted in the same save.
    ///   - contentKey: The hub key; `nil` throws `FernletLockError.locked`.
    /// - Returns: What changed.
    /// - Throws: `FernletLockError.locked`, ``CycleRecordRepositoryError`` (nothing written), a seal
    ///   or save error (rolled back).
    public func upsertMerged(
        _ records: [CycleRecord],
        retiringNarrativeIDs: [UUID],
        contentKey: SymmetricKey?
    ) throws -> CycleRecordUpsertResult {
        try write(records, retiring: retiringNarrativeIDs, requireAbsent: false, contentKey: contentKey)
    }

    /// Stores one new record; its id must be absent.
    ///
    /// - Throws: ``CycleRecordRepositoryError/recordNotStorable(_:)`` for a record that carries
    ///   nothing, ``CycleRecordRepositoryError/recordExists(_:)`` when the id is stored, and every
    ///   throw of ``upsertMerged(_:retiringNarrativeIDs:contentKey:)``.
    public func insert(_ record: CycleRecord, contentKey: SymmetricKey?) throws {
        guard record.isStorable else { throw CycleRecordRepositoryError.recordNotStorable(record.id) }
        let result = try write([record], retiring: [], requireAbsent: true, contentKey: contentKey)
        guard result.inserted == 1 else { throw CycleRecordRepositoryError.recordExists(record.id) }
    }

    /// Replaces a stored record in place — an EDIT, so no merge: the edit is authoritative. Keeps the
    /// stored `createdAt` and `origin`; stamps `updatedAt` with `now`, and each block's `updatedAt`
    /// with `now` only when that block's content changed.
    ///
    /// - Throws: `FernletLockError.locked`; ``CycleRecordRepositoryError/recordNotStorable(_:)`` (an
    ///   emptied edit deletes instead); ``CycleRecordRepositoryError/recordNotFound(_:)``;
    ///   ``CycleRecordRepositoryError/undecidedRows(count:)``; a seal or save error (rolled back).
    public func update(_ record: CycleRecord, contentKey: SymmetricKey?, now: Date = Date()) throws {
        guard let contentKey else { throw FernletLockError.locked }
        guard record.isStorable else { throw CycleRecordRepositoryError.recordNotStorable(record.id) }
        try context.performAndWait {
            do {
                let rows = try fetchRows(ids: [record.id])[record.id] ?? []
                guard let first = rows.first else { throw CycleRecordRepositoryError.recordNotFound(record.id) }
                let stored = try storedCopy(of: rows, contentKey: contentKey)
                try seal(Self.edited(record, over: stored, now: now), into: first, contentKey: contentKey)
                rows.dropFirst().forEach(context.delete)
                try context.saveSealed()
            } catch {
                context.rollback()
                throw error
            }
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "CycleRecord.update")
        }
    }

    // MARK: - Keyless

    /// How many rows the entity holds — KEYLESS, decrypting nothing.
    public func recordCount() throws -> Int {
        try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Self.entityName))
        }
    }

    /// Every stored id, distinct, in store order — KEYLESS. Bounded by ``maxStoredRecords``. The
    /// backup export's snapshot: its chunks are fetched by these ids, so a page can never shift
    /// under a concurrent edit.
    public func allIDs() throws -> [UUID] {
        try context.performAndWait {
            let request = NSFetchRequest<NSDictionary>(entityName: Self.entityName)
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            request.returnsDistinctResults = true
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            request.fetchLimit = Self.maxStoredRecords
            return try context.fetch(request).compactMap { $0["id"] as? UUID }
        }
    }

    /// Deletes every row with these ids WITHOUT decrypting, in one save, then prunes the history
    /// (rethrown). Duplicate rows of an id go too. A failed save is rolled back, so a delete that
    /// throws deleted nothing — and cannot be committed later by someone else's save.
    ///
    /// - Parameter ids: At most ``maxStoredRecords`` ids.
    /// - Returns: How many rows were removed.
    public func delete(ids: [UUID]) throws -> Int {
        guard ids.count <= Self.maxStoredRecords else {
            throw CycleRecordRepositoryError.batchTooLarge(count: ids.count, limit: Self.maxStoredRecords)
        }
        guard !ids.isEmpty else { return 0 }
        return try context.performAndWait {
            let rows = try rowsInOrder(ids: ids)
            guard !rows.isEmpty else { return 0 }
            do {
                rows.forEach(context.delete)
                try context.saveSealed()
            } catch {
                context.rollback()
                throw error
            }
            try PrivatePersistentHistoryPruner.prune(context: context)
            return rows.count
        }
    }

    /// Drops every row WITHOUT decrypting, through the shared `PrivateRowPlumbing.deleteRows`
    /// sequence — so it works while the Private tab is closed and while period tracking is hidden.
    ///
    /// - Returns: Whether any row was removed (failure is always a throw).
    public func deleteAll() throws -> Bool {
        try PrivateRowPlumbing.deleteRows(entityName: Self.entityName, in: context)
    }

    // MARK: - Keyed reads

    /// One page of rows in store order (by id), classified. Empty without a key.
    ///
    /// - Parameters:
    ///   - offset: Rows to skip.
    ///   - limit: Rows wanted; clamped to ``maxPageSize``.
    ///   - contentKey: The hub key.
    public func records(offset: Int, limit: Int, contentKey: SymmetricKey?) throws -> CycleRecordPage {
        guard let contentKey, limit > 0 else { return CycleRecordPage() }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            request.fetchOffset = max(0, offset)
            request.fetchLimit = min(limit, Self.maxPageSize)
            return classify(try context.fetch(request), contentKey: contentKey)
        }
    }

    /// The rows with these ids, classified (an id with no row is simply absent). Empty without a key.
    ///
    /// - Parameter ids: At most ``maxPageSize`` ids.
    public func records(ids: [UUID], contentKey: SymmetricKey?) throws -> CycleRecordPage {
        guard ids.count <= Self.maxPageSize else {
            throw CycleRecordRepositoryError.batchTooLarge(count: ids.count, limit: Self.maxPageSize)
        }
        guard let contentKey, !ids.isEmpty else { return CycleRecordPage() }
        return try context.performAndWait {
            classify(try rowsInOrder(ids: ids), contentKey: contentKey)
        }
    }

    /// Every stored record, walked in pages of ``maxPageSize`` inside ONE `performAndWait` (so no
    /// write interleaves the walk), classified, with duplicate ids reduced by
    /// ``CycleRecord/merged(_:_:)``. Bounded by ``maxStoredRecords``. Empty without a key.
    public func allRecords(contentKey: SymmetricKey?) throws -> CycleRecordPage {
        guard let contentKey else { return CycleRecordPage() }
        return try context.performAndWait {
            let total = min(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Self.entityName)), Self.maxStoredRecords)
            var result = CycleRecordPage()
            for offset in stride(from: 0, to: total, by: Self.maxPageSize) {  // R2: ≤ maxStoredRecords / maxPageSize pages.
                let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                request.fetchOffset = offset
                request.fetchLimit = Self.maxPageSize
                result.absorb(classify(try context.fetch(request), contentKey: contentKey))
            }
            result.records = CycleRecord.reducedByID(result.records)
            return result
        }
    }
}

// MARK: - Internals

nonisolated extension CycleRecordRepository {
    /// How one stored row answered the key.
    private enum RowOpening {
        case opened(CycleRecord)
        case dead
        case undecided
    }

    /// The shared body of the two batch writes: validate, reduce, apply in one save, prune.
    private func write(
        _ records: [CycleRecord],
        retiring narrativeIDs: [UUID],
        requireAbsent: Bool,
        contentKey: SymmetricKey?
    ) throws -> CycleRecordUpsertResult {
        guard let contentKey else { throw FernletLockError.locked }
        guard records.count <= Self.maxStoredRecords, narrativeIDs.count <= Self.maxStoredRecords else {
            throw CycleRecordRepositoryError.batchTooLarge(count: max(records.count, narrativeIDs.count), limit: Self.maxStoredRecords)
        }
        let batch = CycleRecord.reducedByID(records)
        return try context.performAndWait {
            let result: CycleRecordUpsertResult
            do {
                result = try applyBatch(batch, retiring: narrativeIDs, requireAbsent: requireAbsent, contentKey: contentKey)
                if context.hasChanges { try context.saveSealed() }
            } catch {
                context.rollback()
                throw error
            }
            if result.changedAnything {
                PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "CycleRecord.upsertMerged")
            }
            return result
        }
    }

    /// Applies a reduced batch to the context (unsaved). Checks the store bound before any change.
    private func applyBatch(
        _ batch: [CycleRecord],
        retiring narrativeIDs: [UUID],
        requireAbsent: Bool,
        contentKey: SymmetricKey
    ) throws -> CycleRecordUpsertResult {
        let existing = try fetchRows(ids: batch.map(\.id))
        let newRows = batch.filter { existing[$0.id] == nil && $0.isStorable }.count
        let stored = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Self.entityName))
        guard stored + newRows <= Self.maxStoredRecords else {
            throw CycleRecordRepositoryError.storeFull(limit: Self.maxStoredRecords)
        }
        var result = CycleRecordUpsertResult()
        for incoming in batch {  // R2: bounded by the batch, itself ≤ maxStoredRecords.
            let rows = existing[incoming.id] ?? []
            if requireAbsent, !rows.isEmpty { throw CycleRecordRepositoryError.recordExists(incoming.id) }
            try apply(incoming, over: rows, contentKey: contentKey, into: &result)
        }
        result.retiredNarratives = try deleteNarrativeRows(ids: narrativeIDs)
        return result
    }

    /// The per-id rule (see the type's documentation).
    private func apply(
        _ incoming: CycleRecord,
        over rows: [NSManagedObject],
        contentKey: SymmetricKey,
        into result: inout CycleRecordUpsertResult
    ) throws {
        guard let first = rows.first else {
            guard incoming.isStorable else { result.unchanged += 1; return }
            try seal(incoming, into: NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context), contentKey: contentKey)
            result.inserted += 1
            return
        }
        let target: CycleRecord
        if let stored = try storedCopy(of: rows, contentKey: contentKey) {
            let merged = CycleRecord.merged(stored, incoming)
            // Nothing new, or a merge that would leave nothing storable: the stored copy stands.
            guard merged.isStorable, merged != stored || rows.count > 1 else { result.unchanged += 1; return }
            target = merged
            result.merged += 1
        } else {
            guard incoming.isStorable else { result.unchanged += 1; return }
            target = incoming
            result.replaced += 1
        }
        try seal(target, into: first, contentKey: contentKey)
        rows.dropFirst().forEach(context.delete)
    }

    /// The stored copy of one id: every row that opens, merged; `nil` when every row is dead.
    ///
    /// - Throws: ``CycleRecordRepositoryError/undecidedRows(count:)`` when any row could not be
    ///   decided — nothing may be overwritten on a read that did not answer.
    private func storedCopy(of rows: [NSManagedObject], contentKey: SymmetricKey) throws -> CycleRecord? {
        var opened: [CycleRecord] = []
        var undecided = 0
        for row in rows {  // R2: bounded by the id's rows.
            switch open(row, contentKey: contentKey) {
            case .opened(let record): opened.append(record)
            case .dead: continue
            case .undecided: undecided += 1
            }
        }
        guard undecided == 0 else { throw CycleRecordRepositoryError.undecidedRows(count: undecided) }
        guard let first = opened.first else { return nil }
        return opened.dropFirst().reduce(first, CycleRecord.merged)
    }

    /// Seals `record` into `object`. The blob is sealed BEFORE any column is set, so a refused seal
    /// leaves the object exactly as it was.
    private func seal(_ record: CycleRecord, into object: NSManagedObject, contentKey: SymmetricKey) throws {
        let blob = try crypto.seal(record, contentKey: contentKey)
        object.setValue(record.id, forKey: "id")
        object.setValue(Self.storedSchemaVersion, forKey: "schemaVersion")
        object.setValue(blob, forKey: "payloadCiphertext")
    }

    /// Opens one row: the plaintext schema column first (a newer build's row is undecided, never
    /// dead), then the blob, then the id check.
    private func open(_ object: NSManagedObject, contentKey: SymmetricKey) -> RowOpening {
        guard let rowID = object.value(forKey: "id") as? UUID,
              let blob = object.value(forKey: "payloadCiphertext") as? Data else { return .dead }
        let version = (object.value(forKey: "schemaVersion") as? NSNumber)?.intValue ?? 0
        guard version <= CycleRecord.schemaVersion else { return .undecided }
        do {
            guard let record: CycleRecord = try crypto.open(blob, contentKey: contentKey) else { return .dead }
            // R1-F9: the AAD does not bind the row id, so a blob moved onto another row opens — and
            // is refused here.
            return record.id == rowID ? .opened(record) : .dead
        } catch is DeviceBindingID.ReadError {
            return .undecided
        } catch is CycleRecordDecodingError {
            return .undecided
        } catch {
            return .dead
        }
    }

    /// Classifies fetched rows into a page, with ONE audit line per fetch for what did not open
    /// (counts only — never an id or a date).
    private func classify(_ objects: [NSManagedObject], contentKey: SymmetricKey) -> CycleRecordPage {
        var page = CycleRecordPage()
        var unaddressable = 0
        for object in objects {  // R2: bounded by the fetch (≤ maxPageSize rows).
            guard let rowID = object.value(forKey: "id") as? UUID else { unaddressable += 1; continue }
            switch open(object, contentKey: contentKey) {
            case .opened(let record): page.records.append(record)
            case .dead: page.deadIDs.append(rowID)
            case .undecided: page.transientCount += 1
            }
        }
        if !page.deadIDs.isEmpty || page.transientCount > 0 || unaddressable > 0 {
            FernletAuditLog.log("sealedRow.undecryptable", context: [
                "entity": Self.entityName,
                "dead": "\(page.deadIDs.count)",
                "undecided": "\(page.transientCount)",
                "noID": "\(unaddressable)"
            ])
        }
        return page
    }

    /// The rows of these ids, grouped by id — fetched `id IN` in slices of ``maxPageSize`` (R2:
    /// `ids.count / maxPageSize` rounded up fetches).
    private func fetchRows(ids: [UUID]) throws -> [UUID: [NSManagedObject]] {
        var grouped: [UUID: [NSManagedObject]] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.maxPageSize) {
            let slice = Array(ids[start..<min(start + Self.maxPageSize, ids.count)])
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.predicate = NSPredicate(format: "id IN %@", slice)
            for row in try context.fetch(request) {
                guard let id = row.value(forKey: "id") as? UUID else { continue }
                grouped[id, default: []].append(row)
            }
        }
        return grouped
    }

    /// The rows of these ids in the order the ids are given (an id's duplicate rows together) — so a
    /// page fetched by a snapshot's ids comes back in the snapshot's order.
    private func rowsInOrder(ids: [UUID]) throws -> [NSManagedObject] {
        let grouped = try fetchRows(ids: ids)
        var seen = Set<UUID>()
        return ids.flatMap { id -> [NSManagedObject] in
            guard seen.insert(id).inserted else { return [] }
            return grouped[id] ?? []
        }
    }

    /// Deletes the named legacy narrative rows (keyless) into the pending save.
    ///
    /// - Returns: How many rows were deleted.
    private func deleteNarrativeRows(ids: [UUID]) throws -> Int {
        var deleted = 0
        for start in stride(from: 0, to: ids.count, by: Self.maxPageSize) {  // R2: ids ≤ maxStoredRecords.
            let slice = Array(ids[start..<min(start + Self.maxPageSize, ids.count)])
            let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
            request.predicate = NSPredicate(format: "id IN %@", slice)
            let rows = try context.fetch(request)
            rows.forEach(context.delete)
            deleted += rows.count
        }
        return deleted
    }

    /// An edit applied over the stored copy: the stored `createdAt` kept, the stored `origin` kept
    /// unless the edit supplies a clinical block the stored copy did not know (then the edit's — see
    /// ``CycleRecord/combinedOrigin(_:_:)``, review round 2, N-1), `updatedAt` stamped, and each
    /// block restamped only when its content changed.
    static func edited(_ record: CycleRecord, over stored: CycleRecord?, now: Date) -> CycleRecord {
        var result = record
        result.createdAt = stored?.createdAt ?? record.createdAt
        result.origin = stored.map { CycleRecord.combinedOrigin($0, record) } ?? record.origin
        result.updatedAt = now
        result.clinical = restamped(record.clinical, over: stored?.clinical, now: now)
        result.narrative = restamped(record.narrative, over: stored?.narrative, now: now)
        return result
    }

    /// `block` with the stored block's clock when its content is unchanged, else with `now`.
    private static func restamped<Block: CycleRecordBlock>(_ block: Block?, over stored: Block?, now: Date) -> Block? {
        guard var block else { return nil }
        if let stored {
            block.updatedAt = stored.updatedAt
            if block == stored { return block }
        }
        block.updatedAt = now
        return block
    }
}

import CoreData
import CryptoKit
import FernletCrypto
import FernletDomainModel
import FernletFoundation
import Foundation
import PrivateStoreCore

// PrivateMemoryRepository.swift — sealed at-rest storage for the Core memories a person chose to keep
// private (G9-3, owner call M6 = A: "Keep private" moves a memory out of the synced rows into the sealed
// store, and private memories join the encrypted backup).

/// Every stored private memory that opened, plus how many rows did not.
///
/// A row is in ``memories`` when it opened under the key; counted in ``deadCount`` when it can never
/// open (a CryptoKit authentication failure, an install binding that is gone, bytes that do not decode,
/// or a blob whose memory id is not the row's); and counted in ``transientCount`` when this attempt
/// could not decide (the install-binding read did not answer, or a newer build wrote the row).
///
/// `Sendable`: a plain value crossing `performAndWait`'s `@Sendable` closure.
public nonisolated struct PrivateMemoryPage: Equatable, Sendable {
    /// The memories that opened, oldest first (by source date, then id).
    public var memories: [MemoryNote]
    /// Rows that can never open under this key.
    public var deadCount: Int
    /// Rows this attempt could not decide (retryable).
    public var transientCount: Int

    /// Creates a page.
    public init(memories: [MemoryNote] = [], deadCount: Int = 0, transientCount: Int = 0) {
        self.memories = memories
        self.deadCount = deadCount
        self.transientCount = transientCount
    }
}

/// A private-memory write the repository refused, with nothing written.
///
/// `Sendable`: thrown out of `performAndWait`.
public nonisolated enum PrivateMemoryRepositoryError: Error, Equatable, Sendable {
    /// The store already holds ``PrivateMemoryRepository/maxStoredRows`` rows; a new memory would pass it.
    case storeFull(limit: Int)
    /// A stored row with the same id could not be decided this attempt (the install binding did not
    /// answer, or a newer build wrote it); nothing was written and the write is retryable.
    case undecidedRows(count: Int)
}

/// The private-memory store surface the app's `PrivateMemoryVault` depends on — a protocol seam so the
/// "Keep private" move can be driven by a double whose sealed write fails (the Core copy must then stay).
/// ``PrivateMemoryRepository`` is the production conformer.
///
/// The same key contract as the other sealed repositories: keyed writes throw `FernletLockError.locked`
/// without a key, keyed reads answer an empty page, and the counting and delete members take no key, so
/// a wipe or a forget works whatever state the lock is in.
public protocol PrivateMemoryStoring: AnyObject {
    /// How many rows the store holds — keyless, decrypting nothing.
    func rowCount() throws -> Int
    /// Every stored memory that opens under `key`, oldest first; an empty page without a key.
    func memories(key: SymmetricKey?) throws -> PrivateMemoryPage
    /// Seals `memory` as its id's one row (a new row, or the existing row re-sealed in place).
    func save(_ memory: MemoryNote, key: SymmetricKey?) throws
    /// Merges memories a Sealed backup restore carried: absent ids inserted, rows that open kept as
    /// they are, dead rows replaced, never a delete. Returns how many rows changed.
    func mergeRestored(_ incoming: [MemoryNote], key: SymmetricKey?) throws -> Int
    /// Deletes the rows with these ids without decrypting them. Returns how many went.
    func delete(ids: [UUID]) throws -> Int
    /// Drops every row without decrypting. Returns whether any row was removed.
    func deleteAll() throws -> Bool
}

/// Sealed at-rest storage for private Core memories — one `ColumnCrypto` blob per memory under
/// `FernletCryptoPurpose.KeyDerivation.privateMemoryV1`, in `PrivatePersistenceController`'s local-only
/// store (never attached to iCloud). A row holds only `id` (the memory's own random id), `schemaVersion`
/// and the blob: the category, the words, the source date and the edited flag are all inside it, so the
/// store says how many memories are private, never what or when.
///
/// **The key.** The Private tab's content key — the journal's key — passed per call and never kept, so a
/// private memory opens exactly when the journal does. There is no device fallback key: a memory can only
/// be made private while Private is open, and it is listed only then.
///
/// Key discipline as the other sealed repositories: keyed writes throw `FernletLockError.locked` without a
/// key; reads degrade to an empty page; a failed seal or save rolls the context back so no half-built row
/// survives. ``rowCount()``, ``delete(ids:)`` and ``deleteAll()`` are KEYLESS. Every mutation prunes the
/// persistent history (best-effort after a write; rethrown after a delete, whose promise includes the
/// history).
///
/// Bounded: at most ``maxStoredRows`` rows; a new memory past it throws
/// ``PrivateMemoryRepositoryError/storeFull(limit:)``, and every scan fetches at most that many rows.
///
/// A `nonisolated` final class serializing all Core Data access through the view context's
/// `performAndWait`, hence `Sendable` (checked): every stored property is a `let` of a `Sendable` type.
public nonisolated final class PrivateMemoryRepository: PrivateMemoryStoring, Sendable {
    /// The most rows one install keeps.
    public static let maxStoredRows = 1_000
    /// The payload format written into the plaintext `schemaVersion` column. A row written under a
    /// higher number is a newer build's and is never treated as dead.
    public static let schemaVersion = 1
    /// The entity's name in the sealed model.
    static let entityName = "PrivateMemory"

    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.privateMemoryV1)

    /// Creates a repository on a sealed-store stack; `nil` selects the shared on-device one.
    public init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    /// Creates a repository on an explicit context — the seam tests use.
    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - Keyless

    /// How many rows the entity holds — KEYLESS, decrypting nothing. The Core memory page's
    /// "N private memories — unlock to see" line reads it while Private is closed.
    public func rowCount() throws -> Int {
        try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Self.entityName))
        }
    }

    /// Deletes the rows with these ids WITHOUT decrypting them, in one save, then prunes the history
    /// (rethrown). At most ``maxStoredRows`` ids are taken per call (the list becomes an `IN` clause).
    ///
    /// - Returns: How many rows were removed.
    public func delete(ids: [UUID]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let bounded = Array(ids.prefix(Self.maxStoredRows))
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.predicate = NSPredicate(format: "id IN %@", bounded)
            request.fetchLimit = Self.maxStoredRows
            let rows = try context.fetch(request)
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

    /// Drops every row WITHOUT decrypting, through the shared `PrivateRowPlumbing.deleteRows` sequence
    /// (save, then a rethrown history prune), so it works while locked and in any state.
    ///
    /// - Returns: Whether any row was removed (failure is always a throw).
    public func deleteAll() throws -> Bool {
        try PrivateRowPlumbing.deleteRows(entityName: Self.entityName, in: context)
    }

    // MARK: - Keyed

    /// Every stored memory that opens under `key`, oldest first. Empty without a key.
    public func memories(key: SymmetricKey?) throws -> PrivateMemoryPage {
        guard let key else { return PrivateMemoryPage() }
        return try context.performAndWait {
            let scan = scanRows(try fetchRows(), key: key)
            let memories = scan.opened.map(\.memory).sorted(by: Self.isOrderedBefore)
            return PrivateMemoryPage(memories: memories, deadCount: scan.dead.count, transientCount: scan.undecided)
        }
    }

    /// Seals `memory` as its id's one row: a row that already holds that id is re-sealed in place, any
    /// other id gets a new row. One save, then a best-effort history prune.
    ///
    /// - Throws: `FernletLockError.locked` without a key; ``PrivateMemoryRepositoryError`` (nothing
    ///   written); a seal or save error (rolled back).
    public func save(_ memory: MemoryNote, key: SymmetricKey?) throws {
        guard let key else { throw FernletLockError.locked }
        try context.performAndWait {
            do {
                let existing = try fetchRows(ids: [memory.id])
                if let row = existing.first {
                    existing.dropFirst().forEach(context.delete)
                    try seal(memory, into: row, key: key)
                } else {
                    guard try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Self.entityName)) < Self.maxStoredRows else {
                        throw PrivateMemoryRepositoryError.storeFull(limit: Self.maxStoredRows)
                    }
                    try seal(memory, into: NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context), key: key)
                }
                try context.saveSealed()
            } catch {
                context.rollback()
                throw error
            }
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "PrivateMemory.save")
        }
    }

    /// Merges memories a Sealed backup restore carried, in ONE save: an id with no row is inserted, a
    /// row that opens is kept exactly as it is (this iPhone's copy wins), a row that can never open is
    /// re-sealed with the incoming copy. NEVER a delete, and idempotent. A store at ``maxStoredRows``
    /// keeps the newest incoming memories that fit and skips the rest (an audit line counts them), so a
    /// restore can always land.
    ///
    /// - Returns: How many rows changed on disk.
    /// - Throws: `FernletLockError.locked` without a key;
    ///   ``PrivateMemoryRepositoryError/undecidedRows(count:)`` (nothing written, retryable); a seal or
    ///   save error (rolled back).
    @discardableResult
    public func mergeRestored(_ incoming: [MemoryNote], key: SymmetricKey?) throws -> Int {
        guard let key else { throw FernletLockError.locked }
        let byID = Self.foldedByID(incoming)
        guard !byID.isEmpty else { return 0 }
        return try context.performAndWait {
            let changed: Int
            do {
                changed = try applyMerge(byID, key: key)
                if context.hasChanges { try context.saveSealed() }
            } catch {
                context.rollback()
                throw error
            }
            if changed > 0 { PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "PrivateMemory.merge") }
            return changed
        }
    }
}

// MARK: - Internals

nonisolated extension PrivateMemoryRepository {
    /// How one stored row answered the key.
    private enum RowOpening {
        case opened(MemoryNote)
        case dead
        case undecided
    }

    /// Every fetched row sorted by how it answered the key.
    private struct RowScan {
        var opened: [(row: NSManagedObject, memory: MemoryNote)] = []
        var dead: [NSManagedObject] = []
        var undecided = 0
    }

    /// The display and merge order: oldest source date first, ties by id.
    static func isOrderedBefore(_ lhs: MemoryNote, _ rhs: MemoryNote) -> Bool {
        if lhs.sourceDate != rhs.sourceDate { return lhs.sourceDate < rhs.sourceDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// `incoming` reduced to one memory per id (the last copy wins), at most ``maxStoredRows``.
    static func foldedByID(_ incoming: [MemoryNote]) -> [UUID: MemoryNote] {
        var byID: [UUID: MemoryNote] = [:]
        for memory in incoming.prefix(maxStoredRows) {  // R2: bounded by maxStoredRows.
            byID[memory.id] = memory
        }
        return byID
    }

    /// The body of ``mergeRestored(_:key:)`` inside `performAndWait`, unsaved: scan the rows of the
    /// incoming ids, refuse on an undecided one, replace the dead ones, insert the absent ones (newest
    /// first, so a full store keeps the recent ones).
    private func applyMerge(_ byID: [UUID: MemoryNote], key: SymmetricKey) throws -> Int {
        let scan = scanRows(try fetchRows(ids: Array(byID.keys)), key: key)
        guard scan.undecided == 0 else { throw PrivateMemoryRepositoryError.undecidedRows(count: scan.undecided) }
        var changed = 0
        var present = Set(scan.opened.map(\.memory.id))
        for row in scan.dead {  // R2: bounded by the fetch (≤ maxStoredRows).
            guard let id = row.value(forKey: "id") as? UUID, let memory = byID[id], !present.contains(id) else { continue }
            try seal(memory, into: row, key: key)
            present.insert(id)
            changed += 1
        }
        var rowCount = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Self.entityName))
        var skipped = 0
        let absent = byID.values.filter { !present.contains($0.id) }.sorted(by: Self.isOrderedBefore).reversed()
        for memory in absent {  // R2: bounded by `byID` (≤ maxStoredRows).
            guard rowCount < Self.maxStoredRows else {
                skipped += 1
                continue
            }
            try seal(memory, into: NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context), key: key)
            rowCount += 1
            changed += 1
        }
        if skipped > 0 {
            FernletAuditLog.log("privateMemory.merge.storeFull", context: ["skipped": "\(skipped)"])
        }
        return changed
    }

    /// Seals `memory` into `object`. The blob is sealed BEFORE any column is set, so a refused seal
    /// leaves the object as it was.
    private func seal(_ memory: MemoryNote, into object: NSManagedObject, key: SymmetricKey) throws {
        let blob = try crypto.seal(memory, contentKey: key)
        object.setValue(memory.id, forKey: "id")
        object.setValue(Int16(truncatingIfNeeded: Self.schemaVersion), forKey: "schemaVersion")
        object.setValue(blob, forKey: "payloadCiphertext")
    }

    /// Every row of the entity, at most ``maxStoredRows``, in id order.
    private func fetchRows() throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        request.fetchLimit = Self.maxStoredRows
        return try context.fetch(request)
    }

    /// The rows holding any of `ids`, at most ``maxStoredRows``.
    private func fetchRows(ids: [UUID]) throws -> [NSManagedObject] {
        guard !ids.isEmpty else { return [] }
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.predicate = NSPredicate(format: "id IN %@", Array(ids.prefix(Self.maxStoredRows)))
        request.fetchLimit = Self.maxStoredRows
        return try context.fetch(request)
    }

    /// Opens every row, with ONE audit line per scan for what did not open (counts only — never an id).
    private func scanRows(_ rows: [NSManagedObject], key: SymmetricKey) -> RowScan {
        var scan = RowScan()
        for row in rows {  // R2: bounded by the fetch (≤ maxStoredRows).
            switch open(row, key: key) {
            case .opened(let memory): scan.opened.append((row, memory))
            case .dead: scan.dead.append(row)
            case .undecided: scan.undecided += 1
            }
        }
        if !scan.dead.isEmpty || scan.undecided > 0 {
            FernletAuditLog.log("sealedRow.undecryptable", context: [
                "entity": Self.entityName,
                "dead": "\(scan.dead.count)",
                "undecided": "\(scan.undecided)"
            ])
        }
        return scan
    }

    /// Opens one row: the plaintext schema column first (a newer build's row is undecided, never dead),
    /// then the blob, whose memory id must be the row's.
    private func open(_ object: NSManagedObject, key: SymmetricKey) -> RowOpening {
        guard let blob = object.value(forKey: "payloadCiphertext") as? Data,
              let rowID = object.value(forKey: "id") as? UUID else { return .dead }
        let version = (object.value(forKey: "schemaVersion") as? NSNumber)?.intValue ?? 0
        guard version <= Self.schemaVersion else { return .undecided }
        do {
            guard let memory: MemoryNote = try crypto.open(blob, contentKey: key), memory.id == rowID else { return .dead }
            return .opened(memory)
        } catch is DeviceBindingID.ReadError {
            return .undecided
        } catch {
            return .dead
        }
    }
}

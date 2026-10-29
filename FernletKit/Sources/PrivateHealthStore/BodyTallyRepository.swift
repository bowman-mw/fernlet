import CoreData
import CryptoKit
import FernletCrypto
import FernletFoundation
import Foundation
import PrivateStoreCore

// BodyTallyRepository.swift — sealed at-rest CRUD for `BodyTally` (World bodybuilding spec §7, the
// owner's answer 2: "Sealed (Recommended). Store them encrypted like the journal"). Round 7 piece B1:
// the store only — the Sealed iCloud backup of these rows is a later piece.

/// Every stored body tally that opened, keyed by day, plus how many rows did not.
///
/// A row is in ``tallies`` when it opened under the key; counted in ``deadCount`` when it can never
/// open (a CryptoKit authentication failure — e.g. sealed under a device key this iPhone no longer
/// has —, an install binding that is gone, bytes that do not decode); and counted in
/// ``transientCount`` when this attempt could not decide (the install-binding read did not answer,
/// or a newer build wrote the row). Two rows that open to the same day (never written by this
/// repository, but possible after a crash between insert and the duplicate's delete) are reduced to
/// the one with the later `updatedAt`.
///
/// `Sendable`: a plain value crossing `performAndWait`'s `@Sendable` closure.
public nonisolated struct BodyTallyPage: Equatable, Sendable {
    /// The tallies that opened, by `yyyy-MM-dd` day.
    public var tallies: [String: BodyDayTally]
    /// Rows that can never open under this key.
    public var deadCount: Int
    /// Rows this attempt could not decide (retryable).
    public var transientCount: Int

    /// Creates a page.
    public init(tallies: [String: BodyDayTally] = [:], deadCount: Int = 0, transientCount: Int = 0) {
        self.tallies = tallies
        self.deadCount = deadCount
        self.transientCount = transientCount
    }
}

/// A body-tally write the repository refused, with nothing written.
///
/// `Sendable`: thrown out of `performAndWait`.
public nonisolated enum BodyTallyRepositoryError: Error, Equatable, Sendable {
    /// The store already holds ``BodyTallyRepository/maxStoredRows`` rows; a new day would pass it.
    case storeFull(limit: Int)
    /// The tally's day key is not a `yyyy-MM-dd` calendar day.
    case invalidDayKey
    /// A stored row could not be decided this attempt (the install binding did not answer, or a newer
    /// build wrote it), so it might be the day's row; nothing was written and the write is retryable.
    case undecidedRows(count: Int)
}

/// Sealed at-rest CRUD for ``BodyDayTally`` — one `ColumnCrypto` blob per DAY under
/// `FernletCryptoPurpose.KeyDerivation.bodyTallyV1`, in `PrivatePersistenceController`'s local-only
/// store (never attached to iCloud). The row holds only `id`, `schemaVersion` and the blob: no
/// plaintext day key, so the store says how many days have tallies, never which.
///
/// **The key story (decided for piece B1, documented here and in the round's summary).** The journal
/// precedent is "the content key while the Private tab is open; the journal's device fallback key
/// while it is closed", with the device-key rows folded under the content key at the next open. The
/// tallies cannot follow the first half: they are SHOWN outside the Private tab — the Log panel's
/// Bathroom tile ("Bathroom, 2 today") and the Day calendar in Move — and a tap must count while
/// Private is closed or locked. A row under the content key could not be read there, so a closed-tab
/// tap would either be refused or overwrite a day it could not see. The closest honest equivalent is
/// therefore the journal's OWN closed-tab key for every tally: the device-bound journal fallback key
/// (keychain `com.fernlet.journal`, `ThisDeviceOnly`), with this repository's own HKDF purpose so a
/// tally blob can never open as a journal column under it. The repository itself is key-agnostic
/// (the key is passed per call and never kept); the app's `BodyTallyStore` supplies that key. What it
/// buys: every wipe that takes the journal device key crypto-erases the tallies with it (Delete
/// everything's key delete, Reset app lock's and the duress wipe's `sealedContentKeyServices`
/// sweeps), and a phone set up from a device backup cannot open them (the key never migrates).
///
/// Key discipline as the other sealed repositories: writes throw `FernletLockError.locked` without a
/// key; reads degrade to an empty page; a failed seal or save rolls the context back so no half-built
/// row survives. ``rowCount()`` and ``deleteAll()`` are KEYLESS, so a wipe works while locked.
/// ``delete(dayKey:key:)`` needs the key — there is no plaintext day to find the row by — and
/// deletes only rows that open to that day. Every mutation prunes persistent history (best-effort
/// after a write; rethrown after a delete, whose promise includes the history).
///
/// Bounded: at most ``maxStoredRows`` rows (over ten years of daily use); a new day past it throws
/// ``BodyTallyRepositoryError/storeFull(limit:)``. Every scan fetches at most that many rows.
///
/// A `nonisolated` final class serializing all Core Data access through the view context's
/// `performAndWait`, hence `Sendable` (checked): every stored property is a `let` of a `Sendable`
/// type. The app reaches it through `BodyTallyStore`, never directly from a view.
public nonisolated final class BodyTallyRepository: Sendable {
    /// The most rows one install keeps.
    public static let maxStoredRows = 4_000
    /// The entity's name in the sealed model.
    static let entityName = "BodyTally"
    /// The payload format written into the plaintext `schemaVersion` column.
    private static let storedSchemaVersion = Int16(truncatingIfNeeded: BodyDayTally.schemaVersion)

    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.bodyTallyV1)

    /// Creates a repository on a sealed-store stack; `nil` selects the shared on-device one.
    public init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    /// Creates a repository on an explicit context — the seam tests use.
    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Whether the context's coordinator has a persistent store attached. Keyless.
    public var isStoreHealthy: Bool {
        context.performAndWait {
            !(context.persistentStoreCoordinator?.persistentStores.isEmpty ?? true)
        }
    }

    // MARK: - Keyless

    /// How many rows the entity holds — KEYLESS, decrypting nothing. The app's cache uses it to
    /// notice that a wipe emptied the store underneath it.
    public func rowCount() throws -> Int {
        try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Self.entityName))
        }
    }

    /// Drops every row WITHOUT decrypting, through the shared `PrivateRowPlumbing.deleteRows`
    /// sequence (save, then a rethrown history prune), so it works while locked and in any state.
    ///
    /// - Returns: Whether any row was removed (failure is always a throw).
    public func deleteAll() throws -> Bool {
        try PrivateRowPlumbing.deleteRows(entityName: Self.entityName, in: context)
    }

    // MARK: - Keyed

    /// Every stored tally that opens under `key`, by day. Empty without a key.
    public func allTallies(key: SymmetricKey?) throws -> BodyTallyPage {
        guard let key else { return BodyTallyPage() }
        return try context.performAndWait {
            let scan = scanRows(try fetchAllRows(), key: key)
            var page = BodyTallyPage(deadCount: scan.dead, transientCount: scan.undecided)
            for (_, tally) in scan.opened {  // R2: bounded by the fetch (≤ maxStoredRows).
                if let held = page.tallies[tally.dayKey], held.updatedAt >= tally.updatedAt { continue }
                page.tallies[tally.dayKey] = tally
            }
            return page
        }
    }

    /// Stores `tally` as its day's one row, authoritatively (a set, not a merge): the day's row is
    /// re-sealed in place, any duplicate rows of the day are deleted, an EMPTY tally deletes the day's
    /// rows, and a day with no row gets a new one. One save, then a best-effort history prune.
    ///
    /// - Returns: Whether anything changed on disk.
    /// - Throws: `FernletLockError.locked` without a key; ``BodyTallyRepositoryError`` (nothing
    ///   written); a seal or save error (rolled back).
    @discardableResult
    public func save(_ tally: BodyDayTally, key: SymmetricKey?) throws -> Bool {
        guard let key else { throw FernletLockError.locked }
        guard BodyDayTally.isValidDayKey(tally.dayKey) else { throw BodyTallyRepositoryError.invalidDayKey }
        return try context.performAndWait {
            let changed: Bool
            do {
                changed = try applySave(tally, key: key)
                if context.hasChanges { try context.saveSealed() }
            } catch {
                context.rollback()
                throw error
            }
            if changed { PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "BodyTally.save") }
            return changed
        }
    }

    /// Deletes every row that opens under `key` to `dayKey`, in one save, then prunes the history
    /// (rethrown). Rows that do not open are left alone — they might be any day.
    ///
    /// - Returns: How many rows were removed.
    /// - Throws: `FernletLockError.locked` without a key; ``BodyTallyRepositoryError/invalidDayKey``;
    ///   a save or prune error (the save rolled back).
    public func delete(dayKey: String, key: SymmetricKey?) throws -> Int {
        guard let key else { throw FernletLockError.locked }
        guard BodyDayTally.isValidDayKey(dayKey) else { throw BodyTallyRepositoryError.invalidDayKey }
        return try context.performAndWait {
            let rows = scanRows(try fetchAllRows(), key: key).opened.filter { $0.tally.dayKey == dayKey }.map { $0.row }
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
}

// MARK: - Internals

nonisolated extension BodyTallyRepository {
    /// How one stored row answered the key.
    private enum RowOpening {
        case opened(BodyDayTally)
        case dead
        case undecided
    }

    /// Every fetched row sorted by how it answered the key.
    private struct RowScan {
        var opened: [(row: NSManagedObject, tally: BodyDayTally)] = []
        var dead = 0
        var undecided = 0
    }

    /// The body of ``save(_:key:)`` inside `performAndWait`, unsaved: scan, refuse on an undecided
    /// row, then re-seal / delete / insert.
    private func applySave(_ tally: BodyDayTally, key: SymmetricKey) throws -> Bool {
        let rows = try fetchAllRows()
        let scan = scanRows(rows, key: key)
        guard scan.undecided == 0 else { throw BodyTallyRepositoryError.undecidedRows(count: scan.undecided) }
        let matching = scan.opened.filter { $0.tally.dayKey == tally.dayKey }
        if tally.isEmpty {
            matching.forEach { context.delete($0.row) }
            return !matching.isEmpty
        }
        if let first = matching.first {
            let duplicates = matching.dropFirst()
            duplicates.forEach { context.delete($0.row) }
            guard duplicates.isEmpty == false || !first.tally.hasSameContent(as: tally) else { return false }
            try seal(tally, into: first.row, key: key)
            return true
        }
        guard rows.count < Self.maxStoredRows else { throw BodyTallyRepositoryError.storeFull(limit: Self.maxStoredRows) }
        try seal(tally, into: NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context), key: key)
        return true
    }

    /// Seals `tally` into `object`. The blob is sealed BEFORE any column is set, so a refused seal
    /// leaves the object as it was. A new row gets a fresh random id (the id says nothing about the
    /// day); an existing row keeps its id.
    private func seal(_ tally: BodyDayTally, into object: NSManagedObject, key: SymmetricKey) throws {
        let blob = try crypto.seal(tally, contentKey: key)
        if object.value(forKey: "id") == nil { object.setValue(UUID(), forKey: "id") }
        object.setValue(Self.storedSchemaVersion, forKey: "schemaVersion")
        object.setValue(blob, forKey: "payloadCiphertext")
    }

    /// Every row of the entity, at most ``maxStoredRows``, in id order.
    private func fetchAllRows() throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        request.fetchLimit = Self.maxStoredRows
        return try context.fetch(request)
    }

    /// Opens every row, with ONE audit line per scan for what did not open (counts only — never an
    /// id or a day).
    private func scanRows(_ rows: [NSManagedObject], key: SymmetricKey) -> RowScan {
        var scan = RowScan()
        for row in rows {  // R2: bounded by the fetch (≤ maxStoredRows).
            switch open(row, key: key) {
            case .opened(let tally): scan.opened.append((row, tally))
            case .dead: scan.dead += 1
            case .undecided: scan.undecided += 1
            }
        }
        if scan.dead > 0 || scan.undecided > 0 {
            FernletAuditLog.log("sealedRow.undecryptable", context: [
                "entity": Self.entityName,
                "dead": "\(scan.dead)",
                "undecided": "\(scan.undecided)"
            ])
        }
        return scan
    }

    /// Opens one row: the plaintext schema column first (a newer build's row is undecided, never
    /// dead), then the blob.
    private func open(_ object: NSManagedObject, key: SymmetricKey) -> RowOpening {
        guard let blob = object.value(forKey: "payloadCiphertext") as? Data else { return .dead }
        let version = (object.value(forKey: "schemaVersion") as? NSNumber)?.intValue ?? 0
        guard version <= BodyDayTally.schemaVersion else { return .undecided }
        do {
            guard let tally: BodyDayTally = try crypto.open(blob, contentKey: key) else { return .dead }
            return .opened(tally)
        } catch is DeviceBindingID.ReadError {
            return .undecided
        } catch {
            return .dead
        }
    }
}

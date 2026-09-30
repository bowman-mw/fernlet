import CoreData
import FernletCrypto
import CryptoKit
import Foundation
import FernletDomainModel
import FernletFoundation
import PrivateStoreCore

/// The decrypted value form of one sealed journal entry: the free-text body plus its
/// feeling tag, emotion chips, and day/date bookkeeping.
///
/// This is what ``JournalNarrativeRepository`` hands back after opening a row's
/// ciphertext — the app's `JournalSealingCoordinator` seals journal text INTO this
/// shape (stripping it out of the synced snapshot blob) and hydrates it back for
/// display. Only `text` and `emotions` are encrypted at rest; the identity and
/// ordering fields (`id`, `dayKey`, `tag`, `entryDate`, `createdAt`, `updatedAt`)
/// are stored as plaintext Core Data attributes so rows can be fetched and sorted
/// without a content key.
///
/// `Codable` so the app-side sealed-backup export can serialize decrypted rows into its
/// re-encrypted chunks (payload type `journalNarratives`) and the restore can decode them back.
/// `Sendable` (a plain value type of Sendable fields) because the repository seals it inside
/// `NSManagedObjectContext.performAndWait`, whose closure is `@Sendable`.
public struct JournalNarrative: Identifiable, Codable, Equatable, Sendable {
    /// Stable identity shared with the day's in-memory journal entry, used for upsert/delete matching.
    public var id: UUID
    /// The owning day's key (plaintext), used to fetch a day's narratives without decrypting them.
    public var dayKey: String
    /// The feeling tag the entry was written under (stored as its plaintext raw value).
    public var tag: FeelingTag
    /// When the entry was written within the day; the plaintext sort key for reads.
    public var entryDate: Date
    /// The journal body — sealed at rest as `textCiphertext` via `ColumnCrypto`.
    public var text: String
    /// The emotion chips attached to the entry — sealed at rest as the `emotionsCiphertext` JSON payload.
    public var emotions: [String]
    /// First-write timestamp; preserved across upserts by the repository.
    public var createdAt: Date
    /// Last-write timestamp; the repository stamps this on every seal.
    public var updatedAt: Date

    public init(id: UUID, dayKey: String, tag: FeelingTag, entryDate: Date, text: String, emotions: [String], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.dayKey = dayKey
        self.tag = tag
        self.entryDate = entryDate
        self.text = text
        self.emotions = emotions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The journal-narrative store surface the app's `JournalSealingCoordinator` depends on. Extracted as a
/// protocol so the coordinator can be driven by a test double (e.g. a decorator that simulates a transient
/// seal failure for the WI-1 historical scrub) without reaching the on-device Core Data store.
/// ``JournalNarrativeRepository`` is the production conformer.
///
/// The `contentKey` parameter carries the key-availability contract of the whole sealed store:
/// callers pass the content key from `FernletLockService` (or `nil` while the private area is
/// locked), and every conformer must fail closed — writes throw and reads return empty when the
/// key is absent. `delete(id:)` deliberately takes no key: rows are dropped without being
/// decrypted, so deletion stays available while locked. Note the concrete repository also offers
/// `deleteAll()` (used by the full data-reset hook), which is not part of this seam.
public protocol JournalNarrativeStoring: AnyObject {
    /// Seals `narrative` into the private store, inserting a new row or overwriting the row with
    /// the same `id` (upsert). Throws `FernletLockError.locked` when `contentKey` is `nil`.
    func insert(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws
    /// Re-seals an existing row matched by `narrative.id`; a missing row is a silent no-op.
    /// Throws `FernletLockError.locked` when `contentKey` is `nil`.
    func update(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws
    /// Deletes the row with `id` without decrypting it — no content key needed, so deletion
    /// works while the app is locked.
    func delete(id: UUID) throws
    /// All decryptable narratives for one day key, ascending by `entryDate`. Returns `[]` when
    /// `contentKey` is `nil`; individual undecryptable rows are skipped, not rethrown.
    func narratives(forDayKey dayKey: String, contentKey: SymmetricKey?) throws -> [JournalNarrative]
    /// All decryptable narratives across several day keys in one fetch, ascending by `entryDate`.
    /// Returns `[]` when `contentKey` is `nil` or `dayKeys` is empty.
    func narratives(forDayKeys dayKeys: [String], contentKey: SymmetricKey?) throws -> [JournalNarrative]
    /// Re-seals EVERY row that opens under `oldKey` under `newKey`, in bounded pages, skipping rows
    /// that do not open under `oldKey` (already migrated, or sealed under some other key). The fold
    /// the app runs when the Private tab opens, so entries written from Home while it was closed
    /// (sealed under the device key) are readable in the hub — every such entry, not a window of
    /// recent days (period-data design 2026-09-30, §9.17).
    ///
    /// - Returns: How many rows opened under `oldKey` but could not be re-sealed; they stay readable
    ///   under `oldKey`, so the caller keeps that key and retries on a later open.
    func reencryptAll(from oldKey: SymmetricKey, to newKey: SymmetricKey) throws -> Int
}

/// How the rows of one sealed table answer a key, classified without keeping any plaintext: the
/// shape the app's "entries this iPhone can't open" check (period-data design 2026-09-30, §4.9)
/// needs before it may call a row unopenable.
///
/// A row is `openable` when every sealed column opened, `dead` when one refused for good (a
/// CryptoKit authentication failure — the wrong key or damaged bytes — a retired format, an empty
/// column, or an install binding that is authoritatively gone), and counted as `transient` when the
/// install-binding read itself could not answer (`DeviceBindingID.ReadError`): nothing may be called
/// unopenable on a read that did not answer, so a caller treats any transient row as "try again".
///
/// `Sendable`: a plain value that crosses `performAndWait`'s `@Sendable` closure.
public struct SealedRowOpenability: Equatable, Sendable {
    /// Rows whose sealed columns all opened under the key.
    public var openableIDs: [UUID]
    /// Rows that can never open under the key.
    public var deadIDs: [UUID]
    /// Rows whose open could not be decided this time (retryable).
    public var transientCount: Int

    /// Creates a classification.
    public init(openableIDs: [UUID] = [], deadIDs: [UUID] = [], transientCount: Int = 0) {
        self.openableIDs = openableIDs
        self.deadIDs = deadIDs
        self.transientCount = transientCount
    }
}

/// ColumnCrypto-sealed journal storage in the local-only private Core Data store — the production
/// ``JournalNarrativeStoring`` conformer on the protected side of the S3 wall.
///
/// This is where journal text lives at rest after the app's `JournalSealingCoordinator` strips it
/// out of the synced snapshot blob: `text` and `emotions` are ChaChaPoly-sealed per column via
/// `ColumnCrypto` (HKDF label `"journal-narrative"`), while identity/ordering fields stay plaintext
/// so fetch-by-day and delete work without a key. Rows are `JournalNarrative` entities in the
/// sealed, never-iCloud `PrivatePersistenceController` store (`PrivateStoreCore`).
///
/// Key handling is fail-closed: the content key is passed per call (it originates from
/// `FernletLockService` and exists only while the private area is unlocked). Writes throw
/// `FernletLockError.locked` when the key is `nil`; reads return `[]`. A read under the wrong key
/// (or of a damaged blob) skips the individual row rather than failing the whole day.
///
/// Every operation runs synchronously inside `NSManagedObjectContext.performAndWait`, so the class
/// is a plain nonisolated `final class` (per the target's stance in `Package.swift`) and is safe to
/// call from any context that owns its lifetime; it holds no mutable state of its own. That is
/// also why it is `Sendable`, which `performAndWait`'s `@Sendable` closure requires of the `self`
/// it captures. The conformance is `@unchecked` for exactly one reason — `UserDefaults` carries no
/// SDK `Sendable` annotation — and rests on this invariant: every stored property is a `let`;
/// `context` (`NSManagedObjectContext`, `Sendable` in the iOS 26 SDK) is only ever touched inside
/// its own `performAndWait`, which serializes on the context's queue; `crypto` is a stateless
/// value; and `defaults` is Apple-documented thread-safe and used only for the one-way latch below.
/// Adding a `var` here would break the invariant and must not happen. After each mutation the
/// persistent-history log is pruned via `PrivatePersistentHistoryPruner` so superseded ciphertext
/// does not linger in the transaction log — best-effort (`try?`) after upserts, but rethrown after
/// deletes.
///
/// The app's `SealedBackupCoordinator` is the other caller: it exports via the paged
/// ``narratives(offset:limit:contentKey:)`` / ``narrativeCount()`` pair, restores via
/// ``insertAtomically(_:contentKey:)``, and consults ``hasEverStoredNarrative`` so a restore can never
/// resurrect entries the user deliberately deleted. Every mutation — deletes included — sets that
/// one-way latch.
///
/// Failure modes: seal/open rethrow `ColumnCrypto` (CryptoKit/JSON) errors; a failed upsert save
/// rolls back the in-memory change before rethrowing so the context is left clean.
public final class JournalNarrativeRepository: JournalNarrativeStoring, @unchecked Sendable {
    /// The sealed store's view context; every operation is funneled through its `performAndWait`.
    private let context: NSManagedObjectContext
    /// Column sealer bound to the `"journal-narrative"` HKDF label — the label is part of the
    /// at-rest format and must never change.
    private let crypto = ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1)

    /// R5: upper bound on the caller-supplied day-key list of
    /// ``narratives(forDayKeys:contentKey:)``, which becomes a `dayKey IN %@` predicate.
    private static let maxDayKeys = 500
    /// R3: upper bound on one page of ``narratives(offset:limit:contentKey:)``, so an absurd `limit`
    /// cannot decrypt the whole table at once. Above the 250-row sealed-backup chunk size.
    private static let maxPageSize = 500

    /// Device-local marker for "this install has written journal narratives at some point", used by the
    /// sealed-backup restore to tell TWO very different empty stores apart:
    ///
    /// - **never populated** (a genuine reinstall / new device) — restoring the sealed backup is the
    ///   whole point, and there is nothing local to lose.
    /// - **emptied by the user** (they deleted their journal entries) — the cloud backup is stale by
    ///   construction, because deleting an entry drops the narrative row without reconciling the
    ///   sealed backup. Restoring there would silently resurrect entries the user deliberately deleted.
    ///
    /// A plain row count cannot distinguish them, so this flag carries the missing bit. Mirrors
    /// `MenstrualNarrativeRepository.hasEverStoredNarrative` exactly, including living in **standard
    /// (device-local, non-synced) defaults**: iOS drops the app container on uninstall, so a real
    /// reinstall clears it for free, while a delete-all on a live install leaves it SET so the wipe
    /// cannot be undone by a stale cloud copy. One-way for every writer and for the wipe; cleared
    /// only by ``clearDivergenceLatch()``, once the key the rows spoke for is provably gone.
    ///
    /// - Important: The key string is device-local state a shipped build already writes; changing it
    ///   would silently reset every existing install's latch back to "never populated".
    private static let everStoredDefaultsKey = "fernlet.journalNarrative.everStored"

    /// Injected so tests get an isolated suite — the latch is process-global otherwise, and one test
    /// writing a narrative would leak "this device has diverged" into every later test in the run.
    private let defaults: UserDefaults

    /// Reads the latch, BACKFILLING it from the row count first: installs whose journal rows predate the
    /// latch (it ships later than the store) have rows but no defaults bit, and without the backfill an
    /// upgrading user who then deleted their entries would read as "never populated" — re-opening the
    /// resurrection this latch exists to close. A count error leaves the latch unread and un-backfilled
    /// (return the raw bit): claiming divergence on an error would wrongly block a genuine reinstall's
    /// restore forever, and the restore path's own no-clobber count check still refuses a populated store.
    public var hasEverStoredNarrative: Bool {
        if defaults.bool(forKey: Self.everStoredDefaultsKey) { return true }
        guard let count = try? narrativeCount(), count > 0 else { return false }
        markNarrativeStored()
        return true
    }

    /// Sets the one-way divergence latch. Called by every mutation — deletes included — AFTER the
    /// write actually commits, so a failed write never claims this device has diverged.
    private func markNarrativeStored() {
        defaults.set(true, forKey: Self.everStoredDefaultsKey)
    }

    /// Creates a repository on a private-store controller's view context.
    ///
    /// - Parameters:
    ///   - controller: The sealed store to use; `nil` (the default) means the shared on-device
    ///     `PrivatePersistenceController`. Tests pass an in-memory controller.
    ///   - defaults: Suite holding the divergence latch; tests inject an isolated suite.
    public init(controller: PrivatePersistenceController? = nil, defaults: UserDefaults = .standard) {
        self.context = (controller ?? .shared).container.viewContext
        self.defaults = defaults
    }

    /// Creates a repository directly on an arbitrary managed-object context (test seam).
    ///
    /// - Parameters:
    ///   - context: The managed-object context every operation is funneled through.
    ///   - defaults: Suite holding the divergence latch; tests inject an isolated suite.
    public init(context: NSManagedObjectContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
    }

    /// Seals `narrative` into the store — an upsert: an existing row with the same `id` is
    /// overwritten (its original `createdAt` preserved), otherwise a new row is inserted.
    ///
    /// - Important: Throws `FernletLockError.locked` when `contentKey` is `nil`. On a failed
    ///   save the inserted object is removed (or the context rolled back) before rethrowing.
    public func insert(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let isNew: Bool
            let object: NSManagedObject
            let createdAt: Date
            if let existing = try context.fetch(request(id: narrative.id)).first {
                isNew = false
                object = existing
                createdAt = existing.value(forKey: "createdAt") as? Date ?? narrative.createdAt
            } else {
                isNew = true
                object = NSEntityDescription.insertNewObject(forEntityName: "JournalNarrative", into: context)
                createdAt = narrative.createdAt
            }
            do {
                try apply(narrative, to: object, contentKey: contentKey, createdAt: createdAt)
                try context.saveSealed()
            } catch {
                if isNew { context.delete(object) } else { context.rollback() }
                throw error
            }
            // Prune history after an upsert so a re-sealed (edited) row leaves no prior ciphertext in
            // the transaction log. Best-effort — a prune failure must not undo the write that
            // succeeded — but it is audit-logged rather than discarded.
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "JournalNarrative.insert")
            // Latch AFTER a successful save, so a failed write never claims this device has diverged.
            markNarrativeStored()
        }
    }

    /// Inserts many narratives in a SINGLE transaction: either all commit or none do. Used by the
    /// sealed-backup RESTORE so a mid-batch failure cannot leave a partially-populated store — a partial
    /// store would trip the restore no-clobber gate (`narrativeCount() != 0`) on the next launch and
    /// never retry, silently dropping the un-inserted sealed records.
    ///
    /// Deliberately a PLAIN insert, not ``insert(_:contentKey:)``'s upsert: the caller has already
    /// proven the store is empty, so the per-row existence fetch would be pure cost, and an upsert would
    /// quietly overwrite a row this gate says cannot exist rather than surfacing the contradiction.
    ///
    /// - Important: Throws `FernletLockError.locked` when `contentKey` is `nil`. On any per-record
    ///   failure the whole batch is rolled back and the error rethrown, leaving the store empty so the
    ///   next launch re-pulls the full backup.
    public func insertAtomically(_ narratives: [JournalNarrative], contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        guard !narratives.isEmpty else { return }
        try context.performAndWait {
            do {
                for narrative in narratives {
                    let object = NSEntityDescription.insertNewObject(forEntityName: "JournalNarrative", into: context)
                    try apply(narrative, to: object, contentKey: contentKey, createdAt: narrative.createdAt)
                }
                try context.saveSealed()
            } catch {
                context.rollback()
                throw error
            }
            // Prune history after the atomic restore so no per-record transaction lingers in the
            // persistent-history transaction log (best-effort, and logged when it fails).
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "JournalNarrative.insertAtomically")
            // Latch AFTER the transaction commits. A restore that populates the store also counts as
            // "this device has journal narratives", so a later delete-everything cannot re-pull them.
            markNarrativeStored()
        }
    }

    /// Re-seals the existing row matched by `narrative.id` with the given content.
    ///
    /// - Important: A missing row is a silent no-op (unlike ``insert(_:contentKey:)``, which
    ///   creates one). Throws `FernletLockError.locked` when `contentKey` is `nil`; a failed
    ///   save is rolled back before rethrowing.
    public func update(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let request = request(id: narrative.id)
            guard let object = try context.fetch(request).first else { return }
            let createdAt = object.value(forKey: "createdAt") as? Date ?? narrative.createdAt
            do {
                try apply(narrative, to: object, contentKey: contentKey, createdAt: createdAt)
                try context.saveSealed()
            } catch {
                context.rollback()
                throw error
            }
            // Prune history so the prior ciphertext for this row is not retained (best-effort, and
            // logged when it fails).
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "JournalNarrative.update")
            // An update proves a row existed — latch even when the ORIGINAL insert predates the latch
            // (an upgrading install), so a later empty store still reads as "diverged", not "fresh".
            markNarrativeStored()
        }
    }

    /// Deletes the row with `id` without decrypting it — no content key needed, so deletion
    /// stays available while the app is locked. The history prune here rethrows (not best-effort):
    /// a delete's promise includes removing the ciphertext from the transaction log.
    ///
    /// Sets the divergence latch when a row was actually removed: the deletion itself is the proof this
    /// device diverged from the cloud snapshot (the sealed backup is NOT reconciled by deletes), so
    /// without it, deleting the last entry would leave an empty, unlatched store that a later restore
    /// would happily re-populate from the stale cloud copy.
    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = request(id: id)
            let rows = try context.fetch(request)
            rows.forEach(context.delete)
            try context.saveSealed()
            try PrivatePersistentHistoryPruner.prune(context: context)
            if !rows.isEmpty { markNarrativeStored() }
        }
    }

    /// Drops every stored journal narrative. Deletes rows WITHOUT decrypting them, so it works while the
    /// app is locked — deletion must stay available even when reading is not. Routes through the shared
    /// `PrivateRowPlumbing.deleteRows` sequence (fetch → delete → save → rethrowing history prune), like
    /// every sealed repository's `deleteAll()`. Not part of ``JournalNarrativeStoring``: the app's
    /// delete-all-data hook constructs the concrete repository to call it.
    ///
    /// Sets the divergence latch iff rows were actually removed — same reasoning as ``delete(id:)``,
    /// and what keeps "delete everything" from being undone by a stale cloud backup that survived a
    /// failed chunk delete.
    public func deleteAll() throws {
        if try PrivateRowPlumbing.deleteRows(entityName: "JournalNarrative", in: context) {
            markNarrativeStored()
        }
    }

    /// Total number of stored journal narratives, counted without decrypting (or even faulting in) any
    /// rows. Lets the sealed-backup export size its chunks up front, and lets the restore's no-clobber
    /// gate run without a content key.
    public func narrativeCount() throws -> Int {
        try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative"))
        }
    }

    /// A single page of narratives, decrypted, in a stable TOTAL order (`entryDate`, then the unique
    /// `id` tiebreaker). Backs the chunked sealed-backup export: paging by `offset`/`limit` keeps each
    /// chunk bounded regardless of how long the journal is, instead of loading every entry into memory
    /// before sealing.
    ///
    /// The `id` tiebreaker is what makes the order *total* — two entries written in the same second
    /// (or migrated with an identical `entryDate`) would otherwise sort non-deterministically, and
    /// successive pages could overlap or skip rows. Returns `[]` without a key; rows that fail to
    /// decrypt are skipped rather than failing the page.
    public func narratives(offset: Int, limit: Int, contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        guard let contentKey, limit > 0 else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
            request.sortDescriptors = [
                NSSortDescriptor(key: "entryDate", ascending: true),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            request.fetchOffset = max(0, offset)
            // R3/R5: clamp the caller's page size so `limit: .max` cannot decrypt the whole table.
            request.fetchLimit = min(limit, Self.maxPageSize)
            return decryptRows(try context.fetch(request), contentKey: contentKey)
        }
    }

    /// All decryptable narratives for `dayKey`, ascending by `entryDate`.
    ///
    /// - Returns: `[]` when `contentKey` is `nil` (locked). Individual rows that fail to decrypt
    ///   are skipped so one bad row cannot blank the whole day.
    public func narratives(forDayKey dayKey: String, contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        guard let contentKey else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
            request.predicate = NSPredicate(format: "dayKey == %@", dayKey)
            request.sortDescriptors = [NSSortDescriptor(key: "entryDate", ascending: true)]
            // Skip an individual undecryptable row rather than rethrowing, which would make every
            // valid journal narrative for the day disappear because callers wrap this in `try?`.
            // Mirrors Menstrual/Intimacy narrative repositories.
            return decryptRows(try context.fetch(request), contentKey: contentKey)
        }
    }

    /// All decryptable narratives across `dayKeys` in a single fetch, ascending by `entryDate` —
    /// the batch form used when hydrating several days at once.
    ///
    /// - Returns: `[]` when `contentKey` is `nil` or `dayKeys` is empty; undecryptable rows are skipped.
    public func narratives(forDayKeys dayKeys: [String], contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        guard let contentKey, !dayKeys.isEmpty else { return [] }
        // R5: the day-key list is caller-supplied and becomes an `IN` predicate — bound it at entry
        // rather than letting an unbounded array build an unbounded clause. Truncating (rather than
        // refusing) keeps the hydrate path working: the extra keys simply hydrate on the next batch.
        let boundedKeys = Array(dayKeys.prefix(Self.maxDayKeys))
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
            request.predicate = NSPredicate(format: "dayKey IN %@", boundedKeys)
            request.sortDescriptors = [NSSortDescriptor(key: "entryDate", ascending: true)]
            // Skip an individual undecryptable row rather than rethrowing (see above).
            return decryptRows(try context.fetch(request), contentKey: contentKey)
        }
    }

    /// Decrypts a fetched row set, skipping rows whose sealed columns will not open and recording ONE
    /// audit line per fetch (never per row, so a mass failure cannot spam the log).
    ///
    /// Skip-don't-fail is deliberate — one unopenable row must not blank a whole day — but an
    /// authentication failure (tampering, a wrong key, bit-rot) may not read as "no entries" either.
    private func decryptRows(_ objects: [NSManagedObject], contentKey: SymmetricKey) -> [JournalNarrative] {
        var skipped = 0
        let rows = objects.compactMap { object -> JournalNarrative? in
            do {
                return try decrypt(object, contentKey: contentKey)
            } catch {
                skipped += 1
                return nil
            }
        }
        if skipped > 0 {
            FernletAuditLog.log(
                "sealedRow.undecryptable",
                context: ["entity": "JournalNarrative", "count": "\(skipped)"]
            )
        }
        return rows
    }

    // MARK: - Key folds and the unopenable-entries check (period-data design 2026-09-30)

    /// R3: page size of the whole-table walks (``reencryptAll(from:to:)``,
    /// ``openability(under:)``), so a long journal is never faulted in, re-sealed or classified as
    /// one unbounded transaction.
    private static let walkPageSize = 200
    /// R5: upper bound on one ``delete(ids:)`` call's id list, which becomes an `id IN %@` clause.
    public static let maxIDsPerDelete = 500

    /// Re-seals every row that opens under `oldKey` under `newKey` — the device-key → hub-key fold
    /// the app runs whenever the Private tab opens (see ``JournalNarrativeStoring/reencryptAll(from:to:)``).
    ///
    /// Rows that do not open under `oldKey` (already under the hub key, or sealed under a key that is
    /// gone) are left untouched — a classification decision, never a deletion. Paged: `rowCount` is
    /// fixed before the walk and every iteration advances by the rows it handled (R2); each page
    /// commits atomically (a failed save rolls that page back and rethrows), and a re-run is
    /// idempotent because a migrated row no longer opens under `oldKey`. Sets the divergence latch
    /// when anything was re-sealed, like every other mutation.
    ///
    /// - Returns: How many rows opened under `oldKey` but could not be re-sealed under `newKey`.
    public func reencryptAll(from oldKey: SymmetricKey, to newKey: SymmetricKey) throws -> Int {
        try context.performAndWait {
            let rowCount = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative"))
            var offset = 0
            var failures = 0
            var mutatedAnyPage = false
            while offset < rowCount {
                let page = try fetchWalkPage(offset: offset)
                guard !page.isEmpty else { break }
                let outcome = resealPage(page, from: oldKey, to: newKey)
                failures += outcome.failures
                if outcome.mutated {
                    mutatedAnyPage = true
                    do {
                        try context.saveSealed()
                    } catch {
                        context.rollback()
                        throw error
                    }
                }
                offset += page.count
            }
            if failures > 0 {
                FernletAuditLog.log("journal.reencryptSkipped", context: ["count": "\(failures)"])
            }
            guard mutatedAnyPage else { return failures }
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "JournalNarrative.reencryptAll")
            markNarrativeStored()
            return failures
        }
    }

    /// Classifies every row by whether it opens under `key` — READ-ONLY, nothing is kept but ids.
    /// `nil` means no such key exists on this iPhone, so every row is dead under it.
    ///
    /// Paged like ``reencryptAll(from:to:)``. See ``SealedRowOpenability`` for what dead and
    /// transient mean; a caller must never call a row unopenable while `transientCount > 0`.
    public func openability(under key: SymmetricKey?) throws -> SealedRowOpenability {
        try context.performAndWait {
            let rowCount = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative"))
            var result = SealedRowOpenability()
            var offset = 0
            while offset < rowCount {
                let page = try fetchWalkPage(offset: offset)
                guard !page.isEmpty else { break }
                for object in page {
                    guard let id = object.value(forKey: "id") as? UUID else { continue }
                    classify(object, id: id, under: key, into: &result)
                }
                offset += page.count
            }
            return result
        }
    }

    /// Deletes the rows with these ids WITHOUT decrypting them, in one save — how the "entries this
    /// iPhone can't open" card removes exactly the rows it named. Sets the divergence latch when a
    /// row was removed (``delete(id:)``'s reasoning). The history prune rethrows.
    ///
    /// - Parameter ids: At most ``maxIDsPerDelete`` ids per call (R5 — the list becomes an `IN`
    ///   clause); the caller pages longer lists.
    public func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let bounded = Array(ids.prefix(Self.maxIDsPerDelete))
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
            request.predicate = NSPredicate(format: "id IN %@", bounded)
            let rows = try context.fetch(request)
            rows.forEach(context.delete)
            try context.saveSealed()
            try PrivatePersistentHistoryPruner.prune(context: context)
            if !rows.isEmpty { markNarrativeStored() }
        }
    }

    /// Clears the divergence latch (``hasEverStoredNarrative``). NOT a wipe step — "delete everything"
    /// keeps the latch by design. Called only when the key every sealed row here spoke for is
    /// provably gone: the app's new-key check after the unopenable rows were removed, and an app-lock
    /// reset (period-data design 2026-09-30, §4.9, §9.21). The latch backfills from the row count, so
    /// clearing it over rows that still exist is undone by the next read.
    public func clearDivergenceLatch() {
        defaults.removeObject(forKey: Self.everStoredDefaultsKey)
    }

    /// One bounded page of rows in a stable total order (`entryDate`, then the unique `id`), so
    /// successive pages of a walk neither overlap nor skip rows.
    private func fetchWalkPage(offset: Int) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
        request.sortDescriptors = [
            NSSortDescriptor(key: "entryDate", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        request.fetchOffset = offset
        request.fetchLimit = Self.walkPageSize
        return try context.fetch(request)
    }

    /// Re-seals both sealed columns of every row in `page` that opens under `oldKey`.
    ///
    /// - Returns: Whether anything was mutated, and how many rows opened but could not be re-sealed.
    private func resealPage(
        _ page: [NSManagedObject],
        from oldKey: SymmetricKey,
        to newKey: SymmetricKey
    ) -> (mutated: Bool, failures: Int) {
        var mutated = false
        var failures = 0
        for object in page {
            // Only rows sealed under `oldKey` migrate — a classification decision, not a swallowed
            // failure (the same rule `WorryNarrativeRepository.reencryptAll` follows).
            guard let opened = openColumns(object, under: oldKey) else { continue }
            do {
                let text = try crypto.sealString(opened.text, contentKey: newKey)
                let emotions = try crypto.seal(opened.emotions, contentKey: newKey)
                object.setValue(text, forKey: "textCiphertext")
                object.setValue(emotions, forKey: "emotionsCiphertext")
                mutated = true
            } catch {
                failures += 1
            }
        }
        return (mutated, failures)
    }

    /// Both sealed columns of `object` opened under `key`, or nil when either refuses.
    private func openColumns(_ object: NSManagedObject, under key: SymmetricKey) -> (text: String, emotions: [String])? {
        do {
            let text = try crypto.openString(object.value(forKey: "textCiphertext") as? Data, contentKey: key) ?? ""
            let emotions: [String] = try crypto.open(object.value(forKey: "emotionsCiphertext") as? Data, contentKey: key) ?? []
            return (text, emotions)
        } catch {
            return nil
        }
    }

    /// Files one row under ``SealedRowOpenability``: the install-binding read that could not answer is
    /// transient; every other refusal is dead.
    private func classify(_ object: NSManagedObject, id: UUID, under key: SymmetricKey?, into result: inout SealedRowOpenability) {
        guard let key else {
            result.deadIDs.append(id)
            return
        }
        do {
            _ = try crypto.openString(object.value(forKey: "textCiphertext") as? Data, contentKey: key)
            let _: [String]? = try crypto.open(object.value(forKey: "emotionsCiphertext") as? Data, contentKey: key)
            result.openableIDs.append(id)
        } catch is DeviceBindingID.ReadError {
            result.transientCount += 1
        } catch {
            result.deadIDs.append(id)
        }
    }

    // MARK: - Private

    /// Writes `narrative` onto a managed object, sealing `text`/`emotions` and stamping
    /// `updatedAt` while preserving the caller-resolved `createdAt`.
    private func apply(
        _ narrative: JournalNarrative,
        to object: NSManagedObject,
        contentKey: SymmetricKey,
        createdAt: Date
    ) throws {
        object.setValue(narrative.id, forKey: "id")
        object.setValue(narrative.dayKey, forKey: "dayKey")
        object.setValue(narrative.tag.rawValue, forKey: "tag")
        object.setValue(narrative.entryDate, forKey: "entryDate")
        object.setValue(try crypto.sealString(narrative.text, contentKey: contentKey), forKey: "textCiphertext")
        object.setValue(try crypto.seal(narrative.emotions, contentKey: contentKey), forKey: "emotionsCiphertext")
        object.setValue(createdAt, forKey: "createdAt")
        object.setValue(Date(), forKey: "updatedAt")
    }

    /// Rehydrates one row into a ``JournalNarrative``, opening its sealed columns.
    ///
    /// - Returns: `nil` when a plaintext identity field is missing/invalid; throws when a
    ///   ciphertext column fails to open (callers turn that into a skipped row).
    private func decrypt(_ object: NSManagedObject, contentKey: SymmetricKey) throws -> JournalNarrative? {
        guard let id = object.value(forKey: "id") as? UUID,
              let dayKey = object.value(forKey: "dayKey") as? String,
              let tagRaw = object.value(forKey: "tag") as? String,
              let tag = FeelingTag(rawValue: tagRaw),
              let entryDate = object.value(forKey: "entryDate") as? Date else { return nil }
        let text = try crypto.openString(object.value(forKey: "textCiphertext") as? Data, contentKey: contentKey) ?? ""
        let emotions: [String] = try crypto.open(object.value(forKey: "emotionsCiphertext") as? Data, contentKey: contentKey) ?? []
        return JournalNarrative(
            id: id,
            dayKey: dayKey,
            tag: tag,
            entryDate: entryDate,
            text: text,
            emotions: emotions,
            createdAt: object.value(forKey: "createdAt") as? Date ?? entryDate,
            updatedAt: object.value(forKey: "updatedAt") as? Date ?? entryDate
        )
    }

    /// Fetch request for the single row whose plaintext `id` matches.
    private func request(id: UUID) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return request
    }

}

import CoreData
import FernletCrypto
import FernletFoundation
import CryptoKit
import Foundation
import FernletDomainModel
import PrivateStoreCore

/// One intimacy record: an event date plus a free-text note that is encrypted at rest.
///
/// The plaintext half of an `IntimacyLog` row in the sealed (local-only, never-synced) private
/// store: `id`, `dayKey`, `eventDate`, and the timestamps are stored in the clear for querying,
/// while ``note`` exists only as ChaChaPoly ciphertext and is decrypted by ``IntimacyLogRepository``
/// on read. The clinical fact of the activity itself lives in HealthKit as a sexual-activity sample
/// (linked via ``healthKitExternalUUID``); this type carries only Fernlet's note about it.
///
/// `Codable` so the app-side sealed-backup export can serialize decrypted rows into its re-encrypted
/// chunks (payload type `intimacyLogs`) and the restore can decode them back. The type is
/// self-contained — nothing outside this row is needed to render a restored log — which is why
/// intimacy restore, unlike journal restore, needs no day-skeleton reconstruction step.
/// `Sendable` (a plain value type of Sendable fields) because the repository seals it inside
/// `NSManagedObjectContext.performAndWait`, whose closure is `@Sendable`.
public nonisolated struct IntimacyLog: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// Canonical `yyyy-MM-dd` day key derived from ``eventDate`` (see `FernletDate`).
    public var dayKey: String
    /// When the event happened, as the user logged it.
    public var eventDate: Date
    /// The user's free-text note — the sealed column; empty when nothing was written.
    public var note: String
    /// `HKMetadataKeyExternalUUID` of the matching HealthKit sexual-activity sample once the
    /// save-to-HealthKit step succeeded; `nil` until then.
    public var healthKitExternalUUID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        eventDate: Date,
        note: String,
        healthKitExternalUUID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dayKey = FernletDate.dayKey(for: eventDate)
        self.eventDate = eventDate
        self.note = note
        self.healthKitExternalUUID = healthKitExternalUUID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(
        id: UUID,
        dayKey: String,
        eventDate: Date,
        note: String,
        healthKitExternalUUID: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.dayKey = dayKey
        self.eventDate = eventDate
        self.note = note
        self.healthKitExternalUUID = healthKitExternalUUID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Sealed at-rest CRUD for intimacy logs: seals notes into the private Core Data store with
/// `ColumnCrypto` and decrypts them back on read.
///
/// The persistence layer beneath ``IntimacyLogStore`` (the `@MainActor` funnel that adds the
/// visibility gate); nothing else should touch the `IntimacyLog` entity. Rows live in
/// `PrivatePersistenceController`'s local-only store — never CloudKit, and unreachable from the
/// walled `AIProviders`/`CloudKitSync` modules by construction. The note column is sealed via a
/// `ColumnCrypto` labeled `"intimacy-log"` (an HKDF domain separation that keeps intimacy
/// ciphertext unopenable under the other sealed columns' derived keys), while `id`, `dayKey`,
/// `eventDate`, and the timestamps stay plaintext for querying.
///
/// Key discipline: the content key is passed per call and never retained here. Writes fail closed
/// (``insert(_:contentKey:)`` throws `FernletLockError.locked` without a key), reads degrade
/// (``logs(contentKey:)`` returns `[]`, and a row whose ciphertext fails to authenticate is
/// skipped rather than failing the whole fetch), and deletes never need the key — they drop rows
/// without decrypting, which is what keeps the full wipe available while locked or hidden. Every
/// mutation prunes Core Data persistent history afterward (best-effort) so superseded ciphertext
/// does not linger in the transaction log — and every mutation (deletes included) sets the one-way
/// divergence latch.
///
/// The app's `SealedBackupCoordinator` is the second client (payload type `intimacyLogs`, added
/// 2026-08-10) — but it too goes through ``IntimacyLogStore``, never here directly: the app target is
/// grep-walled against constructing this repository so no call site can read or write around the hard
/// gate. The backup surface it uses is the paged ``logs(offset:limit:contentKey:)`` / ``logCount()``
/// pair, ``insertAtomically(_:contentKey:)``, and ``hasEverStoredLog`` (so a restore can never
/// resurrect logs the user deliberately deleted), each exposed through the funnel's sealed-backup
/// seam with its own gating decision.
///
/// A `nonisolated` final class: all Core Data access is serialized through the view context's
/// `performAndWait`, so it is callable from any executor — and therefore `Sendable`, which
/// `performAndWait`'s `@Sendable` closure requires of the `self` it captures. The conformance is
/// `@unchecked` for exactly one reason — `UserDefaults` carries no SDK `Sendable` annotation — and
/// rests on this invariant: every stored property is a `let`; `context` (`NSManagedObjectContext`,
/// `Sendable` in the iOS 26 SDK) is only ever touched inside its own `performAndWait`, which
/// serializes on the context's queue; `crypto` is a stateless value; and `defaults` is
/// Apple-documented thread-safe and used only for the one-way latch below. Adding a `var` here
/// would break the invariant and must not happen.
public nonisolated final class IntimacyLogRepository: @unchecked Sendable {
    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1)

    /// R3: cap on the display fetch, which decrypts every row it returns and holds the plaintext
    /// notes for as long as the caller keeps them. Older rows stay reachable through the paged
    /// ``logs(offset:limit:contentKey:)``.
    private static let maxDisplayedLogs = 500
    /// R3: upper bound on one page of ``logs(offset:limit:contentKey:)``, so an absurd `limit` cannot
    /// decrypt the whole table at once. Above the 250-row sealed-backup chunk size.
    private static let maxPageSize = 500

    /// Device-local marker for "this install has written intimacy logs at some point", used by the
    /// sealed-backup restore to tell TWO very different empty stores apart:
    ///
    /// - **never populated** (a genuine reinstall / new device) — restoring the sealed backup is the
    ///   whole point, and there is nothing local to lose.
    /// - **emptied by the user** (they deleted their logs) — the cloud backup is stale by construction,
    ///   because deletes do not reconcile the sealed backup. Restoring there would silently resurrect
    ///   intimacy notes the user deliberately deleted, which is precisely the harm the sealed store
    ///   exists to prevent.
    ///
    /// Mirrors `MenstrualNarrativeRepository.hasEverStoredNarrative` exactly, including living in
    /// **standard (device-local, non-synced) defaults**: iOS drops the app container on uninstall, so a
    /// real reinstall clears it for free, while a delete-all on a live install leaves it SET so the
    /// wipe cannot be undone by a stale cloud copy. Never cleared once set — a one-way latch.
    ///
    /// - Important: The key string is device-local state a shipped build already writes; changing it
    ///   would silently reset every existing install's latch back to "never populated".
    private static let everStoredDefaultsKey = "fernlet.intimacyLog.everStored"

    /// Injected so tests get an isolated suite — the latch is process-global otherwise, and one test
    /// writing a log would leak "this device has diverged" into every later test in the run.
    private let defaults: UserDefaults

    /// Reads the latch, BACKFILLING it from the row count first: installs whose logs predate the latch
    /// (it ships later than the store) have rows but no defaults bit, and without the backfill an
    /// upgrading user who then deleted their logs would read as "never populated" — re-opening the
    /// resurrection this latch exists to close. A count error leaves the latch unread and un-backfilled
    /// (return the raw bit): claiming divergence on an error would wrongly block a genuine reinstall's
    /// restore forever, and the restore path's own no-clobber count check still refuses a populated store.
    ///
    /// Deliberately NOT gated on intimacy visibility: it counts rows without decrypting anything, and a
    /// hidden store must never read as "never populated" (that would let a restore run behind the gate).
    public var hasEverStoredLog: Bool {
        if defaults.bool(forKey: Self.everStoredDefaultsKey) { return true }
        guard let count = try? logCount(), count > 0 else { return false }
        markLogStored()
        return true
    }

    /// Sets the one-way divergence latch. Called by every mutation — deletes included — AFTER the
    /// write actually commits, so a failed write never claims this device has diverged.
    private func markLogStored() {
        defaults.set(true, forKey: Self.everStoredDefaultsKey)
    }

    /// Creates a repository on a sealed-store stack.
    ///
    /// - Parameters:
    ///   - controller: The private persistence stack to use; `nil` selects the shared
    ///     `PrivatePersistenceController`.
    ///   - defaults: Suite holding the divergence latch; tests inject an isolated suite.
    public init(controller: PrivatePersistenceController? = nil, defaults: UserDefaults = .standard) {
        self.context = (controller ?? .shared).container.viewContext
        self.defaults = defaults
    }

    /// Creates a repository on an explicit managed-object context — the seam tests use to run
    /// against an in-memory store.
    ///
    /// - Parameters:
    ///   - context: The managed-object context every operation is funneled through.
    ///   - defaults: Suite holding the divergence latch; tests inject an isolated suite.
    public init(context: NSManagedObjectContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
    }

    /// Seals and stores a new log, then prunes persistent history (best-effort).
    ///
    /// - Important: Fails closed — throws `FernletLockError.locked` when `contentKey` is `nil`
    ///   (the private area is locked), so no plaintext row can ever be written.
    public func insert(_ log: IntimacyLog, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "IntimacyLog", into: context)
            try apply(log, to: object, contentKey: contentKey)
            // Save, then prune history so no prior ciphertext transaction lingers for this sealed row (best-effort).
            try PrivatePersistentHistoryPruner.saveAndPrune(context)
            // Latch AFTER a successful save, so a failed write never claims this device has diverged.
            markLogStored()
        }
    }

    /// Inserts many logs in a SINGLE transaction: either all commit or none do. Used by the
    /// sealed-backup RESTORE so a mid-batch failure cannot leave a partially-populated store — a
    /// partial store would trip the restore no-clobber gate (`logCount() != 0`) on the next launch and
    /// never retry, silently dropping the un-inserted sealed records.
    ///
    /// A plain insert into a store the caller has already proven empty; no upsert, no per-row fetch.
    ///
    /// - Important: Throws `FernletLockError.locked` when `contentKey` is `nil`. On any per-record
    ///   failure the whole batch is rolled back and the error rethrown, leaving the store empty so the
    ///   next launch re-pulls the full backup.
    public func insertAtomically(_ logs: [IntimacyLog], contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        guard !logs.isEmpty else { return }
        try context.performAndWait {
            do {
                for log in logs {
                    let object = NSEntityDescription.insertNewObject(forEntityName: "IntimacyLog", into: context)
                    try apply(log, to: object, contentKey: contentKey)
                }
                try context.saveSealed()
            } catch {
                context.rollback()
                throw error
            }
            // Prune history after the atomic restore so no per-record transaction lingers in the
            // persistent-history transaction log (best-effort, and logged when it fails).
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "IntimacyLog.insertAtomically")
            // Latch AFTER the transaction commits. A restore that populates the store also counts as
            // "this device has intimacy logs", so a later delete-everything cannot re-pull them.
            markLogStored()
        }
    }

    /// Total number of stored logs, counted without decrypting (or even faulting in) any rows. Lets the
    /// sealed-backup export size its chunks up front, and lets the restore's no-clobber gate run
    /// without a content key.
    public func logCount() throws -> Int {
        try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog"))
        }
    }

    /// A single page of logs, decrypted, in a stable TOTAL order (`eventDate` ASCENDING, then the
    /// unique `id` tiebreaker). Backs the chunked sealed-backup export: paging by `offset`/`limit`
    /// keeps each chunk bounded regardless of how long the history is.
    ///
    /// Note the direction differs from ``logs(contentKey:)``, which is newest-first for display. Export
    /// order only has to be *total* and *stable*; ascending matches the other sealed repositories, and
    /// the `id` tiebreaker is what stops two logs sharing an `eventDate` from sorting
    /// non-deterministically and making successive pages overlap or skip rows.
    ///
    /// Returns `[]` without a key; rows that fail to decrypt are skipped rather than failing the page.
    public func logs(offset: Int, limit: Int, contentKey: SymmetricKey?) throws -> [IntimacyLog] {
        guard let contentKey, limit > 0 else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.sortDescriptors = [
                NSSortDescriptor(key: "eventDate", ascending: true),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            request.fetchOffset = max(0, offset)
            // R3/R5: clamp the caller's page size so `limit: .max` cannot decrypt the whole table.
            request.fetchLimit = min(limit, Self.maxPageSize)
            return decryptLogs(try context.fetch(request), contentKey: contentKey)
        }
    }

    /// The newest stored logs, newest first, decrypted with `contentKey` — the DISPLAY read, bounded
    /// by ``maxDisplayedLogs`` (R3). Older rows stay reachable through the paged
    /// ``logs(offset:limit:contentKey:)``, which the sealed-backup export uses.
    ///
    /// - Returns: `[]` when `contentKey` is `nil` (locked). Rows whose ciphertext fails to
    ///   authenticate (wrong key, tampering) are skipped rather than failing the fetch, and the
    ///   number skipped is audit-logged once per fetch.
    public func logs(contentKey: SymmetricKey?) throws -> [IntimacyLog] {
        guard let contentKey else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.sortDescriptors = [NSSortDescriptor(key: "eventDate", ascending: false)]
            // R3: repeated user actions grow this table without bound, so the display path takes the
            // newest page instead of faulting in and decrypting every log ever written.
            request.fetchLimit = Self.maxDisplayedLogs
            return decryptLogs(try context.fetch(request), contentKey: contentKey)
        }
    }

    /// Decrypts a fetched row set, skipping rows whose sealed columns will not open and recording ONE
    /// audit line per fetch (never per row, so a mass failure cannot spam the log).
    ///
    /// Skip-don't-fail is deliberate — one unopenable row must not blank the list — but an
    /// authentication failure (tampering, a wrong key, bit-rot) may not read as "no logs" either.
    private func decryptLogs(_ objects: [NSManagedObject], contentKey: SymmetricKey) -> [IntimacyLog] {
        var skipped = 0
        let rows = objects.compactMap { object -> IntimacyLog? in
            do {
                return try decryptLog(object, contentKey: contentKey)
            } catch {
                skipped += 1
                return nil
            }
        }
        if skipped > 0 {
            FernletAuditLog.log(
                "sealedRow.undecryptable",
                context: ["entity": "IntimacyLog", "count": "\(skipped)"]
            )
        }
        return rows
    }

    /// Deletes one log by `id` without decrypting it, then prunes persistent history. A missing row
    /// is a silent no-op.
    ///
    /// Sets the divergence latch when a row was actually removed: the deletion itself is the proof this
    /// device diverged from the cloud snapshot (the sealed backup is NOT reconciled by deletes), so
    /// without it, deleting the last log would leave an empty, unlatched store that a later restore
    /// would happily re-populate from the stale cloud copy.
    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let rows = try context.fetch(request)
            rows.forEach(context.delete)
            try context.saveSealed()
            try PrivatePersistentHistoryPruner.prune(context: context)
            if !rows.isEmpty { markLogStored() }
        }
    }

    /// Drops every stored log. Deletes rows WITHOUT decrypting them, so it works while the app is locked
    /// and while intimacy tracking is hidden. Routes through the shared `PrivateRowPlumbing.deleteRows`
    /// sequence, like every sealed repository's `deleteAll()`.
    ///
    /// Sets the divergence latch iff rows were actually removed — same reasoning as ``delete(id:)``,
    /// and what keeps "delete everything" from being undone by a stale cloud backup that survived a
    /// failed chunk delete.
    public func deleteAll() throws {
        if try PrivateRowPlumbing.deleteRows(entityName: "IntimacyLog", in: context) {
            markLogStored()
        }
    }

    /// Records the HealthKit external UUID on an already-saved row — plaintext metadata only; the
    /// sealed note is neither decrypted nor re-sealed. A missing row is a silent no-op.
    public func markSavedToHealthKit(id: UUID, externalUUID: UUID) throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard let object = try context.fetch(request).first else { return }
            object.setValue(externalUUID.uuidString, forKey: "healthKitExternalUUID")
            object.setValue(Date(), forKey: "updatedAt")
            // Save, then prune history so the prior transaction for this sealed row is not retained (best-effort).
            try PrivatePersistentHistoryPruner.saveAndPrune(context)
            // An update proves a row existed — latch even when the ORIGINAL insert predates the latch
            // (an upgrading install), so a later empty store still reads as "diverged", not "fresh".
            markLogStored()
        }
    }

    /// Writes one log onto a managed object, sealing the note column. Shared by ``insert(_:contentKey:)``
    /// and the atomic restore so both write exactly the same columns.
    private func apply(_ log: IntimacyLog, to object: NSManagedObject, contentKey: SymmetricKey) throws {
        object.setValue(log.id, forKey: "id")
        object.setValue(log.dayKey, forKey: "dayKey")
        object.setValue(log.eventDate, forKey: "eventDate")
        object.setValue(try crypto.sealString(log.note, contentKey: contentKey), forKey: "noteCiphertext")
        object.setValue(log.healthKitExternalUUID, forKey: "healthKitExternalUUID")
        object.setValue(log.createdAt, forKey: "createdAt")
        object.setValue(log.updatedAt, forKey: "updatedAt")
    }

    /// Rehydrates one managed object into an ``IntimacyLog``, decrypting the note column; returns
    /// `nil` when the required plaintext fields are missing, and throws when decryption fails.
    private func decryptLog(_ object: NSManagedObject, contentKey: SymmetricKey) throws -> IntimacyLog? {
        guard let id = object.value(forKey: "id") as? UUID,
              let dayKey = object.value(forKey: "dayKey") as? String,
              let eventDate = object.value(forKey: "eventDate") as? Date else { return nil }
        return IntimacyLog(
            id: id,
            dayKey: dayKey,
            eventDate: eventDate,
            note: try crypto.openString(object.value(forKey: "noteCiphertext") as? Data, contentKey: contentKey) ?? "",
            healthKitExternalUUID: object.value(forKey: "healthKitExternalUUID") as? String,
            createdAt: object.value(forKey: "createdAt") as? Date ?? eventDate,
            updatedAt: object.value(forKey: "updatedAt") as? Date ?? eventDate
        )
    }

}

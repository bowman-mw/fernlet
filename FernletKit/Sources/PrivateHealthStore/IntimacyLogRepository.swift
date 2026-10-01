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

/// One page of intimacy logs as the Sealed backup reads them by id (journal and intimacy Sealed backup
/// v2 design 2026-09-30, §4.1, §8): every requested id that still has a row is classified — never
/// silently skipped, because an export that dropped a row it could not open would write a backup
/// missing it over one that holds it.
///
/// - ``records``: rows that opened under the key, one per id, in the order the ids were asked for.
/// - ``deadIDs``: ids whose every row fails to authenticate under the key — they can never open here.
/// - ``needsNewerBuildIDs``: ids whose row opens but lacks a plaintext column this build reads (its
///   day key or event date) — never dead: a build that can read it would show it.
/// - ``transientCount``: rows this attempt could not decide (the install-binding keychain read did not
///   answer); a caller must never call anything dead while it is above zero.
///
/// An id with no row at all was deleted since the snapshot and is simply absent. `Sendable`: a plain
/// value crossing `performAndWait`'s `@Sendable` closure.
public nonisolated struct IntimacyLogPage: Equatable, Sendable {
    /// Rows that opened, one per id, in the requested order.
    public var records: [IntimacyLog]
    /// Ids whose rows can never open under this key.
    public var deadIDs: [UUID]
    /// Ids whose rows open but carry a plaintext column this build cannot read.
    public var needsNewerBuildIDs: [UUID]
    /// Rows this attempt could not decide (retryable).
    public var transientCount: Int

    /// Creates a page.
    public init(records: [IntimacyLog] = [], deadIDs: [UUID] = [], needsNewerBuildIDs: [UUID] = [], transientCount: Int = 0) {
        self.records = records
        self.deadIDs = deadIDs
        self.needsNewerBuildIDs = needsNewerBuildIDs
        self.transientCount = transientCount
    }
}

/// What one restore merge (``IntimacyLogRepository/upsertMerged(_:contentKey:)``) changed.
///
/// `Sendable`: a plain value returned out of `performAndWait`.
public nonisolated struct IntimacyLogMergeResult: Equatable, Sendable {
    /// Ids that were absent and are now stored, with the backup's own stamps.
    public var inserted = 0
    /// Ids whose stored row opened and had no Health link, and now carries the backup's.
    public var linked = 0
    /// Ids whose every stored row was dead, replaced by the backup's copy.
    public var replaced = 0
    /// Ids whose stored row opened and was left exactly as it was.
    public var unchanged = 0

    /// Creates an empty result.
    public init() {}

    /// How many ids the merge inserted, linked or replaced.
    public var changedCount: Int { inserted + linked + replaced }
    /// Whether the save changed anything on disk.
    public var changedAnything: Bool { changedCount > 0 }
}

/// An intimacy-log batch call the repository refused, with nothing written.
///
/// `Sendable`: thrown out of `performAndWait`.
public nonisolated enum IntimacyLogRepositoryError: Error, Equatable, Sendable {
    /// A stored row with an id this write touches could not be decided (the install binding did not
    /// answer) or carries a column this build cannot read. Nothing was written; retryable.
    case undecidedRows(count: Int)
    /// A call named more ids or records than one call accepts.
    case batchTooLarge(count: Int, limit: Int)
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
/// gate. Since the Sealed backup v2 (journal and intimacy design 2026-09-30, §8, unit B2) the backup
/// surface is the v2 engine's: the keyless id snapshot ``allIDs()``, the classified read
/// ``logs(ids:contentKey:)`` (opened, dead, needs a newer build, undecided — never a silent skip), the
/// one restore write ``upsertMerged(_:contentKey:)`` (an id-keyed MERGE: insert absent ids with their
/// own stamps, keep every row that opens and only fill its missing Health link, replace rows that can
/// never open, never delete), the keyless ``delete(ids:)`` behind "Remove them", and
/// ``isStoreHealthy``. ``hasEverStoredLog`` no longer gates any restore: it seeds the app's intimacy
/// restore marker once. Each is exposed through the funnel's sealed-backup seam with its own gating
/// decision.
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
    /// R3: upper bound on one page of ``logs(offset:limit:contentKey:)`` and on the ids one
    /// ``logs(ids:contentKey:)`` names, so an absurd `limit` cannot decrypt the whole table at once.
    /// Above the 250-row sealed-backup chunk size.
    public static let maxPageSize = 500
    /// R3: the Sealed backup's record bound — the most records one ``upsertMerged(_:contentKey:)`` or
    /// ``delete(ids:)`` accepts. ``allIDs()`` answers at most ONE more than this, so a store past the
    /// bound reads as past it (the export refuses it as too large), never as exactly at it.
    public static let maxBackupRecords = 100_000
    /// The longest note this store seals — the cap ``IntimacyLogStore/insert(_:contentKey:)``
    /// applies to a user's note and ``upsertMerged(_:contentKey:)`` applies to a restored one, so a
    /// hostile or older backup can never seal an unbounded note.
    public static let maxNoteLength = 1_000

    /// Device-local marker for "this install has written intimacy logs at some point". Since the
    /// Sealed backup v2 (design 2026-09-30, §4.3, unit B2) it gates no restore: the app reads it ONCE,
    /// as the seed of its intimacy restore marker (`fernlet.intimacyLog.restoreResolved`), the first
    /// time a build with that marker launches. The distinction it seeds is the one it always drew,
    /// between TWO very different empty stores:
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
    /// wipe cannot be undone by a stale cloud copy. One-way for every writer and for the wipe; cleared
    /// only by ``clearDivergenceLatch()``, once the key the rows spoke for is provably gone.
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
    /// restore forever.
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

    /// Clears the divergence latch (``hasEverStoredLog``). NOT a wipe step — "delete everything"
    /// keeps the latch by design. Called only when the key every sealed row here spoke for is
    /// provably gone: the app's new-key check after the unopenable rows were removed, and an app-lock
    /// reset (period-data design 2026-09-30, §4.9, §9.21). The latch backfills from the row count, so
    /// clearing it over rows that still exist is undone by the next read.
    public func clearDivergenceLatch() {
        defaults.removeObject(forKey: Self.everStoredDefaultsKey)
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
    ///   (the private area is locked), so no plaintext row can ever be written. On a failed seal or
    ///   save the inserted object is removed from the context before rethrowing, so no half-built row
    ///   survives the failure (see the inline rationale).
    public func insert(_ log: IntimacyLog, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "IntimacyLog", into: context)
            do {
                try apply(log, to: object, contentKey: contentKey)
                try context.saveSealed()
            } catch {
                // `apply` writes the plaintext columns (id, dayKey, eventDate, healthKitExternalUUID)
                // BEFORE it seals the note, so a throw from the middle of it — `ColumnCrypto`'s
                // `SealedColumnStrictSealError.bindingUnavailable`, when the install's device-binding
                // keychain row is momentarily unreadable — would leave a note-LESS row pending in the
                // SHARED view context, which the next successful sealed write on that context would
                // then commit durably. Such a row is indistinguishable from a successfully sealed one
                // (a nil note ciphertext opens as nil, so `decryptLog` returns a valid, empty-note
                // log), so the event reads as already recorded while the note the user typed is gone.
                // Undo the insert rather than let a transient keychain fault leave that behind;
                // `delete`, not `rollback`, so an unrelated unsaved edit on the shared context stands.
                context.delete(object)
                throw error
            }
            // Prune history so no prior ciphertext transaction lingers for this sealed row
            // (best-effort — a prune failure must not undo the write that succeeded — and logged).
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "IntimacyLog.insert")
            // Latch AFTER a successful save, so a failed write never claims this device has diverged.
            markLogStored()
        }
    }

    /// Total number of stored logs, counted without decrypting (or even faulting in) any rows — the
    /// "entries this iPhone can't open" check's count and the divergence latch's backfill.
    public func logCount() throws -> Int {
        try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog"))
        }
    }

    /// A single page of logs, decrypted, in a stable TOTAL order (`eventDate` ASCENDING, then the
    /// unique `id` tiebreaker) — the same order as ``allIDs()``. Paging by `offset`/`limit` keeps
    /// each page bounded regardless of how long the history is. (The Sealed backup no longer pages by
    /// offset: it snapshots ids and reads them with ``logs(ids:contentKey:)``, which can never shift
    /// under a concurrent write.)
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
    ///
    /// - Returns: Whether any row was removed (failure is always a throw) — what the funnel's mutation
    ///   hook keys off, like `CycleRecordRepository.deleteAll()`.
    public func deleteAll() throws -> Bool {
        let removed = try PrivateRowPlumbing.deleteRows(entityName: "IntimacyLog", in: context)
        if removed { markLogStored() }
        return removed
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
    /// and the restore merge so both write exactly the same columns.
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

// MARK: - Sealed backup v2 surface (design 2026-09-30, §4.1, §8)

nonisolated extension IntimacyLogRepository {
    /// How one stored row answered the key.
    private enum RowOpening {
        case opened(IntimacyLog, NSManagedObject)
        case dead
        case needsNewerBuild
        case undecided
    }

    /// Whether the context's coordinator has a persistent store attached — false when the sealed
    /// store failed to load (the controller then runs against an empty coordinator, where every read
    /// answers empty and would read as "no logs") or is between a failed rebuild and its heal. The
    /// Sealed backup engine requires it before every snapshot and every restore write (R2-F2). Keyless.
    public var isStoreHealthy: Bool {
        context.performAndWait {
            !(context.persistentStoreCoordinator?.persistentStores.isEmpty ?? true)
        }
    }

    /// Every stored id, distinct, in the store's total order (`eventDate` ascending, then `id`) —
    /// KEYLESS, decrypting nothing. The backup export's snapshot: its chunks are read by these ids, so
    /// a page can never shift under a concurrent write. Bounded at ``maxBackupRecords`` + 1 ids.
    public func allIDs() throws -> [UUID] {
        try context.performAndWait {
            let request = NSFetchRequest<NSDictionary>(entityName: "IntimacyLog")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id", "eventDate"]
            request.sortDescriptors = [
                NSSortDescriptor(key: "eventDate", ascending: true),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            request.fetchLimit = Self.maxBackupRecords + 1
            var seen = Set<UUID>()
            return try context.fetch(request).compactMap { $0["id"] as? UUID }.filter { seen.insert($0).inserted }
        }
    }

    /// The logs with these ids, classified (see ``IntimacyLogPage``). An id with no row is absent; an
    /// id whose rows include one that opens answers that row. Empty without a key.
    ///
    /// - Parameter ids: At most ``maxPageSize`` ids.
    /// - Throws: ``IntimacyLogRepositoryError/batchTooLarge(count:limit:)``; a fetch error.
    public func logs(ids: [UUID], contentKey: SymmetricKey?) throws -> IntimacyLogPage {
        guard ids.count <= Self.maxPageSize else {
            throw IntimacyLogRepositoryError.batchTooLarge(count: ids.count, limit: Self.maxPageSize)
        }
        guard let contentKey, !ids.isEmpty else { return IntimacyLogPage() }
        return try context.performAndWait {
            let grouped = try fetchRows(ids: ids)
            var page = IntimacyLogPage()
            var seen = Set<UUID>()
            for id in ids where seen.insert(id).inserted {  // R2: bounded by `ids` (≤ maxPageSize).
                guard let rows = grouped[id] else { continue }
                switch opening(of: rows, contentKey: contentKey) {
                case .opened(let log, _): page.records.append(log)
                case .dead: page.deadIDs.append(id)
                case .needsNewerBuild: page.needsNewerBuildIDs.append(id)
                case .undecided: page.transientCount += 1
                }
            }
            if !page.deadIDs.isEmpty || !page.needsNewerBuildIDs.isEmpty || page.transientCount > 0 {
                FernletAuditLog.log("sealedRow.undecryptable", context: [
                    "entity": "IntimacyLog",
                    "dead": "\(page.deadIDs.count)",
                    "newer": "\(page.needsNewerBuildIDs.count)",
                    "undecided": "\(page.transientCount)"
                ])
            }
            return page
        }
    }

    /// THE restore write (design 2026-09-30, §8.2): an id-keyed MERGE of a restored set, in ONE save
    /// that is rolled back on any throw. The batch is first reduced by id (the later `updatedAt` wins;
    /// a tie keeps the first). Then, per id:
    /// - absent → inserted with the backup's own `createdAt` / `updatedAt`, its note capped at
    ///   ``maxNoteLength``;
    /// - present and a row opens → KEPT exactly as it is, except that a missing Health link is taken
    ///   from the backup (a link is never dropped or changed);
    /// - present and every row dead → replaced by the backup's copy (a dead row can never be read, so
    ///   an openable copy of the same id loses nothing);
    /// - present and undecided, or carrying a column this build cannot read → the WHOLE merge throws
    ///   ``IntimacyLogRepositoryError/undecidedRows(count:)`` and nothing is saved.
    ///
    /// It never deletes a row that opens and never chooses between two notes by their clocks: there
    /// is no per-log edit in the app, so a different note under one id can only come from corruption
    /// or a hostile set, and the local copy wins. Idempotent — a second merge of the same set changes
    /// nothing. History is pruned best-effort and the divergence latch set only when something changed.
    ///
    /// - Throws: `FernletLockError.locked` without a key; ``IntimacyLogRepositoryError``; a seal or save
    ///   error (rolled back).
    public func upsertMerged(_ incoming: [IntimacyLog], contentKey: SymmetricKey?) throws -> IntimacyLogMergeResult {
        guard let contentKey else { throw FernletLockError.locked }
        guard incoming.count <= Self.maxBackupRecords else {
            throw IntimacyLogRepositoryError.batchTooLarge(count: incoming.count, limit: Self.maxBackupRecords)
        }
        let batch = Self.reducedByID(incoming)
        return try context.performAndWait {
            let result: IntimacyLogMergeResult
            do {
                result = try applyMerge(batch, contentKey: contentKey)
                if context.hasChanges { try context.saveSealed() }
            } catch {
                context.rollback()
                throw error
            }
            if result.changedAnything {
                PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "IntimacyLog.upsertMerged")
                markLogStored()
            }
            return result
        }
    }

    /// Deletes every row with these ids WITHOUT decrypting, in one save, then prunes the history
    /// (rethrown) — "Remove them" for logs that can never open. A failed save is rolled back.
    ///
    /// - Parameter ids: At most ``maxBackupRecords`` ids.
    /// - Returns: How many rows were removed.
    public func delete(ids: [UUID]) throws -> Int {
        guard ids.count <= Self.maxBackupRecords else {
            throw IntimacyLogRepositoryError.batchTooLarge(count: ids.count, limit: Self.maxBackupRecords)
        }
        guard !ids.isEmpty else { return 0 }
        return try context.performAndWait {
            let rows = try fetchRows(ids: ids).values.flatMap { $0 }
            guard !rows.isEmpty else { return 0 }
            do {
                rows.forEach(context.delete)
                try context.saveSealed()
            } catch {
                context.rollback()
                throw error
            }
            try PrivatePersistentHistoryPruner.prune(context: context)
            markLogStored()
            return rows.count
        }
    }

    /// The per-id merge rule into the pending (unsaved) context — see ``upsertMerged(_:contentKey:)``.
    private func applyMerge(_ batch: [IntimacyLog], contentKey: SymmetricKey) throws -> IntimacyLogMergeResult {
        let existing = try fetchRows(ids: batch.map(\.id))
        var result = IntimacyLogMergeResult()
        for incoming in batch {  // R2: bounded by the batch (≤ maxBackupRecords).
            guard let rows = existing[incoming.id], let first = rows.first else {
                let object = NSEntityDescription.insertNewObject(forEntityName: "IntimacyLog", into: context)
                try apply(Self.capped(incoming), to: object, contentKey: contentKey)
                result.inserted += 1
                continue
            }
            switch opening(of: rows, contentKey: contentKey) {
            case .opened(let local, let object):
                guard local.healthKitExternalUUID == nil, let link = incoming.healthKitExternalUUID else {
                    result.unchanged += 1
                    continue
                }
                // Core Data KVC on the stored row (the `object` receiver the persisted-surface wall
                // knows is not a defaults write).
                object.setValue(link, forKey: "healthKitExternalUUID")
                result.linked += 1
            case .dead:
                try apply(Self.capped(incoming), to: first, contentKey: contentKey)
                rows.dropFirst().forEach(context.delete)
                result.replaced += 1
            case .needsNewerBuild, .undecided:
                throw IntimacyLogRepositoryError.undecidedRows(count: rows.count)
            }
        }
        return result
    }

    /// How an id's rows answer the key: the first row that opens wins; else any undecided row makes
    /// the id undecided; else a row this build cannot read makes it needs-a-newer-build; else dead.
    private func opening(of rows: [NSManagedObject], contentKey: SymmetricKey) -> RowOpening {
        var undecided = false
        var needsNewer = false
        for row in rows {  // R2: bounded by the id's rows.
            switch open(row, contentKey: contentKey) {
            case .opened(let log, let object): return .opened(log, object)
            case .dead: continue
            case .needsNewerBuild: needsNewer = true
            case .undecided: undecided = true
            }
        }
        if undecided { return .undecided }
        return needsNewer ? .needsNewerBuild : .dead
    }

    /// Opens one row: the plaintext columns first (a row missing its day key or event date is one this
    /// build cannot read — never dead), then the note.
    private func open(_ object: NSManagedObject, contentKey: SymmetricKey) -> RowOpening {
        guard let id = object.value(forKey: "id") as? UUID else { return .dead }
        guard let dayKey = object.value(forKey: "dayKey") as? String,
              let eventDate = object.value(forKey: "eventDate") as? Date else { return .needsNewerBuild }
        do {
            let note = try crypto.openString(object.value(forKey: "noteCiphertext") as? Data, contentKey: contentKey) ?? ""
            let log = IntimacyLog(
                id: id, dayKey: dayKey, eventDate: eventDate, note: note,
                healthKitExternalUUID: object.value(forKey: "healthKitExternalUUID") as? String,
                createdAt: object.value(forKey: "createdAt") as? Date ?? eventDate,
                updatedAt: object.value(forKey: "updatedAt") as? Date ?? eventDate
            )
            return .opened(log, object)
        } catch is DeviceBindingID.ReadError {
            return .undecided
        } catch {
            return .dead
        }
    }

    /// The rows of these ids, grouped by id — fetched `id IN` in slices of ``maxPageSize`` (R2:
    /// `ids.count / maxPageSize` rounded up fetches).
    private func fetchRows(ids: [UUID]) throws -> [UUID: [NSManagedObject]] {
        var grouped: [UUID: [NSManagedObject]] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.maxPageSize) {
            let slice = Array(ids[start..<min(start + Self.maxPageSize, ids.count)])
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.predicate = NSPredicate(format: "id IN %@", slice)
            for row in try context.fetch(request) {
                guard let id = row.value(forKey: "id") as? UUID else { continue }
                grouped[id, default: []].append(row)
            }
        }
        return grouped
    }

    /// `logs` with one copy per id: the later `updatedAt` wins, a tie keeps the first.
    static func reducedByID(_ logs: [IntimacyLog]) -> [IntimacyLog] {
        var order: [UUID] = []
        var chosen: [UUID: IntimacyLog] = [:]
        for log in logs {  // R2: bounded by the batch.
            if let current = chosen[log.id] {
                if log.updatedAt > current.updatedAt { chosen[log.id] = log }
            } else {
                chosen[log.id] = log
                order.append(log.id)
            }
        }
        return order.compactMap { chosen[$0] }
    }

    /// `log` with its note capped at ``maxNoteLength`` characters.
    static func capped(_ log: IntimacyLog) -> IntimacyLog {
        var bounded = log
        bounded.note = String(log.note.prefix(Self.maxNoteLength))
        return bounded
    }
}

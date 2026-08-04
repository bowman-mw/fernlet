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
public struct JournalNarrative: Identifiable, Equatable {
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
/// call from any context that owns its lifetime; it holds no mutable state of its own. After each
/// mutation the persistent-history log is pruned via `PrivatePersistentHistoryPruner` so superseded
/// ciphertext does not linger in the transaction log — best-effort (`try?`) after upserts, but
/// rethrown after deletes.
///
/// Failure modes: seal/open rethrow `ColumnCrypto` (CryptoKit/JSON) errors; a failed upsert save
/// rolls back the in-memory change before rethrowing so the context is left clean.
public final class JournalNarrativeRepository: JournalNarrativeStoring {
    /// The sealed store's view context; every operation is funneled through its `performAndWait`.
    private let context: NSManagedObjectContext
    /// Column sealer bound to the `"journal-narrative"` HKDF label — the label is part of the
    /// at-rest format and must never change.
    private let crypto = ColumnCrypto(label: "journal-narrative")

    /// Creates a repository on a private-store controller's view context.
    ///
    /// - Parameter controller: The sealed store to use; `nil` (the default) means the shared
    ///   on-device `PrivatePersistenceController`. Tests pass an in-memory controller.
    public init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    /// Creates a repository directly on an arbitrary managed-object context (test seam).
    public init(context: NSManagedObjectContext) {
        self.context = context
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
                try context.save()
            } catch {
                if isNew { context.delete(object) } else { context.rollback() }
                throw error
            }
            // Prune history after an upsert so a re-sealed (edited) row leaves no prior ciphertext in
            // the transaction log. Best-effort — a prune failure must not undo the write that succeeded.
            try? PrivatePersistentHistoryPruner.prune(context: context)
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
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            // Prune history so the prior ciphertext for this row is not retained (best-effort).
            try? PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    /// Deletes the row with `id` without decrypting it — no content key needed, so deletion
    /// stays available while the app is locked. The history prune here rethrows (not best-effort):
    /// a delete's promise includes removing the ciphertext from the transaction log.
    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = request(id: id)
            try context.fetch(request).forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    /// Drops every stored journal narrative. Deletes rows WITHOUT decrypting them, so it works while the
    /// app is locked — deletion must stay available even when reading is not. Mirrors
    /// ``WorryNarrativeRepository/deleteAll()``. Not part of ``JournalNarrativeStoring``: the app's
    /// delete-all-data hook constructs the concrete repository to call it.
    public func deleteAll() throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return }
            rows.forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
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
            return try context.fetch(request).compactMap { object in
                // Skip an individual undecryptable row rather than rethrowing, which would
                // make every valid journal narrative for the day disappear because callers
                // wrap this in `try?`. Mirrors Menstrual/Intimacy narrative repositories.
                do {
                    return try decrypt(object, contentKey: contentKey)
                } catch {
                    return nil
                }
            }
        }
    }

    /// All decryptable narratives across `dayKeys` in a single fetch, ascending by `entryDate` —
    /// the batch form used when hydrating several days at once.
    ///
    /// - Returns: `[]` when `contentKey` is `nil` or `dayKeys` is empty; undecryptable rows are skipped.
    public func narratives(forDayKeys dayKeys: [String], contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        guard let contentKey, !dayKeys.isEmpty else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
            request.predicate = NSPredicate(format: "dayKey IN %@", dayKeys)
            request.sortDescriptors = [NSSortDescriptor(key: "entryDate", ascending: true)]
            return try context.fetch(request).compactMap { object in
                // Skip an individual undecryptable row rather than rethrowing (see above).
                do {
                    return try decrypt(object, contentKey: contentKey)
                } catch {
                    return nil
                }
            }
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

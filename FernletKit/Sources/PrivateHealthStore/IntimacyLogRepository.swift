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
public nonisolated struct IntimacyLog: Identifiable, Equatable {
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
/// does not linger in the transaction log.
///
/// A `nonisolated` final class: all Core Data access is serialized through the view context's
/// `performAndWait`, so it is callable from any executor.
public nonisolated final class IntimacyLogRepository {
    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(label: "intimacy-log")

    /// Creates a repository on a sealed-store stack.
    ///
    /// - Parameter controller: The private persistence stack to use; `nil` selects the shared
    ///   `PrivatePersistenceController`.
    public init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    /// Creates a repository on an explicit managed-object context — the seam tests use to run
    /// against an in-memory store.
    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Seals and stores a new log, then prunes persistent history (best-effort).
    ///
    /// - Important: Fails closed — throws `FernletLockError.locked` when `contentKey` is `nil`
    ///   (the private area is locked), so no plaintext row can ever be written.
    public func insert(_ log: IntimacyLog, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "IntimacyLog", into: context)
            object.setValue(log.id, forKey: "id")
            object.setValue(log.dayKey, forKey: "dayKey")
            object.setValue(log.eventDate, forKey: "eventDate")
            object.setValue(try crypto.sealString(log.note, contentKey: contentKey), forKey: "noteCiphertext")
            object.setValue(log.healthKitExternalUUID, forKey: "healthKitExternalUUID")
            object.setValue(log.createdAt, forKey: "createdAt")
            object.setValue(log.updatedAt, forKey: "updatedAt")
            // Save, then prune history so no prior ciphertext transaction lingers for this sealed row (best-effort).
            try PrivatePersistentHistoryPruner.saveAndPrune(context)
        }
    }

    /// Every stored log, newest first, decrypted with `contentKey`.
    ///
    /// - Returns: `[]` when `contentKey` is `nil` (locked). Rows whose ciphertext fails to
    ///   authenticate (wrong key, tampering) are silently skipped rather than failing the fetch.
    public func logs(contentKey: SymmetricKey?) throws -> [IntimacyLog] {
        guard let contentKey else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.sortDescriptors = [NSSortDescriptor(key: "eventDate", ascending: false)]
            return try context.fetch(request).compactMap { object in
                do {
                    return try decryptLog(object, contentKey: contentKey)
                } catch {
                    return nil
                }
            }
        }
    }

    /// Deletes one log by `id` without decrypting it, then prunes persistent history. A missing row
    /// is a silent no-op.
    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            try context.fetch(request).forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    /// Drops every stored log. Deletes rows WITHOUT decrypting them, so it works while the app is locked
    /// and while intimacy tracking is hidden. Mirrors `WorryNarrativeRepository.deleteAll()`.
    public func deleteAll() throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return }
            rows.forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
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
        }
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

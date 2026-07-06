import CoreData
import FernletCrypto
import CryptoKit
import Foundation
import FernletDomainModel
import FernletFoundation
import PrivateStoreCore

/// A Worry Box note: a short worry the user wrote down to "let go" of. Deliberately minimal —
/// id + createdAt (plaintext, for ordering/deletion) and the sealed text.
///
/// PRIVACY POSTURE (deliberate): worries are DEVICE-ONLY. They live exclusively in the sealed
/// local `PrivatePersistenceController` store — never mirrored into `FernletDay`/the synced blob,
/// never fed to `MemoryNote`/`TierTwoMemoryEngine`, and deliberately excluded from every
/// `SealedBackup` payload: "let it go" data shouldn't follow you across devices.
public struct WorryNarrative: Identifiable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var text: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

/// The worry-box store surface the app's `WorryBoxService` depends on. A protocol seam (mirroring
/// `JournalNarrativeStoring`) so the service can be driven by a test double.
public protocol WorryStoring: AnyObject {
    func insert(_ worry: WorryNarrative, contentKey: SymmetricKey?) throws
    func worries(contentKey: SymmetricKey?) throws -> [WorryNarrative]
    func delete(id: UUID) throws
    /// Deletes EVERY worry row without needing a content key (rows are dropped, not decrypted) — the
    /// bulk purge "Reset everything" needs so worries don't survive a full data reset even while the
    /// private lock is closed. See `FernletStore.resetAll` / `WorryBoxService.releaseAll`.
    func deleteAll() throws
    /// Re-seals every row that decrypts under `oldKey` with `newKey` (rows already under another
    /// key are skipped). Used when the user unlocks after writing worries while locked/no-lock —
    /// the same device-key → user-key migration journals perform on activation.
    func reencryptAll(from oldKey: SymmetricKey, to newKey: SymmetricKey) throws
}

/// ColumnCrypto-sealed worry storage in the local-only private store. Mirrors
/// `JournalNarrativeRepository` minus the synced-blob strip/hydration machinery — worries never
/// touch the blob, so none of that is needed here.
public final class WorryNarrativeRepository: WorryStoring {
    private static let entityName = "WorryNarrative"
    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(label: "worry-box")

    public init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    public func insert(_ worry: WorryNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context)
            do {
                object.setValue(worry.id, forKey: "id")
                object.setValue(worry.createdAt, forKey: "createdAt")
                object.setValue(try crypto.sealString(worry.text, contentKey: contentKey), forKey: "textCiphertext")
                try context.save()
            } catch {
                context.delete(object)
                throw error
            }
            // Best-effort history prune so a released (deleted) worry's ciphertext does not
            // linger in the transaction log longer than needed.
            try? PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    /// All worries, newest first. Individual undecryptable rows are skipped rather than failing
    /// the whole read (mirrors the journal/menstrual/intimacy repositories).
    public func worries(contentKey: SymmetricKey?) throws -> [WorryNarrative] {
        guard let contentKey else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            return try context.fetch(request).compactMap { object in
                do {
                    return try decrypt(object, contentKey: contentKey)
                } catch {
                    return nil
                }
            }
        }
    }

    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            try context.fetch(request).forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    public func deleteAll() throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return }
            rows.forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    public func reencryptAll(from oldKey: SymmetricKey, to newKey: SymmetricKey) throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            var mutated = false
            for object in try context.fetch(request) {
                // Only rows sealed under `oldKey` migrate; anything else (already under the new
                // key, or damaged) is left untouched.
                guard let text = try? crypto.openString(object.value(forKey: "textCiphertext") as? Data, contentKey: oldKey) else { continue }
                guard let resealed = try? crypto.sealString(text, contentKey: newKey) else { continue }
                object.setValue(resealed, forKey: "textCiphertext")
                mutated = true
            }
            guard mutated else { return }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            // Prune so the prior (old-key) ciphertext is not retained in history (best-effort).
            try? PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    // MARK: - Private

    private func decrypt(_ object: NSManagedObject, contentKey: SymmetricKey) throws -> WorryNarrative? {
        guard let id = object.value(forKey: "id") as? UUID,
              let createdAt = object.value(forKey: "createdAt") as? Date,
              let text = try crypto.openString(object.value(forKey: "textCiphertext") as? Data, contentKey: contentKey)
        else { return nil }
        return WorryNarrative(id: id, createdAt: createdAt, text: text)
    }
}

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
///
/// `Sendable` (a plain value type of Sendable fields) because the repository seals it inside
/// `NSManagedObjectContext.performAndWait`, whose closure is `@Sendable`.
public struct WorryNarrative: Identifiable, Equatable, Sendable {
    /// Stable identity (plaintext) used to delete a specific worry.
    public var id: UUID
    /// When the worry was written (plaintext); the newest-first sort key for reads.
    public var createdAt: Date
    /// The worry itself — sealed at rest as `textCiphertext` via `ColumnCrypto`.
    public var text: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

/// The worry-box store surface the app's `WorryBoxService` depends on. A protocol seam (mirroring
/// ``JournalNarrativeStoring``) so the service can be driven by a test double.
/// ``WorryNarrativeRepository`` is the production conformer.
///
/// Same key-availability contract as the journal seam: callers pass the content key from
/// `FernletLockService` (or `nil` while locked), writes fail closed with a throw, reads fail
/// closed with `[]`, and the delete methods take no key so worries can be released while locked.
public protocol WorryStoring: AnyObject {
    /// Seals a new worry into the private store. Throws `FernletLockError.locked` when
    /// `contentKey` is `nil`.
    func insert(_ worry: WorryNarrative, contentKey: SymmetricKey?) throws
    /// The newest decryptable worries, newest first, bounded by the conformer's display cap (R3 —
    /// this is a display read, not an export). Returns `[]` when `contentKey` is `nil`; individual
    /// undecryptable rows are skipped, not rethrown.
    func worries(contentKey: SymmetricKey?) throws -> [WorryNarrative]
    /// Deletes the worry with `id` without decrypting it — no content key needed, so "releasing"
    /// a worry works while the app is locked.
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

/// ColumnCrypto-sealed worry storage in the local-only private store — the production
/// ``WorryStoring`` conformer. Mirrors ``JournalNarrativeRepository`` minus the synced-blob
/// strip/hydration machinery — worries never touch the blob, so none of that is needed here.
///
/// Worry text is ChaChaPoly-sealed per row via `ColumnCrypto` (HKDF label `"worry-box"`); only
/// `id` and `createdAt` stay plaintext, for ordering and keyless deletion. Rows are
/// `WorryNarrative` entities in the sealed, never-iCloud `PrivatePersistenceController` store.
/// Unlike the journal repository this one supports a bulk key migration
/// (``reencryptAll(from:to:)``): `WorryBoxService` lets worries be written under a device-local
/// key before any app lock exists, then migrates them to the user's content key on unlock.
///
/// Key handling is fail-closed (writes throw `FernletLockError.locked` without a key, reads
/// return `[]`), and every operation runs synchronously inside
/// `NSManagedObjectContext.performAndWait` — the class is a plain nonisolated `final class` with
/// no mutable state of its own, and therefore `Sendable` (compiler-checked: its stored properties
/// are `let`s of Sendable types — the SDK-`Sendable` `NSManagedObjectContext`, whose access is
/// serialized by its own `performAndWait` queue, and the stateless `ColumnCrypto` value — which
/// is what lets `self` be captured by `performAndWait`'s `@Sendable` closure). Mutations prune the
/// persistent-history log via `PrivatePersistentHistoryPruner` so superseded ciphertext does not
/// linger: best-effort after inserts/re-seals, rethrown after deletes.
public final class WorryNarrativeRepository: WorryStoring, Sendable {
    /// The sealed Core Data entity name backing worry rows.
    private static let entityName = "WorryNarrative"
    /// The sealed store's view context; every operation is funneled through its `performAndWait`.
    private let context: NSManagedObjectContext
    /// Column sealer bound to the `"worry-box"` HKDF label — part of the at-rest format,
    /// isolated from the journal label even under the same content key.
    private let crypto = ColumnCrypto(label: "worry-box")

    /// R3: cap on the display fetch, which decrypts every row it returns. Worry rows grow purely
    /// from repeated user actions and there is no paged alternative here.
    private static let maxDisplayedWorries = 500
    /// R3: page size of the ``reencryptAll(from:to:)`` migration, so the whole table is never
    /// faulted in, re-sealed and saved as one unbounded transaction.
    private static let reencryptPageSize = 200

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

    /// Seals a new worry row (always an insert — worries are write-once, never edited).
    ///
    /// - Important: Throws `FernletLockError.locked` when `contentKey` is `nil`. On a failed
    ///   save the inserted object is removed before rethrowing.
    public func insert(_ worry: WorryNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: Self.entityName, into: context)
            do {
                object.setValue(worry.id, forKey: "id")
                object.setValue(worry.createdAt, forKey: "createdAt")
                object.setValue(try crypto.sealString(worry.text, contentKey: contentKey), forKey: "textCiphertext")
                try context.saveSealed()
            } catch {
                context.delete(object)
                throw error
            }
            // Best-effort history prune so a released (deleted) worry's ciphertext does not
            // linger in the transaction log longer than needed (logged when it fails).
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "Worry.insert")
        }
    }

    /// The newest worries, newest first (capped at ``maxDisplayedWorries``). Individual
    /// undecryptable rows are skipped rather than failing the whole read (mirrors the
    /// journal/menstrual/intimacy repositories).
    public func worries(contentKey: SymmetricKey?) throws -> [WorryNarrative] {
        guard let contentKey else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            // R3: repeated user actions grow this table without bound; take the newest page rather
            // than faulting in and decrypting every worry ever written.
            request.fetchLimit = Self.maxDisplayedWorries
            return decryptRows(try context.fetch(request), contentKey: contentKey)
        }
    }

    /// Decrypts a fetched row set, skipping rows whose sealed column will not open and recording ONE
    /// audit line per fetch (never per row, so a mass failure cannot spam the log).
    private func decryptRows(_ objects: [NSManagedObject], contentKey: SymmetricKey) -> [WorryNarrative] {
        var skipped = 0
        let rows = objects.compactMap { object -> WorryNarrative? in
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
                context: ["entity": "WorryNarrative", "count": "\(skipped)"]
            )
        }
        return rows
    }

    /// Deletes ("releases") the worry with `id` without decrypting it — no content key needed.
    /// The history prune here rethrows (not best-effort): a release's promise includes removing
    /// the ciphertext from the transaction log.
    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            try context.fetch(request).forEach(context.delete)
            try context.saveSealed()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    /// Drops every worry row without decrypting anything, so the full data reset works even while
    /// the private lock is closed (see ``WorryStoring/deleteAll()``). Routes through the shared
    /// `PrivateRowPlumbing.deleteRows` sequence, like every sealed repository's `deleteAll()`.
    public func deleteAll() throws {
        // R7: the Bool says whether rows were actually found and dropped. Nothing to recover here
        // (a store that was already empty is the same end state), but a delete that found rows and
        // a delete that found none are different facts, so the "some were dropped" case is named.
        if try PrivateRowPlumbing.deleteRows(entityName: Self.entityName, in: context) {
            FernletAuditLog.log("worryBox.deleteAll.rowsDropped")
        }
    }

    /// Migrates every row sealed under `oldKey` to `newKey` in one transaction — the device-key →
    /// user-key migration `WorryBoxService` runs on unlock (see ``WorryStoring/reencryptAll(from:to:)``).
    ///
    /// - Important: Rows that do not open under `oldKey` (already migrated, or damaged) are skipped
    ///   as a classification decision. Rows that DO open but cannot be re-sealed are counted and
    ///   audit-logged (`worryBox.reencryptSkipped`) — they stay readable under `oldKey`, so the
    ///   caller must keep it alive until a pass reports none.
    /// - Important: R3 — the walk is PAGED (``reencryptPageSize`` rows per transaction) so an
    ///   unbounded table is never faulted in and saved as one transaction. Each page is atomic (a
    ///   failed save rolls that page back and rethrows); earlier pages stay migrated and the rest
    ///   migrate on the next pass, which is safe because migration is idempotent and per row.
    public func reencryptAll(from oldKey: SymmetricKey, to newKey: SymmetricKey) throws {
        try context.performAndWait {
            // R2: the bound is visible at the loop — `rowCount` is fixed before the walk and every
            // iteration advances `offset` by the rows it just handled.
            let rowCount = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: Self.entityName))
            var offset = 0
            var resealFailures = 0
            var mutatedAnyPage = false
            while offset < rowCount {
                let page = try fetchWorryPage(offset: offset)
                guard !page.isEmpty else { break }
                let outcome = resealPage(page, from: oldKey, to: newKey)
                resealFailures += outcome.failures
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
            if resealFailures > 0 {
                // Recovery: the caller keeps the old key alive — these rows opened under `oldKey` but
                // could not be re-sealed, so they are still readable there and migrate on a later pass.
                FernletAuditLog.log("worryBox.reencryptSkipped", context: ["count": "\(resealFailures)"])
            }
            guard mutatedAnyPage else { return }
            // Prune so the prior (old-key) ciphertext is not retained in history (best-effort).
            PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "Worry.reencryptAll")
        }
    }

    /// One bounded page of worry rows in a stable total order, so successive
    /// ``reencryptAll(from:to:)`` pages neither overlap nor skip rows.
    private func fetchWorryPage(offset: Int) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        request.fetchOffset = offset
        request.fetchLimit = Self.reencryptPageSize
        return try context.fetch(request)
    }

    /// Re-seals every row of `page` that opens under `oldKey`.
    ///
    /// - Returns: Whether anything was mutated, and how many rows opened under `oldKey` but could
    ///   not be re-sealed under `newKey` (the silent data-loss case the caller audit-logs).
    private func resealPage(
        _ page: [NSManagedObject],
        from oldKey: SymmetricKey,
        to newKey: SymmetricKey
    ) -> (mutated: Bool, failures: Int) {
        var mutated = false
        var failures = 0
        for object in page {
            // Only rows sealed under `oldKey` migrate; anything else (already under the new key, or
            // damaged) is left untouched — a classification decision, not a swallowed failure.
            guard let text = try? crypto.openString(object.value(forKey: "textCiphertext") as? Data, contentKey: oldKey) else { continue }
            guard let resealed = try? crypto.sealString(text, contentKey: newKey) else {
                failures += 1
                continue
            }
            object.setValue(resealed, forKey: "textCiphertext")
            mutated = true
        }
        return (mutated, failures)
    }

    // MARK: - Private

    /// Rehydrates one row into a ``WorryNarrative``, opening its sealed text column.
    ///
    /// - Returns: `nil` when a plaintext field is missing; throws when the ciphertext fails to
    ///   open (callers turn that into a skipped row).
    private func decrypt(_ object: NSManagedObject, contentKey: SymmetricKey) throws -> WorryNarrative? {
        guard let id = object.value(forKey: "id") as? UUID,
              let createdAt = object.value(forKey: "createdAt") as? Date,
              let text = try crypto.openString(object.value(forKey: "textCiphertext") as? Data, contentKey: contentKey)
        else { return nil }
        return WorryNarrative(id: id, createdAt: createdAt, text: text)
    }
}

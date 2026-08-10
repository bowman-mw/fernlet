import CoreData
import Foundation
import FernletDomainModel
import FernletFoundation

/// A dedicated non-CloudKit persistent store for sealed (ChaChaPoly-encrypted) entities.
/// Sensitive narrative records live here and are never mirrored to iCloud.
///
/// This is the shared Core Data substrate on the protected side of the S3 privacy wall: the
/// sealed repositories in `PrivateHealthStore` (`MenstrualNarrativeRepository`,
/// `IntimacyLogRepository`) and `PrivateMemoryStore` (`JournalNarrativeRepository`,
/// `WorryNarrativeRepository`) all read and write through its ``container``, and
/// `FernletLockService` calls ``purgeEncryptedEntities()`` during its destructive reset. The
/// walled `AIProviders` and `CloudKitSync` modules have no dependency edge to this module, so no
/// sealed entity is even nameable there.
///
/// Store posture:
/// - Never synced: `cloudKitContainerOptions` is intentionally never set, so the `FernletPrivate`
///   store cannot be mirrored to iCloud.
/// - `FileProtection.complete` on the store file; iOS-backup exclusion follows the user's
///   `localBackupExcludedFromiOSBackup` preference (via the shared `BackupExclusion` helper) so
///   one toggle consistently covers both the synced and sealed stores.
/// - Persistent-history tracking is on; sealed writers pair their saves with
///   ``PrivatePersistentHistoryPruner`` so edited rows do not leave prior ciphertext recoverable
///   from the history tables.
/// - Deletion is a TWO-step contract: ``purgeEncryptedEntities()`` (or the repositories' keyless
///   `deleteAll()`) drops the rows, then ``rebuildStore()`` destroys and re-creates the store file
///   so the `-wal`/freelist residue those rows leave behind goes with it. Both halves are keyless,
///   so a wipe works while the app is locked.
/// - The model is built programmatically (`makeManagedObjectModel()`): plain `NSManagedObject`
///   entities whose text content lives only in `*Ciphertext` binary columns; ids, day keys, and
///   timestamps are plaintext by accepted risk (NEW-4). The column sealing itself happens in the
///   layer-3 repositories under the lock's content key — this module never touches that key.
///
/// Concurrency: this module is nonisolated; ``shared`` is `nonisolated(unsafe)` because
/// `NSPersistentContainer` is not `Sendable` (matching its prior app-target behavior). Failure
/// mode: a store that fails to load logs the error and sets ``didFailToLoad`` instead of
/// crashing.
public final class PrivatePersistenceController {
    /// The process-wide controller for the on-disk sealed store; `nonisolated(unsafe)` because
    /// the container is not `Sendable`.
    nonisolated(unsafe) public static let shared = PrivatePersistenceController()

    /// An in-memory (`/dev/null`-backed) controller for SwiftUI previews and tests.
    @MainActor
    public static let preview = PrivatePersistenceController(inMemory: true)

    /// The local-only container hosting the four sealed entities (`MenstrualNarrative`,
    /// `JournalNarrative`, `IntimacyLog`, `WorryNarrative`).
    public let container: NSPersistentContainer
    /// `true` when the persistent store failed to load; the error is logged and the controller
    /// left running (against an empty container) rather than crashing.
    public private(set) var didFailToLoad = false
    private let inMemory: Bool

    /// Creates the stack and loads the `FernletPrivate` store with complete file protection,
    /// history tracking, lightweight migration, and — for on-disk stores — the user's
    /// backup-exclusion preference applied.
    ///
    /// - Parameters:
    ///   - inMemory: When `true`, backs the store with `/dev/null` for previews and tests. Wins
    ///     over `storeURL` when both are supplied.
    ///   - storeURL: An explicit on-disk location for the `.sqlite` file, overriding the default
    ///     Application Support path. The test seam for the ON-DISK behaviours an in-memory store
    ///     cannot express — chiefly ``rebuildStore()``, whose whole contract is about the sqlite
    ///     file, its `-wal`/`-shm` sidecars, and the `_SUPPORT` blob directory really being
    ///     destroyed and re-created. Production always passes `nil`.
    public init(inMemory: Bool = false, storeURL: URL? = nil) {
        self.inMemory = inMemory
        container = NSPersistentContainer(
            name: "FernletPrivate",
            managedObjectModel: Self.makeManagedObjectModel()
        )
        let storeDesc = container.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
        storeDesc.setOption(FileProtectionType.complete as NSString, forKey: NSPersistentStoreFileProtectionKey)
        storeDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDesc.shouldMigrateStoreAutomatically = true
        storeDesc.shouldInferMappingModelAutomatically = true
        // cloudKitContainerOptions is intentionally never set — this store is always local-only.
        storeDesc.cloudKitContainerOptions = nil
        if inMemory {
            storeDesc.url = URL(fileURLWithPath: "/dev/null")
        } else if let storeURL {
            storeDesc.url = storeURL
        }
        container.persistentStoreDescriptions = [storeDesc]

        container.loadPersistentStores { [self] storeDescription, error in
            if let error {
                print("[Fernlet] PrivatePersistenceController store failed to load: \(error)")
                self.didFailToLoad = true
                return
            }
            // Honor the localBackupExcludedFromiOSBackup preference (default: NOT excluded) for the
            // sealed store too, so one toggle consistently covers BOTH stores. The sealed columns use
            // allowsExternalBinaryDataStorage, so the `_SUPPORT` external-blob dir is included. Reuses
            // the shared BackupExclusion helper so the sealed/synced exclusion paths cannot drift.
            Self.applyBackupExclusion(
                storeURL: storeDescription.url,
                inMemory: inMemory,
                excluded: StoragePreferencesStore.currentPreferences().localBackupExcludedFromiOSBackup
            )
        }
        // Behaviour-identical to `NSMergeByPropertyObjectTrumpMergePolicy`; the typed
        // initializer avoids referencing the non-concurrency-safe CoreData global in this
        // nonisolated module.
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// Re-applies the sealed store's iOS-backup exclusion to the live store at runtime — e.g. when the
    /// user toggles `localBackupExcludedFromiOSBackup`. Without this the sealed store's exclusion would
    /// lag the synced store's until the next launch (the synced store reloads on the toggle; this store
    /// is local-only and never reloads). First-session `-wal`/`-shm`/`_SUPPORT` sidecars that do not yet
    /// exist self-heal on the next launch's idempotent re-apply.
    public func applyBackupExclusion(excluded: Bool) {
        Self.applyBackupExclusion(
            storeURL: container.persistentStoreDescriptions.first?.url,
            inMemory: inMemory,
            excluded: excluded
        )
    }

    /// Excludes (or re-includes) the sealed store file, its `-wal`/`-shm` sidecars, and the
    /// `_SUPPORT` external-binary directory from the iOS backup via the shared `BackupExclusion`
    /// helper. No-op for in-memory stores.
    private static func applyBackupExclusion(storeURL: URL?, inMemory: Bool, excluded: Bool) {
        guard !inMemory, let storeURL else { return }
        BackupExclusion.apply(storeURL: storeURL, excluded: excluded, includeSupportDir: true)
    }

    /// Deletes every row of all four sealed entities, saves, and prunes the persistent history.
    ///
    /// The first destructive step of the lock reset and delete-all-data flows, and deliberately
    /// **keyless** — no `contentKey`, no decrypt — so it works while the app is locked or a
    /// sensitive surface is hidden (deleting data must never require the ability to read it).
    ///
    /// - Important: Row-delete alone is **not** an erasure. SQLite marks the pages free and the
    ///   prune clears the history shadow tables, but neither checkpoints the WAL nor vacuums the
    ///   freelist, so the prior ciphertext can linger in `-wal` frames and freed pages until those
    ///   pages are reused. That residue is class-key-protected (`FileProtection.complete`) and
    ///   key-bound (ChaChaPoly under the lock's content key, on a store that never leaves the
    ///   device) — but it is residue. Callers must follow this with ``rebuildStore()``, which
    ///   physically removes the file the residue lives in; only destroying the content key
    ///   (`FernletLockService.reset()`, and the duress WIPE built on it) is an *instant* honest
    ///   erase of the logical content. The old doc here claimed the rows were "unrecoverable
    ///   afterward — content key owned (and scrubbed) by `FernletLockService`", which conflated
    ///   the reset path (key destroyed) with the delete-everything path, where the lock keychain
    ///   is a documented survivor and the key is only scrubbed from memory.
    public func purgeEncryptedEntities() throws {
        let context = container.viewContext
        try context.performAndWait {
            for entityName in ["MenstrualNarrative", "JournalNarrative", "IntimacyLog", "WorryNarrative"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                try context.fetch(request).forEach(context.delete)
            }
            if context.hasChanges {
                try context.save()
            }
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    // MARK: - Crypto-erasure baseline

    /// Errors thrown by ``rebuildStore()``.
    public enum RebuildError: Error, CustomStringConvertible {
        /// The store description carries no URL, so there is no file to destroy or re-add. Only
        /// reachable if the container was mutated after `init`.
        case noStoreURL

        public var description: String {
            switch self {
            case .noStoreURL:
                return "The sealed store has no file URL — nothing to destroy or re-create."
            }
        }
    }

    /// Destroys the sealed store file and re-creates it empty — the physical half of Fernlet's
    /// crypto-erasure baseline ("Option B", Docs/Plan-Security-Hardening-OpusTrack-2026-08-10.md §6).
    ///
    /// ``purgeEncryptedEntities()`` (and the repositories' keyless `deleteAll()`) remove the ROWS,
    /// but leave the pages they lived on in the `-wal` frames and the freelist until SQLite reuses
    /// them. This removes the file those pages are in: the store is torn off the coordinator,
    /// `destroyPersistentStore(at:ofType:options:)` takes the sqlite plus its `-wal`/`-shm`
    /// sidecars, the `.FernletPrivate_SUPPORT` external-binary directory (where the sealed
    /// `allowsExternalBinaryDataStorage` columns spill blobs over ~100 KB) is deleted outright, and
    /// then an empty store is re-added under the same description — same `FileProtection.complete`,
    /// same history tracking, with the user's backup-exclusion preference re-applied to the new
    /// files.
    ///
    /// - Important: This is **keyless by absolute invariant**. It never calls `contentKey()`,
    ///   never decrypts a column and never re-wraps a key, because every deletion path in Fernlet
    ///   must run while the app is locked and a sensitive surface is hidden. (That is also why the
    ///   rejected alternative — re-minting the content key after the purge — is not the baseline:
    ///   re-wrapping needs the passcode-derived key, which a locked wipe does not have.) Do not
    ///   introduce a decrypt here.
    ///
    /// - Important: Honest limits. This removes the *logical* residue. It cannot promise the
    ///   underlying flash blocks are gone — APFS copy-on-write and wear-levelling may keep them
    ///   until they are overwritten — though those blocks stay under the
    ///   `FileProtection.complete` class key, which is evicted while the device is locked. Only
    ///   destroying the content key is an *instant* honest erase of the logical content: the
    ///   `FernletLockService.reset()` path (and the duress WIPE that reuses this seam) destroys the
    ///   keychain rows AND rebuilds, so it is fully honest; the "delete everything" funnel keeps
    ///   the app-lock key by design, so its honest claim is "no live ciphertext, and the residue is
    ///   class-key-protected and key-bound" — never "crypto-erased".
    ///
    /// Live contexts survive the swap: `container.viewContext` is reset (dropping registered
    /// objects and any unsaved changes) before the store is removed, and the context object itself
    /// is unchanged — so the long-lived repositories that captured it keep working against the
    /// fresh, empty store. In-memory (`/dev/null`) controllers skip the file work and simply
    /// re-add, which is already an empty store.
    ///
    /// - Throws: ``RebuildError/noStoreURL``, the `destroyPersistentStore` error, or the
    ///   re-add error. A throw is the caller's nothing-silent signal that the sealed store could
    ///   not be rebuilt; the rows deleted before it are still gone either way, which is why
    ///   row-delete runs first.
    public func rebuildStore() throws {
        let coordinator = container.persistentStoreCoordinator
        guard let description = container.persistentStoreDescriptions.first,
              let storeURL = description.url else {
            throw RebuildError.noStoreURL
        }

        // Drop every live managed object first: after the store is removed they would be faults
        // pointing at a store that no longer exists.
        let context = container.viewContext
        context.performAndWait { context.reset() }

        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }

        // The destroy failure is CAPTURED, not thrown from here: the store is already off the
        // coordinator, so bailing now would leave the app with no sealed store at all until the
        // next launch. Re-add first, report second.
        var destroyFailure: (any Error)?
        if !inMemory {
            do {
                try coordinator.destroyPersistentStore(at: storeURL, ofType: description.type, options: description.options)
                // Belt and braces, on the success path only: `destroyPersistentStore` is documented
                // to remove the store, but has been seen to leave a zero-byte sqlite (or a sidecar)
                // behind. Anything still on disk here is the residue this method exists to remove.
                // Best-effort — a stale sidecar the fresh store overwrites is not worth failing an
                // otherwise-complete wipe over. (Skipped when the destroy FAILED: hand-deleting the
                // file there would quietly succeed at the rebuild while still reporting failure.)
                let fileManager = FileManager.default
                for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] {
                    try? fileManager.removeItem(atPath: path)
                }
                // The external-blob directory is NOT covered by `destroyPersistentStore` — sealed
                // columns over ~100 KB (a long journal entry, a big symptom payload) live in there
                // as standalone ciphertext files that would otherwise outlive the store that named
                // them.
                try? fileManager.removeItem(at: Self.externalBlobDirectory(for: storeURL))
            } catch {
                destroyFailure = error
            }
        }

        do {
            var options: [String: Any] = description.options
            options[NSMigratePersistentStoresAutomaticallyOption] = true
            options[NSInferMappingModelAutomaticallyOption] = true
            _ = try coordinator.addPersistentStore(
                ofType: description.type,
                configurationName: description.configuration,
                at: storeURL,
                options: options
            )
        } catch {
            didFailToLoad = true
            // The destroy failure, if there was one, is the root cause worth surfacing.
            throw destroyFailure ?? error
        }
        didFailToLoad = false
        Self.applyBackupExclusion(
            storeURL: storeURL,
            inMemory: inMemory,
            excluded: StoragePreferencesStore.currentPreferences().localBackupExcludedFromiOSBackup
        )
        // Nothing-silent: the store is usable again, but the old file — and the residue in it —
        // could not be destroyed, and the caller promised the user otherwise.
        if let destroyFailure { throw destroyFailure }
    }

    /// The sibling `.<StoreName>_SUPPORT` directory Core Data spills
    /// `allowsExternalBinaryDataStorage` blobs into — the same path `BackupExclusion` flags, kept
    /// in one spelling so the exclusion and the rebuild cannot drift onto different directories.
    static func externalBlobDirectory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent(".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT", isDirectory: true)
    }

    // MARK: - Model

    /// Builds the programmatic managed-object model containing the four sealed entities.
    static func makeManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = [makeMenstrualNarrativeEntity(), makeJournalNarrativeEntity(), makeIntimacyLogEntity(), makeWorryNarrativeEntity()]
        return model
    }

    /// The sealed period-narrative entity: plaintext id / HealthKit UUID / day key plus
    /// ciphertext note, symptom-flag, and symptom-scale columns, indexed by `dateKey`.
    static func makeMenstrualNarrativeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "MenstrualNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("id", type: .UUIDAttributeType),
            CoreDataModelBuilding.makeAttribute("hkExternalUUID", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("dateKey", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("noteCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("symptomFlagsCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("customSymptomScalesCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dateKeyProp = entity.propertiesByName["dateKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "byDateKey", elements: [
                NSFetchIndexElementDescription(property: dateKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    /// The sealed journal entity: plaintext id / day key / tag / dates plus ciphertext text and
    /// emotions columns, indexed by `dayKey`.
    static func makeJournalNarrativeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "JournalNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        // id, dayKey, tag, entryDate, createdAt, updatedAt are stored plaintext (accepted risk, NEW-4).
        // This store is local-only (never iCloud-synced), so exposure is limited to local forensic
        // analysis ("which days have entries"). All text content lives in sealed ciphertext columns.
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("id", type: .UUIDAttributeType),
            CoreDataModelBuilding.makeAttribute("dayKey", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("tag", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("entryDate", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("textCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("emotionsCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dayKeyProp = entity.propertiesByName["dayKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "byDayKey", elements: [
                NSFetchIndexElementDescription(property: dayKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    /// The sealed intimacy-log entity: plaintext id / day key / event date / HealthKit UUID plus
    /// a ciphertext note column, indexed by `dayKey`.
    static func makeIntimacyLogEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "IntimacyLog"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        // Dates are plaintext so the calendar can be indexed. Free-form details are always sealed.
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("id", type: .UUIDAttributeType),
            CoreDataModelBuilding.makeAttribute("dayKey", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("eventDate", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("noteCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            CoreDataModelBuilding.makeAttribute("healthKitExternalUUID", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dayKeyProp = entity.propertiesByName["dayKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "intimacyByDayKey", elements: [
                NSFetchIndexElementDescription(property: dayKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    /// The sealed, device-only Worry Box entity: plaintext id / createdAt plus a single
    /// ciphertext text column.
    static func makeWorryNarrativeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "WorryNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        // Worry Box notes are deliberately DEVICE-ONLY: sealed in this local store, never mirrored into
        // FernletDay/the synced blob, and deliberately NOT part of any SealedBackup payload — "let it go"
        // data shouldn't follow you across devices. Model kept minimal: plaintext id/createdAt for
        // ordering + deletion, all text in the sealed ciphertext column (same NEW-4 posture as journals).
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("id", type: .UUIDAttributeType),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType),
            CoreDataModelBuilding.makeAttribute("textCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true)
        ]
        return entity
    }
}

/// Helpers that clear the sealed store's persistent-history transactions after sealed writes.
///
/// History tracking is enabled on the `FernletPrivate` store, so every save leaves a copy of the
/// changed rows — including prior ciphertext — in the history shadow tables. The sealed
/// repositories in `PrivateHealthStore` and `PrivateMemoryStore` call ``saveAndPrune(_:)`` (or
/// ``prune(context:before:)`` after their own do/catch saves) so edits and deletes do not linger
/// as recoverable transactions, and ``PrivatePersistenceController/purgeEncryptedEntities()``
/// prunes after a full wipe. A caseless enum used purely as a namespace.
public enum PrivatePersistentHistoryPruner {
    /// Deletes ALL persistent-history transactions store-wide (across the journal/menstrual/intimacy
    /// entities), not just the caller's. It only clears the history shadow tables — it does NOT
    /// checkpoint the WAL or vacuum freed pages, so prior ciphertext can linger in `-wal` frames or
    /// the freelist until those pages are reused. That residue is ChaChaPoly ciphertext under a
    /// ThisDeviceOnly key on a local-only `FileProtection.complete` store — never plaintext, never
    /// cloud-synced — so it is class-key-protected and key-bound, but it is still residue: pruning
    /// is write-hygiene, not erasure. The only thing that removes it is
    /// ``PrivatePersistenceController/rebuildStore()``, which destroys the file it lives in (and,
    /// on the paths that also destroy the content key, `FernletLockService.reset()`, which makes
    /// the residue instantly meaningless as well).
    public static func prune(context: NSManagedObjectContext, before date: Date = Date()) throws {
        let request = NSPersistentHistoryChangeRequest.deleteHistory(before: date)
        try context.execute(request)
    }

    /// Saves the context, then best-effort prunes the persistent history so a re-sealed (edited) row
    /// leaves no prior ciphertext in the transaction log. A prune failure must not undo the write that
    /// succeeded, so the prune is `try?`. Use this at the simple sealed-write sites where the save is
    /// unconditional; sites that need rollback-on-failure must keep `save()` inside their own do/catch.
    public static func saveAndPrune(_ context: NSManagedObjectContext) throws {
        try context.save()
        try? prune(context: context)
    }
}

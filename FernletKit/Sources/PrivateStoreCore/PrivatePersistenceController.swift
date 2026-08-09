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
    /// - Parameter inMemory: When `true`, backs the store with `/dev/null` for previews and tests.
    public init(inMemory: Bool = false) {
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
    /// The destructive half of the lock reset and delete-all-data flows. The ciphertext rows are
    /// unrecoverable afterward — their content key is owned (and scrubbed) by `FernletLockService`.
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
    /// cloud-synced.
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

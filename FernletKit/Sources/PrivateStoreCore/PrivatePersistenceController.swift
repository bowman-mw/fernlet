import CoreData
import Foundation
import FernletDomainModel
import FernletFoundation

/// A dedicated non-CloudKit persistent store for sealed (ChaChaPoly-encrypted) entities.
/// Sensitive narrative records live here and are never mirrored to iCloud.
public final class PrivatePersistenceController {
    nonisolated(unsafe) public static let shared = PrivatePersistenceController()

    @MainActor
    public static let preview = PrivatePersistenceController(inMemory: true)

    public let container: NSPersistentContainer
    public private(set) var didFailToLoad = false
    private let inMemory: Bool

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

    public func purgeEncryptedEntities() throws {
        let context = container.viewContext
        try context.performAndWait {
            for entityName in ["MenstrualNarrative", "JournalNarrative", "IntimacyLog"] {
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

    static func makeManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = [makeMenstrualNarrativeEntity(), makeJournalNarrativeEntity(), makeIntimacyLogEntity()]
        return model
    }

    static func makeMenstrualNarrativeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "MenstrualNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            makeAttribute("id", type: .UUIDAttributeType),
            makeAttribute("hkExternalUUID", type: .stringAttributeType),
            makeAttribute("dateKey", type: .stringAttributeType),
            makeAttribute("noteCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            makeAttribute("symptomFlagsCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            makeAttribute("customSymptomScalesCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            makeAttribute("createdAt", type: .dateAttributeType),
            makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dateKeyProp = entity.propertiesByName["dateKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "byDateKey", elements: [
                NSFetchIndexElementDescription(property: dateKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    static func makeJournalNarrativeEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "JournalNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        // id, dayKey, tag, entryDate, createdAt, updatedAt are stored plaintext (accepted risk, NEW-4).
        // This store is local-only (never iCloud-synced), so exposure is limited to local forensic
        // analysis ("which days have entries"). All text content lives in sealed ciphertext columns.
        entity.properties = [
            makeAttribute("id", type: .UUIDAttributeType),
            makeAttribute("dayKey", type: .stringAttributeType),
            makeAttribute("tag", type: .stringAttributeType),
            makeAttribute("entryDate", type: .dateAttributeType),
            makeAttribute("textCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            makeAttribute("emotionsCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            makeAttribute("createdAt", type: .dateAttributeType),
            makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dayKeyProp = entity.propertiesByName["dayKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "byDayKey", elements: [
                NSFetchIndexElementDescription(property: dayKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    static func makeIntimacyLogEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "IntimacyLog"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        // Dates are plaintext so the calendar can be indexed. Free-form details are always sealed.
        entity.properties = [
            makeAttribute("id", type: .UUIDAttributeType),
            makeAttribute("dayKey", type: .stringAttributeType),
            makeAttribute("eventDate", type: .dateAttributeType),
            makeAttribute("noteCiphertext", type: .binaryDataAttributeType, allowsExternalBinaryDataStorage: true),
            makeAttribute("healthKitExternalUUID", type: .stringAttributeType),
            makeAttribute("createdAt", type: .dateAttributeType),
            makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        if let dayKeyProp = entity.propertiesByName["dayKey"] {
            entity.indexes = [NSFetchIndexDescription(name: "intimacyByDayKey", elements: [
                NSFetchIndexElementDescription(property: dayKeyProp, collationType: .binary)
            ])]
        }
        return entity
    }

    private static func makeAttribute(
        _ name: String,
        type: NSAttributeType,
        defaultValue: Any? = nil,
        allowsExternalBinaryDataStorage: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        attribute.defaultValue = defaultValue
        attribute.allowsExternalBinaryDataStorage = allowsExternalBinaryDataStorage
        return attribute
    }
}

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

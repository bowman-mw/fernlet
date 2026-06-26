import CoreData
import Foundation

/// A dedicated non-CloudKit persistent store for sealed (ChaChaPoly-encrypted) entities.
/// Sensitive narrative records live here and are never mirrored to iCloud.
final class PrivatePersistenceController {
    static let shared = PrivatePersistenceController()

    @MainActor
    static let preview = PrivatePersistenceController(inMemory: true)

    let container: NSPersistentContainer
    private(set) var didFailToLoad = false

    init(inMemory: Bool = false) {
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

        container.loadPersistentStores { [self] _, error in
            if let error {
                print("[Fernlet] PrivatePersistenceController store failed to load: \(error)")
                self.didFailToLoad = true
            }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    func purgeEncryptedEntities() throws {
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

enum PrivatePersistentHistoryPruner {
    static func prune(context: NSManagedObjectContext, before date: Date = Date()) throws {
        let request = NSPersistentHistoryChangeRequest.deleteHistory(before: date)
        try context.execute(request)
    }
}

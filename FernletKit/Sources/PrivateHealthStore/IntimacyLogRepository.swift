import CoreData
import FernletCrypto
import FernletFoundation
import CryptoKit
import Foundation
import FernletDomainModel
import PrivateStoreCore

public nonisolated struct IntimacyLog: Identifiable, Equatable {
    public var id: UUID
    public var dayKey: String
    public var eventDate: Date
    public var note: String
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

public nonisolated final class IntimacyLogRepository {
    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(label: "intimacy-log")

    public init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

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

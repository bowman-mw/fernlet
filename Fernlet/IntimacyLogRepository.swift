import CoreData
import FernletCrypto
import FernletFoundation
import CryptoKit
import Foundation
import FernletDomainModel
import PrivateStoreCore

struct IntimacyLog: Identifiable, Equatable {
    var id: UUID
    var dayKey: String
    var eventDate: Date
    var note: String
    var healthKitExternalUUID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
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

    init(
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

final class IntimacyLogRepository {
    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(label: "intimacy-log")

    init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func insert(_ log: IntimacyLog, contentKey: SymmetricKey?) throws {
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
            try context.save()
        }
    }

    func logs(contentKey: SymmetricKey?) throws -> [IntimacyLog] {
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

    func delete(id: UUID) throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            try context.fetch(request).forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    func markSavedToHealthKit(id: UUID, externalUUID: UUID) throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "IntimacyLog")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard let object = try context.fetch(request).first else { return }
            object.setValue(externalUUID.uuidString, forKey: "healthKitExternalUUID")
            object.setValue(Date(), forKey: "updatedAt")
            try context.save()
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

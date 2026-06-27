import CoreData
import FernletCrypto
import CryptoKit
import Foundation
import FernletDomainModel
import FernletFoundation
import PrivateStoreCore

public struct JournalNarrative: Identifiable, Equatable {
    public var id: UUID
    public var dayKey: String
    public var tag: FeelingTag
    public var entryDate: Date
    public var text: String
    public var emotions: [String]
    public var createdAt: Date
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

public final class JournalNarrativeRepository {
    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(label: "journal-narrative")

    public init(controller: PrivatePersistenceController? = nil) {
        self.context = (controller ?? .shared).container.viewContext
    }

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

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
        }
    }

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
        }
    }

    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = request(id: id)
            try context.fetch(request).forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

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

    private func request(id: UUID) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return request
    }

}

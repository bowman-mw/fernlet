import CoreData
import CryptoKit
import Foundation

struct JournalNarrative: Identifiable, Equatable {
    var id: UUID
    var dayKey: String
    var tag: FeelingTag
    var entryDate: Date
    var text: String
    var emotions: [String]
    var createdAt: Date
    var updatedAt: Date
}

final class JournalNarrativeRepository {
    private let context: NSManagedObjectContext

    init(controller: PrivatePersistenceController = .shared) {
        self.context = controller.container.viewContext
    }

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func insert(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        let object = NSEntityDescription.insertNewObject(forEntityName: "JournalNarrative", into: context)
        try apply(narrative, to: object, contentKey: contentKey, createdAt: narrative.createdAt)
        try context.save()
    }

    func update(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        let request = request(id: narrative.id)
        guard let object = try context.fetch(request).first else { return }
        let createdAt = object.value(forKey: "createdAt") as? Date ?? narrative.createdAt
        try apply(narrative, to: object, contentKey: contentKey, createdAt: createdAt)
        try context.save()
    }

    func delete(id: UUID) throws {
        let request = request(id: id)
        try context.fetch(request).forEach(context.delete)
        try context.save()
    }

    func narratives(forDayKey dayKey: String, contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        guard let contentKey else { return [] }
        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
        request.predicate = NSPredicate(format: "dayKey == %@", dayKey)
        request.sortDescriptors = [NSSortDescriptor(key: "entryDate", ascending: true)]
        return try context.fetch(request).compactMap { try decrypt($0, contentKey: contentKey) }
    }

    func narratives(forDayKeys dayKeys: [String], contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        guard let contentKey, !dayKeys.isEmpty else { return [] }
        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
        request.predicate = NSPredicate(format: "dayKey IN %@", dayKeys)
        request.sortDescriptors = [NSSortDescriptor(key: "entryDate", ascending: true)]
        return try context.fetch(request).compactMap { try decrypt($0, contentKey: contentKey) }
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
        object.setValue(try encryptString(narrative.text, contentKey: contentKey), forKey: "textCiphertext")
        object.setValue(try encrypt(narrative.emotions, contentKey: contentKey), forKey: "emotionsCiphertext")
        object.setValue(createdAt, forKey: "createdAt")
        object.setValue(Date(), forKey: "updatedAt")
    }

    private func decrypt(_ object: NSManagedObject, contentKey: SymmetricKey) throws -> JournalNarrative? {
        guard let id = object.value(forKey: "id") as? UUID,
              let dayKey = object.value(forKey: "dayKey") as? String,
              let tagRaw = object.value(forKey: "tag") as? String,
              let tag = FeelingTag(rawValue: tagRaw),
              let entryDate = object.value(forKey: "entryDate") as? Date else { return nil }
        let text = try decryptString(object.value(forKey: "textCiphertext") as? Data, contentKey: contentKey) ?? ""
        let emotions: [String] = try decryptValue(object.value(forKey: "emotionsCiphertext") as? Data, contentKey: contentKey) ?? []
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

    private func encryptString(_ value: String, contentKey: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(Data(value.utf8), using: columnKey(from: contentKey)).combined
    }

    private func decryptString(_ data: Data?, contentKey: SymmetricKey) throws -> String? {
        guard let data else { return nil }
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: columnKey(from: contentKey))
        return String(data: plaintext, encoding: .utf8)
    }

    private func encrypt<T: Encodable>(_ value: T, contentKey: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(value)
        return try ChaChaPoly.seal(plaintext, using: columnKey(from: contentKey)).combined
    }

    private func decryptValue<T: Decodable>(_ data: Data?, contentKey: SymmetricKey) throws -> T? {
        guard let data else { return nil }
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: columnKey(from: contentKey))
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    private func columnKey(from contentKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: contentKey, info: Data("journal-narrative".utf8), outputByteCount: 32)
    }
}

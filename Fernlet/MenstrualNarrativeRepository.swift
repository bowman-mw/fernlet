import CoreData
import CryptoKit
import Foundation

struct MenstrualNarrative: Identifiable, Equatable {
    var id: UUID
    var hkExternalUUID: String
    var dateKey: String
    var note: String?
    var symptomFlags: [PeriodSymptom]
    var customSymptomScales: [String: Int]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        hkExternalUUID: String,
        dateKey: String,
        note: String? = nil,
        symptomFlags: [PeriodSymptom] = [],
        customSymptomScales: [String: Int] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.hkExternalUUID = hkExternalUUID
        self.dateKey = dateKey
        self.note = note
        self.symptomFlags = symptomFlags
        self.customSymptomScales = customSymptomScales
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

final class MenstrualNarrativeRepository {
    private let context: NSManagedObjectContext

    init(controller: PersistenceController = .shared) {
        self.context = controller.container.viewContext
    }

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func insert(_ narrative: MenstrualNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        let object = NSEntityDescription.insertNewObject(forEntityName: "MenstrualNarrative", into: context)
        try apply(narrative, to: object, contentKey: contentKey, createdAt: narrative.createdAt)
        try context.save()
    }

    func update(_ narrative: MenstrualNarrative, contentKey: SymmetricKey?) throws {
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

    func narratives(in dateRange: DateInterval, contentKey: SymmetricKey?) throws -> [MenstrualNarrative] {
        guard let contentKey else { return [] }
        let keys = Self.dateKeys(in: dateRange)
        guard !keys.isEmpty else { return [] }
        let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
        request.predicate = NSPredicate(format: "dateKey IN %@", keys)
        request.sortDescriptors = [NSSortDescriptor(key: "dateKey", ascending: true)]
        return try context.fetch(request).compactMap { try decrypt($0, contentKey: contentKey) }
    }

    func narrative(forHKUUID hkExternalUUID: String, contentKey: SymmetricKey?) throws -> MenstrualNarrative? {
        guard let contentKey else { return nil }
        let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "hkExternalUUID == %@", hkExternalUUID)
        guard let object = try context.fetch(request).first else { return nil }
        return try decrypt(object, contentKey: contentKey)
    }

    private func apply(_ narrative: MenstrualNarrative, to object: NSManagedObject, contentKey: SymmetricKey, createdAt: Date) throws {
        object.setValue(narrative.id, forKey: "id")
        object.setValue(narrative.hkExternalUUID, forKey: "hkExternalUUID")
        object.setValue(narrative.dateKey, forKey: "dateKey")
        object.setValue(try encryptOptionalString(narrative.note, contentKey: contentKey), forKey: "noteCiphertext")
        object.setValue(try encrypt(narrative.symptomFlags.map(\.rawValue), contentKey: contentKey), forKey: "symptomFlagsCiphertext")
        object.setValue(try encrypt(narrative.customSymptomScales, contentKey: contentKey), forKey: "customSymptomScalesCiphertext")
        object.setValue(createdAt, forKey: "createdAt")
        object.setValue(Date(), forKey: "updatedAt")
    }

    private func decrypt(_ object: NSManagedObject, contentKey: SymmetricKey) throws -> MenstrualNarrative? {
        guard let id = object.value(forKey: "id") as? UUID,
              let hkExternalUUID = object.value(forKey: "hkExternalUUID") as? String,
              let dateKey = object.value(forKey: "dateKey") as? String else { return nil }
        let symptomRaw: [String] = try decrypt((object.value(forKey: "symptomFlagsCiphertext") as? Data), contentKey: contentKey) ?? []
        let scales: [String: Int] = try decrypt((object.value(forKey: "customSymptomScalesCiphertext") as? Data), contentKey: contentKey) ?? [:]
        return MenstrualNarrative(
            id: id,
            hkExternalUUID: hkExternalUUID,
            dateKey: dateKey,
            note: try decryptString(object.value(forKey: "noteCiphertext") as? Data, contentKey: contentKey),
            symptomFlags: symptomRaw.compactMap(PeriodSymptom.init(rawValue:)),
            customSymptomScales: scales,
            createdAt: object.value(forKey: "createdAt") as? Date ?? Date(),
            updatedAt: object.value(forKey: "updatedAt") as? Date ?? Date()
        )
    }

    private func request(id: UUID) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return request
    }

    private func encryptOptionalString(_ value: String?, contentKey: SymmetricKey) throws -> Data? {
        guard let value, !value.isEmpty else { return nil }
        return try ChaChaPoly.seal(Data(value.utf8), using: columnKey(from: contentKey)).combined
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

    private func decrypt<T: Decodable>(_ data: Data?, contentKey: SymmetricKey) throws -> T? {
        guard let data else { return nil }
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: columnKey(from: contentKey))
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    private func columnKey(from contentKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: contentKey, info: Data("menstrual-narrative".utf8), outputByteCount: 32)
    }

    private static func dateKeys(in interval: DateInterval) -> [String] {
        var keys: [String] = []
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: interval.start)
        let end = calendar.startOfDay(for: interval.end)
        while day <= end {
            keys.append(FernletDate.dayKey(for: day))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return keys
    }
}

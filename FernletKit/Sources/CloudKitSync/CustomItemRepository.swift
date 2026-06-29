// CustomItemRepository.swift
// CloudKitSync
//
// Per-row Core Data + iCloud store for user-designed custom items, separate from the snapshot blob so a
// growing closet never bloats the character/day state and items sync row by row. Mirrors
// `SavedRecipeRepository`. Each item is stored as a JSON `payloadData` blob keyed by its UUID.

import Foundation
import CoreData
import FernletDomainModel
import FernletFoundation
import FernletPersistence

public struct CustomItemRepository: CustomItemRepositoring {
    private let controller: PersistenceController

    public init() {
        self.init(controller: .shared)
    }

    public init(controller: PersistenceController) {
        self.controller = controller
    }

    public func load() -> [CustomizationItem] {
        StartupTiming.timed("CustomItemRepository.load") { loadRecords() }
    }

    public func loadAsync() async -> [CustomizationItem] {
        StartupTiming.timed("CustomItemRepository.loadAsync") { loadRecords() }
    }

    private func loadRecords() -> [CustomizationItem] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "CustomItemRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? context.fetch(request) else {
            assertionFailure("custom item fetch failed")
            return []
        }
        return records.compactMap(Self.item(from:))
    }

    @discardableResult public func save(_ items: [CustomizationItem]) -> Bool {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "CustomItemRecord")
        do {
            let existing = try context.fetch(request)
            var existingByID: [String: NSManagedObject] = [:]
            for record in existing {
                if let idString = record.value(forKey: "idString") as? String {
                    existingByID[idString] = record
                }
            }
            let incomingIDs = Set(items.map { $0.id.uuidString })
            for (idString, record) in existingByID where !incomingIDs.contains(idString) {
                context.delete(record)
            }
            let encoder = JSONEncoder()
            for item in items {
                guard let payload = try? encoder.encode(item) else {
                    assertionFailure("custom item encode failed")
                    continue
                }
                let record = existingByID[item.id.uuidString]
                    ?? NSEntityDescription.insertNewObject(forEntityName: "CustomItemRecord", into: context)
                record.setValue(item.id.uuidString, forKey: "idString")
                record.setValue(payload, forKey: "payloadData")
                record.setValue(item.createdAt, forKey: "createdAt")
            }
            if context.hasChanges {
                try context.save()
            }
            return true
        } catch {
            assertionFailure("custom item Core Data save failed")
            context.rollback()
            return false
        }
    }

    private static func item(from record: NSManagedObject) -> CustomizationItem? {
        guard let data = record.value(forKey: "payloadData") as? Data else { return nil }
        return try? JSONDecoder().decode(CustomizationItem.self, from: data)
    }
}

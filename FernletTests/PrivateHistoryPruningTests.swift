import CoreData
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
@testable import PrivateStoreCore
import PrivateHealthStore
import PrivateMemoryStore
@testable import Fernlet

struct PrivateHistoryPruningTests {
    @Test func menstrualDeletionPrunesWithoutLeavingRecord() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let repository = MenstrualNarrativeRepository(context: context)
        let contentKey = SymmetricKey(size: .bits256)
        let narrative = MenstrualNarrative(
            hkExternalUUID: UUID().uuidString,
            dateKey: "2026-06-01",
            note: "private"
        )

        try repository.insert(narrative, contentKey: contentKey)
        try repository.delete(id: narrative.id)

        let deletedNarrative = try repository.narrative(forHKUUID: narrative.hkExternalUUID, contentKey: contentKey)
        #expect(deletedNarrative?.id == nil)
    }

    @Test func intimacyDeletionPrunesWithoutLeavingRecord() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let repository = IntimacyLogRepository(context: context)
        let contentKey = SymmetricKey(size: .bits256)
        let log = IntimacyLog(eventDate: Date(), note: "private")

        try repository.insert(log, contentKey: contentKey)
        try repository.delete(id: log.id)

        #expect(try repository.logs(contentKey: contentKey).isEmpty)
    }

    /// An edit (re-seal) must not leave the prior ciphertext in the persistent-history transaction log.
    /// Uses a REAL on-disk store: the `/dev/null` in-memory store does not durably record persistent
    /// history, which would make the `== 0` assertion vacuous (it would pass even with the prune removed).
    /// The control write at the end proves this store DOES record history, so the assertion discriminates.
    @Test func journalInsertAndUpdatePruneHistoryOnDisk() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let container = NSPersistentContainer(
            name: "FernletPrivate",
            managedObjectModel: PrivatePersistenceController.makeManagedObjectModel()
        )
        let desc = try #require(container.persistentStoreDescriptions.first)
        desc.url = tempDir.appendingPathComponent("FernletPrivate.sqlite")
        desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        try #require(loadError == nil)
        let context = container.viewContext
        defer {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }

        func historyCount() throws -> Int {
            try context.performAndWait {
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
                let result = try context.execute(request) as? NSPersistentHistoryResult
                return (result?.result as? [NSPersistentHistoryTransaction])?.count ?? 0
            }
        }

        let repository = JournalNarrativeRepository(context: context)
        let contentKey = SymmetricKey(size: .bits256)
        var narrative = JournalNarrative(
            id: UUID(), dayKey: "2026-06-01", tag: .hard, entryDate: Date(),
            text: "first draft", emotions: [], createdAt: Date(), updatedAt: Date()
        )
        try repository.insert(narrative, contentKey: contentKey)
        narrative.text = "edited"
        try repository.update(narrative, contentKey: contentKey)

        // The repo prunes after each write → no transactions remain.
        #expect(try historyCount() == 0)

        // Control: a raw save that does NOT prune leaves a transaction behind, proving the store records
        // history (so the `== 0` above is a real assertion that would fail if the prune were removed).
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "JournalNarrative", into: context)
            object.setValue(UUID(), forKey: "id")
            object.setValue("2026-06-02", forKey: "dayKey")
            object.setValue("good", forKey: "tag")
            object.setValue(Date(), forKey: "entryDate")
            object.setValue(Date(), forKey: "createdAt")
            object.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
        #expect(try historyCount() > 0)
    }
}

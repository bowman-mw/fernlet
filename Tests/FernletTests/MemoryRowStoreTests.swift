import Testing
import CoreData
import Foundation
@testable import CloudKitSync
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import LocalPersistence

/// G9-3 (owner call M1 = A): Core memories as their own `MemoryRecord` rows with soft delete
/// (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md, Part 3). A forget writes a content-free
/// tombstone row, so another phone's stale write of the memory cannot bring it back: reads hide and heal
/// the id, upserts skip it, and `CoreDataFernletRepository` only soft-deletes ids it has served or
/// written, so a stale snapshot never deletes a row another phone added after this phone's last load.
@MainActor
@Suite(.serialized)
struct MemoryRowStoreTests {
    private let stamp = Date(timeIntervalSince1970: 1_780_000_000)
    private let todayKey = "2026-11-15"

    // MARK: - MemoryRecordRepository

    @Test func upsertThenLoadOrdersBySourceDate() {
        let repo = MemoryRecordRepository(controller: PersistenceController(inMemory: true))
        let later = memory("later", daysAfter: 2)
        let earlier = memory("earlier", daysAfter: 0)
        #expect(repo.upsert([later, earlier]))
        #expect(repo.load().map(\.text) == ["earlier", "later"])
    }

    @Test func forgetLeavesOnlyAContentFreeTombstone() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = MemoryRecordRepository(controller: controller)
        let doomed = memory("About my sister")
        let kept = memory("Kept")
        #expect(repo.upsert([doomed, kept]))

        #expect(repo.delete(ids: [doomed.id]))

        #expect(repo.load().map(\.id) == [kept.id])
        let rows = try allRows(in: controller)
        let tombstone = try #require(rows.first { $0.idString == RowTombstones.tombstoneIDString(for: doomed.id) })
        let payload = try #require(tombstone.payload)
        #expect(!String(decoding: payload, as: UTF8.self).contains("sister"))
        #expect(!rows.contains { $0.idString == doomed.id.uuidString })
    }

    @Test func aStaleWriteFromAnotherPhoneIsHiddenAndHealed() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = MemoryRecordRepository(controller: controller)
        let note = memory("Forgotten")
        #expect(repo.upsert([note]))
        #expect(repo.delete(ids: [note.id]))

        try insertLiveRow(note, in: controller)   // the other phone, not yet aware of the forget

        #expect(repo.load().isEmpty)
        #expect(try allRows(in: controller).map(\.idString) == [RowTombstones.tombstoneIDString(for: note.id)])
    }

    @Test func upsertSkipsAForgottenID() {
        let repo = MemoryRecordRepository(controller: PersistenceController(inMemory: true))
        let note = memory("Gone")
        let fresh = memory("Fresh")
        #expect(repo.upsert([note]))
        #expect(repo.delete(ids: [note.id]))
        #expect(repo.upsert([note, fresh]))
        #expect(repo.load().map(\.id) == [fresh.id])
    }

    @Test func adoptMissingNeverOverwritesNorRevives() {
        let repo = MemoryRecordRepository(controller: PersistenceController(inMemory: true))
        let edited = memory("Edited on the other phone")
        let forgotten = memory("Forgotten")
        let new = memory("New")
        #expect(repo.upsert([edited, forgotten]))
        #expect(repo.delete(ids: [forgotten.id]))

        var staleCopy = edited
        staleCopy.text = "Old words"
        #expect(repo.adoptMissing([staleCopy, forgotten, new]))

        #expect(Set(repo.load().map(\.text)) == ["Edited on the other phone", "New"])
    }

    @Test func deleteAllTakesTheTombstonesToo() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = MemoryRecordRepository(controller: controller)
        let note = memory("One")
        #expect(repo.upsert([note, memory("Two")]))
        #expect(repo.delete(ids: [note.id]))
        #expect(repo.deleteAll())
        #expect(try allRows(in: controller).isEmpty)
    }

    // MARK: - CoreDataFernletRepository

    @Test func aSnapshotsMemoriesLiveInRowsAndTheBlobIsWrittenEmpty() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = makeRepository(controller)
        let note = memory("Walks matter")
        #expect(repository.saveSnapshot(snapshot(memories: [note])))

        #expect(try blobMemoryCount(controller) == 0)
        #expect(MemoryRecordRepository(controller: controller).load().map(\.id) == [note.id])
        repository.invalidateCache()
        #expect(repository.loadSnapshot(todayKey: todayKey).memories.map(\.id) == [note.id])
    }

    @Test func removingAMemoryFromTheSnapshotSoftDeletesIt() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = makeRepository(controller)
        let doomed = memory("Doomed")
        let kept = memory("Kept")
        #expect(repository.saveSnapshot(snapshot(memories: [doomed, kept])))

        #expect(repository.saveSnapshot(snapshot(memories: [kept])))

        let rows = try allRows(in: controller)
        #expect(rows.contains { $0.idString == RowTombstones.tombstoneIDString(for: doomed.id) })
        #expect(MemoryRecordRepository(controller: controller).load().map(\.id) == [kept.id])
    }

    @Test func aStaleSnapshotNeverDeletesARowItNeverSaw() {
        let controller = PersistenceController(inMemory: true)
        let repository = makeRepository(controller)
        let mine = memory("Mine")
        #expect(repository.saveSnapshot(snapshot(memories: [mine])))
        _ = repository.loadSnapshot(todayKey: todayKey)

        // Another phone adds a memory after this phone's load.
        let remote = memory("From the iPad")
        #expect(MemoryRecordRepository(controller: controller).upsert([remote]))

        // This phone saves its (stale) list, which does not hold the iPad's memory.
        #expect(repository.saveSnapshot(snapshot(memories: [mine])))

        #expect(Set(MemoryRecordRepository(controller: controller).load().map(\.id)) == [mine.id, remote.id])
    }

    @Test func anUnchangedMemoryIsNotRewritten() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = makeRepository(controller)
        let note = memory("Steady")
        #expect(repository.saveSnapshot(snapshot(memories: [note])))
        let firstStamp = try rowStamp(for: note.id, in: controller)

        #expect(repository.saveSnapshot(snapshot(memories: [note])))

        #expect(try rowStamp(for: note.id, in: controller) == firstStamp)
    }

    @Test func purgeWipesMemoryRowsAndTombstones() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = makeRepository(controller)
        let doomed = memory("Doomed")
        #expect(repository.saveSnapshot(snapshot(memories: [doomed, memory("Kept")])))
        #expect(repository.saveSnapshot(snapshot(memories: [])))

        #expect(repository.purgeAllPersistedData())

        #expect(try allRows(in: controller).isEmpty)
    }

    // MARK: - Helpers

    private func memory(_ text: String, daysAfter: Int = 0) -> MemoryNote {
        MemoryNote(category: "note", text: text, sourceDate: stamp.addingTimeInterval(Double(daysAfter) * 86_400))
    }

    private func makeRepository(_ controller: PersistenceController) -> CoreDataFernletRepository {
        CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoryRowStore-\(UUID().uuidString)").appendingPathExtension("json"))
        )
    }

    private func snapshot(memories: [MemoryNote]) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: todayKey, day: FernletDay(date: todayKey, bottleCount: 1), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: memories, goals: [], workshop: WorkshopData()
        )
    }

    private func insertLiveRow(_ note: MemoryNote, in controller: PersistenceController) throws {
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "MemoryRecord", into: context)
        record.setValue(note.id.uuidString, forKey: "idString")
        record.setValue(try RowPayloadCoders.makeEncoder().encode(note), forKey: "payloadData")
        record.setValue(stamp, forKey: "updatedAt")
        try context.save()
    }

    private func allRows(in controller: PersistenceController) throws -> [(idString: String?, payload: Data?)] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MemoryRecord")
        return try controller.container.viewContext.fetch(request).map {
            ($0.value(forKey: "idString") as? String, $0.value(forKey: "payloadData") as? Data)
        }
    }

    private func rowStamp(for id: UUID, in controller: PersistenceController) throws -> Date? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MemoryRecord")
        request.predicate = NSPredicate(format: "idString == %@", id.uuidString)
        return try controller.container.viewContext.fetch(request).first?.value(forKey: "updatedAt") as? Date
    }

    private func blobMemoryCount(_ controller: PersistenceController) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        let record = try #require(try controller.container.viewContext.fetch(request).first)
        let payload = try #require(record.value(forKey: "payloadData") as? Data)
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return (object["memories"] as? [Any])?.count ?? 0
    }
}

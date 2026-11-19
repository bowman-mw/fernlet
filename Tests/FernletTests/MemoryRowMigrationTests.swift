import Testing
import CoreData
import Foundation
@testable import CloudKitSync
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import LocalPersistence

/// G9-3 one-time (and every-time) move of Core memories out of the aggregate blob into `MemoryRecord`
/// rows: copy first, empty the blob only after the rows saved, and run it whenever a loaded blob still
/// holds memories, so an older build that wrote its list back is moved too, without overwriting a row
/// or reviving a forgotten memory.
@MainActor
@Suite(.serialized)
struct MemoryRowMigrationTests {
    private let stamp = Date(timeIntervalSince1970: 1_780_000_000)
    private let todayKey = "2026-11-15"

    @Test func blobMemoriesMoveIntoRowsAndTheBlobEmpties() throws {
        let controller = PersistenceController(inMemory: true)
        let notes = [memory("First", day: 0), memory("Second", day: 1)]
        try seedBlob(memories: notes, in: controller)

        let loaded = makeRepository(controller).loadSnapshot(todayKey: todayKey)

        #expect(loaded.memories.map(\.id) == notes.map(\.id))
        #expect(MemoryRecordRepository(controller: controller).load().map(\.id) == notes.map(\.id))
        #expect(try blobMemoryCount(controller) == 0)
    }

    @Test func legacyJSONMemoriesMoveIntoRowsOnFirstLaunch() throws {
        let controller = PersistenceController(inMemory: true)
        let legacyURL = temporaryURL("legacy")
        let legacy = LocalFernletRepository(fileURL: legacyURL)
        let note = memory("From the local file", day: 0)
        #expect(legacy.saveSnapshot(FernletSnapshot(
            todayKey: todayKey, day: FernletDay(date: todayKey, bottleCount: 1), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: [note], goals: [], workshop: WorkshopData()
        )))

        let repository = CoreDataFernletRepository(controller: controller,
                                                   legacyRepository: LocalFernletRepository(fileURL: legacyURL))
        #expect(repository.loadSnapshot(todayKey: todayKey).memories.map(\.id) == [note.id])
        #expect(MemoryRecordRepository(controller: controller).load().map(\.id) == [note.id])
        #expect(try blobMemoryCount(controller) == 0)
    }

    @Test func anOldBuildRewritingTheBlobIsMovedWithoutOverwritingOrReviving() throws {
        let controller = PersistenceController(inMemory: true)
        let kept = memory("Kept, as edited here", day: 0)
        let forgotten = memory("Forgotten here", day: 1)
        let rows = MemoryRecordRepository(controller: controller)
        #expect(rows.upsert([kept, forgotten]))
        #expect(rows.delete(ids: [forgotten.id]))

        // An older build, which still keeps memories in the blob, writes back its own list.
        var staleKept = kept
        staleKept.text = "Old words"
        let addedThere = memory("Added on the old build", day: 2)
        try seedBlob(memories: [staleKept, forgotten, addedThere], in: controller)

        let loaded = makeRepository(controller).loadSnapshot(todayKey: todayKey)

        #expect(loaded.memories.map(\.text) == ["Kept, as edited here", "Added on the old build"])
        #expect(try blobMemoryCount(controller) == 0)
    }

    @Test func aFailedRowCopyKeepsTheBlobAndStillServesTheMemories() throws {
        let controller = PersistenceController(inMemory: true)
        let notes = [memory("Must not vanish", day: 0)]
        try seedBlob(memories: notes, in: controller)
        let failing = FailingMemoryRepository()

        let repository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryURL("failing")),
            memoryRepository: failing
        )
        let loaded = repository.loadSnapshot(todayKey: todayKey)

        #expect(loaded.memories.map(\.id) == notes.map(\.id), "a failed copy must never hide a memory")
        #expect(try blobMemoryCount(controller) == 1, "the blob is emptied only after the rows saved")
        #expect(repository.saveSnapshot(FernletSnapshot(
            todayKey: todayKey, day: FernletDay(date: todayKey, bottleCount: 1), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: loaded.memories, goals: [], workshop: WorkshopData()
        )) == false, "a save whose memory rows fail is not durable, and leaves the blob as it was")
        #expect(try blobMemoryCount(controller) == 1)
    }

    /// Release review 2026-11-18 (F2): a failed read used to come back as an empty list. The
    /// repository soft-deletes every id it has served that a saved snapshot no longer holds, so a
    /// snapshot loaded while the rows were unreadable, then saved, tombstoned every memory for good.
    @Test func aSnapshotLoadedWhileTheRowsWereUnreadableNeverForgetsThem() throws {
        let controller = PersistenceController(inMemory: true)
        let notes = [memory("First", day: 0), memory("Second", day: 1)]
        let rows = MemoryRecordRepository(controller: controller)
        #expect(rows.upsert(notes))
        let flaky = FlakyReadMemoryRepository(rows)
        let repository = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: temporaryURL("flaky")),
            memoryRepository: flaky
        )
        #expect(repository.loadSnapshot(todayKey: todayKey).memories.map(\.id) == notes.map(\.id))

        flaky.readsFail = true
        let blind = repository.loadSnapshot(todayKey: todayKey)
        #expect(blind.memories.isEmpty)
        #expect(repository.saveSnapshot(blind))
        flaky.readsFail = false

        #expect(rows.load().map(\.id) == notes.map(\.id), "an unreadable store is not a forget")
        #expect(repository.loadSnapshot(todayKey: todayKey).memories.map(\.id) == notes.map(\.id))

        // Once the rows read again, leaving one out of a saved snapshot is a forget, as before.
        var trimmed = repository.loadSnapshot(todayKey: todayKey)
        trimmed.memories.removeAll { $0.id == notes[0].id }
        #expect(repository.saveSnapshot(trimmed))
        #expect(rows.load().map(\.id) == [notes[1].id])
    }

    @Test func anUnreadableStoreIsNotAnEmptyOne() throws {
        let controller = PersistenceController(inMemory: true)
        let rows = MemoryRecordRepository(controller: controller)
        #expect(rows.loadIfReadable() == [])
        #expect(rows.upsert([memory("Here", day: 0)]))
        #expect(rows.loadIfReadable()?.count == 1)

        // No store behind the coordinator: every fetch throws, as on a locked or unloadable store.
        let coordinator = controller.container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }
        #expect(rows.loadIfReadable() == nil)
        #expect(rows.load().isEmpty)
    }

    // MARK: - Helpers

    /// The real row store, with reads that can be made to fail (a locked or unavailable store).
    @MainActor
    private final class FlakyReadMemoryRepository: MemoryRepositoring {
        private let rows: MemoryRecordRepository
        var readsFail = false

        init(_ rows: MemoryRecordRepository) { self.rows = rows }

        func load() -> [MemoryNote] { loadIfReadable() ?? [] }
        func loadIfReadable() -> [MemoryNote]? { readsFail ? nil : rows.loadIfReadable() }
        func upsert(_ memories: [MemoryNote]) -> Bool { rows.upsert(memories) }
        func adoptMissing(_ memories: [MemoryNote]) -> Bool { rows.adoptMissing(memories) }
        func delete(ids: [UUID]) -> Bool { rows.delete(ids: ids) }
        func deleteAll() -> Bool { rows.deleteAll() }
    }

    /// A memory store whose every write fails (a locked or full store).
    @MainActor
    private final class FailingMemoryRepository: MemoryRepositoring {
        func load() -> [MemoryNote] { [] }
        func upsert(_ memories: [MemoryNote]) -> Bool { memories.isEmpty }
        func adoptMissing(_ memories: [MemoryNote]) -> Bool { false }
        func delete(ids: [UUID]) -> Bool { ids.isEmpty }
        func deleteAll() -> Bool { true }
    }

    private func memory(_ text: String, day: Int) -> MemoryNote {
        MemoryNote(category: "note", text: text, sourceDate: stamp.addingTimeInterval(Double(day) * 86_400))
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRowMigration-\(name)-\(UUID().uuidString)").appendingPathExtension("json")
    }

    private func makeRepository(_ controller: PersistenceController) -> CoreDataFernletRepository {
        CoreDataFernletRepository(controller: controller,
                                  legacyRepository: LocalFernletRepository(fileURL: temporaryURL("legacy")))
    }

    /// Writes an aggregate record holding `memories`, below the repository: what a pre-G9-3 build (or
    /// this build before the move) left in the mirrored blob.
    private func seedBlob(memories: [MemoryNote], in controller: PersistenceController) throws {
        var database = LocalFernletDatabase()
        database.memories = memories
        database.daysMigratedToRows = true
        let payload = try RowPayloadCoders.makeEncoder().encode(database)
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        let record = try context.fetch(request).first
            ?? NSEntityDescription.insertNewObject(forEntityName: "FernletDatabaseRecord", into: context)
        record.setValue("primary", forKey: "recordID")
        record.setValue(payload, forKey: "payloadData")
        record.setValue(Date(), forKey: "updatedAt")
        try context.save()
    }

    private func blobMemoryCount(_ controller: PersistenceController) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        let record = try #require(try controller.container.viewContext.fetch(request).first)
        let payload = try #require(record.value(forKey: "payloadData") as? Data)
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return (object["memories"] as? [Any])?.count ?? 0
    }
}

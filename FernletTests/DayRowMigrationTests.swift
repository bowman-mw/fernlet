import Testing
import CoreData
import Foundation
import CloudKitSync
import LocalPersistence
import FernletDomainModel
import FernletPersistence

@MainActor
@Suite(.serialized)
struct DayRowMigrationTests {
    @Test func migratesBlobDaysIntoRowsAndReadsFromThem() {
        let controller = PersistenceController(inMemory: true)
        var blob = LocalFernletDatabase()
        blob.days = [
            "2026-05-01": FernletDay(date: "2026-05-01", bottleCount: 1),
            "2026-05-02": FernletDay(date: "2026-05-02", bottleCount: 2),
            "2026-05-03": FernletDay(date: "2026-05-03", bottleCount: 3)
        ]
        blob.daysMigratedToRows = false
        seedAggregateBlob(blob, in: controller)

        let dayRepo = DayRecordRepository(controller: controller)
        #expect(dayRepo.loadAll().isEmpty)  // no rows before first load

        let repo = CoreDataFernletRepository(controller: controller)
        let days = repo.loadAllDays()  // triggers the blob→rows fan-out
        #expect(Set(days.keys) == ["2026-05-01", "2026-05-02", "2026-05-03"])
        #expect(dayRepo.loadAll()["2026-05-02"]?.bottleCount == 2)
    }

    @Test func migrationIsIdempotentAcrossReloads() {
        let controller = PersistenceController(inMemory: true)
        var blob = LocalFernletDatabase()
        blob.days = ["2026-05-01": FernletDay(date: "2026-05-01", bottleCount: 1)]
        seedAggregateBlob(blob, in: controller)

        let repo = CoreDataFernletRepository(controller: controller)
        _ = repo.loadAllDays()
        repo.invalidateCache()      // force a fresh decode + migration check
        _ = repo.loadAllDays()
        // A second migration pass must not duplicate the row.
        #expect(rawRowCount("DayRecord", in: controller) == 1)
    }

    @Test func migrationResumesAfterAFailedBatch() {
        let controller = PersistenceController(inMemory: true)
        var blob = LocalFernletDatabase()
        blob.days = ["2026-05-01": FernletDay(date: "2026-05-01", bottleCount: 1)]
        blob.daysMigratedToRows = false
        seedAggregateBlob(blob, in: controller)

        let flaky = FlakyDayRepo(failNextUpsert: true)
        let repo = CoreDataFernletRepository(controller: controller, dayRecordRepository: flaky)
        _ = repo.loadAllDays()            // first attempt: the upsert fails, flag stays false
        #expect(flaky.store.isEmpty)

        let days = repo.loadAllDays()     // retried on the next load because the flag never flipped
        #expect(Set(days.keys) == ["2026-05-01"])
    }

    // MARK: - Helpers

    private func seedAggregateBlob(_ database: LocalFernletDatabase, in controller: PersistenceController) {
        let context = controller.container.viewContext
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let record = NSEntityDescription.insertNewObject(forEntityName: "FernletDatabaseRecord", into: context)
        record.setValue("primary", forKey: "recordID")
        record.setValue(try? encoder.encode(database), forKey: "payloadData")
        record.setValue(Date(), forKey: "updatedAt")
        try? context.save()
    }

    private func rawRowCount(_ entity: String, in controller: PersistenceController) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        return (try? controller.container.viewContext.fetch(request).count) ?? -1
    }
}

/// An in-memory day repo whose first upsert fails, to exercise the resume-after-failure migration path.
@MainActor
private final class FlakyDayRepo: DayRecordRepositoring {
    var store: [String: FernletDay] = [:]
    private var failNextUpsert: Bool
    init(failNextUpsert: Bool) { self.failNextUpsert = failNextUpsert }

    func loadAll() -> [String: FernletDay] { store }
    func load(dateKeys: [String]) -> [String: FernletDay] { store.filter { dateKeys.contains($0.key) } }
    func loadRecent(limit: Int) -> [FernletDay] {
        Array(store.values.sorted { $0.date > $1.date }.prefix(limit))
    }
    @discardableResult func upsert(_ days: [DayRecordUpsert]) -> Bool {
        if failNextUpsert { failNextUpsert = false; return false }
        for entry in days { store[entry.dateKey] = entry.day }
        return true
    }
    @discardableResult func delete(dateKeys: [String]) -> Bool { dateKeys.forEach { store[$0] = nil }; return true }
    @discardableResult func deleteAll() -> Bool { store.removeAll(); return true }
}

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

        let flaky = FlakyDayRepo(failOnUpsertCall: 1)
        let repo = CoreDataFernletRepository(controller: controller, dayRecordRepository: flaky)
        _ = repo.loadAllDays()            // first attempt: the upsert fails, flag stays false
        #expect(flaky.store.isEmpty)

        let days = repo.loadAllDays()     // retried on the next load because the flag never flipped
        #expect(Set(days.keys) == ["2026-05-01"])
    }

    @Test func migratesHistorySpanningMultipleBatches() {
        let controller = PersistenceController(inMemory: true)
        var blob = LocalFernletDatabase()
        for i in 0..<600 {  // > 2 full 250-day batches
            let key = String(format: "2020-%05d", i)
            blob.days[key] = FernletDay(date: key)
        }
        seedAggregateBlob(blob, in: controller)

        let repo = CoreDataFernletRepository(controller: controller)
        #expect(repo.loadAllDays().count >= 600)  // every batch landed
    }

    @Test func resumesWhenASecondBatchFailsThenCompletes() {
        let controller = PersistenceController(inMemory: true)
        var blob = LocalFernletDatabase()
        for i in 0..<600 {
            let key = String(format: "2020-%05d", i)
            blob.days[key] = FernletDay(date: key)
        }
        blob.daysMigratedToRows = false
        seedAggregateBlob(blob, in: controller)

        let flaky = FlakyDayRepo(failOnUpsertCall: 2)  // batch 1 lands, batch 2 fails → flag stays false
        let repo = CoreDataFernletRepository(controller: controller, dayRecordRepository: flaky)
        _ = repo.loadAllDays()
        #expect(flaky.store.count == 250)        // only the first batch persisted

        let days = repo.loadAllDays()            // retry re-runs all batches; upsert is idempotent per key
        #expect(days.count == 600)
    }

    @Test func migrationClearsBlobDaysAndSeedsSummary() {
        let controller = PersistenceController(inMemory: true)
        var blob = LocalFernletDatabase()
        blob.days = [
            "2026-05-01": FernletDay(date: "2026-05-01", bottleCount: 2),
            "2026-05-02": FernletDay(date: "2026-05-02", sleep: SleepLog(hours: 7, quality: .good, note: "x"))
        ]
        seedAggregateBlob(blob, in: controller)

        let repo = CoreDataFernletRepository(controller: controller)
        #expect(repo.loadAllDays().count == 2)  // both days landed as rows

        // Stage B: the blob's days are retired and a precomputed summary carries the counts.
        let reloaded = readBlob(controller)
        #expect(reloaded?.days.isEmpty == true)
        #expect(reloaded?.daysMigratedToRows == true)
        #expect(reloaded?.dayContentSummary.hydrationCount == 1)  // 2026-05-01 has bottleCount > 0
        #expect(reloaded?.dayContentSummary.sleepCount == 1)      // 2026-05-02 has a sleep log
    }

    // MARK: - Helpers

    private func readBlob(_ controller: PersistenceController) -> LocalFernletDatabase? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        guard let record = try? controller.container.viewContext.fetch(request).first,
              let payload = record.value(forKey: "payloadData") as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalFernletDatabase.self, from: payload)
    }

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

/// An in-memory day repo that fails a chosen upsert call, to exercise the resume-after-failure migration
/// path (including a mid-run failure across multiple 250-day batches).
@MainActor
private final class FlakyDayRepo: DayRecordRepositoring {
    var store: [String: FernletDay] = [:]
    private(set) var upsertCalls = 0
    private let failOnCall: Int?  // 1-indexed upsert call to fail; nil = never fail
    init(failOnUpsertCall: Int? = nil) { self.failOnCall = failOnUpsertCall }

    func loadAll() -> [String: FernletDay] { store }
    func load(dateKeys: [String]) -> [String: FernletDay] { store.filter { dateKeys.contains($0.key) } }
    func loadRecent(limit: Int) -> [FernletDay] {
        Array(store.values.sorted { $0.date > $1.date }.prefix(limit))
    }
    @discardableResult func upsert(_ days: [DayRecordUpsert]) -> Bool {
        upsertCalls += 1
        if upsertCalls == failOnCall { return false }
        for entry in days { store[entry.dateKey] = entry.day }
        return true
    }
    @discardableResult func delete(dateKeys: [String]) -> Bool { dateKeys.forEach { store[$0] = nil }; return true }
    @discardableResult func deleteAll() -> Bool { store.removeAll(); return true }
}

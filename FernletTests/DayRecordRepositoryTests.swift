import Testing
import CoreData
import Foundation
import CloudKitSync
import FernletDomainModel
import FernletPersistence

@MainActor
@Suite(.serialized)
struct DayRecordRepositoryTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func upsertAndLoadAllRoundTrips() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        repo.upsert([
            DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 3), updatedAt: stamp),
            DayRecordUpsert(day: FernletDay(date: "2026-05-02", bottleCount: 5), updatedAt: stamp)
        ])
        let days = repo.loadAll()
        #expect(days.count == 2)
        #expect(days["2026-05-01"]?.bottleCount == 3)
        #expect(days["2026-05-02"]?.bottleCount == 5)
    }

    @Test func upsertNeverDeletesUnlistedDays() {
        // The core invariant (like CoinLedger/CustomItem upsert): writing one day must not delete days
        // already in the store — so a stale set on one device can't wipe days synced from another.
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 1), updatedAt: stamp)])
        repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-02", bottleCount: 2), updatedAt: stamp)])
        let days = repo.loadAll()
        #expect(days.count == 2)
        #expect(days["2026-05-01"]?.bottleCount == 1)
    }

    @Test func upsertReplacesSameDateKeyInPlace() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 1), updatedAt: stamp)])
        repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 9), updatedAt: stamp)])
        let days = repo.loadAll()
        #expect(days.count == 1)
        #expect(days["2026-05-01"]?.bottleCount == 9)
    }

    @Test func loadCollapsesDuplicateRowsKeepingNewestAndSelfHeals() {
        // CloudKit can mirror two rows for one dateKey (it keys by record identity, not the attribute).
        // Insert two raw rows directly, then loadAll must keep the newer and delete the loser.
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        insertRawDayRow(in: context, dateKey: "2026-05-01", bottleCount: 1, updatedAt: stamp)
        insertRawDayRow(in: context, dateKey: "2026-05-01", bottleCount: 7, updatedAt: stamp.addingTimeInterval(60))
        try? context.save()

        let repo = DayRecordRepository(controller: controller)
        let days = repo.loadAll()
        #expect(days.count == 1)
        #expect(days["2026-05-01"]?.bottleCount == 7)  // newer updatedAt wins

        // Self-heal: the losing duplicate row is deleted, so a raw count is now 1.
        #expect(rawRowCount(in: context) == 1)
    }

    @Test func loadByDateKeysReturnsOnlyRequested() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for (i, key) in ["2026-05-01", "2026-05-02", "2026-05-03"].enumerated() {
            repo.upsert([DayRecordUpsert(day: FernletDay(date: key, bottleCount: i), updatedAt: stamp)])
        }
        let subset = repo.load(dateKeys: ["2026-05-01", "2026-05-03"])
        #expect(Set(subset.keys) == ["2026-05-01", "2026-05-03"])
    }

    @Test func loadRecentReturnsNewestWithinLimit() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for day in 1...10 {
            let key = String(format: "2026-05-%02d", day)
            repo.upsert([DayRecordUpsert(day: FernletDay(date: key), updatedAt: stamp)])
        }
        let recent = repo.loadRecent(limit: 3)
        #expect(recent.map(\.date) == ["2026-05-10", "2026-05-09", "2026-05-08"])
    }

    @Test func deleteRemovesOnlyListedDays() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for key in ["2026-05-01", "2026-05-02", "2026-05-03"] {
            repo.upsert([DayRecordUpsert(day: FernletDay(date: key), updatedAt: stamp)])
        }
        repo.delete(dateKeys: ["2026-05-02"])
        #expect(Set(repo.loadAll().keys) == ["2026-05-01", "2026-05-03"])
    }

    // MARK: - Raw-row helpers (white-box, to simulate CloudKit-mirrored duplicates)

    private func insertRawDayRow(in context: NSManagedObjectContext, dateKey: String, bottleCount: Int, updatedAt: Date) {
        let record = NSEntityDescription.insertNewObject(forEntityName: "DayRecord", into: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try? encoder.encode(FernletDay(date: dateKey, bottleCount: bottleCount))
        record.setValue(dateKey, forKey: "dateKey")
        record.setValue(payload, forKey: "payloadData")
        record.setValue(updatedAt, forKey: "updatedAt")
    }

    private func rawRowCount(in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        return (try? context.fetch(request).count) ?? -1
    }
}

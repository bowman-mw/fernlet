import Testing
import CoreData
import Foundation
import CloudKitSync
import LocalPersistence
import FernletDomainModel
import FernletPersistence
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct HealthKitCacheCleanerTests {
    /// Opting out of HealthKit must purge cached clinical context from BOTH the per-row DayRecord store and
    /// the aggregate blob's bounded `days` cache (which still syncs to iCloud), while preserving any
    /// user-authored sleep entry. Regression guard for the per-row-split cleaner rewrite.
    @Test func stripsHealthContextFromRowsAndBlobPreservingUserSleep() throws {
        let controller = PersistenceController(inMemory: true)

        // Row A: HealthKit-derived sleep (empty note, hours equal to body.sleepHours) — must be dropped.
        let healthSleepDay = FernletDay(
            date: "2026-05-01",
            sleep: SleepLog(hours: 7.5, quality: .good, note: ""),
            healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 7.5))
        )
        // Row B: a user-authored sleep entry (has a note) — must survive even though healthContext is cleared.
        let userSleepDay = FernletDay(
            date: "2026-05-02",
            sleep: SleepLog(hours: 8, quality: .good, note: "slept in"),
            healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 6))
        )
        let dayRepo = DayRecordRepository(controller: controller)
        dayRepo.upsert([
            DayRecordUpsert(day: healthSleepDay, updatedAt: Date()),
            DayRecordUpsert(day: userSleepDay, updatedAt: Date())
        ])

        // The aggregate blob still carries a bounded-cache day with healthContext — the leak the cleaner closes.
        seedBlobDay(
            FernletDay(date: "2026-05-03", healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 5))),
            in: controller
        )

        try CoreDataHealthKitCacheCleaner(controller: controller).clearHealthKitCachedValues()

        let rows = dayRepo.loadAll()
        #expect(rows["2026-05-01"]?.healthContext == nil)
        #expect(rows["2026-05-01"]?.sleep == nil)               // HealthKit-derived sleep dropped
        #expect(rows["2026-05-02"]?.healthContext == nil)
        #expect(rows["2026-05-02"]?.sleep?.note == "slept in")  // user sleep preserved
        #expect(blobDay("2026-05-03", in: controller)?.healthContext == nil)  // blob stripped too
    }

    private func seedBlobDay(_ day: FernletDay, in controller: PersistenceController) {
        let context = controller.container.viewContext
        var database = LocalFernletDatabase()
        database.days[day.date] = day
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let record = NSEntityDescription.insertNewObject(forEntityName: "FernletDatabaseRecord", into: context)
        record.setValue("primary", forKey: "recordID")
        record.setValue(try? encoder.encode(database), forKey: "payloadData")
        record.setValue(Date(), forKey: "updatedAt")
        try? context.save()
    }

    private func blobDay(_ key: String, in controller: PersistenceController) -> FernletDay? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        guard let record = try? controller.container.viewContext.fetch(request).first,
              let payload = record.value(forKey: "payloadData") as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LocalFernletDatabase.self, from: payload))?.days[key]
    }
}

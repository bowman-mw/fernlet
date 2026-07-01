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

    /// The migrated-store leak (regression guard): once the per-row split clears the blob's `days`, opting
    /// out of HealthKit must still purge the blob's *derived* cache (`dailyLogs` + `dayContentSummary`) by
    /// rebuilding it from the stripped rows. The pre-fix cleaner skipped the rebuild because the blob had no
    /// `days` left to iterate, so stale HealthKit-derived sleep hours kept syncing to iCloud.
    @Test func migratedStoreRebuildsBlobDerivedCacheFromStrippedRows() throws {
        let controller = PersistenceController(inMemory: true)

        // Authoritative row: HealthKit-derived sleep (empty note, hours == body.sleepHours) — dropped on opt-out.
        let healthSleepDay = FernletDay(
            date: "2026-05-01",
            sleep: SleepLog(hours: 7.5, quality: .good, note: ""),
            healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 7.5))
        )
        let dayRepo = DayRecordRepository(controller: controller)
        dayRepo.upsert([DayRecordUpsert(day: healthSleepDay, updatedAt: Date())])

        // Migrated blob: `days` already cleared (Stage B), but its derived cache still carries the HealthKit
        // sleep hours — the stale clinical value that keeps syncing to iCloud after opt-out.
        var database = LocalFernletDatabase()
        database.daysMigratedToRows = true
        database.rebuildDerivedTables(todayKey: "2026-05-01", recentDays: [("2026-05-01", healthSleepDay)])
        database.dayContentSummary = DayContentSummary(days: [healthSleepDay])
        database.days = [:]
        #expect(database.dailyLogs.first?.sleepHours == 7.5)   // precondition: stale clinical value present
        #expect(database.dayContentSummary.sleepCount == 1)
        seedBlob(database, in: controller)

        try CoreDataHealthKitCacheCleaner(controller: controller).clearHealthKitCachedValues()

        #expect(dayRepo.loadAll()["2026-05-01"]?.sleep == nil)   // row's HealthKit sleep dropped
        let blob = blobDatabase(in: controller)
        #expect(blob?.dailyLogs.allSatisfy { $0.sleepHours == nil } == true)  // no clinical sleep left in blob
        #expect(blob?.dayContentSummary.sleepCount == 0)                       // summary no longer counts it
    }

    private func seedBlob(_ database: LocalFernletDatabase, in controller: PersistenceController) {
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

    private func blobDatabase(in controller: PersistenceController) -> LocalFernletDatabase? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        guard let record = try? controller.container.viewContext.fetch(request).first,
              let payload = record.value(forKey: "payloadData") as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalFernletDatabase.self, from: payload)
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

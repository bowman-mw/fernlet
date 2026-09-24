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
    /// Opting out of HealthKit must purge HealthKit values an older build left in BOTH the per-row DayRecord
    /// store and the aggregate blob's bounded `days` cache (which still syncs to iCloud), while preserving
    /// what the user authored. Since 2026-09-23 the shared storage strip decides what is HealthKit's: a day
    /// whose only content was HealthKit's loses its row entirely (no empty rows), and typed sleep survives.
    @Test func stripsHealthContextFromRowsAndBlobPreservingUserSleep() throws {
        let controller = PersistenceController(inMemory: true)

        // Row A: HealthKit-derived sleep (hours equal to body.sleepHours, default rating) — nothing of it is
        // the user's, so the whole row goes.
        let healthSleepDay = FernletDay(
            date: "2026-05-01",
            sleep: SleepLog(hours: 7.5, quality: .ok, note: ""),
            healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 7.5))
        )
        // Row B: a user-authored sleep entry (typed hours differ from HealthKit's) — must survive whole.
        let userSleepDay = FernletDay(
            date: "2026-05-02",
            sleep: SleepLog(hours: 8, quality: .good, note: "slept in"),
            healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 6))
        )
        let dayRepo = DayRecordRepository(controller: controller)
        #expect(dayRepo.upsert([
            DayRecordUpsert(day: healthSleepDay, updatedAt: Date()),
            DayRecordUpsert(day: userSleepDay, updatedAt: Date())
        ]) == true)

        // The aggregate blob still carries a bounded-cache day with healthContext — the leak the cleaner closes.
        seedBlobDay(
            FernletDay(date: "2026-05-03", healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 5))),
            in: controller
        )

        try Self.cleaner(controller).clearHealthKitCachedValues()

        let rows = dayRepo.loadAll()
        #expect(rows["2026-05-01"] == nil)                       // HealthKit-only day: row deleted
        #expect(rows["2026-05-02"]?.healthContext == nil)
        #expect(rows["2026-05-02"]?.sleep?.hours == 8)           // typed hours preserved
        #expect(rows["2026-05-02"]?.sleep?.note == "slept in")  // user sleep preserved
        #expect(blobDay("2026-05-03", in: controller)?.healthContext == nil)  // blob stripped too
    }

    /// HealthKit's hours on a log the user rated or annotated: the pre-2026-09-23 cleaner kept the whole log
    /// (a note made it "user-authored") and with it HealthKit's hours. The shared strip removes just the hours.
    @Test func healthKitHoursGoEvenWhenTheUserAnnotatedTheLog() throws {
        let controller = PersistenceController(inMemory: true)
        let annotated = FernletDay(
            date: "2026-05-04",
            sleep: SleepLog(hours: 7.5, quality: .great, note: "vivid dreams"),
            healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 7.5))
        )
        let dayRepo = DayRecordRepository(controller: controller)
        #expect(dayRepo.upsert([DayRecordUpsert(day: annotated, updatedAt: Date())]))

        try Self.cleaner(controller).clearHealthKitCachedValues()

        let row = dayRepo.loadAll()["2026-05-04"]
        #expect(row?.sleep?.hours == nil)
        #expect(row?.sleep?.quality == .great)
        #expect(row?.sleep?.note == "vivid dreams")
    }

    /// The migrated-store leak (regression guard): once the per-row split clears the blob's `days`, opting
    /// out of HealthKit must still purge the blob's *derived* cache (`dailyLogs` + `dayContentSummary`) by
    /// rebuilding it from the stripped rows. The pre-fix cleaner skipped the rebuild because the blob had no
    /// `days` left to iterate, so stale HealthKit-derived sleep hours kept syncing to iCloud.
    @Test func migratedStoreRebuildsBlobDerivedCacheFromStrippedRows() throws {
        let controller = PersistenceController(inMemory: true)

        // Authoritative row: HealthKit-derived sleep (hours == body.sleepHours) — dropped on opt-out.
        let healthSleepDay = FernletDay(
            date: "2026-05-01",
            sleep: SleepLog(hours: 7.5, quality: .good, note: ""),
            healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 7.5))
        )
        let dayRepo = DayRecordRepository(controller: controller)
        #expect(dayRepo.upsert([DayRecordUpsert(day: healthSleepDay, updatedAt: Date())]) == true)

        // Migrated blob: `days` already cleared (Stage B), but its derived cache still carries the HealthKit
        // sleep hours — the stale clinical value that keeps syncing to iCloud after opt-out.
        var database = LocalFernletDatabase()
        database.daysMigratedToRows = true
        database.rebuildDerivedTables(todayKey: "2026-05-01", recentDays: [("2026-05-01", healthSleepDay)])
        database.dayContentSummary = DayContentSummary(days: [healthSleepDay])
        database.days = [:]
        #expect(database.dailyLogs.first?.sleepHours == 7.5)   // precondition: stale clinical value present
        seedBlob(database, in: controller)

        try Self.cleaner(controller).clearHealthKitCachedValues()

        #expect(dayRepo.loadAll()["2026-05-01"]?.sleep?.hours == nil)   // row's HealthKit sleep hours dropped
        let blob = blobDatabase(in: controller)
        #expect(blob?.dailyLogs.allSatisfy { $0.sleepHours == nil } == true)  // no clinical sleep left in blob
    }

    /// The stored score history rides the same synced blob: its HealthKit scoring contexts go too.
    @Test func optOutStripsHealthKitContextsFromStoredScores() throws {
        let controller = PersistenceController(inMemory: true)
        var database = LocalFernletDatabase()
        var score = DailyHealthScore(dateKey: "2026-05-01", score: 0.6, companionState: .okay, computedAt: Date())
        score.healthActivityContext = HealthActivitySummary(steps: 9_000)
        score.healthBodyContext = HealthBodyContext(restingHeartRateBPM: 55)
        database.dailyScores = [score]
        seedBlob(database, in: controller)

        try Self.cleaner(controller).clearHealthKitCachedValues()

        let stored = blobDatabase(in: controller)?.dailyScores ?? []
        #expect(stored.count == 1)
        #expect(stored.allSatisfy { $0.healthActivityContext == nil && $0.healthBodyContext == nil })
    }

    /// The opt-out empties this device's HealthKit residue cache — the place the readings live now.
    @Test func optOutEmptiesTheDeviceCache() throws {
        let cache = InMemoryDeviceHealthResidueStore()
        let residue = DeviceHealthResidue(context: HealthDailyContext(activity: HealthActivitySummary(steps: 1)),
                                          importedWorkouts: [])
        #expect(cache.record(residue, for: "2026-05-01"))

        try Self.cleaner(PersistenceController(inMemory: true), cache: cache).clearHealthKitCachedValues()

        #expect(cache.allResidues().isEmpty)
    }

    /// Fail-closed: a device cache that will not clear fails the opt-out (retryable) instead of reporting
    /// success over HealthKit readings still on disk.
    @Test func optOutFailsClosedWhenTheDeviceCacheWillNotClear() {
        let cleaner = CoreDataHealthKitCacheCleaner(controller: PersistenceController(inMemory: true),
                                                    residueStore: StuckResidueStore())
        #expect(throws: CoreDataHealthKitCacheCleaner.CacheClearError.self) {
            try cleaner.clearHealthKitCachedValues()
        }
    }

    /// The one-time launch scrub's capture mode: each stripped day's HealthKit values are kept in the device
    /// cache first — without overwriting a reading this device already recorded for that day.
    @Test func scrubCapturesEachDayBeforeStrippingIt() throws {
        let controller = PersistenceController(inMemory: true)
        let legacy = FernletDay(
            date: "2026-05-01",
            bottleCount: 1,
            healthContext: HealthDailyContext(activity: HealthActivitySummary(steps: 7_000))
        )
        let syncedIn = FernletDay(
            date: "2026-05-02",
            bottleCount: 1,
            healthContext: HealthDailyContext(activity: HealthActivitySummary(steps: 111))
        )
        let dayRepo = DayRecordRepository(controller: controller)
        #expect(dayRepo.upsert([DayRecordUpsert(day: legacy, updatedAt: Date()),
                                DayRecordUpsert(day: syncedIn, updatedAt: Date())]))
        let cache = InMemoryDeviceHealthResidueStore()
        let own = DeviceHealthResidue(context: HealthDailyContext(activity: HealthActivitySummary(steps: 9_999)),
                                      importedWorkouts: [])
        #expect(cache.record(own, for: "2026-05-02"))

        try Self.cleaner(controller, cache: cache).scrubSyncedHealthKitValues(capturingInto: cache)

        #expect(dayRepo.loadAll().values.allSatisfy { !$0.carriesHealthKitValues })
        #expect(dayRepo.loadAll().values.allSatisfy { $0.bottleCount == 1 })
        #expect(cache.residue(for: "2026-05-01")?.context?.activity?.steps == 7_000)
        #expect(cache.residue(for: "2026-05-02")?.context?.activity?.steps == 9_999)
    }

    /// Fail-closed regression guard: if any single DayRecord row cannot be decoded (a corrupt row, or a
    /// forward-schema payload written by a newer build on another device and synced in), the scrub MUST throw
    /// rather than silently skip the row. A skipped row keeps its HealthKit-derived `healthContext` in the
    /// CloudKit-synced record while `disableIntegration` would otherwise report a successful opt-out. Because
    /// the throw propagates, `disableIntegration` leaves `healthKitMasterEnabled` ON and the failure is
    /// auditable/retryable.
    @Test func undecodableDayRowFailsClosed() throws {
        let controller = PersistenceController(inMemory: true)

        // A legitimate HealthKit-derived row that WOULD be scrubbed on the happy path.
        let healthSleepDay = FernletDay(
            date: "2026-05-01",
            healthContext: HealthDailyContext(body: HealthBodyContext(sleepHours: 7.5))
        )
        let dayRepo = DayRecordRepository(controller: controller)
        #expect(dayRepo.upsert([DayRecordUpsert(day: healthSleepDay, updatedAt: Date())]) == true)

        // A corrupt / forward-schema DayRecord row: `payloadData` is not a decodable FernletDay.
        seedCorruptDayRow(controller: controller)

        #expect(throws: CoreDataHealthKitCacheCleaner.CacheClearError.self) {
            try Self.cleaner(controller).clearHealthKitCachedValues()
        }
    }

    /// Fail-closed regression guard for the aggregate blob: an undecodable `FernletDatabaseRecord` payload may
    /// still carry HealthKit-derived cache (`dailyLogs`/`dayContentSummary`/an un-migrated `days` map) that
    /// keeps syncing to iCloud, so a decode failure MUST throw rather than leave the blob untouched and report
    /// a successful opt-out.
    @Test func undecodableDatabaseBlobFailsClosed() throws {
        let controller = PersistenceController(inMemory: true)
        seedCorruptBlob(controller: controller)

        #expect(throws: CoreDataHealthKitCacheCleaner.CacheClearError.self) {
            try Self.cleaner(controller).clearHealthKitCachedValues()
        }
    }

    /// A cleaner over `controller` and an in-memory device cache — never the production cache file, which
    /// the cleaner's nil default resolves to.
    private static func cleaner(
        _ controller: PersistenceController,
        cache: InMemoryDeviceHealthResidueStore? = nil
    ) -> CoreDataHealthKitCacheCleaner {
        CoreDataHealthKitCacheCleaner(controller: controller, residueStore: cache ?? InMemoryDeviceHealthResidueStore())
    }

    private func seedCorruptDayRow(controller: PersistenceController) {
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "DayRecord", into: context)
        record.setValue("2026-05-09", forKey: "dateKey")
        record.setValue(Data("not-a-fernlet-day".utf8), forKey: "payloadData")
        record.setValue(Date(), forKey: "updatedAt")
        try? context.save()
    }

    private func seedCorruptBlob(controller: PersistenceController) {
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "FernletDatabaseRecord", into: context)
        record.setValue("primary", forKey: "recordID")
        record.setValue(Data("not-a-database".utf8), forKey: "payloadData")
        record.setValue(Date(), forKey: "updatedAt")
        try? context.save()
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

/// A device cache whose clear never lands — the failure the opt-out must not paper over.
@MainActor
private final class StuckResidueStore: DeviceHealthResidueStoring {
    func residue(for dateKey: String) -> DeviceHealthResidue? { nil }
    func allResidues() -> [String: DeviceHealthResidue] { [:] }
    func record(_ residue: DeviceHealthResidue?, for dateKey: String) -> Bool { true }
    var importedBodyProfile: DeviceHealthBodyProfile? { nil }
    func recordImportedBodyProfile(_ profile: DeviceHealthBodyProfile?) -> Bool { true }
    func clearAll() -> Bool { false }
    var legacySyncedRowsScrubbed: Bool { false }
    func markLegacySyncedRowsScrubbed() -> Bool { true }
}

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

    @Test func migrationKeepsRicherBlobCopyOverSparseExistingRow() {
        // Item D (migration skips a fresher blob edit): a mixed-version fleet can leave a fresher same-day
        // edit ONLY in the shared blob (an old build re-wrote `days` and dropped `daysMigratedToRows`, so
        // this build re-runs migration). If migration skipped that key as "existing", then cleared the blob,
        // the edit would be lost. Migration must instead keep the copy with strictly MORE logged content.
        let controller = PersistenceController(inMemory: true)

        // Pre-seed a SPARSE row for the day (as if a prior partial migration or a stale device wrote it).
        let dayRepo = DayRecordRepository(controller: controller)
        // Empty row.
        #expect(dayRepo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01"), updatedAt: Date())]) == true)

        // The blob holds a RICHER same-day copy (meals + a journal).
        var blob = LocalFernletDatabase()
        blob.days = [
            "2026-05-01": FernletDay(
                date: "2026-05-01",
                meals: [Meal(name: "Eggs", mealType: .breakfast, macros: Macros(protein: 12, carbs: 1, fat: 10), quality: .good, confidence: "t", note: "", source: MealLogSource.manual)],
                journals: [JournalEntry(text: "kept", tag: .good)],
                bottleCount: 2
            )
        ]
        blob.daysMigratedToRows = false
        seedAggregateBlob(blob, in: controller)

        let repo = CoreDataFernletRepository(controller: controller)
        let day = repo.loadAllDays()["2026-05-01"]
        #expect(day?.meals.count == 1)     // the richer blob copy replaced the sparse row
        #expect(day?.journals.count == 1)
        #expect(day?.bottleCount == 2)
    }

    @Test func migrationSkipsBlobCopyThatIsNotRicherThanExistingRow() {
        // Complement to the above: when the existing row is already at least as rich as the blob copy, the
        // row is authoritative (it may be a newer synced-in edit) and must NOT be overwritten with the
        // blob's stale copy — the pure-backfill guard against re-fan clobber.
        let controller = PersistenceController(inMemory: true)
        let dayRepo = DayRecordRepository(controller: controller)
        #expect(dayRepo.upsert([DayRecordUpsert(
            day: FernletDay(date: "2026-05-01", journals: [JournalEntry(text: "newer row edit", tag: .good)], bottleCount: 5),
            updatedAt: Date()
        )]) == true)

        var blob = LocalFernletDatabase()
        blob.days = ["2026-05-01": FernletDay(date: "2026-05-01", bottleCount: 1)]  // sparser
        blob.daysMigratedToRows = false
        seedAggregateBlob(blob, in: controller)

        let repo = CoreDataFernletRepository(controller: controller)
        let day = repo.loadAllDays()["2026-05-01"]
        #expect(day?.journals.count == 1)   // the richer existing row survived
        #expect(day?.bottleCount == 5)      // not overwritten by the blob's bottleCount: 1
    }

    @Test func emptyTodaySaveWritesNoDayRow() {
        // Item G (empty today-row counts as "existing data"): a device that merely launched the app writes a
        // snapshot for a content-free today. That must NOT create a DayRecord row — otherwise every other
        // device reads "existing cloud data" and shows the divergence warning.
        let controller = PersistenceController(inMemory: true)
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let repo = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: legacyURL)
        )
        let today = "2026-05-20"
        let emptySnapshot = FernletSnapshot(
            todayKey: today, day: FernletDay(date: today), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData()
        )
        #expect(repo.saveSnapshot(emptySnapshot))          // succeeds (blob/settings persisted)
        #expect(rawRowCount("DayRecord", in: controller) == 0)  // …but no day row for the empty day

        // A day that HAS content does write a row.
        let withContent = FernletSnapshot(
            todayKey: today, day: FernletDay(date: today, bottleCount: 2), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData()
        )
        #expect(repo.saveSnapshot(withContent))
        #expect(rawRowCount("DayRecord", in: controller) == 1)

        // …and when that day's content is removed again, its row is deleted (not left stale).
        #expect(repo.saveSnapshot(emptySnapshot))
        #expect(rawRowCount("DayRecord", in: controller) == 0)
    }

    @Test func failedDayRowWriteMakesSaveReportFailureForRetry() {
        // Item C (saveSnapshot/updateDay discard the row-upsert result): if the per-row day write fails, the
        // save must report failure so SnapshotSaveCoordinator retries — it must NOT report a durable save
        // (which, post-migration with the blob cleared, would silently lose today's content).
        let controller = PersistenceController(inMemory: true)
        // Hermeticity: the in-memory controller stores at /dev/null, which the serialized suite can leave
        // holding a prior test's blob days. Seed a clean, already-migrated aggregate so `loadDatabase` runs
        // NO migration fan-out — otherwise migrating leaked days through `flaky` would consume the call-#1
        // failure and the day write below would spuriously succeed (call #2).
        var seed = LocalFernletDatabase()
        seed.daysMigratedToRows = true
        seedAggregateBlob(seed, in: controller)
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let flaky = FlakyDayRepo(failOnUpsertCall: 1)  // fail the first (content) upsert
        let repo = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: legacyURL),
            dayRecordRepository: flaky
        )
        let today = "2026-05-21"
        let snapshot = FernletSnapshot(
            todayKey: today, day: FernletDay(date: today, bottleCount: 3), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData()
        )
        #expect(repo.saveSnapshot(snapshot) == false)  // row write failed → save is not durable

        // A retry (the flaky repo only fails call #1) now succeeds and the day lands.
        #expect(repo.saveSnapshot(snapshot))
        #expect(flaky.store["2026-05-21"]?.bottleCount == 3)
    }

    @Test func editingBlobOnlyDayToEmptyDoesNotResurrectItPreMigration() {
        // Item B×G regression: in the failed-migration window (daysMigratedToRows == false, the blob still
        // holds days and is loadDay's fallback, but a batch failure left a day with no row yet), emptying such
        // a blob-only past day writes NO row (item G deletes instead). updateDay must ALSO drop the stale
        // non-empty blob copy — otherwise loadDay's fallback (and the eventual migration) resurrects the
        // pre-edit content, silently undoing the deletion.
        let controller = PersistenceController(inMemory: true)
        var blob = LocalFernletDatabase()
        blob.days = ["2026-05-10": FernletDay(date: "2026-05-10", bottleCount: 4)]  // a blob-only past day
        blob.daysMigratedToRows = false
        seedAggregateBlob(blob, in: controller)

        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        // Migration's fan-out fails, so the day stays blob-only and daysMigratedToRows stays false — the exact
        // window the bug lives in.
        let flaky = FlakyDayRepo(failOnUpsertCall: 1)
        let repo = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: legacyURL),
            dayRecordRepository: flaky
        )

        // The user removes the day's last entry.
        #expect(repo.updateDay(FernletDay(date: "2026-05-10"), for: "2026-05-10", todayKey: "2026-05-21"))

        // It must read back empty — not the stale bottleCount:4 blob copy — and never be resurrected as a row.
        #expect(repo.loadDay(for: "2026-05-10", todayKey: "2026-05-21").hasLoggedContent == false)
        #expect(flaky.store["2026-05-10"] == nil)
    }

    @Test func migrationStripsCycleAndIntimateHealthContextFromRows() {
        // Item E (migration copies legacy PLAINTEXT into synced rows): legacy blob days from pre-hardening
        // builds may carry cycle/intimate healthContext. Migration must route through the SAME SanitizedDay
        // strip as saveSnapshot/updateDay so no sensitive content lands in the uncapped, CloudKit-synced
        // DayRecord rows.
        let controller = PersistenceController(inMemory: true)
        var blob = LocalFernletDatabase()
        blob.days = [
            "2026-05-01": FernletDay(
                date: "2026-05-01",
                bottleCount: 1,  // logged content so the day gets a row
                healthContext: HealthDailyContext(
                    syncedAt: Date(),
                    activity: HealthActivitySummary(steps: 5000),
                    cycle: HealthCycleContext(menstrualFlowEventCount: 2),
                    intimate: HealthIntimateContext(eventCount: 1)
                )
            )
        ]
        blob.daysMigratedToRows = false
        seedAggregateBlob(blob, in: controller)

        let repo = CoreDataFernletRepository(controller: controller)
        let day = repo.loadAllDays()["2026-05-01"]
        #expect(day?.healthContext?.cycle == nil)     // stripped
        #expect(day?.healthContext?.intimate == nil)  // stripped
        #expect(day?.healthContext?.activity != nil)  // non-sensitive context survives
    }

    @Test func normalSaveDoesNotReDecodeWholeHistory() {
        // Item H (full-history re-decode on every save): after the day-history memo is warm, a normal
        // single-day save must patch the memo in place and reuse it for the derived rebuild — NOT re-fetch
        // and re-decode the whole (uncapped) row history via loadRecent/loadAll on the hot path.
        let controller = PersistenceController(inMemory: true)
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let counting = CountingDayRepo()
        counting.store["2026-05-01"] = FernletDay(date: "2026-05-01", bottleCount: 1)
        let repo = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: legacyURL),
            dayRecordRepository: counting
        )

        _ = repo.loadAllDays()          // warms cachedAllDays (migration already complete: empty legacy)
        counting.resetCounts()

        let today = "2026-05-22"
        let snapshot = FernletSnapshot(
            todayKey: today, day: FernletDay(date: today, bottleCount: 4), settings: FernletSettings(),
            recentMeals: [], previousJournals: [], memories: [], goals: [], workshop: WorkshopData()
        )
        #expect(repo.saveSnapshot(snapshot))

        // The save wrote exactly one row and rebuilt the derived state from the warm cache — no whole-history
        // re-read.
        #expect(counting.loadRecentCalls == 0)
        #expect(counting.loadAllCalls == 0)
        #expect(counting.upsertCalls == 1)  // the single known day it wrote
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

/// An in-memory day repo that counts read/write calls, to prove a normal save reuses the warm day-history
/// memo instead of re-fetching the whole history (item H).
@MainActor
private final class CountingDayRepo: DayRecordRepositoring {
    var store: [String: FernletDay] = [:]
    private(set) var loadAllCalls = 0
    private(set) var loadRecentCalls = 0
    private(set) var loadCalls = 0
    private(set) var upsertCalls = 0

    func resetCounts() {
        loadAllCalls = 0; loadRecentCalls = 0; loadCalls = 0; upsertCalls = 0
    }

    func loadAll() -> [String: FernletDay] { loadAllCalls += 1; return store }
    func load(dateKeys: [String]) -> [String: FernletDay] {
        loadCalls += 1
        return store.filter { dateKeys.contains($0.key) }
    }
    func loadRecent(limit: Int) -> [FernletDay] {
        loadRecentCalls += 1
        return Array(store.values.sorted { $0.date > $1.date }.prefix(limit))
    }
    @discardableResult func upsert(_ days: [DayRecordUpsert]) -> Bool {
        upsertCalls += 1
        for entry in days { store[entry.dateKey] = entry.day }
        return true
    }
    @discardableResult func delete(dateKeys: [String]) -> Bool { dateKeys.forEach { store[$0] = nil }; return true }
    @discardableResult func deleteAll() -> Bool { store.removeAll(); return true }
}

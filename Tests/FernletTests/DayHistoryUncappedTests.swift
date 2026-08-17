import Testing
import Foundation
import CloudKitSync
import LocalPersistence
import FernletDomainModel
import FernletPersistence

@MainActor
@Suite(.serialized)
struct DayHistoryUncappedTests {
    /// iCloud path: the per-row store holds well beyond the old 370-day cap, and the repository reads them
    /// all back — history no longer truncates at a year.
    @Test func coreDataHistoryExceeds370DaysViaRows() {
        let controller = PersistenceController(inMemory: true)
        let dayRepo = DayRecordRepository(controller: controller)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<400 {
            let key = String(format: "2020-%05d", i)
            #expect(dayRepo.upsert([DayRecordUpsert(day: FernletDay(date: key), updatedAt: stamp)]) == true)
        }
        let repo = CoreDataFernletRepository(controller: controller)
        #expect(repo.loadAllDays().count >= 400)  // > the old 370 cap, nothing pruned
    }

    /// The day-history read cache memoizes `loadAllDays()` (so the two full-history reads on every
    /// launch/foreground/remote change share one decode instead of re-scanning the uncapped table), and a
    /// cache invalidation re-reads so it can never serve a day that was edited or synced in.
    @Test func loadAllDaysIsCachedAndInvalidatedOnRefresh() {
        let controller = PersistenceController(inMemory: true)
        let dayRepo = DayRecordRepository(controller: controller)
        #expect(dayRepo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01"), updatedAt: Date())]) == true)
        // Isolated (non-existent) legacy file so the blob-missing migration path can't fan stray on-disk
        // legacy days into rows and perturb the exact count — the count assertions below must be hermetic.
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let repo = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: legacyURL)
        )

        let first = repo.loadAllDays()                          // decodes + memoizes
        #expect(first["2026-05-01"] != nil)
        #expect(first["2026-05-02"] == nil)
        #expect(repo.loadAllDays()["2026-05-01"] != nil)        // repeated reads are consistent

        // After a new row lands, an invalidation (what a remote CloudKit change or a local save triggers)
        // must drop the memoized set so the next read reflects the fresh history.
        #expect(dayRepo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-02"), updatedAt: Date())]) == true)
        repo.invalidateCache()
        #expect(repo.loadAllDays()["2026-05-02"] != nil)
    }

    /// Local/no-iCloud path: `apply` with no bound keeps the full history in the single file (the cap is
    /// gone for everyone), while the derived log tables stay bounded by `derivedLogWindowDays`.
    @Test func localApplyKeepsMoreThan370DaysButBoundsDerivedTables() {
        var db = LocalFernletDatabase()
        for i in 0..<400 {
            let key = String(format: "2020-%05d", i)
            db.days[key] = FernletDay(date: key)
        }
        let todayKey = "2020-99999"
        let snapshot = FernletSnapshot(
            todayKey: todayKey,
            day: FernletDay(date: todayKey),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
        db.apply(snapshot)  // nil bound → no pruning
        #expect(db.days.count == 401)

        db.rebuildDerivedTables(todayKey: todayKey)  // must not trip any cap assertion with >370 days
        #expect(db.dailyLogs.count == FernletLimits.derivedLogWindowDays)  // derived stays bounded
    }
}

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
            dayRepo.upsert([DayRecordUpsert(day: FernletDay(date: key), updatedAt: stamp)])
        }
        let repo = CoreDataFernletRepository(controller: controller)
        #expect(repo.loadAllDays().count >= 400)  // > the old 370 cap, nothing pruned
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

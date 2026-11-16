import Testing
import CoreData
import Foundation
@testable import CloudKitSync
import FernletDomainModel
import FernletPersistence

@MainActor
@Suite(.serialized)
struct DayRecordRepositoryTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func upsertAndLoadAllRoundTrips() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        #expect(repo.upsert([
            DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 3), updatedAt: stamp),
            DayRecordUpsert(day: FernletDay(date: "2026-05-02", bottleCount: 5), updatedAt: stamp)
        ]) == true)
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
        #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 1), updatedAt: stamp)]) == true)
        #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-02", bottleCount: 2), updatedAt: stamp)]) == true)
        let days = repo.loadAll()
        #expect(days.count == 2)
        #expect(days["2026-05-01"]?.bottleCount == 1)
    }

    @Test func upsertReplacesSameDateKeyInPlace() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 1), updatedAt: stamp)]) == true)
        #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: "2026-05-01", bottleCount: 9), updatedAt: stamp)]) == true)
        let days = repo.loadAll()
        #expect(days.count == 1)
        #expect(days["2026-05-01"]?.bottleCount == 9)
    }

    @Test func loadMergesLegacyDuplicateRowsAndWritesNothing() throws {
        // CloudKit can mirror two pre-G9 rows for one dateKey (it keys by record identity, not the
        // attribute): two devices that each first-wrote the day before import settled. Bug confirmation
        // 2026-10-15 §3 made the read merge them by entry id; since G9-1 the read merges every row of a
        // day element by element (legacy rows stamped at their `updatedAt`) and NEVER writes or deletes,
        // because a row is its device's own.
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let breakfast = makeMeal("Breakfast")
        let lunch = makeMeal("Lunch")
        let journal = JournalEntry(text: "", tag: .good)
        insertRawDayRow(in: context, FernletDay(date: "2026-05-01", meals: [breakfast], bottleCount: 1), updatedAt: stamp)
        insertRawDayRow(in: context, FernletDay(date: "2026-05-01", meals: [lunch], journals: [journal], bottleCount: 7),
                        updatedAt: stamp.addingTimeInterval(60))
        try context.save()

        let repo = DayRecordRepository(controller: controller)
        let day = try #require(repo.loadAll()["2026-05-01"])
        #expect(Set(day.meals.map(\.id)) == [breakfast.id, lunch.id], "a device's meal was dropped by the merge")
        #expect(day.journals.map(\.id) == [journal.id])
        #expect(day.bottleCount == 7)
        #expect(rawRowCount(in: context) == 2, "a read deleted a row")
        #expect(!context.hasChanges, "a read staged a write")
    }

    @Test func aTieBetweenLegacyRowsReadsTheSameEveryTime() throws {
        // Two migration-backfilled rows share the blob's single `updatedAt`. Both stay on disk (no read
        // deletes anything), both rows' entries are served, and repeated reads agree.
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let breakfast = makeMeal("Breakfast")
        let lunch = makeMeal("Lunch")
        insertRawDayRow(in: context, FernletDay(date: "2026-05-01", meals: [breakfast], bottleCount: 3), updatedAt: stamp)
        insertRawDayRow(in: context, FernletDay(date: "2026-05-01", meals: [lunch], bottleCount: 8), updatedAt: stamp)
        try context.save()

        let repo = DayRecordRepository(controller: controller)
        let day = try #require(repo.loadAll()["2026-05-01"])
        #expect(Set(day.meals.map(\.id)) == [breakfast.id, lunch.id])
        #expect([3, 8].contains(day.bottleCount))
        #expect(repo.loadAll()["2026-05-01"]?.bottleCount == day.bottleCount, "repeated reads disagreed")
        #expect(rawRowCount(in: context) == 2)
    }

    @Test func theNewerLegacyRowsCopyOfAnEntryWins() throws {
        // A copy of the SAME entry in two legacy rows is the newer row's; what only the older row holds
        // (its journal entry, its hygiene tick) is kept.
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        var shared = makeMeal("Toast")
        let olderJournal = JournalEntry(text: "", tag: .good)
        insertRawDayRow(in: context, FernletDay(date: "2026-05-01", meals: [shared], journals: [olderJournal],
                                                bottleCount: 4, hygiene: [.floss]), updatedAt: stamp)
        shared.name = "Toast with jam"
        insertRawDayRow(in: context, FernletDay(date: "2026-05-01", meals: [shared], bottleCount: 2, hygiene: [.shower]),
                        updatedAt: stamp.addingTimeInterval(60))
        try context.save()

        let day = try #require(DayRecordRepository(controller: controller).loadAll()["2026-05-01"])
        #expect(day.meals.map(\.name) == ["Toast with jam"])
        #expect(day.journals.map(\.id) == [olderJournal.id])
        #expect(day.bottleCount == 2)
        #expect(day.hygiene == [.floss, .shower])
    }

    @Test func theMergeTakesEveryElementKindFromItsNewestRow() throws {
        // The rule over values: every entry list, set and plan merges per element, the newer row's copy
        // winning; sleep and water come from the newest row that holds them.
        let recipeA = UUID(), recipeB = UUID()
        let newerWorkout = makeWorkout("Run")
        let olderWorkout = makeWorkout("Swim")
        let newer = FernletDay(date: "2026-05-01", workouts: [newerWorkout], bottleCount: 1,
                               plannedRecipeIDs: [recipeA], plannedMeals: [PlannedMealEntry(recipeID: recipeA, mealType: .lunch)])
        let older = FernletDay(date: "2026-05-01", workouts: [olderWorkout, newerWorkout], sleep: SleepLog(hours: 7, quality: .good, note: ""),
                               bottleCount: 3, completedPersonalCareTaskIDs: ["stretch"], plannedRecipeIDs: [recipeB])
        let rows = [DayRowView.legacy(day: newer, updatedAt: stamp.addingTimeInterval(60), tiebreak: "b"),
                    DayRowView.legacy(day: older, updatedAt: stamp, tiebreak: "a")]
        let merged = try #require(DayRowMerge.merge(date: "2026-05-01", rows: rows)?.day)
        #expect(merged.workouts.map(\.id) == [newerWorkout.id, olderWorkout.id])
        #expect(merged.sleep?.hours == 7)
        #expect(merged.bottleCount == 1)
        #expect(merged.completedPersonalCareTaskIDs.contains("stretch"))
        #expect(merged.plannedRecipeIDs == [recipeA, recipeB])
        #expect(merged.plannedMeals?.map(\.recipeID) == [recipeA])
        #expect(DayRowMerge.merge(date: "2026-05-01", rows: []) == nil)
    }

    @Test func loadByDateKeysReturnsOnlyRequested() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for (i, key) in ["2026-05-01", "2026-05-02", "2026-05-03"].enumerated() {
            #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: key, bottleCount: i + 1), updatedAt: stamp)]) == true)
        }
        let subset = repo.load(dateKeys: ["2026-05-01", "2026-05-03"])
        #expect(Set(subset.keys) == ["2026-05-01", "2026-05-03"])
    }

    @Test func loadRecentReturnsNewestWithinLimit() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for day in 1...10 {
            let key = String(format: "2026-05-%02d", day)
            #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: key, bottleCount: 1), updatedAt: stamp)]) == true)
        }
        let recent = repo.loadRecent(limit: 3)
        #expect(recent.map(\.date) == ["2026-05-10", "2026-05-09", "2026-05-08"])
    }

    @Test func deleteRemovesOnlyListedDays() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for key in ["2026-05-01", "2026-05-02", "2026-05-03"] {
            #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: key, bottleCount: 1), updatedAt: stamp)]) == true)
        }
        #expect(repo.delete(dateKeys: ["2026-05-02"]) == true)
        #expect(Set(repo.loadAll().keys) == ["2026-05-01", "2026-05-03"])
    }

    // MARK: - Raw-row helpers (white-box, to simulate CloudKit-mirrored duplicates)

    private func insertRawDayRow(in context: NSManagedObjectContext, dateKey: String, bottleCount: Int, updatedAt: Date) {
        insertRawDayRow(in: context, FernletDay(date: dateKey, bottleCount: bottleCount), updatedAt: updatedAt)
    }

    private func insertRawDayRow(in context: NSManagedObjectContext, _ day: FernletDay, updatedAt: Date) {
        let record = NSEntityDescription.insertNewObject(forEntityName: "DayRecord", into: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try? encoder.encode(day)
        record.setValue(day.date, forKey: "dateKey")
        record.setValue(payload, forKey: "payloadData")
        record.setValue(updatedAt, forKey: "updatedAt")
    }

    private func rawRowCount(in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        return (try? context.fetch(request).count) ?? -1
    }

    /// A workout with a fresh id.
    private func makeWorkout(_ name: String) -> Workout {
        Workout(name: name, type: .upper, exercises: "", rpe: nil, notes: "", duration: 20, intensity: .moderate)
    }

    /// A meal with a fresh id — the entry identity the merge unions by.
    private func makeMeal(_ name: String) -> Meal {
        let macros = Macros(protein: 10, carbs: 20, fat: 5)
        return Meal(name: name, mealType: .lunch, macros: macros, quality: .good,
                    confidence: "high", note: "", source: "manual")
    }
}

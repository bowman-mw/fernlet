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

    @Test func loadMergesDuplicateRowsIntoTheNewestAndSelfHeals() throws {
        // CloudKit can mirror two rows for one dateKey (it keys by record identity, not the attribute):
        // two devices that each first-wrote the day before import settled. Bug confirmation 2026-10-15
        // §3: the read kept the newer row WHOLE and deleted the other, so breakfast logged on the iPhone
        // vanished from both devices once the iPad's lunch row synced. The read now merges the rows by
        // entry id, writes the merge into the newest row and only then deletes the older one.
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
        #expect(Set(day.meals.map(\.id)) == [breakfast.id, lunch.id], "a device's meal was dropped by the collapse")
        #expect(day.journals.map(\.id) == [journal.id])
        #expect(day.bottleCount == 7)

        // Self-heal: the older duplicate row is deleted — and the surviving row holds the merge, so a
        // fresh read (another launch, the other device after the sync) still has both meals.
        #expect(rawRowCount(in: context) == 1)
        let reread = try #require(DayRecordRepository(controller: controller).loadAll()["2026-05-01"])
        #expect(Set(reread.meals.map(\.id)) == [breakfast.id, lunch.id], "the merge was not written before the delete")
        #expect(rawUpdatedAts(in: context) == [stamp.addingTimeInterval(60)], "the heal re-stamped the surviving row")
    }

    @Test func loadKeepsBothRowsOnEqualUpdatedAtTieAndCollapsesDeterministically() {
        // Item A (mutual-delete data loss): two devices that both ran migration stamp their backfilled rows
        // with the SAME blob `updatedAt`. If the read-side dedup deleted the "loser" on an equal-updatedAt
        // tie, each device would delete the OTHER device's row and both deletes would sync → both rows lost.
        // So on an equal `updatedAt` NOTHING may be deleted; the dict value is only made deterministic.
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        insertRawDayRow(in: context, dateKey: "2026-05-01", bottleCount: 3, updatedAt: stamp)
        insertRawDayRow(in: context, dateKey: "2026-05-01", bottleCount: 8, updatedAt: stamp)  // same stamp
        try? context.save()

        let repo = DayRecordRepository(controller: controller)
        let days = repo.loadAll()
        #expect(days.count == 1)                        // collapsed to one in the returned dict
        #expect(days["2026-05-01"]?.bottleCount == 8)   // the merge takes the larger water count
        // Deterministic: repeated reads return the SAME merge (no flip-flop).
        #expect(repo.loadAll()["2026-05-01"]?.bottleCount == days["2026-05-01"]?.bottleCount)

        // The critical invariant: NEITHER row was deleted — both survive on disk, so two devices can never
        // mutually wipe each other's rows.
        #expect(rawRowCount(in: context) == 2)
    }

    @Test func aTieAtTheTopReturnsBothRowsEntriesAndWritesNothing() throws {
        // The tie case keeps both rows on disk (the mutual-delete guard) — and the read must still serve
        // what BOTH hold, not one row's day chosen by the tiebreak.
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let breakfast = makeMeal("Breakfast")
        let lunch = makeMeal("Lunch")
        insertRawDayRow(in: context, FernletDay(date: "2026-05-01", meals: [breakfast]), updatedAt: stamp)
        insertRawDayRow(in: context, FernletDay(date: "2026-05-01", meals: [lunch]), updatedAt: stamp)
        try context.save()

        let day = try #require(DayRecordRepository(controller: controller).loadAll()["2026-05-01"])
        #expect(Set(day.meals.map(\.id)) == [breakfast.id, lunch.id])
        #expect(rawRowCount(in: context) == 2)
        #expect(!context.hasChanges, "a tie staged a write")
    }

    @Test func loadStillDeletesTheOlderRowOnceItsEntriesAreMerged() throws {
        // The strict-winner self-heal must still fire: a genuinely older duplicate (strictly smaller
        // updatedAt) is deleted so a real conflict collapses to one row — but what it held is kept: the
        // older row's journal entry and its hygiene tick survive in the newer row (bug confirmation
        // 2026-10-15 §3). A copy of the SAME entry in both rows is the newer row's.
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
        #expect(day.meals.map(\.name) == ["Toast with jam"])  // one entry, the newer copy
        #expect(day.journals.map(\.id) == [olderJournal.id])
        #expect(day.bottleCount == 4)
        #expect(day.hygiene == [.floss, .shower])
        #expect(rawRowCount(in: context) == 1)                  // the older row was deleted
    }

    @Test func theMergeUnionsEveryEntryKindByID() {
        // The rule itself, over values: every entry list unions by id with the newer copy winning, water
        // takes the larger count, sets union, and the plan unions by recipe id.
        let recipeA = UUID(), recipeB = UUID()
        let newerWorkout = makeWorkout("Run")
        let olderWorkout = makeWorkout("Swim")
        let newer = FernletDay(date: "2026-05-01", workouts: [newerWorkout], bottleCount: 1,
                               plannedRecipeIDs: [recipeA], plannedMeals: [PlannedMealEntry(recipeID: recipeA, mealType: .lunch)])
        let older = FernletDay(date: "2026-05-01", workouts: [olderWorkout, newerWorkout], sleep: SleepLog(hours: 7, quality: .good, note: ""),
                               bottleCount: 3, completedPersonalCareTaskIDs: ["stretch"], plannedRecipeIDs: [recipeB])
        let merged = DuplicateDayRows.merged(newestFirst: [newer, older])
        #expect(merged?.workouts.map(\.id) == [newerWorkout.id, olderWorkout.id])
        #expect(merged?.sleep?.hours == 7)
        #expect(merged?.bottleCount == 3)
        #expect(merged?.completedPersonalCareTaskIDs.contains("stretch") == true)
        #expect(merged?.plannedRecipeIDs == [recipeA, recipeB])
        #expect(merged?.plannedMeals?.map(\.recipeID) == [recipeA])
        #expect(DuplicateDayRows.merged(newestFirst: []) == nil)
    }

    @Test func loadByDateKeysReturnsOnlyRequested() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for (i, key) in ["2026-05-01", "2026-05-02", "2026-05-03"].enumerated() {
            #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: key, bottleCount: i), updatedAt: stamp)]) == true)
        }
        let subset = repo.load(dateKeys: ["2026-05-01", "2026-05-03"])
        #expect(Set(subset.keys) == ["2026-05-01", "2026-05-03"])
    }

    @Test func loadRecentReturnsNewestWithinLimit() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for day in 1...10 {
            let key = String(format: "2026-05-%02d", day)
            #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: key), updatedAt: stamp)]) == true)
        }
        let recent = repo.loadRecent(limit: 3)
        #expect(recent.map(\.date) == ["2026-05-10", "2026-05-09", "2026-05-08"])
    }

    @Test func deleteRemovesOnlyListedDays() {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        for key in ["2026-05-01", "2026-05-02", "2026-05-03"] {
            #expect(repo.upsert([DayRecordUpsert(day: FernletDay(date: key), updatedAt: stamp)]) == true)
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

    private func rawUpdatedAts(in context: NSManagedObjectContext) -> [Date] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        return ((try? context.fetch(request)) ?? []).compactMap { $0.value(forKey: "updatedAt") as? Date }
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

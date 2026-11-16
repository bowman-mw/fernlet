// DayRowMergeTests.swift
// FernletTests
//
// G9-1 (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md, Part 1): two devices over one store, each
// writing its own `DayRecord` row per day. Each test plays the phone ("A") and the iPad ("B") with two
// `DayRecordRepository`s over ONE in-memory controller, which is what CloudKit makes of two devices
// once their rows have synced.

import Testing
import CoreData
import Foundation
@testable import CloudKitSync
import FernletDomainModel
import FernletPersistence
import FernletFoundation

@MainActor
@Suite(.serialized)
struct DayRowMergeTests {
    private let key = "2026-11-15"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func bothDevicesLoggingTheSameDayKeepBothEntries() throws {
        let (a, b, context) = devices()
        let breakfast = makeMeal("Breakfast"), lunch = makeMeal("Lunch")
        #expect(a.upsert([write(FernletDay(date: key, meals: [breakfast]), at: 0)]))
        #expect(b.upsert([write(FernletDay(date: key, meals: [lunch]), at: 10)]))
        let day = try #require(a.loadAll()[key])
        #expect(Set(day.meals.map(\.id)) == [breakfast.id, lunch.id])
        #expect(rowCount(context) == 2, "each device writes its own row")
    }

    @Test func aDeletionIsNotUndoneByTheOtherDevicesCopy() throws {
        let (a, b, _) = devices()
        let toast = makeMeal("Toast"), soup = makeMeal("Soup")
        #expect(a.upsert([write(FernletDay(date: key, meals: [toast]), at: 0)]))
        var onB = try #require(b.loadAll()[key])
        onB.meals.append(soup)
        #expect(b.upsert([write(onB, at: 10)]))
        var onA = try #require(a.loadAll()[key])
        onA.meals.removeAll { $0.id == toast.id }
        #expect(a.upsert([write(onA, at: 20)]))
        #expect(try #require(a.loadAll()[key]).meals.map(\.id) == [soup.id])
        // B re-saves its stale copy (still holding the toast, unchanged): the deletion stands.
        #expect(b.upsert([write(onB, at: 30)]))
        #expect(try #require(b.loadAll()[key]).meals.map(\.id) == [soup.id])
    }

    @Test func aStaleCopyNeverDeletesWhatItNeverSaw() throws {
        let (a, b, _) = devices()
        let toast = makeMeal("Toast"), soup = makeMeal("Soup")
        #expect(a.upsert([write(FernletDay(date: key, meals: [toast]), at: 0)]))
        let staleOnA = try #require(a.loadAll()[key])
        var onB = try #require(b.loadAll()[key])
        onB.meals.append(soup)
        #expect(b.upsert([write(onB, at: 10)]))
        #expect(a.upsert([write(staleOnA, at: 20)]))
        #expect(Set(try #require(a.loadAll()[key]).meals.map(\.id)) == [toast.id, soup.id])
    }

    @Test func anEmptiedDayStaysEmptyAndKeepsItsRow() throws {
        let (a, b, context) = devices()
        let toast = makeMeal("Toast")
        #expect(a.upsert([write(FernletDay(date: key, meals: [toast], bottleCount: 2), at: 0)]))
        let onB = try #require(b.loadAll()[key])
        #expect(b.upsert([write(onB, at: 10)]))
        var onA = try #require(a.loadAll()[key])
        onA.meals = []
        onA.bottleCount = 0
        #expect(a.upsert([write(onA, at: 20)]))
        #expect(a.loadAll()[key] == nil, "an emptied day reads absent")
        #expect(rowCount(context) == 2, "the emptied day's row holds its tombstones")
        #expect(b.upsert([write(onB, at: 30)]))
        #expect(b.loadAll()[key] == nil, "the other device's stale copy brought the day back")
    }

    @Test func aLaterEditBeatsAStaleResave() throws {
        let (a, b, _) = devices()
        var toast = makeMeal("Toast")
        #expect(a.upsert([write(FernletDay(date: key, meals: [toast]), at: 0)]))
        let staleOnA = try #require(a.loadAll()[key])
        toast.name = "Toast with jam"
        var onB = try #require(b.loadAll()[key])
        onB.meals = [toast]
        #expect(b.upsert([write(onB, at: 10)]))
        #expect(a.upsert([write(staleOnA, at: 20)]))
        #expect(try #require(a.loadAll()[key]).meals.map(\.name) == ["Toast with jam"])
    }

    @Test func anEditWinsEvenWhenThisDevicesClockIsBehind() throws {
        let (a, b, _) = devices()
        var toast = makeMeal("Toast")
        #expect(b.upsert([write(FernletDay(date: key, meals: [toast]), at: 100)]))
        var onA = try #require(a.loadAll()[key])
        toast.name = "Rye toast"
        onA.meals = [toast]
        #expect(a.upsert([write(onA, at: 0)]), "A's clock reads earlier than B's stamp")
        #expect(try #require(b.loadAll()[key]).meals.map(\.name) == ["Rye toast"])
    }

    @Test func aDayWithNothingToRecordWritesNoRow() {
        let (a, _, context) = devices()
        #expect(a.upsert([write(FernletDay(date: key), at: 0)]))
        #expect(rowCount(context) == 0)
    }

    @Test func anUnchangedResaveDoesNotRewriteTheRow() throws {
        let (a, _, context) = devices()
        #expect(a.upsert([write(FernletDay(date: key, bottleCount: 3), at: 0)]))
        let before = try #require(rawRecords(context).first?.value(forKey: "payloadData") as? Data)
        let loaded = try #require(a.loadAll()[key])
        #expect(a.upsert([write(loaded, at: 50)]))
        #expect(rawRecords(context).first?.value(forKey: "payloadData") as? Data == before)
    }

    @Test func aLegacyRowsEntryCanBeDeleted() throws {
        let (a, _, context) = devices()
        let toast = makeMeal("Toast"), soup = makeMeal("Soup")
        insertLegacyRow(FernletDay(date: key, meals: [toast, soup]), updatedAt: t0, in: context)
        try context.save()
        var onA = try #require(a.loadAll()[key])
        onA.meals.removeAll { $0.id == toast.id }
        #expect(a.upsert([write(onA, at: 20)]))
        #expect(try #require(a.loadAll()[key]).meals.map(\.id) == [soup.id])
        #expect(rowCount(context) == 2, "the legacy row is left in place")
    }

    @Test func aNewerFormatOwnRowIsLeftAlone() throws {
        let (a, _, context) = devices()
        let record = NSEntityDescription.insertNewObject(forEntityName: "DayRecord", into: context)
        let newer = Data(#"{"date":"\#(key)","bottleCount":4,"syncFormat":2,"syncStamps":{}}"#.utf8)
        record.setValue(key, forKey: "dateKey")
        record.setValue("A", forKey: "deviceKey")
        record.setValue(newer, forKey: "payloadData")
        record.setValue(t0, forKey: "updatedAt")
        try context.save()
        #expect(try #require(a.loadAll()[key]).bottleCount == 4, "a newer-format row still reads as legacy")
        #expect(a.upsert([write(FernletDay(date: key, bottleCount: 9), at: 20)]))
        #expect(record.value(forKey: "payloadData") as? Data == newer, "a newer-format row was rewritten")
    }

    @Test func theRowPayloadStillDecodesAsAPlainDay() throws {
        // An un-updated build decodes the row as a bare `FernletDay` and ignores the two sync keys.
        var day = FernletDay(date: key, bottleCount: 2)
        day.loadedSyncKeys = ["water"]
        let payload = DayRowPayload(day: day, stamps: ["water": DayElementStamp(at: 1, by: "A")])
        let data = try RowPayloadCoders.makeEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("syncFormat") && json.contains("syncStamps"))
        #expect(!json.contains("loadedSyncKeys"), "in-memory bookkeeping reached a synced row")
        let plain = try RowPayloadCoders.makeDecoder().decode(FernletDay.self, from: data)
        #expect(plain.bottleCount == 2)
        let round = try RowPayloadCoders.makeDecoder().decode(DayRowPayload.self, from: data)
        #expect(round.format == DayRowPayload.currentFormat)
        #expect(round.stamps["water"] == DayElementStamp(at: 1, by: "A"))
    }

    @Test func deleteAllForgetsThisInstallsDeviceKey() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = DayRecordRepository(controller: controller)
        #expect(repo.upsert([write(FernletDay(date: key, bottleCount: 1), at: 0)]))
        let first = try #require(rawRecords(controller.container.viewContext).first?.value(forKey: "deviceKey") as? String)
        #expect(controller.localDefaults.data(forKey: "fernlet.sync.dayRowDeviceKey") == Data(first.utf8))
        #expect(repo.deleteAll())
        #expect(controller.localDefaults.data(forKey: "fernlet.sync.dayRowDeviceKey") == nil)
        #expect(repo.upsert([write(FernletDay(date: key, bottleCount: 1), at: 0)]))
        let second = rawRecords(controller.container.viewContext).first?.value(forKey: "deviceKey") as? String
        #expect(second != nil && second != first, "the wipe kept the old device key")
    }

    // MARK: - Helpers

    private func devices() -> (DayRecordRepository, DayRecordRepository, NSManagedObjectContext) {
        let controller = PersistenceController(inMemory: true)
        return (DayRecordRepository(controller: controller, deviceKey: "A"),
                DayRecordRepository(controller: controller, deviceKey: "B"),
                controller.container.viewContext)
    }

    private func write(_ day: FernletDay, at seconds: TimeInterval) -> DayRecordUpsert {
        DayRecordUpsert(day: day, updatedAt: t0.addingTimeInterval(seconds))
    }

    private func rawRecords(_ context: NSManagedObjectContext) -> [NSManagedObject] {
        (try? context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DayRecord"))) ?? []
    }

    private func rowCount(_ context: NSManagedObjectContext) -> Int {
        rawRecords(context).count
    }

    private func insertLegacyRow(_ day: FernletDay, updatedAt: Date, in context: NSManagedObjectContext) {
        let record = NSEntityDescription.insertNewObject(forEntityName: "DayRecord", into: context)
        record.setValue(day.date, forKey: "dateKey")
        record.setValue(try? RowPayloadCoders.makeEncoder().encode(day), forKey: "payloadData")
        record.setValue(updatedAt, forKey: "updatedAt")
    }

    private func makeMeal(_ name: String) -> Meal {
        Meal(name: name, mealType: .lunch, macros: Macros(protein: 10, carbs: 20, fat: 5), quality: .good,
             confidence: "high", note: "", source: "manual")
    }
}

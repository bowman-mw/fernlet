import Testing
import CoreData
import Foundation
@testable import CloudKitSync
import FernletDomainModel
import FernletFoundation

/// G9-1 soft delete for custom clothing designs (Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md,
/// Part 1, S3 = A). A delete writes a separate content-free tombstone row (`"tombstone:" + uuid`) and
/// hard-deletes the live row, so another phone's stale edit (which upserts the plain-uuid row) cannot
/// undo it: reads hide and heal the id, upserts skip it, tombstones are kept for good, and
/// `deleteAll()` clears them with everything else.
@MainActor
@Suite(.serialized)
struct CustomItemSoftDeleteTests {
    private let stamp = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func deleteLeavesOnlyAContentFreeTombstone() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = CustomItemRepository(controller: controller)
        let doomed = makeItem(name: "Secret sweater")
        let kept = makeItem(name: "Kept hat")
        #expect(repo.upsert([doomed, kept]))

        #expect(repo.delete(ids: [doomed.id]))

        #expect(repo.load().map(\.id) == [kept.id])
        let rows = try allRows(in: controller)
        #expect(rows.count == 2)
        let tombstone = try #require(rows.first { $0.idString == RowTombstones.tombstoneIDString(for: doomed.id) })
        let payloadData = try #require(tombstone.payload)
        let payload = try RowPayloadCoders.makeDecoder().decode(RowTombstonePayload.self, from: payloadData)
        #expect(payload.id == doomed.id)
        #expect(payload.format == RowTombstonePayload.currentFormat)
        // Nothing of the design survives: only id, deletedAt and format are in the JSON.
        let keys = try #require(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]).keys
        #expect(Set(keys) == ["id", "deletedAt", "format"])
        #expect(!String(decoding: payloadData, as: UTF8.self).contains("Secret sweater"))
        #expect(!rows.contains { $0.idString == doomed.id.uuidString })
    }

    @Test func deletingTwiceKeepsOneTombstone() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = CustomItemRepository(controller: controller)
        let item = makeItem(name: "Hat")
        #expect(repo.upsert([item]))
        #expect(repo.delete(ids: [item.id]))
        #expect(repo.delete(ids: [item.id, item.id]))
        #expect(try allRows(in: controller).count == 1)
    }

    @Test func liveRowFromAnotherPhoneIsHiddenAndHealed() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = CustomItemRepository(controller: controller)
        let item = makeItem(name: "Scarf")
        #expect(repo.upsert([item]))
        #expect(repo.delete(ids: [item.id]))

        // Another phone, not yet aware of the delete, edits the price: its write lands on the plain-uuid
        // record and brings the live row back beside the tombstone.
        var edited = item
        edited.price = 40
        try insertLiveRow(edited, in: controller)
        #expect(try allRows(in: controller).count == 2)

        #expect(repo.load().isEmpty)
        let rows = try allRows(in: controller)
        #expect(rows.map(\.idString) == [RowTombstones.tombstoneIDString(for: item.id)])
    }

    @Test func upsertOfADeletedIDIsSkipped() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = CustomItemRepository(controller: controller)
        let item = makeItem(name: "Boots")
        let fresh = makeItem(name: "Fresh")
        #expect(repo.upsert([item]))
        #expect(repo.delete(ids: [item.id]))

        #expect(repo.upsert([item, fresh]))

        #expect(repo.load().map(\.id) == [fresh.id])
        #expect(!(try allRows(in: controller)).contains { $0.idString == item.id.uuidString })
    }

    @Test func deleteAllClearsTombstones() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = CustomItemRepository(controller: controller)
        let item = makeItem(name: "Cape")
        #expect(repo.upsert([item, makeItem(name: "Other")]))
        #expect(repo.delete(ids: [item.id]))

        #expect(repo.deleteAll())

        #expect(try allRows(in: controller).isEmpty)
    }

    @Test func newerFormatTombstoneIsHonouredAndNeverRewritten() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = CustomItemRepository(controller: controller)
        let item = makeItem(name: "Future")
        // A tombstone written by a later build: higher format and a key this build does not know.
        let future = Data(#"{"deletedAt":"2026-11-15T00:00:00Z","format":99,"id":"\#(item.id.uuidString)","why":"x"}"#.utf8)
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "CustomItemRecord", into: context)
        record.setValue(RowTombstones.tombstoneIDString(for: item.id), forKey: "idString")
        record.setValue(future, forKey: "payloadData")
        record.setValue(stamp, forKey: "createdAt")
        try context.save()
        try insertLiveRow(item, in: controller)

        #expect(repo.load().isEmpty)                       // honoured as a delete, live row healed
        #expect(repo.upsert([item]))                       // skipped
        #expect(repo.delete(ids: [item.id]))               // no second tombstone, no rewrite

        let rows = try allRows(in: controller)
        #expect(rows.count == 1)
        #expect(rows.first?.payload == future)
    }

    @Test func oldShapeReaderDropsTheTombstoneRow() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = CustomItemRepository(controller: controller)
        let doomed = makeItem(name: "Gone")
        let kept = makeItem(name: "Here")
        #expect(repo.upsert([doomed, kept]))
        #expect(repo.delete(ids: [doomed.id]))

        // A pre-G9 build: the engine with no load filter, decoding every row as a CustomizationItem.
        let oldReader = AppendOnlyRowStore<CustomizationItem>(
            controller: controller,
            entityName: "CustomItemRecord",
            loadTimingLabel: "CustomItemSoftDeleteTests.oldLoad",
            loadAsyncTimingLabel: "CustomItemSoftDeleteTests.oldLoadAsync",
            auditStore: "customItem",
            idString: { $0.id.uuidString },
            createdAt: { $0.createdAt }
        )
        #expect(try allRows(in: controller).count == 2)
        #expect(oldReader.load().map(\.id) == [kept.id])
    }

    // MARK: - Helpers

    private func makeItem(name: String) -> CustomizationItem {
        CustomizationItem(
            name: name,
            slot: .hat,
            texture: ItemGridTexture.blank(for: .hat, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: UUID()),
            createdAt: stamp
        )
    }

    private func insertLiveRow(_ item: CustomizationItem, in controller: PersistenceController) throws {
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "CustomItemRecord", into: context)
        record.setValue(item.id.uuidString, forKey: "idString")
        record.setValue(try RowPayloadCoders.makeEncoder().encode(item), forKey: "payloadData")
        record.setValue(item.createdAt, forKey: "createdAt")
        try context.save()
    }

    private func allRows(in controller: PersistenceController) throws -> [(idString: String?, payload: Data?)] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CustomItemRecord")
        return try controller.container.viewContext.fetch(request).map {
            ($0.value(forKey: "idString") as? String, $0.value(forKey: "payloadData") as? Data)
        }
    }
}

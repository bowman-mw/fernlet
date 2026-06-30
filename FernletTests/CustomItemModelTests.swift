import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import StoreCore

/// Covers the domain logic behind the custom-clothing feature: grid-texture helpers, item Codable
/// round-trips, anonymized provenance, and the per-row `CustomItemService` CRUD/persistence.
struct CustomItemModelTests {

    // MARK: - ItemGridTexture

    @Test func blankTextureIsSizedToSlotAndIsBlank() {
        let texture = ItemGridTexture.blank(for: .body, palette: ItemDesignPalette.hexes)
        #expect(texture.cols == ItemSlot.body.gridCols)
        #expect(texture.rows == ItemSlot.body.gridRows)
        #expect(texture.pixels.count == ItemSlot.body.gridCols * ItemSlot.body.gridRows)
        #expect(texture.isBlank)
    }

    @Test func hexLookupReturnsPaintedCellAndNilForTransparent() {
        var texture = ItemGridTexture.blank(for: .hat, palette: ["FF0000", "00FF00"])
        texture.pixels[0] = 1 // (0,0) -> 00FF00
        #expect(texture.hex(x: 0, y: 0) == "00FF00")
        #expect(texture.hex(x: 1, y: 0) == nil)        // transparent
        #expect(texture.hex(x: -1, y: 0) == nil)       // out of bounds
        #expect(texture.hex(x: texture.cols, y: 0) == nil)
        #expect(!texture.isBlank)
    }

    @Test func sanitizedClampsDimensionsAndCoercesBadIndices() {
        let raw = ItemGridTexture(
            cols: 4,
            rows: 2,
            palette: ["FF0000"],
            pixels: [0, 9, -1, 0, 0, 0, 0, 0] // index 9 is out of palette range
        )
        let clean = raw.sanitized(maxCols: 3, maxRows: 2)
        #expect(clean.cols == 3)
        #expect(clean.rows == 2)
        #expect(clean.pixels.count == 6)
        #expect(clean.pixels[1] == ItemGridTexture.transparent)
        #expect(clean.pixels[0] == 0)
    }

    @Test func sanitizedKeepsRowsAlignedWhenColsShrink() {
        // 4x2 grid; shrinking to 3 cols must keep each row's first 3 cells, NOT flat-copy (which would
        // pull source row0-col3 into dest row1-col0). palette index 0 = "A", -1 = transparent.
        let raw = ItemGridTexture(
            cols: 4,
            rows: 2,
            palette: ["AAAAAA"],
            pixels: [0, -1, -1, 0,   // row 0
                     -1, 0, 0, -1]   // row 1
        )
        let clean = raw.sanitized(maxCols: 3, maxRows: 2)
        // Correct coordinate copy: row0 = [0,-1,-1], row1 = [-1,0,0]
        #expect(clean.pixels == [0, ItemGridTexture.transparent, ItemGridTexture.transparent,
                                 ItemGridTexture.transparent, 0, 0])
        // The old flat-copy bug would have put source[3]==0 at dest index 3 (row1 col0); guard against it.
        #expect(clean.pixels[3] == ItemGridTexture.transparent)
    }

    // MARK: - Provenance (anonymized)

    @Test func designerCarriesOnlyAnAnonymousID() throws {
        // The whole point of the privacy model: an item on the wire reveals only a random UUID.
        let designer = ItemDesigner(id: UUID())
        let data = try JSONEncoder().encode(designer)
        let json = try #require(String(data: data, encoding: .utf8))
        // No name/key/fingerprint keys — just the id.
        #expect(json.contains("id"))
        #expect(!json.lowercased().contains("name"))
        #expect(!json.lowercased().contains("fingerprint"))
    }

    // MARK: - Item Codable round-trip (its own per-row store, not settings)

    @Test func itemSurvivesEncodeDecode() throws {
        var texture = ItemGridTexture.blank(for: .body, palette: ItemDesignPalette.hexes)
        texture.pixels[5] = 3
        let item = CustomizationItem(
            name: "Sun shirt",
            slot: .body,
            texture: texture,
            designer: ItemDesigner(id: UUID()),
            isShareable: true,
            price: 12
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(CustomizationItem.self, from: data)
        #expect(decoded == item)
    }

    @Test func legacySettingsDecodeWithoutItemFields() throws {
        // A settings blob written before the feature existed has none of the new keys.
        let legacy = "{\"bottleOz\":24}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: legacy)
        #expect(decoded.equippedItemIDsBySlot.isEmpty)
        #expect(decoded.localDesignerID == nil)
        #expect(decoded.knownDesignerNames.isEmpty)
    }

    // MARK: - CustomItemService CRUD over a stub repository

    @MainActor @Test func serviceUpsertDeleteAndShareableFlushToRepository() {
        let repo = StubCustomItemRepository()
        let service = CustomItemService(repository: repo)

        let item = CustomizationItem(
            name: "Hat",
            slot: .hat,
            texture: ItemGridTexture.blank(for: .hat, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: UUID())
        )
        service.upsert(item)
        #expect(service.items.count == 1)

        // upsert replaces in place rather than duplicating
        var renamed = item
        renamed.name = "Cap"
        service.upsert(renamed)
        #expect(service.items.count == 1)
        #expect(service.items.first?.name == "Cap")

        service.setShareable(id: item.id, true)
        #expect(service.items.first?.isShareable == true)

        service.flushPendingSave()
        #expect(repo.saved.count == 1)
        #expect(repo.saved.first?.isShareable == true)

        service.delete(id: item.id)
        service.flushPendingSave()
        #expect(service.items.isEmpty)
        #expect(repo.saved.isEmpty)
    }
}

private final class StubCustomItemRepository: CustomItemRepositoring {
    private(set) var store: [UUID: CustomizationItem] = [:]
    var saved: [CustomizationItem] { Array(store.values) }
    func load() -> [CustomizationItem] { saved }
    func loadAsync() async -> [CustomizationItem] { saved }
    @discardableResult func upsert(_ items: [CustomizationItem]) -> Bool {
        for item in items { store[item.id] = item }
        return true
    }
    @discardableResult func delete(ids: [UUID]) -> Bool {
        for id in ids { store[id] = nil }
        return true
    }
    @discardableResult func deleteAll() -> Bool {
        store.removeAll()
        return true
    }
}

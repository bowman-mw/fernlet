import Foundation
import Testing
import FernletDomainModel
import ProximityKit
@testable import Fernlet

/// The clothing-shop codec (Increment 3): building a peer's broadcast catalog from the user's own
/// shareable designs (capped, deterministically ordered, clamped) and sanitizing an untrusted received
/// catalog before it is rendered or bought.
struct ClothingShareCodecTests {

    private let designerID = UUID()
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func item(
        name: String = "Hat",
        slot: ItemSlot = .hat,
        shareable: Bool,
        price: Int,
        designer: UUID,
        offset: Double = 0
    ) -> CustomizationItem {
        CustomizationItem(
            name: name,
            slot: slot,
            texture: ItemGridTexture.blank(for: slot, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: designer),
            createdAt: base.addingTimeInterval(offset),
            isShareable: shareable,
            price: price
        )
    }

    @Test func catalogListsOnlyOwnShareableItemsCappedAndOrdered() {
        var items: [CustomizationItem] = []
        for i in 0..<7 {  // seven own shareable items — over the cap of six
            items.append(item(name: "Item\(i)", shareable: true, price: 10 + i, designer: designerID, offset: Double(i)))
        }
        items.append(item(name: "Private", shareable: false, price: 5, designer: designerID, offset: 100))
        items.append(item(name: "Friend", shareable: true, price: 5, designer: UUID(), offset: 101))  // someone else's

        let catalog = ClothingShareCodec.catalog(forShareable: items, designerID: designerID, displayName: "Robin")

        #expect(catalog.items.count == ClothingShopLimits.maxListedItems)            // capped at 6
        #expect(catalog.items.allSatisfy { $0.designer.id == designerID })           // only your own designs
        #expect(!catalog.items.contains { $0.name == "Private" })                    // private items excluded
        #expect(!catalog.items.contains { $0.name == "Friend" })                     // friend's design excluded
        let times = catalog.items.map(\.createdAt)
        #expect(times == times.sorted())                                             // deterministic order
        #expect(catalog.designerID == designerID)
        #expect(catalog.displayName == "Robin")
    }

    @Test func catalogClampsPriceAndSanitizesName() throws {
        let big = item(name: "X" + String(repeating: "y", count: 60), shareable: true, price: 9_999, designer: designerID)
        let catalog = ClothingShareCodec.catalog(forShareable: [big], designerID: designerID, displayName: "Robin")
        let listed = try #require(catalog.items.first)
        #expect(listed.price == ClothingShopLimits.maxPrice)
        #expect(listed.name.count <= ItemNameModeration.maxNameLength)
    }

    @Test func catalogPayloadRoundTripsThroughJSON() throws {
        let catalog = ClothingShareCodec.catalog(
            forShareable: [item(shareable: true, price: 12, designer: designerID)],
            designerID: designerID,
            displayName: "Robin"
        )
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(ClothingCatalogPayload.self, from: data)
        #expect(decoded == catalog)
    }

    @Test func sanitizedItemsClampUntrustedTexturePriceAndDeDuplicate() throws {
        // A hostile payload: an oversized texture with out-of-range palette indices, a negative price, an
        // invisible-char name, and a duplicate row (same id).
        var bad = item(shareable: true, price: -5, designer: designerID)
        bad.texture = ItemGridTexture(cols: 200, rows: 200, palette: ["FF0000"], pixels: Array(repeating: 9, count: 200 * 200))
        bad.name = "Hat\u{200B}"
        let payload = ClothingCatalogPayload(designerID: designerID, displayName: "Robin", items: [bad, bad])

        let cleaned = ClothingShareCodec.sanitizedItems(from: payload)

        #expect(cleaned.count == 1)                                                  // deduped by id
        let only = try #require(cleaned.first)
        #expect(only.texture.cols <= ItemSlot.hat.gridCols)                          // refit to slot grid
        #expect(only.texture.rows <= ItemSlot.hat.gridRows)
        #expect(only.texture.pixels.allSatisfy { $0 == ItemGridTexture.transparent || ($0 >= 0 && $0 < only.texture.palette.count) })
        #expect(only.price >= ClothingShopLimits.minPrice && only.price <= ClothingShopLimits.maxPrice)
        #expect(!only.name.unicodeScalars.contains("\u{200B}"))
    }

    @Test func sanitizedItemsSurviveHostileNegativeTextureDimensions() throws {
        // Remotely-triggerable crash: a peer broadcasts a catalog whose item texture carries `rows: -1`
        // (or `cols: -1`). Synthesized Codable happily decodes negative Ints, and the sanitizer used to
        // trap building an inverted Range. Decode-then-sanitize must never crash and must yield a safely
        // bounded texture. Encoding a payload with negative dims and decoding it exercises the real wire path.
        var neg = item(shareable: true, price: 10, designer: designerID)
        neg.texture = ItemGridTexture(cols: -1, rows: -1, palette: ["FF0000"], pixels: [0, 0, 0])
        let payload = ClothingCatalogPayload(designerID: designerID, displayName: "Robin", items: [neg])

        // Round-trip through JSON to prove the negative dims genuinely survive decoding (the untrusted path).
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClothingCatalogPayload.self, from: data)
        #expect(decoded.items.first?.texture.rows == -1)

        let cleaned = ClothingShareCodec.sanitizedItems(from: decoded)   // must not trap

        let only = try #require(cleaned.first)
        #expect(only.texture.cols >= 0)
        #expect(only.texture.rows >= 0)
        #expect(only.texture.cols <= ItemSlot.hat.gridCols)
        #expect(only.texture.rows <= ItemSlot.hat.gridRows)
        #expect(only.texture.pixels.count == only.texture.cols * only.texture.rows)
    }
}

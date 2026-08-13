import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Covers the item-editor reprojection that runs whenever an existing item is opened for editing.
///
/// This path is worth real tests because its failure mode is silent and permanent: `save()` re-encodes
/// the texture at the CURRENT slot dimensions, so anything this function gets wrong is written back over
/// the user's art the first time they tap Edit.
@MainActor
struct CreationStudioEditorTests {

    private let palette = ItemDesignPalette.hexes

    private func item(slot: ItemSlot, texture: ItemGridTexture) -> CustomizationItem {
        CustomizationItem(
            name: "test",
            slot: slot,
            texture: texture,
            designer: ItemDesigner(id: UUID())
        )
    }

    /// A texture already at the slot's dimensions must survive untouched — the common case.
    @Test func matchingDimensionsRoundTripExactly() {
        var texture = ItemGridTexture.blank(for: .body, palette: palette)
        texture.pixels[0] = 3
        texture.pixels[texture.pixels.count - 1] = 5
        let mid = (texture.rows / 2) * texture.cols + (texture.cols / 2)
        texture.pixels[mid] = 2

        let result = CreationStudioView.editorPixels(for: item(slot: .body, texture: texture), palette: palette)

        #expect(result == texture.pixels)
    }

    /// Regression: this used to be a 1:1 top-left copy, so a texture drawn at a smaller budget opened
    /// with its art crammed into one corner — and saving made that permanent. A half-size source must
    /// SCALE UP to fill the canvas, not sit in the corner.
    @Test func halfResolutionTextureUpscalesToFillTheCanvas() {
        let slot = ItemSlot.body
        let halfCols = slot.gridCols / 2
        let halfRows = slot.gridRows / 2
        // Every cell painted: if this crops, the bottom-right of the canvas stays transparent.
        let texture = ItemGridTexture(
            cols: halfCols,
            rows: halfRows,
            palette: palette,
            pixels: Array(repeating: 4, count: halfCols * halfRows)
        )

        let result = CreationStudioView.editorPixels(for: item(slot: slot, texture: texture), palette: palette)

        #expect(result.count == slot.gridCols * slot.gridRows)
        #expect(result.allSatisfy { $0 == 4 })
    }

    /// The exact-2× case must be lossless: each source cell maps to a clean 2×2 block.
    @Test func exactDoublingMapsEachSourceCellToATwoByTwoBlock() {
        let slot = ItemSlot.body
        let halfCols = slot.gridCols / 2
        let halfRows = slot.gridRows / 2
        var pixels = Array(repeating: ItemGridTexture.transparent, count: halfCols * halfRows)
        pixels[0] = 1  // top-left source cell only

        let texture = ItemGridTexture(cols: halfCols, rows: halfRows, palette: palette, pixels: pixels)
        let result = CreationStudioView.editorPixels(for: item(slot: slot, texture: texture), palette: palette)

        // Exactly the 2x2 block at the origin is painted...
        #expect(result[0] == 1)
        #expect(result[1] == 1)
        #expect(result[slot.gridCols] == 1)
        #expect(result[slot.gridCols + 1] == 1)
        // ...and its neighbours are not.
        #expect(result[2] == ItemGridTexture.transparent)
        #expect(result[slot.gridCols * 2] == ItemGridTexture.transparent)
        #expect(result.filter { $0 == 1 }.count == 4)
    }

    /// A texture from a NEWER build at a higher budget must down-sample rather than crop, so a friend's
    /// shop item doesn't lose its right/bottom edges on open.
    ///
    /// Asserts survival of the region, not of an individual cell: point-sampling a 2× source reads only
    /// even-indexed cells, so some source cells are legitimately dropped. Cropping is the bug; lossy
    /// resampling is the deal.
    @Test func higherResolutionTextureDownsamplesRatherThanCropping() {
        let slot = ItemSlot.face
        let bigCols = slot.gridCols * 2
        let bigRows = slot.gridRows * 2
        var pixels = Array(repeating: ItemGridTexture.transparent, count: bigCols * bigRows)
        // Paint ONLY the source's right half. A top-left crop keeps the left portion, so it would
        // return an entirely blank canvas; a resample must show paint on the right.
        for y in 0..<bigRows {
            for x in (bigCols / 2)..<bigCols {
                pixels[y * bigCols + x] = 2
            }
        }

        let texture = ItemGridTexture(cols: bigCols, rows: bigRows, palette: palette, pixels: pixels)
        let result = CreationStudioView.editorPixels(for: item(slot: slot, texture: texture), palette: palette)

        #expect(result.count == slot.gridCols * slot.gridRows)
        // Right half painted, left half untouched — i.e. the art was scaled, not cropped.
        for y in 0..<slot.gridRows {
            #expect(result[y * slot.gridCols + slot.gridCols - 1] == 2)
            #expect(result[y * slot.gridCols] == ItemGridTexture.transparent)
        }
    }

    /// Palette remapping must survive the resample — a texture authored against a different palette is
    /// matched by hex, not by index, or the colours silently shuffle.
    @Test func foreignPaletteIsRemappedByHexDuringResample() {
        let slot = ItemSlot.hat
        let foreignPalette = [palette[5], palette[2]]  // index 0 -> palette[5], index 1 -> palette[2]
        let texture = ItemGridTexture(
            cols: slot.gridCols,
            rows: slot.gridRows,
            palette: foreignPalette,
            pixels: Array(repeating: 0, count: slot.gridCols * slot.gridRows)
        )

        let result = CreationStudioView.editorPixels(for: item(slot: slot, texture: texture), palette: palette)

        #expect(result.allSatisfy { $0 == 5 })
    }

    /// A malformed texture must produce a blank canvas rather than crash or index out of bounds.
    @Test func malformedTextureYieldsBlankCanvas() {
        let slot = ItemSlot.body
        let texture = ItemGridTexture(cols: 4, rows: 4, palette: palette, pixels: [1, 2])  // count mismatch

        let result = CreationStudioView.editorPixels(for: item(slot: slot, texture: texture), palette: palette)

        #expect(result.count == slot.gridCols * slot.gridRows)
        #expect(result.allSatisfy { $0 == ItemGridTexture.transparent })
    }

    /// Symmetry mirrors across a clean axis only if every grid is even-width; an odd width would put a
    /// self-mirroring column at the centre and need a special case. This pins that assumption.
    @Test func everySlotGridIsEvenWidthSoTheMirrorAxisIsClean() {
        for slot in ItemSlot.allCases {
            #expect(slot.gridCols % 2 == 0, "\(slot) grid width \(slot.gridCols) must be even for mirror mode")
        }
    }

    /// Regression (#1): the rename-and-retry loop after a `.nameFlagged` / `.capReached` / `.storeBanned`
    /// shop alert keeps the user on the confirmation screen to re-save. The create path must persist the
    /// item under the slot's stable draft id, so a second save upserts the SAME row rather than minting a
    /// new one. Pre-fix `save()` built a fresh random UUID on every call, so the retry added a second row —
    /// against that code this assertion reads `customItems.count == 2` and fails.
    @Test func resavingTheSameDraftUpsertsOneRowRatherThanDuplicating() {
        let store = makeTestStore()
        let view = CreationStudioView(store: store)
        var texture = ItemGridTexture.blank(for: .body, palette: palette)
        texture.pixels[0] = 3

        // First save, then the rename-and-retry re-save — same editor session + slot, so same draft id.
        view.persistDraftItem(named: "sweater", texture: texture, slot: .body)
        view.persistDraftItem(named: "sweater (renamed)", texture: texture, slot: .body)

        #expect(store.customItems.count == 1)
        #expect(store.customItems.first?.name == "sweater (renamed)")
    }

    /// Regression: the retry-dedup fix above originally keyed EVERY create-path save to one per-session
    /// draft id. Reachable in-app: save a body item (a shop alert keeps you in the session — the item IS
    /// persisted), go back, switch slot (a normal action with the per-slot buffers), draw a hat, save.
    /// `CustomItemService.upsert` is a whole-row replace, so the hat overwrote the saved body row under
    /// the shared id — against that code this reads `customItems.count == 1` (the body item silently
    /// destroyed, both ids equal) and fails. Draft ids must be per-slot: a slot-switched save is a
    /// distinct row, while the same-slot retry above still upserts one.
    @Test func savingOnASecondSlotAddsARowInsteadOfReplacingTheFirstSlotsItem() {
        let store = makeTestStore()
        let view = CreationStudioView(store: store)
        var bodyTexture = ItemGridTexture.blank(for: .body, palette: palette)
        bodyTexture.pixels[0] = 3
        var hatTexture = ItemGridTexture.blank(for: .hat, palette: palette)
        hatTexture.pixels[0] = 2

        // Save on slot .body, then — after the in-editor slot switch — save on slot .hat.
        let bodyID = view.persistDraftItem(named: "sweater", texture: bodyTexture, slot: .body)
        let hatID = view.persistDraftItem(named: "cap", texture: hatTexture, slot: .hat)

        // Two rows, distinct ids: the body item survived the hat save.
        #expect(store.customItems.count == 2)
        #expect(bodyID != hatID)
        #expect(store.customItems.contains { $0.id == bodyID && $0.slot == .body && $0.name == "sweater" })
        #expect(store.customItems.contains { $0.id == hatID && $0.slot == .hat && $0.name == "cap" })

        // And per-slot ids keep the same-slot retry an upsert — still two rows, same hat id.
        let hatRetryID = view.persistDraftItem(named: "cap (renamed)", texture: hatTexture, slot: .hat)
        #expect(hatRetryID == hatID)
        #expect(store.customItems.count == 2)
    }

    /// The 2× raise must keep each slot's aspect ratio identical, because the on-body placement derives
    /// an item's height from its stored texture aspect — a changed aspect would move existing art.
    @Test func doubledGridsPreserveTheOriginalAspectRatios() {
        let original: [ItemSlot: (cols: Int, rows: Int)] = [
            .hat: (16, 12),
            .face: (18, 8),
            .body: (24, 20),
            .heldItem: (14, 14),
        ]
        for (slot, dims) in original {
            let originalAspect = Double(dims.cols) / Double(dims.rows)
            let currentAspect = Double(slot.gridCols) / Double(slot.gridRows)
            #expect(abs(originalAspect - currentAspect) < 0.0001, "\(slot) aspect drifted")
        }
    }
}

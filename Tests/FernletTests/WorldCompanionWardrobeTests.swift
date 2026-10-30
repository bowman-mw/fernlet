import CoreGraphics
import Foundation
import Testing
import FernletDomainModel
import FernletScoring
@testable import Fernlet

/// The pixel companion's wardrobe (phone test W-02, W-03 and W-07, approved by the owner 2026-10-25):
/// every pixel against the design session's reference painter, and the rules around it — the look an
/// appearance resolves to, glasses in their colour, the Creation Studio boxes, old pieces shrinking to
/// fit, and a decoy wearing none.
@MainActor
struct WorldCompanionWardrobeTests {

    // MARK: - Every pixel against the reference painter

    /// The 60 reference cases (`Docs/World-Companion-Reference-Grids.txt`, drawn by the design
    /// session's `kit-comp.js`) paint pixel for pixel the same here. A 20 × 22 case is the body and
    /// leaves the rest of the frame clear; a 24 × 24 case is the whole item frame.
    @Test func everyReferenceCasePaintsPixelForPixel() throws {
        let reference = try Self.referenceGrids()
        #expect(reference.count == Self.cases.count, "the fixture has \(reference.count) cases, the test \(Self.cases.count)")
        for grid in reference {
            let input = try #require(Self.cases[grid.name], "no input for reference case \(grid.name)")
            let painted = WorldCompanionPainter.paint(state: input.state, look: input.look, pose: input.pose,
                                                      increasedContrast: input.increasedContrast)
            let frame = grid.width == WorldCompanionGrid.frameWidth
            var misses: [String] = []
            for y in 0..<WorldCompanionGrid.frameHeight {
                for x in 0..<WorldCompanionGrid.frameWidth {
                    let (rx, ry) = frame ? (x, y) : (x - WorldCompanionGrid.frameX, y - WorldCompanionGrid.frameY)
                    let expected = grid.color(x: rx, y: ry)
                    let actual = painted.frameColor(x: x, y: y)
                    if expected != actual { misses.append("(\(rx),\(ry)) want \(Self.hex(expected)) got \(Self.hex(actual))") }
                }
            }
            #expect(misses.isEmpty, "\(grid.name): \(misses.count) pixels differ, first \(misses.prefix(4))")
        }
    }

    // MARK: - The look an appearance resolves to

    /// Every built-in piece now draws (W-02): the shapes, the flower, the cap and the side items.
    @Test func theAppearanceDressesTheWholeBuiltInWardrobe() {
        var appearance = CompanionAppearance()
        appearance.bodyStyle = .puddle
        appearance.accessory = .flower
        appearance.clothing = .sleepCap
        appearance.sideItem = .mug
        let look = WorldCompanionLook(appearance: appearance, state: .okay, asleep: false)
        #expect(look.shape == .puddle && look.topper == .flower && look.side == .mug)
        #expect(look.cap != nil && look.scarf == nil, "the cap and the scarf share the clothing slot")
        for (style, shape) in [(CompanionBodyStyle.circle, WorldCompanionShape.circle), (.softBlob, .soft), (.pear, .pear)] {
            appearance.bodyStyle = style
            #expect(WorldCompanionLook(appearance: appearance, state: .okay, asleep: false).shape == shape)
        }
        for (item, side) in [(CompanionSideItem.none, WorldCompanionSide.none), (.waterBottle, .bottle), (.book, .book), (.dumbbell, .dumbbell)] {
            appearance.sideItem = item
            #expect(WorldCompanionLook(appearance: appearance, state: .okay, asleep: false).side == side)
        }
    }

    /// The slots that follow the state: the cap in night blue, the scarf in red, a side item in bark,
    /// and an accessory left on Fern keeps the sprout's fern, the flower's rose and the glasses' ink.
    @Test func slotsThatFollowTheStateTakeTheDesignsColours() {
        var appearance = CompanionAppearance()
        appearance.clothing = .sleepCap
        appearance.clothingColor = .state
        appearance.sideItem = .book
        appearance.sideItemColor = .state
        let look = WorldCompanionLook(appearance: appearance, state: .tired, asleep: false)
        #expect(look.cap == WorldCompanionLook.capBlue)
        #expect(look.sideColor == WorldCompanionLook.bark)
        #expect(look.topperColor == nil, "an accessory left on Fern has no colour of its own")
        appearance.clothing = .scarf
        #expect(WorldCompanionLook(appearance: appearance, state: .tired, asleep: false).scarf == WorldCompanionLook.scarfRed)
        appearance.accessoryCustomColorHex = "#123456"
        #expect(WorldCompanionLook(appearance: appearance, state: .tired, asleep: false).topperColor == 0x123456)
    }

    /// W-03: the glasses take the accessory colour, 30 % toward ink, 50 % for a light colour, ink when
    /// left on Fern; and they come off whenever the eyes close.
    @Test func theGlassesTakeTheirColourTowardInk() {
        let ink = WorldCompanionPainter.ink
        #expect(WorldCompanionPainter.glassesColor(nil) == ink)
        #expect(WorldCompanionPainter.glassesColor(0xB67073) == WorldCompanionPainter.mix(0xB67073, ink, 0.3))
        #expect(WorldCompanionPainter.glassesColor(0xEBB551) == WorldCompanionPainter.mix(0xEBB551, ink, 0.5), "Sun is light")
        #expect(WorldCompanionPainter.glassesColor(0xF3E6CB) == WorldCompanionPainter.mix(0xF3E6CB, ink, 0.5), "Cream is light")
        #expect(WorldCompanionPainter.luminance(0x72A364) < 0.62 && WorldCompanionPainter.luminance(0xEBB551) > 0.62)
        let look = WorldCompanionLook(body: 0x5E844D, topper: .glasses, topperColor: 0xB67073)
        let rose = WorldCompanionPainter.glassesColor(0xB67073)
        #expect(WorldCompanionPainter.paint(state: .okay, look: look, pose: WorldCompanionPose()).cells.contains(rose))
        #expect(!WorldCompanionPainter.paint(state: .okay, look: look, pose: WorldCompanionPose(drowsy: true)).cells.contains(rose))
    }

    /// Increase Contrast darkens only the outline (75 % toward the shade instead of 55 %).
    @Test func increaseContrastDarkensTheOutline() {
        let look = WorldCompanionLook(body: 0xD2973B)
        let plain = WorldCompanionPainter.paint(state: .okay, look: look, pose: WorldCompanionPose())
        let strong = WorldCompanionPainter.paint(state: .okay, look: look, pose: WorldCompanionPose(), increasedContrast: true)
        #expect(plain.color(x: 3, y: 12) == WorldCompanionPainter.mix(0xD2973B, WorldCompanionPainter.shade, 0.55))
        #expect(strong.color(x: 3, y: 12) == WorldCompanionPainter.mix(0xD2973B, WorldCompanionPainter.shade, 0.75))
        #expect(plain.color(x: 10, y: 12) == strong.color(x: 10, y: 12), "only the outline changes")
    }

    /// The one-colour widgets cut the face out: eyes, mouth, blush and the glasses, whatever their
    /// colour. The cap and a side item are worn pieces, which keep their shape in the one colour
    /// (phone test W-11; the rest of the rule is `WorldCompanionOneColourTests`).
    @Test func theFaceIsMarkedForTheOneColourCutOut() {
        let look = WorldCompanionLook(body: 0x5E844D, topper: .glasses, topperColor: 0x71808C, cap: 0xB67073, side: .mug)
        let grid = WorldCompanionPainter.paint(state: .thriving, look: look, pose: WorldCompanionPose())
        let frameX = WorldCompanionGrid.frameX, frameY = WorldCompanionGrid.frameY
        #expect(grid.isFace(frameX: 7 + frameX, y: 12 + frameY), "the eye")
        #expect(grid.isFace(frameX: 9 + frameX, y: 12 + frameY), "the glasses' bridge")
        #expect(!grid.takesOneColour(frameX: 7 + frameX, y: 12 + frameY) && !grid.takesOneColour(frameX: 9 + frameX, y: 12 + frameY))
        #expect(grid.piece(frameX: 10 + frameX, y: 7 + frameY) == .cap && grid.takesOneColour(frameX: 10 + frameX, y: 7 + frameY),
                "the cap")
        #expect(grid.piece(frameX: 14 + frameX, y: 15 + frameY) == .side && grid.takesOneColour(frameX: 14 + frameX, y: 15 + frameY),
                "the mug")
    }

    // MARK: - Creation Studio pieces (W-07, draft 2)

    /// The four boxes, in body coordinates, inside the 24 × 24 frame; every canvas is even-width.
    @Test func theBoxesAreTheApprovedOnes() {
        let expected: [ItemSlot: WorldItemBox.Box] = [
            .hat: .init(x: 1, y: -1, width: 18, height: 11), .face: .init(x: 2, y: 9, width: 16, height: 8),
            .body: .init(x: 1, y: 10, width: 18, height: 13), .heldItem: .init(x: 12, y: 10, width: 10, height: 12),
        ]
        for slot in ItemSlot.allCases {
            let box = WorldItemBox.box(for: slot)
            #expect(box == expected[slot], "\(slot)")
            #expect(box.x >= -WorldCompanionGrid.frameX && box.y >= -WorldCompanionGrid.frameY)
            #expect(box.x + box.width <= WorldCompanionGrid.frameWidth - WorldCompanionGrid.frameX, "\(slot) leaves the frame")
            #expect(box.y + box.height <= WorldCompanionGrid.frameHeight - WorldCompanionGrid.frameY, "\(slot) leaves the frame")
            #expect(box.width % 2 == 0, "\(slot)'s canvas must be even-width for Mirror")
            #expect(CreationStudioView.canvasSize(for: slot) == (box.width, box.height))
        }
    }

    /// A piece drawn at its box's size wears 1:1 at the box's corner.
    @Test func aNewPieceWearsOneToOne() {
        let texture = Self.texture(cols: 18, rows: 11) { x, y in (x + y) % 3 == 0 ? 1 : -1 }
        let fitted = WorldItemBox.fit(texture, slot: .hat)
        #expect(fitted == WorldItemBox.Fitted(x: 1, y: -1, width: 18, height: 11, indices: texture.pixels))
    }

    /// A piece drawn on the old, bigger canvas shrinks to fit with one scale for both axes: a hat sits
    /// on the box's bottom edge, an outfit on its top, a face and a held item in the middle.
    @Test func anOldPieceShrinksToFitItsBox() {
        let hat = WorldItemBox.fit(Self.texture(cols: 32, rows: 24) { _, _ in 2 }, slot: .hat)
        #expect((hat.width, hat.height) == (15, 11))
        #expect((hat.x, hat.y) == (2, -1), "centred across, on the bottom edge")
        #expect(hat.indices.allSatisfy { $0 == 2 })
        let outfit = WorldItemBox.fit(Self.texture(cols: 48, rows: 40) { _, _ in 1 }, slot: .body)
        #expect((outfit.width, outfit.height, outfit.x, outfit.y) == (16, 13, 2, 10))
        let face = WorldItemBox.fit(Self.texture(cols: 36, rows: 16) { _, _ in 1 }, slot: .face)
        #expect((face.width, face.height, face.x, face.y) == (16, 7, 2, 9))
        let held = WorldItemBox.fit(Self.texture(cols: 28, rows: 28) { _, _ in 1 }, slot: .heldItem)
        #expect((held.width, held.height, held.x, held.y) == (10, 10, 12, 11))
    }

    /// Shrinking keeps a square painted where at least a third of what it covers is painted, in the
    /// most common colour, so thin lines survive and stray dots do not.
    @Test func shrinkingKeepsTheMostCommonColourOfEachBlock() {
        // A 4 × 2 source to 2 × 1: the left block has 3 of 4 painted (2, 2, 3), the right 1 of 4.
        let texture = ItemGridTexture(cols: 4, rows: 2, palette: ItemDesignPalette.hexes, pixels: [2, 3, 5, -1, 2, -1, -1, -1])
        #expect(WorldItemBox.shrink(texture, toWidth: 2, height: 1) == [2, -1])
        let third = ItemGridTexture(cols: 3, rows: 1, palette: ItemDesignPalette.hexes, pixels: [-1, 4, -1])
        #expect(WorldItemBox.shrink(third, toWidth: 1, height: 1) == [4], "one in three is enough")
    }

    /// A worn hat covers the head (the sprout steps aside); worn pieces paint in the full companion's
    /// order, and a piece with nothing painted draws nothing.
    @Test func wornPiecesPaintInOrderAndAHatCoversTheHead() {
        let hat = Self.item(.hat, cols: 18, rows: 11) { x, y in y == 9 && x > 0 && x < 17 ? 0 : -1 }
        let outfit = Self.item(.body, cols: 18, rows: 13) { _, y in y == 5 ? 11 : -1 }
        let blank = Self.item(.face, cols: 16, rows: 8) { _, _ in -1 }
        let art = WorldItemBox.art(for: [hat, blank, outfit])
        #expect(art.map(\.coversHead) == [false, true], "the outfit first, then the hat; the blank face piece draws nothing")
        let look = WorldCompanionLook(body: 0x5E844D, items: art)
        let grid = WorldCompanionPainter.paint(state: .thriving, look: look, pose: WorldCompanionPose())
        #expect(grid.color(x: 10, y: 5) == nil, "the sprout's stem is gone under the hat")
        #expect(grid.color(x: 5, y: 8) == 0x2E2A24, "the hat's brim, in the Studio's near-black")
    }

    /// The editor opens a piece exactly as the companion wears it: a box-sized one 1:1, an old one
    /// shrunk and placed as the map places it (so the first save keeps what the person saw).
    @Test func theEditorOpensAPieceAsTheCompanionWearsIt() {
        let palette = ItemDesignPalette.hexes
        let new = Self.item(.face, cols: 16, rows: 8) { x, _ in x % 2 }
        #expect(CreationStudioView.editorPixels(for: new, palette: palette) == new.texture.pixels)
        let old = Self.item(.hat, cols: 32, rows: 24) { _, _ in 6 }
        let opened = CreationStudioView.editorPixels(for: old, palette: palette)
        #expect(opened.count == 18 * 11)
        for y in 0..<11 {
            for x in 0..<18 {
                let inside = x >= 1 && x < 16
                #expect(opened[y * 18 + x] == (inside ? 6 : ItemGridTexture.transparent), "(\(x), \(y))")
            }
        }
    }

    // MARK: - Who wears what

    /// A decoy session draws the decoy companion only: no Creation Studio pieces, on the map, in
    /// Customize or in the widget.
    @Test func aDecoyWearsNoPieces() {
        let store = makeTestStore()
        let piece = Self.item(.hat, cols: 18, rows: 11) { _, y in y == 10 ? 0 : -1 }
        store.saveCustomItem(piece)
        store.equipCustomItem(id: piece.id, slot: .hat)
        #expect(store.wornCustomItems.map(\.id) == [piece.id])
        #expect(store.widgetCompanionLook.items?.count == 1)
        #expect(WorldCompanionLook.current(store: store, at: Date()).look.items.count == 1)
        store.duressSessionActive = true
        #expect(store.wornCustomItems.isEmpty)
        #expect(store.widgetCompanionLook.items == nil)
        #expect(WorldCompanionLook.current(store: store, at: Date(), items: [piece]).look.items.isEmpty)
        store.duressSessionActive = false
    }

    /// The widget carries the cap, the side item and the pieces in their place (W-02, W-07), and a
    /// look without them encodes as before.
    @Test func theWidgetCarriesTheWholeWardrobe() {
        var appearance = CompanionAppearance()
        let bare = WidgetSnapshot.CompanionLook(appearance: appearance)
        #expect(bare.capColorHex == nil && bare.sideItemRaw == nil && bare.items == nil, "nothing new to carry")
        appearance.clothing = .sleepCap
        appearance.clothingColor = .state
        appearance.sideItem = .waterBottle
        let piece = Self.item(.heldItem, cols: 10, rows: 12) { x, _ in x == 4 ? 14 : -1 }
        let look = WidgetSnapshot.CompanionLook(appearance: appearance, items: [piece])
        #expect(look.capColorHex == "#6E86B0")
        #expect(look.sideItemRaw == "waterBottle")
        let art = look.items?.first
        #expect(art?.x == 12 && art?.y == 10 && art?.width == 10 && art?.height == 12 && art?.coversHead == false)
        #expect(art?.palette[14] == "#C0392B")
    }

    // MARK: - One picture of the companion (W-06a)

    /// The map, the close-up and the Today card keep the map's night; Customize keeps the bedtime
    /// only; the Studio, Save item and a peek are awake.
    @Test func eachPictureKeepsItsNight() {
        let map = WorldCompanionLook.pose(emotion: nil, night: .map, mapNight: true)
        #expect(map.drowsy && !map.asleep)
        #expect(!WorldCompanionLook.pose(emotion: nil, night: .bedtime, mapNight: true).drowsy, "Customize is awake until bedtime")
        #expect(WorldCompanionLook.pose(emotion: .sleepy, night: .bedtime, mapNight: false).drowsy)
        let asleep = CompanionEmotion.allCases.first { $0.hidesTheDay }
        #expect(WorldCompanionLook.pose(emotion: asleep, night: .bedtime, mapNight: false).asleep)
        #expect(WorldCompanionLook.pose(emotion: asleep, night: .awake, mapNight: true) == WorldCompanionPose())
    }

    /// Every World picture reads the one helper with the live state (a friend's gold heart lifts it).
    @Test func everyPictureReadsTheSharedHelper() throws {
        // Round 7: the close-up retired; page 1 of Sprout's passport is the big picture now.
        let sources = ["App/Fernlet/World/Home/WorldMapCompanion.swift", "App/Fernlet/World/Passport/Sprout/PassportSproutPage.swift",
                       "App/Fernlet/World/Today/TodayCards.swift", "App/Fernlet/World/Customize/CustomizePreviews.swift",
                       "App/Fernlet/World/Customize/CreationStudioPixelPieces.swift"]
        for path in sources {
            let source = try RepoRoot.source(path)
            #expect(source.contains("WorldCompanionLook.current(store: store"), "\(path) draws its own companion")
            #expect(!source.contains("store.companionState"), "\(path) reads the saved state, not the live one")
        }
        let helper = try RepoRoot.source("App/Fernlet/World/Companion/WorldCompanionNow.swift")
        #expect(helper.contains("let state = store.liveCompanionState"))
    }

    /// W-06b: no vector companion anywhere in the World's Customize, Studio or Save item.
    @Test func noVectorCompanionInTheWorldsCustomizeStack() throws {
        for path in ["App/Fernlet/CreationStudioView.swift", "App/Fernlet/CompanionCustomizationSheet.swift",
                     "App/Fernlet/World/Customize/CustomizePieces.swift", "App/Fernlet/World/Customize/CustomizePreviews.swift"] {
            #expect(!(try RepoRoot.source(path)).contains("CompanionView("), "\(path) still draws the vector companion")
        }
    }

    // MARK: - Words

    /// Customize's night note says what sleep changes tonight, with the bedtime as the clock shows it.
    @Test func theNightNoteSaysWhatSleepChanges() {
        let en = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let bedtime = CustomizeNightCopy.bedtime(.standard, calendar: calendar, locale: en)
        #expect(bedtime == "10:30\u{202F}PM" || bedtime == "10:30 PM")
        let full = CustomizeNightCopy.note(name: "Sprout", bedtime: "10:30 PM", glassesOff: true, moodRests: true)
        #expect(full == "Sprout's asleep, as on the map (bedtime 10:30 PM). Its glasses are off and its mood color rests until morning.")
        #expect(CustomizeNightCopy.note(name: "Sprout", bedtime: "10:30 PM", glassesOff: false, moodRests: false)
                    == "Sprout's asleep, as on the map (bedtime 10:30 PM).")
        #expect(CustomizeNightCopy.glassesLine(name: "Sprout") == "Glasses come off while Sprout sleeps. Hold to peek at them.")
    }

    /// Save item's note is the approved one, with the companion's name.
    @Test func saveItemsNoteIsTheApprovedOne() {
        #expect(StudioCopy.saveNote(name: "Sprout") == "Your drawing is the size it shows on Sprout: one square, one pixel, on the map and up close. Items made before, or bought from friends on the old Fernlet, are shrunk to fit automatically.")
        #expect(StudioCopy.size(slot: .hat, cols: 18, rows: 11) == "Hat · 18 × 11")
    }

    /// The Studio's canvas shows the companion faintly where the drawing leaves a square clear.
    @Test func theCanvasShowsTheCompanionFaintlyUnderTheDrawing() throws {
        let look = WorldCompanionLook(body: 0x5E844D, topper: .none)
        let grid = WorldCompanionPainter.paint(state: .thriving, look: look, pose: WorldCompanionPose())
        let ghost = StudioGhost.cells(of: grid, in: WorldItemBox.box(for: .hat))
        #expect(ghost.count == 18 * 11)
        #expect(ghost[10 * 18 + 9] != nil, "the head's top shows in the hat's bottom row")
        #expect(ghost[0] == nil)
        let texture = ItemGridTexture(cols: 18, rows: 11, palette: ItemDesignPalette.hexes,
                                      pixels: [0] + Array(repeating: -1, count: 18 * 11 - 1))
        let image = try #require(StudioCanvasImage.image(for: texture, ghost: ghost))
        #expect(image.width == 18 && image.height == 11)
    }

    // MARK: - Helpers

    /// One reference case's inputs.
    struct Case {
        let state: CompanionState
        let look: WorldCompanionLook
        var pose = WorldCompanionPose()
        var increasedContrast = false
    }

    /// A parsed reference grid.
    struct ReferenceGrid {
        let name: String
        let width: Int
        let height: Int
        let rows: [[UInt32?]]

        func color(x: Int, y: Int) -> UInt32? {
            guard y >= 0, y < rows.count, x >= 0, x < rows[y].count else { return nil }
            return rows[y][x]
        }
    }

    static func referenceGrids() throws -> [ReferenceGrid] {
        let lines = try RepoRoot.source("Docs/World-Companion-Reference-Grids.txt").components(separatedBy: "\n")
        var grids: [ReferenceGrid] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard line.hasPrefix("## ") else { continue }
            let parts = line.dropFirst(3).split(separator: " ")
            let size = parts[1].split(separator: "x").compactMap { Int($0) }
            var palette: [Character: UInt32] = [:]
            for entry in lines[index].dropFirst("palette ".count).split(separator: " ") {
                let pair = entry.split(separator: "=")
                if pair.count == 2, let key = pair[0].first { palette[key] = UInt32(pair[1], radix: 16) }
            }
            let rows = lines[(index + 1)..<(index + 1 + size[1])].map { row in row.map { palette[$0] } }
            grids.append(ReferenceGrid(name: String(parts[0]), width: size[0], height: size[1], rows: Array(rows)))
            index += 1 + size[1]
        }
        return grids
    }

    static func hex(_ value: UInt32?) -> String { value.map { String(format: "%06X", $0) } ?? "clear" }

    static func texture(cols: Int, rows: Int, _ paint: (Int, Int) -> Int) -> ItemGridTexture {
        var pixels: [Int] = []
        for y in 0..<rows { for x in 0..<cols { pixels.append(paint(x, y)) } }
        return ItemGridTexture(cols: cols, rows: rows, palette: ItemDesignPalette.hexes, pixels: pixels)
    }

    static func item(_ slot: ItemSlot, cols: Int, rows: Int, _ paint: (Int, Int) -> Int) -> CustomizationItem {
        CustomizationItem(name: "piece", slot: slot, texture: texture(cols: cols, rows: rows, paint), designer: ItemDesigner(id: UUID()))
    }

    /// A reference piece: its rows and palette at body (x, y).
    nonisolated static func art(_ x: Int, _ y: Int, _ rows: [String], _ palette: [Character: UInt32], hat: Bool = false) -> WorldCompanionItemArt {
        let width = rows.first?.count ?? 0
        let cells: [UInt32?] = rows.flatMap { row in row.map { palette[$0] } }
        return WorldCompanionItemArt(x: x, y: y, width: width, height: rows.count, cells: cells, coversHead: hat)
    }
}

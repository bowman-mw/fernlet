import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The companion in one colour (phone test W-11, approved 2026-10-26) and a feeling's bubble beside a worn
/// piece (Refinements group 16, approved 2026-10-26), pinned through the app's painter, whose twin the
/// widget copies word for word: every reference mask and bubble spot against the design session's
/// reference painter (`Docs/World-Companion-OneColour-Grids.txt`), the spec's list piece by piece, the
/// placements and the fallback, and the widget's wiring in its own sources (the extension has no test
/// target).
@MainActor
struct WorldCompanionOneColourTests {
    nonisolated private static let slate: UInt32 = 0x71808C, clay: UInt32 = 0xB8543D, moss: UInt32 = 0x5E844D
    private static let frameX = WorldCompanionGrid.frameX, frameY = WorldCompanionGrid.frameY

    /// The hungry bubble and the happy twinkle, row for row as `WidgetFeelingSprites` draws them.
    static let apple = [".kkkkkkk.", "kwwwwgwwk", "kwwwgwwwk", "kwwrrrwwk", "kwrrhrrwk", "kwrrrrrwk", "kwrrrrrwk", "kwwrrrwwk",
                        ".kkkkkkk.", ".k.......", "k........"]
    static let twinkle = ["...y...", "...y...", "..yhy..", "yyhhhyy", "..yhy..", "...y...", "...y..."]

    // MARK: - Every cell against the reference painter

    /// The reference cases (`tint()` and the lane's placement rule in the mockup) mask cell for cell the
    /// same here, and put the bubble and the twinkle in the same spot.
    @Test func everyReferenceCaseMasksCellForCell() throws {
        let reference = try Self.referenceMasks()
        #expect(reference.count == 37, "the fixture has \(reference.count) cases")
        for mask in reference {
            let input = try #require(Self.cases[mask.name], "no input for reference case \(mask.name)")
            let grid = WorldCompanionPainter.paint(state: input.state, look: input.look, pose: WorldCompanionPose())
            var misses: [String] = []
            for y in 0..<WorldCompanionGrid.frameHeight {
                for x in 0..<WorldCompanionGrid.frameWidth where grid.takesOneColour(frameX: x, y: y) != mask.tinted(x, y) {
                    misses.append("(\(x),\(y)) want \(mask.tinted(x, y) ? "#" : ".")")
                }
            }
            #expect(misses.isEmpty, "\(mask.name): \(misses.count) cells differ, first \(misses.prefix(4))")
            #expect(Self.spot(Self.apple, on: grid, movable: true) == mask.apple, "\(mask.name)'s bubble")
            #expect(Self.spot(Self.twinkle, on: grid, movable: false) == mask.twinkle, "\(mask.name)'s twinkle")
        }
    }

    // MARK: - The spec's list

    /// The scarf keeps its whole shape; the body's rows above and below it are cut, except next to the
    /// mouth, where a line would run into the face.
    @Test func theScarfsRowsAboveAndBelowAreCutButNextToTheMouth() {
        let grid = Self.paint(WorldCompanionLook(body: Self.state(.okay), scarf: WorldCompanionLook.scarfRed))
        let scarf = Self.cells(of: grid) { $0 == .scarf }
        #expect(scarf.count >= 12 && scarf.allSatisfy { grid.takesOneColour(frameX: $0.0, y: $0.1) }, "the scarf in one colour")
        var kept = 0, cut = 0
        for (x, y) in Self.cells(of: grid, { $0 == .body }) where Self.besides(grid, x, y, { $0 == .scarf }) {
            let near = Self.nearCutOut(grid, x, y)
            #expect(grid.takesOneColour(frameX: x, y: y) == near, "(\(x),\(y))")
            if near { kept += 1 } else { cut += 1 }
        }
        #expect(cut >= 16, "the lines above and below")
        #expect(kept >= 2, "the cells beside the mouth stay filled")
    }

    /// The cap's brim has a cut row under it, the brim itself in one colour.
    @Test func theCapsBrimHasACutRowUnderIt() {
        let look = WorldCompanionLook(body: Self.state(.okay), cap: WorldCompanionLook.capBlue)
        let grid = Self.paint(look)
        let body = WorldCompanionBody(state: .okay, shape: .circle, color: look.body, pose: WorldCompanionPose(), increasedContrast: false)
        let brim = body.top + 1 + Self.frameY
        var under = 0
        for x in 0..<WorldCompanionGrid.frameWidth where grid.piece(frameX: x, y: brim) == .cap {
            #expect(grid.takesOneColour(frameX: x, y: brim), "the brim at \(x)")
            guard grid.piece(frameX: x, y: brim + 1) == .body else { continue }
            under += 1
            #expect(!grid.takesOneColour(frameX: x, y: brim + 1), "the row under the brim at \(x)")
        }
        #expect(under >= 8)
    }

    /// A side item keeps its shape and has a cut ring where it meets the body.
    @Test func aSideItemHasACutRingWhereItMeetsTheBody() {
        for side in [WorldCompanionSide.bottle, .mug, .book, .dumbbell] {
            let grid = Self.paint(WorldCompanionLook(body: Self.state(.okay), side: side, sideColor: Self.slate))
            #expect(Self.cells(of: grid) { $0 == .side }.allSatisfy { grid.takesOneColour(frameX: $0.0, y: $0.1) }, "\(side)")
            var ring = 0
            for (x, y) in Self.cells(of: grid, { $0 == .body }) where Self.besides(grid, x, y, { $0 == .side }) {
                #expect(grid.takesOneColour(frameX: x, y: y) == Self.nearCutOut(grid, x, y), "\(side) at (\(x),\(y))")
                ring += 1
            }
            #expect(ring >= 3, "\(side) meets the body")
        }
    }

    /// The glasses cut out their frames and the eyes behind them, as approved in draft 2.
    @Test func theGlassesCutOutTheFramesAndTheEyes() {
        let grid = Self.paint(WorldCompanionLook(body: Self.state(.okay), topper: .glasses, topperColor: Self.slate))
        let cut = Self.cells(of: grid) { $0 == .glasses || $0 == .eye }
        #expect(cut.count == 26, "22 frame cells and the two eyes' 4, not \(cut.count)")
        #expect(cut.allSatisfy { !grid.takesOneColour(frameX: $0.0, y: $0.1) })
        #expect(cut.allSatisfy { grid.isFace(frameX: $0.0, y: $0.1) }, "the glasses are part of the face")
    }

    /// The flower keeps its centre as a 1-cell cut-out; the petals and the stem stay joined to the head.
    @Test func theFlowersCentreIsCutOut() {
        let grid = Self.paint(WorldCompanionLook(body: Self.state(.okay), topper: .flower))
        let centre = Self.cells(of: grid) { $0 == .flowerCentre }
        #expect(centre.count == 1 && centre.allSatisfy { !grid.takesOneColour(frameX: $0.0, y: $0.1) })
        #expect(Self.cells(of: grid) { $0 == .flower }.allSatisfy { grid.takesOneColour(frameX: $0.0, y: $0.1) })
        #expect(Self.cells(of: grid) { $0 == .body }.allSatisfy { grid.takesOneColour(frameX: $0.0, y: $0.1) },
                "no cut under the stem; the bare body is whole")
    }

    /// The pieces each painter records, and the ranks the rule reads.
    @Test func eachCellRecordsThePieceThatPaintedIt() {
        let look = WorldCompanionLook(body: Self.moss, topper: .glasses, topperColor: Self.slate, cap: Self.clay, side: .mug,
                                      items: [WorldCompanionWardrobeTests.balloon])
        let grid = WorldCompanionPainter.paint(state: .thriving, look: look, pose: WorldCompanionPose())
        #expect(grid.piece(frameX: 7 + Self.frameX, y: 12 + Self.frameY) == .eye)
        #expect(grid.piece(frameX: 9 + Self.frameX, y: 12 + Self.frameY) == .glasses, "the glasses' bridge")
        #expect(grid.piece(frameX: 10 + Self.frameX, y: 7 + Self.frameY) == .cap)
        #expect(grid.piece(frameX: 14 + Self.frameX, y: 15 + Self.frameY) == .side, "the mug")
        #expect(grid.piece(frameX: 18 + Self.frameX, y: 10 + Self.frameY) == .studio(0), "the balloon")
        #expect(grid.piece(frameX: 0, y: 0) == nil && !grid.takesOneColour(frameX: 0, y: 0), "holes stay open")
        let ranks: [(WorldCompanionPiece, Int?)] = [(.body, 0), (.sprout, 0), (.flower, 0), (.scarf, 2), (.cap, 3), (.studio(0), 4),
                                                   (.studio(3), 7), (.side, 9), (.eye, nil), (.glasses, nil), (.flowerCentre, nil)]
        for (piece, rank) in ranks { #expect(piece.rank == rank, "\(piece)") }
        #expect(!WorldCompanionPiece.body.isWorn && !WorldCompanionPiece.tear.isWorn && WorldCompanionPiece.sprout.isWorn
                    && WorldCompanionPiece.glasses.isWorn)
    }

    // MARK: - The bubble beside a worn piece (group 16)

    /// The sleep cap's pompom sends the bubble left: 4 pixels out on Circle, 5 on Soft, 3 on Pear and
    /// Puddle; the wizard hat, 6.
    @Test func aWornPieceInTheCornerSendsTheBubbleLeft() {
        let capped: [(WorldCompanionShape, Int)] = [(.circle, -4), (.soft, -5), (.pear, -3), (.puddle, -3)]
        for (shape, x) in capped {
            let grid = Self.paint(WorldCompanionLook(body: Self.state(.okay), shape: shape, topper: .sprout,
                                                     cap: WorldCompanionLook.capBlue, side: .book, sideColor: Self.moss))
            let placement = WorldCompanionMotifPlacement(rows: Self.apple, on: grid, movable: true, oneColour: false)
            #expect(placement.spot == .topLeft && placement.x == x, "\(shape): \(placement.spot) \(placement.x)")
            #expect(placement.rows == Self.apple.map { String($0.reversed()) }, "mirrored, its tail toward the head")
            #expect(!grid.touches(placement.rows, frameX: placement.x, y: 0, wornOnly: false))
        }
        let wizard = Self.paint(WorldCompanionLook(body: Self.state(.okay), topper: .none, items: [WorldCompanionWardrobeTests.wizard]))
        #expect(Self.spot(Self.apple, on: wizard, movable: true) == "left -6")
    }

    /// Bare shapes, glasses, the scarf, side items and a held balloon keep the bubble where it was; the
    /// twinkle never moves.
    @Test func everythingElseKeepsTheSpot() {
        let looks = [WorldCompanionLook(body: Self.state(.okay), topper: .none), WorldCompanionLook(body: Self.state(.okay)),
                     WorldCompanionLook(body: Self.state(.okay), topper: .glasses), WorldCompanionLook(body: Self.state(.okay), topper: .flower),
                     WorldCompanionLook(body: Self.state(.okay), scarf: WorldCompanionLook.scarfRed),
                     WorldCompanionLook(body: Self.state(.okay), side: .dumbbell), WorldCompanionLook(body: Self.state(.okay), side: .mug),
                     WorldCompanionLook(body: Self.state(.okay), items: [WorldCompanionWardrobeTests.balloon])]
        for shape in [WorldCompanionShape.circle, .soft, .pear, .puddle] {
            for var look in looks {
                look.shape = shape
                #expect(Self.spot(Self.apple, on: Self.paint(look), movable: true) == "today 18", "\(shape) \(look.topper) \(look.side)")
            }
        }
        let capped = Self.paint(WorldCompanionLook(body: Self.state(.okay), cap: WorldCompanionLook.capBlue))
        #expect(Self.spot(Self.twinkle, on: capped, movable: false) == "today 20", "the twinkle stays put")
    }

    /// The fallback: a hat wide enough to fill both top corners keeps the bubble top right, behind it.
    /// Painted cells hide it (the face's cut-outs too); in one colour, so do the cells beside them.
    @Test func aHatFillingBothCornersPutsTheBubbleBehind() {
        let wide = WorldCompanionWardrobeTests.art(-2, -1, [String(repeating: "k", count: 24), String(repeating: "k", count: 24),
                                                            "kk" + String(repeating: ".", count: 20) + "kk"], ["k": 0x2A1A10], hat: true)
        let grid = Self.paint(WorldCompanionLook(body: Self.state(.okay), items: [wide]))
        for oneColour in [false, true] {
            let placement = WorldCompanionMotifPlacement(rows: Self.apple, on: grid, movable: true, oneColour: oneColour)
            #expect(placement.spot == .behind && placement.x == 18)
            var drawn = 0, dropped = 0
            for (j, row) in placement.rows.enumerated() {
                for (i, key) in row.enumerated() {
                    let original = Array(Self.apple[j])[i]
                    guard key != "." else { dropped += original == "." ? 0 : 1; continue }
                    drawn += 1
                    #expect(key == original)
                    let hidden = oneColour ? grid.touchesCell(frameX: 18 + i, y: j, wornOnly: false) : grid.frameColor(x: 18 + i, y: j) != nil
                    #expect(!hidden, "(\(i),\(j)) shows through the companion")
                }
            }
            #expect(drawn > 20 && dropped > 10, "one colour \(oneColour): \(drawn) drawn, \(dropped) hidden")
        }
    }

    // MARK: - The widget's wiring

    /// The silhouette draws the twin's rule; the small card makes room for a left bubble and the medium
    /// card and the map don't; the motif draws the placement's rows, so behind masks by painted cells.
    @Test func theWidgetDrawsTheRuleAndThePlacement() throws {
        let sprite = try RepoRoot.source("App/FernletWidgets/WidgetPixelCompanion.swift")
        #expect(sprite.contains("case .silhouette(let hex): return grid.takesOneColour(frameX: x, y: y) ? hex : nil"))
        #expect(sprite.contains("WidgetCompanionMotifPlacement(rows: motif.sprite.rows, on: grid, movable: motif != .twinkle,"))
        #expect(sprite.contains("oneColour: ink != .color)"))
        #expect(sprite.contains("WidgetSpriteView(sprite: WidgetSprite(rows: placement.rows, palette: motif.sprite.palette)"))
        #expect(sprite.contains(".offset(x: CGFloat(placement.x) * scale, y: 0)"))
        #expect(sprite.contains("guard makesRoomForALeftMotif, let placement, placement.spot == .topLeft else { return 0 }"))
        let painter = try RepoRoot.source("App/Fernlet/World/Companion/WorldCompanionPainter.swift")
        #expect(painter.contains(": grid.frameColor(x: right + i, y: j) != nil"), "behind, every painted cell hides the bubble's")
        let cards = try RepoRoot.source("App/FernletWidgets/CompanionWidgetViews.swift")
        let small = try #require(cards.components(separatedBy: "struct CompanionSmallView: View {").dropFirst().first?
            .components(separatedBy: "\n}\n").first)
        let medium = try #require(cards.components(separatedBy: "struct CompanionThoughtView: View {").dropFirst().first?
            .components(separatedBy: "\n}\n").first)
        #expect(small.contains("motif: entry.homeScreenMotif, makesRoomForALeftMotif: true)"), "the small card shifts")
        #expect(!medium.contains("makesRoomForALeftMotif"), "the medium card has room")
        #expect(cards.components(separatedBy: "makesRoomForALeftMotif").count == 2, "only the small card")
        #expect(!(try RepoRoot.source("App/FernletWidgets/MapWidgetViews.swift")).contains("makesRoomForALeftMotif"))
    }

    // MARK: - Helpers

    private static func state(_ state: CompanionState) -> UInt32 { WorldCompanionLook.stateHex(state) }

    private static func paint(_ look: WorldCompanionLook, _ state: CompanionState = .okay) -> WorldCompanionGrid {
        WorldCompanionPainter.paint(state: state, look: look, pose: WorldCompanionPose())
    }

    /// The frame cells `matching` pieces painted.
    private static func cells(of grid: WorldCompanionGrid, _ matching: (WorldCompanionPiece) -> Bool) -> [(Int, Int)] {
        var found: [(Int, Int)] = []
        for y in 0..<WorldCompanionGrid.frameHeight {
            for x in 0..<WorldCompanionGrid.frameWidth where grid.piece(frameX: x, y: y).map(matching) == true { found.append((x, y)) }
        }
        return found
    }

    /// Whether a left, right, upper or lower neighbour of (x, y) is a `matching` piece.
    private static func besides(_ grid: WorldCompanionGrid, _ x: Int, _ y: Int, _ matching: (WorldCompanionPiece) -> Bool) -> Bool {
        WorldCompanionGrid.sides.contains { grid.piece(frameX: x + $0.0, y: y + $0.1).map(matching) == true }
    }

    /// Whether (x, y) or one of its 8 neighbours is cut out.
    private static func nearCutOut(_ grid: WorldCompanionGrid, _ x: Int, _ y: Int) -> Bool {
        (-1...1).contains { dy in (-1...1).contains { dx in grid.piece(frameX: x + dx, y: y + dy)?.isCutOut == true } }
    }

    /// A placement as the fixture writes it: today, left or behind, and the left column.
    static func spot(_ rows: [String], on grid: WorldCompanionGrid, movable: Bool) -> String {
        let placement = WorldCompanionMotifPlacement(rows: rows, on: grid, movable: movable, oneColour: false)
        switch placement.spot {
        case .topRight: return "today \(placement.x)"
        case .topLeft: return "left \(placement.x)"
        case .behind: return "behind \(placement.x)"
        }
    }

    /// One reference case's inputs.
    struct Case {
        let state: CompanionState
        let look: WorldCompanionLook
    }

    /// The fixture's looks (the lane's `cases.js` LOOKS), awake.
    static let cases: [String: Case] = {
        let wizard = WorldCompanionWardrobeTests.wizard, balloon = WorldCompanionWardrobeTests.balloon
        func look(_ shape: WorldCompanionShape, _ state: CompanionState, _ key: String) -> WorldCompanionLook {
            let body = WorldCompanionLook.stateHex(state), cap = WorldCompanionLook.capBlue, red = WorldCompanionLook.scarfRed
            switch key {
            case "a": return WorldCompanionLook(body: body, shape: shape, topper: .glasses, topperColor: WorldCompanionOneColourTests.slate, scarf: red,
                                                     side: .mug, sideColor: WorldCompanionOneColourTests.clay)
            case "b": return WorldCompanionLook(body: body, shape: shape, cap: cap, side: .book, sideColor: WorldCompanionOneColourTests.moss)
            case "c": return WorldCompanionLook(body: body, shape: shape, topper: .none, items: [wizard, balloon])
            case "capped", "cap": return WorldCompanionLook(body: body, shape: shape, cap: cap)
            case "wizard": return WorldCompanionLook(body: body, shape: shape, topper: .none, items: [wizard])
            case "glasses": return WorldCompanionLook(body: body, shape: shape, topper: .glasses, topperColor: WorldCompanionOneColourTests.slate)
            case "scarf": return WorldCompanionLook(body: body, shape: shape, scarf: red)
            case "flower": return WorldCompanionLook(body: body, shape: shape, topper: .flower)
            case "bottle": return WorldCompanionLook(body: body, shape: shape, side: .bottle, sideColor: WorldCompanionOneColourTests.slate)
            case "dumbbell": return WorldCompanionLook(body: body, shape: shape, side: .dumbbell, sideColor: WorldCompanionOneColourTests.slate)
            case "balloon": return WorldCompanionLook(body: body, shape: shape, items: [balloon])
            default: return WorldCompanionLook(body: body, shape: shape)
            }
        }
        var all: [String: Case] = [:]
        for key in ["a", "b", "c", "capped", "wizard", "glasses", "scarf", "flower", "cap", "bottle", "dumbbell", "balloon"] {
            all["look-\(key)"] = Case(state: .okay, look: look(.circle, .okay, key))
        }
        all["look-a-thriving"] = Case(state: .thriving, look: look(.circle, .thriving, "a"))
        let shapes: [(String, WorldCompanionShape)] = [("circle", .circle), ("soft", .soft), ("pear", .pear), ("puddle", .puddle)]
        for (name, shape) in shapes {
            for state in [CompanionState.thriving, .okay, .tired, .resting, .sick] {
                all["\(name)-\(state.rawValue.lowercased())"] = Case(state: state, look: look(shape, state, "sprout"))
            }
            all["\(name)-dressed"] = Case(state: .okay, look: look(shape, .okay, "a"))
        }
        return all
    }()

    /// A parsed reference mask.
    struct ReferenceMask {
        let name: String
        let apple: String
        let twinkle: String
        let rows: [[Character]]

        func tinted(_ x: Int, _ y: Int) -> Bool {
            y >= 0 && y < rows.count && x >= 0 && x < rows[y].count && rows[y][x] == "#"
        }
    }

    static func referenceMasks() throws -> [ReferenceMask] {
        let lines = try RepoRoot.source("Docs/World-Companion-OneColour-Grids.txt").components(separatedBy: "\n")
        var masks: [ReferenceMask] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard line.hasPrefix("## "), index + 2 + WorldCompanionGrid.frameHeight <= lines.count else { continue }
            let name = String(line.dropFirst(3).split(separator: " ")[0])
            let apple = lines[index].replacingOccurrences(of: "motif apple ", with: "")
            let twinkle = lines[index + 1].replacingOccurrences(of: "motif twinkle ", with: "")
            let rows = lines[(index + 2)..<(index + 2 + WorldCompanionGrid.frameHeight)].map { Array($0) }
            masks.append(ReferenceMask(name: name, apple: apple, twinkle: twinkle, rows: Array(rows)))
            index += 2 + WorldCompanionGrid.frameHeight
        }
        return masks
    }
}

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// G8's new looks (the owner's picks on the "Sprout's New Looks" review page, 2026-11-15): hair, eyes,
/// pattern and background, pinned through the app's painter (the widget's twin is held equal by
/// `WidgetWorldTests`). Today's look paints exactly as before; every new piece keeps the moods readable,
/// stays off the face and the outline where it should, and steps aside for the cap and a drawn hat; the
/// background never reaches a friend.
@MainActor
struct WorldCompanionLooksTests {
    private static let shapes: [WorldCompanionShape] = [.circle, .soft, .pear, .puddle]
    private static let states: [CompanionState] = [.thriving, .okay, .tired, .resting, .sick]

    private static func look(_ state: CompanionState, shape: WorldCompanionShape = .circle,
                             topper: WorldCompanionTopper = .sprout, change: (inout WorldCompanionLook) -> Void = { _ in }) -> WorldCompanionLook {
        var look = WorldCompanionLook(body: WorldCompanionLook.stateHex(state), shape: shape, topper: topper)
        change(&look)
        return look
    }

    private static func cells(_ grid: WorldCompanionGrid, _ piece: WorldCompanionPiece) -> [(Int, Int)] {
        var found: [(Int, Int)] = []
        for y in 0..<WorldCompanionGrid.frameHeight {
            for x in 0..<WorldCompanionGrid.frameWidth where grid.piece(frameX: x, y: y) == piece { found.append((x, y)) }
        }
        return found
    }

    // MARK: Today's look

    /// Spelling out the defaults (no hair, round ink eyes, plain) paints the very grid the look always did.
    @Test func theDefaultsPaintTodaysCompanion() {
        for state in Self.states {
            for shape in Self.shapes {
                for pose in [WorldCompanionPose(), WorldCompanionPose(settled: true), WorldCompanionPose(asleep: true)] {
                    let plain = Self.look(state, shape: shape)
                    let spelled = Self.look(state, shape: shape) {
                        $0.hair = .none; $0.eyes = .round; $0.eyeColor = 0x3E5C7A; $0.pattern = .plain
                    }
                    #expect(WorldCompanionPainter.paint(state: state, look: plain, pose: pose)
                            == WorldCompanionPainter.paint(state: state, look: spelled, pose: pose), "\(state) \(shape)")
                }
            }
        }
    }

    // MARK: Hair

    /// Every style draws hair on every shape, none under the sleep cap or a drawn hat, and the sprout still grows.
    @Test func hairShowsOnEveryShapeAndHidesUnderTheCap() {
        for hair in WorldCompanionHair.allCases where hair != .none {
            for shape in Self.shapes {
                let grid = WorldCompanionPainter.paint(state: .okay, look: Self.look(.okay, shape: shape) { $0.hair = hair },
                                                       pose: WorldCompanionPose())
                #expect(!Self.cells(grid, .hair).isEmpty, "\(hair) on \(shape)")
                #expect(!Self.cells(grid, .sprout).isEmpty, "\(hair) on \(shape): the sprout grows through")
                let capped = WorldCompanionPainter.paint(state: .okay, look: Self.look(.okay, shape: shape) { $0.hair = hair; $0.cap = 0x6E86B0 },
                                                         pose: WorldCompanionPose())
                #expect(Self.cells(capped, .hair).isEmpty, "\(hair) on \(shape) under the cap")
            }
        }
    }

    /// Hair wears its colour, darker at the head's edge.
    @Test func hairWearsItsColour() {
        let grid = WorldCompanionPainter.paint(state: .okay, look: Self.look(.okay) { $0.hair = .fringe; $0.hairColor = 0xC0643A },
                                               pose: WorldCompanionPose())
        let colours = Set(Self.cells(grid, .hair).compactMap { grid.frameColor(x: $0.0, y: $0.1) })
        #expect(colours.contains(0xC0643A))
        #expect(colours.contains(WorldCompanionPainter.mix(0xC0643A, WorldCompanionPainter.shade, 0.3)))
    }

    // MARK: Eyes

    /// Every style keeps the moods: resting, sick and asleep close the eyes to today's lines (lashes add
    /// their flick); a tired day lids the top of the open eye in the body's dark shade.
    @Test func everyEyeStyleKeepsTheMoods() {
        for eyes in WorldCompanionEyes.allCases {
            for state in [CompanionState.resting, .sick] {
                let grid = WorldCompanionPainter.paint(state: state, look: Self.look(state) { $0.eyes = eyes }, pose: WorldCompanionPose())
                let today = WorldCompanionPainter.paint(state: state, look: Self.look(state), pose: WorldCompanionPose())
                let extra = Self.cells(grid, .eye).count - Self.cells(today, .eye).count
                #expect(extra == (eyes == .lashes ? 2 : 0), "\(eyes) \(state): closed eyes are today's lines")
            }
            guard eyes != .dot else { continue }
            let tired = WorldCompanionPainter.paint(state: .tired, look: Self.look(.tired) { $0.eyes = eyes }, pose: WorldCompanionPose())
            let body = WorldCompanionBody(state: .tired, shape: .circle, color: WorldCompanionLook.stateHex(.tired), pose: WorldCompanionPose(),
                                          increasedContrast: false)
            let eyeRow = WorldCompanionFaceLayout(body: body, face: .state(.tired, pose: WorldCompanionPose())).eye
            let lidded = eyes.columns.contains { tired.color(x: $0, y: eyeRow) == body.dark }
            #expect(lidded, "\(eyes): a tired day lids the eye")
        }
    }

    /// Only Big and Button eyes wear the eye colour; the others stay ink. Big eyes keep their white shine.
    @Test func onlyTheLargeEyesWearAColour() {
        for eyes in WorldCompanionEyes.allCases {
            let grid = WorldCompanionPainter.paint(state: .okay, look: Self.look(.okay) { $0.eyes = eyes; $0.eyeColor = 0x3E5C7A },
                                                   pose: WorldCompanionPose())
            let colours = Set(Self.cells(grid, .eye).compactMap { grid.frameColor(x: $0.0, y: $0.1) })
            #expect(colours.contains(0x3E5C7A) == eyes.isLarge, "\(eyes)")
            #expect(colours.contains(0xFFFFFF) == (eyes == .big), "\(eyes): the shine")
        }
    }

    /// Petting keeps the eye style (owner): the round eyes keep today's arcs, the others their own eyes,
    /// under the same smile.
    @Test func pettingKeepsTheEyeStyle() {
        for eyes in WorldCompanionEyes.allCases {
            let petted = WorldCompanionPainter.paint(state: .thriving, look: Self.look(.thriving) { $0.eyes = eyes },
                                                     pose: WorldCompanionPose(settled: true))
            let awake = WorldCompanionPainter.paint(state: .thriving, look: Self.look(.thriving) { $0.eyes = eyes }, pose: WorldCompanionPose())
            // The settled body slumps a row, so compare each face's eyes from their own top-left cell.
            let eyeCells = { (grid: WorldCompanionGrid) -> [String] in
                let cells = Self.cells(grid, .eye)
                let left = cells.map(\.0).min() ?? 0, top = cells.map(\.1).min() ?? 0
                return cells.map { "\($0.0 - left),\($0.1 - top)" }.sorted()
            }
            #expect((eyeCells(petted) == eyeCells(awake)) == (eyes != .round), "\(eyes)")
        }
    }

    /// The glasses' lenses go round every eye style (bigger for Big and Button, owner): no frame covers an eye.
    @Test func theGlassesLensesFitEveryEyeStyle() {
        for eyes in WorldCompanionEyes.allCases {
            for shape in Self.shapes {
                let bare = WorldCompanionPainter.paint(state: .okay, look: Self.look(.okay, shape: shape, topper: .none) { $0.eyes = eyes },
                                                       pose: WorldCompanionPose())
                let worn = WorldCompanionPainter.paint(state: .okay, look: Self.look(.okay, shape: shape, topper: .glasses) { $0.eyes = eyes },
                                                       pose: WorldCompanionPose())
                let body = WorldCompanionBody(state: .okay, shape: shape, color: WorldCompanionLook.stateHex(.okay),
                                              pose: WorldCompanionPose(), increasedContrast: false)
                let eyeRow = WorldCompanionFaceLayout(body: body, face: .state(.okay, pose: WorldCompanionPose())).eye
                // The lashes' flicks sit above the eye, under the lens's top: the frame may cover them.
                for (x, y) in Self.cells(bare, .eye) where y - WorldCompanionGrid.frameY >= eyeRow - (eyes.isLarge ? 1 : 0) {
                    #expect(worn.piece(frameX: x, y: y) == .eye, "\(eyes) on \(shape): a lens frame covers the eye at \(x),\(y)")
                }
            }
        }
    }

    // MARK: Pattern

    /// A pattern never touches the outline or the face, and paints as body, so the one-colour widgets drop it.
    @Test func aPatternStaysOffTheFaceAndTheOutline() {
        for pattern in WorldCompanionPattern.allCases where pattern != .plain {
            for shape in Self.shapes {
                for state in Self.states {
                    let plain = WorldCompanionPainter.paint(state: state, look: Self.look(state, shape: shape), pose: WorldCompanionPose())
                    let patterned = WorldCompanionPainter.paint(state: state, look: Self.look(state, shape: shape) { $0.pattern = pattern },
                                                                pose: WorldCompanionPose())
                    let body = WorldCompanionBody(state: state, shape: shape, color: WorldCompanionLook.stateHex(state),
                                                  pose: WorldCompanionPose(), increasedContrast: false)
                    for y in 0..<WorldCompanionGrid.frameHeight {
                        for x in 0..<WorldCompanionGrid.frameWidth where plain.frameColor(x: x, y: y) != patterned.frameColor(x: x, y: y) {
                            let bx = x - WorldCompanionGrid.frameX, by = y - WorldCompanionGrid.frameY
                            #expect(!body.isOutline(bx, by), "\(pattern) \(shape) \(state): on the outline at \(bx),\(by)")
                            #expect(!plain.isFace(frameX: x, y: y), "\(pattern) \(shape) \(state): on the face at \(bx),\(by)")
                            #expect(patterned.piece(frameX: x, y: y) == .body)
                        }
                    }
                }
            }
        }
    }

    // MARK: Background

    /// No scene is no drawing; every scene fills its 32 × 28 cells; dusk and night darken a day scene and
    /// leave the night sky as it is; dark mode dims every scene.
    @Test func scenesFillTheirFrameAndFollowTheLight() {
        #expect(WorldCompanionScene.paint(.none, light: .day, dark: false) == nil)
        func brightness(_ cells: [UInt32]) -> Double { cells.map(WorldCompanionPainter.luminance).reduce(0, +) / Double(cells.count) }
        for kind in WorldCompanionSceneKind.allCases where kind != .none {
            let day = WorldCompanionScene.paint(kind, light: .day, dark: false) ?? []
            #expect(day.count == WorldCompanionScene.width * WorldCompanionScene.height, "\(kind)")
            #expect(Set(day).count > 3, "\(kind) draws a picture")
            let night = WorldCompanionScene.paint(kind, light: .night, dark: false) ?? []
            let dusk = WorldCompanionScene.paint(kind, light: .dusk, dark: false) ?? []
            if kind == .night {
                #expect(night == day)
            } else {
                #expect(brightness(night) < brightness(dusk) && brightness(dusk) < brightness(day), "\(kind)")
            }
            #expect(brightness(WorldCompanionScene.paint(kind, light: .day, dark: true) ?? []) < brightness(day), "\(kind) dims")
        }
    }

    // MARK: The appearance

    /// The app's tokens map one to one onto the painter's cases, and the look reads the person's colours.
    @Test func theAppearanceMapsOntoThePainter() {
        #expect(CompanionHairStyle.allCases.map { String(describing: WorldCompanionHair($0)) } == CompanionHairStyle.allCases.map(\.rawValue))
        #expect(CompanionEyes.allCases.map { String(describing: WorldCompanionEyes($0)) } == CompanionEyes.allCases.map(\.rawValue))
        #expect(CompanionPattern.allCases.map { String(describing: WorldCompanionPattern($0)) } == CompanionPattern.allCases.map(\.rawValue))
        #expect(CompanionBackground.allCases.map { String(describing: WorldCompanionSceneKind($0)) } == CompanionBackground.allCases.map(\.rawValue))
        let appearance = CompanionAppearance(hairStyle: .bun, hairColorHex: "#C0643A", eyeStyle: .big, eyeColorHex: "#3E5C7A", pattern: .moss)
        let look = WorldCompanionLook(appearance: appearance, state: .okay, asleep: false)
        #expect(look.hair == .bun && look.hairColor == 0xC0643A && look.eyes == .big && look.eyeColor == 0x3E5C7A && look.pattern == .moss)
        let standard = WorldCompanionLook(appearance: .standard, state: .okay, asleep: false)
        #expect(standard.hair == .none && standard.hairColor == WorldCompanionLook.hairBrown && standard.eyes == .round
                && standard.eyeColor == WorldCompanionPainter.ink && standard.pattern == .plain)
    }

    /// An appearance saved before G8 decodes to today's look; a style from a newer build parks its token
    /// and keeps it through a save; the new fields round-trip.
    @Test func theNewFieldsDecodeTolerantly() throws {
        let legacy = try JSONEncoder().encode(CompanionAppearance.standard)
        var object = try #require(try JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        for key in ["hairStyle", "hairColorHex", "eyeStyle", "eyeColorHex", "pattern", "background"] { object[key] = nil }
        let old = try JSONDecoder().decode(CompanionAppearance.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(old == .standard)
        object["hairStyle"] = "mohawk"
        let newer = try JSONDecoder().decode(CompanionAppearance.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(newer.hairStyle == .none && newer.unknownHairStyleToken == "mohawk")
        let resaved = try JSONDecoder().decode(CompanionAppearance.self, from: try JSONEncoder().encode(newer))
        #expect(resaved.unknownHairStyleToken == "mohawk")
        let dressed = CompanionAppearance(hairStyle: .swoop, hairColorHex: "#123456", eyeStyle: .button, eyeColorHex: "#3F6B3A",
                                          pattern: .belly, background: .snow)
        #expect(try JSONDecoder().decode(CompanionAppearance.self, from: try JSONEncoder().encode(dressed)) == dressed)
    }

    /// The background stays on this phone (owner): it is never sent, and a received one is dropped; the
    /// hair's and eyes' colours are clamped at the wire like every other free-text colour.
    @Test func theBackgroundNeverReachesAFriend() {
        let dressed = CompanionAppearance(hairStyle: .tuft, hairColorHex: "#C0643A", background: .beach)
        #expect(dressed.forFriends.background == .none && dressed.forFriends.hairStyle == .tuft)
        var hostile = dressed
        hostile.hairColorHex = "not a colour"
        hostile.eyeColorHex = "#12345G"
        let received = FriendStatePayload(state: .okay, appearance: hostile).sanitizedAppearance
        #expect(received.background == .none && received.hairColorHex == nil && received.eyeColorHex == nil)
        #expect(received.hairStyle == .tuft)
    }

    /// The widget's look carries the new keys only when they differ from today's look, so today's look
    /// encodes exactly as before.
    @Test func theWidgetLookCarriesTheNewKeysOnlyWhenWorn() {
        let standard = WidgetSnapshot.CompanionLook(appearance: .standard)
        #expect(standard.hairRaw == nil && standard.hairColorHex == nil && standard.eyesRaw == nil && standard.eyeColorHex == nil
                && standard.patternRaw == nil && standard.backgroundRaw == nil)
        let dressed = WidgetSnapshot.CompanionLook(appearance: CompanionAppearance(
            hairStyle: .long, hairColorHex: "#e2b85c", eyeStyle: .lashes, eyeColorHex: "#3E5C7A", pattern: .freckles, background: .room))
        #expect(dressed.hairRaw == "long" && dressed.eyesRaw == "lashes" && dressed.patternRaw == "freckles" && dressed.backgroundRaw == "room")
        #expect(dressed.hairColorHex != nil)
        #expect(dressed.eyeColorHex == nil, "lashes show no eye colour")
    }

    /// Customize lists the new slots in the creature's order, and summarizes them.
    @Test func customizeListsTheNewSlots() {
        #expect(CustomizeSlot.allCases == [.body, .hair, .eyes, .pattern, .accessory, .clothing, .sideItem, .background])
        let bare = CustomizeSlotSummary.make(.hair, appearance: .standard, equipped: [])
        #expect(bare.isEmpty && bare.value == CompanionHairStyle.none.label)
        let dressed = CompanionAppearance(hairStyle: .curly, pattern: .stripes, background: .forest)
        #expect(CustomizeSlotSummary.make(.hair, appearance: dressed, equipped: []).value == CompanionHairStyle.curly.label)
        #expect(!CustomizeSlotSummary.make(.pattern, appearance: dressed, equipped: []).isEmpty)
        #expect(!CustomizeSlotSummary.make(.background, appearance: dressed, equipped: []).isEmpty)
        #expect(!CustomizeSlotSummary.make(.eyes, appearance: .standard, equipped: []).isEmpty)
    }
}

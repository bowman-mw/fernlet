import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Body shapes in the widgets (Refinements group 17, approved 2026-10-26), pinned through the app's
/// painter, whose twin the widget copies word for word: the highlight keeps one pixel off Pear's and
/// Puddle's outline, every face sits where the shape has room for it (Pear a row lower, Puddle a row
/// higher, Puddle's sad and hungry or thirsty faces without the touches above the eyes), and Circle
/// and Soft draw exactly as before, but for the sad tear on Circle at x 6.
@MainActor
struct WorldCompanionBodyShapeTests {
    private static let shapes: [WorldCompanionShape] = [.circle, .soft, .pear, .puddle]
    private static let states: [CompanionState] = [.thriving, .okay, .tired, .resting, .sick]
    private static let poses = [WorldCompanionPose(), WorldCompanionPose(breathIn: true), WorldCompanionPose(asleep: true),
                                WorldCompanionPose(drowsy: true)]
    private static let feelings: [WorldCompanionFace] = [.happy, .sad, .hungry, .thirsty]

    private static func body(_ shape: WorldCompanionShape, _ state: CompanionState = .okay,
                             _ pose: WorldCompanionPose = WorldCompanionPose()) -> WorldCompanionBody {
        WorldCompanionBody(state: state, shape: shape, color: WorldCompanionLook.stateHex(state), pose: pose, increasedContrast: false)
    }

    // MARK: - The highlight

    /// The centres per shape, and only the moved ones keep clear of the outline.
    @Test func theHighlightCentresAreTheApprovedOnes() {
        let centres: [(WorldCompanionShape, Double, Double)] = [(.circle, 7, -3.5), (.soft, 7, -3.5), (.pear, 7, -2.2), (.puddle, 6.5, -2.1)]
        for (shape, x, dy) in centres {
            let centre = shape.highlightCentre
            #expect(centre.x == x && centre.dy == dy, "\(shape): (\(centre.x), cy \(centre.dy))")
        }
        #expect(!WorldCompanionShape.circle.highlightKeepsClear && !WorldCompanionShape.soft.highlightKeepsClear)
        #expect(WorldCompanionShape.pear.highlightKeepsClear && WorldCompanionShape.puddle.highlightKeepsClear)
    }

    /// On Pear and Puddle no highlight cell sits beside an outline cell, and some highlight is left.
    @Test func theHighlightStaysOnePixelInsideTheOutline() {
        for shape in [WorldCompanionShape.pear, .puddle] {
            for state in Self.states {
                let body = Self.body(shape, state)
                var lit = 0
                for y in 0..<WorldCompanionGrid.height {
                    for x in 0..<WorldCompanionGrid.width where body.pixelColor(x, y, sick: false) == body.light {
                        lit += 1
                        let touches = body.isOutline(x - 1, y) || body.isOutline(x + 1, y) || body.isOutline(x, y - 1) || body.isOutline(x, y + 1)
                        #expect(!touches, "\(shape) \(state): the highlight at (\(x), \(y)) touches the outline")
                    }
                }
                #expect(lit >= 4, "\(shape) \(state) kept \(lit) highlight pixels")
            }
        }
    }

    // MARK: - Where the face goes

    /// The table's rows: Circle and Soft 12 / 15 as approved, Pear and Puddle 13 / 16.
    @Test func theFaceRowsFollowTheShape() {
        let rows: [(WorldCompanionShape, Int, Int)] = [(.circle, 12, 15), (.soft, 12, 15), (.pear, 13, 16), (.puddle, 13, 16)]
        for (shape, eye, mouth) in rows {
            for face in WorldCompanionFace.allCases {
                let layout = WorldCompanionFaceLayout(body: Self.body(shape), face: face)
                #expect(layout.eye == eye && layout.mouth == mouth, "\(shape) \(face): \(layout.eye) / \(layout.mouth)")
            }
        }
    }

    /// Every state's face (thriving, okay, tired, resting, asleep, sick, and winding down) on its own
    /// body, and the four feelings on an awake day's body, are all clear of the outline, with their
    /// blush and tear. The one exception is the approved art's: a happy or sad feeling on a resting
    /// day's Pear, which sits lower, keeps its smile's or frown's corners on row 18.
    @Test func everyFaceIsClearOfTheOutline() {
        for shape in Self.shapes {
            for state in Self.states {
                for pose in Self.poses {
                    let body = Self.body(shape, state, pose)
                    let face = WorldCompanionFace.state(state, pose: pose)
                    #expect(Self.unclear(face, on: body).isEmpty, "\(shape) \(state) \(pose): \(Self.unclear(face, on: body))")
                    guard !(shape == .pear && state == .resting) else { continue }
                    for feeling in Self.feelings {
                        #expect(Self.unclear(feeling, on: body).isEmpty, "\(shape) \(state) \(feeling): \(Self.unclear(feeling, on: body))")
                    }
                }
            }
        }
    }

    /// The face's cells, with its blush (thriving, happy) and tear (sad), that are not clear.
    private static func unclear(_ face: WorldCompanionFace, on body: WorldCompanionBody) -> [String] {
        let layout = WorldCompanionFaceLayout(body: body, face: face)
        var cells = layout.cells(for: face)
        if face == .thriving || face == .happy {
            guard let cheeks = layout.cheeks else { return ["no cheeks"] }
            cells += [(cheeks.left, layout.mouth + cheeks.rowOffset), (cheeks.right, layout.mouth + cheeks.rowOffset)]
        }
        if face == .sad { cells += [(layout.tear, layout.eye + 2), (layout.tear, layout.eye + 3)] }
        return cells.filter { !body.isClear($0.0, $0.1) }.map { "(\($0.0), \($0.1))" }
    }

    /// Puddle has no room above the eyes: its sad face loses the brows, hungry and thirsty draw their
    /// eyes level. Every other shape keeps them.
    @Test func puddleDropsTheTouchesAboveTheEyes() {
        for shape in Self.shapes {
            for feeling in Self.feelings {
                let layout = WorldCompanionFaceLayout(body: Self.body(shape), face: feeling)
                #expect(layout.lowered == (shape == .puddle && feeling != .happy), "\(shape) \(feeling)")
            }
        }
        let puddle = WorldCompanionFaceLayout(body: Self.body(.puddle), face: .sad)
        #expect(puddle.cells(for: .sad).allSatisfy { $0.1 >= puddle.eye }, "no brows above the eyes")
        let hungry = WorldCompanionFaceLayout(body: Self.body(.puddle), face: .hungry)
        let eyes = hungry.cells(for: .hungry).filter { $0.1 < hungry.mouth }
        #expect(eyes.map { $0.1 }.sorted() == [13, 13, 14, 14], "level eyes on rows eye and eye + 1")
        let pear = WorldCompanionFaceLayout(body: Self.body(.pear), face: .sad)
        #expect(pear.cells(for: .sad).contains { $0 == (7, pear.eye - 2) }, "Pear keeps the brows")
    }

    /// The tear: x 6 on Circle and Pear, x 5 on Soft and Puddle.
    @Test func theTearStepsInwardOnCircle() {
        let tears: [(WorldCompanionShape, Int)] = [(.circle, 6), (.soft, 5), (.pear, 6), (.puddle, 5)]
        for (shape, column) in tears {
            for state in [CompanionState.thriving, .okay, .tired, .resting, .sick] {
                #expect(WorldCompanionFaceLayout(body: Self.body(shape, state), face: .sad).tear == column, "\(shape) \(state)")
            }
        }
    }

    // MARK: - Circle and Soft as approved

    /// Circle and Soft paint every pixel of the body as approved (the highlight round (7, cy − 3.5),
    /// beside the outline or not), and lay every face out as built: eyes on round(cy − 1), the mouth on
    /// round(cy + 2), the blush at x 5 and 14 a row above the mouth, nothing lowered, the tear at x 5 but
    /// on Circle, where it may step in to x 6.
    @Test func circleAndSoftAreTheApprovedArt() {
        for shape in [WorldCompanionShape.circle, .soft] {
            for state in Self.states {
                for pose in Self.poses + [WorldCompanionPose(settled: true)] {
                    let body = Self.body(shape, state, pose)
                    for y in 0..<WorldCompanionGrid.height {
                        for x in 0..<WorldCompanionGrid.width {
                            let sick = state == .sick
                            #expect(body.pixelColor(x, y, sick: sick) == Self.approved(x, y, body: body, sick: sick), "\(shape) \(state) (\(x), \(y))")
                        }
                    }
                    for face in WorldCompanionFace.allCases {
                        let layout = WorldCompanionFaceLayout(body: body, face: face)
                        #expect(layout.eye == Int((body.cy - 1).rounded()) && layout.mouth == Int((body.cy + 2).rounded()))
                        #expect(layout.cheeks == WorldCompanionFaceLayout.Cheeks(left: 5, right: 14, rowOffset: -1) && !layout.lowered)
                        #expect(layout.tear == 5 || (shape == .circle && layout.tear == 6), "\(shape) \(state) \(face) tear \(layout.tear)")
                    }
                }
            }
        }
    }

    /// The approved per-pixel rule, as built before group 17.
    private static func approved(_ x: Int, _ y: Int, body: WorldCompanionBody, sick: Bool) -> UInt32? {
        guard body.contains(x, y) else { return nil }
        let edge = !body.contains(x - 1, y) || !body.contains(x + 1, y) || !body.contains(x, y - 1) || !body.contains(x, y + 1)
        let hy = Double(y) - (body.cy - 3.5)
        let lit = Double((x - 7) * (x - 7)) + hy * hy <= 2.3
        if sick && !edge && Double(y) >= (body.cy + 1.5).rounded() { return x % 3 == 0 ? 0xD9A57E : 0xF3E6CB }
        return edge ? body.dark : (lit ? body.light : (Double(y) >= body.cy + body.ry - 2.2 ? body.low : body.base))
    }

    // MARK: - The widget shares the rule

    /// The widget's feeling faces place and erase both faces with the twin's layout and per-pixel
    /// colour, never a copy of their own.
    @Test func theWidgetsFeelingFacesUseTheSharedLayout() throws {
        let faces = try RepoRoot.source("App/FernletWidgets/WidgetFeelingFaces.swift")
        #expect(faces.contains("let layout = WidgetCompanionFaceLayout(body: body, face: face)"), "the feeling's layout")
        #expect(faces.contains("let face = WidgetCompanionFace.state(state, pose: pose)"), "the state face's layout")
        #expect(faces.contains("face.cells(eye: layout.eye, mouth: mouth, lowered: layout.lowered)"), "the twin's cells")
        #expect(faces.contains("body.pixelColor("), "the twin's per-pixel colour")
        for duplicate in ["(body.cy - 1).rounded()", "(body.cy + 2).rounded()", "body.cy - 3.5", "func bodyColour", "(6, eye - 1)"] {
            #expect(!faces.contains(duplicate), "a private copy of the rule is back: \(duplicate)")
        }
        let painter = try RepoRoot.source("App/FernletWidgets/WidgetPixelCompanion.swift")
        let twin = try #require(WidgetWorldTests.twin(in: painter), "the painter's twin markers are gone")
        #expect(twin.contains("struct WidgetCompanionFaceLayout") && twin.contains("func pixelColor("), "the rule lives in the twin")
    }
}

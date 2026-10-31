import CoreGraphics
import Foundation
import Testing
@testable import Fernlet

/// Home in the air (World-Airports-Spec §6.2, screen 8, draft 6), the pure parts: the 737's tube and its windows at the
/// standard and the largest text sizes, Sprout's place in its window, the clouds' slow drift, and Sprout's three lines
/// taking turns.
struct WorldFlyingHomeTests {
    /// The design's phone width.
    static let width: CGFloat = 402

    // MARK: The tube

    @Test func theStandardTubeIsTheDraftsSize() {
        let layout = WorldFlyingLayout(large: false)
        #expect(layout.tubeHeight == 236)
        #expect(layout.pixelScale == 7)
        #expect(layout.glassSize == CGSize(width: 140, height: 172))
        #expect(layout.sceneHeight == 330)
    }

    @Test func theLargestTextShrinksTheTubeTheWindowsAndSprout() {
        let layout = WorldFlyingLayout(large: true)
        #expect(layout.tubeHeight == 196)
        #expect(layout.pixelScale == 6)
        #expect(layout.glassSize == CGSize(width: 128, height: 150))
        #expect(layout.sceneHeight == 300)
    }

    @Test(arguments: [false, true])
    func windowsComeOneEvery236PointsWithSproutsAt150(large: Bool) {
        let layout = WorldFlyingLayout(large: large)
        let centres = layout.windowCentres(width: Self.width)
        #expect(centres == [150, 386], "the window before Sprout's is wholly off the leading edge")
        let glass = layout.glass(centre: 150)
        #expect(glass.midX == 150)
        #expect(layout.frame(centre: 150) == glass.insetBy(dx: -9, dy: -9))
    }

    @Test func aWiderPhoneShowsTheSameRowFurther() {
        let centres = WorldFlyingLayout(large: false).windowCentres(width: 700)
        #expect(centres == [150, 386, 622])
        #expect(centres.count <= WorldFlyingLayout.maxWindows)
    }

    @Test(arguments: [false, true])
    func theWindowsFrameAndTheCheatLineStayInsideTheTube(large: Bool) {
        let layout = WorldFlyingLayout(large: large)
        let frame = layout.frame(centre: 150)
        #expect(frame.minY > WorldFlyingLayout.edge)
        #expect(layout.cheatLine(width: Self.width).minY > frame.maxY, "the cheat line runs under the windows")
        #expect(layout.pinstripe(width: Self.width).minY == layout.cheatLine(width: Self.width).maxY)
        #expect(layout.pinstripe(width: Self.width).maxY <= layout.tubeHeight, "on the tube, as the draft draws it")
    }

    @Test func seamsSitHalfwayBetweenWindows() {
        #expect(WorldFlyingLayout(large: false).seams(width: Self.width) == [32, 268])
    }

    // MARK: Sprout at the window

    @Test(arguments: [false, true])
    func sproutFillsItsWindowPressedToTheGlass(large: Bool) {
        let layout = WorldFlyingLayout(large: large)
        let origin = layout.spriteOrigin
        let spriteWidth = WorldFlyingLayout.spriteColumns * layout.pixelScale
        #expect(origin.x >= 0 && origin.x + spriteWidth <= layout.glassSize.width, "the body's width fits the glass")
        #expect(spriteWidth >= layout.glassSize.width * 0.9, "pressed right up to the glass")
        #expect(origin.y >= 0 && origin.y < layout.glassSize.height / 2, "the face is at the glass's middle")
        #expect(origin.y + 23 * layout.pixelScale > layout.glassSize.height * 0.9, "the body reaches the glass's foot")
        let mist = layout.mistCentre
        #expect(mist.y > layout.glassSize.height / 2 && mist.y < layout.glassSize.height)
    }

    @Test func theShineCrossesTheGlassFromTopRightToBottomLeft() {
        let layout = WorldFlyingLayout(large: false)
        let shine = layout.shine(centre: 150)
        let glass = layout.glass(centre: 150)
        #expect(shine.count == 4)
        #expect(shine[1].x < glass.maxX && shine[1].y > glass.minY)
        #expect(shine[2].x < shine[1].x && shine[2].y > shine[1].y)
    }

    // MARK: The clouds

    @Test func cloudsStartWhereTheDraftDrawsThem() {
        #expect(WorldFlyingClouds.size == CGSize(width: 48, height: 15))
        #expect(WorldFlyingClouds.x(start: 250, elapsed: 0, width: Self.width) == 250)
        #expect(WorldFlyingClouds.x(start: 18, elapsed: 0, width: Self.width) == 18)
    }

    @Test func cloudsDriftSlowlyLeftAWholePixelAtATime() {
        #expect(WorldFlyingClouds.x(start: 250, elapsed: 0.4, width: Self.width) == 250, "under one pixel's drift")
        #expect(WorldFlyingClouds.x(start: 250, elapsed: 1, width: Self.width) == 244)
        #expect(WorldFlyingClouds.x(start: 250, elapsed: 10, width: Self.width) == 190)
    }

    @Test func aCloudLeavingTheLeadingEdgeComesRoundFromTheTrailingEdge() {
        let lap = TimeInterval((Self.width + 48) / WorldFlyingClouds.speed)
        #expect(WorldFlyingClouds.x(start: 18, elapsed: lap, width: Self.width) == 18, "one whole lap")
        let gone = WorldFlyingClouds.x(start: 18, elapsed: 12, width: Self.width)
        #expect(gone >= -48 && gone < Self.width)
        #expect(gone > 18, "past the leading edge, it came round from the right")
    }

    // MARK: Sprout's lines

    @Test func sproutsLinesTakeTurnsStartingWithTheFirst() {
        #expect(WorldFlyingHomeCopy.line(turn: 0) == "Up in the air! Wake me when we land.")
        #expect(WorldFlyingHomeCopy.line(turn: 1) == "Clouds look like snacks.")
        #expect(WorldFlyingHomeCopy.line(turn: 2) == "Are we there yet?")
        #expect(WorldFlyingHomeCopy.line(turn: 3) == WorldFlyingHomeCopy.line(turn: 0))
        #expect(WorldFlyingHomeCopy.line(turn: -1) == WorldFlyingHomeCopy.line(turn: 0))
    }

    @Test func theSceneIsOneImageNamedForTheCompanion() {
        #expect(WorldFlyingHomeCopy.scene(companion: "Sprout") == "Sprout, flying, its face pressed to the plane's window")
    }
}

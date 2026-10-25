import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The owner's form answers built in round 6b's small lane (2026-10-25): the close-up's one even veil
/// (question 27), and the rest of the lane's small changes as they land.
@MainActor
struct WorldRound6bSmallTests {

    // MARK: 27 · The close-up's veil

    /// One even veil, as drawn: 80 % over the light map, 84 % over the dark, from top to bottom (no
    /// thicker band behind the name and the footer).
    @Test func theCloseUpHasOneEvenVeil() {
        #expect(WorldCloseUpVeil.opacity(dark: false) == 0.8)
        #expect(WorldCloseUpVeil.opacity(dark: true) == 0.84)
    }

    // MARK: 41 · A received plan says "Notes included"

    /// The received workout plan's framed card adds "Notes included" when the sender's notes travel
    /// with it, as its bubble does; the note text itself is never shown. `FernletTests` cannot link
    /// the appex, so the controller's source holds the shape (as `MessagesExtensionBoundaryTests` does).
    @Test func aReceivedPlanSaysNotesIncluded() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesViewController.swift"))
        let body = try #require(MeshRoutedSourceScan.bracedBody(after: "private func showReceivedWorkout(", in: source))
        #expect(body.contains("record.packet.includesNotes"))
        #expect(body.contains("FernletMessagesCopy.workoutSubtitleWithNotes(summary:"))
        #expect(!body.contains(".notes"), "the note text never reaches the panel")
    }

    // MARK: 42 · The Messages panel's icons grow with the text

    /// The panel's pixel icons step up one point a key at the accessibility sizes, as the app's sprites
    /// do, and every panel icon is drawn through the stepping view (no fixed 2-pt image left).
    @Test func thePanelsIconsGrowInSteps() throws {
        #expect(FernletMessagesSprite.pixel(2, accessibilitySize: false) == 2)
        #expect(FernletMessagesSprite.pixel(2, accessibilitySize: true) == 3)
        #expect(FernletMessagesSprite.pixel(3, accessibilitySize: true) == 4)
        for file in ["FernletMessagesPanelPieces.swift", "FernletMessagesFramedViews.swift", "FernletMessagesViewController.swift"] {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/FernletMessagesExtension/\(file)"))
            #expect(!code.contains(".image(pixel: 2") && !code.contains(".image(pixel: 3"),
                    "\(file) draws a pixel icon at a fixed size, which stays small at the largest text")
        }
    }
}

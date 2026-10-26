import FernletUI
import Foundation
import Testing
@testable import Fernlet

/// World build round 6b's integration seams (2026-10-25): the coordinator's spot-check fix the lanes
/// left to the integrator. (The map widget's store lines are held in `WidgetMapTests`.)
@MainActor
struct WorldIntegrationSixBTests {
    /// A wall photo opened from the map keeps "‹ Album" on its plate whatever the hangout's or the phone's
    /// name (`ref-wall-photo`): the root Back always draws its word, VoiceOver hears "Back to Album", the
    /// Back closes the photo to the Album's grid and the ✕ goes back to Home.
    @Test func theWallPhotosBackReadsAlbum() throws {
        let frame = try RepoRoot.source("App/Fernlet/World/Shell/WorldPanelFrame.swift")
        #expect(frame.contains("FernletBackButton(verbatim: backTitle, action: onBack)"),
                "the root Back never gives way to the arrow alone for a long title")
        let album = try RepoRoot.source("App/Fernlet/ConnectView.swift")
        #expect(album.contains("backTitle: onBack == nil ? nil : WorldPanel.friends.title"))
        #expect(album.contains("onBack: feedOpenedFromWall == nil ? nil : { selectedAlbumPostID = nil }"),
                "Back closes the photo over the Album's grid")
        #expect(album.contains("else { closeWallFeedToHome() }"), "✕ goes back to Home")
        #expect(WorldPanel.friends.title == "Album")
        #expect(FernletUICopy.backTo(WorldPanel.friends.title) == "Back to Album")
    }
}

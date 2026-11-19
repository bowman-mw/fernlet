import Foundation
import Testing
@testable import Fernlet

/// The widgets on Sprout's background (owner's pick A, 2026-11-18): the scene fills the companion cards,
/// "Your drive" and the map's bottom strip, in colour only; water and stamp keep their paper; and the drive
/// widget, which the snapshot's reload set leaves out, reloads when Sprout's look changes.
///
/// The extension has no test target, so its half is read off disk (`RepoRoot.source`), in the house
/// style of `WidgetWorldTests`.
@MainActor
struct WidgetSceneBackgroundTests {

    static let widgetRoot = "App/FernletWidgets/"

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSceneBackgroundTests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Reloading "Your drive"

    /// A new background reloads the drive widget on the foreground path; a save that leaves the look
    /// alone does not.
    @Test func theDriveWidgetReloadsOnlyWhenTheLookChanges() {
        var drive = 0
        let mirror = WidgetSnapshotMirror(directory: temporaryDirectory(), reloadTimelines: {},
                                          reloadDriveWidget: { drive += 1 })
        var snapshot = WidgetSnapshotContentEqualityTests.baseline()
        mirror.publish(snapshot)
        #expect(drive == 1, "nothing was published before: the first look is a change")

        snapshot.bottleCount += 1
        mirror.publish(snapshot)
        #expect(drive == 1, "a water log is not Sprout's look")

        snapshot.companionLook?.backgroundRaw = "room"
        mirror.publish(snapshot)
        #expect(drive == 2, "a new background reloads the drive widget")

        mirror.publish(snapshot)
        #expect(drive == 2)
    }

    /// The background refresh's diffed path reloads the drive widget on a look change too.
    @Test func theRefreshPathReloadsTheDriveWidgetOnALookChange() {
        var drive = 0
        let mirror = WidgetSnapshotMirror(directory: temporaryDirectory(), reloadTimelines: {},
                                          reloadDriveWidget: { drive += 1 })
        var snapshot = WidgetSnapshotContentEqualityTests.baseline()
        _ = mirror.publishIfContentChanged(snapshot)
        snapshot.companionLook?.backgroundRaw = "forest"
        #expect(mirror.publishIfContentChanged(snapshot) == .reloaded)
        #expect(drive == 2)
        snapshot.bottleCount += 1
        _ = mirror.publishIfContentChanged(snapshot)
        #expect(drive == 2, "a content change that leaves the look alone does not reload the drive widget")
    }

    // MARK: - Which cards wear the scene

    /// The scene never reaches a one-colour rendering: iOS drops the background there, and the cards
    /// draw on their paper layout.
    @Test func theCardSceneIsColourOnly() throws {
        let source = try RepoRoot.source(Self.widgetRoot + "WidgetSceneCard.swift")
        #expect(source.contains("func cardScene(dark: Bool, mono: Bool) -> [UInt32]? {\n        guard !mono else { return nil }"))
    }

    /// The companion cards, the drive widget and the map take the scene; water and stamp, which have
    /// no Sprout, keep their paper (owner, 2026-11-18).
    @Test func theCardsWithSproutWearTheSceneAndTheOthersKeepPaper() throws {
        let bundle = try RepoRoot.source(Self.widgetRoot + "FernletWidgetsBundle.swift")
        #expect(bundle.contains("CompanionSmallSceneView(entry: entry)"))
        #expect(bundle.contains("CompanionThoughtSceneView(entry: entry)"))
        #expect(bundle.contains("WidgetCardGround(scene: scene"))
        let drive = try RepoRoot.source(Self.widgetRoot + "DriveWidget.swift")
        #expect(drive.contains("DriveSceneView(entry: entry)"))
        let map = try RepoRoot.source(Self.widgetRoot + "MapWidgetViews.swift")
        #expect(map.contains("sceneStrip(width:"))
        for file in ["WaterWidget.swift", "StampWidget.swift"] {
            let source = try RepoRoot.source(Self.widgetRoot + file)
            #expect(!source.contains("cardScene"), "\(file) keeps its plain paper")
        }
    }

    /// On a scene every line of text sits on a paper plate, so it keeps the paper's measured contrast.
    @Test func sceneTextSitsOnPlates() throws {
        let source = try RepoRoot.source(Self.widgetRoot + "CompanionSceneViews.swift")
        // Three cards: small, medium, and the drive's two faces.
        #expect(source.components(separatedBy: ".widgetScenePlate(theme)").count - 1 == 4)
    }
}

// SessionPhotoReviewOverlayTests.swift
// FernletTests
//
// Session photos U3 (2026-09-30): the overlay window and the snapshot cover, hosted in real windows
// on the simulator.
//
//   I9  the overlay window is above a SwiftUI sheet presented in the main window WITHOUT dismissing
//       it: the sheet's `presentedViewController` is still there while the overlay is key, and after
//       the hide the main window is key again with its accessibility restored;
//   I18 no held photo is drawn while the scene is not active — the review sheet renders its opaque
//       cover (`friends.review.snapshotCover`) INSTEAD of the grid, so no tile loads its bytes and
//       not one pixel of a photo is in what the window draws (the app-switcher snapshot is a
//       drawing of the window) — and the overlay's screen takes that phase from the coordinator,
//       because a hosting controller in a window the app creates is outside the SwiftUI scene that
//       supplies `\.scenePhase`.
//
// The photos are MAGENTA, a colour Fernlet's palette never draws, so "the window holds a photo" is a
// pixel count. (SwiftUI's accessibility tree is not exposed to a unit-test process, so the cover's
// identifier cannot be read here; the counts are the stronger claim anyway: they are about what an
// app-switcher snapshot would hold.)

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - Hosts

/// A main-window root that keeps one SwiftUI sheet presented — the half-typed journal entry the
/// review must never take away.
struct StandingSheetHost: View {
    var body: some View {
        Color.clear.sheet(isPresented: .constant(true)) { ForeignCoverMarker() }
    }
}

/// The scene phase the cell drives into the review sheet.
@MainActor
@Observable
final class InjectedPhase {
    var phase: ScenePhase = .inactive
}

/// Counts tile loads — every call is a held photo's bytes being pulled into the view tree.
@MainActor
final class TileLoadCounter {
    private(set) var loads = 0

    func load(_ photo: FriendPhotoPayload) -> Data? {
        loads += 1
        return OverlayTestSupport.magentaJPEG()
    }
}

/// `FriendPhotoReviewSheet` with an injected scene phase and a counting tile loader.
struct PhaseInjectedReview: View {
    let phase: InjectedPhase
    let photos: [FriendPhotoPayload]
    let counter: TileLoadCounter
    @State private var selected: Set<UUID> = []
    @State private var alsoSave = false

    var body: some View {
        FriendPhotoReviewSheet(
            photos: photos, selectedIDs: $selected, alsoSaveToPhotos: $alsoSave,
            keepSelected: {}, discardAll: {}, notNow: {}, loadImageData: { counter.load($0) }
        )
        .environment(\.scenePhase, phase.phase)
    }
}

// MARK: - Helpers

@MainActor
enum OverlayTestSupport {

    /// The first connected window scene (the unit-test host's).
    static func scene() throws -> UIWindowScene {
        try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "Expected an active window scene for SwiftUI lifecycle testing"
        )
    }

    /// A key, visible window on `scene` hosting `root`.
    static func window<Root: View>(on scene: UIWindowScene, root: Root) -> (UIWindow, UIHostingController<Root>) {
        let hosting = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        return (window, hosting)
    }

    /// Tears a test window down.
    static func close(_ window: UIWindow, _ hosting: UIViewController) {
        hosting.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Metadata-only photos (no bytes), so every tile has to LOAD to draw.
    static func metadataPhotos(_ count: Int) -> [FriendPhotoPayload] {
        (0..<count).map { index in
            FriendPhotoPayload(
                id: UUID(), imageData: MeshRoutedPhotoFixtures.tinyJPEG(), addedAt: Date(), senderName: "Sam \(index)",
                senderFingerprint: "sam-fp-\(index)", senderSigningPublicKey: Data([1, 2, 3])
            ).withoutImageData()
        }
    }

    /// A decodable photo in MAGENTA — a colour the app's palette never draws.
    static func magentaJPEG() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let side = CGSize(width: 320, height: 320)
        let image = UIGraphicsImageRenderer(size: side, format: format).image { context in
            UIColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: side))
        }
        return image.jpegData(compressionQuality: 0.9) ?? MeshRoutedPhotoFixtures.tinyJPEG()
    }

    /// How many sampled pixels of what `window` draws are magenta — how much of a test photo the
    /// window (and so an app-switcher snapshot of it) holds.
    static func photoPixels(in window: UIWindow) -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let image = drawn.cgImage else { return 0 }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var count = 0
        // R2: bounded by the bitmap, sampling every fourth pixel.
        for offset in stride(from: 0, to: pixels.count - 3, by: 16) {
            if pixels[offset] > 190, pixels[offset + 1] < 90, pixels[offset + 2] > 190 { count += 1 }
        }
        return count
    }

    /// Polls (bounded: 60 × 50 ms) until `condition` holds.
    static func waitUntil(_ condition: () -> Bool) async throws {
        // R2: bounded.
        for _ in 0..<60 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - The overlay window

/// The overlay window and the snapshot cover, hosted.
@MainActor
@Suite(.serialized)
struct SessionPhotoReviewOverlayTests {
    let store = makeTestStore()

    /// An ended session with `photos` held on a founded manager over this cell's store.
    private func endedManager(photos: Int) throws -> MeshNetworkManager {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        LastMemberReviewFixtures.capture(photos, on: manager)
        manager.leaveSession()
        HeldPhotos.openGate(on: manager)
        try #require(manager.pendingReviewPhotos.count == photos)
        return manager
    }

    /// **I9, hosted.** A SwiftUI sheet presented in the main window survives the overlay: the
    /// overlay window is key and above it, the sheet is still presented, the main window's
    /// accessibility is hidden while the overlay shows, and after the hide the main window is key
    /// again with its accessibility restored and the sheet still up.
    @Test func theOverlayWindowIsAboveAPresentedSheetWithoutDismissingIt() async throws {
        let scene = try OverlayTestSupport.scene()
        let (main, hosting) = OverlayTestSupport.window(on: scene, root: StandingSheetHost())
        defer { OverlayTestSupport.close(main, hosting) }
        try await OverlayTestSupport.waitUntil { holdsForeignCover(hosting.presentedViewController) }
        try #require(holdsForeignCover(hosting.presentedViewController), "precondition: the sheet is up")
        let manager = try endedManager(photos: 1)
        defer { manager.leaveMesh() }
        let presenter = SessionPhotoReviewOverlayPresenter(appearance: { _ in .dark })
        let coordinator = SessionPhotoReviewCoordinator(
            manager: manager, host: store, presenter: presenter, saveKeptPhotosToLibrary: { _ in }
        )
        defer { presenter.hide() }
        presenter.attach(to: scene)

        #expect(presenter.show(coordinator), "the presenter draws once it has a scene")
        let overlay = try #require(scene.windows.first {
            $0.accessibilityIdentifier == SessionPhotoReviewOverlayPresenter.windowIdentifier
        })
        #expect(overlay.isKeyWindow && overlay.windowLevel > main.windowLevel, "the overlay is key and above the main window")
        #expect(overlay.overrideUserInterfaceStyle == .dark, "in the appearance it was handed")
        main.overrideUserInterfaceStyle = .light
        #expect(SessionPhotoReviewOverlayPresenter.mirroredAppearance(of: main) == .light,
                "and by default it mirrors a style the app pinned on the main window")
        main.overrideUserInterfaceStyle = .unspecified
        #expect(holdsForeignCover(hosting.presentedViewController), "and the main window's sheet is still presented")
        #expect(main.accessibilityElementsHidden, "VoiceOver reads only the review")

        presenter.hide()
        #expect(!presenter.isShowing && !scene.windows.contains(overlay), "the overlay window is released")
        #expect(main.isKeyWindow && !main.accessibilityElementsHidden, "the main window is key again, readable again")
        #expect(holdsForeignCover(hosting.presentedViewController), "and nothing underneath was dismissed")
    }

    /// **I18.** While the injected scene phase is not active the review draws its cover: no tile
    /// loads, and not one photo pixel is drawn. Once active the tiles load and the photos are drawn;
    /// back in the background they are gone again.
    @Test func theSnapshotCoverKeepsEveryPhotoOutOfTheWindowWhileTheSceneIsNotActive() async throws {
        let scene = try OverlayTestSupport.scene()
        let phase = InjectedPhase()
        let counter = TileLoadCounter()
        let review = PhaseInjectedReview(phase: phase, photos: OverlayTestSupport.metadataPhotos(3), counter: counter)
        let (window, hosting) = OverlayTestSupport.window(on: scene, root: review)
        defer { OverlayTestSupport.close(window, hosting) }
        try await Task.sleep(for: .milliseconds(600))

        #expect(counter.loads == 0, "inactive: no tile exists, so no held photo's bytes were pulled into the tree")
        #expect(OverlayTestSupport.photoPixels(in: window) == 0, "and the window draws no photo — the cover")

        phase.phase = .active
        try await OverlayTestSupport.waitUntil { counter.loads == 3 && OverlayTestSupport.photoPixels(in: window) > 0 }
        #expect(counter.loads == 3, "active: every tile loads")
        #expect(OverlayTestSupport.photoPixels(in: window) > 500, "and the photos are drawn — the cover was not vacuous")

        phase.phase = .background
        try await OverlayTestSupport.waitUntil { OverlayTestSupport.photoPixels(in: window) == 0 }
        #expect(OverlayTestSupport.photoPixels(in: window) == 0, "a background scene takes every photo out of the window")
    }

    /// **I18**, the overlay's host: `SessionPhotoReviewScreen` takes the scene phase from the
    /// coordinator (ContentView feeds it), not from an environment its window does not have.
    @Test func theOverlayScreenTakesItsScenePhaseFromTheCoordinator() async throws {
        let scene = try OverlayTestSupport.scene()
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for _ in 0..<2 { manager.addPhoto(OverlayTestSupport.magentaJPEG()) }
        }
        manager.leaveSession()
        HeldPhotos.openGate(on: manager)
        let coordinator = SessionPhotoReviewCoordinator(
            manager: manager, host: store, presenter: RecordingReviewPresenter(), saveKeptPhotosToLibrary: { _ in }
        )
        coordinator.launchComplete = true
        coordinator.scenePhase = .active
        coordinator.evaluateNow()
        try #require(coordinator.isShowing && coordinator.photos.count == 2)
        let (window, hosting) = OverlayTestSupport.window(on: scene, root: SessionPhotoReviewScreen(coordinator: coordinator))
        defer { OverlayTestSupport.close(window, hosting) }
        try await OverlayTestSupport.waitUntil { OverlayTestSupport.photoPixels(in: window) > 0 }
        #expect(OverlayTestSupport.photoPixels(in: window) > 500, "active: the held photos are drawn through the gated seam")

        coordinator.scenePhase = .inactive
        try await OverlayTestSupport.waitUntil { OverlayTestSupport.photoPixels(in: window) == 0 }
        #expect(OverlayTestSupport.photoPixels(in: window) == 0,
                "the coordinator's phase covers the grid in the overlay window: no photo in the snapshot")
        coordinator.scenePhase = .active
        try await OverlayTestSupport.waitUntil { OverlayTestSupport.photoPixels(in: window) > 0 }
        #expect(OverlayTestSupport.photoPixels(in: window) > 500, "and uncovers it on return")
    }
}

// DisposableCameraSaveTests.swift
// FernletTests
//
// Round 2026-08-20 item 1.1: the disposable camera's "Develop → Save selected" flow could never
// succeed. `MeshNetworkManager` stores every session photo metadata-only (`withoutImageData()`),
// and `DisposableCameraView` handed those stripped payloads straight to
// `FriendPhotoLibrarySaver.save`, which skips nil-`imageData` payloads and throws
// `NothingSavedError` — and because `finishSessionPhotos(keeping:)` ran only after a successful
// save, the photos were never kept on the in-app wall either. The same flow also demanded Photos
// add-only authorization BEFORE the keep, so denying the system prompt cost the user their
// in-app pictures (UI/UX finding FRND-12).
//
// Two halves here:
//   - behavioral: the export hydrates every KEPT photo from the wall, and keeping to the in-app wall
//     succeeds with no Photos-library involvement at all;
//   - source wall: `DisposableCameraView`'s one function naming `FriendPhotoLibrarySaver` takes the
//     keep's `SessionPhotoAnswer` and reads only `keptOnWall`, hydrated from the wall, and its keep
//     path never touches the saver — that independence is exactly what makes a Photos permission
//     denial unable to cost the keep.
//
// Since 2026-09-30 session photos are HELD in the sealed pending corpus until the answer, so the
// camera roll can only ever receive a photo the person already kept (invariant I2): pending bytes
// have no path to `hydratedPhotos`, which reads the wall alone.

import Foundation
import Photos
import Testing
import UIKit
import FernletDomainModel
import ProximityKit
@testable import Fernlet

// Each @Test function receives a fresh instance of this struct, so `store` is a new FernletStore
// per test (with per-instance photo/proximity temp directories via `makeTestStore()`). The stored
// property keeps the FernletStore alive for the whole test — MeshNetworkManager holds it
// `unowned`.
@Suite(.serialized) @MainActor
struct DisposableCameraSaveTests {
    let store = makeTestStore()

    // MARK: - Hydration after the keep

    /// The session-photo list holds no bytes, and before the answer the wall has none of them
    /// either — `hydratedPhotos` reads the wall alone, so a held photo cannot reach the saver. After
    /// the keep, the export's own expression recovers real bytes for every kept photo.
    @Test func exportAfterTheKeep_hydratesEveryKeptPhotoFromTheWall() throws {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeCameraTestMesh()
        HeldPhotos.openGate(on: manager)

        for _ in 0..<3 { manager.addPhoto(try makeCameraTestJPEG()) }
        try #require(manager.sessionPhotos.count == 3)
        #expect(manager.sessionPhotos.allSatisfy { $0.imageData == nil },
                "Session photos are stored metadata-only")
        #expect(manager.hydratedPhotos(manager.sessionPhotos).isEmpty,
                "Before the answer no session photo is on the wall, so nothing can be handed to the saver")

        let selected = Set(manager.sessionPhotos.prefix(2).map(\.id))
        let answer = manager.finishSessionPhotos(keeping: selected)
        // The fixed DisposableCameraView export: the answer's kept photos, rehydrated from the wall.
        let toSave = manager.hydratedPhotos(manager.meshPhotos.filter { answer.keptOnWall.contains($0.id) })

        #expect(answer.keptOnWall == selected)
        #expect(toSave.count == selected.count, "Every kept photo must rehydrate from the wall")
        #expect(toSave.allSatisfy { $0.imageData != nil },
                "Hydration must repopulate bytes so the export saves pictures instead of throwing NothingSavedError")
    }

    // MARK: - Keep-on-wall needs no Photos authorization (FRND-12)

    /// Keeping the selection on the in-app wall is `finishSessionPhotos(keeping:)` — pure
    /// mesh-manager state plus the two sealed corpora. It must succeed with whatever Photos
    /// authorization state the process has (including none at all), and must not change that
    /// state — i.e. it never triggers the system prompt whose denial used to cost the keep.
    @Test func keepOnWall_succeedsWithoutAnyPhotosAuthorization() throws {
        let statusBefore = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeCameraTestMesh()
        HeldPhotos.openGate(on: manager)

        for _ in 0..<3 { manager.addPhoto(try makeCameraTestJPEG()) }
        let sessionIDs = manager.sessionPhotos.map(\.id)
        try #require(sessionIDs.count == 3)
        let kept = Set(sessionIDs.prefix(2))

        let answer = manager.finishSessionPhotos(keeping: kept)

        #expect(answer.keptOnWall == kept && answer.notApplied.isEmpty)
        let wallIDs = Set(manager.meshPhotos.map(\.id))
        #expect(kept.isSubset(of: wallIDs),
                "Kept photos must reach the in-app wall — no Photos-library involvement required")
        for dropped in sessionIDs.dropFirst(2) {
            #expect(!wallIDs.contains(dropped),
                    "Unkept session photos never reach the wall")
        }
        #expect(manager.sessionPhotos.isEmpty,
                "finishSessionPhotos consumes the session list")
        #expect(PHPhotoLibrary.authorizationStatus(for: .addOnly) == statusBefore,
                "Keeping must not request Photos authorization (FRND-12: a denial used to also destroy the in-app keep)")
    }

    // MARK: - Source wall: the call site

    /// The defect lived at the CALL SITE, so the behavioral tests alone can regress silently: the
    /// one function in `DisposableCameraView` that names `FriendPhotoLibrarySaver` takes a
    /// `SessionPhotoAnswer` and saves only its `keptOnWall`, hydrated from the wall (I2), and the
    /// keep path never names the saver. Reads shipping source off disk via ``RepoRoot`` so a vacuous
    /// pass is impossible.
    @Test func disposableCameraSource_exportsOnlyTheAnswersKeptPhotos_andKeepsWithoutTheSaver() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/DisposableCameraView.swift"))

        #expect(source.contains("loadImageData: { manager.reviewThumbnailData(for: $0) }"),
                "The review tiles load held photos through the gated review seam")
        #expect(source.contains("alsoSaveToPhotos: $alsoSaveToPhotos"),
                "The Photos copy is the sheet's opt-in toggle, applied after the answer")
        #expect(!source.contains("saveToPhotos:"),
                "no pre-answer export button: the camera roll must not see a photo before the choice")
        #expect(source.components(separatedBy: "FriendPhotoLibrarySaver.save(").count - 1 == 1,
                "the camera names the saver in exactly one place")

        let export = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func exportKeptPhotosIfAsked(_ answer: SessionPhotoAnswer) async", in: source),
            "the one export takes a SessionPhotoAnswer — renamed?")
        #expect(export.contains("FriendPhotoLibrarySaver.save("), "and it is that function")
        #expect(export.contains("manager.hydratedPhotos(manager.meshPhotos.filter { answer.keptOnWall.contains($0.id) })"),
                "saving only what the answer reports landed, hydrated from the WALL")

        let keep = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func keepSelectedSessionPhotos() async", in: source),
            "DisposableCameraView.keepSelectedSessionPhotos is the FRND-12 keep action — renamed?")
        #expect(keep.contains("finishSessionPhotos(keeping:"),
                "The keep action must answer the ticked photos")
        #expect(!keep.contains("FriendPhotoLibrarySaver"),
                """
                The keep action must never touch FriendPhotoLibrarySaver: its authorization gate \
                is what used to turn a Photos permission denial into losing the in-app photos.
                """)
        let answerLine = try #require(keep.range(of: "finishSessionPhotos(keeping:"))
        let exportLine = try #require(keep.range(of: "exportKeptPhotosIfAsked(answer)"))
        #expect(answerLine.lowerBound < exportLine.lowerBound, "the export runs only AFTER the answer")
    }
}

// MARK: - Helpers

/// A minimal open mesh so `addPhoto` routes captures into the session list (mirrors the private
/// fixture in `MeshNetworkManagerTests`).
@MainActor
private func makeCameraTestMesh() -> MeshDescriptor {
    let now = Date()
    let fp = "camera-test-host-fp"
    return MeshDescriptor(
        meshID: UUID(),
        name: "Camera Test Mesh",
        mode: .open,
        members: [],
        nameSetAt: now,
        nameSetBy: fp,
        modeSetAt: now,
        modeSetBy: fp,
        createdAt: now
    )
}

/// A real (decodable) JPEG so the disk cache round-trips actual image bytes.
@MainActor
private func makeCameraTestJPEG() throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
    let image = renderer.image { ctx in
        UIColor.systemTeal.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    return try #require(image.jpegData(compressionQuality: 0.7),
                        "UIGraphicsImageRenderer output must encode as JPEG")
}

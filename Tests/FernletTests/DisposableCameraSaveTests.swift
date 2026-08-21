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
//   - behavioral: the hydration seam recovers bytes for every selected session photo, and keeping
//     to the in-app wall succeeds with no Photos-library involvement at all;
//   - source wall: `DisposableCameraView`'s export path must wrap the selection in
//     `manager.hydratedPhotos(...)`, and its keep path must never touch `FriendPhotoLibrarySaver`
//     — that independence is exactly what makes a Photos permission denial unable to cost the
//     keep.

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

    // MARK: - Hydration before export

    /// The session-photo list holds no bytes, so the pre-fix call (passing it to the saver
    /// unwrapped) could only throw `NothingSavedError`; wrapping the selection in
    /// `hydratedPhotos` recovers real bytes for every selected photo from the disk cache.
    @Test func exportSelection_hydratesEverySelectedPhotoInsteadOfSavingNothing() throws {
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeCameraTestMesh()

        for _ in 0..<3 { manager.addPhoto(try makeCameraTestJPEG()) }
        try #require(manager.sessionPhotos.count == 3)

        #expect(manager.sessionPhotos.allSatisfy { $0.imageData == nil },
                "Session photos are stored metadata-only; an un-hydrated save can only skip them all")

        // The fixed DisposableCameraView export: filter the ticked ids, then rehydrate.
        let selected = Set(manager.sessionPhotos.prefix(2).map(\.id))
        let toSave = manager.hydratedPhotos(manager.sessionPhotos.filter { selected.contains($0.id) })

        #expect(toSave.count == selected.count,
                "Every selected session photo must rehydrate from the disk cache")
        #expect(toSave.allSatisfy { $0.imageData != nil },
                "Hydration must repopulate bytes so the export saves pictures instead of throwing NothingSavedError")
    }

    // MARK: - Keep-on-wall needs no Photos authorization (FRND-12)

    /// Keeping the selection on the in-app wall is `finishSessionPhotos(keeping:)` — pure
    /// mesh-manager state plus the encrypted disk cache. It must succeed with whatever Photos
    /// authorization state the process has (including none at all), and must not change that
    /// state — i.e. it never triggers the system prompt whose denial used to cost the keep.
    @Test func keepOnWall_succeedsWithoutAnyPhotosAuthorization() throws {
        let statusBefore = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeCameraTestMesh()

        for _ in 0..<3 { manager.addPhoto(try makeCameraTestJPEG()) }
        let sessionIDs = manager.sessionPhotos.map(\.id)
        try #require(sessionIDs.count == 3)
        let kept = Set(sessionIDs.prefix(2))

        manager.finishSessionPhotos(keeping: kept)

        let wallIDs = Set(manager.meshPhotos.map(\.id))
        #expect(kept.isSubset(of: wallIDs),
                "Kept photos must stay on the in-app wall — no Photos-library involvement required")
        for dropped in sessionIDs.dropFirst(2) {
            #expect(!wallIDs.contains(dropped),
                    "Unkept session photos are removed from the wall")
        }
        #expect(manager.sessionPhotos.isEmpty,
                "finishSessionPhotos consumes the session list")
        #expect(PHPhotoLibrary.authorizationStatus(for: .addOnly) == statusBefore,
                "Keeping must not request Photos authorization (FRND-12: a denial used to also destroy the in-app keep)")
    }

    // MARK: - Source wall: the call site

    /// The defect lived at the CALL SITE, so the behavioral tests alone can regress silently: pin
    /// `DisposableCameraView`'s export path to the hydration seam, and pin the keep path's
    /// independence from `FriendPhotoLibrarySaver` (what makes a Photos denial harmless to the
    /// keep). Reads shipping source off disk via ``RepoRoot`` so a vacuous pass is impossible.
    @Test func disposableCameraSource_hydratesBeforeExport_andKeepsWithoutTheSaver() throws {
        let source = try RepoRoot.source("App/Fernlet/DisposableCameraView.swift")

        #expect(source.contains("manager.hydratedPhotos(manager.sessionPhotos.filter"),
                """
                The disposable camera's Photos export must rehydrate the ticked session photos \
                (manager.hydratedPhotos(...)) before handing them to FriendPhotoLibrarySaver — \
                session payloads are metadata-only, so an un-hydrated save throws NothingSavedError.
                """)

        #expect(source.contains("loadImageData:"),
                "The review sheet needs the disk-cache rehydrator or every tile renders as a placeholder")
        #expect(source.contains("saveToPhotos:"),
                "FRND-12: the Photos export must be wired as the sheet's optional secondary action, not fused into the keep")

        // Slice the keep action's body: it runs from its declaration to the export action that
        // is declared immediately after it. If either function is renamed or reordered, fail
        // loudly here rather than scanning the wrong span.
        let keepDecl = try #require(source.range(of: "func keepSelectedSessionPhotos"),
                                    "DisposableCameraView.keepSelectedSessionPhotos is the FRND-12 keep action — renamed?")
        let exportDecl = try #require(source.range(of: "func exportSelectedPhotosToLibrary"),
                                      "DisposableCameraView.exportSelectedPhotosToLibrary is the optional Photos export — renamed?")
        try #require(keepDecl.lowerBound < exportDecl.lowerBound,
                     "Expected the keep action to be declared before the export action — update this scan if they moved")
        let keepBody = source[keepDecl.upperBound..<exportDecl.lowerBound]

        #expect(keepBody.contains("finishSessionPhotos(keeping:"),
                "The keep action must keep the ticked photos on the in-app wall")
        #expect(!keepBody.contains("FriendPhotoLibrarySaver"),
                """
                The keep action must never touch FriendPhotoLibrarySaver: its authorization gate \
                is what used to turn a Photos permission denial into losing the in-app photos.
                """)
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

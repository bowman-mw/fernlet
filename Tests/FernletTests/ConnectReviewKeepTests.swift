// ConnectReviewKeepTests.swift
// FernletTests
//
// Residual from round 2026-08-20 item 1.1 (UI/UX finding FRND-12): `DisposableCameraView`'s
// in-session review got the split action bar — keep-to-wall as the primary action, the Photos
// export as a separate optional button — but `FriendsView`'s DISCONNECT review (ConnectView.swift)
// still used the fused flow: `FriendPhotoLibrarySaver.save` ran first and
// `finishSessionPhotos(keeping:)` only after a successful save, so denying the Photos add-only
// prompt still cost the user their in-app photos in this flow.
//
// Two halves, mirroring `DisposableCameraSaveTests`:
//   - behavioral: keeping to the in-app wall succeeds with no Photos-library involvement at all —
//     it neither requires nor changes the process's PHPhotoLibrary authorization state;
//   - source wall: `FriendsView`'s review call site must pass `saveToPhotos:` (the split form),
//     its keep action must call `finishSessionPhotos(keeping:)`, and that keep action must never
//     touch `FriendPhotoLibrarySaver` — that independence is exactly what makes a Photos
//     permission denial unable to cost the keep.

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
struct ConnectReviewKeepTests {
    let store = makeTestStore()

    // MARK: - Keep-on-wall needs no Photos authorization (FRND-12)

    /// The disconnect review's keep path is `finishSessionPhotos(keeping:)` — pure mesh-manager
    /// state plus the encrypted disk cache. It must succeed with whatever Photos authorization
    /// state the process has (including none at all), and must not change that state — i.e. it
    /// never triggers the system prompt whose denial used to cost the keep in this flow.
    @Test func disconnectKeepOnWall_succeedsWithoutAnyPhotosAuthorization() throws {
        let statusBefore = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeConnectTestMesh()

        for _ in 0..<3 { manager.addPhoto(try makeConnectTestJPEG()) }
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

    // MARK: - Source wall: the disconnect-review call site

    /// The defect lived at the CALL SITE, so the behavioral test alone can regress silently: pin
    /// `FriendsView`'s disconnect review (ConnectView.swift) to the split (FRND-12) sheet form,
    /// its keep action to `finishSessionPhotos(keeping:)`, and that keep action's independence
    /// from `FriendPhotoLibrarySaver` (what makes a Photos denial harmless to the keep). Reads
    /// shipping source off disk via ``RepoRoot`` so a vacuous pass is impossible.
    @Test func connectViewSource_passesSaveToPhotos_andKeepsWithoutTheSaver() throws {
        let source = try RepoRoot.source("App/Fernlet/ConnectView.swift")

        #expect(source.contains("saveToPhotos: { await exportSelectedPhotosToLibrary() }"),
                """
                FRND-12: the disconnect review must build FriendPhotoReviewSheet in the split form \
                — the Photos export wired as the sheet's optional saveToPhotos: secondary action, \
                not fused into the keep.
                """)
        #expect(source.contains("saveSelected: { await keepSelectedSessionPhotos() }"),
                "The sheet's primary action must be the keep — in-app wall only, no Photos authorization")
        #expect(source.contains("manager.hydratedPhotos(manager.sessionPhotos.filter"),
                """
                The Photos export must rehydrate the ticked session photos \
                (manager.hydratedPhotos(...)) before handing them to FriendPhotoLibrarySaver — \
                session payloads are metadata-only, so an un-hydrated save throws NothingSavedError.
                """)

        // Slice the keep action's body: it runs from its declaration to the export action that
        // is declared immediately after it. If either function is renamed or reordered, fail
        // loudly here rather than scanning the wrong span. (The FriendPhotoLibrarySaver check
        // MUST stay scoped to this slice: the same file's album carousel legitimately saves an
        // already-kept wall photo to the Photos library on explicit request.)
        let keepDecl = try #require(source.range(of: "func keepSelectedSessionPhotos"),
                                    "FriendsView.keepSelectedSessionPhotos is the FRND-12 keep action — renamed?")
        let exportDecl = try #require(source.range(of: "func exportSelectedPhotosToLibrary"),
                                      "FriendsView.exportSelectedPhotosToLibrary is the optional Photos export — renamed?")
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
/// fixture in `DisposableCameraSaveTests`).
@MainActor
private func makeConnectTestMesh() -> MeshDescriptor {
    let now = Date()
    let fp = "connect-test-host-fp"
    return MeshDescriptor(
        meshID: UUID(),
        name: "Connect Test Mesh",
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
private func makeConnectTestJPEG() throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
    let image = renderer.image { ctx in
        UIColor.systemIndigo.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    return try #require(image.jpegData(compressionQuality: 0.7),
                        "UIGraphicsImageRenderer output must encode as JPEG")
}

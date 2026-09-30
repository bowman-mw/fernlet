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
//   - source wall: `FriendsView`'s keep action answers the promoted batch with
//     `finishReviewedPhotos(_:keeping:in:)` and never touches `FriendPhotoLibrarySaver` — that
//     independence is exactly what makes a Photos permission denial unable to cost the keep.
//
// Since 2026-09-30 (the owner: "None of the photos should be saved to the camera roll until this
// selection has been made") the Photos export is no longer a button that works BEFORE the answer:
// it is an opt-in toggle applied AFTER the keep, only over the photos the answer reports landed on
// the wall (`SessionPhotoAnswer.keptOnWall`), re-read from the wall. The source wall pins that the
// one review function naming the saver takes the answer (invariant I2).

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

    /// The disconnect review's keep path is `finishReviewedPhotos(_:keeping:in:)` over the
    /// promoted batch — pure mesh-manager state plus the encrypted disk cache. It must succeed with
    /// whatever Photos authorization state the process has (including none at all), and must not
    /// change that state — i.e. it never triggers the system prompt whose denial used to cost the
    /// keep in this flow.
    @Test func disconnectKeepOnWall_succeedsWithoutAnyPhotosAuthorization() throws {
        let statusBefore = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeConnectTestMesh()
        HeldPhotos.openGate(on: manager)

        for _ in 0..<3 { manager.addPhoto(try makeConnectTestJPEG()) }
        let sessionIDs = manager.sessionPhotos.map(\.id)
        try #require(sessionIDs.count == 3)
        let kept = Set(sessionIDs.prefix(2))
        manager.leaveSession()   // the ending promotes the roll into the batch the review answers
        let batch = try #require(manager.pendingFriendReview, "the ending promoted the photos")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == Set(sessionIDs))

        let answer = manager.finishReviewedPhotos(Set(sessionIDs), keeping: kept, in: batch.id)

        #expect(answer.keptOnWall == kept && answer.notApplied.isEmpty)
        let wallIDs = Set(manager.meshPhotos.map(\.id))
        #expect(kept.isSubset(of: wallIDs),
                "Kept photos must stay on the in-app wall — no Photos-library involvement required")
        for dropped in sessionIDs.dropFirst(2) {
            #expect(!wallIDs.contains(dropped),
                    "Unkept session photos are removed from the wall")
        }
        #expect(manager.pendingReviewPhotos.isEmpty,
                "finishReviewedPhotos answers the batch's photo half")
        #expect(PHPhotoLibrary.authorizationStatus(for: .addOnly) == statusBefore,
                "Keeping must not request Photos authorization (FRND-12: a denial used to also destroy the in-app keep)")
    }

    // MARK: - Source wall: the disconnect-review call site

    /// The defect lived at the CALL SITE, so the behavioral test alone can regress silently: pin
    /// `FriendsView`'s disconnect review (ConnectView.swift) to the answer-first form — the keep
    /// answers the promoted batch and never names `FriendPhotoLibrarySaver`, and the ONE review
    /// function that does name it takes the answer and reads only `keptOnWall`, hydrated from the
    /// wall (I2: nothing reaches the camera roll before the choice, and nothing the answer did not
    /// report kept). Reads shipping source off disk via ``RepoRoot`` so a vacuous pass is impossible.
    @Test func connectViewSource_exportsOnlyTheAnswersKeptPhotos_andKeepsWithoutTheSaver() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))

        #expect(source.contains("keepSelected: { await keepSelectedSessionPhotos() }"),
                "The sheet's primary action must be the keep — in-app wall only, no Photos authorization")
        #expect(source.contains("alsoSaveToPhotos: $alsoSaveToPhotos"),
                "The Photos copy is the sheet's opt-in toggle, read by the host after the answer")
        #expect(!source.contains("saveToPhotos:"),
                "no pre-answer export button: the camera roll must not see a photo before the choice")
        #expect(source.contains("loadImageData: { manager.reviewThumbnailData(for: $0) }"),
                "tiles load held photos through the gated review seam, never the wall")

        let keep = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func keepSelectedSessionPhotos() async", in: source),
            "FriendsView.keepSelectedSessionPhotos is the FRND-12 keep action — renamed?")
        #expect(keep.contains("finishReviewedPhotos("),
                "The keep action must answer the promoted batch")
        #expect(!keep.contains("FriendPhotoLibrarySaver"),
                """
                The keep action must never touch FriendPhotoLibrarySaver: its authorization gate \
                is what used to turn a Photos permission denial into losing the in-app photos.
                """)
        let answerLine = try #require(keep.range(of: "finishReviewedPhotos("))
        let exportLine = try #require(keep.range(of: "exportKeptPhotosIfAsked(answer)"),
                                      "the export must take the answer the keep just returned")
        #expect(answerLine.lowerBound < exportLine.lowerBound, "the export runs only AFTER the answer")

        let export = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func exportKeptPhotosIfAsked(_ answer: SessionPhotoAnswer) async", in: source),
            "the one review export takes a SessionPhotoAnswer — renamed?")
        #expect(export.contains("FriendPhotoLibrarySaver.save("))
        #expect(export.contains("manager.hydratedPhotos(manager.meshPhotos.filter { answer.keptOnWall.contains($0.id) })"),
                "and saves only what the answer reports landed, hydrated from the WALL")
        #expect(export.contains("guard alsoSaveToPhotos"), "and only when the person turned the toggle on")
        // Every other function naming the saver is the album carousel's per-photo save of a photo
        // already on the wall, which is not the review's (the feed views declared below FriendsView).
        let reviewHalf = try #require(source.range(of: "private struct FriendPhotoFeedView"))
        let saverSites = source[..<reviewHalf.lowerBound].components(separatedBy: "FriendPhotoLibrarySaver.save(").count - 1
        #expect(saverSites == 1, "the Friends review names the saver in exactly one place: the post-answer export")
    }

    /// P6 item 2's pass-B review finding P2-4, as a source wall because both halves live in
    /// SwiftUI state transitions no tier-1 cell can drive.
    ///
    /// Half one: the heal arm special-cased only the compact keep prompt, and the blip's common
    /// case is the **photo review** sheet — so a pair that healed seconds later (the same room,
    /// always) presented the celebration `fullScreenCover` in the same transaction as a standing
    /// sheet, which the arm's own comment says drops one of the two.
    ///
    /// Half two: nothing ever reset `showConnectionAnimation` if the cover failed to present —
    /// `sessionReady` is set only inside the cover's own completion — and
    /// `.accessibilityHidden(showConnectionAnimation)` is on the whole Friends surface, so
    /// VoiceOver and Switch Control lost it for the rest of the session. Both non-celebrating
    /// exits of the arm now clear the flag.
    /// **Amended by the fix review (finding P2-2):** the heal arm's special case must be the ONE
    /// predicate over all THREE presenters. The album photo feed is a second `fullScreenCover` on
    /// the same anchor, so a commit while a wall photo was open took the celebrate branch, the
    /// celebration never presented, and the a11y latch closed again — one presentation conflict
    /// away from the two the original fix closed. So this now pins the predicate's membership by
    /// name, and reads CODE rather than raw source (finding P3-8: a doc comment satisfied the
    /// `>= 2` count and the `isSessionLive` needle).
    @Test func connectViewSource_healArmHandlesBothSheets_andClearsTheAccessibilityCover() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        let armDecl = try #require(source.range(of: "func handleCommittedPeerChange"),
                                   "FriendsView.handleCommittedPeerChange is the lifecycle arm — renamed?")
        let nextDecl = try #require(source.range(of: "private var disconnectReviewSheet"),
                                    "the review sheet is declared right after the arm — reordered?")
        try #require(armDecl.lowerBound < nextDecl.lowerBound,
                     "Expected the arm to be declared before the review sheet — update this scan if they moved")
        let armBody = source[armDecl.upperBound..<nextDecl.lowerBound]

        #expect(armBody.contains("aPresentationIsUp"),
                """
                The heal arm must branch on the ONE predicate over every presenter, not on a \
                hand-listed subset: the two session-end sheets AND the album photo feed can each \
                be up when a peer commits.
                """)
        #expect(armBody.contains("disconnectReviewPresented"),
                """
                The heal arm must dismiss the PHOTO REVIEW sheet as well as the keep prompt: it is \
                the blip's common case, and a heal arrives seconds later in the same room.
                """)
        #expect(armBody.components(separatedBy: "showConnectionAnimation = false").count - 1 >= 2,
                """
                Both non-celebrating exits of the arm must clear showConnectionAnimation, or a \
                cover that never presented latches .accessibilityHidden(true) on the whole \
                Friends surface for the rest of the session.
                """)

        let predicateDecl = try #require(source.range(of: "private var aPresentationIsUp: Bool {"),
                                         "the one-presentation predicate is gone — renamed?")
        let predicateEnd = try #require(source.range(of: "}", range: predicateDecl.upperBound..<source.endIndex))
        let predicateBody = source[predicateDecl.upperBound..<predicateEnd.lowerBound]
        for presenter in ["disconnectReviewPresented", "keepFriendsPromptPresented", "selectedAlbumPostID"] {
            #expect(predicateBody.contains(presenter),
                    """
                    \(presenter) is one of the three presenters hung off this view's single anchor, \
                    so it must be named in aPresentationIsUp — a presenter missing from the \
                    predicate is a presentation SwiftUI drops with nothing resetting the a11y latch.
                    """)
        }

        let reviewDecl = try #require(source.range(of: "private func presentDisconnectReviewIfNeeded()"),
                                      "the review presenter is gone — renamed?")
        let reviewEnd = try #require(
            source.range(of: "private func finalizeFriendKeeps", range: reviewDecl.upperBound..<source.endIndex),
            "finalizeFriendKeeps is declared right after the review presenter — reordered?"
        )
        let reviewBody = source[reviewDecl.upperBound..<reviewEnd.lowerBound]
        #expect(reviewBody.contains("guard !manager.isSessionLive else { return }"),
                """
                And the review presents only once the SESSION has ended: on hasCommittedPeer a \
                link blip showed a sheet whose primary action signs a termination on a live mesh. \
                The needle is scoped to this function's body (finding P3-8).
                """)
        #expect(reviewBody.contains("guard !aPresentationIsUp else { return }"),
                """
                And it refuses while any presenter is up: a .sheet requested over the album's \
                fullScreenCover is dropped, and a review that never appears is a batch the user \
                never answers.
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

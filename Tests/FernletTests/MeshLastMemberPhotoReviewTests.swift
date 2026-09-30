// MeshLastMemberPhotoReviewTests.swift
// FernletTests
//
// Owner report, 2026-09-29: "When the last person is knocked out of the mesh because they were the
// last person, it doesn't give them the option of going through the images and picking what they
// want to keep. It keeps everything."
//
// **The mechanism.** Every session photo is written to the persisted friend wall the moment it is
// taken or received (`cachePhoto`); `sessionPhotos` is only the list the review reads, and the ONLY
// thing that ever removes an unkept photo is the user's answer. The last device left in a mesh ends
// through a verified termination — the other side's Develop signs it — and
// `applyVerifiedTermination()` ran `leaveSession()`, whose first line was
// `sessionPhotos.removeAll()`, in the same main-actor turn as the promotion. So by the time
// `FriendsView.presentDisconnectReviewIfNeeded()` ran, it saw no photos: at most the keep-as-friend
// prompt, and every photo stayed on the wall unasked. A removal naming this device, the ceiling,
// epoch exhaustion, the pairwise "Ask to remove" and a hard stop all took the same shortcut.
//
// **The fix under test.** Photos leave the live list only through the user's choice or by being
// PROMOTED into `pendingFriendReview.photos` at the session-end moment — never dropped. The cells
// below drive the owner's case end to end on the fake fabric (both roads a termination reaches the
// last member by: the live record and the merge), the other involuntary endings, and the review
// API's scoping rules; the source walls pin the presenter to the batch.
//
// Nothing here runs a real radio or sleeps on a wall clock; the fabric's clock is advanced by the
// rigs' own bounded settles.

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import FernletCrypto
import FernletDomainModel
import PrivateMediaStore
@testable import ProximityKit
@testable import Fernlet

// MARK: - Fixtures

/// Shared helpers for the last-member review cells.
@MainActor
enum LastMemberReviewFixtures {

    /// The photo ids the node's PERSISTED wall index holds right now, read straight off disk
    /// through a fresh store over the same file — so "nothing was discarded before the choice" is a
    /// claim about the sealed index, not about the manager's in-memory copy.
    static func persistedWallIDs(_ store: FernletStore) -> Set<UUID>? {
        let index = PrivateMediaStore(
            indexURL: store.proximitySupportDirectory.appendingPathComponent("MeshPhotoCache.json")
        )
        guard case .entries(let photos) = index.loadIndex() else { return nil }
        return Set(photos.map(\.id))
    }

    /// Takes `count` photos on `manager` through the real `addPhoto`, under the pinned install.
    static func capture(_ count: Int, on manager: MeshNetworkManager) {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            // R2: bounded by the caller's count.
            for _ in 0..<count { manager.addPhoto(MeshRoutedPhotoFixtures.tinyJPEG()) }
        }
    }

    /// A manager over a recording fake radio with a founded, single-member mesh — enough for
    /// `addPhoto` to route captures into the session list and for the machine to take an ending.
    static func foundedManager(store: FernletStore, createdAt: Date = Date()) -> MeshNetworkManager {
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, createdAt: createdAt)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
        }
        return manager
    }
}

// MARK: - The owner's case, end to end

/// The last member of a mesh, ended by the other side's development, is offered its photos.
@MainActor
@Suite(.serialized)
struct MeshLastMemberPhotoReviewTests {

    /// **The owner's case, live-record road.** A founded pair; the partner (node 1) takes two
    /// photos; node 0 develops — a final pair's development signs a termination — and node 1, the
    /// last member left, reads it live and ends.
    ///
    /// Before the fix node 1's batch carried the partner as a keep-as-friend candidate and NO
    /// photos, `sessionPhotos` was empty, and both photos were already on its wall: kept unasked.
    @Test func theLastMemberEndedByThePartnersDevelopmentIsOfferedEveryPhoto() async throws {
        let rig = try MeshFoundingRig.build(2, label: "last-member-live")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle()
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        try #require(rig.roster(1).count == 2, "precondition: a founded pair whose signed roster is two")
        let leaver = rig.nodes[0].manager
        let lastMember = rig.nodes[1].manager
        LastMemberReviewFixtures.capture(2, on: lastMember)
        let captured = lastMember.sessionPhotos.map(\.id)
        try #require(captured.count == 2, "precondition: the last member took two photos")

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await leaver.leaveSessionAfterNotifyingPeers()
        }
        #expect(leaver.lastDevelopmentPlan?.ending == .termination,
                "precondition: a final pair's development signs the termination")
        try await rig.settle([1], until: { lastMember.sessionState == .terminated })

        #expect(lastMember.sessionState == .terminated, "the last member read the termination live")
        #expect(lastMember.currentMesh == nil, "and its session is over")
        #expect(!lastMember.isSessionLive, "so the presenter's gate is open")
        try Self.assertOffered(captured, on: rig.nodes[1])
        try Self.assertTheAnswerPrunesOnlyWhatWasDiscarded(captured, on: rig.nodes[1])
    }

    /// **The merge road.** The last member missed the live record and reads the termination in a
    /// merged ledger instead (`applyMergedRosterVerdict` → `applyVerifiedTermination()`).
    @Test func theLastMemberThatReadsTheTerminationAtAMergeIsOfferedEveryPhoto() async throws {
        let pair = try MeshTerminationPairScenario.build(label: "last-member-merge-")
        defer { pair.teardown() }
        LastMemberReviewFixtures.capture(2, on: pair.nodeB.manager)
        let captured = pair.nodeB.manager.sessionPhotos.map(\.id)
        try #require(captured.count == 2, "precondition: the last member took two photos")

        try Self.readTheTermination(in: pair)

        #expect(pair.nodeB.manager.sessionState == .terminated, "the merged termination ended it")
        try Self.assertOffered(captured, on: pair.nodeB)
    }

    /// **A termination read while door 3's review is already up leaves that review's photos
    /// alone.** Door 3 (five minutes with nobody) promotes the photos and holds the mesh for the
    /// review's own leave; the partner's termination arriving later used to run `leaveSession()`
    /// and empty the list the open sheet was reading. Now there is nothing left in the live list
    /// to drop, and the batch the sheet was presented from is the same batch, photos intact.
    @Test func aTerminationReadAfterTheGiveUpDoesNotTakeThePhotosFromTheOpenReview() async throws {
        let pair = try MeshTerminationPairScenario.build(label: "last-member-door3-")
        defer { pair.teardown() }
        let manager = pair.nodeB.manager
        LastMemberReviewFixtures.capture(2, on: manager)
        let captured = manager.sessionPhotos.map(\.id)
        try #require(captured.count == 2)

        manager.endSessionAfterDiscoveryTimeout()
        #expect(!manager.isSessionLive, "door 3 ended the session")
        #expect(manager.currentMesh != nil, "with the mesh held for the review's own leave")
        let presented = try #require(manager.pendingFriendReview, "door 3 promoted a batch")
        #expect(Set(presented.photos.map(\.id)) == Set(captured), "with the photos in it")

        try Self.readTheTermination(in: pair)

        #expect(manager.sessionState == .terminated)
        #expect(manager.pendingFriendReview?.id == presented.id, "the sheet's batch is still the batch")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == Set(captured),
                "and the photos it is offering were not taken out from under it")
    }

    /// A's genuine termination, merged into B's ledger — the merge road's one step.
    private static func readTheTermination(in pair: MeshTerminationPairScenario) throws {
        let record = try MeshTerminationFixtures.termination(
            by: pair.nodeA.manager.identityForTesting, meshID: pair.meshID,
            rosterAtSigning: [pair.nodeA.fingerprint, pair.nodeB.fingerprint]
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            #expect(pair.nodeB.manager.mergeMembershipLedger(
                MeshTerminationFixtures.terminationOnly(record)).isEmpty,
                    "a genuine final pair's termination verifies")
        }
    }

    /// The claims every road must meet: the batch carries exactly the captured photos,
    /// metadata-only; the live list is empty (moved, not copied); and nothing left the wall — in
    /// memory or in the persisted index — before the user was asked.
    private static func assertOffered(_ captured: [UUID], on node: MeshDepartureNode) throws {
        let manager = node.manager
        let batch = try #require(manager.pendingFriendReview, "the ending produced a review batch")
        #expect(Set(batch.photos.map(\.id)) == Set(captured),
                "carrying every photo the last member took, for the user to choose between")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == Set(captured), "all still offerable")
        #expect(batch.photos.allSatisfy { $0.imageData == nil }, "metadata only, as the live list held them")
        #expect(manager.sessionPhotos.isEmpty, "moved into the batch, not copied")
        #expect(Set(captured).isSubset(of: Set(manager.meshPhotos.map(\.id))),
                "nothing left the wall before the choice")
        let persisted = try #require(LastMemberReviewFixtures.persistedWallIDs(node.store))
        #expect(Set(captured).isSubset(of: persisted), "nor the persisted, sealed index")
        #expect(FriendMintingReview.sessionEndReview(
            hasPhotos: !manager.pendingReviewPhotos.isEmpty, eligibleCandidateCount: 0) == .photoReview,
                "so the presenter's decision is the PHOTO review, not the keep-friends prompt or nothing")
    }

    /// The user's answer — keep the first photo, discard the second — prunes exactly the discarded
    /// one, from memory and from disk, and the batch clears once both halves are answered.
    private static func assertTheAnswerPrunesOnlyWhatWasDiscarded(
        _ captured: [UUID], on node: MeshDepartureNode
    ) throws {
        let manager = node.manager
        let batch = try #require(manager.pendingFriendReview)
        let kept = captured[0]
        let discarded = captured[1]
        manager.finishReviewedPhotos(Set(captured), keeping: [kept], in: batch.id)
        #expect(manager.meshPhotos.contains { $0.id == kept }, "the kept photo stays on the wall")
        #expect(!manager.meshPhotos.contains { $0.id == discarded }, "the discarded one leaves it")
        let persisted = try #require(LastMemberReviewFixtures.persistedWallIDs(node.store))
        #expect(persisted.contains(kept) && !persisted.contains(discarded), "and the sealed index agrees")
        #expect(manager.pendingFriendReview?.photos.isEmpty ?? true, "the photo half is answered")
        if let id = manager.pendingFriendReview?.id { manager.completeFriendReview(id) }
        #expect(manager.pendingFriendReview == nil, "and with the candidate half answered, the batch is gone")
    }
}

// MARK: - Every other involuntary ending

/// The endings that are not the owner's exact case but took the same `leaveSession()` shortcut.
@MainActor
@Suite(.serialized)
struct MeshInvoluntaryEndingPhotoReviewTests {
    let store = makeTestStore()

    /// `leaveSession()` is the funnel every other ending reaches (a removal naming this device, the
    /// pairwise "Ask to remove", epoch exhaustion, a hard stop). It promotes; it never drops.
    @Test func leaveSessionPromotesTheSessionPhotosAndDropsNone() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        LastMemberReviewFixtures.capture(3, on: manager)
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 3)

        manager.leaveSession()

        #expect(Set(manager.pendingFriendReview?.photos.map(\.id) ?? []) == captured)
        #expect(manager.pendingFriendReview?.entries.isEmpty == true, "a photos-only batch is legal")
        #expect(manager.sessionPhotos.isEmpty)
        #expect(captured.isSubset(of: Set(manager.meshPhotos.map(\.id))), "nothing discarded unasked")
        #expect(manager.pendingFriendReview?.photos.allSatisfy { $0.session?.meshName == "Acceptance Meadow" } == true,
                "the ended session's metadata was stamped before its ids were cleared")
    }

    /// The ceiling — reached on EVERY device at once, so every device is a "last member" — ends
    /// through `enforceSessionCeiling` → `leaveSession()`, and the photos reach the review.
    @Test func theCeilingExpiryLeavesThePhotosInTheReview() async throws {
        let created = Date()
        let manager = LastMemberReviewFixtures.foundedManager(store: store, createdAt: created)
        defer { manager.leaveMesh() }
        manager.startSessionCeiling(
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds), startedAt: created
        )
        LastMemberReviewFixtures.capture(2, on: manager)
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 2)

        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await manager.enforceSessionCeiling(now: created, monotonicElapsed: MeshSessionCeiling.ceilingSeconds)
        }

        #expect(manager.sessionState == .expired, "precondition: the ceiling ended the session")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured)
        #expect(captured.isSubset(of: Set(manager.meshPhotos.map(\.id))))
    }

    /// A new search is a new session, and it must not silently keep what the last one left in the
    /// live list (a late arrival after a pairwise ending, a DEBUG driver's direct start).
    @Test func aNewSearchMovesLeftoverPhotosIntoTheReviewRatherThanDroppingThem() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        LastMemberReviewFixtures.capture(1, on: manager)
        let leftover = Set(manager.sessionPhotos.map(\.id))
        try #require(leftover.count == 1)
        manager.currentMesh = nil   // the ended session's mesh is gone; its photo is still listed

        manager.startJoin()

        #expect(manager.sessionPhotos.isEmpty, "the new session starts with an empty roll")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == leftover, "and the old roll awaits its answer")
    }

    /// Door 3 — five minutes with nobody — promotes the photos while holding the mesh.
    @Test func theDiscoveryGiveUpPromotesThePhotos() async throws {
        let rig = try MeshFoundingRig.build(2, label: "door3-photos")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        rig.capturePhoto(at: 0)
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 1)
        let slot = try #require(manager.slots.first)
        manager.evictSlotForTesting(peerID: slot.id)
        #expect(manager.pendingFriendReview == nil, "a blip promotes nothing")
        #expect(manager.sessionPhotos.count == 1, "and keeps the roll live")

        manager.endSessionAfterDiscoveryTimeout()

        #expect(manager.currentMesh != nil, "the mesh is held for the review's own leave")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured)
        #expect(manager.sessionPhotos.isEmpty)
    }
}

// MARK: - The review API's scoping

/// `completeFriendReview`, `finishReviewedPhotos`, the per-photo delete and the removal purge each
/// answer only what they own.
@MainActor
@Suite(.serialized)
struct PendingPhotoReviewScopingTests {
    let store = makeTestStore()

    /// A batch whose photos are pending, promoted with one candidate.
    private func endedSessionWithPhotos(_ count: Int) throws -> (MeshNetworkManager, [UUID]) {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Bea", fingerprint: "bea-fp-0011223344",
            signingPublicKey: Data([7]), keyAgreementPublicKey: Data([8])
        )
        LastMemberReviewFixtures.capture(count, on: manager)
        let captured = manager.sessionPhotos.map(\.id)
        try #require(captured.count == count)
        manager.leaveSession()
        try #require(manager.pendingFriendReview?.entries.count == 1)
        return (manager, captured)
    }

    /// The keep-friends answer consumes the candidates and never the photo choice.
    @Test func completingTheFriendHalfLeavesThePhotoChoicePending() throws {
        let (manager, captured) = try endedSessionWithPhotos(2)
        defer { manager.leaveMesh() }
        let batch = try #require(manager.pendingFriendReview)

        manager.completeFriendReview(batch.id)

        #expect(manager.pendingFriendReview?.id == batch.id, "the batch stays up")
        #expect(manager.pendingFriendReview?.entries.isEmpty == true, "with the candidates answered")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == Set(captured), "and every photo still pending")
    }

    /// The answer is scoped to what the sheet SHOWED: a photo promoted after presentation is
    /// neither discarded nor treated as kept, and a stale batch id changes nothing.
    @Test func finishingThePhotoHalfPrunesOnlyTheReviewedUnkeptPhotos() throws {
        let (manager, captured) = try endedSessionWithPhotos(3)
        defer { manager.leaveMesh() }
        let batch = try #require(manager.pendingFriendReview)
        let shown = Set(captured.prefix(2))
        let unseen = captured[2]

        manager.finishReviewedPhotos(shown, keeping: [], in: UUID())
        #expect(Set(manager.meshPhotos.map(\.id)).isSuperset(of: Set(captured)), "a stale id discards nothing")

        manager.finishReviewedPhotos(shown, keeping: [captured[0]], in: batch.id)

        let wall = Set(manager.meshPhotos.map(\.id))
        #expect(wall.contains(captured[0]), "kept")
        #expect(!wall.contains(captured[1]), "shown and unticked: discarded")
        #expect(wall.contains(unseen), "never shown: not discarded")
        #expect(manager.pendingReviewPhotos.map(\.id) == [unseen], "and still awaiting its own answer")
        #expect(manager.pendingFriendReview?.entries.count == 1, "the candidate half is untouched")
    }

    /// A photo deleted from the wall is no longer a choice, and a batch left with nothing clears.
    @Test func deletingAPendingPhotoRemovesItFromTheReview() throws {
        let (manager, captured) = try endedSessionWithPhotos(1)
        defer { manager.leaveMesh() }
        let batch = try #require(manager.pendingFriendReview)
        manager.completeFriendReview(batch.id)
        #expect(manager.pendingFriendReview != nil, "precondition: only the photo is pending")

        manager.deletePhoto(captured[0])

        #expect(manager.pendingFriendReview == nil, "nothing left to answer, so the batch clears")
    }

    /// The vote purge drops the voted-out candidate; it must not take the photo choice with it.
    @Test func aRemovalPurgeKeepsAPhotosOnlyBatch() throws {
        let (manager, captured) = try endedSessionWithPhotos(1)
        defer { manager.leaveMesh() }
        let proposal = MeshRemovalProposalPayload(
            id: UUID(), targetFingerprint: "bea-fp-0011223344", targetDisplayName: "Bea",
            proposerFingerprint: "cal-fp-5566778899", proposerDisplayName: "Cal",
            createdAt: Date(), expiresAt: Date().addingTimeInterval(60)
        )

        manager.secondRemoval(proposal)

        #expect(manager.pendingFriendReview?.entries.isEmpty == true, "the voted-out candidate is purged")
        #expect(manager.pendingReviewPhotos.map(\.id) == captured, "and the photo choice survives the purge")
    }
}

// MARK: - The presenter, hosted

/// The SwiftUI half, in a real window on the simulator: `FriendsView` presents the PHOTO review for
/// an ending that promoted photos — the sheet the owner never saw.
@MainActor
@Suite(.serialized)
struct FriendsViewLastMemberReviewPresentationTests {
    let store = makeTestStore()

    /// A colored, decodable photo big enough to read in a screenshot of the sheet.
    private static func swatch(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let side = CGSize(width: 480, height: 480)
        let image = UIGraphicsImageRenderer(size: side, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: side))
        }
        return image.jpegData(compressionQuality: 0.8) ?? MeshRoutedPhotoFixtures.tinyJPEG()
    }

    /// The owner's ending on the store's own manager — photos taken, then a teardown the person
    /// did not start (`leaveSession()`, which a verified termination runs) — and then the Friends
    /// surface appears: its model-state presenter must put up the photo review, every photo in it.
    ///
    /// `TEST_RUNNER_FERNLET_TEST_EVIDENCE_DIR` (optional) makes the cell write what the window shows
    /// as a PNG there — evidence for a review, never an assertion.
    @Test func theFriendsSurfacePresentsThePhotoReviewAfterAnEndingNobodyReviewed() async throws {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "Expected an active window scene for SwiftUI lifecycle testing"
        )
        let manager = store.meshNetworkManager
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for color in [UIColor.systemTeal, .systemOrange, .systemPink] { manager.addPhoto(Self.swatch(color)) }
        }
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 3)
        manager.leaveSession()
        try #require(!manager.isSessionLive && Set(manager.pendingReviewPhotos.map(\.id)) == captured)

        let hosting = UIHostingController(rootView: FriendsView(
            store: store, activeSheet: .constant(nil), isTabBarCompact: .constant(false),
            tabResetToken: .constant(0)
        ))
        var window: UIWindow? = UIWindow(windowScene: windowScene)
        window?.frame = windowScene.screen.bounds
        window?.rootViewController = hosting
        window?.makeKeyAndVisible()
        defer {
            hosting.dismiss(animated: false)
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
        }
        // R2: bounded — at most 60 polls of 100 ms for the sheet's presentation to land.
        for _ in 0..<60 where hosting.presentedViewController == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(800))   // let the sheet's slide-up settle for the capture

        #expect(hosting.presentedViewController != nil,
                "the Friends surface presented a sheet for the promoted batch — the photo review")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured,
                "and nothing was consumed or kept on the way: the choice is still the person's")
        if let window { Self.writeEvidence(of: window) }
    }

    /// Renders the window (the presented sheet included) to a PNG in the evidence directory, when
    /// one was named. Evidence only; a failed write changes no verdict.
    private static func writeEvidence(of window: UIWindow) {
        guard let directory = ProcessInfo.processInfo.environment["FERNLET_TEST_EVIDENCE_DIR"] else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("last-member-photo-review.png")
        do {
            try image.pngData()?.write(to: url)
        } catch {
            print("evidence not written: \(error)")
        }
    }
}

// MARK: - Source walls

/// The defect lived in two places a behavioral cell cannot reach at once — the manager's teardown
/// and the SwiftUI presenter — so both are pinned by reading the shipping source.
@Suite
struct LastMemberPhotoReviewSourceWallTests {

    /// Only the user's answer and the promotion may empty the live photo list.
    @Test func theLivePhotoListIsEmptiedOnlyByAnAnswerOrThePromotion() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        #expect(source.components(separatedBy: "sessionPhotos.removeAll()").count - 1 == 2,
                "exactly two bulk empties: finishSessionPhotos (the answer) and the promotion's move")
        let answer = try #require(MeshRoutedSourceScan.bracedBody(
            after: "public func finishSessionPhotos(keeping", in: source))
        let promotion = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func movePhotosIntoPendingReview()", in: source))
        #expect(answer.contains("sessionPhotos.removeAll()"))
        #expect(promotion.contains("sessionPhotos.removeAll()"))
        #expect(promotion.contains("pendingFriendReview = batch"), "the promotion moves, never drops")
        let leave = try #require(MeshRoutedSourceScan.bracedBody(after: "public func leaveSession()", in: source))
        #expect(!leave.contains("sessionPhotos"), "leaveSession decides nothing about the photos")
        let join = try #require(MeshRoutedSourceScan.bracedBody(after: "public func startJoin()", in: source))
        #expect(join.contains("movePhotosIntoPendingReview()"), "a new search promotes leftovers too")
    }

    /// The presenter reads the batch, never the live list, and its answers are scoped to the batch.
    @Test func theFriendsReviewReadsTheBatchAndAnswersIt() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        #expect(!source.contains("manager.sessionPhotos"),
                "FriendsView must never read the live list: the ending empties it before the presenter runs")
        let present = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func presentDisconnectReviewIfNeeded()", in: source))
        #expect(present.contains("manager.pendingReviewPhotos"), "the photos come from the batch")
        for action in ["private func keepSelectedSessionPhotos()", "private func discardAllSessionPhotos()"] {
            let body = try #require(MeshRoutedSourceScan.bracedBody(after: action, in: source), "\(action) is gone")
            #expect(body.contains("finishReviewedPhotos("), "\(action) answers the batch's photo half")
            #expect(body.contains("if manager.currentMesh != nil"),
                    "\(action) leaves only a mesh that is still held (door 3)")
        }
        #expect(source.contains(".onChange(of: scenePhase)"), "a review promoted in the dark presents on return")
    }
}

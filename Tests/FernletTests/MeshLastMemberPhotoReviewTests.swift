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
// **And since the owner's 2026-09-30 answer, nothing is on the wall before the choice.** Every
// session photo is HELD in the sealed pending corpus from capture or receipt; the cells that used to
// assert "still on the wall, not yet pruned" now assert the inverse — held, and NOT on the wall, in
// memory or in the persisted index — and every cell that answers pushes an open routed gate first,
// because the answer (which reads plaintext to re-seal kept photos under the wall key) runs only
// where the gate is open.
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
    /// metadata-only; the live list is empty (moved, not copied); and NOTHING is on the wall — in
    /// memory or in the persisted index — before the user was asked, while every photo is held in
    /// the sealed pending corpus (2026-09-30: inverted from "nothing left the wall").
    private static func assertOffered(_ captured: [UUID], on node: MeshDepartureNode) throws {
        let manager = node.manager
        let batch = try #require(manager.pendingFriendReview, "the ending produced a review batch")
        #expect(Set(batch.photos.map(\.id)) == Set(captured),
                "carrying every photo the last member took, for the user to choose between")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == Set(captured), "all still offerable")
        #expect(batch.photos.allSatisfy { $0.imageData == nil }, "metadata only, as the live list held them")
        #expect(manager.sessionPhotos.isEmpty, "moved into the batch, not copied")
        #expect(Set(captured).isDisjoint(with: Set(manager.meshPhotos.map(\.id))),
                "nothing is on the wall before the choice")
        let persisted = LastMemberReviewFixtures.persistedWallIDs(node.store) ?? []
        #expect(Set(captured).isDisjoint(with: persisted), "nor in the persisted, sealed wall index")
        let held = try #require(HeldPhotos.persistedIndex(node.store), "the pending index reads back")
        #expect(Set(captured).isSubset(of: held.heldLocalIDs), "every photo is held in the sealed pending corpus")
        #expect(FriendMintingReview.sessionEndReview(
            hasPhotos: !manager.pendingReviewPhotos.isEmpty, eligibleCandidateCount: 0) == .photoReview,
                "so the presenter's decision is the PHOTO review, not the keep-friends prompt or nothing")
    }

    /// The user's answer — keep the first photo, discard the second — puts exactly the kept one on
    /// the wall, in memory and on disk, deletes the other, and the batch clears once both halves
    /// are answered.
    private static func assertTheAnswerPrunesOnlyWhatWasDiscarded(
        _ captured: [UUID], on node: MeshDepartureNode
    ) throws {
        let manager = node.manager
        let batch = try #require(manager.pendingFriendReview)
        let kept = captured[0]
        let discarded = captured[1]
        HeldPhotos.openGate(on: manager)
        let answer = manager.finishReviewedPhotos(Set(captured), keeping: [kept], in: batch.id)
        #expect(answer.keptOnWall == [kept] && answer.discarded == [discarded] && answer.notApplied.isEmpty)
        #expect(manager.meshPhotos.contains { $0.id == kept }, "the kept photo reaches the wall")
        #expect(!manager.meshPhotos.contains { $0.id == discarded }, "the discarded one never does")
        let persisted = try #require(LastMemberReviewFixtures.persistedWallIDs(node.store))
        #expect(persisted.contains(kept) && !persisted.contains(discarded), "and the sealed index agrees")
        let held = try #require(HeldPhotos.persistedIndex(node.store))
        #expect(held.heldLocalIDs.isDisjoint(with: captured), "neither is held any more")
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
        #expect(captured.isDisjoint(with: Set(manager.meshPhotos.map(\.id))), "nothing kept unasked")
        #expect(captured.isSubset(of: HeldPhotos.persistedIndex(store)?.heldLocalIDs ?? []),
                "and nothing discarded unasked: every photo is still held")
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
        #expect(captured.isDisjoint(with: Set(manager.meshPhotos.map(\.id))), "held, never on the wall")
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

// MARK: - The in-camera review under door 3

/// Fix round findings C-F1/L-F1: door 3's give-up ends the session while the mesh is HELD, so the
/// camera — and a Develop review it already has open — stays on screen while the ending moves the
/// live list into the pending batch. The review snapshots its ids at Develop and renders/answers
/// them wherever the manager holds them; before, it read `sessionPhotos`, went empty, and its
/// "Delete all" pruned nothing.
@MainActor
@Suite(.serialized)
struct MeshDevelopReviewUnderGiveUpTests {

    /// A founded pair whose partner vanished: `captureCount` photos on node 0, the camera's
    /// Develop snapshot taken, the slot lost, and then door 3 fires — the reviewer's sequence.
    private static func developThenGiveUp(
        _ rig: MeshFoundingRig, captureCount: Int
    ) throws -> (MeshNetworkManager, [UUID]) {
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        // R2: bounded by the caller's count.
        for _ in 0..<captureCount { rig.capturePhoto(at: 0) }
        let snapshot = manager.sessionPhotos.map(\.id)   // beginDevelop()'s snapshot
        try #require(snapshot.count == captureCount)
        let slot = try #require(manager.slots.first)
        manager.evictSlotForTesting(peerID: slot.id)
        manager.endSessionAfterDiscoveryTimeout()
        try #require(!manager.isSessionLive && manager.currentMesh != nil,
                     "precondition: door 3 ended the session and holds the mesh, so the camera stays up")
        try #require(manager.isInSession, "precondition: the Friends surface keeps the camera and its review")
        try #require(manager.sessionPhotos.isEmpty, "precondition: the ending moved the roll out from under it")
        return (manager, snapshot)
    }

    /// The open review keeps offering every photo it snapshotted, and its "Keep selected" answer —
    /// one kept, two unticked — lands: only the ticked one reaches the wall and the sealed index, and
    /// nothing is left pending to be asked about again.
    @Test func theOpenDevelopReviewStillOffersAndAnswersItsPhotosAfterTheGiveUp() throws {
        let rig = try MeshFoundingRig.build(2, label: "develop-door3")
        defer { rig.teardown() }
        let (manager, snapshot) = try Self.developThenGiveUp(rig, captureCount: 3)

        #expect(manager.photosAwaitingAnswer(among: Set(snapshot)).map(\.id) == snapshot,
                "the grid the person is looking at still holds every photo it offered, in order")

        HeldPhotos.openGate(on: manager)
        let answer = manager.finishSessionPhotos(keeping: [snapshot[0]], of: Set(snapshot))

        #expect(answer.keptOnWall == [snapshot[0]] && answer.discarded == Set(snapshot.dropFirst()))
        let wall = Set(manager.meshPhotos.map(\.id))
        #expect(wall.contains(snapshot[0]), "the ticked photo is kept")
        #expect(!wall.contains(snapshot[1]) && !wall.contains(snapshot[2]), "the unticked ones never reach the wall")
        let persisted = try #require(LastMemberReviewFixtures.persistedWallIDs(rig.nodes[0].store))
        #expect(persisted.contains(snapshot[0]) && persisted.isDisjoint(with: snapshot.dropFirst()),
                "and the sealed index agrees")
        #expect(manager.pendingReviewPhotos.isEmpty, "answered once: FriendsView has nothing to re-ask")
        #expect(manager.pendingFriendReview?.photos.isEmpty ?? true)
    }

    /// The reviewer's exact failure: "Delete all" confirmed in the camera after the give-up.
    @Test func deleteAllInTheOpenDevelopReviewAfterTheGiveUpRemovesEveryPhoto() throws {
        let rig = try MeshFoundingRig.build(2, label: "develop-door3-delete")
        defer { rig.teardown() }
        let (manager, snapshot) = try Self.developThenGiveUp(rig, captureCount: 2)

        HeldPhotos.openGate(on: manager)
        let answer = manager.finishSessionPhotos(keeping: [], of: Set(snapshot))

        #expect(answer.discarded == Set(snapshot))
        #expect(Set(manager.meshPhotos.map(\.id)).isDisjoint(with: snapshot), "no photo reached the wall")
        let persisted = LastMemberReviewFixtures.persistedWallIDs(rig.nodes[0].store) ?? []
        #expect(persisted.isDisjoint(with: snapshot), "nor the sealed index")
        let held = try #require(HeldPhotos.persistedIndex(rig.nodes[0].store))
        #expect(held.heldLocalIDs.isDisjoint(with: snapshot), "and the pending corpus let every one go")
        #expect(manager.photosAwaitingAnswer(among: Set(snapshot)).isEmpty, "nothing left to offer")
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
        HeldPhotos.openGate(on: manager)

        #expect(manager.finishReviewedPhotos(shown, keeping: [], in: UUID()) == .nothing, "a stale id answers nothing")
        #expect(HeldPhotos.ids(manager).isSuperset(of: Set(captured)), "and discards nothing")

        let answer = manager.finishReviewedPhotos(shown, keeping: [captured[0]], in: batch.id)

        #expect(answer.keptOnWall == [captured[0]] && answer.discarded == [captured[1]])
        let wall = Set(manager.meshPhotos.map(\.id))
        #expect(wall.contains(captured[0]), "kept")
        #expect(!wall.contains(captured[1]) && !HeldPhotos.ids(manager).contains(captured[1]),
                "shown and unticked: deleted, never on the wall")
        #expect(!wall.contains(unseen) && HeldPhotos.ids(manager).contains(unseen), "never shown: still held")
        #expect(manager.pendingReviewPhotos.map(\.id) == [unseen], "and still awaiting its own answer")
        #expect(manager.pendingFriendReview?.entries.count == 1, "the candidate half is untouched")
    }

    /// The camera's answer ignores an id someone already answered: the post-session review kept it,
    /// so a later "Delete all" from a review that also showed it must not discard it.
    @Test func aDevelopAnswerIgnoresPhotosAlreadyAnswered() throws {
        let (manager, captured) = try endedSessionWithPhotos(2)
        defer { manager.leaveMesh() }
        let batch = try #require(manager.pendingFriendReview)
        HeldPhotos.openGate(on: manager)
        #expect(manager.finishReviewedPhotos(Set(captured), keeping: Set(captured), in: batch.id).keptOnWall == Set(captured))

        let late = manager.finishSessionPhotos(keeping: [], of: Set(captured))

        #expect(late == .nothing, "no longer held, so nothing to answer")
        #expect(Set(manager.meshPhotos.map(\.id)).isSuperset(of: Set(captured)), "the first answer stands")
    }

    /// A photo that arrived after the Develop snapshot was never shown, so the camera's answer
    /// leaves it listed — it reaches the post-session review at the teardown, ticked.
    @Test func aDevelopAnswerLeavesAPhotoItNeverShowedForThePostSessionReview() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        LastMemberReviewFixtures.capture(2, on: manager)
        let snapshot = Set(manager.sessionPhotos.map(\.id))
        LastMemberReviewFixtures.capture(1, on: manager)   // lands while the sheet is up
        let late = try #require(manager.sessionPhotos.first { !snapshot.contains($0.id) }?.id)
        HeldPhotos.openGate(on: manager)

        #expect(manager.finishSessionPhotos(keeping: [], of: snapshot).discarded == snapshot)
        #expect(manager.sessionPhotos.map(\.id) == [late], "only what the sheet showed was answered")
        manager.leaveSession()

        #expect(manager.pendingReviewPhotos.map(\.id) == [late], "and the late one awaits its own answer")
        #expect(HeldPhotos.persistedIndex(store)?.heldLocalIDs == [late], "still held, not discarded unseen")
    }

    /// A held photo leaves only through an answer (2026-09-30): a per-photo delete of one is
    /// refused, so the batch keeps offering it and the pending corpus keeps holding it — a delete
    /// that dropped it from memory while the index kept it would bring it back at the next launch.
    @Test func deletingAHeldPhotoIsRefusedAndTheBatchKeepsIt() throws {
        let (manager, captured) = try endedSessionWithPhotos(1)
        defer { manager.leaveMesh() }
        let batch = try #require(manager.pendingFriendReview)
        manager.completeFriendReview(batch.id)
        #expect(manager.pendingFriendReview != nil, "precondition: only the photo is pending")

        manager.deletePhoto(captured[0])

        #expect(manager.pendingReviewPhotos.map(\.id) == captured, "still offered")
        #expect(HeldPhotos.persistedIndex(store)?.heldLocalIDs == Set(captured), "and still held on disk")
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
        HeldPhotos.openGate(on: manager)   // the review presents held photos only where its seam is open
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

    /// Fix round findings C-F2/L-F2: the session ends in the SAME main-actor turn that lowers a sheet
    /// the Friends surface does not own (here one hung by the view containing it — ContentView's
    /// other root slots). The reviewers' concern was a request dropped in that transaction and then
    /// latched. On the iOS 26.5 simulator SwiftUI did NOT drop it, even with the pre-round immediate
    /// presenter and no watchdog (red-check 2026-09-30: green both ways), so this cell pins the
    /// outcome — the review lands, every photo still pending — rather than proving the latch.
    @Test func aReviewDueInTheSameTransactionAsAnotherSheetClosingStillLands() async throws {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "Expected an active window scene for SwiftUI lifecycle testing"
        )
        let manager = store.meshNetworkManager
        HeldPhotos.openGate(on: manager)   // the review presents held photos only where its seam is open
        let cover = ForeignCoverModel()
        let hosting = UIHostingController(rootView: ForeignCoverHost(store: store, cover: cover))
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
        try await Task.sleep(for: .milliseconds(500))   // the album surface settles, nothing pending
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for color in [UIColor.systemTeal, .systemOrange] { manager.addPhoto(Self.swatch(color)) }
        }
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 2)
        cover.isUp = true
        // R2: bounded — at most 30 polls of 100 ms for the cover to land.
        for _ in 0..<30 where !holdsForeignCover(hosting.presentedViewController) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(holdsForeignCover(hosting.presentedViewController), "precondition: the cover is up")

        // One turn: the covering sheet goes and the session ends — nobody reviewing.
        cover.isUp = false
        manager.leaveSession()

        // R2: bounded — at most 100 polls of 100 ms for the review to land.
        for _ in 0..<100 where hosting.presentedViewController == nil || holdsForeignCover(hosting.presentedViewController) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(hosting.presentedViewController != nil && !holdsForeignCover(hosting.presentedViewController),
                "the photo review landed after the other sheet went — no dropped, latched request")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured,
                "and nothing was answered on the way")
    }

    /// The camera's teardown shape (finding C-F2): the view that OWNS a presented sheet leaves the
    /// hierarchy in the same main-actor turn as the ending — the camera swapping out with its chat,
    /// info or Develop sheet up. As above, not a drop on the iOS 26.5 simulator either way; the cell
    /// pins that the review lands, every photo pending.
    @Test func aReviewDueAsASheetOwnerLeavesTheHierarchyStillLands() async throws {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "Expected an active window scene for SwiftUI lifecycle testing"
        )
        let manager = store.meshNetworkManager
        HeldPhotos.openGate(on: manager)   // the review presents held photos only where its seam is open
        let cover = ForeignCoverModel()
        let hosting = UIHostingController(rootView: ForeignCoverHost(store: store, cover: cover))
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
        try await Task.sleep(for: .milliseconds(500))
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for color in [UIColor.systemTeal, .systemOrange] { manager.addPhoto(Self.swatch(color)) }
        }
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 2)
        cover.childMounted = true
        try await Task.sleep(for: .milliseconds(200))
        cover.isChildSheetUp = true
        // R2: bounded — at most 30 polls of 100 ms for the owner's sheet to land.
        for _ in 0..<30 where !holdsForeignCover(hosting.presentedViewController) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(holdsForeignCover(hosting.presentedViewController), "precondition: the owner's sheet is up")

        // One turn: the sheet's owner leaves the hierarchy and the session ends.
        cover.childMounted = false
        manager.leaveSession()

        // R2: bounded — at most 100 polls of 100 ms for the review to land.
        for _ in 0..<100 where hosting.presentedViewController == nil || holdsForeignCover(hosting.presentedViewController) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(hosting.presentedViewController != nil && !holdsForeignCover(hosting.presentedViewController),
                "the photo review landed after the owner and its sheet went")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured, "and nothing was answered on the way")
    }

    /// Fix round finding L-F2 (d), and the hazard the empirical run actually showed: on the iOS 26.5
    /// simulator a sheet requested by `FriendsView` while a sheet of a view ABOVE it is up does not
    /// drop — SwiftUI REPLACES the standing one ("only presenting a single sheet is supported"). So a
    /// review requested over the root router's sheet (a First Aid route consumed on the same
    /// activation, a meal log, Settings' Delete everything) took that sheet away. The presenter now
    /// waits out `activeSheet` and re-checks the moment it closes. Red-checked 2026-09-30: with the
    /// `activeSheet` leg of the guard removed, the first expectation fails.
    @Test func aReviewWaitsOutTheRootSheetInsteadOfReplacingIt() async throws {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "Expected an active window scene for SwiftUI lifecycle testing"
        )
        let manager = store.meshNetworkManager
        HeldPhotos.openGate(on: manager)   // the review presents held photos only where its seam is open
        let cover = ForeignCoverModel()
        let hosting = UIHostingController(rootView: ForeignCoverHost(store: store, cover: cover))
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
        try await Task.sleep(for: .milliseconds(500))
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for color in [UIColor.systemTeal, .systemOrange] { manager.addPhoto(Self.swatch(color)) }
        }
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 2)
        cover.rootSheet = .journal
        // R2: bounded — at most 30 polls of 100 ms for the root sheet to land.
        for _ in 0..<30 where !holdsForeignCover(hosting.presentedViewController) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(holdsForeignCover(hosting.presentedViewController), "precondition: the root sheet is up")

        manager.leaveSession()
        try await Task.sleep(for: .milliseconds(2_500))   // past the deferred check and a landing grace

        #expect(holdsForeignCover(hosting.presentedViewController),
                "the root sheet is still the one on screen: the review did not replace it")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured, "and the review is still owed")
        cover.rootSheet = nil
        // R2: bounded — at most 100 polls of 100 ms for the review to land once the root sheet goes.
        for _ in 0..<100 where hosting.presentedViewController == nil || holdsForeignCover(hosting.presentedViewController) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(hosting.presentedViewController != nil && !holdsForeignCover(hosting.presentedViewController),
                "then the review lands on its own, off the root sheet closing")
    }

    /// Fix round 1, U2-L-U2-R1: a photo review owed under a duress decoy does NOT present — its
    /// tiles would be blank, every answer refused, the sheet not dismissable, and "N photos waiting"
    /// is itself the tell — yet nothing is answered or deleted; it presents once the decoy ends. A
    /// review that is up when a duress session starts is withdrawn, again answering nothing.
    /// Red-checked: without the presenter's duress guard the first expectation fails.
    @Test func aPhotoReviewNeverPresentsUnderADuressDecoyAndReturnsAfterIt() async throws {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "Expected an active window scene for SwiftUI lifecycle testing"
        )
        let manager = store.meshNetworkManager
        HeldPhotos.openGate(on: manager)
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for color in [UIColor.systemTeal, .systemOrange] { manager.addPhoto(Self.swatch(color)) }
        }
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 2)
        manager.leaveSession()
        Self.enterDuress(on: manager, store: store)

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
        try await Task.sleep(for: .milliseconds(2_500))   // past the deferred check and a landing grace

        #expect(hosting.presentedViewController == nil, "no photo review under the decoy")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured, "and nothing answered or deleted")

        store.duressSessionActive = false
        HeldPhotos.openGate(on: manager)
        // R2: bounded — at most 60 polls of 100 ms for the review to land once the decoy ends.
        for _ in 0..<60 where hosting.presentedViewController == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(hosting.presentedViewController != nil, "the decoy ending brings the review back")

        Self.enterDuress(on: manager, store: store)
        // R2: bounded — at most 60 polls of 100 ms for the withdrawal to land.
        for _ in 0..<60 where hosting.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(hosting.presentedViewController == nil, "a duress session starting withdraws the review")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured, "unanswered: every photo still held")
    }

    /// Puts `store` and `manager` into a duress session the way the app does: the store's flag (the
    /// views read it) and the routed gate's duress leg (the decrypt seam reads it).
    private static func enterDuress(on manager: MeshNetworkManager, store: FernletStore) {
        store.duressSessionActive = true
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.applyRoutedAccessGate(HeldPhotoFixtures.duressGate, now: Date())
        }
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

/// The test's stand-in for a presentation the Friends surface cannot see: a sheet hung by the view
/// that contains it, raised and lowered by the cell.
@MainActor
@Observable
final class ForeignCoverModel {
    /// Whether the container's sheet is up.
    var isUp = false
    /// Whether the child that owns ``isChildSheetUp``'s sheet is in the hierarchy at all.
    var childMounted = false
    /// Whether the mounted child's own sheet is up.
    var isChildSheetUp = false
    /// The root router's slot, bound to `FriendsView.activeSheet` exactly as ContentView binds it.
    var rootSheet: FernletSheet?
}

/// `FriendsView` inside a container whose sheets the cell drives: a root-router slot bound to
/// `activeSheet` (ContentView's shape), a container sheet `FriendsView` cannot see (ContentView's
/// other root slots), and a child that owns a sheet and can leave the hierarchy (the camera's shape).
struct ForeignCoverHost: View {
    let store: FernletStore
    @Bindable var cover: ForeignCoverModel

    var body: some View {
        ZStack {
            FriendsView(
                store: store, activeSheet: $cover.rootSheet, isTabBarCompact: .constant(false),
                tabResetToken: .constant(0)
            )
            if cover.childMounted {
                Color.clear
                    .frame(width: 1, height: 1)
                    .sheet(isPresented: $cover.isChildSheetUp) { ForeignCoverMarker() }
            }
        }
        .sheet(isPresented: $cover.isUp) {
            ForeignCoverMarker()
        }
        .sheet(item: $cover.rootSheet) { _ in
            ForeignCoverMarker()
        }
    }
}

/// A UIKit view the cell can find in a presented controller's hierarchy: which sheet is up.
final class ForeignCoverMarkerView: UIView {}

/// The cover sheet's content, recognizable by its ``ForeignCoverMarkerView``.
struct ForeignCoverMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> ForeignCoverMarkerView { ForeignCoverMarkerView() }
    func updateUIView(_ uiView: ForeignCoverMarkerView, context: Context) {}
}

/// Whether `controller`'s view hierarchy holds the cover's marker (bounded breadth-first walk).
@MainActor
func holdsForeignCover(_ controller: UIViewController?) -> Bool {
    guard let root = controller?.view else { return false }
    var queue: [UIView] = [root]
    var index = 0
    // R2: bounded by the finite view tree, and capped.
    while index < queue.count, index < 5_000 {
        if queue[index] is ForeignCoverMarkerView { return true }
        queue.append(contentsOf: queue[index].subviews)
        index += 1
    }
    return false
}

// MARK: - Source walls

/// The defect lived in two places a behavioral cell cannot reach at once — the manager's teardown
/// and the SwiftUI presenter — so both are pinned by reading the shipping source.
@Suite
struct LastMemberPhotoReviewSourceWallTests {

    /// Only the user's answer, the promotion and delete-all may empty the live photo list.
    @Test func theLivePhotoListIsEmptiedOnlyByAnAnswerOrThePromotion() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        #expect(source.components(separatedBy: "sessionPhotos.removeAll()").count - 1 == 1,
                "exactly one bulk move: the promotion's (the answers remove what they answered)")
        #expect(source.components(separatedBy: "sessionPhotos = []").count - 1 == 1,
                "and exactly one other emptier: delete-all's purge of the photos nobody chose")
        let purge = try #require(MeshRoutedSourceScan.bracedBody(
            after: "public func purgeHeldSessionPhotosForDeleteAll() -> Bool", in: source))
        #expect(purge.contains("sessionPhotos = []") && purge.contains("heldPhotoStore.purgeAll()"),
                "the purge empties the roll AND the corpus behind it, never one without the other")
        let answer = try #require(MeshRoutedSourceScan.bracedBody(
            after: "public func finishSessionPhotos(keeping kept: Set<UUID>, of reviewed: Set<UUID>) -> SessionPhotoAnswer",
            in: source))
        let engine = try #require(MeshRoutedSourceScan.bracedBody(
            after: "func applyPhotoAnswers(kept: Set<UUID>, discarded: Set<UUID>, now: Date) -> SessionPhotoAnswer",
            in: source))
        let forget = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func forgetAnsweredHeldPhotos(_ ids: Set<UUID>)", in: source))
        let promotion = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func movePhotosIntoPendingReview()", in: source))
        #expect(answer.contains("applyPhotoAnswers("), "the camera's answer runs through the one engine")
        #expect(engine.contains("forgetAnsweredHeldPhotos("), "which takes what it answered out of the lists")
        #expect(forget.contains("sessionPhotos.removeAll { ids.contains($0.id) }"),
                "out of the live list")
        #expect(forget.contains("batch.photos.removeAll { ids.contains($0.id) }"),
                "and out of the pending batch, where door 3 may have moved it (C-F1/L-F1)")
        #expect(promotion.contains("sessionPhotos.removeAll()"))
        #expect(promotion.contains("pendingFriendReview = batch"), "the promotion moves, never drops")
        #expect(!promotion.contains("heldPhotoStore") && !promotion.contains("photoCacheStore"),
                "and writes nothing (I6): both lists are memory projections of the pending index")
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
        for action in ["private func keepSelectedSessionPhotos() async", "private func discardAllSessionPhotos() async"] {
            let body = try #require(MeshRoutedSourceScan.bracedBody(after: action, in: source), "\(action) is gone")
            #expect(body.contains("finishReviewedPhotos("), "\(action) answers the batch's photo half")
            #expect(body.contains("await finishPhotoReview(after: answer, leaving: leaving)"),
                    "\(action) reads what its answer did")
            // Fix round 1, U2-L-U2-R4: the mesh to leave is decided AT the answer, before any await.
            let decided = try #require(body.range(of: "let leaving = meshToLeaveAfterTheAnswer()"),
                                       "\(action) decides what to leave at the answer")
            let answered = try #require(body.range(of: "finishReviewedPhotos("))
            #expect(decided.lowerBound < answered.lowerBound, "\(action) decides before it answers or awaits")
        }
        let finish = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func finishPhotoReview(after answer: SessionPhotoAnswer, leaving: UUID?) async", in: source))
        #expect(finish.contains("guard answer.notApplied.isEmpty else"),
                "an answer that did not apply keeps the sheet up (no hide-and-re-present loop)")
        #expect(finish.contains("if let leaving, manager.currentMesh?.meshID == leaving, !manager.isSessionLive"),
                "and a finished one leaves only the mesh its answer found held, and only while it is still not live")
        #expect(!finish.contains("if manager.currentMesh != nil"),
                "never whatever mesh is current after the export, the notice or the alert (U2-L-U2-R4)")
        let decide = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func meshToLeaveAfterTheAnswer() -> UUID?", in: source))
        #expect(decide.contains("guard !manager.isSessionLive else { return nil }"),
                "an answer over a live session leaves nothing")
        #expect(source.contains(".onChange(of: scenePhase)"), "a review promoted in the dark presents on return")
    }

    /// Fix round 1, U2-L-U2-R1: the Friends surface never presents held photos under a duress decoy
    /// or while the manager's decrypt seam is shut, withdraws a review that is up — unanswered — when
    /// a duress session starts, re-checks on both edges, and never traps the person in a review whose
    /// every answer is refused.
    @Test func theFriendsReviewHidesUnderDuressAndIsNeverATrap() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        let present = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func presentDisconnectReviewIfNeeded()", in: source))
        let gate = try #require(present.range(of: "guard !manager.hasOutstandingPhotoReview || heldPhotosMayBeReviewed else { return }"),
                                "a review with photos waits for the seam and never presents under duress")
        let snapshot = try #require(present.range(of: "reviewBatch = batch"))
        #expect(gate.lowerBound < snapshot.lowerBound, "decided before anything is snapshotted or requested")
        let may = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private var heldPhotosMayBeReviewed: Bool", in: source))
        #expect(may.contains("!store.duressSessionActive") && may.contains("manager.heldPhotosCanBeShown"))
        let duress = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func handleDuressSessionChange(active: Bool)", in: source))
        #expect(duress.contains("disconnectReviewPresented = false") && duress.contains("reviewBatch = nil"),
                "a duress session starting withdraws the review")
        #expect(!duress.contains("finishReviewedPhotos") && !duress.contains("completeFriendReview"),
                "without answering anything: hide, never delete")
        #expect(duress.contains("scheduleReviewCheck()"), "and the decoy ending brings it back")
        #expect(source.contains(".onChange(of: store.duressSessionActive)"))
        #expect(source.contains(".onChange(of: manager.heldPhotosCanBeShown)"))
        #expect(source.contains(".interactiveDismissDisabled(manager.wallCanTakeKeeps && reviewAnswerFailure == nil)"),
                "an answer that did not apply leaves a swipe-down that answers nothing")
    }

    /// Fix round C-F2/L-F2: every trigger schedules, the check refuses over presentations this
    /// surface does not own, and an unlanded request is withdrawn and re-asked rather than latched.
    @Test func theFriendsPresenterNeverLatchesADroppedRequest() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        #expect(source.components(separatedBy: "presentDisconnectReviewIfNeeded()").count - 1 == 2,
                "declared once and called once — from the deferred check; every trigger schedules")
        let deferred = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func runDeferredReviewCheck() async", in: source))
        #expect(deferred.contains("presentDisconnectReviewIfNeeded()"))
        let present = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func presentDisconnectReviewIfNeeded()", in: source))
        #expect(present.contains("guard activeSheet == nil, !cameraPresentsOwnSheet else { return }"),
                "no request over the root sheet or the camera's own sheets")
        #expect(present.components(separatedBy: "noteSessionEndSheetRequested()").count - 1 == 2,
                "both session-end sheets arm the landing watchdog")
        let watchdog = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func confirmSessionEndSheetLanded() async", in: source))
        #expect(watchdog.contains("!sessionEndSheetLanded") && watchdog.contains("withdrawUnlandedSessionEndSheet()"),
                "an unlanded request is withdrawn")
        #expect(watchdog.contains("guard reviewRetriesLeft > 0 else { return }"), "and re-asked a bounded number of times")
        let withdraw = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func withdrawUnlandedSessionEndSheet()", in: source))
        #expect(!withdraw.contains("completeFriendReview") && !withdraw.contains("finishReviewedPhotos"),
                "withdrawing answers nothing")
        #expect(source.contains("DisposableCameraView(store: store, presentsOwnSheet: $cameraPresentsOwnSheet)"),
                "the camera reports its own sheets up")
        #expect(source.contains(".onChange(of: cameraPresentsOwnSheet)") && source.contains(".onChange(of: activeSheet == nil)"),
                "and each covering presentation re-checks when it goes")
    }

    /// Fix round C-F1/L-F1: the camera's Develop review renders and answers its snapshotted ids,
    /// never the live list an ending can move out from under it.
    @Test func theCameraReviewAnswersItsSnapshotWhereverThePhotosAreHeld() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/DisposableCameraView.swift"))
        let sheet = try #require(MeshRoutedSourceScan.bracedBody(after: "private var reviewSheet: some View", in: source))
        #expect(sheet.contains("photos: developReviewPhotos"), "the grid renders the snapshot wherever it is held")
        let discard = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func discardAllSessionPhotos() async", in: source))
        #expect(discard.contains("manager.finishSessionPhotos(keeping: [], of: developReviewIDs)"),
                "Delete all answers the snapshot")
        let keep = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func keepSelectedSessionPhotos() async", in: source))
        #expect(keep.contains("manager.finishSessionPhotos(keeping: selectedForSave, of: developReviewIDs)"),
                "Keep selected answers the snapshot")
        #expect(!source.contains("deleteAllSessionPhotos()"), "no answer scoped to the live list alone")
        #expect(source.contains("manager.photosAwaitingAnswer(among: developReviewIDs)"))
    }
}

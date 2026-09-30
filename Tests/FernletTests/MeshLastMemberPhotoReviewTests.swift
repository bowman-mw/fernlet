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

/// The SwiftUI half, in real windows on the simulator. Since session photos U3 the photo review is
/// not `FriendsView`'s sheet: `SessionPhotoReviewCoordinator` draws it in its own overlay window,
/// above whatever the main window shows — so these cells host the Friends surface (and the sheets
/// it cannot see) in a main window and assert the OVERLAY: that it is the first thing shown after
/// an ending nobody reviewed, that it lands above (never instead of) a sheet that is up, that it
/// never draws under a duress decoy, and that a keep-friends prompt already up is withdrawn,
/// unanswered, so the overlay answers that session's candidates once (I17).
@MainActor
@Suite(.serialized)
struct FriendsViewLastMemberReviewPresentationTests {
    let store = makeTestStore()

    /// A colored, decodable photo big enough to read in a screenshot of the review.
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

    /// The store's own coordinator, attached to `scene` and fed a launched, active scene — what
    /// ContentView's triggers do in the app.
    private func armedCoordinator(on scene: UIWindowScene) -> SessionPhotoReviewCoordinator {
        let coordinator = store.sessionPhotoReviewCoordinator
        coordinator.attach(to: scene)
        coordinator.launchComplete = true
        coordinator.scenePhase = .active
        return coordinator
    }

    /// Takes the overlay down and disarms the coordinator, so no settled evaluation can draw over
    /// the next cell.
    private static func disarm(_ coordinator: SessionPhotoReviewCoordinator) {
        coordinator.launchComplete = false
        coordinator.crisisSurfaceUp = true   // a showing review steps aside at once, answering nothing
        coordinator.presenter.hide()
    }

    /// Whether `scene` shows the review's overlay window.
    private static func overlayShows(on scene: UIWindowScene) -> Bool {
        scene.windows.contains {
            $0.accessibilityIdentifier == SessionPhotoReviewOverlayPresenter.windowIdentifier && !$0.isHidden
        }
    }

    /// Takes `colors.count` photos on the store's manager inside a mesh, then ends the session with
    /// a teardown nobody reviewed (`leaveSession()`, which a verified termination runs).
    private func endWithPhotos(_ colors: [UIColor]) throws -> Set<UUID> {
        let manager = store.meshNetworkManager
        HeldPhotos.openGate(on: manager)   // the review presents held photos only where its seam is open
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for color in colors { manager.addPhoto(Self.swatch(color)) }
        }
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == colors.count)
        manager.leaveSession()
        try #require(!manager.isSessionLive && Set(manager.pendingReviewPhotos.map(\.id)) == captured)
        return captured
    }

    /// The owner's ending, then the review: the overlay is up — over the Friends surface, which
    /// itself presents nothing for photos — with every photo offered and nothing consumed.
    ///
    /// `TEST_RUNNER_FERNLET_TEST_EVIDENCE_DIR` (optional) makes the cell write what the overlay shows
    /// as a PNG there — evidence for a review, never an assertion.
    @Test func theOverlayPresentsThePhotoReviewAfterAnEndingNobodyReviewed() async throws {
        let scene = try OverlayTestSupport.scene()
        let captured = try endWithPhotos([.systemTeal, .systemOrange, .systemPink])
        let (window, hosting) = OverlayTestSupport.window(on: scene, root: FriendsView(
            store: store, activeSheet: .constant(nil), isTabBarCompact: .constant(false), tabResetToken: .constant(0)
        ))
        defer { OverlayTestSupport.close(window, hosting) }
        let coordinator = armedCoordinator(on: scene)
        defer { Self.disarm(coordinator) }

        coordinator.evaluateNow()
        try await Task.sleep(for: .milliseconds(1_200))   // the fade, and the Friends surface's own deferred check

        #expect(Self.overlayShows(on: scene) && coordinator.isShowing, "the review is up, in its own window")
        #expect(Set(coordinator.photos.map(\.id)) == captured, "offering every photo")
        #expect(hosting.presentedViewController == nil, "and the Friends surface presents no photo sheet of its own")
        #expect(Set(store.meshNetworkManager.pendingReviewPhotos.map(\.id)) == captured,
                "nothing was consumed or kept on the way: the choice is still the person's")
        if let overlay = scene.windows.first(where: { $0.accessibilityIdentifier == SessionPhotoReviewOverlayPresenter.windowIdentifier }) {
            Self.writeEvidence(of: overlay)
        }
    }

    /// A sheet the Friends surface cannot see is up (ContentView's other root slots) when the
    /// session ends: the overlay lands ABOVE it, and the sheet is still presented under it.
    @Test func aReviewDueWhileAnotherSheetIsUpLandsAboveIt() async throws {
        let scene = try OverlayTestSupport.scene()
        let cover = ForeignCoverModel()
        let (window, hosting) = OverlayTestSupport.window(on: scene, root: ForeignCoverHost(store: store, cover: cover))
        defer { OverlayTestSupport.close(window, hosting) }
        cover.isUp = true
        try await OverlayTestSupport.waitUntil { holdsForeignCover(hosting.presentedViewController) }
        try #require(holdsForeignCover(hosting.presentedViewController), "precondition: the cover is up")
        let captured = try endWithPhotos([.systemTeal, .systemOrange])
        let coordinator = armedCoordinator(on: scene)
        defer { Self.disarm(coordinator) }

        coordinator.evaluateNow()

        #expect(Self.overlayShows(on: scene), "the review is up")
        #expect(holdsForeignCover(hosting.presentedViewController), "above the other sheet, which is still presented")
        #expect(Set(store.meshNetworkManager.pendingReviewPhotos.map(\.id)) == captured, "and nothing was answered")
    }

    /// The camera's teardown shape (finding C-F2): the view that OWNS a presented sheet leaves the
    /// hierarchy in the same main-actor turn as the ending. The overlay does not care: it presents,
    /// every photo pending.
    @Test func aReviewDueAsASheetOwnerLeavesTheHierarchyStillLands() async throws {
        let scene = try OverlayTestSupport.scene()
        let cover = ForeignCoverModel()
        let (window, hosting) = OverlayTestSupport.window(on: scene, root: ForeignCoverHost(store: store, cover: cover))
        defer { OverlayTestSupport.close(window, hosting) }
        let manager = store.meshNetworkManager
        HeldPhotos.openGate(on: manager)
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            for color in [UIColor.systemTeal, .systemOrange] { manager.addPhoto(Self.swatch(color)) }
        }
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 2)
        cover.childMounted = true
        try await Task.sleep(for: .milliseconds(200))
        cover.isChildSheetUp = true
        try await OverlayTestSupport.waitUntil { holdsForeignCover(hosting.presentedViewController) }
        try #require(holdsForeignCover(hosting.presentedViewController), "precondition: the owner's sheet is up")
        let coordinator = armedCoordinator(on: scene)
        defer { Self.disarm(coordinator) }

        // One turn: the sheet's owner leaves the hierarchy and the session ends.
        cover.childMounted = false
        manager.leaveSession()
        coordinator.evaluateNow()

        #expect(Self.overlayShows(on: scene), "the review landed as the owner and its sheet went")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured, "and nothing was answered on the way")
    }

    /// REWRITTEN for the overlay (design §6 Unit 3). This cell used to pin that the Friends
    /// surface's review WAITED OUT the root router's sheet (a SwiftUI request from below replaced
    /// it). The owner's rule is the opposite — the review is the first thing shown — and the overlay
    /// window makes that safe: it presents OVER the root sheet (a half-typed journal entry) without
    /// replacing it, and after the answer the root sheet is still there.
    @Test func aReviewPresentsOverTheRootSheetWithoutReplacingIt() async throws {
        let scene = try OverlayTestSupport.scene()
        let cover = ForeignCoverModel()
        let (window, hosting) = OverlayTestSupport.window(on: scene, root: ForeignCoverHost(store: store, cover: cover))
        defer { OverlayTestSupport.close(window, hosting) }
        cover.rootSheet = .journal
        try await OverlayTestSupport.waitUntil { holdsForeignCover(hosting.presentedViewController) }
        try #require(holdsForeignCover(hosting.presentedViewController), "precondition: the root sheet is up")
        _ = try endWithPhotos([.systemTeal, .systemOrange])
        let coordinator = armedCoordinator(on: scene)
        defer { Self.disarm(coordinator) }

        coordinator.evaluateNow()
        #expect(Self.overlayShows(on: scene), "the review is shown first, over the root sheet")
        #expect(holdsForeignCover(hosting.presentedViewController), "which is still the one presented underneath")

        await coordinator.discardAll()
        #expect(!Self.overlayShows(on: scene) && !coordinator.isShowing, "the answer takes the overlay down")
        #expect(holdsForeignCover(hosting.presentedViewController), "and the journal entry is exactly where it was")
        #expect(store.meshNetworkManager.pendingReviewPhotos.isEmpty, "the answer applied")
    }

    /// Fix round 1, U2-L-U2-R1, carried to the overlay: a photo review owed under a duress decoy does
    /// NOT present — its tiles would be blank and "N photos waiting" is itself the tell — yet
    /// nothing is answered or deleted; it presents once the decoy ends, and a review that is up when
    /// a duress session starts is withdrawn, again answering nothing.
    @Test func aPhotoReviewNeverPresentsUnderADuressDecoyAndReturnsAfterIt() async throws {
        let scene = try OverlayTestSupport.scene()
        let captured = try endWithPhotos([.systemTeal, .systemOrange])
        let manager = store.meshNetworkManager
        Self.enterDuress(on: manager, store: store)
        let coordinator = armedCoordinator(on: scene)
        defer { Self.disarm(coordinator) }

        coordinator.evaluateNow()
        #expect(!Self.overlayShows(on: scene), "no photo review under the decoy")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured, "and nothing answered or deleted")

        store.duressSessionActive = false
        HeldPhotos.openGate(on: manager)
        coordinator.evaluateNow()
        #expect(Self.overlayShows(on: scene), "the decoy ending brings the review back")

        Self.enterDuress(on: manager, store: store)
        coordinator.scheduleEvaluation()
        #expect(!Self.overlayShows(on: scene), "a duress session starting withdraws the review at once")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured, "unanswered: every photo still held")
        store.duressSessionActive = false
    }

    /// **I17.** A keep-friends prompt is up for a candidates-only batch when a late photo turns it
    /// into a photo batch: the overlay shows, the prompt is withdrawn with nothing minted or
    /// consumed, and the overlay offers — and answers — that session's candidates once.
    @Test func aKeepFriendsPromptUpIsWithdrawnUnansweredWhenTheOverlayShows() async throws {
        let scene = try OverlayTestSupport.scene()
        let manager = store.meshNetworkManager
        HeldPhotos.openGate(on: manager)
        manager.recordSessionParticipant(
            displayName: "Bea", fingerprint: "bea-fp-0011223344",
            signingPublicKey: Data([7]), keyAgreementPublicKey: Data([8])
        )
        manager.leaveSession()
        try #require(manager.pendingFriendReview?.entries.count == 1 && !manager.hasOutstandingPhotoReview)
        let (window, hosting) = OverlayTestSupport.window(on: scene, root: FriendsView(
            store: store, activeSheet: .constant(nil), isTabBarCompact: .constant(false), tabResetToken: .constant(0)
        ))
        defer { OverlayTestSupport.close(window, hosting) }
        try await OverlayTestSupport.waitUntil { hosting.presentedViewController != nil }
        try #require(hosting.presentedViewController != nil, "precondition: the keep-friends prompt is up")
        let coordinator = armedCoordinator(on: scene)
        defer { Self.disarm(coordinator) }

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.addPhoto(Self.swatch(.systemTeal))   // a late photo: held awaiting, into the same batch
        }
        coordinator.evaluateNow()
        try await OverlayTestSupport.waitUntil { hosting.presentedViewController == nil }

        #expect(Self.overlayShows(on: scene), "the overlay shows")
        #expect(hosting.presentedViewController == nil, "and the prompt under it is withdrawn")
        let bea = Data([7])
        #expect(!store.trustedProximityPeers.contains { $0.signingPublicKey == bea }, "with nothing minted")
        #expect(manager.pendingFriendReview?.entries.count == 1, "and nothing consumed")
        #expect(coordinator.candidates.map(\.fingerprint) == ["bea-fp-0011223344"], "the overlay offers the candidate")

        coordinator.keptFriendFingerprints = ["bea-fp-0011223344"]
        await coordinator.keepSelected()
        #expect(store.trustedProximityPeers.filter { $0.signingPublicKey == bea }.count == 1, "minted once, by the overlay")
        #expect(manager.pendingFriendReview == nil, "and the batch is answered, both halves")
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(hosting.presentedViewController == nil, "the prompt does not come back for an answered batch")
    }

    /// Puts `store` and `manager` into a duress session the way the app does: the store's flag (the
    /// coordinator reads it) and the routed gate's duress leg (the decrypt seam reads it).
    private static func enterDuress(on manager: MeshNetworkManager, store: FernletStore) {
        store.duressSessionActive = true
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.applyRoutedAccessGate(HeldPhotoFixtures.duressGate, now: Date())
        }
    }

    /// Renders the window to a PNG in the evidence directory, when one was named. Evidence only; a
    /// failed write changes no verdict.
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
    /// Since session photos U3 the presenter is `SessionPhotoReviewCoordinator`, not `FriendsView`.
    @Test func theFriendsReviewReadsTheBatchAndAnswersIt() throws {
        let friends = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        #expect(!friends.contains("manager.sessionPhotos"),
                "FriendsView must never read the live list: the ending empties it before any presenter runs")
        #expect(!friends.contains("finishReviewedPhotos(") && !friends.contains("FriendPhotoReviewSheet("),
                "and it no longer presents or answers the photo review at all — the overlay does (U3)")
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/SessionPhotoReviewCoordinator.swift"))
        let present = try #require(MeshRoutedSourceScan.bracedBody(after: "private func present()", in: source))
        #expect(present.contains("manager.pendingReviewPhotos"), "the photos come from the batch")
        let show = try #require(present.range(of: "presenter.show(self)"))
        let leave = try #require(present.range(of: "leaveEndedMeshIfHeld()"), "an ended held mesh is left AT PRESENT (I21)")
        #expect(show.lowerBound < leave.lowerBound, "once the review is up")
        for action in ["func keepSelected() async", "func discardAll() async"] {
            let body = try #require(MeshRoutedSourceScan.bracedBody(after: action, in: source), "\(action) is gone")
            #expect(body.contains("finishReviewedPhotos(Set(photos.map(\\.id))"), "\(action) answers exactly what it showed")
            #expect(body.contains("await finish(after: answer)"), "\(action) reads what its answer did")
            let raised = try #require(body.range(of: "beginAnswer()"), "\(action) raises the block's answer leg")
            let answered = try #require(body.range(of: "finishReviewedPhotos("))
            let lowered = try #require(body.range(of: "endAnswer()"))
            #expect(raised.lowerBound < answered.lowerBound && answered.lowerBound < lowered.lowerBound,
                    "\(action) raises the leg before the manager is touched and lowers it last (I21)")
        }
        let finish = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func finish(after answer: SessionPhotoAnswer) async", in: source))
        #expect(finish.contains("guard answer.notApplied.isEmpty else"),
                "an answer that did not apply keeps the review up (no hide-and-re-present loop, I25)")
        let waited = try #require(finish.range(of: "await awaitLeave()"))
        let hidden = try #require(finish.range(of: "hide()", range: waited.upperBound..<finish.endIndex))
        #expect(waited.lowerBound < hidden.lowerBound, "and a finished one hides only after the leave returned")
        let leaveBody = try #require(MeshRoutedSourceScan.bracedBody(after: "private func leaveEndedMeshIfHeld()", in: source))
        #expect(leaveBody.contains("manager.currentMesh != nil, !manager.isSessionLive"),
                "it leaves only an ENDED mesh this device still holds, never a live session")
        #expect(source.contains(".onChange(of: scenePhase, initial: true)"),
                "ContentView feeds the scene phase, so a review promoted in the dark presents on return")
    }

    /// Fix round 1, U2-L-U2-R1, carried to the overlay: the review never presents held photos under
    /// a duress decoy (the gate's step-aside, fail-closed without a host) or while the decrypt seam
    /// is shut, withdraws a showing review unanswered when a duress session starts, and the Friends
    /// card is not rendered under the decoy.
    @Test func theFriendsReviewHidesUnderDuressAndIsNeverATrap() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/SessionPhotoReviewCoordinator.swift"))
        let stepAside = try #require(MeshRoutedSourceScan.bracedBody(
            after: "static func mustStepAside(_ input: Input) -> Bool", in: source))
        #expect(stepAside.contains("input.duressSessionActive"), "duress takes the review down and keeps it down")
        #expect(source.contains("duressSessionActive: host?.duressSessionActive ?? true"),
                "and with no host the coordinator assumes the decoy (fail closed)")
        let mayPresent = try #require(MeshRoutedSourceScan.bracedBody(
            after: "static func mayPresent(_ input: Input) -> Bool", in: source))
        #expect(mayPresent.contains("input.heldPhotosCanBeShown"), "the review waits for the decrypt seam")
        let hide = try #require(MeshRoutedSourceScan.bracedBody(after: "private func hideWithoutAnswer()", in: source))
        #expect(!hide.contains("finishReviewedPhotos") && !hide.contains("completeFriendReview"),
                "withdrawing answers nothing: hide, never delete")
        #expect(source.contains(".onChange(of: store.duressSessionActive)"), "the duress edge is observed")
        let schedule = try #require(MeshRoutedSourceScan.bracedBody(after: "func scheduleEvaluation()", in: source))
        #expect(schedule.contains("SessionPhotoReviewGate.mustStepAside(gateInput) { hideWithoutAnswer() }"),
                "and a showing review steps aside at once, not after the settle")
        let friends = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        let card = try #require(MeshRoutedSourceScan.bracedBody(after: "private var pendingPhotoReviewCard: some View", in: friends))
        #expect(card.contains("!store.duressSessionActive") && card.contains("!manager.isSessionLive"),
                "no Photos-waiting card under the decoy or over a live session")
    }

    /// Fix round C-F2/L-F2: every trigger schedules, the check refuses over presentations this
    /// surface does not own, and an unlanded request is withdrawn and re-asked rather than latched.
    /// Since U3 the Friends surface requests ONE session-end sheet — the keep-friends prompt — and
    /// never while photos are outstanding or the overlay shows (I17).
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
        #expect(present.contains("guard !manager.hasOutstandingPhotoReview, !reviewCoordinator.isShowing,"),
                "photos first: never while photos wait or the overlay is up (I17)")
        #expect(present.contains("sessionEndReview(hasPhotos: false"), "the photo half is never decided here")
        #expect(present.components(separatedBy: "noteSessionEndSheetRequested()").count - 1 == 1,
                "one session-end sheet arms the landing watchdog: the keep-friends prompt")
        let watchdog = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func confirmSessionEndSheetLanded() async", in: source))
        #expect(watchdog.contains("!sessionEndSheetLanded") && watchdog.contains("withdrawUnlandedSessionEndSheet()"),
                "an unlanded request is withdrawn")
        #expect(watchdog.contains("guard reviewRetriesLeft > 0 else { return }"), "and re-asked a bounded number of times")
        let withdraw = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func withdrawUnlandedSessionEndSheet()", in: source))
        #expect(!withdraw.contains("completeFriendReview") && !withdraw.contains("finishReviewedPhotos"),
                "withdrawing answers nothing")
        let overlay = try #require(MeshRoutedSourceScan.bracedBody(
            after: "private func handleOverlayChange(showing: Bool)", in: source))
        let cleared = try #require(overlay.range(of: "reviewBatch = nil"))
        let lowered = try #require(overlay.range(of: "keepFriendsPromptPresented = false"))
        #expect(cleared.lowerBound < lowered.lowerBound,
                "the overlay showing withdraws a standing prompt with its batch cleared FIRST, so its finalize mints nothing")
        #expect(source.contains(".onChange(of: reviewCoordinator.isShowing)"))
        #expect(source.contains("DisposableCameraView(store: store, presentsOwnSheet: $cameraPresentsOwnSheet)"),
                "the camera reports its own sheets up")
        #expect(source.contains(".onChange(of: cameraPresentsOwnSheet)") && source.contains(".onChange(of: activeSheet == nil)"),
                "and each covering presentation re-checks when it goes")
    }

    /// Session photos U3, invariant I20: the camera reports its Develop review to the coordinator
    /// and clears it THREE ways — from its presentation flag, on the camera's disappear, and on the
    /// review sheet's disappear — and the gate reads it ANDed with the camera's mount condition, so
    /// a missed clear cannot outlive the camera. Its answer raises the block's answer leg with
    /// `defer`, and its capture session stops while the overlay is up.
    @Test func theCameraReportsItsDevelopReviewAndCannotLatchIt() throws {
        let camera = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/DisposableCameraView.swift"))
        #expect(camera.contains(".onChange(of: reviewPresented, initial: true) { _, up in reviewCoordinator.cameraDevelopReviewUp = up }"),
                "the flag follows the Develop sheet")
        #expect(camera.components(separatedBy: "reviewCoordinator.cameraDevelopReviewUp = false").count - 1 == 2,
                "and is cleared on the camera's disappear AND the review sheet's disappear")
        for action in ["private func keepSelectedSessionPhotos() async", "private func discardAllSessionPhotos() async"] {
            let body = try #require(MeshRoutedSourceScan.bracedBody(after: action, in: camera), "\(action) is gone")
            let raised = try #require(body.range(of: "reviewCoordinator.beginAnswer()"))
            let deferred = try #require(body.range(of: "defer { reviewCoordinator.endAnswer() }"))
            let answered = try #require(body.range(of: "manager.finishSessionPhotos("))
            #expect(raised.lowerBound < answered.lowerBound && deferred.lowerBound < answered.lowerBound,
                    "\(action) raises the answer leg before the manager, lowered by `defer` after its leave")
        }
        let overlay = try #require(MeshRoutedSourceScan.bracedBody(after: "private func handleOverlayChange(showing: Bool)", in: camera))
        #expect(overlay.contains("camera.stopSession()") && overlay.contains("guard manager.isSessionLive, !reviewPresented"),
                "no live capture under the overlay, and no restart after it unless the session is live")
        let coordinator = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/SessionPhotoReviewCoordinator.swift"))
        #expect(coordinator.contains("cameraDevelopReviewUp: cameraDevelopReviewUp && manager.isInSession"),
                "the gate reads the flag only while the camera is mounted")
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

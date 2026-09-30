// SessionPhotoReviewCoordinatorTests.swift
// FernletTests
//
// Session photos U3 (2026-09-30): `SessionPhotoReviewCoordinator` — the one app-level presenter of
// the session-end photo review — driven with a RECORDING presenter (no window), a recording Photos
// saver and a controllable leave, over real managers and real sealed stores.
//
// What it pins, by the design's invariants:
//   I2  the camera roll sees only what the answer reports kept, only after the answer;
//   I10 "Not now", a step-aside and a backgrounding answer nothing (the pending index is
//       byte-identical, the wall unchanged);
//   I11 the discovery block is false over a live session;
//   I13 no review under a duress decoy;
//   I20 the camera's Develop flag cannot outlive the camera (both roads);
//   I21 door 3: the leave starts at present, and the block holds through the export and until the
//       leave returns — the run-policy transition never sees the block fall over a held mesh;
//   I25 a wall that cannot be read disables Keep, Delete all still applies, nothing loops;
// plus the late-arrival re-presentation, First Aid (Q8), door 3 then "Not now" landing on the album
// with the card, and the resume-offer suppression. The overlay window itself is
// `SessionPhotoReviewOverlayTests`'s.

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import FernletCrypto
import FernletDomainModel
import PrivateMediaStore
@testable import ProximityKit
@testable import Fernlet

// MARK: - Recorders

/// A presenter that draws nothing and counts.
@MainActor
final class RecordingReviewPresenter: SessionPhotoReviewPresenting {
    private(set) var isShowing = false
    private(set) var shows = 0
    private(set) var hides = 0

    func attach(to windowScene: UIWindowScene) {}

    func show(_ coordinator: SessionPhotoReviewCoordinator) -> Bool {
        shows += 1
        isShowing = true
        return true
    }

    func hide() {
        if isShowing { hides += 1 }
        isShowing = false
    }
}

/// A Photos saver that records what it was handed and can hold the export open.
@MainActor
final class RecordingPhotoSaver {
    /// Every batch handed to the saver, in order.
    private(set) var saved: [[FriendPhotoPayload]] = []
    /// When true the export suspends until ``release()``.
    var holdsUntilReleased = false
    private var waiting: CheckedContinuation<Void, Never>?

    /// Whether an export is suspended right now.
    var isSuspended: Bool { waiting != nil }

    func save(_ photos: [FriendPhotoPayload]) async throws {
        saved.append(photos)
        guard holdsUntilReleased else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }
}

/// A leave the cell releases by hand, so the block can be observed while it runs.
@MainActor
final class LeaveLatch {
    private(set) var started = 0
    private var isOpen = false
    private var waiting: CheckedContinuation<Void, Never>?

    func leave(_ manager: MeshNetworkManager) async {
        started += 1
        if !isOpen { await withCheckedContinuation { waiting = $0 } }
        manager.leaveSession()
    }

    func open() {
        isOpen = true
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }
}

/// Shared helpers.
@MainActor
enum ReviewCoordinatorFixtures {

    /// A coordinator over `manager` with recorders, fed an active, launched scene.
    static func coordinator(
        _ manager: MeshNetworkManager, host: FernletStore, presenter: RecordingReviewPresenter,
        saver: RecordingPhotoSaver? = nil, latch: LeaveLatch? = nil
    ) -> SessionPhotoReviewCoordinator {
        // Resolved here, not as default arguments: those are evaluated outside the main actor.
        let saver = saver ?? RecordingPhotoSaver()
        let latch = latch ?? LeaveLatch()
        let coordinator = SessionPhotoReviewCoordinator(
            manager: manager, host: host, presenter: presenter,
            saveKeptPhotosToLibrary: { try await saver.save($0) },
            leaveEndedMesh: { await latch.leave($0) }
        )
        coordinator.launchComplete = true
        coordinator.scenePhase = .active
        return coordinator
    }

    /// Waits (bounded: at most 300 × 10 ms) until `condition` holds.
    static func waitUntil(_ condition: () -> Bool) async throws {
        // R2: bounded.
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The pending corpus's sealed index bytes, straight off disk.
    static func pendingIndexBytes(_ store: FernletStore) -> Data? {
        FileManager.default.contents(atPath: HeldPhotoFixtures.pendingIndexURL(store).path)
    }
}

// MARK: - The coordinator

/// The presenter's model, without a window.
@MainActor
@Suite(.serialized)
struct SessionPhotoReviewCoordinatorTests {
    let store = makeTestStore()
    private typealias Fixtures = ReviewCoordinatorFixtures

    /// An ended session on a founded manager: `photos` captured, one keep-as-friend candidate, the
    /// teardown run, the decrypt seam open.
    private func endedSession(photos: Int) throws -> (MeshNetworkManager, [UUID]) {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        manager.recordSessionParticipant(
            displayName: "Bea", fingerprint: "bea-fp-0011223344",
            signingPublicKey: Data([7]), keyAgreementPublicKey: Data([8])
        )
        LastMemberReviewFixtures.capture(photos, on: manager)
        let captured = manager.sessionPhotos.map(\.id)
        try #require(captured.count == photos)
        manager.leaveSession()
        HeldPhotos.openGate(on: manager)
        try #require(manager.heldPhotosCanBeShown && manager.pendingReviewPhotos.count == photos)
        return (manager, captured)
    }

    /// Present snapshots the batch: every photo, all ticked, the candidates, the toggle off.
    @Test func presentSnapshotsTheEndedSessionTickedWithTheToggleOff() throws {
        let (manager, captured) = try endedSession(photos: 2)
        defer { manager.leaveMesh() }
        let presenter = RecordingReviewPresenter()
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: presenter)

        coordinator.evaluateNow()

        #expect(presenter.shows == 1 && coordinator.isShowing, "the review is the first thing shown")
        #expect(Set(coordinator.photos.map(\.id)) == Set(captured) && coordinator.selectedIDs == Set(captured),
                "every held photo is offered, ticked")
        #expect(coordinator.candidates.map(\.fingerprint) == ["bea-fp-0011223344"], "with the session's candidate")
        #expect(!coordinator.alsoSaveToPhotos, "the camera-roll toggle is off each time")
        coordinator.evaluateNow()
        #expect(presenter.shows == 1, "a showing review is left up, never presented twice")
    }

    /// **I10.** "Not now" answers nothing — the pending index is byte-identical and the wall
    /// unchanged — and the review comes back at the next background-to-active edge, or at once from
    /// the Friends card.
    @Test func notNowAnswersNothingAndComesBackAtTheNextActivationOrTheCard() async throws {
        let (manager, captured) = try endedSession(photos: 2)
        defer { manager.leaveMesh() }
        let presenter = RecordingReviewPresenter()
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: presenter)
        coordinator.evaluateNow()
        let before = try #require(Fixtures.pendingIndexBytes(store))
        let wallBefore = manager.meshPhotos

        await coordinator.notNow()

        #expect(!coordinator.isShowing && presenter.hides == 1, "hidden")
        #expect(Fixtures.pendingIndexBytes(store) == before, "the sealed pending index is byte-identical")
        #expect(manager.meshPhotos == wallBefore, "the wall is unchanged")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == Set(captured), "every photo still waiting")
        #expect(manager.pendingFriendReview?.entries.count == 1, "and the candidate too")
        coordinator.evaluateNow()
        #expect(presenter.shows == 1, "no re-presentation this activation")
        coordinator.scenePhase = .inactive
        coordinator.scenePhase = .active
        coordinator.evaluateNow()
        #expect(presenter.shows == 1, "an inactive blip (Control Center) is not a new activation")
        coordinator.scenePhase = .background
        coordinator.scenePhase = .active
        coordinator.evaluateNow()
        #expect(presenter.shows == 2, "the next background-to-active edge brings it back")

        await coordinator.notNow()
        coordinator.reopen()
        #expect(presenter.shows == 3 && coordinator.isShowing, "and the Friends card's Choose photos reopens it at once")
    }

    /// **I10**, the step-aside half, and Q8: First Aid opened under the review takes it down
    /// answering nothing; it waits while First Aid is up and returns when it closes.
    @Test func firstAidTakesTheReviewDownUnansweredAndItReturnsOnClose() throws {
        let (manager, captured) = try endedSession(photos: 1)
        defer { manager.leaveMesh() }
        let presenter = RecordingReviewPresenter()
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: presenter)
        coordinator.evaluateNow()
        let before = try #require(Fixtures.pendingIndexBytes(store))

        coordinator.crisisSurfaceUp = true

        #expect(!coordinator.isShowing && presenter.hides == 1, "the review steps aside at once for First Aid")
        #expect(Fixtures.pendingIndexBytes(store) == before, "answering nothing")
        coordinator.evaluateNow()
        #expect(presenter.shows == 1, "and waits while First Aid is up")
        coordinator.crisisSurfaceUp = false
        coordinator.evaluateNow()
        #expect(presenter.shows == 2 && Set(coordinator.photos.map(\.id)) == Set(captured),
                "then returns with every photo")
    }

    /// **I13.** Under a duress decoy the review never presents, and one that is up is taken down
    /// without an answer; nothing is deleted.
    @Test func aDuressDecoyNeverPresentsAndWithdrawsAShowingReview() throws {
        let (manager, captured) = try endedSession(photos: 1)
        defer { manager.leaveMesh() }
        let presenter = RecordingReviewPresenter()
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: presenter)
        store.duressSessionActive = true
        defer { store.duressSessionActive = false }

        coordinator.evaluateNow()
        #expect(presenter.shows == 0, "no review under the decoy")

        store.duressSessionActive = false
        coordinator.evaluateNow()
        #expect(presenter.shows == 1, "the decoy ending brings it")
        store.duressSessionActive = true
        coordinator.scheduleEvaluation()
        #expect(!coordinator.isShowing, "a duress session starting withdraws it at once")
        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == Set(captured), "unanswered: every photo still held")
    }

    /// **I2.** With the toggle on, the saver is called ONCE, after the answer, with exactly the
    /// photos the answer reports landed on the wall, hydrated from the wall; with it off, and on
    /// Delete all, never.
    @Test func theCameraRollSeesOnlyWhatTheAnswerKept() async throws {
        let (manager, captured) = try endedSession(photos: 3)
        defer { manager.leaveMesh() }
        let presenter = RecordingReviewPresenter()
        let saver = RecordingPhotoSaver()
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: presenter, saver: saver)
        coordinator.evaluateNow()
        coordinator.selectedIDs = [captured[0], captured[1]]
        coordinator.alsoSaveToPhotos = true

        await coordinator.keepSelected()

        #expect(saver.saved.count == 1, "one export")
        let exported = try #require(saver.saved.first)
        #expect(Set(exported.map(\.id)) == [captured[0], captured[1]], "exactly the kept photos")
        #expect(Set(exported.map(\.id)).isSubset(of: Set(manager.meshPhotos.map(\.id))), "each on the wall at that moment")
        #expect(exported.allSatisfy { $0.imageData != nil }, "hydrated — from the wall, never the pending corpus")
        #expect(!Set(manager.meshPhotos.map(\.id)).contains(captured[2]), "the unticked one was deleted, never exported")
        #expect(!coordinator.isShowing, "and the review is done")
    }

    /// **I2**, the other two roads: the toggle off, and Delete all, never reach the saver.
    @Test func noToggleAndDeleteAllNeverReachTheCameraRoll() async throws {
        let (manager, captured) = try endedSession(photos: 2)
        defer { manager.leaveMesh() }
        let presenter = RecordingReviewPresenter()
        let saver = RecordingPhotoSaver()
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: presenter, saver: saver)
        coordinator.evaluateNow()
        coordinator.selectedIDs = [captured[0]]

        await coordinator.keepSelected()
        #expect(saver.saved.isEmpty, "the toggle off: nothing reaches the camera roll")
        #expect(manager.meshPhotos.map(\.id) == [captured[0]], "while the keep landed")

        LastMemberReviewFixtures.capture(1, on: manager)   // no mesh now: held awaiting
        coordinator.evaluateNow()
        coordinator.alsoSaveToPhotos = true
        await coordinator.discardAll()
        #expect(saver.saved.isEmpty, "Delete all never exports, toggle or not")
        #expect(manager.pendingReviewPhotos.isEmpty, "and deleted what it showed")
    }

    /// A photo promoted while the review is up was not in the snapshot: the answer neither keeps
    /// nor deletes it, and the review presents again for it afterwards.
    @Test func aPhotoPromotedWhileTheReviewIsUpIsPresentedAfterTheAnswer() async throws {
        let (manager, captured) = try endedSession(photos: 1)
        defer { manager.leaveMesh() }
        let presenter = RecordingReviewPresenter()
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: presenter)
        coordinator.evaluateNow()
        LastMemberReviewFixtures.capture(1, on: manager)   // a late photo, held awaiting
        let late = try #require(manager.pendingReviewPhotos.map(\.id).first { $0 != captured[0] })

        await coordinator.discardAll()

        #expect(manager.pendingReviewPhotos.map(\.id) == [late], "the late photo was not answered")
        coordinator.evaluateNow()
        #expect(presenter.shows == 2 && coordinator.photos.map(\.id) == [late], "and is presented on its own")
    }

    /// **I20.** The Develop flag waits the review only while the camera is mounted: a termination
    /// that tears the camera down (its flag never cleared) presents at once; and on the own-Keep
    /// road a late arrival is presented once the camera's review closes.
    @Test func theDevelopFlagCannotOutliveTheCamera() async throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        LastMemberReviewFixtures.capture(2, on: manager)
        HeldPhotos.openGate(on: manager)
        let presenter = RecordingReviewPresenter()
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: presenter)
        coordinator.cameraDevelopReviewUp = true   // the Develop sheet is up over the live roll

        manager.leaveSession()   // the termination road: the camera leaves the hierarchy
        try #require(!manager.isInSession && manager.hasOutstandingPhotoReview)
        coordinator.evaluateNow()
        #expect(presenter.shows == 1, "the flag, never cleared, cannot hold the review back once the camera is gone")

        await coordinator.discardAll()
        let second = LastMemberReviewFixtures.foundedManager(store: store)
        defer { second.leaveMesh() }
        LastMemberReviewFixtures.capture(1, on: second)
        HeldPhotos.openGate(on: second)
        let road = Fixtures.coordinator(second, host: store, presenter: RecordingReviewPresenter())
        road.cameraDevelopReviewUp = true
        let snapshot = Set(second.sessionPhotos.map(\.id))
        LastMemberReviewFixtures.capture(1, on: second)   // lands after the Develop snapshot
        road.beginAnswer()
        _ = second.finishSessionPhotos(keeping: snapshot, of: snapshot)
        road.evaluateNow()
        #expect(!road.isShowing, "while the camera answers its own review, nothing presents over it")
        second.leaveSession()   // the camera's own leave: the session ends and the camera unmounts
        road.cameraDevelopReviewUp = false   // the sheet's and the camera's onDisappear
        road.endAnswer()
        road.evaluateNow()
        #expect(road.isShowing && road.photos.count == 1, "then the late arrival is presented at once")
        #expect(!road.photos.contains { snapshot.contains($0.id) }, "and only it: the Develop answer stands")
    }

    /// **I11.** The block is false whenever a session is live — even with an earlier session's
    /// photos outstanding and an answer in flight — so a live session's discovery is never changed.
    @Test func theBlockIsFalseOverALiveSession() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        LastMemberReviewFixtures.capture(1, on: manager)
        manager.leaveSession()
        try #require(manager.hasOutstandingPhotoReview && !manager.isSessionLive)
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: RecordingReviewPresenter())
        #expect(coordinator.blocksDiscovery, "an ended session's photos block discovery")

        // A relaunch that rebuilds the ended session's review, then founds a new, live session.
        let live = LastMemberReviewFixtures.foundedManager(store: store)
        defer { live.leaveMesh() }
        HeldPhotos.openGate(on: live)
        try #require(live.isSessionLive && live.hasOutstandingPhotoReview,
                     "precondition: a live session with an earlier session's photos outstanding")
        let overLive = Fixtures.coordinator(live, host: store, presenter: RecordingReviewPresenter())
        overLive.beginAnswer()
        #expect(!overLive.blocksDiscovery, "false over a live session, whatever is outstanding or in flight")
        overLive.endAnswer()
    }

    /// The resume offer is withheld while the review blocks discovery; endings are not.
    @Test func theResumeOfferIsSuppressedWhileBlocked() throws {
        let (manager, _) = try endedSession(photos: 1)
        defer { manager.leaveMesh() }
        let coordinator = Fixtures.coordinator(manager, host: store, presenter: RecordingReviewPresenter())
        try #require(coordinator.blocksDiscovery)
        #expect(coordinator.resumePresentation(.offerResume) == .nothing, "no 'you'll reconnect' promise while blocked")
        #expect(coordinator.resumePresentation(.previousSessionCouldNotBeReopened) == .previousSessionCouldNotBeReopened,
                "the other cards are untouched")
        #expect(coordinator.resumePresentation(.nothing) == .nothing)

        let quietStore = makeTestStore()   // nothing held on this one
        let quietManager = MeshNetworkManager(store: quietStore, transport: FakeMeshTransportSession())
        let quiet = Fixtures.coordinator(quietManager, host: quietStore, presenter: RecordingReviewPresenter())
        #expect(!quiet.blocksDiscovery && quiet.resumePresentation(.offerResume) == .offerResume,
                "and nothing blocked, the offer shows")
    }
}

// MARK: - Door 3, the wall, and the camera's answer

/// The held-mesh and unreadable-wall roads (I21, I25), on the fake fabric.
@MainActor
@Suite(.serialized)
struct SessionPhotoReviewDoor3Tests {
    let store = makeTestStore()
    private typealias Fixtures = ReviewCoordinatorFixtures

    /// Door 3 on node 0 of a founded pair: `photos` captured, the partner lost, the give-up fired —
    /// the session is over while the mesh is still held.
    private static func door3(_ rig: MeshFoundingRig, photos: Int) throws -> MeshNetworkManager {
        rig.link(0, 1)
        rig.commit(0, 1)
        let manager = rig.nodes[0].manager
        // R2: bounded by the caller's count.
        for _ in 0..<photos { rig.capturePhoto(at: 0) }
        let slot = try #require(manager.slots.first)
        manager.evictSlotForTesting(peerID: slot.id)
        manager.endSessionAfterDiscoveryTimeout()
        try #require(!manager.isSessionLive && manager.currentMesh != nil && manager.hasOutstandingPhotoReview)
        HeldPhotos.openGate(on: manager)
        try #require(manager.heldPhotosCanBeShown)
        return manager
    }

    /// One sample of what the run policy would be fed: the block and the session presence.
    private struct Sample: Equatable {
        let blocked: Bool
        let session: ProximitySessionPresence
    }

    private static func sample(_ coordinator: SessionPhotoReviewCoordinator) -> Sample {
        Sample(
            blocked: coordinator.blocksDiscovery,
            session: ProximitySessionPresence.folding(
                isInSession: coordinator.manager.isInSession, hasCommittedPeer: coordinator.manager.hasCommittedPeer
            )
        )
    }

    /// Whether any consecutive pair lets the block FALL while a mesh is held — the edge on which
    /// the policy's transition answers `.resumeSearch` (`ProximityRunSeamsTests`).
    private static func blockFellOverAHeldMesh(_ samples: [Sample]) -> Bool {
        zip(samples, samples.dropFirst()).contains { earlier, later in
            earlier.blocked && !later.blocked && later.session == .meshHeld
        }
    }

    /// **I21.** Door 3, Keep with the Photos toggle on: the leave starts AT PRESENT; the block is up
    /// through the export (answer in flight) and past it while the leave runs ("Ending the
    /// session..."), and falls only after the leave returned, with no mesh held.
    @Test func door3TheLeaveStartsAtPresentAndTheBlockHoldsUntilItReturns() async throws {
        let rig = try MeshFoundingRig.build(2, label: "u3-door3-keep")
        defer { rig.teardown() }
        let manager = try Self.door3(rig, photos: 1)
        let presenter = RecordingReviewPresenter()
        let saver = RecordingPhotoSaver()
        saver.holdsUntilReleased = true
        let latch = LeaveLatch()
        let coordinator = Fixtures.coordinator(
            manager, host: rig.nodes[0].store, presenter: presenter, saver: saver, latch: latch
        )
        var samples = [Self.sample(coordinator)]

        coordinator.evaluateNow()
        try await Fixtures.waitUntil { latch.started == 1 }
        #expect(latch.started == 1 && coordinator.leaveInFlight, "the held mesh is left at present")
        samples.append(Self.sample(coordinator))

        coordinator.alsoSaveToPhotos = true
        let keep = Task { await coordinator.keepSelected() }
        try await Fixtures.waitUntil { saver.isSuspended }
        #expect(!manager.hasOutstandingPhotoReview && coordinator.blocksDiscovery,
                "answered, and still blocked while the export runs")
        samples.append(Self.sample(coordinator))
        saver.release()
        try await Fixtures.waitUntil { coordinator.workingMessage == .endingSession }
        #expect(coordinator.blocksDiscovery && manager.currentMesh != nil,
                "after the export, the review waits on the leave with the block up and the mesh still held")
        samples.append(Self.sample(coordinator))

        latch.open()
        await keep.value
        samples.append(Self.sample(coordinator))

        #expect(!coordinator.blocksDiscovery && manager.currentMesh == nil && !coordinator.isShowing,
                "the block falls only once the leave returned and the review hid")
        #expect(!Self.blockFellOverAHeldMesh(samples), "the run policy never sees the block fall over a held mesh")
        #expect(samples.last == Sample(blocked: false, session: .absent), "the next Friends edge is a fresh search")
        #expect(saver.saved.count == 1, "and the kept photo was exported once, after the answer")
    }

    /// Door 3 then "Not now": the leave the present started is awaited, the mesh is gone — so the
    /// Friends tab draws the album, not a stopped camera — the card's condition holds and the
    /// block stays up, because nothing was answered.
    @Test func door3ThenNotNowLandsOnTheAlbumWithTheCard() async throws {
        let rig = try MeshFoundingRig.build(2, label: "u3-door3-notnow")
        defer { rig.teardown() }
        let manager = try Self.door3(rig, photos: 2)
        let latch = LeaveLatch()
        let coordinator = Fixtures.coordinator(
            manager, host: rig.nodes[0].store, presenter: RecordingReviewPresenter(), latch: latch
        )
        coordinator.evaluateNow()
        try await Fixtures.waitUntil { latch.started == 1 }

        let notNow = Task { await coordinator.notNow() }
        try await Fixtures.waitUntil { coordinator.workingMessage == .endingSession }
        #expect(coordinator.isShowing, "Not now waits for the leave, showing 'Ending the session...'")
        latch.open()
        await notNow.value

        #expect(!coordinator.isShowing && coordinator.deferredByUser, "then hides, deferred")
        #expect(!manager.isInSession, "the mesh is gone: FriendsView's swap draws the album")
        #expect(manager.hasOutstandingPhotoReview && !manager.isSessionLive && !rig.nodes[0].store.duressSessionActive,
                "and the Photos-waiting card's condition holds")
        #expect(coordinator.blocksDiscovery, "while discovery stays blocked until the person chooses")
    }

    /// **I21**, the camera's Develop answer under door 3: its answer leg keeps the block up while
    /// its own leave runs, so the block falls with no mesh held.
    @Test func theCamerasDevelopAnswerUnderDoor3HoldsTheBlockUntilItsLeave() throws {
        let rig = try MeshFoundingRig.build(2, label: "u3-door3-develop")
        defer { rig.teardown() }
        let manager = try Self.door3(rig, photos: 1)
        let coordinator = Fixtures.coordinator(manager, host: rig.nodes[0].store, presenter: RecordingReviewPresenter())
        coordinator.cameraDevelopReviewUp = true
        var samples = [Self.sample(coordinator)]
        let snapshot = Set(manager.pendingReviewPhotos.map(\.id))

        coordinator.beginAnswer()   // DisposableCameraView.keepSelectedSessionPhotos, before the manager
        _ = manager.finishSessionPhotos(keeping: snapshot, of: snapshot)
        samples.append(Self.sample(coordinator))
        #expect(coordinator.blocksDiscovery && manager.currentMesh != nil, "answered, the mesh held, still blocked")
        manager.leaveSession()   // the camera's leave returns
        samples.append(Self.sample(coordinator))
        coordinator.endAnswer()   // its `defer`
        coordinator.cameraDevelopReviewUp = false
        samples.append(Self.sample(coordinator))

        #expect(!Self.blockFellOverAHeldMesh(samples), "the block never falls over the held mesh")
        #expect(samples.last == Sample(blocked: false, session: .absent), "it falls with nothing held")
    }

    /// **I25.** A wall index that stays unreadable with protected data available: the review
    /// presents with Keep off, a forced Keep is not applied and the review STAYS UP with the inline
    /// failure (never hide-and-re-present), and Delete all applies and closes it.
    @Test func anUnreadableWallDisablesKeepAndDeleteAllStillApplies() async throws {
        let first = LastMemberReviewFixtures.foundedManager(store: store)
        defer { first.leaveMesh() }
        LastMemberReviewFixtures.capture(2, on: first)
        let ids = first.sessionPhotos.map(\.id)
        try #require(ids.count == 2)
        let aside = try HeldPhotoFixtures.makeWallUnreadable(store)
        defer { try? HeldPhotoFixtures.restoreWall(store, aside: aside) }
        let relaunched = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        HeldPhotos.openGate(on: relaunched)
        let presenter = RecordingReviewPresenter()
        let coordinator = Fixtures.coordinator(relaunched, host: store, presenter: presenter)

        coordinator.evaluateNow()
        #expect(coordinator.isShowing && !coordinator.canKeep, "presented, with Keep off and its reason")

        await coordinator.keepSelected()
        #expect(coordinator.isShowing && presenter.hides == 0, "a refused keep leaves the review up")
        #expect(coordinator.answerFailure == .keepUnavailable, "saying why")
        #expect(Set(coordinator.photos.map(\.id)) == Set(ids), "still offering every photo")
        coordinator.evaluateNow()
        #expect(presenter.shows == 1, "and nothing re-presents on its own — no loop")

        await coordinator.discardAll()
        #expect(!coordinator.isShowing && presenter.hides == 1, "Delete all applies and closes the review")
        #expect(relaunched.pendingReviewPhotos.isEmpty, "every photo deleted")
    }
}

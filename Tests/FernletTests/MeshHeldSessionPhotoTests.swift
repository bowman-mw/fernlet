// MeshHeldSessionPhotoTests.swift
// FernletTests
//
// The owner, 2026-09-30, answering "should the review survive a process kill": "Yes; the pop up
// screen for selecting photos should be the first thing shown. None of the photos should be saved
// to the camera roll until this selection has been made."
//
// Unit 2 of the session-photo design (the model): every session photo — taken here or received —
// is HELD in the sealed pending corpus (`PendingSessionPhotoStore`) from the moment it exists, and
// reaches the friend wall only through the person's answer. These cells pin the design's model
// invariants on the manager: nothing on the wall before the answer (I1), the answer is exact (I4),
// an answered photo never comes back from the mesh (I5), the ending writes nothing (I6), the review
// survives a kill (I7), the launch reconcile waits for a readable wall (I8), duress reveals and
// accepts nothing (I13), the corpus is bounded (I14), peers' photos follow the same rule and "live"
// is the signed mesh id's call (I16), no timer removes a held photo (I19), a keep never loses a photo
// (I22), identity is origin + item id (I23), and a wall that cannot be read never deadlocks the
// review (I25's model half).
//
// Every cell that answers pushes an open routed gate first: the answer reads plaintext (to re-seal
// kept photos under the wall key) and so runs only where the gate is open.

import Foundation
import Testing
import UIKit
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
import PrivateMediaStore
@testable import ProximityKit
@testable import Fernlet

// MARK: - Fixtures

/// On-disk paths and direct store access for the held-photo cells.
@MainActor
enum HeldPhotoFixtures {

    /// The pending corpus directory under `store`'s proximity root.
    static func pendingDirectory(_ store: FernletStore) -> URL {
        store.proximitySupportDirectory
            .appendingPathComponent(PendingSessionPhotoStore.directoryName, isDirectory: true)
    }

    /// The pending store over `store`'s corpus, on the process-wide pending key (what the manager uses).
    static func pendingStore(_ store: FernletStore) -> PendingSessionPhotoStore {
        PendingSessionPhotoStore(directory: pendingDirectory(store))
    }

    /// A held photo's sealed full-size file.
    static func pendingImageURL(_ store: FernletStore, localID: UUID) -> URL {
        pendingDirectory(store).appendingPathComponent("Photos/\(localID.uuidString).jpg")
    }

    /// The pending index file.
    static func pendingIndexURL(_ store: FernletStore) -> URL {
        pendingDirectory(store).appendingPathComponent(PendingSessionPhotoStore.indexFileName)
    }

    /// The wall's sealed index file.
    static func wallIndexURL(_ store: FernletStore) -> URL {
        store.proximitySupportDirectory.appendingPathComponent("MeshPhotoCache.sealed")
    }

    /// The wall store over `store`'s root, on the process-wide wall key.
    static func wallStore(_ store: FernletStore) -> PrivateMediaStore {
        PrivateMediaStore(indexURL: store.proximitySupportDirectory.appendingPathComponent("MeshPhotoCache.json"))
    }

    /// A routed-shaped photo from `origin` (bytes included) with the given id.
    static func peerPhoto(id: UUID, origin: String, name: String = "Peer") -> FriendPhotoPayload {
        FriendPhotoPayload(
            id: id, imageData: MeshRoutedPhotoFixtures.tinyJPEG(), addedAt: Date(),
            senderName: name, senderFingerprint: origin, senderSigningPublicKey: Data([1, 2, 3])
        )
    }

    /// The gate a duress decoy runs under: unlocked, foreground, duress.
    static let duressGate = MeshRoutedAccessGate(
        protectedDataAvailable: true, appIsForeground: true, duressActive: true
    )

    /// Makes the wall's sealed index a file that EXISTS but cannot be read (a directory in its
    /// place), keeping the real bytes aside. Returns the aside URL for ``restoreWall(_:aside:)``.
    static func makeWallUnreadable(_ store: FernletStore) throws -> URL {
        let index = wallIndexURL(store)
        let aside = index.appendingPathExtension("aside")
        if FileManager.default.fileExists(atPath: index.path) {
            try FileManager.default.moveItem(at: index, to: aside)
        }
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        return aside
    }

    /// Undoes ``makeWallUnreadable(_:)``.
    static func restoreWall(_ store: FernletStore, aside: URL) throws {
        let index = wallIndexURL(store)
        try FileManager.default.removeItem(at: index)
        if FileManager.default.fileExists(atPath: aside.path) {
            try FileManager.default.moveItem(at: aside, to: index)
        }
    }
}

// MARK: - The model

/// The held-photo model on one manager.
@MainActor
@Suite(.serialized)
struct MeshHeldSessionPhotoTests {
    let store = makeTestStore()

    /// **I1.** After captures and an ending, with no answer: nothing is on the wall — not in
    /// `meshPhotos`, not in the sealed wall index, not in the wall posts or saved sessions, and not
    /// readable through the wall's byte doors — while every photo is held and readable through the
    /// review's gated seam.
    @Test func nothingReachesTheWallBeforeTheAnswer() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        HeldPhotos.openGate(on: manager)
        LastMemberReviewFixtures.capture(3, on: manager)
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 3)

        manager.leaveSession()

        #expect(Set(manager.pendingReviewPhotos.map(\.id)) == captured, "offered for review")
        #expect(manager.meshPhotos.isEmpty, "no photo in the wall mirror (the Home photowall reads it)")
        #expect((HeldPhotos.persistedWallIDs(store) ?? []).isDisjoint(with: captured), "none in the sealed wall index")
        #expect(manager.photoWallPosts.isEmpty && manager.savedPhotoSessions.isEmpty, "no wall post or album session")
        for photo in manager.pendingReviewPhotos {
            #expect(manager.imageData(for: photo) == nil, "the wall's byte door knows nothing of it")
            #expect(manager.thumbnailData(forPhotoID: photo.id) == nil)
            #expect(manager.reviewThumbnailData(for: photo) != nil, "while the review's seam draws it")
        }
        let held = try #require(HeldPhotos.persistedIndex(store))
        #expect(held.heldLocalIDs == captured, "every photo is held in the sealed pending corpus")
    }

    /// **I4.** Kept = shown ∩ held ∩ ticked, landed on the wall with its bytes re-sealed under the
    /// wall key; discarded = shown ∩ held − ticked, files gone; both tombstoned by (origin, id); an
    /// id not shown stays held; and an id answered once is ignored by every later answer.
    @Test func anAnswerIsExactAndFirstAnswerWins() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        HeldPhotos.openGate(on: manager)
        LastMemberReviewFixtures.capture(4, on: manager)
        let ids = manager.sessionPhotos.map(\.id)
        try #require(ids.count == 4)
        manager.leaveSession()
        let batch = try #require(manager.pendingFriendReview)

        let answer = manager.finishReviewedPhotos(Set(ids.prefix(3)), keeping: [ids[0], ids[3]], in: batch.id)

        #expect(answer.keptOnWall == [ids[0]], "ticked but not shown is not kept")
        #expect(answer.discarded == [ids[1], ids[2]] && answer.notApplied.isEmpty && answer.failure == nil)
        let kept = try #require(manager.meshPhotos.first { $0.id == ids[0] })
        #expect(manager.imageData(for: kept) != nil, "the kept bytes open under the WALL key")
        #expect(!FileManager.default.fileExists(atPath: HeldPhotoFixtures.pendingImageURL(store, localID: ids[1]).path),
                "a discarded photo's pending file is gone")
        #expect(!FileManager.default.fileExists(atPath: HeldPhotoFixtures.pendingImageURL(store, localID: ids[0]).path),
                "and so is a kept one's: it now lives on the wall only")
        let index = try #require(HeldPhotos.persistedIndex(store))
        #expect(index.heldLocalIDs == [ids[3]], "the unshown photo is still held")
        for id in ids.prefix(3) {
            #expect(index.isAnswered(HeldPhotoKey(origin: manager.localFingerprint, itemID: id)),
                    "answered photos are tombstoned by origin and id")
        }

        let again = manager.finishSessionPhotos(keeping: [], of: Set(ids))
        #expect(again.discarded == [ids[3]], "a later answer reaches only what is still held")
        #expect(manager.meshPhotos.contains { $0.id == ids[0] }, "and never un-keeps the first answer")
    }

    /// **I6.** The session ending moves the live roll into the review WITHOUT a single disk write:
    /// the pending index is byte-identical across the ending, and a manager rebuilt over it offers
    /// every photo as awaiting.
    @Test func theEndingWritesNothing() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        LastMemberReviewFixtures.capture(2, on: manager)
        let captured = Set(manager.sessionPhotos.map(\.id))
        let indexURL = HeldPhotoFixtures.pendingIndexURL(store)
        let before = try Data(contentsOf: indexURL)
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date

        manager.leaveSession()

        #expect(Set(manager.pendingFriendReview?.photos.map(\.id) ?? []) == captured, "moved into the review")
        #expect(try Data(contentsOf: indexURL) == before, "the pending index is byte-identical")
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date
        #expect(modifiedAfter == modifiedBefore, "and was not even rewritten")
        let rebuilt = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        #expect(Set(rebuilt.pendingReviewPhotos.map(\.id)) == captured, "a rebuilt manager sees every photo awaiting")
    }

    /// **I7.** A kill before the answer: a second manager over the same corpus rebuilds a
    /// photos-only batch with every held photo and NO candidates (they are memory-only key
    /// material — owner question Q5's default), and the review is outstanding.
    @Test func theReviewSurvivesAKillWithoutItsCandidates() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        manager.recordSessionParticipant(
            displayName: "Bea", fingerprint: "bea-fp-0011223344",
            signingPublicKey: Data([7]), keyAgreementPublicKey: Data([8])
        )
        LastMemberReviewFixtures.capture(3, on: manager)
        let captured = Set(manager.sessionPhotos.map(\.id))
        try #require(captured.count == 3 && manager.isSessionLive, "a kill mid-session")

        let relaunched = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())

        let batch = try #require(relaunched.pendingFriendReview, "the review came back")
        #expect(Set(batch.photos.map(\.id)) == captured, "with every held photo")
        #expect(batch.entries.isEmpty, "and without the keep-as-friend candidates")
        #expect(relaunched.hasOutstandingPhotoReview)
        #expect(relaunched.sessionPhotos.isEmpty, "at a launch every held photo is awaiting")
        #expect(!relaunched.heldPhotosCanBeShown, "nothing is drawn before the gate opens")
        HeldPhotos.openGate(on: relaunched)
        #expect(relaunched.heldPhotosCanBeShown, "and it can be once it does")
    }

    /// **I8.** The crash window of an answer — a photo already committed to the wall and still held
    /// — is repaired by the launch reconcile, which waits for a READABLE wall: over a wall deferred
    /// at a locked launch nothing is offered and the review cannot be shown; the unlock edge re-reads
    /// the wall and then drops the kept photo from the pending corpus, offering only the rest.
    @Test func theReconcileWaitsForAReadableWallThenDropsWhatTheWallHolds() throws {
        let first = LastMemberReviewFixtures.foundedManager(store: store)
        defer { first.leaveMesh() }
        LastMemberReviewFixtures.capture(2, on: first)
        let ids = first.sessionPhotos.map(\.id)
        try #require(ids.count == 2)
        // The kill lands between the wall commit and the pending write: photo 0 is both kept and held.
        let pending = HeldPhotoFixtures.pendingStore(store)
        guard case .loaded(let index) = pending.load(now: Date()) else { throw HeldPhotoCellFailure.pendingUnreadable }
        let heldZero = try #require(index.heldPhoto(localID: ids[0]))
        let hydrated = try #require(pending.hydrated(heldZero))
        let wall = HeldPhotoFixtures.wallStore(store)
        #expect(wall.commitKept([hydrated], onto: wall.load()).keptOnWall == [ids[0]], "precondition: on the wall")
        let aside = try HeldPhotoFixtures.makeWallUnreadable(store)

        let relaunched = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())

        #expect(relaunched.pendingFriendReview == nil, "over an unreadable wall nothing is offered")
        #expect(!relaunched.heldPhotosCanBeShown && !relaunched.wallCanTakeKeeps)
        try HeldPhotoFixtures.restoreWall(store, aside: aside)
        HeldPhotos.openGate(on: relaunched)

        #expect(relaunched.pendingReviewPhotos.map(\.id) == [ids[1]], "the kept photo is never offered again")
        #expect(relaunched.meshPhotos.map(\.id) == [ids[0]], "it is on the wall, recovered at the unlock edge")
        #expect(relaunched.heldPhotosCanBeShown && relaunched.wallCanTakeKeeps)
        let after = try #require(HeldPhotos.persistedIndex(store))
        #expect(after.heldLocalIDs == [ids[1]], "and the pending corpus let it go")
        #expect(after.isAnswered(HeldPhotoKey(origin: relaunched.localFingerprint, itemID: ids[0])))
    }

    /// **I25 (model half).** A wall that stays unreadable with protected data AVAILABLE is a
    /// persistent failure, not a locked launch: the held photos are offered anyway (waiting would
    /// never end), a Keep is not applied (`keepUnavailable`) and leaves the photo held, and a
    /// Delete all applies — it needs only the pending index.
    @Test func aWallThatStaysUnreadableRefusesKeepsButAppliesDiscards() throws {
        let first = LastMemberReviewFixtures.foundedManager(store: store)
        defer { first.leaveMesh() }
        LastMemberReviewFixtures.capture(2, on: first)
        let ids = first.sessionPhotos.map(\.id)
        try #require(ids.count == 2)
        let aside = try HeldPhotoFixtures.makeWallUnreadable(store)
        defer { try? HeldPhotoFixtures.restoreWall(store, aside: aside) }

        let relaunched = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        #expect(relaunched.pendingFriendReview == nil, "a locked launch waits")
        HeldPhotos.openGate(on: relaunched)
        let batch = try #require(relaunched.pendingFriendReview, "unlocked and still unreadable: offered")
        #expect(Set(batch.photos.map(\.id)) == Set(ids) && relaunched.heldPhotosCanBeShown && !relaunched.wallCanTakeKeeps)

        let keep = relaunched.finishReviewedPhotos(Set(ids), keeping: [ids[0]], in: batch.id)

        #expect(keep.notApplied == [ids[0]] && keep.failure == .keepUnavailable, "the keep is refused, with its reason")
        #expect(keep.discarded == [ids[1]], "while the discard applied")
        #expect(relaunched.pendingReviewPhotos.map(\.id) == [ids[0]], "the kept photo is still held and offered")
        #expect(HeldPhotos.persistedIndex(store)?.heldLocalIDs == [ids[0]])
    }

    /// **I13.** Under a duress session: the review seam draws nothing, a capture is refused (no film
    /// spent, nothing shared), an answer applies nothing, and the review cannot be shown. Nothing held
    /// is deleted — hide, never delete.
    @Test func duressRevealsNothingAndAcceptsNothing() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        HeldPhotos.openGate(on: manager)
        LastMemberReviewFixtures.capture(1, on: manager)
        let held = try #require(manager.sessionPhotos.first)
        let film = manager.filmRemaining
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = manager.applyRoutedAccessGate(HeldPhotoFixtures.duressGate, now: Date())
        }

        #expect(manager.reviewImageData(for: held) == nil && manager.reviewThumbnailData(for: held) == nil)
        #expect(!manager.heldPhotosCanBeShown)
        LastMemberReviewFixtures.capture(1, on: manager)
        #expect(manager.sessionPhotos.map(\.id) == [held.id], "no capture is held under duress")
        #expect(manager.filmRemaining == film, "and no film is spent")
        #expect(manager.meshError != nil, "the capture says it could not keep the photo")
        let answer = manager.finishSessionPhotos(keeping: [], of: [held.id])
        #expect(answer.notApplied == [held.id] && answer.failure == .unavailable, "no answer runs")
        #expect(HeldPhotos.persistedIndex(store)?.heldLocalIDs == [held.id], "and nothing held was deleted")
    }

    /// **I14.** The corpus is bounded without ever evicting: the 201st hold is `.full`, and every
    /// photo held before it is still held.
    @Test func theTwoHundredAndFirstHoldIsRefusedAndNothingIsEvicted() throws {
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        let cap = PendingSessionPhotoStore.maxHeldPhotos
        var first: UUID?
        // R2: a hard constant ceiling — the corpus bound.
        for position in 0..<cap {
            let id = UUID()
            if position == 0 { first = id }
            let outcome = manager.holdSessionPhoto(
                HeldPhotoFixtures.peerPhoto(id: id, origin: "fp-cap"),
                key: MeshContentKey(senderFingerprint: "fp-cap", contentID: id), live: false
            )
            try #require(outcome == .held, "hold \(position) of \(cap)")
        }
        let overflow = UUID()

        let refused = manager.holdSessionPhoto(
            HeldPhotoFixtures.peerPhoto(id: overflow, origin: "fp-cap"),
            key: MeshContentKey(senderFingerprint: "fp-cap", contentID: overflow), live: false
        )

        #expect(refused == .full)
        #expect(manager.pendingReviewPhotos.count == cap, "nothing evicted to make room")
        #expect(manager.pendingReviewPhotos.contains { $0.id == first }, "the oldest is still held")
        #expect(HeldPhotos.persistedIndex(store)?.photos.count == cap)
    }

    /// **I19.** No timer removes a held photo: one held a year before this launch is offered.
    @Test func aPhotoHeldAYearAgoIsStillOffered() throws {
        let id = UUID()
        let yearAgo = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        let photo = HeldPhotoFixtures.peerPhoto(id: id, origin: "fp-old")
        let (outcome, _) = HeldPhotoFixtures.pendingStore(store).hold(
            HeldSessionPhoto(key: HeldPhotoKey(origin: "fp-old", itemID: id), heldAt: yearAgo, payload: photo),
            imageData: try #require(photo.imageData), into: .empty
        )
        try #require(outcome == .held)

        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())

        #expect(manager.pendingReviewPhotos.map(\.id) == [id], "a year later it is still waiting for the person")
    }

    /// **I22.** A kept photo whose sealed bytes do not land on the wall is NOT reported kept: it
    /// stays held and offered, the answer names the failure, and the export set cannot include it.
    @Test func aKeepThatDoesNotLandLeavesThePhotoHeldAndOffered() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        HeldPhotos.openGate(on: manager)
        LastMemberReviewFixtures.capture(2, on: manager)
        let ids = manager.sessionPhotos.map(\.id)
        try #require(ids.count == 2)
        // The wall's write for photo 0 fails: a directory stands where its sealed file would go.
        try FileManager.default.createDirectory(
            at: store.proximitySupportDirectory.appendingPathComponent("MeshPhotos/\(ids[0].uuidString).jpg"),
            withIntermediateDirectories: true
        )

        let answer = manager.finishSessionPhotos(keeping: Set(ids), of: Set(ids))

        #expect(answer.keptOnWall == [ids[1]], "only the photo that landed is kept")
        #expect(answer.notApplied == [ids[0]] && answer.failure == .wallWriteFailed)
        #expect(manager.sessionPhotos.map(\.id) == [ids[0]], "the other is still offered")
        #expect(HeldPhotos.persistedIndex(store)?.heldLocalIDs == [ids[0]], "and still held, bytes and all")
        #expect(manager.sessionPhotos.first.flatMap { manager.reviewImageData(for: $0) } != nil)
        let exportable = manager.meshPhotos.filter { answer.keptOnWall.contains($0.id) }.map(\.id)
        #expect(exportable == [ids[1]], "the camera-roll export set cannot include a photo that did not land")
    }

    /// **I23.** Identity is origin + item id: an impostor reusing a genuine photo's item id is held
    /// separately (under a fresh local id), neither suppresses the other, and discarding the
    /// impostor tombstones only the impostor's key.
    @Test func anImpostorWithACopiedItemIDNeitherSuppressesNorTombstonesTheGenuinePhoto() throws {
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        HeldPhotos.openGate(on: manager)
        let itemID = UUID()
        let impostorKey = MeshContentKey(senderFingerprint: "fp-impostor", contentID: itemID)
        let genuineKey = MeshContentKey(senderFingerprint: "fp-genuine", contentID: itemID)
        #expect(manager.holdSessionPhoto(
            HeldPhotoFixtures.peerPhoto(id: itemID, origin: "fp-impostor"), key: impostorKey, live: false) == .held)

        #expect(manager.holdSessionPhoto(
            HeldPhotoFixtures.peerPhoto(id: itemID, origin: "fp-genuine"), key: genuineKey, live: false) == .held,
                "the genuine photo is not 'already held' because of the impostor")
        let offered = manager.pendingReviewPhotos
        #expect(offered.count == 2 && Set(offered.map(\.id)).count == 2, "two photos under two local ids")
        let genuineLocal = try #require(offered.first { $0.senderFingerprint == "fp-genuine" }?.id)
        #expect(genuineLocal != itemID, "the later one got a fresh local id instead of overwriting a file")

        let batch = try #require(manager.pendingFriendReview)
        #expect(manager.finishReviewedPhotos([itemID], keeping: [], in: batch.id).discarded == [itemID])

        #expect(manager.pendingReviewPhotos.map(\.id) == [genuineLocal], "the genuine photo is still offered")
        #expect(manager.holdSessionPhoto(
            HeldPhotoFixtures.peerPhoto(id: itemID, origin: "fp-genuine"), key: genuineKey, live: false) == .alreadyHeld,
                "and its key is held, not answered")
        #expect(manager.holdSessionPhoto(
            HeldPhotoFixtures.peerPhoto(id: itemID, origin: "fp-impostor"), key: impostorKey, live: false) == .answered,
                "while only the impostor's key carries the tombstone")
    }

    /// A kept photo deleted from the wall is tombstoned by its identity for 24 hours, so a routed
    /// copy still in custody cannot come back as a new held photo; a HELD photo is not deletable.
    @Test func deletingAKeptPhotoTombstonesItAndAHeldPhotoIsNotDeletable() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        HeldPhotos.openGate(on: manager)
        LastMemberReviewFixtures.capture(2, on: manager)
        let ids = manager.sessionPhotos.map(\.id)
        #expect(manager.finishSessionPhotos(keeping: [ids[0]], of: [ids[0]]).keptOnWall == [ids[0]])

        manager.deletePhoto(ids[1])
        #expect(manager.sessionPhotos.map(\.id) == [ids[1]], "a held photo leaves only through an answer")

        manager.deletePhoto(ids[0])
        #expect(manager.meshPhotos.isEmpty, "the kept photo left the wall")
        let key = MeshContentKey(senderFingerprint: manager.localFingerprint, contentID: ids[0])
        let photo = HeldPhotoFixtures.peerPhoto(id: ids[0], origin: manager.localFingerprint)
        #expect(manager.holdSessionPhoto(photo, key: key, live: true) == .answered,
                "and a re-delivery of it is refused by the tombstone")
    }

    /// Delete-all's leg (4d): the corpus directory is gone, the lists, the WHOLE batch (candidates
    /// too) and the live roster are empty, the wall is untouched — and nothing comes back on a
    /// rebuild.
    @Test func theDeleteAllPurgeTakesEveryUnchosenPhotoAndTheirSessionsOffer() throws {
        let manager = LastMemberReviewFixtures.foundedManager(store: store)
        defer { manager.leaveMesh() }
        HeldPhotos.openGate(on: manager)
        LastMemberReviewFixtures.capture(3, on: manager)
        let ids = manager.sessionPhotos.map(\.id)
        #expect(manager.finishSessionPhotos(keeping: [ids[0]], of: [ids[0]]).keptOnWall == [ids[0]])
        manager.recordSessionParticipant(
            displayName: "Bea", fingerprint: "bea-fp-0011223344",
            signingPublicKey: Data([7]), keyAgreementPublicKey: Data([8])
        )
        manager.leaveSession()
        try #require(manager.pendingFriendReview?.entries.count == 1)

        #expect(manager.purgeHeldSessionPhotosForDeleteAll())

        #expect(!FileManager.default.fileExists(atPath: HeldPhotoFixtures.pendingDirectory(store).path))
        #expect(manager.pendingFriendReview == nil && manager.sessionPhotos.isEmpty && manager.sessionRoster.isEmpty)
        #expect(!manager.hasOutstandingPhotoReview)
        #expect(manager.meshPhotos.map(\.id) == [ids[0]], "the kept wall survives")
        let rebuilt = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        #expect(rebuilt.pendingFriendReview == nil, "and nothing unchosen comes back")
    }

    /// The I5 source half: the tombstone refusal sits in the photo arm BEFORE the body is opened
    /// (no decrypt) and so before the quota (spent inside the canonical dispatch), and the ending's
    /// memory move never names a store (I6).
    @Test func theRoutedRefusalPrecedesTheDecryptAndTheQuota() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
        let dispatch = try #require(MeshRoutedSourceScan.bracedBody(after: "private func dispatchRoutedPlaintext(", in: source))
        let settle = try #require(dispatch.range(of: "routedPhotoSettlement(manifest)"))
        let open = try #require(dispatch.range(of: "openedRoutedPhotoBody(blob, manifest: manifest)"))
        #expect(settle.lowerBound < open.lowerBound, "the tombstone is read before anything is decrypted")
        #expect(!source.contains("cachePhoto("), "the wall-first hold is gone for both producers")
        #expect(!source.contains("isPhotoFromCurrentSession"), "live is the signed mesh id's call, never the header's")
    }
}

/// Why a held-photo cell could not reach its precondition.
enum HeldPhotoCellFailure: Error {
    /// The pending index did not load as `.loaded`.
    case pendingUnreadable
}

// MARK: - Peers' photos

/// Routed arrivals follow the same rule (I16), and an answered photo is refused from custody across
/// a rebuilt manager (I5).
@MainActor
@Suite(.serialized)
struct MeshHeldRoutedPhotoTests {

    /// **I16.** A session-less routed photo (no `header.session`) from the LIVE mesh is held on the
    /// live roll — the signed `manifest.meshID` decides, never the optional header — and does not
    /// touch the review batch; the wall never sees it.
    @Test func aSessionlessRoutedPhotoFromTheLiveMeshIsHeldLive() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "held-live")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        let receiver = rig.nodes[1].manager
        try #require(receiver.isSessionLive && receiver.currentMesh?.meshID == rig.meshID, "precondition: live")
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        rig.link(0, 1)

        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()

        #expect(receiver.sessionPhotos.map(\.id) == [item.manifest.itemID], "held on the live roll")
        #expect(receiver.sessionPhotos.first?.session?.meshID == rig.meshID, "stamped with the live session")
        #expect(receiver.pendingFriendReview == nil, "the review batch is untouched mid-session")
        #expect(receiver.meshPhotos.isEmpty, "and the wall never sees it before the answer")
    }

    /// **I16, the late arrival.** A photo projected after this device's session ended is held
    /// AWAITING and re-triggers the review.
    @Test func aLateRoutedPhotoIsHeldAwaitingAndRetriggersTheReview() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "held-late")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        let receiver = rig.nodes[1].manager
        receiver.endSessionAfterDiscoveryTimeout()
        try #require(!receiver.isSessionLive && receiver.currentMesh != nil, "precondition: ended, mesh held")
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        rig.link(0, 1)

        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()

        #expect(receiver.pendingReviewPhotos.map(\.id) == [item.manifest.itemID], "held awaiting: the review re-triggers")
        #expect(receiver.sessionPhotos.isEmpty && receiver.meshPhotos.isEmpty)
    }

    /// **I5.** A photo the person discarded is refused by its (origin, item id) tombstone when the
    /// routed custody copy is projected AGAIN — here by a manager rebuilt over the same stores with
    /// the ledger restored, whose memory-only "already projected" set is empty — and the verdict
    /// takes it off the retry list.
    @Test func anAnsweredPhotoIsRefusedFromCustodyByARebuiltManager() async throws {
        let rig = try MeshRoutedDrainRig.build(2, label: "held-tombstone")
        defer { rig.teardown() }
        rig.seedAgreementKeys()
        rig.pushGate(MeshRoutedDrainRig.openGate, at: 1)
        let item = try MeshRoutedPhotoFixtures.item(rig, origin: 0)
        let itemID = item.manifest.itemID
        rig.link(0, 1)
        try rig.handOver(item, sender: 0, receiver: 1)
        try await rig.settle()
        try #require(rig.nodes[1].manager.sessionPhotos.map(\.id) == [itemID], "precondition: held")
        #expect(rig.nodes[1].manager.finishSessionPhotos(keeping: [], of: [itemID]).discarded == [itemID])
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        let reborn = MeshNetworkManager(
            store: rig.nodes[1].store, transport: FakeMeshTransportSession(), identity: rig.identities[1]
        )
        let rebornNode = MeshDepartureRig.node(
            "held-tombstone-reborn", identity: rig.identities[1], on: rig.fabric,
            manager: reborn, store: rig.nodes[1].store
        )
        MeshDepartureRig.start(
            rebornNode, ledger: rig.ledger, founderKey: rig.identities[0].localSigningPublicKey,
            meshID: rig.meshID, createdAt: MeshRoutedDrainRig.createdAt
        )
        defer { reborn.leaveMesh() }
        try #require(rig.routedIndex(rig.nodes[1])?.record(for: MeshRoutedItemKey(item.manifest))?.isComplete == true,
                     "precondition: the custody copy is still here")
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            _ = reborn.applyRoutedAccessGate(MeshRoutedDrainRig.openGate, now: MeshRoutedDrainRig.now)
        }

        #expect(HeldPhotos.all(reborn).isEmpty && reborn.meshPhotos.isEmpty, "the answered photo never comes back")
        #expect(capture.count(of: "mesh.routedProjection.photoAlreadyAnswered", where: heldBy(rig.meshID)) == 1,
                "refused by its tombstone, by name")
        #expect(reborn.routedProjectedItems.contains(MeshRoutedItemKey(item.manifest)),
                "and the refusal takes it off the retry list")
    }
}

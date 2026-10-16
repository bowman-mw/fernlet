// SessionContentReportTests.swift
// FernletTests
//
// App Review guideline 1.2 (owner decision 2026-10-15): Report… on a live-session chat message and
// on a session photo. Both run the app's EXISTING people report — `FernletStore.reportProximityPeer`,
// the trust vault's report-and-block on this device, what Friends & Blocks records — through the one
// report flow (`PeerReportFlow.swift`), and never a second moderation store. What these cells hold:
//   * your own message, and your own photo, offer no Report;
//   * a reported message's sender is reported and blocked through that report, and their rows leave
//     the transcript at once;
//   * a reported photo no longer shows — on the wall, and in the session-end review, where it is
//     answered as declined (deleted for good) and its sender leaves the keep-as-friend rows.

import Foundation
import SwiftUI
import Testing
import FernletDomainModel
import FernletConnections
import PrivateMediaStore
@testable import FernletSocial
@testable import ProximityKit
@testable import Fernlet

/// Report… on a session message or photo: who it names, what it records, and what it removes.
@Suite(.serialized) @MainActor
struct SessionContentReportTests {
    let store = makeTestStore()

    init() {
        // Chat is gated at 13+ and fails closed; a 13–16 bracket opens it (SessionMessageTests' seed).
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.chat.minimumAge, upperBound: AgeGate.intimacy.minimumAge,
            provenance: .guardianDeclared
        )
    }

    /// A peer's signing key and the fingerprint the vault derives from it.
    private static func peer(_ seed: UInt8) -> (key: Data, fingerprint: String) {
        let key = Data(repeating: seed, count: 32)
        return (key, IdentityService.fingerprint(of: key))
    }

    /// One transcript row.
    private static func message(
        from sender: (key: Data, fingerprint: String), text: String, isOutgoing: Bool = false, keyed: Bool = true
    ) -> SessionMessageStore.Message {
        SessionMessageStore.Message(
            messageID: UUID(), senderFingerprint: sender.fingerprint,
            senderSigningPublicKey: keyed && !isOutgoing ? sender.key : Data(),
            senderDisplayName: "Ana", text: text, sentAt: Date(), isOutgoing: isOutgoing
        )
    }

    // MARK: - Messages

    /// Your own messages offer no Report: an outgoing row has no subject, and neither does an
    /// inbound row whose author key the delivery did not carry. Another person's keyed row names
    /// their key and quotes only the opening of the message.
    @Test func ownMessagesOfferNoReport() throws {
        let ana = Self.peer(0x41)
        let own = Self.message(from: ana, text: "hi from me", isOutgoing: true)
        #expect(!own.canBeReported && PeerReportSubject.message(own) == nil, "never your own message")
        #expect(PeerReportSubject.message(Self.message(from: ana, text: "hi", keyed: false)) == nil,
                "nor a row with no verified author key")

        let long = String(repeating: "word ", count: 40)
        let subject = try #require(PeerReportSubject.message(Self.message(from: ana, text: long)))
        #expect(subject.signingPublicKey == ana.key && subject.displayName == "Ana")
        guard case .message(let excerpt) = subject.content else {
            Issue.record("a message report quotes its message")
            return
        }
        #expect(excerpt.count <= PeerReportSubject.excerptCharacters + 1 && excerpt.hasSuffix("…"),
                "only the opening, no larger than needed")
        #expect(PeerReportSubject.excerpt(of: "  short one ") == "short one")
    }

    /// The sender of a reported message is reported AND blocked through the people report — the
    /// trust vault's own record, with the reason's frozen token — and their rows leave the transcript
    /// at once, while another person's stay.
    @Test func aReportedMessageSenderIsReportedAndBlockedAndHidden() throws {
        let ana = Self.peer(0x41)
        let ben = Self.peer(0x42)
        let chat = store.meshFeatures.chat
        // R2: bounded by the two literal senders.
        for (sender, text) in [(ana, "a message to report"), (ben, "a kind message")] {
            #expect(chat.sessionMessages.receiveIncoming(
                id: UUID(), senderFingerprint: sender.fingerprint, senderSigningPublicKey: sender.key,
                senderDisplayName: "Peer", text: text, sentAt: Date(), seenAt: Date(), in: .fernlet
            ) == .appended)
        }
        chat.refreshVisibleTranscript()
        let row = try #require(chat.sessionMessages.messages.first { $0.senderFingerprint == ana.fingerprint })
        #expect(row.senderSigningPublicKey == ana.key, "the row carries the verified author key")
        let subject = try #require(PeerReportSubject.message(row))

        store.reportSessionPeer(subject, reason: .hateful)

        let record = try #require(store.proximityTrustVault.peer(signingPublicKey: ana.key))
        #expect(record.reportedAt != nil && record.reportReason == ReportReason.hateful.rawValue,
                "the report is recorded where Friends & Blocks records it, on this device")
        #expect(record.blockedAt != nil && store.isBlockedFingerprint(ana.fingerprint), "and the sender is blocked")
        #expect(!chat.sessionMessages.messages.contains { $0.senderFingerprint == ana.fingerprint },
                "their message leaves the transcript at once, not at the next message")
        #expect(chat.sessionMessages.messages.map(\.senderFingerprint) == [ben.fingerprint],
                "another person's message stays")
        #expect(store.proximityTrustVault.peer(signingPublicKey: ben.key) == nil, "and nobody else is reported")
    }

    /// The report funnel refuses an empty key and this device's own key outright, whatever built
    /// the subject.
    @Test func theFunnelNeverReportsThisDevice() throws {
        let own = store.meshNetworkManager.localSigningPublicKey
        let subject = try #require(PeerReportSubject.person(signingPublicKey: own, displayName: "Me"))
        store.reportSessionPeer(subject, reason: .spam)
        #expect(store.proximityTrustVault.peer(signingPublicKey: own) == nil, "this device is never reported")
        #expect(PeerReportSubject.person(signingPublicKey: Data(), displayName: "Nobody") == nil)
    }

    // MARK: - Photos

    /// A photo `sender` took, carrying its key and fingerprint as a routed delivery attributes it.
    private static func photo(from sender: (key: Data, fingerprint: String), name: String) -> FriendPhotoPayload {
        FriendPhotoPayload(
            id: UUID(), imageData: MeshRoutedPhotoFixtures.tinyJPEG(), addedAt: Date(), senderName: name,
            senderFingerprint: sender.fingerprint, senderSigningPublicKey: sender.key
        )
    }

    /// Your own photos offer no Report — by fingerprint or by key — and neither does a photo that
    /// names nobody. Another person's photo names the key its delivery verified, or the vault's key
    /// for its fingerprint.
    @Test func ownPhotosOfferNoReport() {
        let local = Self.peer(0x01)
        let ana = Self.peer(0x41)
        let vault = [ana.fingerprint: ana.key]
        func key(_ photo: FriendPhotoPayload) -> Data? {
            PeerReportSubject.photoSenderKey(
                of: photo, localSigningKey: local.key, localFingerprint: local.fingerprint, vaultKey: { vault[$0] }
            )
        }
        let bytes = Data([0xFF, 0xD8])
        #expect(key(FriendPhotoPayload(imageData: bytes, senderName: "Me", senderFingerprint: local.fingerprint,
                                       senderSigningPublicKey: local.key)) == nil, "your own photo")
        #expect(key(FriendPhotoPayload(imageData: bytes, senderName: "Me", senderFingerprint: nil,
                                       senderSigningPublicKey: local.key)) == nil, "your own key without a fingerprint")
        #expect(key(FriendPhotoPayload(imageData: bytes, senderName: "?")) == nil, "a photo that names nobody")
        #expect(key(FriendPhotoPayload(imageData: bytes, senderName: "Ana", senderFingerprint: ana.fingerprint,
                                       senderSigningPublicKey: ana.key)) == ana.key, "the verified key")
        #expect(key(FriendPhotoPayload(imageData: bytes, senderName: "Ana",
                                       senderFingerprint: ana.fingerprint)) == ana.key, "or the vault's")
        #expect(PeerReportSubject.photo(FriendPhotoPayload(imageData: bytes, senderName: "Me"), senderKey: nil) == nil)
    }

    /// A reported wall photo no longer shows: its sender is reported and blocked, and the photo is
    /// deleted from the wall and every post, while another photo stays.
    @Test func aReportedWallPhotoNoLongerShows() throws {
        let ana = Self.peer(0x41)
        let photos = store.meshFeatures.photos
        let reported = Self.photo(from: ana, name: "Ana")
        let kept = Self.photo(from: Self.peer(0x42), name: "Ben")
        photos.meshPhotos = [reported.withoutImageData(), kept.withoutImageData()]
        let subject = try #require(PeerReportSubject.photo(reported, senderKey: store.reportableSenderKey(of: reported)))

        store.reportWallPhoto(subject, reason: .sexual)

        #expect(!photos.meshPhotos.contains { $0.id == reported.id }, "the reported photo left the wall")
        #expect(!photos.photoWallPosts.flatMap(\.photos).contains { $0.id == reported.id }, "and every post")
        #expect(photos.meshPhotos.map(\.id) == [kept.id], "another photo stays")
        #expect(subject.signingPublicKey == ana.key, "the report names the photo's sender")
        let record = try #require(store.proximityTrustVault.peer(signingPublicKey: ana.key))
        #expect(record.reportedAt != nil && record.blockedAt != nil, "its sender is reported and blocked")
    }

    /// A reported photo in the session-end review is answered as declined — deleted from the sealed
    /// pending corpus for good — and leaves the review's grid and ticks, its sender handed to the
    /// host's people report and taken out of the keep-as-friend rows; your own photo in the same
    /// review offers no Report; and the review stays up for what is left. The host is a recording
    /// double (the store's funnel has its own cells above), so the review's photos are the rig's alone.
    @Test func aReportedReviewPhotoLeavesTheReviewAndIsDeleted() async throws {
        let features = LastMemberReviewFixtures.foundedFeatures(store: store)
        let manager = features.mesh
        defer { manager.leaveMesh() }
        let ana = Self.peer(0x41)
        manager.recordSessionParticipant(
            displayName: "Ana", fingerprint: ana.fingerprint, signingPublicKey: ana.key, keyAgreementPublicKey: Data([8])
        )
        LastMemberReviewFixtures.capture(1, on: features.photos)
        manager.leaveSession()
        let fromAna = Self.photo(from: ana, name: "Ana")
        let held = features.photos.holdSessionPhoto(
            fromAna, key: MeshContentKey(senderFingerprint: ana.fingerprint, contentID: fromAna.id), live: false
        )
        try #require(held == .held)
        HeldPhotos.openGate(on: manager)
        try #require(features.photos.heldPhotosCanBeShown && features.photos.pendingReviewPhotos.count == 2)
        let host = RecordingReportHost(localSigningKey: manager.localSigningPublicKey, localFingerprint: manager.localFingerprint)
        let coordinator = SessionPhotoReviewCoordinator(
            manager: manager, sessionPhotos: features.photos, host: host, presenter: RecordingReviewPresenter(),
            saveKeptPhotosToLibrary: { _ in }, leaveEndedMesh: { $0.leaveSession() }
        )
        coordinator.launchComplete = true
        coordinator.scenePhase = .active
        coordinator.evaluateNow()
        try #require(coordinator.isShowing && coordinator.candidates.map(\.fingerprint) == [ana.fingerprint])
        let own = try #require(coordinator.photos.first { $0.id != fromAna.id })
        let shownAna = try #require(coordinator.photos.first { $0.id == fromAna.id })
        #expect(!coordinator.canReport(own) && coordinator.reportSubject(for: own) == nil,
                "your own photo offers no Report")
        #expect(coordinator.canReport(shownAna))
        coordinator.keptFriendFingerprints = [ana.fingerprint]
        let subject = try #require(coordinator.reportSubject(for: shownAna))

        await coordinator.reportPhoto(subject, reason: .offensive)

        #expect(host.reports.map { $0.key } == [ana.key] && host.reports.map { $0.reason } == [.offensive],
                "the sender went to the people report, once")
        #expect(coordinator.photos.map(\.id) == [own.id] && coordinator.selectedIDs == [own.id],
                "the reported photo left the grid and its tick")
        #expect(!features.photos.pendingReviewPhotos.contains { $0.id == fromAna.id }, "and is no longer offered")
        #expect(HeldPhotos.persistedIndex(store)?.heldLocalIDs.contains(fromAna.id) == false,
                "it was deleted from the sealed pending corpus, as a declined photo is")
        #expect(!features.photos.meshPhotos.contains { $0.id == fromAna.id }, "and never reached the wall")
        #expect(coordinator.candidates.isEmpty && coordinator.keptFriendFingerprints.isEmpty,
                "its sender left the keep-as-friend rows")
        #expect(coordinator.isShowing, "the review stays up for the photo that is left")

        await coordinator.discardAll()
        #expect(!coordinator.isShowing && features.photos.pendingReviewPhotos.isEmpty, "and answers as before")
    }
}

/// A ``SessionPhotoReviewHost`` that answers a photo's sender key as the store does (never this
/// device's) and records each people report it is handed, touching no store.
@MainActor
private final class RecordingReportHost: SessionPhotoReviewHost {
    let localSigningKey: Data
    let localFingerprint: String
    var trustedProximityPeers: [ProximityTrustedPeerRecord] = []
    var duressSessionActive = false
    var deleteAllInProgress = false
    /// Every report handed to ``reportSessionPeer(_:reason:)``, in order.
    private(set) var reports: [(key: Data, reason: ReportReason)] = []

    init(localSigningKey: Data, localFingerprint: String) {
        self.localSigningKey = localSigningKey
        self.localFingerprint = localFingerprint
    }

    func keepProximityFriends(from candidates: [MeshSessionRosterEntry], keptFingerprints: Set<String>) {}

    func reportableSenderKey(of photo: FriendPhotoPayload) -> Data? {
        PeerReportSubject.photoSenderKey(
            of: photo, localSigningKey: localSigningKey, localFingerprint: localFingerprint, vaultKey: { _ in nil }
        )
    }

    func reportSessionPeer(_ subject: PeerReportSubject, reason: ReportReason) {
        reports.append((subject.signingPublicKey, reason))
    }
}

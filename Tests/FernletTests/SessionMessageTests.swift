// SessionMessageTests.swift
// Phase 5 — live-session temporary messages on the friend mesh
// (Docs/Proximity-Mesh-Redesign-2026-07-10.md).
//
// Owner decision (binding): messages are exchanged ONLY during a live session and VANISH at session
// end — nothing retained on device, nothing synced, no dead-drop, no offline queue. Covers: the wire
// codec round trip; the registry dispatch path (committed-slot gate drops an uncommitted sender;
// blocked-fingerprint drop, mirroring .friendPhoto); the store's hostile-input guards (sanitize + cap,
// dedup, per-sender rate limit); the transcript clearing on EVERY session-end path (leaveSession,
// leaveMesh, removeSlot via evictSlotForTesting) AND on the next session formation; the structural
// guarantee that the transcript never reaches the persisted snapshot; and the capability-gated room
// broadcast (a legacy / photos-only peer is skipped).

@testable import ProximityKit
import Foundation
import Testing
import MultipeerConnectivity
import FernletFoundation
import FernletDomainModel
import FernletPersistence
import CloudKitSync
@testable import Fernlet

@Suite(.serialized) @MainActor
struct SessionMessageTests {
    // Keeps the FernletStore alive past the manager's `unowned let store` (mirrors MeshClothingShopTests).
    let store = makeTestStore()

    init() {
        // Chat is gated at 13+ and fails closed, so these transport tests would otherwise all exercise
        // the gate instead of the messaging path. Seed a 13–16 bracket: old enough to chat, and
        // deliberately NOT old enough for intimacy, so nothing here quietly depends on an adult record.
        // `AgeAssuranceTests` owns the gate's own coverage.
        store.ageAssurance.applyDetermination(
            lowerBound: AgeGate.chat.minimumAge,
            upperBound: AgeGate.intimacy.minimumAge,
            provenance: .guardianDeclared
        )
    }

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private var messagesCap: [String] {
        [ProximityCapability.photos.rawValue, ProximityCapability.messages.rawValue]
    }

    // MARK: - Fixtures

    private func makePeerIdentity(
        name: String,
        signingPublicKey: Data,
        capabilities: [String]? = [ProximityCapability.photos.rawValue, ProximityCapability.messages.rawValue]
    ) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: name,
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: Data([9, 9, 9]),
            fingerprint: IdentityService.fingerprint(of: signingPublicKey),
            rangingMode: .none,
            firstSeenAt: day,
            capabilities: capabilities
        )
    }

    private func makePeerHandle(name: String) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil
        )
    }

    private func throwawayCoordinator() -> ProximityCoordinator {
        let identity = IdentityService(keychainService: "test.mesh.messages.\(UUID().uuidString)")
        return ProximityCoordinator(
            identity: identity,
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }

    private func messageEnvelope(
        text: String,
        id: UUID = UUID(),
        sentAt: Date? = nil,
        senderName: String = "Robin"
    ) throws -> (envelope: FernletIdentityEnvelope, plaintext: Data) {
        let payload = TempMessagePayload(id: id, text: text, sentAt: sentAt ?? day)
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: senderName,
            recipientFingerprint: nil,
            payloadType: .tempMessage,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Message"),
            payload: plaintext,
            createdAt: day,
            expiresAt: nil,
            signature: Data()
        )
        return (envelope, plaintext)
    }

    /// Registers a COMMITTED slot and drives a message through the full production dispatch path
    /// (registry commit gate → blocked drop → store receive).
    @discardableResult
    private func deliverMessage(
        via manager: MeshNetworkManager,
        text: String,
        id: UUID = UUID(),
        sentAt: Date? = nil,
        senderName: String = "Robin",
        senderSigningKey: Data = Data([1, 2, 3])
    ) throws -> ProximityCoordinator.PeerIdentity {
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: senderName, signingPublicKey: senderSigningKey)
        if !manager.slots.contains(where: { $0.fingerprint == identity.fingerprint }) {
            manager.addSlotForTesting(
                coordinator: coordinator,
                peer: makePeerHandle(name: senderName),
                fingerprint: identity.fingerprint,
                peerCapabilities: messagesCap
            )
        }
        let (envelope, plaintext) = try messageEnvelope(text: text, id: id, sentAt: sentAt, senderName: senderName)
        // The coordinator argument must be the one owning the committed slot for the manager to find it.
        let slotCoordinator = manager.slots.first { $0.fingerprint == identity.fingerprint }!.coordinator
        manager.proximityCoordinator(slotCoordinator, didReceive: envelope, plaintext: plaintext, from: identity)
        return identity
    }

    // MARK: - Wire codec

    @Test func tempMessagePayloadRoundTrips() throws {
        let original = TempMessagePayload(id: UUID(), text: "hey there 👋", sentAt: day)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TempMessagePayload.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Registry dispatch

    @Test func committedSlotMessageIsReceived() throws {
        let manager = store.meshNetworkManager
        let robin = try deliverMessage(via: manager, text: "hello")
        #expect(manager.sessionMessages.messages.count == 1)
        let message = try #require(manager.sessionMessages.messages.first)
        #expect(message.text == "hello")
        #expect(message.senderFingerprint == robin.fingerprint)   // transport-verified, not a wire claim
        #expect(!message.isOutgoing)
    }

    @Test func messageFromUncommittedSlotIsDroppedByTheRegistryGate() throws {
        let manager = store.meshNetworkManager
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: "Pending", signingPublicKey: Data([9, 9, 1]))
        // fingerprint: nil models a pre-dwell (uncommitted) candidate — the registry gate must drop it.
        manager.addSlotForTesting(coordinator: coordinator, peer: makePeerHandle(name: "Pending"), fingerprint: nil)
        let (envelope, plaintext) = try messageEnvelope(text: "sneaky", senderName: "Pending")
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: identity)

        #expect(manager.sessionMessages.messages.isEmpty, "Feature payloads are for committed session members only")
    }

    @Test func messageFromBlockedFingerprintIsDropped() throws {
        let manager = store.meshNetworkManager
        let signingKey = Data([7, 7, 7])
        let identity = makePeerIdentity(name: "Blocked", signingPublicKey: signingKey)
        // Block mirrors .friendPhoto: trust then block so the vault holds the fingerprint.
        store.proximityTrustVault.trust(identity, mode: .friend)
        store.proximityTrustVault.block(signingPublicKey: signingKey)

        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: makePeerHandle(name: "Blocked"),
            fingerprint: identity.fingerprint,
            peerCapabilities: messagesCap
        )
        let (envelope, plaintext) = try messageEnvelope(text: "blocked text", senderName: "Blocked")
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: identity)

        #expect(manager.sessionMessages.messages.isEmpty)
    }

    /// The rendered sender name must come from the handshake-verified identity, not the per-message
    /// wire claim — otherwise a committed member could set envelope.senderDisplayName to another
    /// member's name and impersonate them in the transcript.
    @Test func messageSenderNameUsesVerifiedIdentityNotWireClaim() throws {
        let manager = store.meshNetworkManager
        let identity = makePeerIdentity(name: "Bob", signingPublicKey: Data([4, 2, 4]))
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: makePeerHandle(name: "Bob"),
            fingerprint: identity.fingerprint,
            peerCapabilities: messagesCap
        )
        // Bob signs the envelope (his key) but claims to be "Robin" in the wire display-name field.
        let (envelope, plaintext) = try messageEnvelope(text: "hi", senderName: "Robin")
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: identity)

        let msg = try #require(manager.sessionMessages.messages.first)
        #expect(msg.senderDisplayName == "Bob", "Transcript must show the verified identity name, not the wire claim")
        #expect(msg.senderFingerprint == identity.fingerprint)
    }

    // MARK: - Store hostile-input guards

    @Test func receiveSanitizesAndCapsAndDropsEmpty() {
        let s = SessionMessageStore()
        // Length cap.
        let long = String(repeating: "a", count: SessionMessageStore.maxTextLength + 50)
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp1", senderDisplayName: "R", text: long, sentAt: day, now: day))
        #expect(s.messages.first?.text.count == SessionMessageStore.maxTextLength)

        // Control / invisible / bidi scalars stripped; whitespace collapsed.
        let dirty = "hi\u{202E}\u{200B}   there\n\n"
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp2", senderDisplayName: "R", text: dirty, sentAt: day, now: day))
        #expect(s.messages.last?.text == "hi there")

        // Empty-after-sanitize is dropped entirely.
        let before = s.messages.count
        #expect(!s.receiveIncoming(id: UUID(), senderFingerprint: "fp3", senderDisplayName: "R", text: "\u{200B}\n\t ", sentAt: day, now: day))
        #expect(s.messages.count == before)
    }

    @Test func receiveDedupesById() {
        let s = SessionMessageStore()
        let id = UUID()
        #expect(s.receiveIncoming(id: id, senderFingerprint: "fp", senderDisplayName: "R", text: "once", sentAt: day, now: day))
        // A re-send of the same id is dropped even well past the rate-limit window.
        #expect(!s.receiveIncoming(id: id, senderFingerprint: "fp", senderDisplayName: "R", text: "twice", sentAt: day, now: day.addingTimeInterval(60)))
        #expect(s.messages.count == 1)
        #expect(s.messages.first?.text == "once")
    }

    @Test func receiveToleratesNormalBurstsButThrottlesAFlood() {
        let s = SessionMessageStore()
        // Normal human double-/triple-texting (well within the burst allowance) all arrives —
        // the old flat 1/sec window silently dropped these.
        for i in 0..<5 {
            #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "R",
                                      text: "burst\(i)", sentAt: day, now: day.addingTimeInterval(0.1 * Double(i))),
                    "A burst of \(Int(SessionMessageStore.burstAllowance)) messages must all be accepted")
        }
        // The bucket is now empty; a further message in the same instant is throttled.
        #expect(!s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "R",
                                   text: "flood", sentAt: day, now: day.addingTimeInterval(0.5)),
                "Beyond the burst allowance, a same-instant flood message is dropped")
        // After the bucket refills (>= 1 s later) it is accepted again.
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "R",
                                  text: "later", sentAt: day, now: day.addingTimeInterval(2)),
                "Once the bucket refills the sender can send again")

        // A different sender has an independent bucket — not throttled by the first sender's flood.
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "other", senderDisplayName: "A",
                                  text: "hi", sentAt: day, now: day.addingTimeInterval(0.5)))
    }

    @Test func droppedMessageDoesNotPoisonALaterLegitimateOne() {
        let s = SessionMessageStore()
        let id = UUID()
        // An empty-after-sanitize message is dropped and must NOT record its id (dedup) or rate-limit key.
        #expect(!s.receiveIncoming(id: id, senderFingerprint: "fp", senderDisplayName: "R", text: "\u{200B}", sentAt: day, now: day))
        // Same sender, immediately after: a real message is still accepted (no rate-limit poisoning).
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "R", text: "real", sentAt: day, now: day))
        #expect(s.messages.count == 1)
    }

    // MARK: - Session-end clearing (every path) + formation

    @Test func leaveSessionClearsTheTranscript() throws {
        let manager = store.meshNetworkManager
        try deliverMessage(via: manager, text: "in-session")
        #expect(!manager.sessionMessages.messages.isEmpty)

        manager.leaveSession()   // → leaveMesh → stopSearching teardown funnel
        #expect(manager.sessionMessages.messages.isEmpty, "Messages vanish at session end")
    }

    @Test func leaveMeshClearsTheTranscript() throws {
        let manager = store.meshNetworkManager
        try deliverMessage(via: manager, text: "in-session")
        #expect(!manager.sessionMessages.messages.isEmpty)

        manager.leaveMesh()
        #expect(manager.sessionMessages.messages.isEmpty)
    }

    @Test func lastSlotEvictionClearsTheTranscript() throws {
        let manager = store.meshNetworkManager
        let robin = try deliverMessage(via: manager, text: "in-session")
        let slotID = try #require(manager.slots.first { $0.fingerprint == robin.fingerprint }?.id)
        #expect(!manager.sessionMessages.messages.isEmpty)

        manager.evictSlotForTesting(peerID: slotID)   // removeSlot funnel — the last committed slot is gone
        #expect(!manager.isInSession)
        #expect(manager.sessionMessages.messages.isEmpty)
    }

    @Test func newSessionFormationStartsWithAnEmptyTranscript() throws {
        let manager = store.meshNetworkManager
        // A stale message lingering in the store (no live session).
        #expect(manager.sessionMessages.receiveIncoming(id: UUID(), senderFingerprint: "fp",
                                                       senderDisplayName: "Ghost", text: "stale",
                                                       sentAt: day, now: day))
        #expect(!manager.sessionMessages.messages.isEmpty)

        // First slot COMMIT (session formation) clears it.
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: "Alex", signingPublicKey: Data([4, 5, 6]))
        let peer = makePeerHandle(name: "Alex")
        manager.addSlotForTesting(coordinator: coordinator, peer: peer, fingerprint: identity.fingerprint, peerCapabilities: messagesCap)
        let slot = try #require(manager.slots.first { $0.id == peer.id })
        manager.noteSlotCommittedForShop(slot: slot, identity: identity)

        #expect(manager.sessionMessages.messages.isEmpty, "A new session forms with a clean transcript")
    }

    // MARK: - Never persisted

    /// Structural guarantee: the transcript is memory-only and is NOT a snapshot slice. A sentinel
    /// message seeded into the store must never appear in the persisted snapshot (which the store
    /// force-saves here), and a full snapshot round trip returns without it.
    @Test func messagesNeverEnterThePersistedSnapshot() throws {
        let (persistStore, repository, _) = makeTestStoreWithRepositories(date: day)
        let sentinel = "SECRET-CHAT-SENTINEL-9x7q"
        #expect(persistStore.meshNetworkManager.sessionMessages.receiveIncoming(
            id: UUID(), senderFingerprint: "fp-robin", senderDisplayName: "Robin",
            text: sentinel, sentAt: day, now: day
        ))
        #expect(!persistStore.meshNetworkManager.sessionMessages.messages.isEmpty)

        // Force the store to persist everything it CAN persist.
        persistStore.scheduleSnapshotSave()
        persistStore.flushPendingSnapshotSave()

        let reloaded = repository.loadSnapshot(todayKey: persistStore.todayKey)
        let json = String(data: try JSONEncoder().encode(reloaded), encoding: .utf8) ?? ""
        #expect(!json.contains(sentinel), "A session message must never reach the persisted snapshot")
    }

    // MARK: - Capability-gated send

    /// The room broadcast is sealed per active committed slot and skips peers that don't advertise the
    /// `messages` capability (a legacy / photos-only peer would park-and-drop it anyway). The local echo
    /// is appended exactly once regardless.
    @Test func sendBroadcastsOnlyToMessagesCapablePeers() {
        let manager = store.meshNetworkManager
        var sentSlotIDs: [UUID] = []
        manager.onTempMessageSendForTesting = { sentSlotIDs.append($0) }

        // One messages-capable committed peer, one photos-only, one legacy (nil capabilities).
        let capable = makePeerHandle(name: "Capable")
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: capable, fingerprint: "fp-capable",
            verifiedKeyAgreementPublicKey: Data([1]), peerCapabilities: messagesCap
        )
        let photosOnly = makePeerHandle(name: "PhotosOnly")
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: photosOnly, fingerprint: "fp-photos",
            verifiedKeyAgreementPublicKey: Data([2]), peerCapabilities: [ProximityCapability.photos.rawValue]
        )
        let legacy = makePeerHandle(name: "Legacy")
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: legacy, fingerprint: "fp-legacy",
            verifiedKeyAgreementPublicKey: Data([3]), peerCapabilities: nil
        )

        manager.sendTempMessage("hello everyone")

        #expect(sentSlotIDs == [capable.id], "Only the messages-capable peer receives the broadcast")
        // Local echo appended exactly once.
        let outgoing = manager.sessionMessages.messages.filter { $0.isOutgoing }
        #expect(outgoing.count == 1)
        #expect(outgoing.first?.text == "hello everyone")
    }

    @Test func sendDropsEmptyOrWhitespaceOnlyText() {
        let manager = store.meshNetworkManager
        var sends = 0
        manager.onTempMessageSendForTesting = { _ in sends += 1 }
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: makePeerHandle(name: "Capable"),
            fingerprint: "fp-capable", verifiedKeyAgreementPublicKey: Data([1]), peerCapabilities: messagesCap
        )

        manager.sendTempMessage("   \n\t ")
        #expect(sends == 0)
        #expect(manager.sessionMessages.messages.isEmpty, "Nothing is echoed for an empty message")
    }

    /// There is still no user-facing opt-out for messages — session membership is the consent gate —
    /// but the 13+ age gate does withhold the capability, which is what this now pins.
    @Test func localCapabilitiesAdvertiseMessagesOnlyAboveTheAgeGate() {
        let manager = store.meshNetworkManager
        #expect(manager.localCapabilities().contains(ProximityCapability.messages.rawValue))
        // No opt-out for v1: even with the shop opt-out off, messages stays advertised.
        store.setAllowNearbyClothingShares(false)
        #expect(manager.localCapabilities().contains(ProximityCapability.messages.rawValue))

        // Below the gate, the capability is withheld so friends' devices skip us in the room
        // broadcast — but every other capability is untouched.
        store.ageAssurance.applyDetermination(
            lowerBound: nil, upperBound: AgeGate.chat.minimumAge, provenance: .guardianDeclared
        )
        #expect(!manager.localCapabilities().contains(ProximityCapability.messages.rawValue))
        #expect(manager.localCapabilities().contains(ProximityCapability.photos.rawValue))
    }
}

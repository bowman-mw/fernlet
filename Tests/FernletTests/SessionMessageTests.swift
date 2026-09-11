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

    /// Registers a COMMITTED slot and hands it an envelope carrying the **parked** `.tempMessage`
    /// payload — the shape an older peer still emits. Nothing may dispatch it (P6 item 4).
    private func deliverParkedMessageEnvelope(
        via manager: MeshNetworkManager,
        text: String,
        senderName: String = "Robin",
        senderSigningKey: Data = Data([1, 2, 3])
    ) throws -> ProximityCoordinator.PeerIdentity {
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: senderName, signingPublicKey: senderSigningKey)
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: makePeerHandle(name: senderName),
            fingerprint: identity.fingerprint,
            peerCapabilities: messagesCap
        )
        let (envelope, plaintext) = try messageEnvelope(text: text, senderName: senderName)
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: identity)
        return identity
    }

    /// Seeds the transcript the way the SENDER does, for the cells whose subject is the CLEAR
    /// rather than the transport. The routed receive path has its own suite
    /// (`MeshRoutedTextDeliveryTests`) and drives a real pair end to end.
    private func seedTranscript(via manager: MeshNetworkManager, text: String) {
        manager.sessionMessages.appendOutgoing(
            id: UUID(), senderFingerprint: manager.localFingerprint,
            senderDisplayName: "Local", text: text, sentAt: day
        )
    }

    // MARK: - Wire codec

    @Test func tempMessagePayloadRoundTrips() throws {
        let original = TempMessagePayload(id: UUID(), text: "hey there 👋", sentAt: day)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TempMessagePayload.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - The retired transport, parked

    /// `PayloadType.tempMessage` is **parked, not deleted** (P6 item 4, the `.friendPhoto`
    /// precedent): the token and its payload still decode, so an older peer's frame is refused by
    /// name rather than mis-dispatched or failing the session — and NOTHING dispatches it, so the
    /// transcript stays empty even for a fully committed, unblocked, capability-advertising peer.
    ///
    /// This is the cell that would have gone green for the wrong reason if the retirement had been
    /// forgotten: before P6 item 4 the same call filled the transcript.
    @Test func aParkedTempMessageEnvelopeFromACommittedPeerIsNeverDispatched() throws {
        let manager = store.meshNetworkManager
        _ = try deliverParkedMessageEnvelope(via: manager, text: "hello")
        #expect(manager.sessionMessages.messages.isEmpty, """
            the legacy `.tempMessage` handler is gone — chat arrives as a routed item and nothing \
            else may write the transcript
            """)
    }

    // MARK: - Store hostile-input guards

    @Test func receiveSanitizesAndCapsAndDropsEmpty() {
        let s = SessionMessageStore()
        // Length cap.
        let long = String(repeating: "a", count: SessionMessageStore.maxTextLength + 50)
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp1", senderDisplayName: "R",
                                  text: long, sentAt: day, seenAt: day) == .appended)
        #expect(s.messages.first?.text.count == SessionMessageStore.maxTextLength)

        // Control / invisible / bidi scalars stripped; whitespace collapsed.
        let dirty = "hi\u{202E}\u{200B}   there\n\n"
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp2", senderDisplayName: "R",
                                  text: dirty, sentAt: day.addingTimeInterval(1),
                                  seenAt: day.addingTimeInterval(1)) == .appended)
        #expect(s.messages.last?.text == "hi there")

        // Empty-after-sanitize is refused BY NAME rather than collapsed into a bare `false`.
        let before = s.messages.count
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp3", senderDisplayName: "R",
                                  text: "\u{200B}\n\t ", sentAt: day, seenAt: day)
                    == .emptyAfterSanitizing)
        #expect(s.messages.count == before)
    }

    @Test func receiveDedupesById() {
        let s = SessionMessageStore()
        let id = UUID()
        #expect(s.receiveIncoming(id: id, senderFingerprint: "fp", senderDisplayName: "R",
                                  text: "once", sentAt: day, seenAt: day) == .appended)
        // A re-send of the same id is refused as already held, however much later it arrives.
        #expect(s.receiveIncoming(id: id, senderFingerprint: "fp", senderDisplayName: "R",
                                  text: "twice", sentAt: day.addingTimeInterval(60),
                                  seenAt: day.addingTimeInterval(60)) == .alreadyHeld)
        #expect(s.messages.count == 1)
        #expect(s.messages.first?.text == "once")
    }

    /// The per-sender token bucket retired with the transport it belonged to (P6 item 4): a drain
    /// answer carries up to 16 items, so a burst allowance of 5 would flood-DROP 11 legitimate
    /// messages out of one backlog, and a fixed per-item `firstSeenAt` would never refill it. The
    /// replacement is the routed path's own per-origin, per-session quota
    /// (`allowIncomingRoutedText`), which `MeshRoutedTextDeliveryTests` covers.
    @Test func aBurstFromOneSenderIsNoLongerRateLimited() {
        let s = SessionMessageStore()
        // R2: bounded loop, one more than the retired burst allowance of 5 twice over.
        for index in 0..<12 {
            #expect(s.receiveIncoming(
                id: UUID(), senderFingerprint: "fp", senderDisplayName: "R",
                text: "burst\(index)", sentAt: day.addingTimeInterval(Double(index) * 0.1),
                seenAt: day
            ) == .appended, "message \(index) of one drained backlog must not be rate-dropped")
        }
        #expect(s.messages.count == 12)
    }

    @Test func droppedMessageDoesNotPoisonALaterLegitimateOne() {
        let s = SessionMessageStore()
        let id = UUID()
        // An empty-after-sanitize message is refused and must NOT record its id (dedup).
        #expect(s.receiveIncoming(id: id, senderFingerprint: "fp", senderDisplayName: "R",
                                  text: "\u{200B}", sentAt: day, seenAt: day)
                    == .emptyAfterSanitizing)
        // Same sender, immediately after: a real message is still accepted.
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "fp", senderDisplayName: "R",
                                  text: "real", sentAt: day, seenAt: day) == .appended)
        #expect(s.messages.count == 1)
    }

    // MARK: - The transcript is a derivation (plan §10.3, §12)

    /// §10.3's order, re-derived rather than appended: a backlog drains in INDEX order —
    /// `(originFingerprint, itemID)` — so arrival order is not send order on the routed path, and a
    /// device joining a chat in progress would otherwise see the transcript grouped by sender.
    ///
    /// The inversion is the non-vacuity: the later-claimed message is delivered FIRST.
    @Test func theTranscriptIsOrderedBySentAtAcrossSendersNotByArrival() {
        let s = SessionMessageStore()
        let seen = day
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "zeta", senderDisplayName: "Z",
                                  text: "third", sentAt: day.addingTimeInterval(30),
                                  seenAt: seen) == .appended)
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "alpha", senderDisplayName: "A",
                                  text: "first", sentAt: day.addingTimeInterval(10),
                                  seenAt: seen) == .appended)
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "zeta", senderDisplayName: "Z",
                                  text: "second", sentAt: day.addingTimeInterval(20),
                                  seenAt: seen) == .appended)
        #expect(s.messages.map(\.text) == ["first", "second", "third"], """
            two members interleaved and delivered out of order must still read in send order — \
            appended order would have given ["third", "first", "second"]
            """)
    }

    /// A forged claim is CLAMPED to ±10 minutes of first-seen rather than trusted or dropped, and
    /// the clamped instant is what is stored: the UI renders relative times, so a message claiming
    /// 1999 must not render as 1999.
    @Test func aClaimedSentAtBeyondTheWindowIsClampedForOrdering() throws {
        let s = SessionMessageStore()
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "honest", senderDisplayName: "H",
                                  text: "now", sentAt: day, seenAt: day) == .appended)
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "forger", senderDisplayName: "F",
                                  text: "ancient", sentAt: Date(timeIntervalSince1970: 0),
                                  seenAt: day) == .appended)
        let ancient = try #require(s.messages.first { $0.text == "ancient" })
        #expect(ancient.sentAt == day.addingTimeInterval(-MeshMergedMessage.claimWindow),
                "the claim is pulled to the edge of its window, not accepted and not discarded")
        #expect(s.messages.map(\.text) == ["ancient", "now"],
                "so it sorts before an honest message and no further back than ten minutes")
    }

    /// The gates are a **view filter over an unmutated union** (§21.3's decision), so a block that
    /// arrives after delivery hides a row, and lifting it shows the row again with no second
    /// delivery. The rows were never destroyed — that is what makes the derivation shape worth it.
    @Test func aGateClosingHidesRowsAndReopeningShowsThemWithNoSecondDelivery() {
        let s = SessionMessageStore()
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "keep", senderDisplayName: "K",
                                  text: "kept", sentAt: day, seenAt: day) == .appended)
        #expect(s.receiveIncoming(id: UUID(), senderFingerprint: "hide", senderDisplayName: "H",
                                  text: "hidden", sentAt: day.addingTimeInterval(1),
                                  seenAt: day) == .appended)

        s.refreshGates(chatAllowed: true) { $0 == "hide" }
        #expect(s.messages.map(\.text) == ["kept"], "a blocked sender's rows are filtered out")

        s.refreshGates(chatAllowed: false) { _ in false }
        #expect(s.messages.isEmpty, "and the age gate empties the whole transcript")

        s.refreshGates(chatAllowed: true) { _ in false }
        #expect(s.messages.map(\.text) == ["kept", "hidden"],
                "both come back on re-derivation — nothing was mutated, so nothing was lost")
    }

    // MARK: - Session-end clearing (every path) + formation

    @Test func leaveSessionClearsTheTranscript() {
        let manager = store.meshNetworkManager
        seedTranscript(via: manager, text: "in-session")
        #expect(!manager.sessionMessages.messages.isEmpty)

        manager.leaveSession()   // → leaveMesh → stopSearching teardown funnel
        #expect(manager.sessionMessages.messages.isEmpty, "Messages vanish at session end")
    }

    @Test func leaveMeshClearsTheTranscript() {
        let manager = store.meshNetworkManager
        seedTranscript(via: manager, text: "in-session")
        #expect(!manager.sessionMessages.messages.isEmpty)

        manager.leaveMesh()
        #expect(manager.sessionMessages.messages.isEmpty)
    }

    @Test func lastSlotEvictionClearsTheTranscript() throws {
        let manager = store.meshNetworkManager
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: "Robin", signingPublicKey: Data([1, 2, 3]))
        manager.addSlotForTesting(
            coordinator: coordinator, peer: makePeerHandle(name: "Robin"),
            fingerprint: identity.fingerprint, peerCapabilities: messagesCap
        )
        seedTranscript(via: manager, text: "in-session")
        let slotID = try #require(manager.slots.first { $0.fingerprint == identity.fingerprint }?.id)
        #expect(!manager.sessionMessages.messages.isEmpty)

        // The LEDGERLESS shape (no mesh was ever founded here), which is door 4 of `isSessionLive`
        // and still means "the last committed slot going away is the session ending".
        manager.evictSlotForTesting(peerID: slotID)   // removeSlot funnel
        #expect(!manager.isInSession)
        #expect(manager.sessionMessages.messages.isEmpty)
    }

    @Test func newSessionFormationStartsWithAnEmptyTranscript() throws {
        let manager = store.meshNetworkManager
        // A stale message lingering in the store (no live session).
        #expect(manager.sessionMessages.receiveIncoming(
            id: UUID(), senderFingerprint: "fp", senderDisplayName: "Ghost", text: "stale",
            sentAt: day, seenAt: day
        ) == .appended)
        #expect(!manager.sessionMessages.messages.isEmpty)
        let generationBefore = manager.transcriptGeneration

        // First slot COMMIT (session formation) clears it.
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: "Alex", signingPublicKey: Data([4, 5, 6]))
        let peer = makePeerHandle(name: "Alex")
        manager.addSlotForTesting(coordinator: coordinator, peer: peer, fingerprint: identity.fingerprint, peerCapabilities: messagesCap)
        let slot = try #require(manager.slots.first { $0.id == peer.id })
        manager.noteSlotCommittedForShop(slot: slot, identity: identity)

        #expect(manager.sessionMessages.messages.isEmpty, "A new session forms with a clean transcript")
        #expect(manager.transcriptGeneration > generationBefore, """
            and the formation clear BUMPS the generation, so a routed text item custodied under the \
            previous one can never project into this transcript (item 2 fix review P2-3)
            """)
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
            text: sentinel, sentAt: day, seenAt: day
        ) == .appended)
        #expect(!persistStore.meshNetworkManager.sessionMessages.messages.isEmpty)

        // Force the store to persist everything it CAN persist.
        persistStore.scheduleSnapshotSave()
        persistStore.flushPendingSnapshotSave()

        let reloaded = repository.loadSnapshot(todayKey: persistStore.todayKey)
        let json = String(data: try JSONEncoder().encode(reloaded), encoding: .utf8) ?? ""
        #expect(!json.contains(sentinel), "A session message must never reach the persisted snapshot")
    }

    // MARK: - The send, now a routed mint

    /// The destination set is the DERIVED ROSTER, not the `messages` capability (P6 item 4).
    ///
    /// The retired transport sealed one envelope per active committed slot that advertised the
    /// capability, so a legacy or photos-only peer was skipped and an admitted member who was not
    /// linked at that instant got nothing, ever. A routed mint addresses the roster: the manifest
    /// binds wraps ≡ destinations, so a destination cannot be skipped, and an unlinked one is
    /// custodied. With no mesh and no ledger there is no roster at all — which is exactly the
    /// answer this asserts, by name, rather than a silent nothing.
    @Test func theDestinationSetIsTheDerivedRosterNotTheCapability() {
        let manager = store.meshNetworkManager
        var outcomes: [MeshTextSendOutcome] = []
        manager.onTextSendForTesting = { outcomes.append($0) }

        // Three committed slots, one per capability shape the legacy fan-out used to sort on.
        for (index, capabilities) in [messagesCap, [ProximityCapability.photos.rawValue], nil].enumerated() {
            manager.addSlotForTesting(
                coordinator: throwawayCoordinator(), peer: makePeerHandle(name: "Peer\(index)"),
                fingerprint: "fp-peer-\(index)", verifiedKeyAgreementPublicKey: Data([UInt8(index + 1)]),
                peerCapabilities: capabilities
            )
        }

        #expect(manager.sendTempMessage("hello everyone") == .noDestinations, """
            slots are not destinations: with no mesh and no membership ledger the derived roster \
            names nobody, and the capability column no longer decides anything
            """)
        #expect(outcomes == [.noDestinations], "reported exactly once, and not silently")
        #expect(manager.sessionMessages.messages.isEmpty, """
            and NOTHING is echoed for a message that reached nobody — destinations are frozen at \
            the mint and there is no offline queue, so the echo would be a claim that never comes true
            """)
    }

    @Test func sendDropsEmptyOrWhitespaceOnlyText() {
        let manager = store.meshNetworkManager
        var outcomes: [MeshTextSendOutcome] = []
        manager.onTextSendForTesting = { outcomes.append($0) }
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: makePeerHandle(name: "Capable"),
            fingerprint: "fp-capable", verifiedKeyAgreementPublicKey: Data([1]), peerCapabilities: messagesCap
        )

        #expect(manager.sendTempMessage("   \n\t ") == .empty)
        #expect(outcomes == [.empty])
        #expect(manager.sessionMessages.messages.isEmpty, "Nothing is echoed for an empty message")
    }

    /// The byte bound can empty a message the `Character` cap admitted — one base plus four
    /// thousand combining marks is a SINGLE `Character` and 8 001 bytes — and minting that would
    /// echo an empty row the user cannot dismiss (the design check's finding A3b).
    @Test func aCombiningMarkFloodIsByteBoundedAndMintsNothingWhenItEmpties() {
        let manager = store.meshNetworkManager
        var outcomes: [MeshTextSendOutcome] = []
        manager.onTextSendForTesting = { outcomes.append($0) }
        let flood = "a" + String(repeating: "\u{0301}", count: 4_000)
        #expect(flood.count == 1, "the whole flood is ONE Character, which is the trap")
        #expect(flood.utf8.count > MeshRoutedTextBody.maxTextUTF8ByteCount)

        #expect(manager.sendTempMessage(flood) == .empty)
        #expect(outcomes == [.empty])
        #expect(manager.sessionMessages.messages.isEmpty)
    }

    // MARK: - Capability advertisement

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

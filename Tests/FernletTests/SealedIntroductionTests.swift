// SealedIntroductionTests.swift
// FernletTests
//
// Mesh redesign Phase 4b — SEALED-INTRODUCTION rule (Docs/Proximity-Mesh-Redesign-2026-07-10.md).
// The security deliverable for Group 1: a presence-originated heart connection must NEVER emit this
// device's identity introduction (stable signing key, KA key, display name) in a form a tag-replay
// forger can read. These tests drive the coordinator sealed-introduction seam directly and assert
// on exactly what was written to the mock transport.
//
// Property proven, most-important first:
//   (b)  the outbound identity introduction is SEALED — the emitted bytes decode as a sealed
//        wrapper, NOT a plain envelope, and contain none of our stable identity material; a forger
//        holding only the friend's PUBLIC keys cannot open it.
//   (b2) an inbound sealed wrapper we cannot open (a forger) fails the connection with NO further
//        identity emitted.
//   (b3) an inbound PLAIN identity intro on a sealed connection (a forger baiting a cleartext ack)
//        is rejected — no ack emitted.
//   (a)  a genuine mutual friend decrypts the sealed intro, both sides verify identity, reach
//        `.connected`, and a sealed heart is delivered end-to-end.
//   (c)  a missing/empty expected KA key refuses to send — the intro is never emitted unsealed.
//
// No test here starts a real radio — every path is driven through `MockMultipeerTransport`.

@testable import ProximityKit
import Foundation
import Testing
import CryptoKit
import MultipeerConnectivity
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@MainActor
final class RecordingPayloadHandler: ProximityPayloadHandling {
    var received: [(envelope: FernletIdentityEnvelope, plaintext: Data)] = []
    func proximityCoordinator(
        _ coordinator: ProximityCoordinator,
        didReceive envelope: FernletIdentityEnvelope,
        plaintext: Data,
        from peer: ProximityCoordinator.PeerIdentity?
    ) {
        received.append((envelope, plaintext))
    }
}

@MainActor
@Suite(.serialized)
struct SealedIntroductionTests {

    // MARK: - Fixtures

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.sealedintro.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    private func cleanup(_ id: String) { KeychainItem.deleteAll(service: id) }

    /// A presence-style peer: NO advertised fingerprint (presence discoveryInfo carries only tags),
    /// mirroring what `MeshMultipeerSession` produces for a heart channel.
    private func presencePeer(name: String) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: name,
            discoveryInfo: ["v": "1", "t": "sometag"],
            advertisedFingerprint: nil)
    }

    private func makeSealedCoordinator(
        identity: IdentityService,
        transport: MockMultipeerTransport,
        expectedFriendKA: Data?,
        displayName: String,
        payloadHandler: (any ProximityPayloadHandling)? = nil,
        inspector: (any ProximityInspectorRecording)? = nil
    ) -> ProximityCoordinator {
        ProximityCoordinator(
            identity: identity,
            transport: transport,
            ranging: MockRangingProvider(isHardwareSupported: false),
            inspector: inspector,
            payloadHandler: payloadHandler,
            replayCache: ReplayCache(),
            foregroundAnchor: NoopProximityForegroundAnchor(),
            displayName: displayName,
            capabilities: [ProximityCapability.hearts.rawValue],
            sealedIntroductionPeerKeyAgreementKey: expectedFriendKA,
            timeoutSeconds: 0)
    }

    /// Gives up only once the deadline has passed AND `minimumPolls` observations have really been
    /// made. A `ContinuousClock` deadline alone measures wall clock, which keeps advancing while
    /// this `@MainActor` suite is starved in a loaded full-suite run — so it can expire having
    /// genuinely looked only a handful of times. Counting observations ties the give-up decision
    /// to scheduling received rather than to time elapsed, and still terminates: `polls` only
    /// climbs, and every turn of the loop sleeps.
    private func waitUntil(
        timeout: Duration = .seconds(3),
        minimumPolls: Int = 400,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func dataContains(_ haystack: Data, _ needle: Data) -> Bool {
        guard !needle.isEmpty else { return false }
        return haystack.range(of: needle) != nil
    }

    // MARK: - (b) The outbound introduction never leaks identity in the clear

    @Test func presenceHeartIntroductionIsSealedAndLeaksNoIdentity() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (friend, friendID) = try makeIdentity(); defer { cleanup(friendID) }   // the intended friend
        let (forger, forgerID) = try makeIdentity(); defer { cleanup(forgerID) }   // holds only public keys

        let transport = MockMultipeerTransport()
        let coordinator = makeSealedCoordinator(
            identity: local, transport: transport,
            expectedFriendKA: friend.localKeyAgreementPublicKey, displayName: "Aisha Bloom")

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: presencePeer(name: "ephemeral-01"))
        await waitUntil { !transport.sentData.isEmpty }

        let sent = try #require(transport.sentData.first?.0)

        // It is NOT a plain identity envelope...
        #expect((try? JSONDecoder().decode(FernletIdentityEnvelope.self, from: sent)) == nil,
                "A presence-heart intro must never go on the wire as a plain (cleartext) envelope")
        // ...it is the sealed wrapper.
        let wrapper = try JSONDecoder().decode(SealedIntroductionEnvelope.self, from: sent)

        // None of our stable identity material appears in the emitted bytes.
        #expect(!dataContains(sent, local.localSigningPublicKey), "Signing key must not appear in the clear")
        #expect(!dataContains(sent, local.localKeyAgreementPublicKey), "KA key must not appear in the clear")
        #expect(!dataContains(sent, Data("Aisha Bloom".utf8)), "Display name must not appear in the clear")

        // A tag-replay forger holds only the friend's PUBLIC keys, not the KA private key, so it
        // cannot open the wrapper — it learns neither keys nor name.
        #expect(throws: (any Error).self) {
            try forger.open(wrapper.sealedIntroduction, from: local.localKeyAgreementPublicKey)
        }

        // The intended friend CAN open it — the real identity is inside, sealed only to them.
        let opened = try friend.open(wrapper.sealedIntroduction, from: local.localKeyAgreementPublicKey)
        let inner = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: opened)
        #expect(inner.payloadType == .identityIntroduction)
        #expect(inner.senderSigningPublicKey == local.localSigningPublicKey)
        #expect(inner.senderDisplayName == "Aisha Bloom")
    }

    // MARK: - (b2) An unopenable inbound wrapper (forger) fails with no identity emitted

    @Test func inboundSealedWrapperThatCannotBeOpenedFailsWithoutEmittingAck() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (friend, friendID) = try makeIdentity(); defer { cleanup(friendID) }
        let (forger, forgerID) = try makeIdentity(); defer { cleanup(forgerID) }

        let transport = MockMultipeerTransport()
        let coordinator = makeSealedCoordinator(
            identity: local, transport: transport,
            expectedFriendKA: friend.localKeyAgreementPublicKey, displayName: "Aisha Bloom")
        let peer = presencePeer(name: "forger-ephemeral")

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        await waitUntil { !transport.sentData.isEmpty }   // our sealed intro is out
        let sentAfterIntro = transport.sentData.count

        // The forger seals a wrapper to US with ITS OWN key. `open(from: friendKA)` cannot decrypt
        // it — but ONLY because `IdentityService.seal` puts the SEALER's own key in the sharedInfo
        // slot, and we derive with the expected friend's. That makes this case unopenable by
        // construction; it does NOT show that `open` authenticates the sender. A forger who
        // hand-rolls the wrapper with the FRIEND's public key in the sharedInfo produces one that
        // opens perfectly — see `inboundSealedWrapperFromAForgerHoldingOnlyPublicKeysIsRejected`,
        // which is the test that actually pins the sender binding.
        let forgerWrapper = SealedIntroductionEnvelope(
            sealedIntroduction: try forger.seal(Data("bait".utf8), to: local.localKeyAgreementPublicKey))
        transport.simulateInboundData(try JSONEncoder().encode(forgerWrapper), from: peer)

        await waitUntil { if case .failed = coordinator.state { return true }; return false }
        guard case .failed = coordinator.state else {
            Issue.record("Expected .failed on an unopenable wrapper, got \(coordinator.state)")
            return
        }
        // The forger's wrapper DID reach the AEAD and was rejected there, so it must carry the
        // open-failed reason — not the retired-format one that
        // `inboundSealedIntroductionWithNoWireFormatMarkerIsNamedAsARetiredFormat` pins. Asserting
        // the reason here is what stops the two arms of `SealedIntroUnwrap` collapsing into one.
        #expect(failureReason(coordinator.state) == "sealed introduction open failed")
        // No further bytes were emitted — no acknowledgement, nothing identifying, after the sealed
        // intro. The forger learns nothing in either direction.
        #expect(transport.sentData.count == sentAfterIntro)
    }

    // MARK: - (b2b) A wrapper with no `FPT2` marker is a retired format, not a forger

    /// The `SealedIntroUnwrap.legacyWireFormat` remap. `unwrapSealedIntroduction` catches
    /// ``IdentityError/legacyWireFormat`` and returns its own case rather than `.failed`, and
    /// `unwrapInboundEnvelopeData` turns the two into different Connection Inspector lines and
    /// different failure reasons. Nothing else in the suite told them apart, so a cleanup pass that
    /// dropped the inner `catch` would have left an older-build peer reported to the user as a
    /// tag-replay forger — the exact flattening the remap's doc comment says it exists to prevent.
    ///
    /// The bytes must reach the branch under test. The wrapper carries a REAL introduction the
    /// friend sealed to us with only the 4-byte `FPT2` marker stripped — the shape a pre-Phase-4
    /// build put on the wire — and the precondition proves the unstripped form opens, so the marker
    /// is what routes it. The `.failed` arm's own reason is pinned in
    /// `inboundSealedWrapperThatCannotBeOpenedFailsWithoutEmittingAck`; asserting both is what
    /// makes either assertion meaningful.
    @Test func inboundSealedIntroductionWithNoWireFormatMarkerIsNamedAsARetiredFormat() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (friend, friendID) = try makeIdentity(); defer { cleanup(friendID) }

        let recorder = ProximityInspectorEventRecorder()
        let transport = MockMultipeerTransport()
        let coordinator = makeSealedCoordinator(
            identity: local, transport: transport,
            expectedFriendKA: friend.localKeyAgreementPublicKey, displayName: "Aisha Bloom",
            inspector: recorder)
        let peer = presencePeer(name: "older-build")

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        await waitUntil { !transport.sentData.isEmpty }   // our sealed intro is out
        let sentAfterIntro = transport.sentData.count

        let inner = try FernletIdentityEnvelope.signed(
            identityService: friend,
            senderDisplayName: "Robin",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: Data())
        let innerJSON = try JSONEncoder().encode(inner)
        let sealed = try friend.seal(innerJSON, to: local.localKeyAgreementPublicKey)
        #expect((try? local.open(sealed, from: friend.localKeyAgreementPublicKey)) != nil,
                "precondition: with its marker this wrapper opens, so the strip below is the only difference")

        let wrapper = SealedIntroductionEnvelope(sealedIntroduction: Data(sealed.dropFirst(4)))
        transport.simulateInboundData(try JSONEncoder().encode(wrapper), from: peer)

        await waitUntil { if case .failed = coordinator.state { return true }; return false }
        #expect(failureReason(coordinator.state) == "sealed introduction in a retired or unrecognised wire format",
                "An unmarked wrapper must fail as a retired format, not as an open failure")
        #expect(recorder.events.contains("sealed introduction carries no current wire-format marker — failing"))
        #expect(!recorder.events.contains("sealed introduction could not be opened — failing"),
                "The retired-format arm must not also report the forger line")
        #expect(transport.sentData.count == sentAfterIntro,
                "Nothing identifying is emitted to a peer whose wire format we refuse")
    }

    // MARK: - (b3) A PLAIN inbound intro on a sealed connection is rejected

    @Test func inboundPlainIntroductionOnSealedConnectionIsRejected() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (friend, friendID) = try makeIdentity(); defer { cleanup(friendID) }
        let (forger, forgerID) = try makeIdentity(); defer { cleanup(forgerID) }

        let transport = MockMultipeerTransport()
        let coordinator = makeSealedCoordinator(
            identity: local, transport: transport,
            expectedFriendKA: friend.localKeyAgreementPublicKey, displayName: "Aisha Bloom")
        let peer = presencePeer(name: "forger-plain")

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        await waitUntil { !transport.sentData.isEmpty }
        let sentAfterIntro = transport.sentData.count

        // The forger sends its own signed PLAIN identity introduction, hoping to bait a cleartext
        // acknowledgement. On a sealed connection the plain intro is rejected outright.
        let plainIntro = try FernletIdentityEnvelope.signed(
            identityService: forger,
            senderDisplayName: "Forger",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: Data())
        transport.simulateInboundData(try JSONEncoder().encode(plainIntro), from: peer)

        await waitUntil { if case .failed = coordinator.state { return true }; return false }
        guard case .failed = coordinator.state else {
            Issue.record("Expected .failed on a plain intro over a sealed connection, got \(coordinator.state)")
            return
        }
        #expect(transport.sentData.count == sentAfterIntro, "No acknowledgement is emitted to a plain-intro forger")
    }

    // MARK: - (b4) A pre-verification heartbeat never bait a cleartext identity ack

    @Test func inboundHeartbeatBeforeSealedVerificationEmitsNoCleartextAck() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (friend, friendID) = try makeIdentity(); defer { cleanup(friendID) }
        let (forger, forgerID) = try makeIdentity(); defer { cleanup(forgerID) }

        let transport = MockMultipeerTransport()
        let coordinator = makeSealedCoordinator(
            identity: local, transport: transport,
            expectedFriendKA: friend.localKeyAgreementPublicKey, displayName: "Aisha Bloom")
        let peer = presencePeer(name: "forger-heartbeat")

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        await waitUntil { !transport.sentData.isEmpty }   // our sealed intro is out
        let sentAfterIntro = transport.sentData.count

        // The forger signs and sends a plain heartbeat PING while we are still awaiting the sealed
        // intro. `sendHeartbeatAcknowledgement` would carry our identity in the clear — it must NOT
        // fire before identity is verified.
        let pingPayload = try JSONEncoder().encode(
            ["kind": "ping", "heartbeatID": UUID().uuidString, "sentAt": ISO8601DateFormatter().string(from: Date())])
        let ping = try FernletIdentityEnvelope.signed(
            identityService: forger,
            senderDisplayName: "Forger",
            payloadType: .sessionHeartbeat,
            payloadSummary: PayloadSummary(title: "Heartbeat"),
            payload: pingPayload)
        transport.simulateInboundData(try JSONEncoder().encode(ping), from: peer)
        try? await Task.sleep(for: .milliseconds(60))

        // No acknowledgement (or any other envelope) was emitted after the sealed intro.
        #expect(transport.sentData.count == sentAfterIntro,
                "A heartbeat before sealed identity verification must not bait a cleartext ack")
    }

    // MARK: - (c) A missing expected KA key refuses to send (never unsealed)

    @Test func sealedConnectionWithEmptyExpectedKeyRefusesToEmitIntro() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }

        let transport = MockMultipeerTransport()
        // Sealed mode requested (non-nil) but the key is EMPTY — fail-closed, never fall back to
        // an unsealed intro.
        let coordinator = makeSealedCoordinator(
            identity: local, transport: transport,
            expectedFriendKA: Data(), displayName: "Aisha Bloom")

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: presencePeer(name: "no-key"))

        await waitUntil { if case .failed = coordinator.state { return true }; return false }
        guard case .failed = coordinator.state else {
            Issue.record("Expected .failed when the expected KA key is missing, got \(coordinator.state)")
            return
        }
        #expect(transport.sentData.isEmpty, "No introduction — sealed or unsealed — may be emitted without the key")
    }

    // MARK: - (b4) An OPENABLE wrapper carrying a foreign identity is rejected

    /// The sender-binding regression. `IdentityService.seal`/`open` is ephemeral-static ECIES: the
    /// sealer's static key is a public HKDF `sharedInfo`/AAD input, never a key-agreement input, so
    /// a successful `open` proves only that the sealer knew OUR public KA key. Anyone holding the
    /// friend's and our published KA keys can hand-roll a wrapper that opens.
    ///
    /// Deliberately does NOT use `forger.seal(_:to:)` — that API necessarily puts the FORGER's own
    /// key in the sharedInfo slot, which is the one construction that cannot open, and is why
    /// `inboundSealedWrapperThatCannotBeOpenedFailsWithoutEmittingAck` passes vacuously as a test
    /// of sender authentication. The wrapper is built by hand with CryptoKit, exactly as
    /// `IdentityService.seal` builds it but with the FRIEND's KA key in the sharedInfo/AAD slot.
    @Test func inboundSealedWrapperFromAForgerHoldingOnlyPublicKeysIsRejected() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (friend, friendID) = try makeIdentity(); defer { cleanup(friendID) }
        let (forger, forgerID) = try makeIdentity(); defer { cleanup(forgerID) }

        let transport = MockMultipeerTransport()
        let coordinator = makeSealedCoordinator(
            identity: local, transport: transport,
            expectedFriendKA: friend.localKeyAgreementPublicKey, displayName: "Aisha Bloom")
        let peer = presencePeer(name: "forger-openable")

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        await waitUntil { !transport.sentData.isEmpty }
        let sentAfterIntro = transport.sentData.count

        // The inner envelope is signed by the FORGER — a genuine, verifiable signature over a
        // different identity than the one this coordinator exists for.
        let innerEnvelope = try FernletIdentityEnvelope.signed(
            identityService: forger,
            senderDisplayName: "Forger",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: Data())
        let innerJSON = try JSONEncoder().encode(innerEnvelope)

        // Hand-rolled wrapper: ephemeral-static ECIES with the FRIEND's public KA key occupying the
        // sender slot in the sharedInfo and the AAD. The forger holds only PUBLIC keys.
        //
        // The wire spelling is hand-written on purpose and must track `IdentityService.seal`: the
        // `FPT2` marker and the typed `fernlet.proximity.transport.aead.v2` AAD prefix are both
        // MANDATORY since the crypto standardization round's Phase 4 deleted the unmarked read.
        // Without them this forgery no longer opens, and the precondition below — not the sender
        // binding this test exists for — is what would fail.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let recipient = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: local.localKeyAgreementPublicKey)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let symKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("fernlet.proximity.v1".utf8),
            sharedInfo: friend.localKeyAgreementPublicKey + local.localKeyAgreementPublicKey,
            outputByteCount: 32)
        let aad = Data("fernlet.proximity.transport.aead.v2".utf8) + friend.localKeyAgreementPublicKey
        let box = try ChaChaPoly.seal(innerJSON, using: symKey, authenticating: aad)
        let wrapper = SealedIntroductionEnvelope(
            sealedIntroduction: Data("FPT2".utf8) + ephemeral.publicKey.rawRepresentation + box.combined)

        // Precondition: this wrapper really does open — otherwise the test proves nothing.
        #expect((try? local.open(wrapper.sealedIntroduction,
                                 from: friend.localKeyAgreementPublicKey)) != nil,
                "The hand-rolled wrapper must be openable, or the sender binding is not what is under test")

        transport.simulateInboundData(try JSONEncoder().encode(wrapper), from: peer)

        await waitUntil { if case .failed = coordinator.state { return true }; return false }
        guard case .failed = coordinator.state else {
            Issue.record("Expected .failed on an openable wrapper carrying a foreign identity, got \(coordinator.state)")
            return
        }
        if case .connected = coordinator.state {
            Issue.record("A forger must never reach .connected")
        }
        #expect(transport.sentData.count == sentAfterIntro,
                "No ack, no heartbeat — nothing carrying local identity is emitted to the forger")
    }

    // MARK: - (a) Real mutual friends: sealed intro decrypts, heart delivered

    @Test func realMutualFriendsCompleteSealedHandshakeAndDeliverHeart() async throws {
        let (a, aID) = try makeIdentity(); defer { cleanup(aID) }
        let (b, bID) = try makeIdentity(); defer { cleanup(bID) }

        let handlerA = RecordingPayloadHandler()
        let handlerB = RecordingPayloadHandler()
        let ta = MockMultipeerTransport()
        let tb = MockMultipeerTransport()

        // Each coordinator is created with the OTHER's vault KA public key (mutual-by-construction).
        let coordA = makeSealedCoordinator(
            identity: a, transport: ta, expectedFriendKA: b.localKeyAgreementPublicKey,
            displayName: "Aisha", payloadHandler: handlerA)
        let coordB = makeSealedCoordinator(
            identity: b, transport: tb, expectedFriendKA: a.localKeyAgreementPublicKey,
            displayName: "Robin", payloadHandler: handlerB)

        let peerAasSeenByB = presencePeer(name: "a-ephemeral")
        let peerBasSeenByA = presencePeer(name: "b-ephemeral")

        await coordA.begin(role: .browser, mode: .friend)
        await coordB.begin(role: .browser, mode: .friend)
        ta.simulateConnected(peer: peerBasSeenByA)
        tb.simulateConnected(peer: peerAasSeenByB)

        var aIdx = 0, bIdx = 0
        @MainActor func exchangeOnce() {
            while aIdx < ta.sentData.count { tb.simulateInboundData(ta.sentData[aIdx].0, from: peerAasSeenByB); aIdx += 1 }
            while bIdx < tb.sentData.count { ta.simulateInboundData(tb.sentData[bIdx].0, from: peerBasSeenByA); bIdx += 1 }
        }

        // Pump the sealed intro⇄intro / ack⇄ack exchange until both sides have verified identity
        // and are waiting to commit.
        for _ in 0..<20 {
            exchangeOnce()
            try? await Task.sleep(for: .milliseconds(15))
            if isPastIdentity(coordA.state), isPastIdentity(coordB.state) { break }
        }

        // Both decrypted the sealed intro and verified the OTHER's real identity.
        #expect(committedFingerprint(coordA.state) == b.localFingerprint || pendingIdentityVerified(coordA.state, expect: b.localFingerprint))
        #expect(committedFingerprint(coordB.state) == a.localFingerprint || pendingIdentityVerified(coordB.state, expect: a.localFingerprint))

        // Programmatic auto-commit (the presence handshake has no dwell ritual), then pump to
        // .connected on both sides.
        await coordA.commitManualProximity()
        await coordB.commitManualProximity()
        for _ in 0..<20 {
            exchangeOnce()
            try? await Task.sleep(for: .milliseconds(15))
            if case .connected = coordA.state, case .connected = coordB.state { break }
        }
        guard case .connected(let aPeer) = coordA.state, case .connected(let bPeer) = coordB.state else {
            Issue.record("Both sides should reach .connected — A=\(coordA.state) B=\(coordB.state)")
            return
        }
        #expect(aPeer.fingerprint == b.localFingerprint)
        #expect(bPeer.fingerprint == a.localFingerprint)

        // Heart delivered end-to-end over the verified sealed connection.
        let heart = HeartPayload(sentAtDayKey: "2026-07-11")
        try await coordA.sendPayload(
            type: .friendHeart,
            summary: PayloadSummary(title: "Good vibes"),
            payload: try JSONEncoder().encode(heart),
            sealed: true)
        for _ in 0..<20 {
            exchangeOnce()
            try? await Task.sleep(for: .milliseconds(15))
            if handlerB.received.contains(where: { $0.envelope.payloadType == .friendHeart }) { break }
        }
        let delivered = try #require(handlerB.received.first(where: { $0.envelope.payloadType == .friendHeart }))
        let decoded = try JSONDecoder().decode(HeartPayload.self, from: delivered.plaintext)
        #expect(decoded == heart, "The sealed heart is delivered and decrypts for the real friend")
    }

    // MARK: - State helpers

    private func isPastIdentity(_ state: ProximityCoordinator.State) -> Bool {
        switch state {
        case .awaitingProximityCommit, .awaitingManualCommit, .connected, .transferring: return true
        default: return false
        }
    }

    /// The reason string a `.failed` state carries. `fail(_:)` passes it through verbatim, so it is
    /// the only place a test can see WHICH refusal ended the session — the distinction the
    /// `SealedIntroUnwrap` remap exists to preserve for the Connection Inspector.
    private func failureReason(_ state: ProximityCoordinator.State) -> String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    private func committedFingerprint(_ state: ProximityCoordinator.State) -> String? {
        if case .connected(let peer) = state { return peer.fingerprint }
        return nil
    }

    private func pendingIdentityVerified(_ state: ProximityCoordinator.State, expect fingerprint: String) -> Bool {
        switch state {
        case .awaitingProximityCommit(let peer), .awaitingManualCommit(let peer):
            return peer.fingerprint == fingerprint
        default:
            return false
        }
    }
}

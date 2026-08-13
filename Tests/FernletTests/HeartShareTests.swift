// HeartShareTests.swift
// Batch F — send-good-vibes hearts (proximity-only v1).
//
// Ported to the mesh-redesign Phase 4b flow: hearts ride the presence layer, so the receive path,
// the friend gate, and the send gating now live on `PresenceManager` (the standalone
// ProximityHeartManager is deleted). Covers: payload codec + wire-boundary day-key validation,
// envelope kind classification and the sealed-delivery requirement, PresenceManager's receive path
// (trusted-friend happy path, blocked/untrusted/unverified rejection, silent duplicate drops), the
// per-connection trust gate (non-friend torn down, friend retained), the persisted per-friend
// 5-MINUTE rate limit (Phase 4b owner decision — no daily limit in person) across "relaunch" with
// an injected clock, and the pure 24h glow-decay math. Presence-specific gates (inbound invitation
// gate, hearts-off send/receive drops) live in PresenceHeartsTests.

@testable import ProximityKit
import Foundation
import Testing
import MultipeerConnectivity
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@MainActor
struct HeartShareTests {

    private let baseDate = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Payload codec

    @Test func heartPayloadRoundTripsThroughJSON() throws {
        let payload = HeartPayload(sentAtDayKey: "2026-07-05")
        let decoded = try JSONDecoder().decode(HeartPayload.self, from: JSONEncoder().encode(payload))

        #expect(decoded == payload)
        #expect(decoded.format == "fernlet.proximity.heart")
        #expect(decoded.version == 1)
        #expect(decoded.sentAtDayKey == "2026-07-05")
    }

    @Test func heartPayloadCarriesOnlyIdentityAndDayKey() throws {
        // The fuzzy-vibes axiom, enforced at the wire: no note, no numbers, no sender state.
        let data = try JSONEncoder().encode(HeartPayload(sentAtDayKey: "2026-07-05"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "version", "id", "sentAtDayKey"])
    }

    @Test func dayKeyValidatorAcceptsOnlyCanonicalShape() {
        #expect(HeartPayload.isValidDayKey("2026-07-05"))
        #expect(HeartPayload.isValidDayKey("0000-01-01"))

        #expect(!HeartPayload.isValidDayKey(""))
        #expect(!HeartPayload.isValidDayKey("2026-7-5"))
        #expect(!HeartPayload.isValidDayKey("2026-07-051"))
        #expect(!HeartPayload.isValidDayKey("2026/07/05"))
        #expect(!HeartPayload.isValidDayKey("abcd-ef-gh"))
        #expect(!HeartPayload.isValidDayKey("2026-07-0X"))
        #expect(!HeartPayload.isValidDayKey("2026-07-\u{0660}5"))  // non-ASCII digit
        #expect(!HeartPayload.isValidDayKey(String(repeating: "9", count: 10_000)))
    }

    // MARK: - Envelope kind + sealing

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.proximity.heart.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    private func cleanup(_ id: String) {
        KeychainItem.deleteAll(service: id)
    }

    @Test func envelopeClassifiesHeartKindAndUnsealsForRecipient() throws {
        let (sender, senderID) = try makeIdentity()
        defer { cleanup(senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { cleanup(recipientID) }

        #expect(PayloadType(rawValue: "fernlet.friend.heart.v1") == .friendHeart)

        let payload = HeartPayload(sentAtDayKey: "2026-07-05")
        let plaintext = try JSONEncoder().encode(payload)
        let sealed = try sender.seal(plaintext, to: recipient.localKeyAgreementPublicKey)

        let envelope = try FernletIdentityEnvelope.signed(
            identityService: sender,
            senderDisplayName: "Aisha",
            recipientFingerprint: recipient.localFingerprint,
            payloadType: .friendHeart,
            payloadEncryption: .sealedTo(recipientKeyAgreementPublicKey: recipient.localKeyAgreementPublicKey),
            payloadSummary: PayloadSummary(title: "Good vibes"),
            payload: sealed
        )
        #expect(envelope.payloadTypeToken == "fernlet.friend.heart.v1")

        let opened = try envelope.verify(identityService: recipient, replayCache: ReplayCache())
        let decoded = try JSONDecoder().decode(HeartPayload.self, from: opened)
        #expect(decoded == payload)
    }

    @Test func unsealedHeartEnvelopeIsRejectedAtTheReceiver() throws {
        // A misbehaving sender that skips sealing must be rejected even over the encrypted
        // transport — .friendHeart is in the envelope's sealing-required set.
        let (sender, senderID) = try makeIdentity()
        defer { cleanup(senderID) }
        let (recipient, recipientID) = try makeIdentity()
        defer { cleanup(recipientID) }

        let plaintext = try JSONEncoder().encode(HeartPayload(sentAtDayKey: "2026-07-05"))
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: sender,
            senderDisplayName: "Aisha",
            recipientFingerprint: recipient.localFingerprint,
            payloadType: .friendHeart,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Good vibes"),
            payload: plaintext
        )

        #expect(throws: FernletIdentityEnvelope.VerifyError.sealingRequired) {
            try envelope.verify(identityService: recipient, replayCache: ReplayCache())
        }
    }

    // MARK: - Manager receive path

    private func tempLedgerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("heart-share-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json")
    }

    private func makePeerIdentity(displayName: String) -> ProximityCoordinator.PeerIdentity {
        let signingKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let kaKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        return ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: displayName,
            signingPublicKey: signingKey,
            keyAgreementPublicKey: kaKey,
            fingerprint: IdentityService.fingerprint(of: signingKey),
            rangingMode: .none,
            firstSeenAt: baseDate
        )
    }

    private func makeHeartEnvelope(payload: HeartPayload, senderDisplayName: String) throws -> (FernletIdentityEnvelope, Data) {
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: senderDisplayName,
            recipientFingerprint: nil,
            payloadType: .friendHeart,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Good vibes"),
            payload: plaintext,
            createdAt: baseDate,
            expiresAt: nil,
            signature: Data()
        )
        return (envelope, plaintext)
    }

    private func throwawayCoordinator() -> ProximityCoordinator {
        let identity = IdentityService(keychainService: "test.heart.share.\(UUID().uuidString)")
        try? identity.ensureProvisioned()
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

    /// Delivers a heart through the manager's real public receive path.
    private func deliver(
        _ payload: HeartPayload,
        to manager: PresenceManager,
        from peer: ProximityCoordinator.PeerIdentity?,
        senderDisplayName: String = "Aisha Bloom"
    ) throws {
        let (envelope, plaintext) = try makeHeartEnvelope(payload: payload, senderDisplayName: senderDisplayName)
        manager.proximityCoordinator(throwawayCoordinator(), didReceive: envelope, plaintext: plaintext, from: peer)
    }

    @Test func receivedHeartFromTrustedFriendIsPersisted() throws {
        let host = MockHeartProximityHost()
        let friend = makePeerIdentity(displayName: "Aisha Bloom")
        host.proximityTrustVault.trust(friend, mode: .friend)
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)

        try deliver(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: friend)

        #expect(ledger.receivedHearts.count == 1)
        let record = try #require(ledger.receivedHearts.first)
        #expect(record.senderFingerprint == friend.fingerprint)
        #expect(record.senderDisplayName == ItemNameModeration.sanitizedName(friend.displayName))
        #expect(record.receivedAt == baseDate)
        #expect(ledger.pendingBubbleHeart?.id == record.id)
    }

    @Test func receivedHeartSanitizesPeerSuppliedDisplayName() throws {
        let host = MockHeartProximityHost()
        let hostileName = "Ai\u{202E}sha\u{0000}\u{200B} Bloom"
        let friend = makePeerIdentity(displayName: hostileName)
        host.proximityTrustVault.trust(friend, mode: .friend)
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)

        try deliver(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: friend, senderDisplayName: hostileName)

        let record = try #require(ledger.receivedHearts.first)
        #expect(record.senderDisplayName == ItemNameModeration.sanitizedName(hostileName))
        #expect(!record.senderDisplayName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(!record.senderDisplayName.contains("\u{202E}"))
    }

    @Test func heartFromBlockedSenderIsDropped() throws {
        let host = MockHeartProximityHost()
        let friend = makePeerIdentity(displayName: "Aisha Bloom")
        host.proximityTrustVault.trust(friend, mode: .friend)
        host.proximityTrustVault.block(signingPublicKey: friend.signingPublicKey)
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)

        try deliver(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: friend)

        #expect(ledger.receivedHearts.isEmpty)
    }

    @Test func heartFromNonFriendOrUnverifiedSenderIsDropped() throws {
        let host = MockHeartProximityHost()
        let stranger = makePeerIdentity(displayName: "Stranger")  // never trusted
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)

        try deliver(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: stranger)
        #expect(ledger.receivedHearts.isEmpty)

        // No verified identity at all (from: nil) → dropped even with a well-formed payload.
        try deliver(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: nil)
        #expect(ledger.receivedHearts.isEmpty)
    }

    @Test func malformedHeartPayloadsAreDropped() throws {
        let host = MockHeartProximityHost()
        let friend = makePeerIdentity(displayName: "Aisha Bloom")
        host.proximityTrustVault.trust(friend, mode: .friend)
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)

        try deliver(HeartPayload(format: "something.else", sentAtDayKey: "2026-07-05"), to: manager, from: friend)
        try deliver(HeartPayload(version: 2, sentAtDayKey: "2026-07-05"), to: manager, from: friend)
        try deliver(HeartPayload(sentAtDayKey: "not a day key"), to: manager, from: friend)

        #expect(ledger.receivedHearts.isEmpty)
    }

    @Test func duplicateHeartsFromSameFriendWithinRateWindowAreSilentlyDropped() throws {
        let host = MockHeartProximityHost()
        let friend = makePeerIdentity(displayName: "Aisha Bloom")
        host.proximityTrustVault.trust(friend, mode: .friend)
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)

        let first = HeartPayload(sentAtDayKey: "2026-07-05")
        try deliver(first, to: manager, from: friend)
        try deliver(first, to: manager, from: friend)                                // exact re-delivery
        try deliver(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: friend)  // fresh id, same window

        #expect(ledger.receivedHearts.count == 1)

        // A different friend's heart in the same window still lands.
        let other = makePeerIdentity(displayName: "Robin Vale")
        host.proximityTrustVault.trust(other, mode: .friend)
        try deliver(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: other, senderDisplayName: "Robin Vale")
        #expect(ledger.receivedHearts.count == 2)
    }

    // MARK: - Manager send gating

    @Test func sendHeartFailsGentlyWhenFriendIsNotReachable() throws {
        let host = MockHeartProximityHost()
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)
        let friend = trustedRecord(displayName: "Aisha Bloom")

        manager.sendHeart(to: friend)

        guard case .failed(let message) = manager.heartSendState else {
            Issue.record("Expected a failed send state, got \(manager.heartSendState)")
            return
        }
        #expect(message.contains("in person"))
        #expect(ledger.canSendHeart(to: friend.fingerprint))  // the rate window was NOT consumed
    }

    @Test func sendHeartRefusesSecondHeartToSameFriendWithinRateWindow() throws {
        let host = MockHeartProximityHost()
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)
        let friend = trustedRecord(displayName: "Aisha Bloom")

        ledger.recordHeartSent(to: friend.fingerprint)
        manager.sendHeart(to: friend)

        guard case .failed(let message) = manager.heartSendState else {
            Issue.record("Expected a failed send state, got \(manager.heartSendState)")
            return
        }
        // Phase 4b: the copy is a 5-minute cooldown, not a daily limit.
        #expect(message.contains("You just sent Aisha some warmth"))
    }

    // MARK: - Per-connection trust gate (Phase 4b): non-friends torn down, friends retained

    /// Drives a real coordinator through the full handshake to `.connected`, so the peer identity's
    /// signing key equals `remote`'s (which the caller may or may not have trusted in the vault).
    /// Returns the connected coordinator, its retained trust policy, and the transport peer.
    private func connectedCoordinator(
        local: IdentityService,
        remote: IdentityService,
        vault: ProximityTrustVault,
        peerName: String
    ) async throws -> (ProximityCoordinator, FriendSessionTrustPolicy, MultipeerPeer) {
        let transport = MockMultipeerTransport()
        let trustPolicy = FriendSessionTrustPolicy(vault: vault)
        let coordinator = ProximityCoordinator(
            identity: local,
            transport: transport,
            ranging: MockRangingProvider(),
            inspector: nil,
            trustPolicy: trustPolicy,
            replayCache: ReplayCache(),
            foregroundAnchor: NoopProximityForegroundAnchor(),
            displayName: "Local",
            timeoutSeconds: 0
        )
        let peer = MultipeerPeer(
            id: UUID(),
            displayName: peerName,
            discoveryInfo: ["fp": remote.localFingerprint],
            advertisedFingerprint: remote.localFingerprint,
            underlying: MCPeerID(displayName: peerName)
        )
        let intro = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: peerName,
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello from \(peerName)"),
            payload: Data()
        )
        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        // Poll rather than sleep-a-fixed-amount: the transport→coordinator hop is async and 10 ms is
        // not reliable under parallel test execution.
        await waitUntil { if case .awaitingTapConfirmation = coordinator.state { return true }; return false }
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(intro), from: peer)
        await waitUntil {
            switch coordinator.state {
            case .awaitingUserConfirmation, .connected: return true
            default: return false
            }
        }
        // FriendSessionTrustPolicy.isTrustedProximityPeer always returns true, so in trainer mode the
        // coordinator auto-confirms to .connected on its own; only confirm explicitly if it hasn't yet
        // (otherwise pendingPeerIdentity is already consumed and a second confirm fails).
        if case .awaitingUserConfirmation = coordinator.state {
            await coordinator.confirmPeerIdentity()
        }
        guard case .connected = coordinator.state else {
            throw TestFailure.notConnected(String(describing: coordinator.state))
        }
        return (coordinator, trustPolicy, peer)
    }

    private enum TestFailure: Error { case notConnected(String) }

    /// Gives up only once the deadline has passed AND `minimumPolls` observations have really been
    /// made. A `ContinuousClock` deadline alone measures wall clock, which keeps advancing while
    /// this `@MainActor` suite is starved in a loaded full-suite run — so it can expire having
    /// genuinely looked only a handful of times. Counting observations ties the give-up decision
    /// to scheduling received rather than to time elapsed, and still terminates: `polls` only
    /// climbs, and every turn of the loop sleeps.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        minimumPolls: Int = 400,
        condition: @escaping @MainActor () -> Bool
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

    @Test func verifiedNonFriendHeartPeerIsTornDown() async throws {
        let host = MockHeartProximityHost()
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (stranger, strangerID) = try makeIdentity(); defer { cleanup(strangerID) }
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)

        // The stranger is NEVER trusted in the vault.
        let (coordinator, policy, peer) = try await connectedCoordinator(
            local: local, remote: stranger, vault: host.proximityTrustVault, peerName: "Stranger"
        )
        // An inbound-only heart connection (no intendedFriend) from a verified non-friend is
        // torn down at once — the connection is dropped and never retained.
        let accepted = manager.evaluateConnectedCoordinatorForTesting(coordinator, peer: peer, trustPolicy: policy)

        #expect(!accepted)
        #expect(manager.heartConnectionCountForTesting == 0)
    }

    @Test func verifiedTrustedFriendConnectionIsRetained() async throws {
        let host = MockHeartProximityHost()
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (friend, friendID) = try makeIdentity(); defer { cleanup(friendID) }
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { self.baseDate })
        let manager = PresenceManager(store: host, ledger: ledger)

        // Trust the friend's real signing key in the vault (mode .friend).
        host.proximityTrustVault.trust(
            ProximityCoordinator.PeerIdentity(
                id: UUID(),
                displayName: "Aisha Bloom",
                signingPublicKey: friend.localSigningPublicKey,
                keyAgreementPublicKey: friend.localKeyAgreementPublicKey,
                fingerprint: friend.localFingerprint,
                rangingMode: .none,
                firstSeenAt: baseDate
            ),
            mode: .friend
        )

        let (coordinator, policy, peer) = try await connectedCoordinator(
            local: local, remote: friend, vault: host.proximityTrustVault, peerName: "Aisha Bloom"
        )
        // A verified, still-trusted friend's inbound connection is retained so they can deliver.
        let accepted = manager.evaluateConnectedCoordinatorForTesting(coordinator, peer: peer, trustPolicy: policy)

        #expect(accepted)
        #expect(manager.heartConnectionCountForTesting == 1)
    }

    @Test func blockedFriendHeartPeerIsNeverEligibleForTeardownGate() async throws {
        // A once-trusted friend who is now blocked is treated as NOT a trusted friend by the gate.
        // (`vault.block` also revokes, so the live coordinator additionally rejects their envelopes at
        // the wire layer — see retainedTrustPolicyDropsEnvelopeFromBlockedKey; this test isolates the
        // manager-side gate decision so it doesn't depend on the handshake reaching .connected.)
        let host = MockHeartProximityHost()
        let (peerIdentity, peerID) = try makeIdentity(); defer { cleanup(peerID) }

        let identity = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Ex Friend",
            signingPublicKey: peerIdentity.localSigningPublicKey,
            keyAgreementPublicKey: peerIdentity.localKeyAgreementPublicKey,
            fingerprint: peerIdentity.localFingerprint,
            rangingMode: .none,
            firstSeenAt: baseDate
        )
        host.proximityTrustVault.trust(identity, mode: .friend)
        // Before block: the gate accepts them.
        #expect(PresenceManager.isHeartEligibleFriendForTesting(identity, in: host))

        host.proximityTrustVault.block(signingPublicKey: peerIdentity.localSigningPublicKey)
        // After block: the gate rejects them (blocked signing key + blocked fingerprint).
        #expect(!PresenceManager.isHeartEligibleFriendForTesting(identity, in: host))
    }

    // MARK: - Retained trust policy enforces revoked/blocked keys at the envelope layer (finding [11])

    @Test func retainedTrustPolicyDropsEnvelopeFromBlockedKey() async throws {
        // With the trust policy RETAINED (as the connection now does), an envelope from a BLOCKED
        // signing key is rejected inside the coordinator (state → .failed), and the manager never
        // sees the payload. This is the enforcement that silently no-oped when the policy deallocated.
        // (Phase-2 friend lifecycle semantics moved the friend-mode transport ban to blocked keys
        // only — a revoked-only "Removed" peer may handshake again — so this test blocks rather
        // than revokes; block() sets both timestamps and fires the same coordinator gate.)
        let vault = ProximityTrustVault()
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (remote, remoteID) = try makeIdentity(); defer { cleanup(remoteID) }

        // Trust then BLOCK the remote's signing key.
        let remotePeer = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Revoked",
            signingPublicKey: remote.localSigningPublicKey,
            keyAgreementPublicKey: remote.localKeyAgreementPublicKey,
            fingerprint: remote.localFingerprint,
            rangingMode: .none,
            firstSeenAt: baseDate
        )
        vault.trust(remotePeer, mode: .friend)
        vault.block(signingPublicKey: remote.localSigningPublicKey)

        let transport = MockMultipeerTransport()
        let trustPolicy = FriendSessionTrustPolicy(vault: vault)   // held for the test's lifetime
        let coordinator = ProximityCoordinator(
            identity: local,
            transport: transport,
            ranging: MockRangingProvider(),
            inspector: nil,
            trustPolicy: trustPolicy,
            replayCache: ReplayCache(),
            foregroundAnchor: NoopProximityForegroundAnchor(),
            displayName: "Local",
            timeoutSeconds: 0
        )
        let peer = MultipeerPeer(
            id: UUID(),
            displayName: "Revoked",
            discoveryInfo: ["fp": remote.localFingerprint],
            advertisedFingerprint: remote.localFingerprint,
            underlying: MCPeerID(displayName: "Revoked")
        )
        let intro = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Revoked",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: Data()
        )

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        await waitUntil { if case .awaitingTapConfirmation = coordinator.state { return true }; return false }
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(intro), from: peer)
        await waitUntil { if case .failed = coordinator.state { return true }; return false }

        // The banned-key check fired: the coordinator failed instead of processing the envelope.
        guard case .failed(let reason) = coordinator.state else {
            Issue.record("Expected .failed from blocked-key drop, got \(coordinator.state)")
            return
        }
        #expect(reason.contains("revokedKey"))
        // And the audit trail recorded the block (recordTrainerAudit ran because the policy was alive).
        #expect(vault.auditEvents.contains { $0.kind == .revokedPeerBlocked })
    }

    private func trustedRecord(displayName: String) -> ProximityTrustedPeerRecord {
        let signingKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        return ProximityTrustedPeerRecord(
            displayName: displayName,
            fingerprint: IdentityService.fingerprint(of: signingKey),
            signingPublicKey: signingKey,
            keyAgreementPublicKey: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }),
            mode: .friend
        )
    }

    // MARK: - Rate-limit persistence across relaunch (injected clock)

    @Test func sendRateLimitPersistsAcrossRelaunchAndResetsAfterWindow() throws {
        // Phase 4b: the send limit is a rolling 5-minute per-friend window, not a daily key.
        let url = tempLedgerURL()
        var clock = baseDate

        let first = ProximityHeartLedger(fileURL: url, now: { clock })
        #expect(first.canSendHeart(to: "fp-aisha"))
        first.recordHeartSent(to: "fp-aisha")
        #expect(!first.canSendHeart(to: "fp-aisha"))
        #expect(first.canSendHeart(to: "fp-robin"))  // per-friend, not global

        // "Relaunch": a fresh ledger on the same file, still inside the window → still spent.
        let relaunched = ProximityHeartLedger(fileURL: url, now: { clock })
        #expect(!relaunched.canSendHeart(to: "fp-aisha"))

        // Past the 5-minute window → the heart is available again.
        clock = baseDate.addingTimeInterval(ProximityHeartLedger.rateLimitInterval + 1)
        let afterWindow = ProximityHeartLedger(fileURL: url, now: { clock })
        #expect(afterWindow.canSendHeart(to: "fp-aisha"))
    }

    @Test func receiveRateLimitAndRecordsPersistAcrossRelaunch() throws {
        let url = tempLedgerURL()
        var clock = baseDate

        let first = ProximityHeartLedger(fileURL: url, now: { clock })
        #expect(first.recordReceivedHeart(id: UUID(), senderDisplayName: "Aisha", senderFingerprint: "fp-aisha"))
        #expect(!first.recordReceivedHeart(id: UUID(), senderDisplayName: "Aisha", senderFingerprint: "fp-aisha"))

        // "Relaunch": the stored heart and the 5-minute receive window both survive.
        let relaunched = ProximityHeartLedger(fileURL: url, now: { clock })
        #expect(relaunched.receivedHearts.count == 1)
        #expect(relaunched.receivedHearts.first?.senderDisplayName == "Aisha")
        #expect(!relaunched.recordReceivedHeart(id: UUID(), senderDisplayName: "Aisha", senderFingerprint: "fp-aisha"))

        // Past the window: a fresh heart from the same friend lands again.
        clock = baseDate.addingTimeInterval(ProximityHeartLedger.rateLimitInterval + 1)
        let afterWindow = ProximityHeartLedger(fileURL: url, now: { clock })
        #expect(afterWindow.recordReceivedHeart(id: UUID(), senderDisplayName: "Aisha", senderFingerprint: "fp-aisha"))
        #expect(afterWindow.receivedHearts.count == 2)
    }

    @Test func bubbleDismissalPersistsAndGlowKeepsDecaying() throws {
        let url = tempLedgerURL()
        var clock = baseDate

        let ledger = ProximityHeartLedger(fileURL: url, now: { clock })
        let heartID = UUID()
        ledger.recordReceivedHeart(id: heartID, senderDisplayName: "Aisha", senderFingerprint: "fp-aisha")
        #expect(ledger.pendingBubbleHeart?.id == heartID)

        ledger.dismissBubble(id: heartID)
        #expect(ledger.pendingBubbleHeart == nil)
        // Dismissing the bubble does not touch the glow.
        clock = baseDate.addingTimeInterval(12 * 60 * 60)
        #expect(abs(ledger.activeGlow() - 0.5) < 0.001)

        let relaunched = ProximityHeartLedger(fileURL: url, now: { clock })
        #expect(relaunched.pendingBubbleHeart == nil)
        #expect(abs(relaunched.activeGlow() - 0.5) < 0.001)
    }

    // MARK: - Glow decay math

    @Test func glowDecaysLinearlyOverTwentyFourHours() {
        let receivedAt = baseDate

        #expect(HeartGlowMath.glow(receivedAt: receivedAt, at: receivedAt) == 1)
        #expect(abs(HeartGlowMath.glow(receivedAt: receivedAt, at: receivedAt.addingTimeInterval(6 * 3600)) - 0.75) < 0.001)
        #expect(abs(HeartGlowMath.glow(receivedAt: receivedAt, at: receivedAt.addingTimeInterval(12 * 3600)) - 0.5) < 0.001)
        #expect(HeartGlowMath.glow(receivedAt: receivedAt, at: receivedAt.addingTimeInterval(24 * 3600)) == 0)
        #expect(HeartGlowMath.glow(receivedAt: receivedAt, at: receivedAt.addingTimeInterval(48 * 3600)) == 0)
    }

    @Test func glowClampsClockSkewAndDegenerateWindows() {
        // Receipt "in the future" (device clock moved back) reads as just-received, never > 1.
        #expect(HeartGlowMath.glow(receivedAt: baseDate.addingTimeInterval(3600), at: baseDate) == 1)
        // A degenerate window can never divide by zero or go negative.
        #expect(HeartGlowMath.glow(receivedAt: baseDate, at: baseDate, window: 0) == 0)
        #expect(HeartGlowMath.glow(receivedAt: baseDate, at: baseDate.addingTimeInterval(1), window: -5) == 0)
    }

    @Test func activeGlowUsesStrongestHeartNotASum() throws {
        var clock = baseDate
        let ledger = ProximityHeartLedger(fileURL: tempLedgerURL(), now: { clock })
        ledger.recordReceivedHeart(id: UUID(), senderDisplayName: "Aisha", senderFingerprint: "fp-aisha")
        clock = baseDate.addingTimeInterval(12 * 60 * 60)
        ledger.recordReceivedHeart(id: UUID(), senderDisplayName: "Robin", senderFingerprint: "fp-robin")

        // Older heart is at 0.5, newer at 1.0 → the glow is the max (1.0), never 1.5.
        #expect(abs(ledger.activeGlow() - 1.0) < 0.001)
    }

    // MARK: - Settings

    @Test func allowNearbyHeartsDefaultsOffAndDecodesWhenAbsent() throws {
        // Opt-in (default off): the auto-connecting heart listener stays silent until the user turns
        // it on, so no signed-identity exchange happens without consent.
        #expect(!FernletSettings().allowNearbyHearts)

        let legacy = try JSONDecoder().decode(FernletSettings.self, from: Data("{}".utf8))
        #expect(!legacy.allowNearbyHearts)

        var settings = FernletSettings()
        settings.allowNearbyHearts = true
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.allowNearbyHearts)
    }
}

/// Minimal `ProximityHost` — the heart manager reads the display name, the trust vault, and the
/// blocked-fingerprint check (which defers to the vault here, matching the store's behavior).
@MainActor
private final class MockHeartProximityHost: ProximityHost {
    var proximityDisplayName: String { "Tester" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}

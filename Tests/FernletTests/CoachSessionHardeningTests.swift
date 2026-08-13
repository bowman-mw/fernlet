// CoachSessionHardeningTests.swift
// FernletTests
//
// Increment 10, option B (Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26): the coach-path
// hardening that ships AHEAD of the coach session manager, driven purely by tests — the
// pre-decrypt size gate, the coach verification ceremony (slot-independent, carrying the
// wrong-peer nonce rules from the 2026-07-25 review), the mode-scoped coach trust policy, the
// wire2 capability negotiation pin for trainer mode, and the executable role-split decision.
// The non-UWB tap-gate fallback itself is pinned in ProximityCoordinatorTests
// (nonUWBTrainerAutoAdvancesPastTheTapGate / uwbTrainerStillWaitsForTheTap).

import Foundation
import Testing
import MultipeerConnectivity
import ProximityKit
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@Suite(.serialized) @MainActor
struct CoachSessionHardeningTests {

    // MARK: - Harness

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.coach.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    private func cleanup(_ id: String) {
        KeychainItem.deleteAll(service: id)
    }

    private func makePeer(name: String = "Coach", fingerprint: String? = nil) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: fingerprint.map { ["fp": $0] },
            advertisedFingerprint: fingerprint,
            underlying: MCPeerID(displayName: name)
        )
    }

    final class AuditRecordingTrustPolicy: ProximityTrustPolicy {
        var events: [TrainerAuditEvent] = []
        func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool { false }
        func isBlockedProximitySigningKey(_ publicKey: Data) -> Bool { false }
        func isTrustedProximityPeer(signingPublicKey: Data) -> Bool { false }
        func recordTrainerAudit(_ event: TrainerAuditEvent) { events.append(event) }
    }

    private func makeRecord(
        _ identity: IdentityService,
        name: String,
        mode: ProximityMode,
        revokedAt: Date? = nil,
        blockedAt: Date? = nil
    ) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: name,
            fingerprint: identity.localFingerprint,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            mode: mode,
            revokedAt: revokedAt,
            blockedAt: blockedAt
        )
    }

    // MARK: - Role split (executable decision record)

    /// The role split is a decision, not a convention: Fernlet BROWSES, the coaching app
    /// ADVERTISES — two advertisers never find each other. Pinned so a future session manager
    /// reads it from `CoachSessionContract` instead of guessing.
    @Test func roleSplitIsFernletBrowsesCoachAdvertises() {
        #expect(CoachSessionContract.fernletRole == .browser)
        #expect(CoachSessionContract.coachAppRole == .advertiser)
        #expect(CoachSessionContract.fernletRole != CoachSessionContract.coachAppRole)
    }

    // MARK: - Pre-decrypt size gate (Increment 10 item 4)

    /// An oversized inbound blob on a TRAINER session is rejected before the envelope is even
    /// decoded — the hearts ordering (size before key agreement/inflate), at the layer
    /// `TrainerExportPayload.isWellFormed` (post-decrypt) cannot provide.
    @Test func oversizedTrainerInboundIsRejectedBeforeDecode() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let audit = AuditRecordingTrustPolicy()
        let coordinator = ProximityCoordinator(
            identity: identity,
            transport: transport,
            ranging: MockRangingProvider(),
            trustPolicy: audit,
            replayCache: ReplayCache(),
            displayName: "Local Device",
            timeoutSeconds: 0
        )
        let peer = makePeer()
        await coordinator.begin(role: CoachSessionContract.fernletRole, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        transport.simulateInboundData(
            Data(count: TrainerExportPayload.maxTrainerWireBytes + 1), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.state == .failed(reason: "oversized inbound payload"))
        #expect(audit.events.contains {
            $0.kind == .envelopeRejected && $0.message.contains("oversized")
        }, "the rejection must be auditable, not silent")
    }

    /// The same blob on a FRIEND session does not trip the trainer gate — the friend channel
    /// legitimately carries multi-MB photo payloads under its own receiver cap. (It still fails
    /// envelope DECODE here, which is the point: a different, later, cheaper-per-byte layer.)
    @Test func theTrainerWireCapIsTrainerScoped() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = ProximityCoordinator(
            identity: identity,
            transport: transport,
            ranging: MockRangingProvider(),
            replayCache: ReplayCache(),
            displayName: "Local Device",
            timeoutSeconds: 0
        )
        let peer = makePeer(name: "Friend")
        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        transport.simulateInboundData(
            Data(count: TrainerExportPayload.maxTrainerWireBytes + 1), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.state != .failed(reason: "oversized inbound payload"))
    }

    /// The wire cap is derived from the bundle cap, never hand-written — and the margin is
    /// pinned against the REAL inflate guard, so a future `maxInflatedByteCount` change can't
    /// silently erode it.
    @Test func trainerWireCapInvariantsHold() {
        #expect(TrainerExportPayload.maxTrainerWireBytes == 2 * TrainerExportPayload.maxBundleBytes)
        #expect(TrainerExportPayload.maxTrainerWireBytes < SealedPayloadFraming.maxInflatedByteCount / 2)
    }

    // MARK: - Coach trust policy (Increment 10 item 5)

    /// "A coach is NOT a friend" (coach spec §3.2), executable: remembered trust on the coach
    /// channel requires a `.trainer`-mode vault record — an established FRIEND does not
    /// auto-confirm as a coach, and vice versa the friend policy's unconditional-true answer
    /// must never reach a coach coordinator.
    @Test func coachTrustIsModeScopedRememberedTrust() throws {
        let (friend, friendID) = try makeIdentity()
        defer { cleanup(friendID) }
        let (coach, coachID) = try makeIdentity()
        defer { cleanup(coachID) }
        let (formerCoach, formerID) = try makeIdentity()
        defer { cleanup(formerID) }
        let (banned, bannedID) = try makeIdentity()
        defer { cleanup(bannedID) }
        let (stranger, strangerID) = try makeIdentity()
        defer { cleanup(strangerID) }

        let vault = ProximityTrustVault(initialPeers: [
            makeRecord(friend, name: "Best Friend", mode: .friend),
            makeRecord(coach, name: "Coach Kim", mode: .trainer),
            makeRecord(formerCoach, name: "Removed Coach", mode: .trainer, revokedAt: Date()),
            makeRecord(banned, name: "Blocked Coach", mode: .trainer, blockedAt: Date())
        ])
        let policy = CoachSessionTrustPolicy(vault: vault)

        #expect(policy.isTrustedProximityPeer(signingPublicKey: coach.localSigningPublicKey))
        #expect(!policy.isTrustedProximityPeer(signingPublicKey: friend.localSigningPublicKey),
                "a friend record must not auto-confirm a coach session")
        #expect(!policy.isTrustedProximityPeer(signingPublicKey: formerCoach.localSigningPublicKey))
        #expect(!policy.isTrustedProximityPeer(signingPublicKey: banned.localSigningPublicKey))
        #expect(!policy.isTrustedProximityPeer(signingPublicKey: stranger.localSigningPublicKey))

        // Lifecycle: removed ≠ banned (a re-hired coach may handshake again through the full
        // first-pairing flow); blocked is the transport ban, mode-blind.
        #expect(!policy.isRevokedProximitySigningKey(formerCoach.localSigningPublicKey))
        #expect(policy.isRevokedProximitySigningKey(banned.localSigningPublicKey))
        #expect(policy.isBlockedProximitySigningKey(banned.localSigningPublicKey))

        // The divergence this policy exists for, made explicit:
        let friendPolicy = FriendSessionTrustPolicy(vault: vault)
        #expect(friendPolicy.isTrustedProximityPeer(signingPublicKey: friend.localSigningPublicKey))
        #expect(friendPolicy.isTrustedProximityPeer(signingPublicKey: stranger.localSigningPublicKey),
                "the friend policy answers true unconditionally — exactly why it must never be injected into a coach coordinator")
    }

    /// `.trainer` is the decode FREEZE DEFAULT for a mode this build doesn't know
    /// (`ProximityPersistenceRecords` parks the real token in `unknownModeToken`), and the
    /// record's contract demands any privilege-deriving reader of stored mode re-audit that
    /// default. A record synced from a NEWER build under a future mode must read "not a coach"
    /// — never silently auto-confirm as one (adversarial review finding, 2026-07-27).
    @Test func aFreezeDefaultedUnknownModeNeverAutoConfirmsAsACoach() throws {
        let (peer, peerID) = try makeIdentity()
        defer { cleanup(peerID) }

        var frozen = makeRecord(peer, name: "Future Mode Peer", mode: .trainer)
        frozen.unknownModeToken = "someFutureMode" // what the tolerant decoder parks
        let vault = ProximityTrustVault(initialPeers: [frozen])
        let policy = CoachSessionTrustPolicy(vault: vault)

        #expect(!policy.isTrustedProximityPeer(signingPublicKey: peer.localSigningPublicKey),
                "a freeze-defaulted record must not grant coach auto-confirm")
    }

    // MARK: - Wire2 capability negotiation pin (Increment 10 item 3)

    /// The capability handshake is mode-blind, so a trainer session negotiates wire2 exactly
    /// like the mesh — PROVIDED the coordinator is constructed with real `capabilities`. This
    /// pins that path for the future coach session manager (the old discovery-info "caps"
    /// string it might have been tempted to rely on is gone).
    @Test func trainerSessionNegotiatesWire2FromRealCapabilities() async throws {
        struct CapablePayload: Encodable {
            let rangingMode: String
            let discoveryToken: Data?
            let capabilities: [String]
        }
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = ProximityCoordinator(
            identity: local,
            transport: transport,
            ranging: MockRangingProvider(isHardwareSupported: false),
            replayCache: ReplayCache(),
            displayName: "Local Device",
            capabilities: [ProximityCapability.wire2.rawValue],
            timeoutSeconds: 0
        )
        let peer = makePeer(name: "Remote Coach", fingerprint: remote.localFingerprint)
        await coordinator.begin(role: CoachSessionContract.fernletRole, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000) // non-UWB fallback auto-sends our intro

        // Our own intro advertises the configured capability set.
        let intro = try #require(transport.sentData.first.flatMap {
            try? JSONDecoder().decode(FernletIdentityEnvelope.self, from: $0.0)
        })
        #expect(intro.payloadType == .identityIntroduction)
        struct DecodableCaps: Decodable { let capabilities: [String]? }
        #expect(try JSONDecoder().decode(DecodableCaps.self, from: intro.payload).capabilities == ["wire2"])

        // The peer's advertised capabilities land on the verified identity the session exposes.
        let payload = try JSONEncoder().encode(CapablePayload(
            rangingMode: "rssi", discoveryToken: nil,
            capabilities: [ProximityCapability.wire2.rawValue]))
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Remote Coach",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: payload
        )
        transport.simulateInboundData(try JSONEncoder().encode(envelope), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .awaitingUserConfirmation(let peerIdentity) = coordinator.state else {
            Issue.record("expected awaitingUserConfirmation, got \(coordinator.state)")
            return
        }
        #expect(peerIdentity.supports(.wire2),
                "wire2 must negotiate on the trainer channel or every coach payload silently degrades to legacy")
    }

    // MARK: - Coach verification ceremony (Increment 10 item 2)

    private func makeCeremonies(
        clock: @escaping () -> Date = Date.init
    ) throws -> (a: CoachVerificationCeremony, aID: IdentityService, b: CoachVerificationCeremony, bID: IdentityService, cleanupIDs: [String]) {
        let (aIdentity, aService) = try makeIdentity()
        let (bIdentity, bService) = try makeIdentity()
        return (
            CoachVerificationCeremony(identity: aIdentity, now: clock), aIdentity,
            CoachVerificationCeremony(identity: bIdentity, now: clock), bIdentity,
            [aService, bService]
        )
    }

    /// The happy path: display → scan → sealed challenge → checked-then-signed response →
    /// verified proof of key possession, bound to the scanner's KA key and both nonces.
    @Test func ceremonyRoundTripProvesKeyPossession() throws {
        let (a, aID, b, bID, ids) = try makeCeremonies()
        defer { ids.forEach(cleanup) }

        let url = try #require(a.makeDisplayURL(forPeerSigningKey: bID.localSigningPublicKey))
        let challenge = try #require(b.beginVerification(
            scannedURL: url, expectedPeerSigningKey: aID.localSigningPublicKey))

        let verdict = a.handleChallenge(
            challenge,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        )
        guard case .respond(let response) = verdict else {
            Issue.record("expected a response, got \(verdict)")
            return
        }
        #expect(b.handleResponse(response, senderSigningPublicKey: aID.localSigningPublicKey))
    }

    /// THE carried-forward defect (easy to reintroduce in a fresh implementation): a challenge
    /// from a peer other than the one the sheet was opened for is dropped WITHOUT clearing the
    /// nonce — and nothing is signed before that check. Burning the nonce is exactly how a
    /// racing third party would deny the named peer their genuine round.
    @Test func wrongPeerChallengeIsDroppedWithoutBurningTheNonce() throws {
        let (a, aID, b, bID, ids) = try makeCeremonies()
        defer { ids.forEach(cleanup) }
        let (racer, racerService) = try makeIdentity()
        defer { cleanup(racerService) }

        let url = try #require(a.makeDisplayURL(forPeerSigningKey: bID.localSigningPublicKey))
        let genuine = try #require(b.beginVerification(
            scannedURL: url, expectedPeerSigningKey: aID.localSigningPublicKey))

        // A third party who can see the screen races the ceremony, quoting the same QR nonce.
        let raced = VerifyChallengePayload(
            qrNonce: genuine.qrNonce,
            challengeNonce: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
        let racedVerdict = a.handleChallenge(
            raced,
            senderSigningPublicKey: racer.localSigningPublicKey,
            senderKeyAgreementPublicKey: racer.localKeyAgreementPublicKey
        )
        #expect(racedVerdict == .droppedWrongPeer)

        // The named peer's genuine round still completes — the nonce survived the race.
        let verdict = a.handleChallenge(
            genuine,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        )
        guard case .respond(let response) = verdict else {
            Issue.record("the genuine round was denied after a raced challenge: \(verdict)")
            return
        }
        #expect(b.handleResponse(response, senderSigningPublicKey: aID.localSigningPublicKey))
    }

    /// A response is single-use and the display is spent only by the named peer's round.
    @Test func theDisplayIsSingleUse() throws {
        let (a, aID, b, bID, ids) = try makeCeremonies()
        defer { ids.forEach(cleanup) }

        let url = try #require(a.makeDisplayURL(forPeerSigningKey: bID.localSigningPublicKey))
        let challenge = try #require(b.beginVerification(
            scannedURL: url, expectedPeerSigningKey: aID.localSigningPublicKey))
        guard case .respond = a.handleChallenge(
            challenge,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        ) else {
            Issue.record("first round failed")
            return
        }
        // A replayed challenge after the display was spent is stale.
        #expect(a.handleChallenge(
            challenge,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        ) == .droppedStale)
    }

    @Test func staleAndExpiredChallengesAreDropped() throws {
        nonisolated final class Clock: @unchecked Sendable {
            var date = Date()
        }
        let clock = Clock()
        let (a, aID, b, bID, ids) = try makeCeremonies(clock: { clock.date })
        defer { ids.forEach(cleanup) }

        // No display at all → stale.
        let noDisplay = a.handleChallenge(
            VerifyChallengePayload(qrNonce: Data(count: 16), challengeNonce: Data(count: 16)),
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        )
        #expect(noDisplay == .droppedStale)

        // A challenge quoting a nonce we are not displaying → stale (display kept).
        let url = try #require(a.makeDisplayURL(forPeerSigningKey: bID.localSigningPublicKey))
        let genuine = try #require(b.beginVerification(
            scannedURL: url, expectedPeerSigningKey: aID.localSigningPublicKey))
        let wrongNonce = VerifyChallengePayload(
            qrNonce: Data(count: 16), challengeNonce: genuine.challengeNonce)
        #expect(a.handleChallenge(
            wrongNonce,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        ) == .droppedStale)

        // Past the freshness window the display is dead and cleared — a genuine challenge is
        // refused, and so is every later one (the binding is gone, not resurrectable).
        clock.date = clock.date.addingTimeInterval(ProximityVerifyQR.freshnessWindow + 1)
        #expect(a.handleChallenge(
            genuine,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        ) == .droppedExpired)
        #expect(a.handleChallenge(
            genuine,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        ) == .droppedStale)
    }

    /// Scanner side: a coach session has exactly one counterpart — a valid QR from anyone else
    /// is refused outright rather than searched for a match.
    /// The scanner's signature + freshness gate is load-bearing, not decorative: a stale
    /// (photographed-days-ago) QR and a tampered one (someone else's payload rewritten to claim
    /// the session peer's keys) must both be refused before any challenge is minted.
    @Test func scannerRefusesStaleAndTamperedQRs() throws {
        nonisolated final class Clock: @unchecked Sendable {
            var date = Date()
        }
        let clock = Clock()
        let (a, aID, b, _, ids) = try makeCeremonies(clock: { clock.date })
        defer { ids.forEach(cleanup) }

        // Stale: the QR was minted, then the freshness window passed before the scan.
        let staleURL = try #require(a.makeDisplayURL(forPeerSigningKey: aID.localSigningPublicKey))
        clock.date = clock.date.addingTimeInterval(ProximityVerifyQR.freshnessWindow + 1)
        #expect(b.beginVerification(
            scannedURL: staleURL, expectedPeerSigningKey: aID.localSigningPublicKey) == nil)

        // Tampered: a payload re-written to claim the session peer's signing key no longer
        // matches its own signature.
        let freshURL = try #require(a.makeDisplayURL(forPeerSigningKey: aID.localSigningPublicKey))
        let payload = try #require(ProximityVerifyQR.parse(freshURL))
        let forged = ProximityVerifyQR.Payload(
            version: payload.version,
            signingPublicKey: payload.signingPublicKey,
            keyAgreementPublicKey: payload.keyAgreementPublicKey,
            timestamp: payload.timestamp,
            nonce: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }), // re-minted nonce
            signature: payload.signature // …but the old signature
        )
        var components = URLComponents()
        components.scheme = ProximityVerifyQR.urlScheme
        components.host = ProximityVerifyQR.urlHost
        components.queryItems = [URLQueryItem(
            name: "d",
            value: ProximityVerifyQR.base64URLEncode(try JSONEncoder().encode(forged)))]
        let forgedURL = try #require(components.url)
        #expect(b.beginVerification(
            scannedURL: forgedURL, expectedPeerSigningKey: aID.localSigningPublicKey) == nil,
            "a payload that fails its own signature must never open a round")
    }

    @Test func scannerRefusesAQRFromAnyoneButTheSessionPeer() throws {
        let (_, aID, b, _, ids) = try makeCeremonies()
        defer { ids.forEach(cleanup) }
        let (impostor, impostorService) = try makeIdentity()
        defer { cleanup(impostorService) }

        let impostorCeremony = CoachVerificationCeremony(identity: impostor)
        let impostorURL = try #require(
            impostorCeremony.makeDisplayURL(forPeerSigningKey: aID.localSigningPublicKey))
        #expect(b.beginVerification(
            scannedURL: impostorURL,
            expectedPeerSigningKey: aID.localSigningPublicKey) == nil)
    }

    /// Scanner side: a tampered or wrong-sender response never verifies, a bad signature burns
    /// the round (fail-closed re-scan), and a verified round is not replayable.
    @Test func responsesAreCheckedForSenderSignatureAndReplay() throws {
        let (a, aID, b, bID, ids) = try makeCeremonies()
        defer { ids.forEach(cleanup) }
        let (impostor, impostorService) = try makeIdentity()
        defer { cleanup(impostorService) }

        let url = try #require(a.makeDisplayURL(forPeerSigningKey: bID.localSigningPublicKey))
        let challenge = try #require(b.beginVerification(
            scannedURL: url, expectedPeerSigningKey: aID.localSigningPublicKey))
        guard case .respond(let response) = a.handleChallenge(
            challenge,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        ) else {
            Issue.record("no response")
            return
        }

        // Wrong sender: dropped, round KEPT — the real response still verifies afterwards.
        #expect(!b.handleResponse(response, senderSigningPublicKey: impostor.localSigningPublicKey))
        #expect(b.handleResponse(response, senderSigningPublicKey: aID.localSigningPublicKey))

        // Verified rounds are spent: a replay of the same response fails.
        #expect(!b.handleResponse(response, senderSigningPublicKey: aID.localSigningPublicKey))

        // A tampered signature burns the round entirely (fail-closed; the user re-scans).
        let url2 = try #require(a.makeDisplayURL(forPeerSigningKey: bID.localSigningPublicKey))
        let challenge2 = try #require(b.beginVerification(
            scannedURL: url2, expectedPeerSigningKey: aID.localSigningPublicKey))
        guard case .respond(let response2) = a.handleChallenge(
            challenge2,
            senderSigningPublicKey: bID.localSigningPublicKey,
            senderKeyAgreementPublicKey: bID.localKeyAgreementPublicKey
        ) else {
            Issue.record("no second response")
            return
        }
        var tamperedSignature = response2.signature
        tamperedSignature[0] ^= 0xFF
        let tampered = VerifyResponsePayload(
            challengeNonce: response2.challengeNonce, signature: tamperedSignature)
        #expect(!b.handleResponse(tampered, senderSigningPublicKey: aID.localSigningPublicKey))
        #expect(!b.handleResponse(response2, senderSigningPublicKey: aID.localSigningPublicKey),
                "a bad signature burns the round — fail-closed")
    }
}

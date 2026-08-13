// PresenceHeartsTests.swift
// FernletTests
//
// Mesh redesign Phase 4b (Docs/Proximity-Mesh-Redesign-2026-07-10.md): the presence-specific
// heart behaviour that did NOT exist on the deleted standalone heart radio — reachability defined
// by the presence nearby set, the inbound invitation gate (accept only a discovered-matched
// friend), and the three homes of the `allowNearbyHearts` opt-out (send-side block, receive-side
// drop; the FriendListView row render is a view concern). Codec / envelope / ledger / per-connection
// trust-gate coverage lives in HeartShareTests. No test here starts a real radio — every path is
// driven through the no-radio seams.

@testable import ProximityKit
import Foundation
import Testing
import CryptoKit
import MultipeerConnectivity
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@MainActor
private final class MockPresenceHeartsHost: ProximityHost {
    var proximityDisplayName: String { "Tester" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    /// Settable so a test can toggle the hearts opt-out (the app's FernletStore backs this with
    /// `settings.allowNearbyHearts`).
    var allowNearbyHearts: Bool = true
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}

@MainActor
@Suite(.serialized)
struct PresenceHeartsTests {

    private let baseDate = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Fixtures

    private func makeIdentity() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.presencehearts.test.\(UUID().uuidString)"
        let svc = IdentityService(keychainService: serviceID)
        try svc.ensureProvisioned()
        return (svc, serviceID)
    }

    private func makeLedger() -> ProximityHeartLedger {
        ProximityHeartLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-hearts-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json"),
            now: { self.baseDate })
    }

    private func kaPublic() -> Data {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    }

    private func makeFriend(fingerprint: String, keyAgreementPublicKey: Data) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: "Friend",
            fingerprint: fingerprint,
            signingPublicKey: Data((0..<8).map { _ in UInt8.random(in: 0...255) }),
            keyAgreementPublicKey: keyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: baseDate,
            lastSeenAt: baseDate)
    }

    private func peer(tokens: [String]) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: "peer-\(UUID().uuidString.prefix(8))",
            discoveryInfo: ["v": "1", "t": tokens.joined(separator: ",")],
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: "mc-\(UUID().uuidString.prefix(8))"))
    }

    private func makePeerIdentity(displayName: String, in host: MockPresenceHeartsHost, trust: Bool) -> ProximityCoordinator.PeerIdentity {
        let signingKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let identity = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: displayName,
            signingPublicKey: signingKey,
            keyAgreementPublicKey: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }),
            fingerprint: IdentityService.fingerprint(of: signingKey),
            rangingMode: .none,
            firstSeenAt: baseDate)
        if trust { host.proximityTrustVault.trust(identity, mode: .friend) }
        return identity
    }

    private func deliverHeart(_ payload: HeartPayload, to manager: PresenceManager, from peer: ProximityCoordinator.PeerIdentity?) throws {
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: peer?.displayName ?? "Aisha",
            recipientFingerprint: nil,
            payloadType: .friendHeart,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Good vibes"),
            payload: plaintext,
            createdAt: baseDate,
            expiresAt: nil,
            signature: Data())
        let coordinator = ProximityCoordinator(
            identity: {
                let id = IdentityService(keychainService: "test.presencehearts.\(UUID().uuidString)")
                try? id.ensureProvisioned()
                return id
            }(),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0)
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: peer)
    }

    // MARK: - Reachability = presence nearby set

    @Test func friendBecomesReachableWhenDiscoveredNearby() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHeartsHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        #expect(!manager.isReachable(fingerprint: "f00df00df00df00d"))

        // The friend advertises our shared tag PLUS a tag for one of their other friends (which we
        // cannot derive) — the latter distinguishes them from our own single-friend ghost (Group 3
        // self-exclusion layer 3).
        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        manager.handleDiscoveredPeerForTesting(peer(tokens: [token, theirOtherFriendTag]))

        #expect(manager.isReachable(fingerprint: "f00df00df00df00d"))
    }

    // MARK: - Hearts require presence (Group 2)

    @Test func heartAffordanceRequiresPresence() {
        // Hearts off → the row is hidden entirely, regardless of presence/reachability.
        #expect(PresenceManager.heartAffordance(heartsEnabled: false, presenceEnabled: false, reachable: false) == .heartsOff)
        #expect(PresenceManager.heartAffordance(heartsEnabled: false, presenceEnabled: true, reachable: true) == .heartsOff)

        // Hearts ON + presence OFF → the actionable `needsPresence` state, NOT a dead "not nearby",
        // even if a stale reachable flag says otherwise (reachability is meaningless without presence).
        #expect(PresenceManager.heartAffordance(heartsEnabled: true, presenceEnabled: false, reachable: false) == .needsPresence)
        #expect(PresenceManager.heartAffordance(heartsEnabled: true, presenceEnabled: false, reachable: true) == .needsPresence)

        // Hearts + presence on → the usual reachable/not-nearby split.
        #expect(PresenceManager.heartAffordance(heartsEnabled: true, presenceEnabled: true, reachable: false) == .notNearby)
        #expect(PresenceManager.heartAffordance(heartsEnabled: true, presenceEnabled: true, reachable: true) == .reachable)
    }

    /// Regression (review 2026-07-27): away delivery needs no presence radio, so the
    /// enable-presence prompt must not pre-empt it. It used to — `.needsPresence` fired on
    /// hearts-on + presence-off alone, and the friend row renders that branch INSTEAD of the send
    /// affordance, so opting into away hearts while leaving Nearby Friends off left every friend
    /// row on a dead-end nag with no Send button and copy ("hearts are sent in person") that the
    /// feature had just made false.
    @Test func awayDeliveryReplacesTheNeedsPresencePromptWithASendableNotNearby() {
        // The regressing combination: hearts on, presence OFF, away delivery ON.
        #expect(PresenceManager.heartAffordance(
            heartsEnabled: true, presenceEnabled: false, reachable: false,
            awayDeliveryEnabled: true) == .notNearby)
        // A stale reachable flag is still meaningless without presence — never `.reachable`.
        #expect(PresenceManager.heartAffordance(
            heartsEnabled: true, presenceEnabled: false, reachable: true,
            awayDeliveryEnabled: true) == .notNearby)

        // Away delivery does NOT resurrect a hidden row: the hearts opt-out still outranks it.
        #expect(PresenceManager.heartAffordance(
            heartsEnabled: false, presenceEnabled: false, reachable: false,
            awayDeliveryEnabled: true) == .heartsOff)

        // With away delivery OFF the prompt is still the right answer (the pre-existing behavior,
        // which the defaulted parameter also preserves for every untouched call site).
        #expect(PresenceManager.heartAffordance(
            heartsEnabled: true, presenceEnabled: false, reachable: false,
            awayDeliveryEnabled: false) == .needsPresence)

        // Presence on: away delivery changes nothing — the in-person split still decides.
        #expect(PresenceManager.heartAffordance(
            heartsEnabled: true, presenceEnabled: true, reachable: true,
            awayDeliveryEnabled: true) == .reachable)
        #expect(PresenceManager.heartAffordance(
            heartsEnabled: true, presenceEnabled: true, reachable: false,
            awayDeliveryEnabled: true) == .notNearby)
    }

    // MARK: - Teardown keeps a still-advertising peer reachable AND sendable (Group 4)

    @Test func heartConnectionTeardownKeepsAdvertisingPeerSendable() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHeartsHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        // A distinguishable friend advertisement (its own tag + a tag for another of their friends,
        // so self-exclusion layer 3 doesn't treat it as our ghost).
        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let otherTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let discovered = peer(tokens: [token, otherTag])
        manager.handleDiscoveredPeerForTesting(discovered)

        #expect(manager.isReachable(fingerprint: "f00df00df00df00d"))
        #expect(manager.hasSendablePeerForTesting(fingerprint: "f00df00df00df00d"))

        // A heart connection to this peer completes/fails and tears down while the peer is STILL
        // advertising presence — it must remain both reachable and sendable. Reachable-but-
        // unsendable was the bug: an immediate re-send after the cooldown failed "not nearby".
        manager.simulateHeartConnectionTeardownForTesting(
            peer: discovered, ranging: MockRangingProvider(isHardwareSupported: false))

        #expect(manager.isReachable(fingerprint: "f00df00df00df00d"),
                "A still-advertising peer stays reachable after a heart connection tears down")
        #expect(manager.hasSendablePeerForTesting(fingerprint: "f00df00df00df00d"),
                "...and stays sendable — reachable and sendable must agree")
    }

    // MARK: - Inbound invitation gate

    @Test func inboundInvitationAcceptedOnlyFromDiscoveredFriend() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHeartsHost()
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        // A peer whose tag matched a friend → accepted (distinguishable from our ghost by a tag for
        // one of the friend's other friends — Group 3 self-exclusion layer 3).
        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let friendPeer = peer(tokens: [token, theirOtherFriendTag])
        manager.handleDiscoveredPeerForTesting(friendPeer)
        #expect(manager.shouldAcceptHeartInvitationForTesting(friendPeer))

        // A never-discovered peer (the pre-discovery race) → rejected; the sender retries.
        let strangerPeer = peer(tokens: ["not-a-friend-tag"])
        #expect(!manager.shouldAcceptHeartInvitationForTesting(strangerPeer))
    }

    @Test func inboundInvitationRejectedWhenHeartsOff() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceHeartsHost()
        host.allowNearbyHearts = false
        let epoch = IdentityService.presenceEpoch(at: baseDate)

        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA)
        host.proximityTrustVault.apply(peers: [friend], audit: [])

        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.activateForTesting()

        let token = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOtherFriendTag = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let friendPeer = peer(tokens: [token, theirOtherFriendTag])
        manager.handleDiscoveredPeerForTesting(friendPeer)

        // Even a matched friend is refused a connection while hearts are off — presence stays
        // visible, but no heart connection forms.
        #expect(!manager.shouldAcceptHeartInvitationForTesting(friendPeer))
    }

    // MARK: - allowNearbyHearts send-side gate

    @Test func sendHeartIsBlockedWhenHeartsOff() throws {
        let host = MockPresenceHeartsHost()
        host.allowNearbyHearts = false
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let ledger = makeLedger()
        let manager = PresenceManager(store: host, ledger: ledger, identity: identity)
        manager.activateForTesting()

        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: kaPublic())
        manager.sendHeart(to: friend)

        guard case .failed(let message) = manager.heartSendState else {
            Issue.record("Expected a failed send, got \(manager.heartSendState)")
            return
        }
        #expect(message.contains("Turn on nearby hearts"))
        #expect(ledger.canSendHeart(to: friend.fingerprint))  // the window was NOT consumed
    }

    // MARK: - allowNearbyHearts receive-side drop

    @Test func inboundHeartIsDroppedWhenHeartsOff() throws {
        let host = MockPresenceHeartsHost()
        host.allowNearbyHearts = false
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let ledger = makeLedger()
        let manager = PresenceManager(store: host, ledger: ledger, identity: identity)

        // A verified, still-trusted friend — the ONLY reason the heart drops is the opt-out.
        let friend = makePeerIdentity(displayName: "Aisha Bloom", in: host, trust: true)
        try deliverHeart(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: friend)
        #expect(ledger.receivedHearts.isEmpty)

        // Turning hearts back on, the same friend's next heart lands.
        host.allowNearbyHearts = true
        try deliverHeart(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: friend)
        #expect(ledger.receivedHearts.count == 1)
    }

    // MARK: - Receive rate mirror (1 per sender per 5 min) through the manager

    @Test func inboundHeartRateMirrorDropsSecondWithinWindow() throws {
        let host = MockPresenceHeartsHost()
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let ledger = makeLedger()
        let manager = PresenceManager(store: host, ledger: ledger, identity: identity)

        let friend = makePeerIdentity(displayName: "Aisha Bloom", in: host, trust: true)
        try deliverHeart(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: friend)
        try deliverHeart(HeartPayload(sentAtDayKey: "2026-07-05"), to: manager, from: friend)  // fresh id, same window

        #expect(ledger.receivedHearts.count == 1, "The receive-rate mirror keeps only the first heart per sender per 5 min")
    }
}

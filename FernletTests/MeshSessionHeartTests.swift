// MeshSessionHeartTests.swift
// FernletTests
//
// TF b19 item 5 tier 2 — in-session hearts delivered over the LIVE mesh session (the reliable
// already-connected channel) instead of the fragile on-demand presence connect. Covers the mesh
// `.friendHeart` receive handler's MANDATORY receiver-side gates (a past review found an opt-out bypass
// in a share manager — these must not repeat it): the committed-slot registry gate, the
// `allowNearbyHearts` receive opt-out, the trusted-friend requirement, and the block list; that a
// received heart lands through the SAME shared ledger the presence path uses; and the send path's
// capability gating + 5-minute cooldown + opt-out. The full presence-radio heart coverage lives in
// PresenceHeartsTests / HeartShareTests — this file is the mesh-slot transport that item 5 added.
//
// The shared `store` (retained past the manager's `unowned` reference) persists its trust vault and
// slots across this serialized suite, so every fixture uses a UNIQUE random signing key / fingerprint
// to keep per-test trust and slot state isolated.

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
struct MeshSessionHeartTests {
    // Keeps the FernletStore alive past the manager's `unowned let store` (mirrors SessionMessageTests).
    let store = makeTestStore()

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private var heartsCap: [String] {
        [ProximityCapability.photos.rawValue, ProximityCapability.hearts.rawValue]
    }

    // MARK: - Fixtures

    private func randomKey() -> Data { Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }) }
    private func uniqueFingerprint() -> String { "fp-\(UUID().uuidString)" }

    /// A fresh, temp-file-backed ledger injected into the manager so assertions are isolated from the
    /// shared on-disk HeartLedger.json (and from the presence path's ledger).
    private func isolatedLedger() -> ProximityHeartLedger {
        ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mesh-heart-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("HeartLedger.json"),
            now: { self.day })
    }

    private func makePeerIdentity(
        name: String,
        signingPublicKey: Data,
        capabilities: [String]? = nil
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

    private func makeMultipeerPeer(name: String) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: "mc-\(UUID().uuidString.prefix(8))")
        )
    }

    private func throwawayCoordinator() -> ProximityCoordinator {
        let identity = IdentityService(keychainService: "test.mesh.hearts.\(UUID().uuidString)")
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

    private func heartEnvelope(
        id: UUID = UUID(),
        dayKey: String = "2026-07-25",
        senderName: String = "Robin"
    ) throws -> (envelope: FernletIdentityEnvelope, plaintext: Data) {
        let payload = HeartPayload(id: id, sentAtDayKey: dayKey)
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: senderName,
            recipientFingerprint: nil,
            payloadType: .friendHeart,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Good vibes"),
            payload: plaintext,
            createdAt: day,
            expiresAt: nil,
            signature: Data()
        )
        return (envelope, plaintext)
    }

    /// Registers a COMMITTED slot for a peer and drives a heart through the full production dispatch
    /// path (registry commit gate → receiver gates → shared ledger). `trust` controls whether the peer
    /// is a vault friend (the trusted-friend requirement). Each call uses a UNIQUE signing key.
    @discardableResult
    private func deliverHeart(
        via manager: MeshNetworkManager,
        id: UUID = UUID(),
        dayKey: String = "2026-07-25",
        senderName: String = "Robin",
        trust: Bool = true,
        commit: Bool = true
    ) throws -> ProximityCoordinator.PeerIdentity {
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: senderName, signingPublicKey: randomKey(), capabilities: heartsCap)
        if trust { store.proximityTrustVault.trust(identity, mode: .friend) }
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: makeMultipeerPeer(name: senderName),
            fingerprint: commit ? identity.fingerprint : nil,
            peerCapabilities: heartsCap
        )
        let (envelope, plaintext) = try heartEnvelope(id: id, dayKey: dayKey, senderName: senderName)
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: identity)
        return identity
    }

    // MARK: - Receive gates

    @Test func committedFriendHeartIsRecordedThroughTheSharedLedger() throws {
        let manager = store.meshNetworkManager
        let ledger = isolatedLedger()
        manager.heartLedger = ledger
        store.setAllowNearbyHearts(true)

        let robin = try deliverHeart(via: manager)
        #expect(ledger.receivedHearts.count == 1)
        let record = try #require(ledger.receivedHearts.first)
        #expect(record.senderFingerprint == robin.fingerprint)   // transport-verified, not a wire claim
        #expect(record.senderDisplayName == "Robin")
    }

    @Test func heartFromUncommittedSlotIsDroppedByTheRegistryGate() throws {
        let manager = store.meshNetworkManager
        let ledger = isolatedLedger()
        manager.heartLedger = ledger
        store.setAllowNearbyHearts(true)

        // commit: false models a pre-dwell candidate — feature payloads are for committed members only.
        try deliverHeart(via: manager, commit: false)
        #expect(ledger.receivedHearts.isEmpty)
    }

    @Test func heartDroppedWhenNearbyHeartsOff() throws {
        let manager = store.meshNetworkManager
        let ledger = isolatedLedger()
        manager.heartLedger = ledger
        // Receiver-side opt-out (the gate a share-manager bypass regression must never re-open).
        store.setAllowNearbyHearts(false)

        try deliverHeart(via: manager)
        #expect(ledger.receivedHearts.isEmpty, "A heart to a hearts-off device is silently dropped")
    }

    @Test func heartFromNonFriendIsDropped() throws {
        let manager = store.meshNetworkManager
        let ledger = isolatedLedger()
        manager.heartLedger = ledger
        store.setAllowNearbyHearts(true)

        // trust: false → the sender is NOT a vault friend, so the trusted-friend requirement drops it.
        try deliverHeart(via: manager, trust: false)
        #expect(ledger.receivedHearts.isEmpty)
    }

    @Test func heartFromBlockedFingerprintIsDropped() throws {
        let manager = store.meshNetworkManager
        let ledger = isolatedLedger()
        manager.heartLedger = ledger
        store.setAllowNearbyHearts(true)

        let signingKey = randomKey()
        let identity = makePeerIdentity(name: "Blocked", signingPublicKey: signingKey, capabilities: heartsCap)
        // Trust then block so the vault holds the fingerprint (mirrors .friendPhoto / .tempMessage).
        store.proximityTrustVault.trust(identity, mode: .friend)
        store.proximityTrustVault.block(signingPublicKey: signingKey)

        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: makeMultipeerPeer(name: "Blocked"),
            fingerprint: identity.fingerprint,
            peerCapabilities: heartsCap
        )
        let (envelope, plaintext) = try heartEnvelope(senderName: "Blocked")
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: identity)

        #expect(ledger.receivedHearts.isEmpty)
    }

    @Test func malformedDayKeyHeartIsDropped() throws {
        let manager = store.meshNetworkManager
        let ledger = isolatedLedger()
        manager.heartLedger = ledger
        store.setAllowNearbyHearts(true)

        // A hostile peer can't land an oversized/garbage day key past the wire shape-check.
        try deliverHeart(via: manager, dayKey: "not-a-day-key-at-all")
        #expect(ledger.receivedHearts.isEmpty)
    }

    // MARK: - Send path

    @Test func sendSessionHeartRidesTheMeshToAHeartsCapablePeer() {
        let manager = store.meshNetworkManager
        manager.heartLedger = isolatedLedger()
        store.setAllowNearbyHearts(true)

        var sentSlotIDs: [UUID] = []
        manager.onSessionHeartSendForTesting = { sentSlotIDs.append($0) }

        let fp = uniqueFingerprint()
        let peer = makeMultipeerPeer(name: "Capable")
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: peer, fingerprint: fp,
            verifiedKeyAgreementPublicKey: Data([1]), peerCapabilities: heartsCap
        )
        #expect(manager.canSendSessionHeart(toFingerprint: fp))

        manager.sendSessionHeart(to: friendRecord(fingerprint: fp, name: "Capable"))
        #expect(sentSlotIDs == [peer.id], "The heart dispatches over the committed hearts-capable slot")
        #expect(manager.sessionHeartState == .sending(recipientName: "Capable"))
    }

    @Test func sendSessionHeartSkipsAPeerWithoutTheHeartsCapability() {
        let manager = store.meshNetworkManager
        manager.heartLedger = isolatedLedger()
        store.setAllowNearbyHearts(true)

        var sends = 0
        manager.onSessionHeartSendForTesting = { _ in sends += 1 }
        // A photos-only committed peer (older build) cannot receive a mesh heart.
        let fp = uniqueFingerprint()
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: makeMultipeerPeer(name: "PhotosOnly"),
            fingerprint: fp, verifiedKeyAgreementPublicKey: Data([2]),
            peerCapabilities: [ProximityCapability.photos.rawValue]
        )
        #expect(!manager.canSendSessionHeart(toFingerprint: fp))

        manager.sendSessionHeart(to: friendRecord(fingerprint: fp, name: "PhotosOnly"))
        #expect(sends == 0, "No mesh heart is dispatched to a peer that can't handle it")
        #expect(manager.sessionHeartState.isFailed)
    }

    @Test func sendSessionHeartRespectsTheOptOut() {
        let manager = store.meshNetworkManager
        manager.heartLedger = isolatedLedger()
        store.setAllowNearbyHearts(false)

        var sends = 0
        manager.onSessionHeartSendForTesting = { _ in sends += 1 }
        let fp = uniqueFingerprint()
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: makeMultipeerPeer(name: "Capable"),
            fingerprint: fp, verifiedKeyAgreementPublicKey: Data([1]), peerCapabilities: heartsCap
        )

        manager.sendSessionHeart(to: friendRecord(fingerprint: fp, name: "Capable"))
        #expect(sends == 0, "Hearts-off blocks the send")
    }

    @Test func sendSessionHeartRespectsTheCooldown() {
        let manager = store.meshNetworkManager
        let ledger = isolatedLedger()
        manager.heartLedger = ledger
        store.setAllowNearbyHearts(true)

        let fp = uniqueFingerprint()
        // Prime the shared ledger so the friend is inside the 5-minute per-friend window.
        ledger.recordHeartSent(to: fp)

        var sends = 0
        manager.onSessionHeartSendForTesting = { _ in sends += 1 }
        manager.addSlotForTesting(
            coordinator: throwawayCoordinator(), peer: makeMultipeerPeer(name: "Capable"),
            fingerprint: fp, verifiedKeyAgreementPublicKey: Data([1]), peerCapabilities: heartsCap
        )

        manager.sendSessionHeart(to: friendRecord(fingerprint: fp, name: "Capable"))
        #expect(sends == 0, "A heart inside the 5-minute cooldown is not re-sent")
        #expect(manager.sessionHeartState.isFailed)
    }

    // MARK: - Capability advertisement

    @Test func localCapabilitiesAdvertiseHearts() {
        let manager = store.meshNetworkManager

        // Opted in → we can receive a mesh heart, so advertise `.hearts` (heart-reachable).
        store.setAllowNearbyHearts(true)
        #expect(manager.localCapabilities().contains(ProximityCapability.hearts.rawValue))

        // Opted out (the default) → the receiver silently drops every heart (`receiveSessionHeart`), so
        // we must NOT appear heart-reachable; otherwise a sender "succeeds" and burns the 5-minute
        // cooldown on a dropped heart. Only the hearts capability is gated on the opt-out — the always-on
        // capabilities (e.g. photos) are still advertised.
        store.setAllowNearbyHearts(false)
        #expect(!manager.localCapabilities().contains(ProximityCapability.hearts.rawValue))
        #expect(manager.localCapabilities().contains(ProximityCapability.photos.rawValue))
    }

    // MARK: - Helpers

    private func friendRecord(fingerprint: String, name: String) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: name,
            fingerprint: fingerprint,
            signingPublicKey: randomKey(),
            keyAgreementPublicKey: Data([1]),
            mode: .friend,
            firstAcceptedAt: day,
            lastSeenAt: day
        )
    }
}

private extension MeshNetworkManager.SessionHeartState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

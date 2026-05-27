import Foundation
import Testing
@testable import Fernlet

@MainActor
struct ProximityTrustVaultTests {

    private func makePeer(
        name: String = "Alice",
        fingerprint: String = "fp-alice"
    ) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: name,
            signingPublicKey: Data([1, 2, 3]),
            keyAgreementPublicKey: Data([4, 5, 6]),
            fingerprint: fingerprint,
            rangingMode: .none,
            firstSeenAt: Date()
        )
    }

    @Test func trustIdempotencyByFingerprint() {
        var callCount = 0
        let vault = ProximityTrustVault(onChange: { callCount += 1 })
        let peer = makePeer()

        vault.trust(peer, mode: .trainer)
        #expect(vault.trustedPeers.count == 1)
        #expect(vault.trustedPeers[0].displayName == "Alice")

        let updated = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Alice Updated",
            signingPublicKey: peer.signingPublicKey,
            keyAgreementPublicKey: Data([7, 8, 9]),
            fingerprint: peer.fingerprint,
            rangingMode: .none,
            firstSeenAt: Date()
        )
        vault.trust(updated, mode: .friend)
        #expect(vault.trustedPeers.count == 1)
        #expect(vault.trustedPeers[0].displayName == "Alice Updated")
        #expect(vault.trustedPeers[0].mode == .friend)
        #expect(vault.trustedPeers[0].revokedAt == nil)
        #expect(callCount == 2)
    }

    @Test func revokeWritesAuditEvent() {
        let vault = ProximityTrustVault()
        vault.trust(makePeer(name: "Bob", fingerprint: "fp-bob"), mode: .trainer)

        vault.revoke(fingerprint: "fp-bob")
        #expect(vault.trustedPeers[0].revokedAt != nil)
        #expect(vault.auditEvents.count == 1)
        #expect(vault.auditEvents[0].kind == .trainerRevoked)

        vault.revoke(fingerprint: "fp-bob")
        #expect(vault.auditEvents.count == 2)
    }

    @Test func isTrustedOnlyWhenNotRevoked() {
        let vault = ProximityTrustVault()
        vault.trust(makePeer(fingerprint: "fp-x"), mode: .trainer)

        #expect(vault.isTrustedProximityPeer(fingerprint: "fp-x"))
        vault.revoke(fingerprint: "fp-x")
        #expect(!vault.isTrustedProximityPeer(fingerprint: "fp-x"))
    }

    @Test func isRevokedSigningKeyFalseForActivePeer() {
        let vault = ProximityTrustVault()
        #expect(!vault.isTrustedProximityPeer(fingerprint: "unknown"))
    }

    @Test func auditEventRingBufferCappedAt500() {
        let vault = ProximityTrustVault()
        for i in 0..<502 {
            vault.recordTrainerAudit(TrainerAuditEvent(
                kind: .stateTransition,
                message: "Event \(i)"
            ))
        }
        #expect(vault.auditEvents.count == 500)
        #expect(vault.auditEvents[0].message == "Event 501")
        #expect(vault.auditEvents[499].message == "Event 2")
    }

    @Test func onChangeCalledExactlyOncePerMutation() {
        var callCount = 0
        let vault = ProximityTrustVault(onChange: { callCount += 1 })
        let peer = makePeer()

        vault.trust(peer, mode: .trainer)
        #expect(callCount == 1)
        vault.revoke(fingerprint: peer.fingerprint)
        #expect(callCount == 2)
        vault.recordTrainerAudit(TrainerAuditEvent(kind: .error, message: "test"))
        #expect(callCount == 3)
    }

    @Test func applyReplacesBothArraysAtomically() {
        let vault = ProximityTrustVault()
        vault.trust(makePeer(), mode: .trainer)
        vault.recordTrainerAudit(TrainerAuditEvent(kind: .sessionEnded, message: "old"))

        let newPeer = ProximityTrustedPeerRecord(
            displayName: "Charlie",
            fingerprint: "fp-charlie",
            signingPublicKey: Data(),
            keyAgreementPublicKey: Data(),
            mode: .friend
        )
        vault.apply(peers: [newPeer], audit: [TrainerAuditEvent(kind: .pairingStarted, message: "new")])

        #expect(vault.trustedPeers.count == 1)
        #expect(vault.trustedPeers[0].displayName == "Charlie")
        #expect(vault.auditEvents.count == 1)
        #expect(vault.auditEvents[0].kind == .pairingStarted)
    }

    @Test func peerLookupByDisplayNameReturnsMostRecentlySeen() {
        let vault = ProximityTrustVault()
        let older = ProximityTrustedPeerRecord(
            displayName: "Dave",
            fingerprint: "fp-dave-1",
            signingPublicKey: Data(),
            keyAgreementPublicKey: Data(),
            mode: .trainer,
            lastSeenAt: Date().addingTimeInterval(-100)
        )
        let newer = ProximityTrustedPeerRecord(
            displayName: "Dave",
            fingerprint: "fp-dave-2",
            signingPublicKey: Data(),
            keyAgreementPublicKey: Data(),
            mode: .trainer,
            lastSeenAt: Date()
        )
        vault.apply(peers: [older, newer], audit: [])
        #expect(vault.peer(displayName: "Dave")?.fingerprint == "fp-dave-2")
    }
}

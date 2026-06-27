import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct ProximityTrustVaultTests {

    private func makePeer(
        name: String = "Alice",
        fingerprint: String = "fp-alice",
        signingPublicKey: Data = Data([1, 2, 3])
    ) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: name,
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: Data([4, 5, 6]),
            fingerprint: fingerprint,
            rangingMode: .none,
            firstSeenAt: Date()
        )
    }

    @Test func trustIdempotencyBySigningKey() {
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

        vault.revoke(signingPublicKey: Data([1, 2, 3]))
        #expect(vault.trustedPeers[0].revokedAt != nil)
        #expect(vault.auditEvents.count == 1)
        #expect(vault.auditEvents[0].kind == .trainerRevoked)

        vault.revoke(signingPublicKey: Data([1, 2, 3]))
        #expect(vault.auditEvents.count == 2)
    }

    @Test func isTrustedOnlyWhenNotRevoked() {
        let vault = ProximityTrustVault()
        vault.trust(makePeer(fingerprint: "fp-x"), mode: .trainer)

        #expect(vault.isTrustedProximityPeer(signingPublicKey: Data([1, 2, 3])))
        vault.revoke(signingPublicKey: Data([1, 2, 3]))
        #expect(!vault.isTrustedProximityPeer(signingPublicKey: Data([1, 2, 3])))
    }

    @Test func isRevokedSigningKeyFalseForActivePeer() {
        let vault = ProximityTrustVault()
        #expect(!vault.isTrustedProximityPeer(signingPublicKey: Data([9, 9, 9])))
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
        vault.revoke(signingPublicKey: peer.signingPublicKey)
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

    @Test func friendSessionPolicyKeepsProximityGateAuthorizationPermissive() {
        let policy = FriendSessionTrustPolicy(vault: ProximityTrustVault())

        #expect(policy.isTrustedProximityPeer(signingPublicKey: Data([1, 2, 3])))
    }

    @Test func friendSessionPolicyDelegatesBlockedRevokedAndAuditChecksToVault() {
        let signingKey = Data([9, 8, 7])
        let fingerprint = IdentityService.fingerprint(of: signingKey)
        let vault = ProximityTrustVault(initialPeers: [
            ProximityTrustedPeerRecord(
                displayName: "Eve",
                fingerprint: fingerprint,
                signingPublicKey: signingKey,
                keyAgreementPublicKey: Data([6, 5, 4]),
                mode: .friend
            )
        ])
        let policy = FriendSessionTrustPolicy(vault: vault)

        vault.block(signingPublicKey: signingKey)
        #expect(policy.isBlockedProximitySigningKey(signingKey))
        #expect(policy.isRevokedProximitySigningKey(signingKey))

        policy.recordTrainerAudit(TrainerAuditEvent(kind: .error, message: "forwarded"))
        #expect(vault.auditEvents.first?.message == "forwarded")
    }

    @Test func collisionFingerprintCannotOverwriteRevokeOrBlockDifferentSigningKey() {
        let sharedFingerprint = "shared-fp"
        let firstKey = Data([1, 2, 3])
        let secondKey = Data([4, 5, 6])
        let vault = ProximityTrustVault(initialPeers: [
            ProximityTrustedPeerRecord(
                displayName: "First",
                fingerprint: sharedFingerprint,
                signingPublicKey: firstKey,
                keyAgreementPublicKey: Data([7]),
                mode: .friend
            ),
            ProximityTrustedPeerRecord(
                displayName: "Second",
                fingerprint: sharedFingerprint,
                signingPublicKey: secondKey,
                keyAgreementPublicKey: Data([8]),
                mode: .friend
            )
        ])

        vault.revoke(signingPublicKey: firstKey)
        vault.block(signingPublicKey: firstKey)

        #expect(vault.trustedPeers.count == 2)
        #expect(vault.isRevokedProximitySigningKey(firstKey))
        #expect(vault.isBlockedProximitySigningKey(firstKey))
        #expect(vault.isTrustedProximityPeer(signingPublicKey: secondKey))
        #expect(!vault.isRevokedProximitySigningKey(secondKey))
        #expect(!vault.isBlockedProximitySigningKey(secondKey))
    }

    @Test func applyNormalizesLegacyFingerprintFromSigningKey() {
        let signingKey = Data([9, 8, 7])
        let vault = ProximityTrustVault()
        vault.apply(peers: [
            ProximityTrustedPeerRecord(
                displayName: "Legacy",
                fingerprint: String(IdentityService.fingerprint(of: signingKey).prefix(8)),
                signingPublicKey: signingKey,
                keyAgreementPublicKey: Data([6, 5, 4]),
                mode: .friend
            )
        ], audit: [])

        #expect(vault.trustedPeers[0].fingerprint == IdentityService.fingerprint(of: signingKey))
        #expect(vault.trustedPeers[0].fingerprint.count == 16)
    }

    @Test func legacyPhotoFingerprintStillMatchesBlockedPeer() {
        let signingKey = Data([9, 8, 7])
        let vault = ProximityTrustVault()
        vault.block(signingPublicKey: signingKey)

        let legacyFingerprint = String(IdentityService.fingerprint(of: signingKey).prefix(8))
        #expect(vault.isBlockedFingerprint(legacyFingerprint))
    }
}

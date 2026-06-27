import Foundation

final class FriendSessionTrustPolicy: ProximityTrustPolicy {
    private let vault: ProximityTrustVault

    init(vault: ProximityTrustVault) {
        self.vault = vault
    }

    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool {
        vault.isRevokedProximitySigningKey(publicKey)
    }

    func isBlockedProximitySigningKey(_ publicKey: Data) -> Bool {
        vault.isBlockedProximitySigningKey(publicKey)
    }

    // Friend sessions authorize through the proximity gate; remembered trust is not required.
    func isTrustedProximityPeer(signingPublicKey: Data) -> Bool { true }

    func recordTrainerAudit(_ event: TrainerAuditEvent) {
        vault.recordTrainerAudit(event)
    }
}

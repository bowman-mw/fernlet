import Foundation
import Observation

@MainActor
@Observable
final class ProximityTrustVault: ProximityTrustPolicy {
    private(set) var trustedPeers: [ProximityTrustedPeerRecord] = []
    private(set) var auditEvents: [TrainerAuditEvent] = []

    // Mutable so FernletStore can wire it after all stored properties are initialized.
    @ObservationIgnored var onChange: () -> Void = {}

    init(
        initialPeers: [ProximityTrustedPeerRecord] = [],
        initialAudit: [TrainerAuditEvent] = [],
        onChange: @escaping () -> Void = {}
    ) {
        self.trustedPeers = initialPeers
        self.auditEvents = initialAudit
        self.onChange = onChange
    }

    // MARK: - Reads

    func peer(fingerprint: String) -> ProximityTrustedPeerRecord? {
        trustedPeers.first { $0.fingerprint == fingerprint }
    }

    func peer(displayName: String) -> ProximityTrustedPeerRecord? {
        trustedPeers
            .filter { $0.displayName == displayName }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first
    }

    func isTrustedProximityPeer(fingerprint: String) -> Bool {
        trustedPeers.contains { $0.fingerprint == fingerprint && $0.revokedAt == nil }
    }

    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool {
        let fp = IdentityService.fingerprint(of: publicKey)
        return trustedPeers.contains { $0.fingerprint == fp && $0.revokedAt != nil }
    }

    // MARK: - Writes

    func trust(_ peer: ProximityCoordinator.PeerIdentity, mode: ProximityCoordinator.Mode) {
        if let index = trustedPeers.firstIndex(where: { $0.fingerprint == peer.fingerprint }) {
            trustedPeers[index].displayName = peer.displayName
            trustedPeers[index].keyAgreementPublicKey = peer.keyAgreementPublicKey
            trustedPeers[index].mode = mode
            trustedPeers[index].lastSeenAt = Date()
            trustedPeers[index].revokedAt = nil
        } else {
            trustedPeers.append(ProximityTrustedPeerRecord(
                displayName: peer.displayName,
                fingerprint: peer.fingerprint,
                signingPublicKey: peer.signingPublicKey,
                keyAgreementPublicKey: peer.keyAgreementPublicKey,
                mode: mode
            ))
        }
        onChange()
    }

    func revoke(fingerprint: String) {
        guard let index = trustedPeers.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        trustedPeers[index].revokedAt = Date()
        recordAuditWithoutSaving(TrainerAuditEvent(
            kind: .trainerRevoked,
            peerFingerprint: trustedPeers[index].fingerprint,
            peerDisplayName: trustedPeers[index].displayName,
            message: "Revoked \(trustedPeers[index].displayName)"
        ))
        onChange()
    }

    func recordTrainerAudit(_ event: TrainerAuditEvent) {
        recordAuditWithoutSaving(event)
        onChange()
    }

    // MARK: - Snapshot

    func apply(peers: [ProximityTrustedPeerRecord], audit: [TrainerAuditEvent]) {
        trustedPeers = peers
        auditEvents = audit
    }

    private func recordAuditWithoutSaving(_ event: TrainerAuditEvent) {
        auditEvents.insert(event, at: 0)
        auditEvents = Array(auditEvents.prefix(500))
    }
}

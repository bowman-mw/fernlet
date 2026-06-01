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

    func isTrustedProximityPeer(signingPublicKey: Data) -> Bool {
        let fp = IdentityService.fingerprint(of: signingPublicKey)
        return trustedPeers.contains {
            $0.fingerprint == fp && $0.signingPublicKey == signingPublicKey && $0.revokedAt == nil
        }
    }

    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool {
        // Phase 4 (SEC-1): require full public-key match, not just the 8-char fingerprint prefix,
        // so a collision-crafted key cannot inherit a revoked peer's status.
        let fp = IdentityService.fingerprint(of: publicKey)
        return trustedPeers.contains { $0.fingerprint == fp && $0.signingPublicKey == publicKey && $0.revokedAt != nil }
    }

    func isBlockedProximitySigningKey(_ publicKey: Data) -> Bool {
        // Phase 4 (SEC-1): same full-key check for the block list.
        let fp = IdentityService.fingerprint(of: publicKey)
        return trustedPeers.contains { $0.fingerprint == fp && $0.signingPublicKey == publicKey && $0.blockedAt != nil }
    }

    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        trustedPeers.contains { $0.fingerprint == fingerprint && $0.blockedAt != nil }
    }

    // MARK: - Writes

    func trust(_ peer: ProximityCoordinator.PeerIdentity, mode: ProximityCoordinator.Mode) {
        if let index = trustedPeers.firstIndex(where: { $0.fingerprint == peer.fingerprint }) {
            trustedPeers[index].displayName = peer.displayName
            trustedPeers[index].signingPublicKey = peer.signingPublicKey
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

    func block(fingerprint: String) {
        let now = Date()
        guard let index = trustedPeers.firstIndex(where: { $0.fingerprint == fingerprint }) else {
            trustedPeers.append(ProximityTrustedPeerRecord(
                displayName: fingerprint,
                fingerprint: fingerprint,
                signingPublicKey: Data(),
                keyAgreementPublicKey: Data(),
                mode: .friend,
                firstAcceptedAt: now,
                lastSeenAt: now,
                revokedAt: now,
                blockedAt: now
            ))
            onChange()
            return
        }
        trustedPeers[index].blockedAt = now
        trustedPeers[index].revokedAt = now
        recordAuditWithoutSaving(TrainerAuditEvent(
            kind: .revokedPeerBlocked,
            peerFingerprint: trustedPeers[index].fingerprint,
            peerDisplayName: trustedPeers[index].displayName,
            message: "Blocked \(trustedPeers[index].displayName)"
        ))
        onChange()
    }

    func unblock(fingerprint: String) {
        guard let index = trustedPeers.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        trustedPeers[index].blockedAt = nil
        trustedPeers[index].revokedAt = nil
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

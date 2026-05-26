import Foundation
import Observation

@MainActor
@Observable
final class TrainerProximityService {
    private let store: FernletStore
    private weak var coordinator: ProximityCoordinator?

    init(store: FernletStore, coordinator: ProximityCoordinator? = nil) {
        self.store = store
        self.coordinator = coordinator
    }

    func attachCoordinator(_ coordinator: ProximityCoordinator) {
        self.coordinator = coordinator
    }

    func disclosure(for peer: ProximityCoordinator.PeerIdentity) -> TrainerDisclosureCardModel {
        store.recordTrainerAudit(TrainerAuditEvent(
            kind: .disclosureShown,
            peerFingerprint: peer.fingerprint,
            peerDisplayName: peer.displayName,
            message: "Disclosure shown for \(peer.displayName)"
        ))
        return TrainerDisclosureCardModel.make(for: peer)
    }

    func shouldShowPreInviteDialog(displayName: String, fingerprint: String) -> Bool {
        guard let peer = store.trustedProximityPeer(fingerprint: fingerprint) else {
            return true  // unknown peer — always show pre-invite dialog (§11.1)
        }
        return peer.revokedAt != nil  // revoked peer — treat as new
    }

    func keyChangeWarning(displayName: String, fingerprint: String) -> String? {
        guard let previous = store.trustedProximityPeer(displayName: displayName),
              previous.fingerprint != fingerprint,
              previous.revokedAt == nil else {
            return nil
        }
        return "\(displayName) is using a different proximity key. Verify the fingerprint before accepting."
    }

    func accept(_ peer: ProximityCoordinator.PeerIdentity, mode: ProximityCoordinator.Mode = .trainer) async {
        store.trustProximityPeer(peer, mode: mode)
        store.recordTrainerAudit(TrainerAuditEvent(
            kind: .peerAccepted,
            peerFingerprint: peer.fingerprint,
            peerDisplayName: peer.displayName,
            message: "Accepted \(peer.displayName)"
        ))
        await coordinator?.confirmPeerIdentity()
    }

    func reject(_ peer: ProximityCoordinator.PeerIdentity) async {
        store.recordTrainerAudit(TrainerAuditEvent(
            kind: .peerRejected,
            peerFingerprint: peer.fingerprint,
            peerDisplayName: peer.displayName,
            message: "Rejected \(peer.displayName)"
        ))
        await coordinator?.rejectPendingInvite()
    }

    func revokeTrainer(fingerprint: String) {
        store.revokeTrustedProximityPeer(fingerprint: fingerprint)
    }
}

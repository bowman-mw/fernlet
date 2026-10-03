// TrainerAuditEvent+SessionAudit.swift
// FernletConnections
//
// Fernlet's one conversion from what ProximityKit's session coordinator reports to what Fernlet
// persists. The coordinator records each audit event through its trust policy in ProximityKit's own
// `ProximitySessionAudit`; Fernlet keeps its audit trail as FernletDomainModel's `TrainerAuditEvent`,
// in the trust vault and the synced snapshot (`FernletSnapshot.trainerAuditEvents`). Every
// `ProximityTrustPolicy` Fernlet answers with converts here and nowhere else:
// `FriendSessionTrustPolicy`, `CoachSessionTrustPolicy` and the app's `FernletStore`.
// `ProximityVocabularyGoldenTests` holds a converted audit to the frozen row's JSON, byte for byte,
// and each of the eight kinds to the token its row persists under.

import FernletDomainModel
import Foundation
import ProximityKit

nonisolated extension TrainerAuditEvent {

    /// The row Fernlet persists for one audit event a coordinator reported: `id`, `timestamp`, the
    /// two peer fields and the message copied unchanged, the kind mapped case for case, and the
    /// envelope's token read as a `PayloadType`.
    ///
    /// A token this build does not know becomes no payload type, and nothing is parked
    /// (`unknownPayloadTypeToken` stays `nil`): the row records what the envelope's typed view,
    /// `FernletIdentityEnvelope.payloadType`, reads for it, and its message still names the token.
    ///
    /// `nonisolated` against this module's `defaultIsolation(MainActor.self)`, like the value types
    /// on both sides of it.
    ///
    /// - Parameter audit: What the coordinator reported.
    public nonisolated init(_ audit: ProximitySessionAudit) {
        self.init(
            id: audit.id,
            timestamp: audit.timestamp,
            kind: Kind(audit.kind),
            peerFingerprint: audit.peerFingerprint,
            peerDisplayName: audit.peerDisplayName,
            payloadType: audit.payloadType.flatMap(PayloadType.init(rawValue:)),
            message: audit.message
        )
    }
}

nonisolated extension TrainerAuditEvent.Kind {

    /// ProximityKit's audit kind onto the persisted kind of the same name, case for case. An
    /// exhaustive switch, so a kind ProximityKit adds fails to compile here instead of being
    /// persisted as something else.
    fileprivate nonisolated init(_ kind: ProximitySessionAudit.Kind) {
        switch kind {
        case .pairingStarted: self = .pairingStarted
        case .stateTransition: self = .stateTransition
        case .envelopeReceived: self = .envelopeReceived
        case .envelopeSent: self = .envelopeSent
        case .envelopeRejected: self = .envelopeRejected
        case .revokedPeerBlocked: self = .revokedPeerBlocked
        case .sessionEnded: self = .sessionEnded
        case .error: self = .error
        }
    }
}

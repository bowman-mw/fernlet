import Foundation

struct ProximityTrustedPeerRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var displayName: String
    var fingerprint: String
    var signingPublicKey: Data
    var keyAgreementPublicKey: Data
    var mode: ProximityCoordinator.Mode
    var firstAcceptedAt: Date
    var lastSeenAt: Date
    var revokedAt: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        fingerprint: String,
        signingPublicKey: Data,
        keyAgreementPublicKey: Data,
        mode: ProximityCoordinator.Mode,
        firstAcceptedAt: Date = Date(),
        lastSeenAt: Date = Date(),
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.signingPublicKey = signingPublicKey
        self.keyAgreementPublicKey = keyAgreementPublicKey
        self.mode = mode
        self.firstAcceptedAt = firstAcceptedAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }
}

struct TrainerAuditEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case pairingStarted
        case stateTransition
        case peerDiscovered
        case disclosureShown
        case peerAccepted
        case peerRejected
        case envelopeReceived
        case envelopeSent
        case envelopeRejected
        case revokedPeerBlocked
        case trainerRevoked
        case sessionEnded
        case error
    }

    var id: UUID
    var timestamp: Date
    var kind: Kind
    var peerFingerprint: String?
    var peerDisplayName: String?
    var payloadType: PayloadType?
    var message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        peerFingerprint: String? = nil,
        peerDisplayName: String? = nil,
        payloadType: PayloadType? = nil,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.peerFingerprint = peerFingerprint
        self.peerDisplayName = peerDisplayName
        self.payloadType = payloadType
        self.message = message
    }
}

struct TrainerDisclosureCardModel: Equatable {
    let title: String
    let fingerprint: String
    let canSend: [String]
    let cannotAccess: [String]

    static func make(for peer: ProximityCoordinator.PeerIdentity) -> TrainerDisclosureCardModel {
        TrainerDisclosureCardModel(
            title: "Accept plan from \(peer.displayName)?",
            fingerprint: peer.fingerprint,
            canSend: [
                "Planned workouts",
                "Completed workout summaries",
                "Plan swaps"
            ],
            cannotAccess: [
                "Journal",
                "Period history",
                "Sleep",
                "Private notes",
                "Data before today"
            ]
        )
    }
}

@MainActor
protocol ProximityTrustPolicy: AnyObject {
    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool
    func isTrustedProximityPeer(fingerprint: String) -> Bool
    func recordTrainerAudit(_ event: TrainerAuditEvent)
}

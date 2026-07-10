// ProximityPersistenceRecords.swift
// SPM carve-up: the two pure Codable trust/audit DTOs carved DOWN out of the app-layer
// Proximity/Trust/TrainerAuditLog.swift so the persistence layer can reference them without an
// upward edge. The audit-log LOGIC stays in TrainerAuditLog.swift. ProximityTrustedPeerRecord's
// `mode` field uses the canonical DomainModel enum ProximityMode (the app-side
// ProximityCoordinator.Mode is a typealias to it). Codable identity is unchanged.

import Foundation

public nonisolated struct ProximityTrustedPeerRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var fingerprint: String
    public var signingPublicKey: Data
    public var keyAgreementPublicKey: Data
    /// This is the PERSISTED trust vault copy in the synced blob, not the wire envelope. `mode`
    /// decodes tolerantly (EnumDecodeCompat): a peer-relationship mode minted by a NEWER build
    /// would otherwise throw and brick the older device — losing the whole trust vault, which is
    /// security-relevant state. The unknown mode freezes to `.trainer` (the narrower-scope
    /// relationship — no photo wall / hearts / shop) and the true token is parked so the newer
    /// device's mode is preserved through this device's re-saves and re-adopted after an upgrade.
    /// An explicit local re-trust in a known mode clears the park (`didSet`).
    public var mode: ProximityMode {
        didSet { unknownModeToken = nil }
    }
    public var unknownModeToken: String? = nil
    public var firstAcceptedAt: Date
    public var lastSeenAt: Date
    public var revokedAt: Date?
    public var blockedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        fingerprint: String,
        signingPublicKey: Data,
        keyAgreementPublicKey: Data,
        mode: ProximityMode,
        firstAcceptedAt: Date = Date(),
        lastSeenAt: Date = Date(),
        revokedAt: Date? = nil,
        blockedAt: Date? = nil
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
        self.blockedAt = blockedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Identity material stays strict — a record missing keys/fingerprint is corrupt, not a
        // forward-compat case. Only the extensible enum decodes tolerantly.
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        signingPublicKey = try c.decode(Data.self, forKey: .signingPublicKey)
        keyAgreementPublicKey = try c.decode(Data.self, forKey: .keyAgreementPublicKey)
        let modeSplit = try c.decodeTolerantEnum(
            ProximityMode.self, forKey: .mode, parkedTokenKey: .unknownModeToken, default: .trainer)
        mode = modeSplit.value
        unknownModeToken = modeSplit.parkedToken
        firstAcceptedAt = try c.decode(Date.self, forKey: .firstAcceptedAt)
        lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
        revokedAt = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
        blockedAt = try c.decodeIfPresent(Date.self, forKey: .blockedAt)
    }
}

public nonisolated struct TrainerAuditEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
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

    public var id: UUID
    public var timestamp: Date
    // Persisted-in-blob audit record (`FernletSnapshot.trainerAuditEvents`), not the wire payload.
    // `kind` and `payloadType` decode tolerantly (EnumDecodeCompat): PayloadType grows with every
    // new in-person share feature, and an audit row stamped with a newer kind/payload type would
    // otherwise brick the older paired device. Unknown kind freezes to `.stateTransition` (the
    // message still describes the event); unknown payloadType resolves to nil. Both park.
    public var kind: Kind
    public var unknownKindToken: String? = nil
    public var peerFingerprint: String?
    public var peerDisplayName: String?
    public var payloadType: PayloadType?
    public var unknownPayloadTypeToken: String? = nil
    public var message: String

    public init(
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        let kindSplit = try c.decodeTolerantEnum(
            Kind.self, forKey: .kind, parkedTokenKey: .unknownKindToken, default: .stateTransition)
        kind = kindSplit.value
        unknownKindToken = kindSplit.parkedToken
        peerFingerprint = try c.decodeIfPresent(String.self, forKey: .peerFingerprint)
        peerDisplayName = try c.decodeIfPresent(String.self, forKey: .peerDisplayName)
        let payloadSplit = try c.decodeTolerantOptionalEnum(
            PayloadType.self, forKey: .payloadType, parkedTokenKey: .unknownPayloadTypeToken)
        payloadType = payloadSplit.value
        unknownPayloadTypeToken = payloadSplit.parkedToken
        message = try c.decode(String.self, forKey: .message)
    }
}

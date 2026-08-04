// ProximityPersistenceRecords.swift
// SPM carve-up: the two pure Codable trust/audit DTOs carved DOWN out of the app-layer
// Proximity/Trust/TrainerAuditLog.swift so the persistence layer can reference them without an
// upward edge. The audit-log LOGIC stays in TrainerAuditLog.swift. ProximityTrustedPeerRecord's
// `mode` field uses the canonical DomainModel enum ProximityMode (the app-side
// ProximityCoordinator.Mode is a typealias to it). Codable identity is unchanged.

import Foundation

/// The trust vault's persisted record of one accepted peer: identity keys, mode, and lifecycle
/// timestamps.
///
/// Security-relevant synced state: identity material (keys/fingerprint) decodes STRICTLY — absence
/// is corruption, never forward compat — while `mode` decodes tolerantly so a relationship mode
/// minted by a newer build can't destroy the whole vault on an older device (see the field note on
/// why the `.trainer` freeze default is privilege-neutral today). `blockedAt`/`reportedAt`
/// deliberately sync: they record the user's OWN moderation actions, which must apply on every one
/// of the user's devices.
public nonisolated struct ProximityTrustedPeerRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var fingerprint: String
    public var signingPublicKey: Data
    public var keyAgreementPublicKey: Data
    /// This is the PERSISTED trust vault copy in the synced blob, not the wire envelope. `mode`
    /// decodes tolerantly (EnumDecodeCompat): a peer-relationship mode minted by a NEWER build
    /// would otherwise throw and brick the older device — losing the whole trust vault, which is
    /// security-relevant state.
    ///
    /// The stored mode is informational/display-facing TODAY: no production code gates a privilege
    /// on it. The hearts gate is mode-blind (`ProximityTrustVault.isTrustedProximityPeer` checks
    /// the signing key), session flows hard-code their own mode, and the only read of the stored
    /// field is a live-session capability string. The `.trainer` freeze default is therefore
    /// privilege-NEUTRAL — it is NOT a safety downgrade, and any FUTURE code that starts deriving
    /// privileges from the stored mode must NOT assume an unknown mode froze to something safe;
    /// re-audit this default first.
    ///
    /// The true token is parked so the newer device's mode is preserved through this device's
    /// re-saves and re-adopted after an upgrade. An explicit local re-trust in a known mode clears
    /// the park (`didSet`).
    public var mode: ProximityMode {
        didSet { unknownModeToken = nil }
    }
    public var unknownModeToken: String? = nil
    public var firstAcceptedAt: Date
    public var lastSeenAt: Date
    public var revokedAt: Date?
    public var blockedAt: Date?
    /// When the local user reported this peer, and why. Deliberately SYNCED alongside `blockedAt`/
    /// `revokedAt` (this record rides the CloudKit blob) — a considered choice, not the same stance as
    /// `ModerationLedger`. The ledger keeps report data device-local because it holds OTHER peers' relayed
    /// reports about third parties (sensitive social evidence that must not follow the user into iCloud).
    /// These two fields are the user's OWN moderation action about a peer they chose to block: the block
    /// itself must apply on every one of the user's devices, so its timestamp and reason travel with it.
    /// `reportReason` is a bounded `ReportReason` token (never free text), kept forward-tolerant. If any
    /// future code makes this record carry richer or free-text report detail, revisit whether it should
    /// still sync.
    public var reportedAt: Date?
    /// Raw `ReportReason` token for the report, kept forward-tolerant. Nil when not reported. See `reportedAt`.
    public var reportReason: String?

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
        blockedAt: Date? = nil,
        reportedAt: Date? = nil,
        reportReason: String? = nil
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
        self.reportedAt = reportedAt
        self.reportReason = reportReason
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
        // Required key (synthesized-strict pre-compat): absence is corruption, not a newer build.
        let modeSplit = try c.decodeTolerantRequiredEnum(
            ProximityMode.self, forKey: .mode, parkedTokenKey: .unknownModeToken, default: .trainer)
        mode = modeSplit.value
        unknownModeToken = modeSplit.parkedToken
        firstAcceptedAt = try c.decode(Date.self, forKey: .firstAcceptedAt)
        lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
        revokedAt = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
        blockedAt = try c.decodeIfPresent(Date.self, forKey: .blockedAt)
        reportedAt = try c.decodeIfPresent(Date.self, forKey: .reportedAt)
        reportReason = try c.decodeIfPresent(String.self, forKey: .reportReason)
    }
}

/// One persisted trainer-pairing audit row (`FernletSnapshot.trainerAuditEvents`).
///
/// `kind` and `payloadType` decode tolerantly with parked tokens — ``PayloadType`` grows with every
/// in-person share feature, and an audit row stamped by a newer build must not brick the older
/// paired device. The audit-log LOGIC stays app-side in TrainerAuditLog.swift; this is the pure
/// DTO the persistence layer holds.
public nonisolated struct TrainerAuditEvent: Codable, Equatable, Identifiable, Sendable {
    /// The taxonomy of auditable trainer-pairing events, from pairing start to revocation.
    ///
    /// Unknown kinds from newer builds freeze to `.stateTransition` on decode with the token
    /// parked; `message` still describes the event.
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
        case peerReported
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
        // Required key (synthesized-strict pre-compat): absence is corruption, not a newer build.
        let kindSplit = try c.decodeTolerantRequiredEnum(
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

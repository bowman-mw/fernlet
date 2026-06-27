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
    public var mode: ProximityMode
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
    public var kind: Kind
    public var peerFingerprint: String?
    public var peerDisplayName: String?
    public var payloadType: PayloadType?
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
}

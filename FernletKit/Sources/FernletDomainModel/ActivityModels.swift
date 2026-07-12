// ActivityModels.swift
// FernletDomainModel
//
// Group Activities (Phase 6 / B5): a proximity-only, small-group feature. An Activity is a
// HOST-SIGNED, VERSIONED ROSTER; membership is a host-signed, invitee-key-bound `ActivityJoinToken`
// minted only after the existing UWB dwell-commit (the dwell IS the join ritual). Roster consistency =
// host-authoritative versioned snapshot, gossiped opportunistically, honest about staleness (highest
// verified version wins; anyone may relay a self-authenticating snapshot; tokens are host-signed
// grow-only deltas).  Design source: 2026-07-11 group-activities memo.
//
// These are PURE value types (`nonisolated Codable Sendable`) — no manager, wire, or crypto logic.
// The signing / verification (`signed` / `verify` + `canonicalBytes` overloads) lives in ProximityKit
// (`Wire/ActivityPayloads.swift` + `CanonicalSignatureSerializer.swift`), because it needs the
// `@MainActor IdentityService` and CryptoKit — neither of which DomainModel may name. Keeping the data
// here lets the app + tests reach the types without an upward edge, and lets the wire payloads wrap them.
//
// KEY PRIVACY / SECURITY INVARIANTS (enforced by the ProximityKit `verify` + the manager):
//  * `schemaVersion` is SIGNED on both the token and the snapshot from day one, so a SINGLE canonical
//    encoder can be gated on it — avoiding the permanent dual-verify trap `MeshAdmissionToken` is stuck
//    with (it has no version field, so it must accept both v2 + legacy bytes forever).
//  * `hostSigningPublicKey` is the trust root, PINNED at join from the descriptor. Every later token /
//    snapshot for the activity is verified under that pinned key, so a different host cannot inject one.
//  * `coarseLocation` is optional host-typed TEXT at city granularity — never a `CLLocation`.
//  * `expiresAt` is REQUIRED and clamped to <= 7 days; expired descriptors/tokens/snapshots are GC'd.

import Foundation

/// Small-group activity bounds. Held here (DomainModel) so the manager, wire, and tests share them.
public nonisolated enum ActivityLimits {
    /// Roster cap INCLUDING the host. A group activity is intentionally small (v1 defers larger groups
    /// + cascading trust). Verified on every received snapshot.
    public static let maxParticipants = 12
    /// How many activities one device may host at once.
    public static let maxHosted = 3
    /// How many activities one device may be a member of at once.
    public static let maxJoined = 10
    /// How many distinct activity offers a host advertises per committed slot (anti-amplification).
    public static let maxOffersPerCommit = 3
    /// Hard ceiling on an activity's lifetime; a descriptor with a later `expiresAt` is clamped to this.
    public static let maxLifetime: TimeInterval = 7 * 24 * 60 * 60
}

// MARK: - Descriptor

/// The immutable parameters of an activity, authored by the host. Not signed on its own: its
/// authenticity flows from (a) arriving sealed from the transport-verified host whose
/// `verifiedSigningPublicKey == hostSigningPublicKey`, and (b) every signed token/snapshot binding the
/// `activityParamsHash` (SHA-256 of the canonical descriptor, computed in ProximityKit). The joiner
/// PINS this descriptor at join and rejects any later token whose `activityParamsHash` disagrees.
public nonisolated struct ActivityDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { activityID }

    public let activityID: UUID
    public let hostFingerprint: String
    /// Trust root — the host's full Ed25519 public key, pinned at join. Every token/snapshot verifies
    /// under this key.
    public let hostSigningPublicKey: Data
    /// Sanitized via `ItemNameModeration.sanitizedName` before construction AND re-sanitized on render.
    public let title: String
    /// A RAW, forward-tolerant string tag ("walk", "coffee", …). Never switched on for security; an
    /// unknown token just renders generically, so newer builds can add types without bricking older ones.
    public let activityTypeToken: String
    /// Optional host-typed coarse location text (city granularity). NEVER a `CLLocation`.
    public let coarseLocation: String?
    public let createdAt: Date
    /// REQUIRED; clamped to <= `ActivityLimits.maxLifetime` from `createdAt`.
    public let expiresAt: Date

    public init(
        activityID: UUID,
        hostFingerprint: String,
        hostSigningPublicKey: Data,
        title: String,
        activityTypeToken: String,
        coarseLocation: String?,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.activityID = activityID
        self.hostFingerprint = hostFingerprint
        self.hostSigningPublicKey = hostSigningPublicKey
        self.title = title
        self.activityTypeToken = activityTypeToken
        self.coarseLocation = coarseLocation
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// The wire/display-safe title (control/zero-width/bidi scalars dropped, whitespace collapsed,
    /// capped at `ItemNameModeration.maxNameLength`). Cheap defense-in-depth for rendering a
    /// possibly-hostile received descriptor.
    public var sanitizedTitle: String { ItemNameModeration.sanitizedName(title) }

    /// `expiresAt` clamped into the (createdAt, createdAt + maxLifetime] window. Callers building a
    /// descriptor should pass this as the `expiresAt` so the ceiling holds even on a hostile receipt.
    public static func clampedExpiry(createdAt: Date, requested: Date) -> Date {
        let ceiling = createdAt.addingTimeInterval(ActivityLimits.maxLifetime)
        if requested <= createdAt { return ceiling }
        return min(requested, ceiling)
    }

    /// True once `now` is at/after expiry — GC'd and no longer joinable.
    public func isExpired(at now: Date) -> Bool { now >= expiresAt }
}

// MARK: - Participant

/// One member of an activity's roster. Mirrors `MeshMember`. Identity-bearing so a joiner can render
/// the roster and (future) reach members. Display names are UNTRUSTED wire data — sanitize on receipt.
public nonisolated struct ActivityParticipant: Codable, Equatable, Identifiable, Sendable {
    public var id: String { fingerprint }

    public let fingerprint: String
    public var displayName: String
    public let signingPublicKey: Data
    public let keyAgreementPublicKey: Data
    public let joinedAt: Date

    public init(
        fingerprint: String,
        displayName: String,
        signingPublicKey: Data,
        keyAgreementPublicKey: Data,
        joinedAt: Date
    ) {
        self.fingerprint = fingerprint
        self.displayName = displayName
        self.signingPublicKey = signingPublicKey
        self.keyAgreementPublicKey = keyAgreementPublicKey
        self.joinedAt = joinedAt
    }
}

// MARK: - Roster snapshot

/// A host-authoritative, host-signed roster at a point in time. `version` is host-monotone; a receiver
/// keeps the highest verified version it has seen (`max`). `schemaVersion` is SIGNED (day one) so the
/// signature verifies with a single canonical encoder. The `hostSignature` covers every other field
/// (see `canonicalBytes(for: ActivityRosterSnapshot)` in ProximityKit).
public nonisolated struct ActivityRosterSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let supportedSchemaVersions: Set<Int> = [1]

    public let schemaVersion: Int
    public let activityID: UUID
    /// Host-monotone; receivers keep `max`.
    public let version: Int
    /// The roster, host included. `<= ActivityLimits.maxParticipants` (verified on receipt).
    public let participants: [ActivityParticipant]
    public let issuedAt: Date
    public let hostSigningPublicKey: Data
    public var hostSignature: Data

    public init(
        schemaVersion: Int = ActivityRosterSnapshot.currentSchemaVersion,
        activityID: UUID,
        version: Int,
        participants: [ActivityParticipant],
        issuedAt: Date,
        hostSigningPublicKey: Data,
        hostSignature: Data
    ) {
        self.schemaVersion = schemaVersion
        self.activityID = activityID
        self.version = version
        self.participants = participants
        self.issuedAt = issuedAt
        self.hostSigningPublicKey = hostSigningPublicKey
        self.hostSignature = hostSignature
    }
}

// MARK: - Join token

/// A host-signed, invitee-key-bound membership credential minted only after the UWB dwell-commit and an
/// explicit host confirm. Binds the JOINER'S signing key (`joinerSigningPublicKey`) so a
/// fingerprint-collision attacker can't reuse it; binds the `activityID` + `activityParamsHash` so a
/// token issued for one activity can't be replayed inside a grant claiming another (the grant's outer id
/// is unsigned — the `handleAdmissionGrant` lesson). `schemaVersion` is SIGNED (single-encoder verify).
public nonisolated struct ActivityJoinToken: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let supportedSchemaVersions: Set<Int> = [1]

    public let schemaVersion: Int
    public let activityID: UUID
    /// SHA-256 of the canonical descriptor (computed in ProximityKit). Binds the exact params the joiner
    /// pinned; a host cannot swap params after the fact without invalidating the token.
    public let activityParamsHash: Data
    public let joinerFingerprint: String
    /// The joiner's full Ed25519 public key, bound into the host's signature.
    public let joinerSigningPublicKey: Data
    public let hostFingerprint: String
    public let hostSigningPublicKey: Data
    public let grantedAt: Date
    /// == the descriptor's `expiresAt`.
    public let expiresAt: Date
    /// The roster version at the moment of grant (for display / ordering; not a trust input).
    public let rosterVersionAtGrant: Int
    public var hostSignature: Data

    public init(
        schemaVersion: Int = ActivityJoinToken.currentSchemaVersion,
        activityID: UUID,
        activityParamsHash: Data,
        joinerFingerprint: String,
        joinerSigningPublicKey: Data,
        hostFingerprint: String,
        hostSigningPublicKey: Data,
        grantedAt: Date,
        expiresAt: Date,
        rosterVersionAtGrant: Int,
        hostSignature: Data
    ) {
        self.schemaVersion = schemaVersion
        self.activityID = activityID
        self.activityParamsHash = activityParamsHash
        self.joinerFingerprint = joinerFingerprint
        self.joinerSigningPublicKey = joinerSigningPublicKey
        self.hostFingerprint = hostFingerprint
        self.hostSigningPublicKey = hostSigningPublicKey
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.rosterVersionAtGrant = rosterVersionAtGrant
        self.hostSignature = hostSignature
    }
}

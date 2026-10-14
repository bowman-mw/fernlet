// ProximityIdentityEnvelope+PayloadType.swift
// FernletConnections
//
// Fernlet's typed view of the signed envelope's raw payload token, in Fernlet's vocabulary module.
// ProximityKit's `ProximityIdentityEnvelope` carries the token as a string (`payloadTypeToken`, the
// `payloadType` key on the wire): `verify` parks by the verifying namespace's `payloads.known`, and the
// engine reads and signs the raw token. Fernlet's features read and sign through this view, which spells
// the same token as FernletDomainModel's `PayloadType` case, so every byte an envelope minted through it
// carries is the raw form's for that case's raw value. ProximityKit names no `PayloadType`
// (`ProximityNamespaceBoundaryTests` rule 4), and `ProximityVocabularyGoldenTests` group 2 signs an
// envelope for every one of Fernlet's tokens through the typed factory and holds each to the sealing
// rule.

import FernletDomainModel
import Foundation
import ProximityKit

// `nonisolated` against this module's `defaultIsolation(MainActor.self)`: the envelope is a
// `nonisolated`, `Sendable` wire value, so its typed reads and typed initializer are reachable from any
// isolation, as its raw ones are (a nonisolated test suite builds typed envelopes synchronously). Only
// `signed` touches the `@MainActor` IdentityService, and it says so.
nonisolated extension ProximityIdentityEnvelope {

    /// Fernlet's typed view of `payloadTypeToken`: the `PayloadType` case it spells, or `nil` when
    /// Fernlet has no case for it. Feature code and tests read it, and Fernlet's feature dispatch
    /// gates on it being non-nil. `verify` itself parks by the verifying identity's namespace
    /// (`payloads.known`), which for Fernlet holds exactly these cases' tokens, so the two agree there.
    public var payloadType: PayloadType? { PayloadType(rawValue: payloadTypeToken) }

    /// Fernlet's typed view of a parked envelope: true when the sender used a token Fernlet has no
    /// `PayloadType` case for. Under Fernlet's namespace such an envelope still verifies
    /// (schema/expiry/signature/recipient/replay) but its payload is never decrypted or dispatched —
    /// fail-closed by non-dispatch.
    public var isUnknownPayloadType: Bool { payloadType == nil }

    /// An envelope for one of Fernlet's payload types, field by field: exactly the raw-token
    /// initializer's envelope for `payloadType`'s raw value, so its wire JSON and canonical bytes are
    /// the raw form's. For fixtures and re-signing; a sender mints through the typed `signed` below.
    ///
    /// - Parameters:
    ///   - schemaVersion: The canonical form's version (`currentSchemaVersion` or `legacySchemaVersion`).
    ///   - envelopeID: The envelope's id, for replay protection and the inspector's correlation.
    ///   - senderSigningPublicKey: The sender's Ed25519 public key, raw.
    ///   - senderKeyAgreementPublicKey: The sender's X25519 public key, raw.
    ///   - senderDisplayName: The sender's disclosed name; empty when it withholds one.
    ///   - recipientFingerprint: The recipient's fingerprint, or `nil` for a broadcast.
    ///   - payloadType: The Fernlet payload type whose raw value is the envelope's token.
    ///   - payloadEncryption: Whether, and to whom, the payload is sealed.
    ///   - payloadSummary: The sender-authored disclosure summary: frozen literals, never localized.
    ///   - payload: The payload's bytes, sealed or plain as `payloadEncryption` says.
    ///   - createdAt: When the envelope was minted.
    ///   - expiresAt: When it stops verifying, or `nil` for never.
    ///   - signature: The Ed25519 signature over the canonical bytes; empty before signing.
    public init(
        schemaVersion: Int,
        envelopeID: UUID,
        senderSigningPublicKey: Data,
        senderKeyAgreementPublicKey: Data,
        senderDisplayName: String,
        recipientFingerprint: String?,
        payloadType: PayloadType,
        payloadEncryption: PayloadEncryption,
        payloadSummary: PayloadSummary,
        payload: Data,
        createdAt: Date,
        expiresAt: Date?,
        signature: Data
    ) {
        self.init(
            schemaVersion: schemaVersion,
            envelopeID: envelopeID,
            senderSigningPublicKey: senderSigningPublicKey,
            senderKeyAgreementPublicKey: senderKeyAgreementPublicKey,
            senderDisplayName: senderDisplayName,
            recipientFingerprint: recipientFingerprint,
            payloadTypeToken: payloadType.rawValue,
            payloadEncryption: payloadEncryption,
            payloadSummary: payloadSummary,
            payload: payload,
            createdAt: createdAt,
            expiresAt: expiresAt,
            signature: signature
        )
    }

    /// Creates a signed envelope for one of Fernlet's payload types: exactly the envelope ProximityKit's
    /// raw factory, `signed(identityService:envelopeID:senderDisplayName:recipientFingerprint:payloadTypeToken:...)`,
    /// signs for the type's raw value. `@MainActor`: signs with the `@MainActor` IdentityService
    /// private key state.
    ///
    /// - Parameters:
    ///   - identityService: This device's identity, whose keys sign and whose namespace labels the
    ///     signature.
    ///   - envelopeID: The envelope's id; a fresh one by default.
    ///   - senderDisplayName: The name this side discloses; empty to withhold it.
    ///   - recipientFingerprint: The recipient's fingerprint, or `nil` for a broadcast.
    ///   - payloadType: The Fernlet payload type whose raw value is the envelope's token.
    ///   - payloadEncryption: Whether, and to whom, `payload` is sealed; unsealed by default.
    ///   - payloadSummary: The disclosure summary: frozen literals, never localized.
    ///   - payload: The payload's bytes, already sealed when `payloadEncryption` says so.
    ///   - createdAt: When the envelope is minted; now by default.
    ///   - expiresAt: When it stops verifying; never by default.
    /// - Returns: The signed envelope.
    /// - Throws: What the raw factory throws when the identity cannot sign.
    @MainActor
    public static func signed(
        identityService: IdentityService,
        envelopeID: UUID = UUID(),
        senderDisplayName: String,
        recipientFingerprint: String? = nil,
        payloadType: PayloadType,
        payloadEncryption: PayloadEncryption = .none,
        payloadSummary: PayloadSummary,
        payload: Data,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) throws -> ProximityIdentityEnvelope {
        try signed(
            identityService: identityService, envelopeID: envelopeID, senderDisplayName: senderDisplayName,
            recipientFingerprint: recipientFingerprint, payloadTypeToken: payloadType.rawValue,
            payloadEncryption: payloadEncryption, payloadSummary: payloadSummary, payload: payload,
            createdAt: createdAt, expiresAt: expiresAt)
    }
}

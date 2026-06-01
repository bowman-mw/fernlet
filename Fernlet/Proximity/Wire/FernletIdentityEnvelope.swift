// FernletIdentityEnvelope.swift
// Fernlet/Proximity
//
// Wire envelope for all peer-to-peer transfers between Fernlet devices.
// Every envelope is Ed25519-signed over a deterministic canonical JSON encoding.

import Foundation

// MARK: - Envelope

struct FernletIdentityEnvelope: Codable, Equatable {
    let schemaVersion: Int                        // 1
    let envelopeID: UUID                          // for replay protection + Inspector log correlation
    let senderSigningPublicKey: Data              // Ed25519 raw, 32 B
    let senderKeyAgreementPublicKey: Data         // X25519 raw, 32 B
    let senderDisplayName: String
    let recipientFingerprint: String?             // 8-char SHA-256 prefix; nil = broadcast
    let payloadType: PayloadType
    let payloadEncryption: PayloadEncryption
    let payloadSummary: PayloadSummary
    let payload: Data
    let createdAt: Date
    let expiresAt: Date?
    var signature: Data                           // Ed25519 over canonical JSON (this field is zeroed during signing)
}

// MARK: - Canonical encoding

/// Returns the deterministic byte sequence that is signed and verified.
/// The `signature` field is zeroed so signing and verification produce identical input.
func canonicalBytes(for envelope: FernletIdentityEnvelope) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var copy = envelope
    copy.signature = Data()
    // Encoding a well-formed struct with deterministic options to JSON cannot fail.
    return try! encoder.encode(copy)
}

// MARK: - Verification

extension FernletIdentityEnvelope {
    enum VerifyError: Error, Equatable {
        case schemaVersionUnsupported
        case expired
        case signatureInvalid
        case recipientMismatch
        case payloadDecryptionFailed
        case replayDetected
        case sealingRequired
    }

    // Payload types that must always be delivered sealed to the recipient.
    // A misbehaving sender that omits sealing is rejected at the receiver even if the transport
    // is already encrypted, closing the misbehaving-sender gap for sensitive content.
    private static let sealingRequiredTypes: Set<PayloadType> = [.friendPhoto]

    /// Verifies the envelope signature, recipient, expiry, and replay status; returns the plaintext payload.
    func verify(identityService: IdentityService, replayCache: ReplayCache) throws -> Data {
        guard schemaVersion == 1 else { throw VerifyError.schemaVersionUnsupported }
        if let expiresAt, expiresAt < Date() { throw VerifyError.expired }

        let canon = canonicalBytes(for: self)
        guard IdentityService.verify(signature, of: canon, by: senderSigningPublicKey) else {
            throw VerifyError.signatureInvalid
        }

        if let recipientFingerprint, recipientFingerprint != identityService.localFingerprint {
            throw VerifyError.recipientMismatch
        }

        if Self.sealingRequiredTypes.contains(payloadType), payloadEncryption == .none {
            throw VerifyError.sealingRequired
        }

        try replayCache.recordIfNew(envelopeID: envelopeID)

        switch payloadEncryption {
        case .none:
            return payload
        case .sealedTo:
            do {
                return try identityService.open(payload, from: senderKeyAgreementPublicKey)
            } catch {
                throw VerifyError.payloadDecryptionFailed
            }
        }
    }
}

// MARK: - Signed factory

extension FernletIdentityEnvelope {
    /// Creates a signed envelope. `signature` is computed over the canonical JSON of all other fields.
    static func signed(
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
    ) throws -> FernletIdentityEnvelope {
        var envelope = FernletIdentityEnvelope(
            schemaVersion: 1,
            envelopeID: envelopeID,
            senderSigningPublicKey: identityService.localSigningPublicKey,
            senderKeyAgreementPublicKey: identityService.localKeyAgreementPublicKey,
            senderDisplayName: senderDisplayName,
            recipientFingerprint: recipientFingerprint,
            payloadType: payloadType,
            payloadEncryption: payloadEncryption,
            payloadSummary: payloadSummary,
            payload: payload,
            createdAt: createdAt,
            expiresAt: expiresAt,
            signature: Data()
        )
        envelope.signature = try identityService.sign(canonicalBytes(for: envelope))
        return envelope
    }
}

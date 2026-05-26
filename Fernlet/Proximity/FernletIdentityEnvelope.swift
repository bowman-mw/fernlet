// FernletIdentityEnvelope.swift
// Fernlet/Proximity
//
// Wire envelope for all peer-to-peer transfers between Fernlet devices.
// Every envelope is Ed25519-signed over a deterministic canonical JSON encoding.

import Foundation

// MARK: - Payload classification

enum PayloadType: String, Codable, CaseIterable {
    // Handshake
    case identityIntroduction  = "fernlet.identity.intro.v1"
    case identityAcknowledge   = "fernlet.identity.ack.v1"
    // Trainer
    case trainerPlan           = "fernlet.trainer.plan.v1"
    case trainerPlanDelta      = "fernlet.trainer.plan.delta.v1"
    case workoutCompletion     = "fernlet.workout.completion.v1"
    case workoutLiveUpdate     = "fernlet.workout.live.v1"
    // Session control
    case sessionHeartbeat      = "fernlet.session.ping.v1"
    case sessionGoodbye        = "fernlet.session.bye.v1"
    // Friends
    case friendPhoto           = "fernlet.friend.photo.v1"
    case friendPhotoManifest   = "fernlet.friend.photo.manifest.v1"
    case friendPhotoRequest    = "fernlet.friend.photo.request.v1"
    // Mesh
    case meshDescriptor        = "fernlet.mesh.descriptor.v1"
    case meshAdmissionGrant    = "fernlet.mesh.admission.grant.v1"
    case meshAdmissionToken    = "fernlet.mesh.admission.token.v1"
    case meshAdmissionRequest  = "fernlet.mesh.admission.request.v1"
    case meshStateChange       = "fernlet.mesh.state.v1"
    case meshFriendVouchList   = "fernlet.mesh.vouch.v1"
    case trainerAttachment     = "fernlet.trainer.attachment.v1"
    // Diagnostic
    case inspectorEcho         = "fernlet.diagnostic.echo.v1"
}

enum PayloadEncryption: Codable, Equatable {
    case none
    case sealedTo(recipientKeyAgreementPublicKey: Data)
}

/// A contiguous date interval used in PayloadSummary.
/// Using a plain struct rather than ClosedRange<Date> to sidestep retroactive Codable conformance.
struct DateRange: Codable, Equatable {
    let start: Date
    let end: Date
}

struct PayloadSummary: Codable, Equatable {
    let title: String
    let subtitle: String?
    let itemCount: Int
    let dateRange: DateRange?
    let extraDetails: [String: String]

    init(
        title: String,
        subtitle: String? = nil,
        itemCount: Int = 0,
        dateRange: DateRange? = nil,
        extraDetails: [String: String] = [:]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.itemCount = itemCount
        self.dateRange = dateRange
        self.extraDetails = extraDetails
    }
}

enum MeshMode: String, Codable, Equatable {
    case open
    case closed
}

struct MeshMember: Codable, Equatable, Identifiable {
    var id: String { fingerprint }

    let fingerprint: String
    var displayName: String
    let signingPublicKey: Data
    let keyAgreementPublicKey: Data
    let joinedAt: Date
}

struct MeshDescriptor: Codable, Equatable, Identifiable {
    var id: UUID { meshID }

    let meshID: UUID
    var name: String
    var mode: MeshMode
    var members: [MeshMember]
    var nameSetAt: Date
    var nameSetBy: String
    var modeSetAt: Date
    var modeSetBy: String
    var createdAt: Date
}

struct MeshStateChangePayload: Codable, Equatable {
    let descriptor: MeshDescriptor
}

struct MeshAdmissionRequestPayload: Codable, Equatable {
    let meshID: UUID
    let requesterFingerprint: String
    let requesterDisplayName: String
    let requesterSigningPublicKey: Data
    let requesterKeyAgreementPublicKey: Data
}

struct MeshAdmissionGrantPayload: Codable, Equatable {
    let meshID: UUID
    let requesterFingerprint: String
    let token: MeshAdmissionToken
}

struct MeshAdmissionToken: Codable, Equatable {
    let meshID: UUID
    let joinerFingerprint: String
    let admitterFingerprint: String
    let grantedAt: Date
    let expiresAt: Date
    let admitterSigningPublicKey: Data
    var admitterSignature: Data
}

func canonicalBytes(for token: MeshAdmissionToken) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var copy = token
    copy.admitterSignature = Data()
    return try! encoder.encode(copy)
}

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
    }

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

extension MeshAdmissionToken {
    enum VerifyError: Error, Equatable {
        case expired
        case fingerprintMismatch
        case signatureInvalid
    }

    static func signed(
        meshID: UUID,
        joinerFingerprint: String,
        admitterIdentity: IdentityService,
        grantedAt: Date = Date(),
        expiresAt: Date? = nil
    ) throws -> MeshAdmissionToken {
        let resolvedExpiresAt = expiresAt ?? grantedAt.addingTimeInterval(2 * 60 * 60)
        var token = MeshAdmissionToken(
            meshID: meshID,
            joinerFingerprint: joinerFingerprint,
            admitterFingerprint: admitterIdentity.localFingerprint,
            grantedAt: grantedAt,
            expiresAt: resolvedExpiresAt,
            admitterSigningPublicKey: admitterIdentity.localSigningPublicKey,
            admitterSignature: Data()
        )
        token.admitterSignature = try admitterIdentity.sign(canonicalBytes(for: token))
        return token
    }

    func verify(now: Date = Date()) throws {
        guard expiresAt >= now else { throw VerifyError.expired }
        guard IdentityService.fingerprint(of: admitterSigningPublicKey) == admitterFingerprint else {
            throw VerifyError.fingerprintMismatch
        }
        guard IdentityService.verify(admitterSignature, of: canonicalBytes(for: self), by: admitterSigningPublicKey) else {
            throw VerifyError.signatureInvalid
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

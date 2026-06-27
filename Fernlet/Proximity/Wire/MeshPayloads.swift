import Foundation
import FernletDomainModel

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

struct MeshRemovalProposalPayload: Codable, Equatable, Identifiable {
    let id: UUID
    let targetFingerprint: String
    let targetDisplayName: String
    let proposerFingerprint: String
    let proposerDisplayName: String
    let createdAt: Date
    let expiresAt: Date
}

struct MeshRemovalSecondPayload: Codable, Equatable {
    let proposal: MeshRemovalProposalPayload
    let seconderFingerprint: String
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
    // Phase 3: pairwise-wrapped current group key for the joiner (nil = epoch 0, no key yet)
    var encryptedCurrentKey: Data?
    var currentKeyEpoch: Int

    init(meshID: UUID, requesterFingerprint: String, token: MeshAdmissionToken,
         encryptedCurrentKey: Data? = nil, currentKeyEpoch: Int = 0) {
        self.meshID = meshID
        self.requesterFingerprint = requesterFingerprint
        self.token = token
        self.encryptedCurrentKey = encryptedCurrentKey
        self.currentKeyEpoch = currentKeyEpoch
    }
}

struct MeshAdmissionToken: Codable, Equatable {
    let meshID: UUID
    let joinerFingerprint: String
    let joinerSigningPublicKey: Data        // full Ed25519 public key bound into the admitter's signature
    let admitterFingerprint: String
    let grantedAt: Date
    let expiresAt: Date
    let admitterSigningPublicKey: Data
    var admitterSignature: Data
}

/// Sent after a successful trusted handshake.
/// Lets peers label strangers as "Friend of Aisha" in the mesh roster.
/// Never persisted across app launches; cache expires after 2 hours.
struct MeshFriendVouchListPayload: Codable, Equatable {
    let voucherFingerprint: String
    let voucherDisplayName: String
    let trustedFingerprints: [String]
    let expiresAt: Date
}

// MARK: - Phase 3 Group Encryption Payloads

// Broadcast by the coordinator once per rotation.
// perMember maps each member fingerprint to their pairwise-encrypted copy of the 32-byte new key.
struct MeshKeyRotationPayload: Codable, Equatable {
    let newEpoch: Int
    let perMember: [String: Data]
    let rotationInitiatedAt: Date
    let coordinatorFingerprint: String
}

// Sent by each member after successfully unwrapping and caching the new key.
struct MeshKeyAckPayload: Codable, Equatable {
    let epoch: Int
    let memberFingerprint: String
}

// Broadcast by the coordinator before generating a new key.
// Members drain in-flight photo exchanges before responding with a MeshKeyAckPayload.
struct MeshRotationSyncPayload: Codable, Equatable {
    let closingEpoch: Int
}

// Broadcast by the coordinator every ~20 seconds. Never encrypted - any peer can read it.
struct MeshCoordinatorBeaconPayload: Codable, Equatable {
    let coordinatorFingerprint: String
    let currentEpoch: Int
    let nextRotationAt: Date
    let sentAt: Date
}

// Closed-mode wrapper: inner payload is AES-256-GCM ciphertext over a JSON EncryptedMetadataInner.
struct MeshEncryptedMetadataPayload: Codable, Equatable {
    let ciphertext: Data   // AES-GCM ciphertext + 16-byte tag
    let nonce: Data        // 12-byte random nonce
    let keyEpoch: Int
}

// Inner content of MeshEncryptedMetadataPayload after decryption.
struct EncryptedMetadataInner: Codable {
    let payloadType: String
    let payload: Data
}

func canonicalBytes(for token: MeshAdmissionToken) -> Data {
    var copy = token
    copy.admitterSignature = Data()
    return try! makeCanonicalSignatureEncoder().encode(copy)
}

extension MeshAdmissionToken {
    enum VerifyError: Error, Equatable {
        case expired
        case fingerprintMismatch
        case joinerKeyMismatch
        case signatureInvalid
        case meshMismatch
    }

    static func signed(
        meshID: UUID,
        joinerFingerprint: String,
        joinerSigningPublicKey: Data,
        admitterIdentity: IdentityService,
        grantedAt: Date = Date(),
        expiresAt: Date? = nil
    ) throws -> MeshAdmissionToken {
        let resolvedExpiresAt = expiresAt ?? grantedAt.addingTimeInterval(2 * 60 * 60)
        var token = MeshAdmissionToken(
            meshID: meshID,
            joinerFingerprint: joinerFingerprint,
            joinerSigningPublicKey: joinerSigningPublicKey,
            admitterFingerprint: admitterIdentity.localFingerprint,
            grantedAt: grantedAt,
            expiresAt: resolvedExpiresAt,
            admitterSigningPublicKey: admitterIdentity.localSigningPublicKey,
            admitterSignature: Data()
        )
        token.admitterSignature = try admitterIdentity.sign(canonicalBytes(for: token))
        return token
    }

    /// Verifies the token against the key the local device actually holds.
    /// `presentedKey` must match the `joinerSigningPublicKey` bound into the token at issuance,
    /// preventing a fingerprint-collision attack from impersonating the intended joiner.
    /// `expectedMeshID` must match the signed `meshID`, so a token issued for one mesh cannot be
    /// replayed inside a grant claiming a different mesh (the grant's outer meshID is unsigned).
    func verify(joinerSigningPublicKey presentedKey: Data, expectedMeshID: UUID, now: Date = Date()) throws {
        guard meshID == expectedMeshID else { throw VerifyError.meshMismatch }
        guard expiresAt >= now else { throw VerifyError.expired }
        guard presentedKey == joinerSigningPublicKey else { throw VerifyError.joinerKeyMismatch }
        guard IdentityService.fingerprintsMatch(
            IdentityService.fingerprint(of: joinerSigningPublicKey),
            joinerFingerprint
        ) else {
            throw VerifyError.fingerprintMismatch
        }
        guard IdentityService.fingerprintsMatch(
            IdentityService.fingerprint(of: admitterSigningPublicKey),
            admitterFingerprint
        ) else {
            throw VerifyError.fingerprintMismatch
        }
        guard IdentityService.verify(admitterSignature, of: canonicalBytes(for: self), by: admitterSigningPublicKey) else {
            throw VerifyError.signatureInvalid
        }
    }
}

import Foundation
import FernletDomainModel

struct FriendPhotoPayload: Codable, Equatable, Identifiable {
    let id: UUID
    let imageData: Data?               // non-nil for epoch-0 unencrypted or locally-decrypted photos
    let encryptedImageData: Data?      // AES-256-GCM ciphertext + 16-byte tag; non-nil when transmitted encrypted
    let nonce: Data?                   // 12-byte GCM nonce; paired with encryptedImageData
    let keyEpoch: Int                  // 0 = unencrypted legacy; >=1 = encrypted
    let addedAt: Date
    let senderName: String
    let senderFingerprint: String?
    let senderSigningPublicKey: Data?
    let session: FriendPhotoSessionMetadata?

    // Epoch-0 / already-decrypted initialiser
    init(id: UUID = UUID(), imageData: Data, addedAt: Date = Date(), senderName: String,
         senderFingerprint: String? = nil, senderSigningPublicKey: Data? = nil,
         session: FriendPhotoSessionMetadata? = nil) {
        self.id = id
        self.imageData = imageData
        self.encryptedImageData = nil
        self.nonce = nil
        self.keyEpoch = 0
        self.addedAt = addedAt
        self.senderName = senderName
        self.senderFingerprint = senderFingerprint
        self.senderSigningPublicKey = senderSigningPublicKey
        self.session = session
    }

    // Encrypted initialiser (epoch >= 1); used when transmitting over the wire
    init(id: UUID = UUID(), encryptedImageData: Data, nonce: Data, keyEpoch: Int,
         addedAt: Date = Date(), senderName: String,
         senderFingerprint: String? = nil, senderSigningPublicKey: Data? = nil,
         session: FriendPhotoSessionMetadata? = nil) {
        self.id = id
        self.imageData = nil
        self.encryptedImageData = encryptedImageData
        self.nonce = nonce
        self.keyEpoch = keyEpoch
        self.addedAt = addedAt
        self.senderName = senderName
        self.senderFingerprint = senderFingerprint
        self.senderSigningPublicKey = senderSigningPublicKey
        self.session = session
    }

    // Returns a copy with imageData set and encryption fields cleared, for local caching after decryption.
    func withDecryptedImageData(_ data: Data) -> FriendPhotoPayload {
        return FriendPhotoPayload(
            id: id,
            imageData: data,
            addedAt: addedAt,
            senderName: senderName,
            senderFingerprint: senderFingerprint,
            senderSigningPublicKey: senderSigningPublicKey,
            session: session
        )
    }

    func withSession(_ session: FriendPhotoSessionMetadata) -> FriendPhotoPayload {
        FriendPhotoPayload(
            id: id,
            imageData: imageData,
            encryptedImageData: encryptedImageData,
            nonce: nonce,
            keyEpoch: keyEpoch,
            addedAt: addedAt,
            senderName: senderName,
            senderFingerprint: senderFingerprint,
            senderSigningPublicKey: senderSigningPublicKey,
            session: session
        )
    }

    func withoutImageData() -> FriendPhotoPayload {
        FriendPhotoPayload(
            id: id,
            imageData: nil,
            encryptedImageData: encryptedImageData,
            nonce: nonce,
            keyEpoch: keyEpoch,
            addedAt: addedAt,
            senderName: senderName,
            senderFingerprint: senderFingerprint,
            senderSigningPublicKey: senderSigningPublicKey,
            session: session
        )
    }

    private init(
        id: UUID,
        imageData: Data?,
        encryptedImageData: Data?,
        nonce: Data?,
        keyEpoch: Int,
        addedAt: Date,
        senderName: String,
        senderFingerprint: String?,
        senderSigningPublicKey: Data?,
        session: FriendPhotoSessionMetadata?
    ) {
        self.id = id
        self.imageData = imageData
        self.encryptedImageData = encryptedImageData
        self.nonce = nonce
        self.keyEpoch = keyEpoch
        self.addedAt = addedAt
        self.senderName = senderName
        self.senderFingerprint = senderFingerprint
        self.senderSigningPublicKey = senderSigningPublicKey
        self.session = session
    }
}

struct FriendPhotoSessionParticipant: Codable, Equatable, Identifiable {
    var id: String { fingerprint }

    let fingerprint: String
    let displayName: String
}

struct FriendPhotoSessionMetadata: Codable, Equatable, Identifiable {
    let id: UUID
    let meshID: UUID?
    let meshName: String?
    let startedAt: Date
    let participants: [FriendPhotoSessionParticipant]
}

struct FriendPhotoManifestEntry: Codable, Equatable {
    let id: UUID
    let senderFingerprint: String
    let keyEpoch: Int   // receiver skips requesting photos from epochs it cannot decrypt

    init(id: UUID, senderFingerprint: String, keyEpoch: Int = 0) {
        self.id = id
        self.senderFingerprint = senderFingerprint
        self.keyEpoch = keyEpoch
    }
}

struct FriendPhotoManifestPayload: Codable, Equatable {
    let entries: [FriendPhotoManifestEntry]
}

struct FriendPhotoRequestPayload: Codable, Equatable {
    let missingPhotoIDs: [UUID]
}

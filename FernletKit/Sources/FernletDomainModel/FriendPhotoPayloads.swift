import Foundation

// WI-9: the friend-photo wire payloads are `Sendable` — they are encoded into `envelope.payload` and
// decoded from untrusted peer plaintext exactly like the recipe/mesh wire types, so the whole peer-wire
// surface is uniformly off-main-decode-safe. (FernletDomainModel has no `.defaultIsolation(MainActor.self)`,
// so these need no `nonisolated` keyword — only the `Sendable` conformance.)
public struct FriendPhotoPayload: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let imageData: Data?               // non-nil for epoch-0 unencrypted or locally-decrypted photos
    public let encryptedImageData: Data?      // AES-256-GCM ciphertext + 16-byte tag; non-nil when transmitted encrypted
    public let nonce: Data?                   // 12-byte GCM nonce; paired with encryptedImageData
    public let keyEpoch: Int                  // 0 = unencrypted legacy; >=1 = encrypted
    public let addedAt: Date
    public let senderName: String
    public let senderFingerprint: String?
    public let senderSigningPublicKey: Data?
    public let session: FriendPhotoSessionMetadata?

    // Epoch-0 / already-decrypted initialiser
    public init(id: UUID = UUID(), imageData: Data, addedAt: Date = Date(), senderName: String,
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
    public init(id: UUID = UUID(), encryptedImageData: Data, nonce: Data, keyEpoch: Int,
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
    public func withDecryptedImageData(_ data: Data) -> FriendPhotoPayload {
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

    public func withSession(_ session: FriendPhotoSessionMetadata) -> FriendPhotoPayload {
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

    public func withoutImageData() -> FriendPhotoPayload {
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

public struct FriendPhotoSessionParticipant: Codable, Equatable, Identifiable, Sendable {
    public var id: String { fingerprint }

    public let fingerprint: String
    public let displayName: String

    public init(fingerprint: String, displayName: String) {
        self.fingerprint = fingerprint
        self.displayName = displayName
    }
}

public struct FriendPhotoSessionMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meshID: UUID?
    public let meshName: String?
    public let startedAt: Date
    public let participants: [FriendPhotoSessionParticipant]

    public init(id: UUID, meshID: UUID?, meshName: String?, startedAt: Date, participants: [FriendPhotoSessionParticipant]) {
        self.id = id
        self.meshID = meshID
        self.meshName = meshName
        self.startedAt = startedAt
        self.participants = participants
    }
}

public struct FriendPhotoManifestEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let senderFingerprint: String
    public let keyEpoch: Int   // receiver skips requesting photos from epochs it cannot decrypt

    public init(id: UUID, senderFingerprint: String, keyEpoch: Int = 0) {
        self.id = id
        self.senderFingerprint = senderFingerprint
        self.keyEpoch = keyEpoch
    }
}

public struct FriendPhotoManifestPayload: Codable, Equatable, Sendable {
    public let entries: [FriendPhotoManifestEntry]

    public init(entries: [FriendPhotoManifestEntry]) {
        self.entries = entries
    }
}

public struct FriendPhotoRequestPayload: Codable, Equatable, Sendable {
    public let missingPhotoIDs: [UUID]

    public init(missingPhotoIDs: [UUID]) {
        self.missingPhotoIDs = missingPhotoIDs
    }
}

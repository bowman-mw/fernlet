import Foundation

// WI-9: the friend-photo wire payloads are `Sendable` — they are encoded into `envelope.payload` and
// decoded from untrusted peer plaintext exactly like the recipe/mesh wire types, so the whole peer-wire
// surface is uniformly off-main-decode-safe. (FernletDomainModel has no `.defaultIsolation(MainActor.self)`,
// so these need no `nonisolated` keyword — only the `Sendable` conformance.)
/// The friend-photo wire payload: one shared photo, either plaintext (epoch 0) or AES-GCM sealed.
///
/// Encoded into `envelope.payload` and decoded from untrusted peer plaintext, so it is `Sendable`
/// for off-main decode like the rest of the wire surface. `keyEpoch` 0 means legacy unencrypted
/// `imageData`; epoch ≥ 1 carries `encryptedImageData` + `nonce`, decrypted by the receiving photo
/// store which caches the result via `withDecryptedImageData(_:)`. **Its `PayloadType` is parked
/// since P5 item 13** — nothing sends or dispatches the sealed shape any more, because photo bytes
/// ride the routed store under a per-recipient content-key wrap — but the struct itself is very much
/// alive: it is what the wall, `cachePhoto` and `PrivateMediaStore` speak, and the routed delivery
/// projection builds one (with the ORIGIN's signed attribution) to hand them.
/// `withoutImageData()` strips plaintext bytes for paths that must not hold them; `session`
/// attaches the who/when metadata.
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

/// One participant of a photo session, identified by mesh fingerprint with a display name.
///
/// The display name is untrusted wire data — identity is always the fingerprint.
public struct FriendPhotoSessionParticipant: Codable, Equatable, Identifiable, Sendable {
    public var id: String { fingerprint }

    public let fingerprint: String
    public let displayName: String

    public init(fingerprint: String, displayName: String) {
        self.fingerprint = fingerprint
        self.displayName = displayName
    }
}

/// Which session a shared photo came from: the mesh, when it started, and who was there.
///
/// Attached to photos so the wall can group "that evening with those friends" without carrying any
/// location or content metadata.
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

    /// Bounded decode (R3): this rides untrusted mesh plaintext, so the participant list is capped
    /// where the bytes enter rather than trusting the sender.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        meshID = try c.decodeIfPresent(UUID.self, forKey: .meshID)
        meshName = try c.decodeIfPresent(String.self, forKey: .meshName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        participants = try FriendPhotoLimits.bounded(
            c.decode([FriendPhotoSessionParticipant].self, forKey: .participants),
            limit: FriendPhotoLimits.maxParticipants, container: c, key: .participants)
    }

    /// Wire JSON keys for the session metadata attached to a shared photo.
    private enum CodingKeys: String, CodingKey { case id, meshID, meshName, startedAt, participants }
}

/// Hard bounds on the friend-photo wire payloads.
///
/// The manifest, request and session-metadata types are decoded from untrusted mesh plaintext, and
/// nothing downstream caps them, so these are the caps that keep one hostile frame from
/// materializing an unbounded array (R3).
public enum FriendPhotoLimits {
    public static let maxManifestEntries = 512
    public static let maxRequestedPhotoIDs = 512
    public static let maxParticipants = 32

    /// Rejects a decoded collection that exceeds `limit`, naming the key in the thrown error.
    static func bounded<Element, Key: CodingKey>(_ values: [Element], limit: Int,
                                                 container: KeyedDecodingContainer<Key>,
                                                 key: Key) throws -> [Element] {
        guard values.count <= limit else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "\(values.count) entries exceeds the \(limit) allowed")
        }
        return values
    }
}

/// One row of a peer's photo manifest: photo id, sender fingerprint, and key epoch.
///
/// **Parked with its payload since P5 item 13** (D-13.5). The epoch column existed so a receiver
/// could skip requesting photos from epochs it could not decrypt — the `keyEpoch >= localJoinedEpoch`
/// filter, one of the two gates item 13 retired **with** the path that made them necessary. The
/// routed drain that replaced the pull names no epoch at all, so nothing reads this column now; the
/// wire shape stays frozen and decodable so an older peer's frame is parked by name.
public struct FriendPhotoManifestEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let senderFingerprint: String
    public let keyEpoch: Int   // parked: the epoch filter it fed retired with P5 item 13

    public init(id: UUID, senderFingerprint: String, keyEpoch: Int = 0) {
        self.id = id
        self.senderFingerprint = senderFingerprint
        self.keyEpoch = keyEpoch
    }
}

/// The manifest a peer sends to advertise which photos it holds.
///
/// The receiver diffs it against its own wall and answers with a ``FriendPhotoRequestPayload`` for
/// the ids it is missing.
public struct FriendPhotoManifestPayload: Codable, Equatable, Sendable {
    public let entries: [FriendPhotoManifestEntry]

    public init(entries: [FriendPhotoManifestEntry]) {
        self.entries = entries
    }

    /// Bounded decode (R3): a hostile manifest must not materialize an unbounded entry list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try FriendPhotoLimits.bounded(
            c.decode([FriendPhotoManifestEntry].self, forKey: .entries),
            limit: FriendPhotoLimits.maxManifestEntries, container: c, key: .entries)
    }

    /// Wire JSON keys for a photo manifest.
    private enum CodingKeys: String, CodingKey { case entries }
}

/// A request for the specific photo ids the receiver is missing.
///
/// Sent in response to a ``FriendPhotoManifestPayload``; the peer replies with one
/// ``FriendPhotoPayload`` per requested id.
public struct FriendPhotoRequestPayload: Codable, Equatable, Sendable {
    public let missingPhotoIDs: [UUID]

    public init(missingPhotoIDs: [UUID]) {
        self.missingPhotoIDs = missingPhotoIDs
    }

    /// Bounded decode (R3): the id list drives a filter over the session's photos on the answering
    /// side, so an unbounded request is both memory and CPU the peer chose for us.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        missingPhotoIDs = try FriendPhotoLimits.bounded(
            c.decode([UUID].self, forKey: .missingPhotoIDs),
            limit: FriendPhotoLimits.maxRequestedPhotoIDs, container: c, key: .missingPhotoIDs)
    }

    /// Wire JSON keys for a photo request.
    private enum CodingKeys: String, CodingKey { case missingPhotoIDs }
}

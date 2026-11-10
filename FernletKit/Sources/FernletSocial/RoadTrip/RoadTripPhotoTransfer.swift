// RoadTripPhotoTransfer.swift
// FernletSocial/RoadTrip
//
// Road trip mode, PR 3 "Photos" (Docs/World-RoadTrip-Spec.md §2.7, owner-approved 2026-11-10): a trip photo goes
// to a friend in pieces after the catch-up swap, because the mesh's frame ceiling (16 MiB for the whole signed
// envelope JSON) can't carry a large photo once it is base64'd, sealed and base64'd again. This file is the pure
// half: splitting a photo into pieces and putting a friend's pieces back together, checked and bounded. The
// exchange (`RoadTripExchange`) sends and receives them; the app decides which photos go and keeps what arrives.

import CryptoKit
import Foundation

/// A friend's trip photo, put back together and checked (``RoadTripPhotoAssembler``): every piece arrived, the
/// bytes are the length the pieces said and their SHA-256 matches. Who took it is the transport-verified sender
/// the exchange hands it over with, never a field.
public nonisolated struct RoadTripReceivedPhoto: Equatable, Sendable {
    /// The trip.
    public let tripID: UUID
    /// Its id on the sender's phone.
    public let photoID: UUID
    /// When it was taken.
    public let takenAt: Date
    /// The photo's bytes.
    public let bytes: Data

    /// A received photo.
    public init(tripID: UUID, photoID: UUID, takenAt: Date, bytes: Data) {
        self.tripID = tripID
        self.photoID = photoID
        self.takenAt = takenAt
        self.bytes = bytes
    }
}

/// One of this phone's own trip photos to send a friend: which, and when it was taken. Its bytes are read only when
/// its turn comes, one photo at a time (``RoadTripExchange/sendPhotos(_:to:bytes:done:)``).
public nonisolated struct RoadTripOutgoingPhoto: Equatable, Sendable {
    /// The trip.
    public let tripID: UUID
    /// The photo's id on this phone.
    public let photoID: UUID
    /// When it was taken.
    public let takenAt: Date

    /// A photo to send.
    public init(tripID: UUID, photoID: UUID, takenAt: Date) {
        self.tripID = tripID
        self.photoID = photoID
        self.takenAt = takenAt
    }
}

/// Splits a photo into ``RoadTripPhotoChunkPayload``s: pieces of ``RoadTripPhotoChunkPayload/chunkBytes`` (1 MiB),
/// the last shorter, each carrying the whole photo's length and SHA-256. Pure.
public nonisolated enum RoadTripPhotoChunker {
    /// `bytes`' SHA-256, lowercase hex.
    public static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// `photo`'s pieces for `bytes`, in order; none when the photo is empty or larger than
    /// ``RoadTripPhotoChunkPayload/maxPhotoBytes``.
    public static func chunks(of bytes: Data, for photo: RoadTripOutgoingPhoto) -> [RoadTripPhotoChunkPayload] {
        let count = RoadTripPhotoChunkPayload.chunkCount(forBytes: bytes.count)
        guard count > 0 else { return [] }
        let digest = digest(bytes), takenAt = RoadTripPayload.seconds(photo.takenAt)
        let start = bytes.startIndex
        // R2: bounded by the piece count (at most ten).
        return (0..<min(count, RoadTripPhotoChunkPayload.maxChunks)).map { index in
            let from = start + index * RoadTripPhotoChunkPayload.chunkBytes
            let length = RoadTripPhotoChunkPayload.pieceLength(index: index, byteCount: bytes.count)
            return RoadTripPhotoChunkPayload(tripID: photo.tripID, photoID: photo.photoID, takenAt: takenAt,
                                             byteCount: bytes.count, sha256: digest, index: index, count: count,
                                             bytes: Data(bytes[from..<(from + length)]))
        }
    }
}

/// Puts friends' trip photos back together from their pieces (`rt-photos`), checking each piece against the first
/// one of its photo and the whole against its length and SHA-256.
///
/// - **Resume:** pieces of one photo from one sender gather under (sender, trip, photo) wherever they came from, so
///   a photo sent again (a cut-off transfer the sender retries) fills in the pieces still missing. A photo whose
///   pieces stop coming is dropped after ``staleAfter`` without one, and everything still incomplete is dropped
///   when the hangout ends (``removeAll()``); the next catch-up sends it again whole, since it isn't held.
/// - **Refused whole:** a piece that isn't well formed, or describes its photo differently from the pieces before
///   it (which drops what was gathered), and a photo whose bytes don't match its digest.
/// - **Bounded** (Power of 10): at most ``maxInFlight`` photos gathering at once, ``maxInFlightPerSender`` from one
///   sender, and ``maxInFlightBytes`` reserved for them (each photo's whole length from its first piece); a new photo
///   past a bound is refused (the sender's next catch-up offers it again), never an eviction.
///
/// A value type, owned by the exchange on the main actor.
nonisolated struct RoadTripPhotoAssembler {
    /// The most photos gathering at once.
    static let maxInFlight = 8
    /// The most photos one sender may have gathering at once (a sender sends one photo at a time).
    static let maxInFlightPerSender = 2
    /// The most bytes reserved for photos gathering at once.
    static let maxInFlightBytes = 40 * 1_024 * 1_024
    /// How long a photo waits for its next piece before it is dropped.
    static let staleAfter: TimeInterval = 120

    /// What one piece did.
    enum Outcome: Equatable {
        /// Kept; the photo still waits for pieces.
        case gathering
        /// The photo's last piece: every byte, checked.
        case complete(RoadTripReceivedPhoto)
        /// Refused (and, for a piece that contradicts its photo or a digest that doesn't match, the photo dropped).
        case refused(Refusal)
    }

    /// Why a piece was refused.
    enum Refusal: Equatable {
        /// It isn't well formed.
        case malformed
        /// It describes its photo differently from the pieces before it.
        case mismatch
        /// The reassembled bytes don't match the photo's length or SHA-256.
        case digest
        /// Too many photos, or too many bytes, are gathering now.
        case busy
    }

    /// The photo a piece belongs to.
    private struct Key: Hashable {
        let sender: String
        let tripID: UUID
        let photoID: UUID
    }

    /// One photo's pieces so far.
    private struct Partial {
        /// The first piece's description of the photo (its bytes emptied).
        let first: RoadTripPhotoChunkPayload
        /// The pieces, by index.
        var pieces: [Int: Data]
        /// When its last piece came.
        var lastPiece: Date
    }

    private var partials: [Key: Partial] = [:]

    /// How many photos are gathering.
    var inFlight: Int { partials.count }

    /// One piece from `sender` at `now`.
    mutating func accept(_ chunk: RoadTripPhotoChunkPayload, from sender: String, now: Date) -> Outcome {
        guard chunk.isWellFormed else { return .refused(.malformed) }
        dropStale(now: now)
        let key = Key(sender: sender, tripID: chunk.tripID, photoID: chunk.photoID)
        if var partial = partials[key] {
            guard partial.first.describesSamePhoto(as: chunk) else {
                partials[key] = nil
                return .refused(.mismatch)
            }
            partial.pieces[chunk.index] = chunk.bytes
            partial.lastPiece = now
            partials[key] = partial
        } else {
            guard hasRoom(for: chunk, from: sender) else { return .refused(.busy) }
            let first = RoadTripPhotoChunkPayload(tripID: chunk.tripID, photoID: chunk.photoID, takenAt: chunk.takenAt,
                                                  byteCount: chunk.byteCount, sha256: chunk.sha256, index: chunk.index,
                                                  count: chunk.count, bytes: Data())
            partials[key] = Partial(first: first, pieces: [chunk.index: chunk.bytes], lastPiece: now)
        }
        return completed(key)
    }

    /// Drops every photo still gathering (the hangout ended, a decoy began, a wipe).
    mutating func removeAll() {
        partials.removeAll()
    }

    /// Whether a new photo described by `chunk` from `sender` fits the bounds.
    private func hasRoom(for chunk: RoadTripPhotoChunkPayload, from sender: String) -> Bool {
        let reserved = partials.values.reduce(0) { $0 + $1.first.byteCount }
        let fromSender = partials.keys.filter { $0.sender == sender }.count
        return partials.count < Self.maxInFlight && fromSender < Self.maxInFlightPerSender
            && reserved + chunk.byteCount <= Self.maxInFlightBytes
    }

    /// The photo `key` once every piece is in and its bytes check out; still gathering otherwise.
    private mutating func completed(_ key: Key) -> Outcome {
        guard let partial = partials[key], partial.pieces.count >= partial.first.count else { return .gathering }
        partials[key] = nil
        var bytes = Data()
        bytes.reserveCapacity(partial.first.byteCount)
        // R2: bounded by the piece count (at most ten).
        for index in 0..<min(partial.first.count, RoadTripPhotoChunkPayload.maxChunks) {
            guard let piece = partial.pieces[index] else { return .refused(.mismatch) }
            bytes.append(piece)
        }
        guard bytes.count == partial.first.byteCount, RoadTripPhotoChunker.digest(bytes) == partial.first.sha256 else {
            return .refused(.digest)
        }
        return .complete(RoadTripReceivedPhoto(tripID: partial.first.tripID, photoID: partial.first.photoID,
                                               takenAt: RoadTripPayload.date(partial.first.takenAt), bytes: bytes))
    }

    /// Drops the photos whose last piece came more than ``staleAfter`` before `now`.
    private mutating func dropStale(now: Date) {
        let stale = partials.filter { now.timeIntervalSince($0.value.lastPiece) > Self.staleAfter }.map(\.key)
        // R2: bounded by the in-flight cap.
        for key in stale.prefix(Self.maxInFlight) { partials[key] = nil }
    }
}

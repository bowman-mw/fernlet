// RoadTripPayloads.swift
// FernletSocial/Wire
//
// Road trip mode, PR 2 "Mesh exchange" (Docs/World-RoadTrip-Spec.md, owner-approved 2026-11-10): the wire
// types of the one road trip token (`PayloadType.roadTrip`), sealed and sent over the direct, phone-to-phone
// feature send, never as a routed row. Four kinds share it, told apart by `kind`: the invite a hangout member
// sends when they start a trip, each friend's Join or Not this time, the catch-up swap at a stop, and (PR 3,
// "Photos") the pieces of a trip photo sent after the swap.
//
// This module may not import WorldMapStore (the S3 wall), so a point is carried as whole units of 1e-5° (about
// 1.1 m) and whole seconds since 1970 — the app's own line keeps the same units at rest — and the app converts.
// Every list is bounded and every field checked before the app sees a value: a payload that breaks one rule is
// refused whole. Field names are frozen wire bytes, never localized.

import Foundation

// MARK: - The pieces

/// One person on a road trip, as the wire carries them: their stable id (their mesh signing fingerprint) and their
/// first name only. Frozen: `id` and `firstName` are field names.
public nonisolated struct RoadTripWireMember: Codable, Equatable, Sendable {
    /// The longest id carried (a fingerprint is 16 characters).
    public static let maxIDLength = 128
    /// The longest first name carried.
    public static let maxNameLength = 40

    /// The member's stable id.
    public let id: String
    /// Their first name.
    public let firstName: String

    /// A member with `id` and `firstName`.
    public init(id: String, firstName: String) {
        self.id = id
        self.firstName = firstName
    }

    /// Whether both fields are present and within their bounds.
    public var isWellFormed: Bool {
        RoadTripPayload.isID(id) && !firstName.isEmpty && firstName.count <= Self.maxNameLength
    }
}

/// One timed point of a road: latitude and longitude in whole units of 1e-5° and the time in whole seconds since
/// 1970 (the units the app's line keeps at rest). Frozen: `lat`, `lon` and `t` are field names.
public nonisolated struct RoadTripWirePoint: Codable, Equatable, Sendable {
    /// Degrees are carried in units of this.
    public static let degreeScale = 100_000.0
    /// The largest latitude, in units.
    public static let maxLatitude: Int32 = 9_000_000
    /// The largest longitude, in units.
    public static let maxLongitude: Int32 = 18_000_000

    /// Latitude, in units of 1e-5°.
    public let lat: Int32
    /// Longitude, in units of 1e-5°.
    public let lon: Int32
    /// Seconds since 1970.
    public let t: Int64

    /// A point from its units.
    public init(lat: Int32, lon: Int32, t: Int64) {
        self.lat = lat
        self.lon = lon
        self.t = t
    }

    /// The point at `latitude`, `longitude` (degrees) and `date`, rounded to the units; nil when it is off the globe
    /// or its time is outside 1970 to the year 9999.
    public init?(latitude: Double, longitude: Double, at date: Date) {
        let seconds = date.timeIntervalSince1970
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180, seconds.isFinite,
              seconds >= 0, seconds <= Double(RoadTripPayload.maxSeconds) else { return nil }
        self.init(lat: Int32((latitude * Self.degreeScale).rounded()), lon: Int32((longitude * Self.degreeScale).rounded()),
                  t: Int64(seconds.rounded(.down)))
    }

    /// The latitude in degrees.
    public var latitude: Double { Double(lat) / Self.degreeScale }
    /// The longitude in degrees.
    public var longitude: Double { Double(lon) / Self.degreeScale }
    /// When.
    public var date: Date { RoadTripPayload.date(t) }

    /// Whether it is on the globe and within the times a point may carry.
    public var isWellFormed: Bool {
        abs(lat) <= Self.maxLatitude && abs(lon) <= Self.maxLongitude && RoadTripPayload.isTime(t)
    }
}

/// One stretch of road, oldest point first, its time never running backwards. Frozen: `points` is a field name.
public nonisolated struct RoadTripWireSegment: Codable, Equatable, Sendable {
    /// The points, oldest first.
    public let points: [RoadTripWirePoint]

    /// A stretch of `points`.
    public init(points: [RoadTripWirePoint]) {
        self.points = points
    }

    /// Whether it has at least one point and at most ``RoadTripPayload/maxPoints``, every one well formed and none
    /// older than the one before.
    public var isWellFormed: Bool {
        guard !points.isEmpty, points.count <= RoadTripPayload.maxPoints else { return false }
        var previous = Int64.min
        // R2: bounded by the count checked above.
        for point in points {
            guard point.isWellFormed, point.t >= previous else { return false }
            previous = point.t
        }
        return true
    }
}

/// "Map from this iPhone" as the wire carries it (`rt-mapper`): who took over, when, and what the automatic rule
/// answered then. Frozen: `memberID`, `at` and `ruleAnswer` are field names.
public nonisolated struct RoadTripWireTakeover: Codable, Equatable, Sendable {
    /// The member who took over.
    public let memberID: String
    /// When, in seconds since 1970.
    public let at: Int64
    /// The member the rule chose then.
    public let ruleAnswer: String

    /// A takeover by `memberID` at `at`, when the rule answered `ruleAnswer`.
    public init(memberID: String, at: Int64, ruleAnswer: String) {
        self.memberID = memberID
        self.at = at
        self.ruleAnswer = ruleAnswer
    }

    /// Whether both ids and the time are within their bounds.
    public var isWellFormed: Bool { RoadTripPayload.isID(memberID) && RoadTripPayload.isID(ruleAnswer) && RoadTripPayload.isTime(at) }
}

/// What the sender's iPhone says for the mapper rule (`rt-mapper`): whether it is on CarPlay, whether it is
/// charging, and the "Map from this iPhone" it knows of, if any. Frozen: `onCarPlay`, `isCharging` and `takeover`
/// are field names.
public nonisolated struct RoadTripWireMapperState: Codable, Equatable, Sendable {
    /// Whether CarPlay is connected.
    public let onCarPlay: Bool
    /// Whether the phone is plugged in.
    public let isCharging: Bool
    /// The newest "Map from this iPhone" the sender knows of, still in force on its phone.
    public let takeover: RoadTripWireTakeover?

    /// The sender's state.
    public init(onCarPlay: Bool, isCharging: Bool, takeover: RoadTripWireTakeover?) {
        self.onCarPlay = onCarPlay
        self.isCharging = isCharging
        self.takeover = takeover
    }
}

// MARK: - The three kinds

/// The invite (`rt-start`): the trip the starter's phone just began, sent to each friend in the hangout. Frozen:
/// `tripID`, `name`, `starterID`, `members` and `startedAt` are field names.
public nonisolated struct RoadTripInvitePayload: Codable, Equatable, Sendable {
    /// The trip's id, the same on every phone.
    public let tripID: UUID
    /// The name the starter gave it; nil for the default ("Road trip" and the date, drawn on each phone).
    public let name: String?
    /// Who started it (one of ``members``).
    public let starterID: String
    /// Everyone invited, the starter included: at least two, at most ``RoadTripPayload/maxMembers``.
    public let members: [RoadTripWireMember]
    /// When it started, in seconds since 1970.
    public let startedAt: Int64

    /// An invite.
    public init(tripID: UUID, name: String?, starterID: String, members: [RoadTripWireMember], startedAt: Int64) {
        self.tripID = tripID
        self.name = name
        self.starterID = starterID
        self.members = members
        self.startedAt = startedAt
    }

    /// Whether it names two to five distinct, well-formed members, the starter among them, a name no longer than
    /// ``RoadTripPayload/maxTripNameLength`` and a start in range.
    public var isWellFormed: Bool {
        guard (2...RoadTripPayload.maxMembers).contains(members.count), members.allSatisfy(\.isWellFormed),
              Set(members.map(\.id)).count == members.count, members.contains(where: { $0.id == starterID }),
              RoadTripPayload.isTime(startedAt) else { return false }
        guard let name else { return true }
        return !name.isEmpty && name.count <= RoadTripPayload.maxTripNameLength
    }
}

/// A friend's answer to the invite (`rt-join`): Join, or Not this time (also what a phone answers a catch-up for a
/// trip it is not on). The sender is the transport-verified peer, never a field. Frozen: `tripID` and `joins` are
/// field names.
public nonisolated struct RoadTripJoinPayload: Codable, Equatable, Sendable {
    /// The trip answered.
    public let tripID: UUID
    /// Join (true) or Not this time (false).
    public let joins: Bool

    /// An answer.
    public init(tripID: UUID, joins: Bool) {
        self.tripID = tripID
        self.joins = joins
    }
}

/// The catch-up swap at a stop (`rt-catchup`): the road the sender holds that the receiver was there for (since
/// their last catch-up together, by the proof-of-presence rule), the sender's mapper state, and when the trip
/// ended if it did. An offer is answered by one reply, so the swap does not depend on which phone committed
/// first. Frozen: `tripID`, `isReply`, `segments`, `mapper`, `endedAt` and `heldPhotos` are field names.
///
/// **Photos** (PR 3, `rt-photos`): ``heldPhotos`` lists the receiver's own trip photos the sender already holds
/// (their ids on the receiver's phone, at most ``RoadTripPayload/maxPhotosPerMember``), so the receiver sends only
/// the ones missing, as ``RoadTripPhotoChunkPayload``s after it. Nil and empty mean the same: none yet. It names
/// only the receiver's own photos, so a catch-up never tells one friend what another took.
public nonisolated struct RoadTripCatchUpPayload: Codable, Equatable, Sendable {
    /// The trip.
    public let tripID: UUID
    /// Whether this answers the receiver's own offer (a reply is never answered).
    public let isReply: Bool
    /// The road, oldest stretch first: at most ``RoadTripPayload/maxSegments`` stretches of at most
    /// ``RoadTripPayload/maxPoints`` points in all.
    public let segments: [RoadTripWireSegment]
    /// The sender's state for the mapper rule.
    public let mapper: RoadTripWireMapperState
    /// When the trip ended on the sender's phone (End the road trip, there or relayed), in seconds since 1970.
    public let endedAt: Int64?
    /// The receiver's own trip photos the sender already holds, by their ids on the receiver's phone (PR 3).
    public let heldPhotos: [UUID]?

    /// A catch-up.
    public init(tripID: UUID, isReply: Bool, segments: [RoadTripWireSegment], mapper: RoadTripWireMapperState,
                endedAt: Int64?, heldPhotos: [UUID]? = nil) {
        self.tripID = tripID
        self.isReply = isReply
        self.segments = segments
        self.mapper = mapper
        self.endedAt = endedAt
        self.heldPhotos = heldPhotos
    }

    /// How many points it carries in all.
    public var pointCount: Int { segments.prefix(RoadTripPayload.maxSegments).reduce(0) { $0 + $1.points.count } }

    /// Whether its stretches are within their bounds, each well formed and none starting before the one before
    /// ended, its takeover well formed, its end in range and its held photos at most one roll, none twice.
    public var isWellFormed: Bool {
        guard segments.count <= RoadTripPayload.maxSegments, pointCount <= RoadTripPayload.maxPoints,
              mapper.takeover?.isWellFormed ?? true, endedAt.map(RoadTripPayload.isTime) ?? true else { return false }
        let held = heldPhotos ?? []
        guard held.count <= RoadTripPayload.maxPhotosPerMember, Set(held).count == held.count else { return false }
        var previous = Int64.min
        // R2: bounded by the count checked above.
        for segment in segments {
            guard segment.isWellFormed, let first = segment.points.first, let last = segment.points.last,
                  first.t >= previous else { return false }
            previous = last.t
        }
        return true
    }
}

/// One piece of a trip photo (PR 3, `rt-photos`): a photo the sender took on the trip, sent after a catch-up in
/// pieces of ``chunkBytes`` image bytes, because a whole photo, base64'd, sealed and base64'd again, would not fit the
/// mesh's 16 MiB frame. Every piece carries the whole photo's description (its trip, its id on the sender's phone,
/// when it was taken, its byte count and SHA-256), so the receiver can check each piece against the first and the
/// reassembled bytes against the digest (`RoadTripPhotoAssembler`). Who took it is never a field: it is the
/// transport-verified sender, so a friend's photo can't be passed on as someone else's.
///
/// Frozen: `tripID`, `photoID`, `takenAt`, `byteCount`, `sha256`, `index`, `count` and `bytes` are field names.
public nonisolated struct RoadTripPhotoChunkPayload: Codable, Equatable, Sendable {
    /// The image bytes in every piece but the last (1 MiB).
    public static let chunkBytes = 1_024 * 1_024
    /// The largest photo carried (the photo corpora's own byte cap, 10 MiB).
    public static let maxPhotoBytes = 10 * 1_024 * 1_024
    /// The most pieces one photo has.
    public static let maxChunks = maxPhotoBytes / chunkBytes
    /// The length of a hex SHA-256 digest.
    public static let digestLength = 64

    /// The trip.
    public let tripID: UUID
    /// The photo's id on the sender's phone.
    public let photoID: UUID
    /// When it was taken, in seconds since 1970.
    public let takenAt: Int64
    /// The whole photo's length in bytes.
    public let byteCount: Int
    /// The whole photo's SHA-256, lowercase hex.
    public let sha256: String
    /// This piece's place, from 0.
    public let index: Int
    /// How many pieces the photo has.
    public let count: Int
    /// This piece's bytes.
    public let bytes: Data

    /// A piece.
    public init(tripID: UUID, photoID: UUID, takenAt: Int64, byteCount: Int, sha256: String, index: Int, count: Int,
                bytes: Data) {
        self.tripID = tripID
        self.photoID = photoID
        self.takenAt = takenAt
        self.byteCount = byteCount
        self.sha256 = sha256
        self.index = index
        self.count = count
        self.bytes = bytes
    }

    /// How many pieces a photo of `byteCount` bytes is sent in; 0 outside 1 to ``maxPhotoBytes``.
    public static func chunkCount(forBytes byteCount: Int) -> Int {
        guard byteCount > 0, byteCount <= maxPhotoBytes else { return 0 }
        return (byteCount + chunkBytes - 1) / chunkBytes
    }

    /// The bytes piece `index` of a photo of `byteCount` bytes carries.
    public static func pieceLength(index: Int, byteCount: Int) -> Int {
        let count = chunkCount(forBytes: byteCount)
        guard index >= 0, index < count else { return 0 }
        return index < count - 1 ? chunkBytes : byteCount - chunkBytes * (count - 1)
    }

    /// Whether the photo's size, the count, the index, this piece's length, the digest and the time agree.
    public var isWellFormed: Bool {
        let expected = Self.chunkCount(forBytes: byteCount)
        guard expected > 0, count == expected, index >= 0, index < count,
              bytes.count == Self.pieceLength(index: index, byteCount: byteCount), RoadTripPayload.isTime(takenAt) else { return false }
        return sha256.count == Self.digestLength && sha256.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Whether `other` describes the same photo (every field but the piece's own).
    public func describesSamePhoto(as other: RoadTripPhotoChunkPayload) -> Bool {
        tripID == other.tripID && photoID == other.photoID && takenAt == other.takenAt && byteCount == other.byteCount
            && sha256 == other.sha256 && count == other.count
    }
}

// MARK: - The envelope body

/// The road trip token's one body (`PayloadType.roadTrip`): a version, the kind, and exactly that kind's part.
/// Frozen: `version`, `kind`, `invite`, `join`, `catchUp` and `photo` are field names, and the kinds' raw values are
/// wire tokens. PR 3 appended ``Kind/photo`` (unshipped PR 2 builds drop it as malformed), keeping version 1.
public nonisolated struct RoadTripPayload: Codable, Equatable, Sendable {
    /// Which of the four messages this is. Frozen raw values.
    public enum Kind: String, Codable, Sendable {
        /// ``RoadTripInvitePayload``.
        case invite
        /// ``RoadTripJoinPayload``.
        case join
        /// ``RoadTripCatchUpPayload``.
        case catchUp
        /// ``RoadTripPhotoChunkPayload`` (PR 3).
        case photo
    }

    /// The format this build writes and reads.
    public static let currentVersion = 1
    /// The most people on one trip, the starter included (one phone's direct links).
    public static let maxMembers = 5
    /// The longest name a trip may be given.
    public static let maxTripNameLength = 60
    /// The most stretches of road in one catch-up.
    public static let maxSegments = 16
    /// The most points in one catch-up: a whole trip's line on one phone (about 2,500 km at 25 m apart).
    public static let maxPoints = 100_000
    /// The most bytes a body may have before it is decoded: room for ``maxPoints`` points (and for one photo piece,
    /// whose 1 MiB is about 1.4 MB as JSON).
    public static let maxPlaintextBytes = 6 * 1024 * 1024
    /// The latest time a field may carry (the year 9999).
    public static let maxSeconds: Int64 = 253_402_300_799
    /// The most photos one person may take on one trip (`rt-photos`: "up to 30 per person").
    public static let maxPhotosPerMember = 30

    /// The format.
    public let version: Int
    /// The kind.
    public let kind: Kind
    /// The invite, for ``Kind/invite``.
    public let invite: RoadTripInvitePayload?
    /// The answer, for ``Kind/join``.
    public let join: RoadTripJoinPayload?
    /// The catch-up, for ``Kind/catchUp``.
    public let catchUp: RoadTripCatchUpPayload?
    /// A photo's piece, for ``Kind/photo``.
    public let photo: RoadTripPhotoChunkPayload?

    private init(kind: Kind, invite: RoadTripInvitePayload? = nil, join: RoadTripJoinPayload? = nil,
                 catchUp: RoadTripCatchUpPayload? = nil, photo: RoadTripPhotoChunkPayload? = nil) {
        self.version = Self.currentVersion
        self.kind = kind
        self.invite = invite
        self.join = join
        self.catchUp = catchUp
        self.photo = photo
    }

    /// An invite's body.
    public static func invite(_ invite: RoadTripInvitePayload) -> RoadTripPayload {
        RoadTripPayload(kind: .invite, invite: invite)
    }

    /// An answer's body.
    public static func join(_ join: RoadTripJoinPayload) -> RoadTripPayload {
        RoadTripPayload(kind: .join, join: join)
    }

    /// A catch-up's body.
    public static func catchUp(_ catchUp: RoadTripCatchUpPayload) -> RoadTripPayload {
        RoadTripPayload(kind: .catchUp, catchUp: catchUp)
    }

    /// A photo piece's body.
    public static func photo(_ photo: RoadTripPhotoChunkPayload) -> RoadTripPayload {
        RoadTripPayload(kind: .photo, photo: photo)
    }

    /// Whether it is this build's version and carries exactly its kind's part, well formed.
    public var isWellFormed: Bool {
        guard version == Self.currentVersion else { return false }
        let parts = [invite != nil, join != nil, catchUp != nil, photo != nil].filter { $0 }.count
        guard parts == 1 else { return false }
        switch kind {
        case .invite: return invite?.isWellFormed ?? false
        case .join: return join != nil
        case .catchUp: return catchUp?.isWellFormed ?? false
        case .photo: return photo?.isWellFormed ?? false
        }
    }

    /// The body in `plaintext`, or nil when it is larger than ``maxPlaintextBytes``, doesn't decode or isn't well
    /// formed (the receive door: nothing malformed reaches the app).
    public static func decoded(from plaintext: Data) -> RoadTripPayload? {
        guard !plaintext.isEmpty, plaintext.count <= maxPlaintextBytes,
              let payload = try? JSONDecoder().decode(RoadTripPayload.self, from: plaintext),
              payload.isWellFormed else { return nil }
        return payload
    }

    /// Whether `id` is a member id within its bounds.
    static func isID(_ id: String) -> Bool { !id.isEmpty && id.count <= RoadTripWireMember.maxIDLength }

    /// Whether `seconds` is a time a field may carry: 1970 to ``maxSeconds``.
    static func isTime(_ seconds: Int64) -> Bool { seconds >= 0 && seconds <= maxSeconds }

    /// `date` in whole seconds since 1970, clamped to the times a field may carry.
    public static func seconds(_ date: Date) -> Int64 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return 0 }
        return Int64(min(max(seconds, 0), Double(maxSeconds)).rounded(.down))
    }

    /// The date `seconds` since 1970 stands for.
    public static func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
}

import FernletDomainModel
import FernletSocial
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The road trip's wire (World-RoadTrip-Spec PR 2, owner-approved 2026-11-10): FernletSocial's one body for the
/// invite, the join answer and the catch-up round-trips through JSON; every list is bounded and every field checked;
/// a malformed or oversize body is refused whole; and the app's conversions keep the line's own units.
@MainActor
struct RoadTripWireTests {
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)
    private static let here = GeoPoint(45.5205, -122.6255)

    /// Three members, Mike starting.
    nonisolated static let members = [RoadTripWireMember(id: "aaaaaaaaaaaaaaaa", firstName: "Mike"),
                          RoadTripWireMember(id: "bbbbbbbbbbbbbbbb", firstName: "Rae"),
                          RoadTripWireMember(id: "cccccccccccccccc", firstName: "Sam")]

    /// An invite from Mike.
    static func invite(members: [RoadTripWireMember] = members, name: String? = "To the coast") -> RoadTripInvitePayload {
        RoadTripInvitePayload(tripID: UUID(), name: name, starterID: "aaaaaaaaaaaaaaaa", members: members,
                              startedAt: RoadTripPayload.seconds(start))
    }

    /// `count` points 30 m apart, a second apart, from the start.
    static func wirePoints(_ count: Int, from offset: Int = 0) -> [RoadTripWirePoint] {
        (0..<count).compactMap { index in
            let point = here.offset(east: Double(index + offset) * 30, north: 0)
            return RoadTripWirePoint(latitude: point.latitude, longitude: point.longitude,
                                     at: start.addingTimeInterval(Double(index + offset)))
        }
    }

    /// A catch-up carrying `segments`.
    static func catchUp(_ segments: [RoadTripWireSegment], isReply: Bool = false, endedAt: Int64? = nil,
                        takeover: RoadTripWireTakeover? = nil) -> RoadTripCatchUpPayload {
        RoadTripCatchUpPayload(tripID: UUID(), isReply: isReply, segments: segments,
                               mapper: RoadTripWireMapperState(onCarPlay: true, isCharging: false, takeover: takeover),
                               endedAt: endedAt)
    }

    /// `payload`'s JSON, as the mesh's sender encodes it.
    static func encoded(_ payload: RoadTripPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    // MARK: Round trips

    /// Each kind encodes and decodes to itself, carrying exactly its own part, under the one frozen token, sealed.
    @Test func eachKindRoundTrips() throws {
        let catchUp = Self.catchUp([RoadTripWireSegment(points: Self.wirePoints(40))], endedAt: 2_000_000_100,
                                   takeover: RoadTripWireTakeover(memberID: "bbbbbbbbbbbbbbbb", at: 2_000_000_050,
                                                                  ruleAnswer: "aaaaaaaaaaaaaaaa"))
        let bodies: [RoadTripPayload] = [.invite(Self.invite()), .join(RoadTripJoinPayload(tripID: UUID(), joins: false)),
                                         .catchUp(catchUp)]
        // R2: bounded by the three kinds.
        for body in bodies {
            let decoded = try #require(RoadTripPayload.decoded(from: Self.encoded(body)), "\(body.kind) did not decode")
            #expect(decoded == body)
            #expect(decoded.version == 1)
        }
        #expect(PayloadType.roadTrip.rawValue == "fernlet.road-trip.v1")
        #expect(ProximityCapability.roadTrip.rawValue == "roadTrip")
        #expect(RoadTripPayload.Kind.catchUp.rawValue == "catchUp" && RoadTripPayload.Kind.invite.rawValue == "invite"
                && RoadTripPayload.Kind.join.rawValue == "join")
        let json = try #require(String(data: Self.encoded(.join(RoadTripJoinPayload(tripID: UUID(), joins: true))), encoding: .utf8))
        #expect(json.contains("\"kind\":\"join\"") && json.contains("\"joins\":true"), "frozen field names: \(json)")
    }

    /// The bounds match the trip record's, so nothing the wire takes is more than a trip keeps.
    @Test func theBoundsMatchTheTripsOwn() throws {
        #expect(RoadTripPayload.maxMembers == RoadTrip.maxMembers)
        #expect(RoadTripPayload.maxTripNameLength == RoadTrip.maxNameLength)
        #expect(RoadTripPayload.maxPoints == RoadTripLine.maxPoints)
        #expect(RoadTripWireMember.maxIDLength == RoadTripMember.maxIDLength)
        #expect(RoadTripWireMember.maxNameLength == RoadTripMember.maxNameLength)
        #expect(RoadTripPayload.maxSeconds == Int64(RoadTripLineCodec.maxSeconds))
        #expect(RoadTripWirePoint.degreeScale == RoadTripLineCodec.degreeScale)
        // A whole trip's line of the widest points fits under the byte bound, and that under the mesh's 16 MiB frame.
        let widest = RoadTripWirePoint(lat: -8_999_999, lon: -17_999_999, t: 253_402_300_799)
        let one = try JSONEncoder().encode(widest).count
        #expect((one + 1) * RoadTripPayload.maxPoints < RoadTripPayload.maxPlaintextBytes)
        #expect(RoadTripPayload.maxPlaintextBytes < 16 * 1024 * 1024)
    }

    // MARK: Refusals

    /// An invite with too many or too few people, a starter not among them, an id twice, a member's bad name or a
    /// name too long is refused.
    @Test func aBadInviteIsRefused() throws {
        let six = (0..<6).map { RoadTripWireMember(id: String(repeating: "\($0)", count: 16), firstName: "P\($0)") }
        let bad: [RoadTripInvitePayload] = [
            Self.invite(members: [Self.members[0]]),
            Self.invite(members: [Self.members[0]] + Array(six.prefix(5))),
            RoadTripInvitePayload(tripID: UUID(), name: nil, starterID: "dddddddddddddddd", members: Self.members, startedAt: 0),
            Self.invite(members: [Self.members[0], Self.members[0]]),
            Self.invite(members: [Self.members[0], RoadTripWireMember(id: "bbbbbbbbbbbbbbbb", firstName: "")]),
            Self.invite(members: [Self.members[0], RoadTripWireMember(id: String(repeating: "b", count: 129), firstName: "Rae")]),
            Self.invite(name: String(repeating: "x", count: 61)),
            Self.invite(name: ""),
            RoadTripInvitePayload(tripID: UUID(), name: nil, starterID: "aaaaaaaaaaaaaaaa", members: Self.members, startedAt: -1)
        ]
        // R2: bounded by the cases above.
        for invite in bad {
            #expect(!invite.isWellFormed)
            #expect(RoadTripPayload.decoded(from: try Self.encoded(.invite(invite))) == nil)
        }
        #expect(Self.invite(name: nil).isWellFormed && Self.invite(name: String(repeating: "x", count: 60)).isWellFormed)
    }

    /// A catch-up with time running backwards, a point off the globe, too many points or stretches, stretches out
    /// of order, an empty stretch, a bad takeover or end is refused whole.
    @Test func aBadCatchUpIsRefusedWhole() throws {
        var backwards = Self.wirePoints(10)
        backwards.swapAt(3, 4)
        let tooMany = (0..<(RoadTripPayload.maxPoints + 1)).map { RoadTripWirePoint(lat: 0, lon: 0, t: Int64($0)) }
        let bad: [RoadTripCatchUpPayload] = [
            Self.catchUp([RoadTripWireSegment(points: backwards)]),
            Self.catchUp([RoadTripWireSegment(points: [RoadTripWirePoint(lat: 9_000_001, lon: 0, t: 1)])]),
            Self.catchUp([RoadTripWireSegment(points: [RoadTripWirePoint(lat: 0, lon: -18_000_001, t: 1)])]),
            Self.catchUp([RoadTripWireSegment(points: [RoadTripWirePoint(lat: 0, lon: 0, t: -1)])]),
            Self.catchUp([RoadTripWireSegment(points: tooMany)]),
            Self.catchUp(Array(repeating: RoadTripWireSegment(points: Self.wirePoints(1)), count: 17)),
            Self.catchUp([RoadTripWireSegment(points: Self.wirePoints(5, from: 10)), RoadTripWireSegment(points: Self.wirePoints(5))]),
            Self.catchUp([RoadTripWireSegment(points: [])]),
            Self.catchUp([], endedAt: RoadTripPayload.maxSeconds + 1),
            Self.catchUp([], takeover: RoadTripWireTakeover(memberID: "", at: 0, ruleAnswer: "aaaaaaaaaaaaaaaa"))
        ]
        // R2: bounded by the cases above.
        for (index, catchUp) in bad.enumerated() {
            #expect(!catchUp.isWellFormed, "case \(index)")
        }
        #expect(RoadTripPayload.decoded(from: try Self.encoded(.catchUp(bad[0]))) == nil)
        let two = Self.catchUp([RoadTripWireSegment(points: Self.wirePoints(5)), RoadTripWireSegment(points: Self.wirePoints(5, from: 5))])
        #expect(two.isWellFormed && two.pointCount == 10, "stretches in order are fine")
        #expect(Self.catchUp([]).isWellFormed, "a catch-up may carry no road")
    }

    /// A body that isn't this version, carries another kind's part or none, names an unknown kind, isn't JSON, is
    /// empty or is over the byte bound never decodes.
    @Test func aMalformedBodyNeverDecodes() throws {
        let join = try Self.encoded(.join(RoadTripJoinPayload(tripID: UUID(), joins: true)))
        let text = try #require(String(data: join, encoding: .utf8))
        let variants = [
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            text.replacingOccurrences(of: "\"kind\":\"join\"", with: "\"kind\":\"invite\""),
            text.replacingOccurrences(of: "\"kind\":\"join\"", with: "\"kind\":\"photo\""),
            "{\"version\":1,\"kind\":\"join\"}",
            "not json"
        ]
        // R2: bounded by the variants above.
        for variant in variants {
            #expect(RoadTripPayload.decoded(from: Data(variant.utf8)) == nil, "\(variant)")
        }
        #expect(RoadTripPayload.decoded(from: Data()) == nil)
        #expect(RoadTripPayload.decoded(from: Data(repeating: 0x20, count: RoadTripPayload.maxPlaintextBytes + 1)) == nil)
    }

    // MARK: The app's conversions

    /// A line point goes over the wire and back as the line would keep it (1e-5°, whole seconds); a point off the
    /// globe never goes; the stretches come back in order.
    @Test func linePointsRoundTripInTheLinesUnits() throws {
        let points = RoadTripCoreTests.points(50)
        let segments = RoadTripWire.segments(points)
        #expect(segments.count == 1 && segments[0].points.count == 50)
        let back = RoadTripWire.points(segments)
        #expect(back.count == 50)
        for (a, b) in zip(back, points) {
            #expect(abs(a.point.latitude - b.point.latitude) < 1e-5 && abs(a.point.longitude - b.point.longitude) < 1e-5)
            #expect(a.at == b.at)
        }
        #expect(RoadTripWire.wire(RoadTripPoint(point: GeoPoint(91, 0), at: Self.start)) == nil)
        #expect(RoadTripWire.segments([]).isEmpty)
    }

    /// A Join makes the trip of the invite on this iPhone: every member at the start, named as this iPhone knows
    /// them, mapped by the rule over this phone's own state; an invite that doesn't name it makes none.
    @Test func aJoinMakesTheInvitesTrip() throws {
        let invite = Self.invite()
        let own = RoadTripDeviceState(onCarPlay: true, isCharging: false)
        let trip = try #require(RoadTripWire.trip(joining: invite, selfID: "bbbbbbbbbbbbbbbb",
                                                  names: ["cccccccccccccccc": "Samantha Q"], own: own))
        #expect(trip.id == invite.tripID && trip.starterID == "aaaaaaaaaaaaaaaa" && trip.selfID == "bbbbbbbbbbbbbbbb")
        #expect(trip.members.map(\.firstName) == ["Mike", "Rae", "Samantha Q"])
        #expect(trip.atStart == trip.memberIDs && trip.startedAt == Self.start && trip.lastCatchUp == Self.start)
        #expect(trip.mapperID == "bbbbbbbbbbbbbbbb", "on CarPlay, this phone maps")
        #expect(trip.isValid && trip.isActive)
        #expect(RoadTripWire.trip(joining: invite, selfID: "dddddddddddddddd", names: [:], own: own) == nil)
        let back = RoadTripWire.invite(for: trip)
        #expect(back.tripID == invite.tripID && back.starterID == invite.starterID && back.startedAt == invite.startedAt)
    }
}

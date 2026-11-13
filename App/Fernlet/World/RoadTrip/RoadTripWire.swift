import FernletSocial
import Foundation
import WorldMapStore

/// The road trip's values on and off the wire (World-RoadTrip-Spec PR 2): FernletSocial carries a trip's invite,
/// answer and catch-up in its own types (it may not import WorldMapStore), and this converts, so every point that
/// reaches the line or the fog is checked here too. A point keeps the line's own units (1e-5°, whole seconds), so a
/// point that went over the wire and back is the point the line would have kept.
nonisolated enum RoadTripWire {
    /// `point` on the wire; nil when it is off the globe or out of time.
    static func wire(_ point: RoadTripPoint) -> RoadTripWirePoint? {
        guard point.point.isValid else { return nil }
        return RoadTripWirePoint(latitude: point.point.latitude, longitude: point.point.longitude, at: point.at)
    }

    /// A wire point as a line point; nil when it is not a valid place.
    static func point(_ wire: RoadTripWirePoint) -> RoadTripPoint? {
        guard wire.isWellFormed else { return nil }
        let point = GeoPoint(wire.latitude, wire.longitude)
        guard point.isValid else { return nil }
        return RoadTripPoint(point: point, at: wire.date)
    }

    /// `points` (oldest first) as the wire's stretches: one, of at most `RoadTripPayload/maxPoints`; none when empty.
    static func segments(_ points: [RoadTripPoint]) -> [RoadTripWireSegment] {
        let wired = points.prefix(RoadTripPayload.maxPoints).compactMap(wire)
        guard !wired.isEmpty else { return [] }
        return [RoadTripWireSegment(points: wired)]
    }

    /// The stretches' points, oldest first, each a valid place (the payload was checked whole before).
    static func points(_ segments: [RoadTripWireSegment]) -> [RoadTripPoint] {
        var points: [RoadTripPoint] = []
        // R2: bounded by the payload's own bounds (16 stretches, 100,000 points).
        for segment in segments.prefix(RoadTripPayload.maxSegments) {
            points += segment.points.prefix(RoadTripPayload.maxPoints - points.count).compactMap(point)
        }
        return points
    }

    /// This iPhone's state for a catch-up: its phone now and the takeover it knows of.
    static func mapperState(own: RoadTripDeviceState, takeover: RoadTripMapperOverride?) -> RoadTripWireMapperState {
        RoadTripWireMapperState(onCarPlay: own.onCarPlay, isCharging: own.isCharging, takeover: takeover.map {
            RoadTripWireTakeover(memberID: $0.memberID, at: RoadTripPayload.seconds($0.at), ruleAnswer: $0.ruleAnswer)
        })
    }

    /// A received catch-up's state, takeover and end, as the rules apply them.
    static func received(_ catchUp: RoadTripCatchUpPayload) -> RoadTripReceivedCatchUp {
        let mapper = catchUp.mapper
        let takeover = mapper.takeover.map {
            RoadTripMapperOverride(memberID: $0.memberID, at: RoadTripPayload.date($0.at), ruleAnswer: $0.ruleAnswer)
        }
        return RoadTripReceivedCatchUp(state: RoadTripDeviceState(onCarPlay: mapper.onCarPlay, isCharging: mapper.isCharging),
                                       takeover: takeover, endedAt: catchUp.endedAt.map(RoadTripPayload.date))
    }

    /// The invite for `trip`, which this iPhone just started.
    static func invite(for trip: RoadTrip) -> RoadTripInvitePayload {
        RoadTripInvitePayload(tripID: trip.id, name: trip.name, starterID: trip.starterID,
                              members: trip.members.map { RoadTripWireMember(id: $0.id, firstName: $0.firstName) },
                              startedAt: RoadTripPayload.seconds(trip.startedAt))
    }

    /// The trip a Join makes of `invite` on this iPhone (`selfID`): every member at the start, each named as this
    /// iPhone knows them (`names`, by id) or else as the invite does, mapped by the rule over this iPhone's own
    /// state (`own`) until the first catch-up. Nil when it doesn't name this iPhone or wouldn't be a valid trip.
    static func trip(joining invite: RoadTripInvitePayload, selfID: String, names: [String: String],
                     own: RoadTripDeviceState) -> RoadTrip? {
        guard invite.isWellFormed, invite.members.contains(where: { $0.id == selfID }) else { return nil }
        let members = invite.members.prefix(RoadTrip.maxMembers).map {
            RoadTripMember(id: $0.id, firstName: names[$0.id].flatMap(RoadTripWire.firstName) ?? $0.firstName)
        }
        let ids = members.map(\.id)
        let mapper = RoadTripMapperRule.ruleAnswer(members: ids, starter: invite.starterID, states: [selfID: own]) ?? invite.starterID
        let startedAt = RoadTripPayload.date(invite.startedAt)
        let trip = RoadTrip(id: invite.tripID, name: invite.name, startedAt: startedAt, starterID: invite.starterID,
                            selfID: selfID, members: members, mapperID: mapper, mapperOverride: nil, lastCatchUp: startedAt,
                            endedAt: nil, leftAt: nil, atStart: ids, ledger: nil, states: [selfID: own], endToTell: nil)
        return trip.isValid ? trip : nil
    }

    /// `name` trimmed and cut to a member's bound; nil when nothing is left.
    static func firstName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(RoadTripMember.maxNameLength))
    }
}

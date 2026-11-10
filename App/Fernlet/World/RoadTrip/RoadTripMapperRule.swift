import Foundation

/// What a member's iPhone says about itself for the mapper rule (`rt-mapper`): whether it is on CarPlay and whether
/// it is charging (plugged in, charging or full). Read on this iPhone from the car keeper's route and the battery
/// (`FernletStore.roadTripDeviceState()`); the other members' arrive at a catch-up (PR 2).
///
/// Frozen at rest and on the wire (PR 2): `onCarPlay` and `isCharging` are field names.
nonisolated struct RoadTripDeviceState: Codable, Equatable, Sendable {
    /// Whether CarPlay is connected.
    var onCarPlay: Bool
    /// Whether the phone is plugged in.
    var isCharging: Bool

    /// Whether this state makes the phone the one to map: on CarPlay or charging.
    var mapsTheRoad: Bool { onCarPlay || isCharging }
}

/// Who maps the road (`rt-mapper`, owner's pick "auto", 2026-11-10): "The phone on CarPlay or charging maps. If none
/// or several are, the person who started. It switches by itself at a stop when that changes. Map from this iPhone
/// lets anyone take over."
///
/// Pure, so PR 2 feeds it every member's state at a catch-up; PR 1 knows only this iPhone's, and a member with no
/// state counts as neither on CarPlay nor charging.
nonisolated enum RoadTripMapperRule {
    /// The rule's own answer for `members` (ids, in the trip's order), started by `starter`, with `states` by member
    /// id: the one member whose phone is on CarPlay or charging; with none or several, the starter while they are on
    /// the trip, else the first member. Nil with no members.
    static func ruleAnswer(members: [String], starter: String, states: [String: RoadTripDeviceState]) -> String? {
        guard !members.isEmpty else { return nil }
        let mapping = members.prefix(RoadTrip.maxMembers).filter { states[$0]?.mapsTheRoad == true }
        if mapping.count == 1, let only = mapping.first { return only }
        return members.contains(starter) ? starter : members.first
    }

    /// Who maps now, and the override still in force: `override` holds while its member is on the trip and the rule
    /// answers what it answered when the override was made; otherwise it lapses and the rule's answer maps. Nil with
    /// no members.
    static func mapper(members: [String], starter: String, states: [String: RoadTripDeviceState],
                       override: RoadTripMapperOverride?) -> (mapper: String, override: RoadTripMapperOverride?)? {
        guard let answer = ruleAnswer(members: members, starter: starter, states: states) else { return nil }
        guard let override, members.contains(override.memberID), override.ruleAnswer == answer else { return (answer, nil) }
        return (override.memberID, override)
    }
}

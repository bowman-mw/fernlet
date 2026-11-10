import Foundation

/// A friend's catch-up as this iPhone applies it (World-RoadTrip-Spec PR 2): their phone's state for the mapper rule,
/// the "Map from this iPhone" they know of, and when the trip ended on their phone, if it did. The road is applied
/// apart (the keeper's line and the fog), filtered by ``RoadTripPresence``.
nonisolated struct RoadTripReceivedCatchUp: Equatable, Sendable {
    /// Their phone: on CarPlay, charging.
    let state: RoadTripDeviceState
    /// The newest takeover they know of.
    let takeover: RoadTripMapperOverride?
    /// When the trip ended on their phone.
    let endedAt: Date?
}

/// What a catch-up and an answer change in a trip record (World-RoadTrip-Spec §2.3, §2.5, §2.6, owner-approved
/// 2026-11-10). Pure, so each rule is tested as a value:
///
/// - **The ledger** (``applying(_:from:to:own:now:)``): the catch-up is recorded for this iPhone and the friend
///   (``RoadTripPresence/recording(catchUpWith:at:in:)``).
/// - **Who maps** (`rt-mapper`: "It switches by itself at a stop when that changes"): the friend's state joins what
///   this iPhone knows of each member's phone (its own fresh), the newer of the two takeovers holds while it names a
///   member, and ``RoadTripMapperRule`` decides; the passenger gate follows the record.
/// - **The end** (`rt-info`: "End the road trip ... ends it for everyone at their next catch-up"): a friend's end
///   ends the trip here; this iPhone then owes it to the members neither of them is known to have told. Every
///   catch-up with a member settles what was owed to them.
/// - **Not this time** (``removing(_:from:)``): a friend who said no, or whose phone is not on the trip, leaves the
///   record; the starter and this iPhone never do.
nonisolated enum RoadTripCatchUpRules {
    /// `trip` after `catchUp` from `member` at `now`, with this iPhone's own state `own`; unchanged when `member`
    /// isn't another member of it.
    static func applying(_ catchUp: RoadTripReceivedCatchUp, from member: String, to trip: RoadTrip,
                         own: RoadTripDeviceState, now: Date) -> RoadTrip {
        guard member != trip.selfID, trip.memberIDs.contains(member) else { return trip }
        var next = RoadTripPresence.recording(catchUpWith: [member], at: now, in: trip)
        var states = next.states ?? [:]
        states[member] = catchUp.state
        states[next.selfID] = own
        next.states = states
        next.endToTell = next.endToTell.map { $0.filter { $0 != member } }
        if next.isActive {
            next.mapperOverride = newer(next.mapperOverride, catchUp.takeover, members: next.memberIDs)
            if let decided = RoadTripMapperRule.mapper(members: next.memberIDs, starter: next.starterID, states: states,
                                                       override: next.mapperOverride) {
                next.mapperID = decided.mapper
                next.mapperOverride = decided.override
            }
        }
        if let ended = catchUp.endedAt, next.isActive {
            next.endedAt = max(ended, next.startedAt)
            next.endToTell = next.others.map(\.id).filter { $0 != member }
        }
        return next
    }

    /// The newer of two takeovers (by when it was made) that names a member; nil when neither does.
    static func newer(_ mine: RoadTripMapperOverride?, _ theirs: RoadTripMapperOverride?,
                      members: [String]) -> RoadTripMapperOverride? {
        let known = [mine, theirs].compactMap { $0 }.filter { members.contains($0.memberID) }
        return known.max { $0.at < $1.at }
    }

    /// "End the road trip" on this iPhone at `now`: the trip ends here and is owed to every other member.
    static func ending(_ trip: RoadTrip, now: Date) -> RoadTrip {
        guard trip.isActive else { return trip }
        var next = trip
        next.endedAt = max(now, trip.startedAt)
        next.endToTell = trip.others.map(\.id)
        return next
    }

    /// `trip` without `member` (they said Not this time, or their phone is not on the trip): out of the members and
    /// every PR 2 field, a takeover of theirs lapsing, and the mapper decided again when it was them. Unchanged for
    /// the starter, for this iPhone and for someone not on it.
    static func removing(_ member: String, from trip: RoadTrip) -> RoadTrip {
        guard member != trip.selfID, member != trip.starterID, trip.memberIDs.contains(member) else { return trip }
        var next = trip
        next.members.removeAll { $0.id == member }
        next.atStart = trip.atStart?.filter { $0 != member }
        next.ledger?[member] = nil
        next.states?[member] = nil
        next.endToTell = trip.endToTell?.filter { $0 != member }
        if next.mapperOverride?.memberID == member { next.mapperOverride = nil }
        if next.mapperID == member {
            next.mapperID = RoadTripMapperRule.ruleAnswer(members: next.memberIDs, starter: next.starterID,
                                                         states: next.states ?? [:]) ?? next.starterID
            next.mapperOverride = nil
        }
        return next
    }
}

import Foundation
import WorldMapStore

/// How a road trip ends on this iPhone and what its end adds up to (World-RoadTrip-Spec §2.9, `rt-end`, owner-approved
/// 2026-11-10: "The trip ends when someone taps End the road trip, when everyone has left, or by itself after 7 days
/// without a catch-up."). Pure, so each rule is tested as a value; End the road trip itself is
/// ``RoadTripCatchUpRules/ending(_:now:)``.
///
/// - **By itself** (``endingIfQuiet(_:now:)``): each iPhone, by its own clock, ends a trip still on once its last
///   catch-up is ``quietSeconds`` old. The end is the seven-day mark, not the moment the check ran. Nobody is owed it:
///   the others' phones count their own seven days. The quiet days also take this iPhone off the trip at the mark,
///   as Leave does, so a member it meets later hears it left rather than that the trip ended for everyone.
/// - **Everyone has left** (``markingLeft(_:in:now:)``): a member who left says so (their Leave, or their quiet end,
///   told at a catch-up); once every other member has, the trip ends here, owed to no one. A leaver who mapped hands
///   the road to the rule's next answer among those still on it.
/// - **The numbers** (``summary(of:line:uncovered:photos:towns:calendar:)``): the days, the road, the new tiles, the
///   towns and the photos, worked out once and kept in the trip's record (``RoadTripSummary``).
nonisolated enum RoadTripEndRules {
    /// How long a trip stays on without a catch-up: seven days, in seconds.
    static let quietSeconds: TimeInterval = 7 * 24 * 60 * 60
    /// How far apart along the road the towns are looked for, in metres (a town's core reaches 2 km).
    static let townSpacing = 500.0

    /// When `trip` ends by itself: its last catch-up and ``quietSeconds``.
    static func quietEnd(of trip: RoadTrip) -> Date {
        trip.lastCatchUp.addingTimeInterval(quietSeconds)
    }

    /// `trip` ended by its quiet days, when it is on and `now` is at or past the mark: ended and left at the mark, owed
    /// to no one. Nil while it is not due (or not on).
    static func endingIfQuiet(_ trip: RoadTrip, now: Date) -> RoadTrip? {
        guard trip.isActive else { return nil }
        let mark = quietEnd(of: trip)
        guard now >= mark else { return nil }
        var next = trip
        next.endedAt = mark
        next.leftAt = mark
        next.endToTell = nil
        return next
    }

    /// `trip` once `member` has said at `now` that they left: they are known to have left and owed nothing more; when
    /// they mapped, the rule decides again among the members still on it; and when every other member has left, the
    /// trip ends here at `now`, owed to no one. Unchanged for this iPhone, someone not on it, or a leave already heard.
    static func markingLeft(_ member: String, in trip: RoadTrip, now: Date) -> RoadTrip {
        guard member != trip.selfID, trip.memberIDs.contains(member), !(trip.othersLeft ?? []).contains(member) else { return trip }
        var next = trip
        next.othersLeft = Array(((trip.othersLeft ?? []) + [member]).prefix(RoadTrip.maxMembers))
        next.endToTell = trip.endToTell?.filter { $0 != member }
        guard next.isActive else { return next }
        guard !next.othersOnTrip.isEmpty else {
            next.endedAt = max(now, trip.startedAt)
            next.endToTell = nil
            return next
        }
        guard trip.mapperID == member || trip.mapperOverride?.memberID == member else { return next }
        if next.mapperOverride?.memberID == member { next.mapperOverride = nil }
        let decided = RoadTripMapperRule.mapper(members: next.onTripIDs, starter: next.starterID, states: next.states ?? [:],
                                                override: next.mapperOverride)
        next.mapperID = decided?.mapper ?? next.selfID
        next.mapperOverride = decided?.override
        return next
    }

    // MARK: The numbers

    /// The calendar days from `start` to `end`, both included, in `calendar` (a trip within one day is 1).
    static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let first = calendar.startOfDay(for: start), last = calendar.startOfDay(for: max(start, end))
        let span = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        return min(max(span + 1, 1), RoadTripSummary.maxDays)
    }

    /// The distinct towns and cities `points` (oldest first) pass: the place under the first point and then every
    /// ``townSpacing`` along the road, by `city` (the token of the town or city a place is in, or nil).
    static func towns(along points: [RoadTripPoint], city: (GeoPoint) -> String?) -> Int {
        var found = Set<String>()
        var sinceLook = Double.infinity
        var previous: GeoPoint?
        // R2: bounded by the line's own bound.
        for point in points.prefix(RoadTripLine.maxPoints) {
            if let previous { sinceLook += previous.distance(to: point.point) }
            previous = point.point
            guard sinceLook >= townSpacing else { continue }
            sinceLook = 0
            if let token = city(point.point) { found.insert(token) }
        }
        return found.count
    }

    /// The numbers of `trip` once it stopped being on: `line` its road on this iPhone (oldest first; points after the
    /// end left out), `uncovered` the tiles this iPhone has uncovered now (nil when the map can't be read), `photos`
    /// the trip photos it holds, and `towns` the atlas's city lookup (nil without an atlas). Nil while the trip is on.
    static func summary(of trip: RoadTrip, line: [RoadTripPoint], uncovered: Int?, photos: Int,
                        towns lookup: ((GeoPoint) -> String?)?, calendar: Calendar = .current) -> RoadTripSummary? {
        guard let end = trip.closedAt else { return nil }
        let road = line.prefix(RoadTripLine.maxPoints).filter { $0.at <= end }
        let newTiles = uncovered.flatMap { now in trip.cellsAtStart.map { max(0, now - $0) } }
        return RoadTripSummary(days: days(from: trip.startedAt, to: end, calendar: calendar),
                               metres: RoadTripLine.length(of: road, from: nil), newTiles: newTiles,
                               towns: lookup.map { towns(along: road, city: $0) }, photos: max(0, photos))
    }
}

import Foundation

/// Proof of presence (World-RoadTrip-Spec §2.6, owner-approved 2026-11-10): "you get only the road between two
/// catch-ups you were part of, plus from the start if you were there at the start."
///
/// Pure, over the trip record's ``RoadTrip/atStart`` and ``RoadTrip/ledger`` (the catch-ups this iPhone took part
/// in, per member, this one included):
///
/// - **What a member is sent** (``sendWindow(to:in:now:)``): this iPhone's road after the last catch-up it shared
///   with them (the start, when both were there) up to the catch-up being made now. That stretch lies between two
///   catch-ups they were part of: that one and this one. A member this iPhone never caught up with who was not at
///   the start is sent nothing now; this catch-up opens their stretch, and the next one closes it.
/// - **What this iPhone accepts** (``acceptWindow(in:now:)``): road from its own first presence (the start if it was
///   there, else its first catch-up) up to now, plus ``clockSkew`` for a friend's clock running ahead; anything
///   outside is dropped, whoever sent it.
/// - **Recording** (``recording(catchUpWith:at:in:)``): each catch-up joins the ledger for this iPhone and the
///   member; a second record within ``sameStop`` of the last (the offer and its reply, or a quick second tap) moves
///   that entry rather than adding one, and a full list moves its last entry, so a member's first presence is never
///   lost. Bounded: ``maxCatchUps`` entries a member.
nonisolated enum RoadTripPresence {
    /// The most catch-ups kept per member (a week's trip with a stop every hour is 168).
    static let maxCatchUps = 200
    /// Two records this close are one stop.
    static let sameStop: TimeInterval = 10 * 60
    /// How far past now a friend's point may be, for their clock running ahead, in seconds.
    static let clockSkew: TimeInterval = 5 * 60

    /// Whether `member` was at the trip's start (nil ``RoadTrip/atStart``: every member was).
    static func wasAtStart(_ member: String, in trip: RoadTrip) -> Bool {
        guard trip.memberIDs.contains(member) else { return false }
        return trip.atStart?.contains(member) ?? true
    }

    /// The catch-ups `member` was part of as this iPhone knows them, oldest first: the start when they were there,
    /// then the ledger's.
    static func presence(of member: String, in trip: RoadTrip) -> [Date] {
        let start = wasAtStart(member, in: trip) ? [trip.startedAt] : []
        return start + (trip.ledger?[member] ?? []).filter { $0 >= trip.startedAt }.sorted()
    }

    /// The last catch-up this iPhone shared with `member`: their ledger's last (every entry is one this iPhone took
    /// part in), else the start when both were there; nil when there is none.
    static func lastShared(with member: String, in trip: RoadTrip) -> Date? {
        if let last = (trip.ledger?[member] ?? []).filter({ $0 >= trip.startedAt }).max() { return last }
        guard wasAtStart(member, in: trip), wasAtStart(trip.selfID, in: trip) else { return nil }
        return trip.startedAt
    }

    /// The stretch of this iPhone's road `member` gets at a catch-up `now`: after the last catch-up this iPhone
    /// shared with them, through now. Nil when there is none, or when it would be empty.
    static func sendWindow(to member: String, in trip: RoadTrip, now: Date) -> (after: Date, through: Date)? {
        guard member != trip.selfID, trip.memberIDs.contains(member), let last = lastShared(with: member, in: trip),
              last < now else { return nil }
        return (last, now)
    }

    /// The road this iPhone accepts at a catch-up `now`: from its own first presence through now and the clock skew.
    /// Nil when it has no presence yet (it was not at the start and has caught up with no one).
    static func acceptWindow(in trip: RoadTrip, now: Date) -> (from: Date, through: Date)? {
        guard let first = presence(of: trip.selfID, in: trip).first else { return nil }
        return (first, now.addingTimeInterval(clockSkew))
    }

    /// `points` after `after` (exclusive) through `through`, in their order.
    static func points(_ points: [RoadTripPoint], after: Date, through: Date) -> [RoadTripPoint] {
        points.prefix(RoadTripLine.maxPoints).filter { $0.at > after && $0.at <= through }
    }

    /// `points` from `from` through `through` (both inclusive), in their order.
    static func points(_ points: [RoadTripPoint], from: Date, through: Date) -> [RoadTripPoint] {
        points.prefix(RoadTripLine.maxPoints).filter { $0.at >= from && $0.at <= through }
    }

    /// `trip` with a catch-up with `members` at `now` recorded for each of them and for this iPhone, and Trip info's
    /// last catch-up moved to it. Members not on the trip are skipped.
    static func recording(catchUpWith members: [String], at now: Date, in trip: RoadTrip) -> RoadTrip {
        let others = members.filter { $0 != trip.selfID && trip.memberIDs.contains($0) }
        guard !others.isEmpty, now >= trip.startedAt else { return trip }
        var next = trip
        var ledger = trip.ledger ?? [:]
        // R2: bounded by one trip's members.
        for member in (others + [trip.selfID]).prefix(RoadTrip.maxMembers + 1) {
            ledger[member] = recorded(now, in: ledger[member] ?? [])
        }
        next.ledger = ledger
        next.lastCatchUp = max(trip.lastCatchUp, now)
        return next
    }

    /// `entries` with `now` recorded: the last entry moved to it when it is within ``sameStop`` or the list is full,
    /// else appended.
    static func recorded(_ now: Date, in entries: [Date]) -> [Date] {
        var sorted = Array(entries.sorted().prefix(maxCatchUps))
        guard let last = sorted.last else { return [now] }
        guard now >= last else { return sorted }
        if now.timeIntervalSince(last) < sameStop || sorted.count >= maxCatchUps {
            sorted[sorted.count - 1] = now
        } else {
            sorted.append(now)
        }
        return sorted
    }
}

import Foundation

/// One person on a road trip (World-RoadTrip-Spec, owner-approved 2026-11-10): a stable id (their mesh signing
/// fingerprint, as the hangout knows it; this phone's own for "me") and their first name only.
///
/// Frozen at rest: `id` and `firstName` are field names.
nonisolated struct RoadTripMember: Codable, Equatable, Identifiable, Sendable {
    /// The longest id kept (a fingerprint string is far shorter).
    static let maxIDLength = 128
    /// The longest first name kept.
    static let maxNameLength = 40

    /// The member's stable id.
    let id: String
    /// Their first name, as the hangout showed it.
    let firstName: String

    /// Whether the id and name are present and within their bounds.
    var isValid: Bool {
        !id.isEmpty && id.count <= Self.maxIDLength && !firstName.isEmpty && firstName.count <= Self.maxNameLength
    }
}

/// "Map from this iPhone" (`rt-mapper`): who took over, when, and what the automatic rule answered then. At a stop
/// where the rule answers someone else (a phone went on CarPlay or onto a charger, or came off one), the override
/// lapses and the rule decides again (``RoadTripMapperRule/mapper(members:starter:states:override:)``).
///
/// Frozen at rest: the field names.
nonisolated struct RoadTripMapperOverride: Codable, Equatable, Sendable {
    /// The member who tapped "Map from this iPhone".
    let memberID: String
    /// When.
    let at: Date
    /// The member the rule chose when the override was made.
    let ruleAnswer: String
}

/// A road trip, as this iPhone keeps it (`rt-start`, `rt-mapper`, `rt-info`, `rt-end`): a Fernlet-level record that
/// spans a chain of short catch-up hangouts, since a hangout lasts at most six hours and a left one can't be rejoined.
///
/// - **Members:** up to ``maxMembers`` (one phone's direct links), this phone among them as ``selfID``.
/// - **Who maps:** ``mapperID``, decided by ``RoadTripMapperRule`` and overridden by ``mapperOverride``.
/// - **Catch-ups:** ``lastCatchUp`` starts at ``startedAt`` (everyone is together at the start).
/// - **The end:** ``endedAt`` (End the road trip, on any phone) or ``leftAt`` (this phone left); either way the record
///   and its line stay on this iPhone, sealed, until map history is deleted. An end this phone has not yet told a
///   member at a catch-up is ``endToTell`` (PR 2: "ends it for everyone at their next catch-up").
/// - **Proof of presence** (PR 2, `rt-catchup`): ``atStart`` and ``ledger`` say which catch-ups each member was part
///   of as this iPhone knows them (``RoadTripPresence``); ``states`` is each other member's phone as last heard at a
///   catch-up, for the mapper rule.
///
/// - **The end** (PR 4, `rt-end`): ``othersLeft`` are the other members this iPhone knows have left (told by them,
///   ``RoadTripEndRules/markingLeft(_:in:now:)``); once every other member has, the trip ends here. Seven days
///   without a catch-up end it here by itself (``RoadTripEndRules/endingIfQuiet(_:now:)``). ``cellsAtStart`` is
///   how much of the map this iPhone had uncovered when it started or joined, so the summary counts the new tiles;
///   ``summary`` is the end's numbers, worked out once, and ``summaryShown`` whether Home's card has shown.
///
/// Its line is kept apart, in pieces (``RoadTripLine``, `RoadTripStore`). Frozen at rest: the field names. The four
/// fields PR 2 added and the four PR 4 added are optional, so a book an earlier build wrote reads unchanged (nil:
/// every member at the start, no catch-up yet, no state heard, no end owed; nobody known to have left, the map at
/// the start not known, no summary yet, none shown).
nonisolated struct RoadTrip: Codable, Equatable, Identifiable, Sendable {
    /// The most people on one trip (one phone's direct links).
    static let maxMembers = 5
    /// The longest name the person can give a trip.
    static let maxNameLength = 60

    /// The trip's id (its line's files are bound to it).
    let id: UUID
    /// The person's own name for the trip; nil for the default ("Road trip" and the date, drawn, never stored).
    var name: String?
    /// When it started.
    let startedAt: Date
    /// Who started it.
    let starterID: String
    /// This iPhone's own member id.
    let selfID: String
    /// Everyone on the trip, this phone included.
    var members: [RoadTripMember]
    /// Whose iPhone maps the road now.
    var mapperID: String
    /// A "Map from this iPhone" still in force, if any.
    var mapperOverride: RoadTripMapperOverride?
    /// When this phone last caught up with another member (the start, before any stop).
    var lastCatchUp: Date
    /// When the trip ended, if it has.
    var endedAt: Date?
    /// When this phone left the trip, if it did.
    var leftAt: Date?
    /// The members who were at the start (they joined from the hangout it began in); nil for every member.
    var atStart: [String]? = nil
    /// This iPhone's catch-up ledger: for each member, this one included, when this iPhone caught up with them,
    /// oldest first (at most ``RoadTripPresence/maxCatchUps`` each).
    var ledger: [String: [Date]]? = nil
    /// Each other member's phone as last heard at a catch-up, for the mapper rule.
    var states: [String: RoadTripDeviceState]? = nil
    /// After the trip ended: the members this iPhone has not yet told at a catch-up.
    var endToTell: [String]? = nil
    /// The other members this iPhone knows have left the trip (PR 4), in the order it heard.
    var othersLeft: [String]? = nil
    /// How many tiles of the map this iPhone had uncovered when it started or joined the trip (PR 4); nil when the
    /// map couldn't be read then.
    var cellsAtStart: Int? = nil
    /// The end's numbers (PR 4), worked out once after the trip stopped being on here.
    var summary: RoadTripSummary? = nil
    /// Whether Home's summary card has shown (PR 4: "A summary card shows once on Home").
    var summaryShown: Bool? = nil

    /// Whether the trip is still on for this iPhone: not ended and not left.
    var isActive: Bool { endedAt == nil && leftAt == nil }

    /// When the trip stopped being on for this iPhone: the earlier of its end and this phone's leave; nil while on.
    var closedAt: Date? {
        switch (endedAt, leftAt) {
        case let (ended?, left?): min(ended, left)
        case let (ended?, nil): ended
        case let (nil, left?): left
        case (nil, nil): nil
        }
    }

    /// The members still on the trip as this iPhone knows it, in the trip's order: this one and every other member
    /// it hasn't heard has left.
    var onTripIDs: [String] {
        let left = Set(othersLeft ?? [])
        return memberIDs.filter { !left.contains($0) }
    }

    /// The other members still on the trip as this iPhone knows it, in the trip's order.
    var othersOnTrip: [RoadTripMember] {
        let left = Set(othersLeft ?? [])
        return others.filter { !left.contains($0.id) }
    }

    /// Whether this iPhone maps the road.
    var isMapping: Bool { mapperID == selfID }

    /// The other members, in the trip's order.
    var others: [RoadTripMember] { members.filter { $0.id != selfID } }

    /// The member whose iPhone maps, if they are on the trip.
    var mapper: RoadTripMember? { members.first { $0.id == mapperID } }

    /// The members' ids, in the trip's order.
    var memberIDs: [String] { members.map(\.id) }

    /// Whether every field is within its bounds and names a member: at most ``maxMembers``, no id twice, this phone,
    /// the starter and the mapper among them, a name no longer than ``maxNameLength``, and dates in order.
    var isValid: Bool {
        guard !members.isEmpty, members.count <= Self.maxMembers, members.allSatisfy(\.isValid) else { return false }
        let ids = Set(memberIDs)
        guard ids.count == members.count, ids.contains(selfID), ids.contains(starterID), ids.contains(mapperID) else { return false }
        if let name, name.isEmpty || name.count > Self.maxNameLength { return false }
        guard lastCatchUp >= startedAt else { return false }
        if let endedAt, endedAt < startedAt { return false }
        if let leftAt, leftAt < startedAt { return false }
        return presenceIsValid(members: ids)
    }

    /// Whether the PR 2 and PR 4 fields name only members, within their bounds: nobody left twice and never this
    /// iPhone, a count of tiles that isn't negative, and a summary within its own bounds.
    private func presenceIsValid(members ids: Set<String>) -> Bool {
        guard ids.isSuperset(of: atStart ?? []), ids.isSuperset(of: endToTell ?? []),
              ids.isSuperset(of: (ledger ?? [:]).keys), ids.isSuperset(of: (states ?? [:]).keys) else { return false }
        let left = othersLeft ?? []
        guard ids.isSuperset(of: left), !left.contains(selfID), Set(left).count == left.count,
              (cellsAtStart ?? 0) >= 0, summary?.isValid ?? true else { return false }
        return (ledger ?? [:]).values.allSatisfy { $0.count <= RoadTripPresence.maxCatchUps }
    }
}

/// The end's numbers (World-RoadTrip-Spec §2.9, `rt-end`: "Road trip to the coast · 3 days · 412 km · 1,280 new tiles
/// · 4 towns · 23 photos"), worked out once when the trip stopped being on for this iPhone and kept in its sealed
/// record, so they never drift and go with map history (``RoadTripEndRules/summary(of:line:uncovered:photos:towns:calendar:)``).
///
/// - ``days``: the calendar days the trip spans, start to end inclusive, in the local calendar then.
/// - ``metres``: the length of the trip's whole road as this iPhone holds it, its own and what it received, to the end.
/// - ``newTiles``: the tiles this iPhone first uncovered during the trip, walked, driven or received; nil when the map
///   couldn't be read at the start (the card leaves the row out).
/// - ``towns``: the distinct towns and cities the road passed, by the bundled atlas's city rule; nil when the atlas
///   isn't on this iPhone (the card leaves the row out).
/// - ``photos``: the trip photos this iPhone holds for the trip, its own and friends'.
///
/// Frozen at rest: the field names.
nonisolated struct RoadTripSummary: Codable, Equatable, Sendable {
    /// The most days a summary counts (a trip can't run longer than its book allows; a bound for the reader).
    static let maxDays = 10_000

    /// The calendar days, start to end inclusive.
    let days: Int
    /// The road, in metres.
    let metres: Double
    /// The tiles first uncovered during the trip; nil when not known.
    let newTiles: Int?
    /// The towns and cities passed; nil when the atlas isn't here.
    let towns: Int?
    /// The trip photos held.
    let photos: Int

    /// Whether every number is within its bounds.
    var isValid: Bool {
        (1...Self.maxDays).contains(days) && metres.isFinite && metres >= 0 && (newTiles ?? 0) >= 0 && (towns ?? 0) >= 0
            && photos >= 0
    }
}

/// Every road trip this iPhone keeps (`road-trips.bin`): at most one on at a time, the ended and left ones kept for
/// the passport's trips (PR 4) until map history is deleted. Bounded (Power of 10): at most ``maxTrips``; past it a
/// new trip is refused (``adding(_:)``), never an eviction of an old one.
///
/// Frozen at rest: `version` and `trips` are field names.
nonisolated struct RoadTripBook: Codable, Equatable, Sendable {
    /// The most trips kept.
    static let maxTrips = 100
    /// The format this build writes.
    static let currentVersion = 1
    /// No trips.
    static let empty = RoadTripBook(version: currentVersion, trips: [])

    /// The format the book was written in.
    let version: Int
    /// The trips, oldest first.
    private(set) var trips: [RoadTrip]

    /// The trip on now, if any (the newest one still on).
    var active: RoadTrip? { trips.last(where: \.isActive) }

    /// The trips no longer on for this iPhone (ended, or left), oldest first: the passport's road trips (PR 4).
    var closed: [RoadTrip] { trips.filter { !$0.isActive } }

    /// The trip whose summary card Home shows (PR 4: "A summary card shows once on Home"): the newest trip no longer
    /// on, once its numbers are in, until the card has shown; nil for none.
    var summaryToShow: RoadTrip? {
        guard let last = trips.last(where: { !$0.isActive }), last.summary != nil, last.summaryShown != true else { return nil }
        return last
    }

    /// The book with only valid trips, at most ``maxTrips`` (what a read keeps), and at most one on: an older trip
    /// still on beside a newer one is read as left when the newer one started.
    func validated() -> RoadTripBook {
        var kept = Array(trips.filter(\.isValid).suffix(Self.maxTrips))
        let onIndices = kept.indices.filter { kept[$0].isActive }
        for (position, index) in onIndices.enumerated() where position < onIndices.count - 1 {
            kept[index].leftAt = kept[onIndices[position + 1]].startedAt
        }
        return RoadTripBook(version: Self.currentVersion, trips: kept)
    }

    /// The book with `trip` added, or nil when it isn't valid, another trip is on, its id is taken or the book is full.
    func adding(_ trip: RoadTrip) -> RoadTripBook? {
        guard trip.isValid, trip.isActive, active == nil, trips.count < Self.maxTrips,
              !trips.contains(where: { $0.id == trip.id }) else { return nil }
        var next = self
        next.trips.append(trip)
        return next
    }

    /// The book with the trip on now changed by `change`, or nil with none on or when the change leaves it invalid.
    func changingActive(_ change: (inout RoadTrip) -> Void) -> RoadTripBook? {
        guard let id = active?.id else { return nil }
        return changing(id, change)
    }

    /// The book with the trip `id` changed by `change`, or nil without it, when the change leaves it invalid or
    /// changes its id, or when it would leave two trips on.
    func changing(_ id: UUID, _ change: (inout RoadTrip) -> Void) -> RoadTripBook? {
        guard let index = trips.lastIndex(where: { $0.id == id }) else { return nil }
        var next = self
        change(&next.trips[index])
        guard next.trips[index].id == id, next.trips[index].isValid, next.trips.filter(\.isActive).count <= 1 else { return nil }
        return next
    }

    /// The trip `member` and this iPhone share for a catch-up. Without `id` (a commit, Catch up now): the trip on now
    /// when they are another member of it, else the newest trip, when it ended and still owes them its end. With `id`
    /// (their catch-up names it): that trip, on or ended, while this iPhone has not left it and they are on it, so a
    /// friend who missed the end is answered with it.
    func trip(sharedWith member: String, id: UUID? = nil) -> RoadTrip? {
        if let id {
            guard let trip = trips.last(where: { $0.id == id }), trip.leftAt == nil,
                  trip.others.contains(where: { $0.id == member }) else { return nil }
            return trip
        }
        if let trip = active, trip.others.contains(where: { $0.id == member }) { return trip }
        guard let last = trips.last, last.leftAt == nil, last.endedAt != nil,
              last.endToTell?.contains(member) == true else { return nil }
        return last
    }
}

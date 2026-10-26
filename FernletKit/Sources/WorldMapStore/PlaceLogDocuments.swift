import Foundation

/// "Where you've been" as it is sealed under the Private tab's hub key (`b2-where-been`): the rolling
/// 30-day timeline of stops, and Places you return to (a visit count each, never dates).
///
/// Bounded: at most ``maxPlaces`` places (a new place past it is not added) and ``maxStops`` stops (the
/// oldest go first), and no stop older than ``keptDays`` days survives a fold.
///
/// Frozen at rest: `schemaVersion`, `places` and `stops` are field names. Format 2 (World build round 5)
/// keeps a place's reference and the person's own name, never the lookup's name or kind; a format-1 log
/// reads with those dropped (``PlaceRecord``) and is sealed again as format 2 at once
/// (``PlaceLogStore/log(hubKey:)``).
public nonisolated struct PlaceLog: Codable, Equatable, Sendable {
    /// The format this build writes.
    public static let currentSchema = 2
    /// The oldest format this build still reads (and rewrites in the current one).
    public static let oldestReadableSchema = 1
    /// How many days the timeline keeps.
    public static let keptDays = 30
    /// The most places kept.
    public static let maxPlaces = 300
    /// The most stops kept.
    public static let maxStops = 2_000
    /// An empty log.
    public static let empty = PlaceLog(places: [], stops: [])

    public var schemaVersion: Int
    /// Places you return to.
    public var places: [PlaceRecord]
    /// The timeline, oldest first.
    public var stops: [PlaceStop]

    /// A log in the current format.
    public init(places: [PlaceRecord], stops: [PlaceStop]) {
        self.schemaVersion = Self.currentSchema
        self.places = places
        self.stops = stops
    }

    /// This log with the device side's captures folded in at `now`: new places added (up to the cap), each
    /// stop added once (a stop already here, from a fold cut short, is skipped and not counted again), each
    /// visit counted on its place, then stops older than ``keptDays`` days dropped. A stop that waited longer
    /// than the timeline keeps (Private not opened for 30 days) is neither added nor counted.
    public func folding(_ device: PlaceDeviceState, now: Date, calendar: Calendar = .current) -> PlaceLog {
        var next = self
        let known = Set(places.map(\.id))
        for place in device.newPlaces where !known.contains(place.id) && next.places.count < Self.maxPlaces {
            next.places.append(PlaceRecord(id: place.id, label: place.label, placeID: place.placeID, point: place.point))
        }
        let seen = Set(stops.map(\.id))
        let firstDay = Self.firstDay(now: now, calendar: calendar)
        for stop in device.pending where !seen.contains(stop.id) && stop.at >= firstDay {
            // A visit to a place the timeline already has a visit to within three hours is the same visit
            // (the map opened again there after Private folded the first one).
            if stop.kind == .visit, next.stops.contains(where: { $0.isSameVisit(as: stop) }) { continue }
            if stop.kind == .visit, let place = stop.placeID {
                guard let index = next.places.firstIndex(where: { $0.id == place }) else { continue }
                next.places[index].visits += 1
            }
            next.stops.append(stop)
        }
        next.stops.sort { $0.at < $1.at }
        return next.pruned(now: now, calendar: calendar)
    }

    /// This log without stops from before the timeline's first day, and at most ``maxStops`` of them.
    public func pruned(now: Date, calendar: Calendar = .current) -> PlaceLog {
        var next = self
        let firstDay = Self.firstDay(now: now, calendar: calendar)
        next.stops.removeAll { $0.at < firstDay }
        if next.stops.count > Self.maxStops { next.stops.removeFirst(next.stops.count - Self.maxStops) }
        return next
    }

    /// The start of the timeline's first day at `now` (the 30 days include today).
    static func firstDay(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -(keptDays - 1), to: calendar.startOfDay(for: now)) ?? now
    }

    /// The days that have stops, newest first.
    public func days(calendar: Calendar = .current) -> [Date] {
        let starts = Set(stops.map { calendar.startOfDay(for: $0.at) })
        return starts.sorted(by: >)
    }

    /// The stops on the day that starts at `day`, in time order.
    public func stops(on day: Date, calendar: Calendar = .current) -> [PlaceStop] {
        stops.filter { calendar.isDate($0.at, inSameDayAs: day) }
    }

    /// Places you return to, most visited first (the person's names, then the order they were first
    /// visited in, break ties), without places no visit is left on.
    public var returnedTo: [PlaceRecord] {
        let order = Dictionary(places.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return places.filter { $0.visits > 0 }.sorted { lhs, rhs in
            if lhs.visits != rhs.visits { return lhs.visits > rhs.visits }
            if lhs.label != rhs.label { return (lhs.label ?? "\u{10FFFF}") < (rhs.label ?? "\u{10FFFF}") }
            return order[lhs.id, default: 0] < order[rhs.id, default: 0]
        }
    }

    /// This log without the stops on `day`: each visit taken off its place's count, and a place left with
    /// no visits removed. The walk and run workouts whose stops went, so their saved lines can go too.
    public func deletingDay(_ day: Date, calendar: Calendar = .current) -> (log: PlaceLog, workoutIDs: [UUID], removedPlaces: Set<UUID>) {
        var next = self
        let going = stops(on: day, calendar: calendar)
        let ids = Set(going.map(\.id))
        next.stops.removeAll { ids.contains($0.id) }
        for stop in going where stop.kind == .visit {
            guard let place = stop.placeID, let index = next.places.firstIndex(where: { $0.id == place }) else { continue }
            next.places[index].visits = max(0, next.places[index].visits - 1)
        }
        let emptied = Set(next.places.filter { $0.visits == 0 }.map(\.id))
        next.places.removeAll { emptied.contains($0.id) }
        return (next, going.compactMap(\.workoutID), emptied)
    }

    /// This log with place `id` given the person's own name `name` (trimmed, at most
    /// ``PlaceRecord/maxNameLength``), its label from now on; an empty name changes nothing.
    public func renaming(_ id: UUID, to name: String) -> PlaceLog {
        guard let label = PlaceRecord.validLabel(name), let index = places.firstIndex(where: { $0.id == id }) else { return self }
        var next = self
        next.places[index].label = label
        return next
    }

    /// This log in the current format: a log read from an older one (whose records' lookup names and kinds
    /// were dropped as it was read) is marked current, so it is sealed again without them.
    public var migrated: PlaceLog {
        var next = self
        next.schemaVersion = Self.currentSchema
        return next
    }

    /// How long the person was out and about on the day that starts at `day` (`ref-home-where`): from each
    /// time they left a home or their hotel to the next time they got back that day. Nil when no leave was
    /// followed by a return that day.
    public func outAndAbout(on day: Date, calendar: Calendar = .current) -> TimeInterval? {
        var total: TimeInterval = 0
        var leftAt: Date?
        for stop in stops(on: day, calendar: calendar) {
            switch stop.kind {
            case .leftHome: leftAt = stop.at
            case .cameHome:
                if let leftAt, stop.at > leftAt { total += stop.at.timeIntervalSince(leftAt) }
                leftAt = nil
            case .visit, .walk, .run: continue
            }
        }
        return total > 0 ? total : nil
    }
}

/// The places log's device side, sealed under the map vault's after-first-unlock buffer key: what was
/// captured while Private was closed, waiting to be folded under the hub key, and the allowed places'
/// points and references (no names) that visits are matched against.
///
/// Bounded: at most ``maxPending`` stops wait (the oldest go first) and at most ``PlaceLog/maxPlaces`` places
/// are known.
///
/// World build round 6 adds two optional parts that live only here, because the map reads them with
/// Private closed (and Always mode's visits with the phone locked): the person's homes and hotel
/// (``homes``) and the places they eat out at (``restaurants``). Neither is ever folded into the log.
///
/// Frozen at rest: `schemaVersion`, `known`, `pending`, `newPlaces`, `homes` and `restaurants` are field
/// names. A first-format state (no `schemaVersion`; its new places held the lookup's names and kinds) reads
/// with those dropped and is sealed again at once (``PlaceLogStore/deviceState()``).
public nonisolated struct PlaceDeviceState: Codable, Equatable, Sendable {
    /// The format this build writes.
    public static let currentSchema = 2
    /// The most stops that wait for a fold.
    public static let maxPending = 500
    /// How near a reading must be to a known place to count as being there, in metres.
    public static let matchRadius = 75.0
    /// How long after a visit to a place another visit there counts as the same one.
    public static let sameVisitWindow: TimeInterval = 3 * 60 * 60
    /// Nothing known, nothing waiting.
    public static let empty = PlaceDeviceState(known: [], pending: [], newPlaces: [])

    /// The format it was written in; nil for the first format.
    public var schemaVersion: Int?
    /// The allowed places' points and references.
    public var known: [KnownPlace]
    /// Stops waiting to be folded, oldest first.
    public var pending: [PlaceStop]
    /// New places (a point and a reference, and the person's own name for a place they added), waiting to
    /// be folded.
    public var newPlaces: [PlaceRecord]
    /// The homes and hotel (round 6); nil until one is marked.
    public var homes: HomeBook?
    /// The places the person eats out at (round 6); nil until a meal is noted at one.
    public var restaurants: [EatingPlace]?

    /// A device state in the current format.
    public init(known: [KnownPlace], pending: [PlaceStop], newPlaces: [PlaceRecord], homes: HomeBook? = nil,
                restaurants: [EatingPlace]? = nil) {
        self.schemaVersion = Self.currentSchema
        self.known = known
        self.pending = pending
        self.newPlaces = newPlaces
        self.homes = homes
        self.restaurants = restaurants
    }

    /// The homes and hotel (empty when none was ever marked).
    public var homeBook: HomeBook { homes ?? .empty }

    /// The places to eat (none until a meal was noted at one).
    public var eatingPlaces: [EatingPlace] { restaurants ?? [] }

    /// This state with `book` as the homes and hotel.
    public func withHomes(_ book: HomeBook) -> PlaceDeviceState {
        var next = self
        next.homes = book
        return next
    }

    /// This state with `meal` noted at the place to eat `id` (Apple's reference `placeID`, the person's
    /// point `point`), which is added when new (up to ``EatingPlace/maxPlaces``). A meal already noted
    /// anywhere is not noted again.
    public func notingMeal(_ meal: EatingMeal, at id: UUID, placeID: String, point: GeoPoint) -> PlaceDeviceState {
        var places = eatingPlaces
        guard !places.hasNoted(meal.id) else { return self }
        if let index = places.firstIndex(where: { $0.id == id || $0.placeID == placeID }) {
            places[index] = places[index].noting(meal)
        } else {
            guard places.count < EatingPlace.maxPlaces else { return self }
            places.append(EatingPlace(id: id, placeID: placeID, point: point).noting(meal))
        }
        var next = self
        next.restaurants = places
        return next
    }

    /// This state with the place to eat `id` given the person's own name (a rename in Where you've been
    /// reaches the map's bowl too); an empty name changes nothing.
    public func renamingEatingPlace(_ id: UUID, to name: String) -> PlaceDeviceState {
        guard let label = PlaceRecord.validLabel(name), let index = eatingPlaces.firstIndex(where: { $0.id == id }) else { return self }
        var next = self
        next.restaurants?[index].label = label
        return next
    }

    /// Whether it was read from an older format and must be sealed again in the current one.
    public var needsMigration: Bool { schemaVersion != Self.currentSchema }

    /// The known place nearest `point` within ``matchRadius``, or nil.
    public func knownPlace(near point: GeoPoint) -> KnownPlace? {
        known.map { (place: $0, metres: $0.point.distance(to: point)) }
            .filter { $0.metres <= Self.matchRadius }
            .min { $0.metres < $1.metres }?.place
    }

    /// The known place the lookup refers to as `placeID`, or nil (none given, or none known).
    public func knownPlace(withPlaceID placeID: String?) -> KnownPlace? {
        guard let placeID else { return nil }
        return known.first { $0.placeID == placeID }
    }

    /// This state with a visit to `place` at `date`, unless one is already waiting there from the last
    /// ``sameVisitWindow`` (a visit Private already folded is caught by the fold itself, ``PlaceLog/folding(_:now:calendar:)``).
    public func recordingVisit(to place: UUID, at date: Date) -> PlaceDeviceState {
        let visit = PlaceStop(kind: .visit, at: date, placeID: place)
        guard !pending.contains(where: { $0.isSameVisit(as: visit) }) else { return self }
        return appending(visit)
    }

    /// This state with a new place learned at its first visit, `date`: known for matching, its record waiting
    /// for the fold, and the visit itself. Unchanged when ``PlaceLog/maxPlaces`` places are already known.
    public func learning(_ place: PlaceRecord, at date: Date) -> PlaceDeviceState {
        guard known.count < PlaceLog.maxPlaces else { return self }
        var next = self
        next.known.append(KnownPlace(id: place.id, point: place.point, placeID: place.placeID))
        next.newPlaces.append(place)
        return next.appending(PlaceStop(kind: .visit, at: date, placeID: place.id))
    }

    /// This state with `stop` waiting, the oldest dropped past ``maxPending``.
    public func appending(_ stop: PlaceStop) -> PlaceDeviceState {
        var next = self
        next.pending.append(stop)
        if next.pending.count > Self.maxPending { next.pending.removeFirst(next.pending.count - Self.maxPending) }
        return next
    }

    /// This state after a fold: nothing waits; the known points, the homes and the places to eat stay.
    public var folded: PlaceDeviceState {
        PlaceDeviceState(known: known, pending: [], newPlaces: [], homes: homes, restaurants: restaurants)
    }

    /// This state without the known places in `ids` (a day's delete emptied them), nor their meals out.
    public func forgetting(_ ids: Set<UUID>) -> PlaceDeviceState {
        guard !ids.isEmpty else { return self }
        var next = self
        next.known.removeAll { ids.contains($0.id) }
        next.newPlaces.removeAll { ids.contains($0.id) }
        next.pending.removeAll { $0.placeID.map(ids.contains) ?? false }
        next.restaurants?.removeAll { ids.contains($0.id) }
        return next
    }

    /// What "Delete all of it" leaves: the homes and hotel alone, which stay until they are removed in
    /// Settings › Home map (the approved policy sentence).
    public var keepingOnlyHomes: PlaceDeviceState {
        PlaceDeviceState(known: [], pending: [], newPlaces: [], homes: homes)
    }
}

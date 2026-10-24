import Foundation

/// "Where you've been" as it is sealed under the Private tab's hub key (`b2-where-been`): the rolling
/// 30-day timeline of stops, and Places you return to (a visit count each, never dates).
///
/// Bounded: at most ``maxPlaces`` places (a new place past it is not added) and ``maxStops`` stops (the
/// oldest go first), and no stop older than ``keptDays`` days survives a fold.
///
/// Frozen at rest: `schemaVersion`, `places` and `stops` are field names.
public nonisolated struct PlaceLog: Codable, Equatable, Sendable {
    /// The format this build writes and reads.
    public static let currentSchema = 1
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
            next.places.append(PlaceRecord(id: place.id, name: place.name, category: place.category, point: place.point))
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

    /// Places you return to, most visited first (names break ties), without places no visit is left on.
    public var returnedTo: [PlaceRecord] {
        places.filter { $0.visits > 0 }.sorted { ($0.visits, $1.name) > ($1.visits, $0.name) }
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

    /// This log with place `id` renamed to `name` (trimmed, at most ``PlaceRecord/maxNameLength``); an empty
    /// name changes nothing.
    public func renaming(_ id: UUID, to name: String) -> PlaceLog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = places.firstIndex(where: { $0.id == id }) else { return self }
        var next = self
        next.places[index].name = String(trimmed.prefix(PlaceRecord.maxNameLength))
        return next
    }
}

/// The places log's device side, sealed under the map vault's after-first-unlock buffer key: what was
/// captured while Private was closed, waiting to be folded under the hub key, and the allowed places'
/// points (no names) that background visits are matched against.
///
/// Bounded: at most ``maxPending`` stops wait (the oldest go first) and at most ``PlaceLog/maxPlaces`` places
/// are known.
///
/// Frozen at rest: `known`, `pending` and `newPlaces` are field names.
public nonisolated struct PlaceDeviceState: Codable, Equatable, Sendable {
    /// The most stops that wait for a fold.
    public static let maxPending = 500
    /// How near a reading must be to a known place to count as being there, in metres.
    public static let matchRadius = 75.0
    /// How long after a visit to a place another visit there counts as the same one.
    public static let sameVisitWindow: TimeInterval = 3 * 60 * 60
    /// Nothing known, nothing waiting.
    public static let empty = PlaceDeviceState(known: [], pending: [], newPlaces: [])

    /// The allowed places' points.
    public var known: [KnownPlace]
    /// Stops waiting to be folded, oldest first.
    public var pending: [PlaceStop]
    /// New places' names and points, waiting to be folded.
    public var newPlaces: [PlaceRecord]

    /// A device state.
    public init(known: [KnownPlace], pending: [PlaceStop], newPlaces: [PlaceRecord]) {
        self.known = known
        self.pending = pending
        self.newPlaces = newPlaces
    }

    /// The known place nearest `point` within ``matchRadius``, or nil.
    public func knownPlace(near point: GeoPoint) -> KnownPlace? {
        known.map { (place: $0, metres: $0.point.distance(to: point)) }
            .filter { $0.metres <= Self.matchRadius }
            .min { $0.metres < $1.metres }?.place
    }

    /// This state with a visit to `place` at `date`, unless one is already waiting there from the last
    /// ``sameVisitWindow`` (a visit Private already folded is caught by the fold itself, ``PlaceLog/folding(_:now:calendar:)``).
    public func recordingVisit(to place: UUID, at date: Date) -> PlaceDeviceState {
        let visit = PlaceStop(kind: .visit, at: date, placeID: place)
        guard !pending.contains(where: { $0.isSameVisit(as: visit) }) else { return self }
        return appending(visit)
    }

    /// This state with a new place learned at its first visit, `date`: known for matching, its name waiting
    /// for the fold, and the visit itself. Unchanged when ``PlaceLog/maxPlaces`` places are already known.
    public func learning(_ place: PlaceRecord, at date: Date) -> PlaceDeviceState {
        guard known.count < PlaceLog.maxPlaces else { return self }
        var next = self
        next.known.append(KnownPlace(id: place.id, category: place.category, point: place.point))
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

    /// This state after a fold: nothing waits; the known points stay.
    public var folded: PlaceDeviceState {
        PlaceDeviceState(known: known, pending: [], newPlaces: [])
    }

    /// This state without the known places in `ids` (a day's delete emptied them).
    public func forgetting(_ ids: Set<UUID>) -> PlaceDeviceState {
        guard !ids.isEmpty else { return self }
        var next = self
        next.known.removeAll { ids.contains($0.id) }
        next.newPlaces.removeAll { ids.contains($0.id) }
        next.pending.removeAll { $0.placeID.map(ids.contains) ?? false }
        return next
    }
}

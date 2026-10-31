import Foundation

/// Where the flight detector learns which airports' grounds hold a point (World-Airports-Spec §2): the
/// bundled ``WorldAirports`` in the app, a few made-up airports in tests.
public nonisolated protocol AirportGroundsLookup {
    /// Every unlockable airport whose grounds hold `point`.
    func airports(containing point: GeoPoint) -> [WorldAirport]
}

extension WorldAirports: AirportGroundsLookup {}

/// One location reading as the flight detector reads it, in plain values (no CoreLocation type reaches
/// WorldMapStore).
public nonisolated struct FlightFix: Equatable, Sendable {
    /// Where.
    public var point: GeoPoint
    /// When it was taken.
    public var at: Date
    /// Its horizontal accuracy, in metres (smaller is better; negative means iOS has no fix, and the reading
    /// is passed by).
    public var accuracy: Double
    /// CoreLocation's own speed for it, in metres a second; nil (or negative) when it gave none.
    public var speed: Double?

    public init(point: GeoPoint, at: Date, accuracy: Double, speed: Double? = nil) {
        self.point = point
        self.at = at
        self.accuracy = accuracy
        self.speed = speed
    }
}

/// How an airport was found (spec §3, §7).
public nonisolated enum FlightFinding: String, Equatable, Sendable {
    /// Ten minutes inside a large airport's own approved outline.
    case dwell
    /// A reading inside its grounds during a trip: a ticket, or a trip a flight began (§7 "Without the button":
    /// a flight found by its speed does everything a ticket does).
    case ticket
    /// The airport a flight found by its speed (or a gap) left from, when no trip had found it yet.
    case takeOff
    /// The first reading at it after a flight.
    case landing
}

/// What one reading, a ticket or an ended trip changed. A call's events come in the order they happened.
public nonisolated enum FlightEvent: Equatable, Sendable {
    /// An airport was found: the passport stamps it if it's new (it alone knows which are; the detector says
    /// each way at most once per stay, landing or trip).
    case airportFound(token: String, how: FlightFinding, at: Date)
    /// A flight began. `from` is the airport it left, when known; `departed` is the take-off as best known (the
    /// last reading on the ground there, or the first reading in the air when no airport is known).
    case flightStarted(from: String?, departed: Date)
    /// A flight ended at an airport: its two airports and times are all that's remembered of it (§6.1).
    case landed(token: String, from: String?, departed: Date, at: Date)
    /// A flight ended away from any listed airport (a few minutes on the ground, or a day without a landing).
    case endedWithoutAirport(from: String?, departed: Date, at: Date)
    /// The person flew on from the airport they landed at without leaving its grounds: it was a layover, and
    /// its stamp says TRANSIT (§4.2).
    case layoverBecameTransit(token: String, at: Date)
    /// The person left the grounds of the airport they landed at: an arrival. Only now may its country and
    /// continent stamp (§4.2, the owner's note on 9).
    case arrived(token: String, at: Date)
    /// A trip began: by the ticket, or by a flight found by its speed.
    case tripStarted(at: Date, byTicket: Bool)
    /// A trip ended: by the person, or on getting home.
    case tripEnded(at: Date)
}

/// The detector's answer for one reading.
public nonisolated struct FlightVerdict: Equatable, Sendable {
    /// Whether the reading may reach the fog, the passport, the route store or Private history. False while
    /// flying, for a reading that may be in the air, and for any reading the detector passed by.
    public let mayKeep: Bool
    /// What changed.
    public let events: [FlightEvent]
    /// The nearest airport whose grounds hold a kept reading (Private history's "At an airport", friends'
    /// silence at airports, §11); nil outside grounds or when not kept.
    public let airport: String?

    public init(mayKeep: Bool, events: [FlightEvent], airport: String?) {
        self.mayKeep = mayKeep
        self.events = events
        self.airport = airport
    }

    /// A reading passed by: refused, changing nothing.
    public static let ignored = FlightVerdict(mayKeep: false, events: [], airport: nil)
}

/// Whether the person is flying, landed or on the ground, from the phone's own readings alone
/// (World-Airports-Spec §3, §5, §6, §7). A pure value: no network, no CoreLocation, no timers; time comes only
/// from readings' timestamps. The app's location keepers ask it about every reading before the reading may
/// reach the fog, the passport, the route store or Private history, and save it (it is `Codable`, and holds
/// a fixed handful of values plus at most ``maxTripFinds`` airport tokens) across relaunches.
///
/// - **Speed:** a good reading (within ``goodAccuracy``) has a speed: CoreLocation's own, else the pace from
///   the last good reading at least ``minPaceTime`` before it (within ``pairTime``), counting only the distance
///   beyond both readings' accuracy, as the car and bike rule does. Other readings have no speed.
/// - **Grounds:** only a reading within ``placedAccuracy`` is placed inside or outside an airport's grounds.
/// - **A flight starts** (§6.1) at any reading over ``anywhereSpeed`` (450 km/h), anywhere; or at a reading
///   outside every airport's grounds over ``takeOffSpeed`` (300 km/h) within ``departureWindow`` of the last
///   reading on the ground inside an airport's grounds (a reading there under ``groundSpeed``, or with no
///   speed). 300, not lower, so a high-speed train (250–350 km/h) isn't taken for a plane; and a train
///   rushing through grounds never counts as being there, so it never leaves them.
/// - **The gap rule** (§6.1, common in flight mode): the last placed reading within ``nearAirportMetres`` of
///   an airport whose grounds held the person within ``departureWindow`` before it, and then a reading more
///   than ``gapMinMetres`` away, is a flight from that airport: one that has landed, when the reading is inside
///   another airport's grounds and the implied speed is within ``gapLandingSpeeds`` (150–1,000 km/h); one still
///   on, when it is inside no grounds and the implied speed is within ``gapAwaySpeeds`` (300–1,000 km/h).
/// - **While flying** every reading is refused, nothing is found or stamped, and only the flight's two
///   airports and times come out. It **ends** at the first placed reading inside an airport's grounds that
///   is on the ground (under ``groundSpeed``, or with no speed and no reading in the ``pairTime`` before it
///   implying more): a landing, which finds that airport at once. Or it ends after readings under
///   ``groundSpeed`` span ``slowEndTime`` (5 minutes) with no fast one between, or at a reading more than
///   ``longestFlight`` after take-off: ended without an airport.
/// - **Landed:** while readings stay inside the grounds it's a layover (``layoverDuration(at:)``). Flying on
///   makes it a transit; a reading outside the grounds that is surely slow (its speed, or the pace implied
///   from the last placed reading, under ``groundSpeed``) makes it an arrival.
/// - **On the ground,** a reading over ``takeOffSpeed``, or over ``groundSpeed`` outside grounds within
///   ``departureWindow`` of being at an airport, is refused even before a flight is found: it may be a
///   climb-out, and nothing at that speed feeds the fog.
/// - **Ten minutes at a large airport** (§3): readings within ``dwellAccuracy`` inside a large airport's own
///   approved outline, none faster than ``walkingSpeed`` and none more than ``dwellMaxGap`` apart, spanning
///   ``dwellTime``, find it. A car crossing it, or any reading outside it, starts the count again; vaguer
///   readings neither count nor break it. Medium airports, and large ones without our outline, never count by
///   time.
/// - **Trips** (§5, §7): a ticket (``startTrip(at:)``) or a flight found by its speed starts one. During a
///   trip the first placed reading inside each airport's grounds finds it (``FlightFinding/ticket``), and the
///   travel look shows inside grounds (``showsTravelLook``). A trip ends by ``endTrip(at:)``, or at the first
///   placed reading at home (the caller's `isHome`) once the trip has been to an airport or flown. The
///   destination the person types is never given to the detector: it is kept only in the passport's sealed
///   backup (§7 "Kept"), and this state is saved outside it.
/// - **Passed by:** a reading with an invalid point or accuracy, or not newer than the last one (out of order
///   or a duplicate), is refused and changes nothing.
public nonisolated struct FlightDetector: Codable, Equatable, Sendable {
    // MARK: Thresholds

    /// Faster than this, outside grounds and just after an airport, is a take-off (300 km/h), in m/s.
    public static let takeOffSpeed = 300.0 / 3.6
    /// Faster than this anywhere is a flight (450 km/h), in m/s.
    public static let anywhereSpeed = 450.0 / 3.6
    /// Slower than this is on the ground (150 km/h), in m/s.
    public static let groundSpeed = 150.0 / 3.6
    /// How long readings under ``groundSpeed`` must span to end a flight away from any airport.
    public static let slowEndTime: TimeInterval = 5 * 60
    /// How soon after the last reading on the ground at an airport a take-off still counts as leaving it
    /// (and the gap rule's last reading must fall).
    public static let departureWindow: TimeInterval = 15 * 60
    /// How long after the last reading at an airport a flight found at ``anywhereSpeed`` still names it as the
    /// airport it left (flight mode can hide hours of a flight).
    public static let departureLookBack: TimeInterval = 6 * 60 * 60
    /// A slow reading farther than this from the airport last stood at means the person went elsewhere by
    /// land: no later flight names it. The gap rule's last reading must be this close to it.
    public static let nearAirportMetres = 30_000.0
    /// The gap rule's least distance between the readings either side of the gap.
    public static let gapMinMetres = 150_000.0
    /// The gap rule's implied speeds, in m/s, for a gap that ends at another airport (150–1,000 km/h).
    public static let gapLandingSpeeds: ClosedRange<Double> = (150.0 / 3.6)...(1_000.0 / 3.6)
    /// The gap rule's implied speeds, in m/s, for a gap that ends at no airport (300–1,000 km/h).
    public static let gapAwaySpeeds: ClosedRange<Double> = (300.0 / 3.6)...(1_000.0 / 3.6)
    /// The longest gap a pace is measured over; and a reading at an airport while flying with a reading this
    /// recently before it is judged by the pace between them.
    public static let pairTime: TimeInterval = 2 * 60
    /// The shortest time a pace is measured over (a second's GPS jitter is no speed).
    public static let minPaceTime: TimeInterval = 10
    /// The worst accuracy a reading may have to have a speed, in metres (the car and bike rule's).
    public static let goodAccuracy = 65.0
    /// The worst accuracy a reading may have to be placed inside or outside grounds, in metres.
    public static let placedAccuracy = 500.0
    /// The worst accuracy a reading may have to count toward ten minutes at a large airport, in metres.
    public static let dwellAccuracy = 100.0
    /// The fastest pace that still counts toward ten minutes at a large airport (walking), in m/s.
    public static let walkingSpeed = 2.5
    /// How long inside a large airport's own outline finds it (§3).
    public static let dwellTime: TimeInterval = 10 * 60
    /// The longest gap between two readings that keeps the ten minutes continuous.
    public static let dwellMaxGap: TimeInterval = 5 * 60
    /// A flight with no landing this long after take-off has ended somewhere unknown.
    public static let longestFlight: TimeInterval = 24 * 60 * 60
    /// How recent the last reading at an airport must be for a ticket to find that airport at once.
    public static let ticketReach: TimeInterval = 10 * 60
    /// The most airports one trip remembers having found (older ones drop; the passport ignores a repeat).
    public static let maxTripFinds = 16
    /// The most airports one reading weighs (grounds touch in twos at most).
    static let maxAirportsPerReading = 8

    // MARK: State

    /// A placed reading: where, when, how sure, and the nearest airport whose grounds held it.
    struct Sample: Codable, Equatable, Sendable {
        var point: GeoPoint
        var at: Date
        var accuracy: Double
        var airport: String?
    }

    /// The airport last stood at, and when.
    struct Departure: Codable, Equatable, Sendable {
        var token: String
        var point: GeoPoint
        var lastInside: Date
    }

    /// A flight under way.
    struct Flight: Codable, Equatable, Sendable {
        var from: String?
        var departed: Date
        /// When the current run of readings under ``FlightDetector/groundSpeed`` began.
        var slowSince: Date?
    }

    /// Landed, still inside the grounds.
    struct Layover: Codable, Equatable, Sendable {
        var token: String
        var landed: Date
    }

    /// A run of readings inside a large airport's own outline.
    struct Dwell: Codable, Equatable, Sendable {
        var token: String
        var since: Date
        var lastAt: Date
        var found: Bool
    }

    /// A trip under way.
    struct Trip: Codable, Equatable, Sendable {
        var startedAt: Date
        var byTicket: Bool
        /// Whether it has been to an airport or flown (only then does getting home end it).
        var beenAway: Bool
        /// The airports it has found, oldest first, at most ``FlightDetector/maxTripFinds``.
        var found: [String]

        mutating func remember(_ token: String) {
            guard !found.contains(token) else { return }
            found.append(token)
            if found.count > FlightDetector.maxTripFinds { found.removeFirst(found.count - FlightDetector.maxTripFinds) }
        }
    }

    enum Phase: Codable, Equatable, Sendable {
        case ground
        case flying(Flight)
        case landed(Layover)
    }

    private var lastAt: Date?
    private var lastPlaced: Sample?
    /// The good reading a pace is measured from.
    private var anchor: Sample?
    private var departure: Departure?
    private var phase: Phase = .ground
    private var dwell: Dwell?
    private var trip: Trip?

    /// A detector that has seen nothing: on the ground, no trip.
    public init() {}

    // MARK: Reading the state

    /// Whether a flight is under way (Home shows the plane, not the map, §6.2).
    public var isFlying: Bool {
        if case .flying = phase { return true }
        return false
    }

    /// The airport the flight under way left, when known.
    public var flightOrigin: String? {
        if case .flying(let flight) = phase { return flight.from }
        return nil
    }

    /// When the flight under way took off, as best known.
    public var flightDeparted: Date? {
        if case .flying(let flight) = phase { return flight.departed }
        return nil
    }

    /// The airport landed at, while the person is still inside its grounds.
    public var layoverAirport: String? {
        if case .landed(let layover) = phase { return layover.token }
        return nil
    }

    /// How long since the landing, while still inside the grounds ("Layover at Helsinki · 2 h 14 min", §5).
    public func layoverDuration(at now: Date) -> TimeInterval? {
        guard case .landed(let layover) = phase else { return nil }
        return max(0, now.timeIntervalSince(layover.landed))
    }

    /// Whether a trip is on (a ticket, or a flight found by its speed).
    public var isOnTrip: Bool { trip != nil }

    /// Whether the trip under way began with the ticket (the blue button's "End trip" row).
    public var isTripByTicket: Bool { trip?.byTicket ?? false }

    /// The nearest airport whose grounds held the last placed reading, when not flying.
    public var currentAirport: String? {
        isFlying ? nil : lastPlaced?.airport
    }

    /// Whether Sprout wears the travel look: on a trip, on the ground, inside an airport's grounds (§5).
    public var showsTravelLook: Bool {
        isOnTrip && currentAirport != nil
    }

    // MARK: Taking readings

    /// Takes a location reading; whether it may be kept, and what changed. `airports` places it in airports'
    /// grounds; `isHome` says whether a point is at one of the person's homes (asked only during a trip).
    public mutating func observe(_ fix: FlightFix, airports: some AirportGroundsLookup,
                                 isHome: (GeoPoint) -> Bool = { _ in false }) -> FlightVerdict {
        guard fix.point.isValid, fix.accuracy.isFinite, fix.accuracy >= 0,
              fix.at.timeIntervalSinceReferenceDate.isFinite else { return .ignored }
        if let lastAt, fix.at <= lastAt { return .ignored }
        let placed = fix.accuracy <= Self.placedAccuracy
        let here = placed ? Self.nearestFirst(airports.airports(containing: fix.point), to: fix.point) : []
        let reading = Reading(fix: fix, placed: placed, here: here, speed: speed(of: fix),
                              implied: placed ? implied(to: fix) : nil)
        var events: [FlightEvent] = []
        let keep: Bool
        if case .flying(let flight) = phase {
            keep = follow(flight, reading, isHome: isHome, events: &events)
        } else {
            keep = followGround(reading, isHome: isHome, events: &events)
        }
        note(reading)
        return FlightVerdict(mayKeep: keep, events: events, airport: keep ? here.first?.token : nil)
    }

    /// The ticket (§7): starts a trip, and finds the airport the last reading was at when it is recent. The
    /// destination is never given here. Nothing when a trip is already on.
    public mutating func startTrip(at date: Date) -> [FlightEvent] {
        guard trip == nil else { return [] }
        var trip = Trip(startedAt: date, byTicket: true, beenAway: false, found: [])
        var events: [FlightEvent] = [.tripStarted(at: date, byTicket: true)]
        if !isFlying, let last = lastPlaced, let token = last.airport,
           abs(date.timeIntervalSince(last.at)) <= Self.ticketReach {
            trip.beenAway = true
            trip.remember(token)
            events.append(.airportFound(token: token, how: .ticket, at: date))
        }
        self.trip = trip
        return events
    }

    /// Ends the trip under way ("End trip"); nothing when none is on.
    public mutating func endTrip(at date: Date) -> [FlightEvent] {
        guard trip != nil else { return [] }
        trip = nil
        return [.tripEnded(at: date)]
    }

    // MARK: Flying

    /// One reading, as the detector weighs it.
    private struct Reading {
        let fix: FlightFix
        let placed: Bool
        /// The airports whose grounds hold it, nearest first (empty when not placed).
        let here: [WorldAirport]
        /// Its speed, when it is good enough to have one.
        let speed: Double?
        /// The pace implied from the last placed reading, when both are placed.
        let implied: Implied?
    }

    /// The straight line from the last placed reading to this one.
    private struct Implied {
        let metres: Double
        let seconds: TimeInterval
        var speed: Double { metres / max(seconds, 0.001) }
    }

    /// A reading while flying; whether it may be kept.
    private mutating func follow(_ flight: Flight, _ reading: Reading, isHome: (GeoPoint) -> Bool,
                                 events: inout [FlightEvent]) -> Bool {
        let at = reading.fix.at
        if let airport = reading.here.first, isOnTheGround(reading) {
            land(at: airport, flight: flight, on: at, events: &events)
            return true
        }
        if at.timeIntervalSince(flight.departed) > Self.longestFlight {
            events.append(.endedWithoutAirport(from: flight.from, departed: flight.departed, at: at))
            phase = .ground
            return followGround(reading, isHome: isHome, events: &events)
        }
        var flight = flight
        if let speed = reading.speed {
            if speed < Self.groundSpeed {
                let since = flight.slowSince ?? at
                if at.timeIntervalSince(since) >= Self.slowEndTime {
                    events.append(.endedWithoutAirport(from: flight.from, departed: flight.departed, at: at))
                    phase = .ground
                    return followGround(reading, isHome: isHome, events: &events)
                }
                flight.slowSince = since
            } else {
                flight.slowSince = nil
            }
        }
        phase = .flying(flight)
        return false
    }

    /// Whether a reading at an airport while flying is on the ground there: its speed under ``groundSpeed``;
    /// with no speed, the pace from a placed reading within ``pairTime`` before it under ``groundSpeed``, or no
    /// such reading (the first reading after flight mode).
    private func isOnTheGround(_ reading: Reading) -> Bool {
        if let speed = reading.speed { return speed < Self.groundSpeed }
        guard let implied = reading.implied, implied.seconds <= Self.pairTime else { return true }
        return implied.speed < Self.groundSpeed
    }

    /// A landing at `airport`: it is found at once, and the layover begins.
    private mutating func land(at airport: WorldAirport, flight: Flight, on at: Date, events: inout [FlightEvent]) {
        events.append(.airportFound(token: airport.token, how: .landing, at: at))
        events.append(.landed(token: airport.token, from: flight.from, departed: flight.departed, at: at))
        phase = .landed(Layover(token: airport.token, landed: at))
        departure = Departure(token: airport.token, point: airport.point, lastInside: at)
        dwell = nil
        if var trip {
            trip.beenAway = true
            trip.remember(airport.token)
            self.trip = trip
        }
    }

    // MARK: On the ground

    /// Where a flight found on the ground began, and the airport it has already landed at (a gap).
    private struct Start {
        let from: Departure?
        let departed: Date
        let landing: WorldAirport?
    }

    /// A reading on the ground or landed; whether it may be kept.
    private mutating func followGround(_ reading: Reading, isHome: (GeoPoint) -> Bool,
                                       events: inout [FlightEvent]) -> Bool {
        let at = reading.fix.at
        if let start = flightStart(reading) {
            takeOff(start, events: &events)
            if let airport = start.landing, case .flying(let flight) = phase {
                land(at: airport, flight: flight, on: at, events: &events)
                return true
            }
            // A gap flight read on the ground starts its slow count at once.
            if case .flying(var flight) = phase, let speed = reading.speed, speed < Self.groundSpeed {
                flight.slowSince = at
                phase = .flying(flight)
            }
            return false
        }
        var keep = true
        if let speed = reading.speed {
            if speed > Self.takeOffSpeed {
                keep = false
            } else if speed > Self.groundSpeed, reading.here.isEmpty, let departure,
                      at.timeIntervalSince(departure.lastInside) <= Self.departureWindow {
                keep = false
            }
        }
        if case .landed(let layover) = phase, reading.placed,
           !reading.here.contains(where: { $0.token == layover.token }), isSurelySlow(reading) {
            // Bounded: `here` holds at most maxAirportsPerReading airports.
            events.append(.arrived(token: layover.token, at: at))
            phase = .ground
        }
        noteDeparture(reading)
        if case .ground = phase { trackDwell(reading, events: &events) }
        trackTrip(reading, isHome: isHome, events: &events)
        return keep
    }

    /// Whether this reading starts a flight, by the gap rule or by speed.
    private func flightStart(_ reading: Reading) -> Start? {
        let at = reading.fix.at
        if reading.placed, let last = lastPlaced, let departure, let implied = reading.implied,
           Self.greatCircleMetres(last.point, departure.point) <= Self.nearAirportMetres,
           last.at.timeIntervalSince(departure.lastInside) <= Self.departureWindow,
           implied.metres > Self.gapMinMetres {
            // Bounded: `here` holds at most maxAirportsPerReading airports.
            if let other = reading.here.first(where: { $0.token != departure.token }),
               Self.gapLandingSpeeds.contains(implied.speed) {
                return Start(from: departure, departed: last.at, landing: other)
            }
            if reading.here.isEmpty, Self.gapAwaySpeeds.contains(implied.speed) {
                return Start(from: departure, departed: last.at, landing: nil)
            }
        }
        guard let speed = reading.speed else { return nil }
        if speed > Self.anywhereSpeed {
            let from = departure.flatMap { at.timeIntervalSince($0.lastInside) <= Self.departureLookBack ? $0 : nil }
            return Start(from: from, departed: from?.lastInside ?? at, landing: nil)
        }
        if speed > Self.takeOffSpeed, reading.here.isEmpty, let departure,
           at.timeIntervalSince(departure.lastInside) <= Self.departureWindow {
            return Start(from: departure, departed: departure.lastInside, landing: nil)
        }
        return nil
    }

    /// A take-off: a layover becomes a transit, a trip begins if none is on, and the airport left is found.
    private mutating func takeOff(_ start: Start, events: inout [FlightEvent]) {
        if case .landed(let layover) = phase {
            events.append(.layoverBecameTransit(token: layover.token, at: start.departed))
        }
        events.append(.flightStarted(from: start.from?.token, departed: start.departed))
        var trip: Trip
        if let current = self.trip {
            trip = current
        } else {
            events.append(.tripStarted(at: start.departed, byTicket: false))
            trip = Trip(startedAt: start.departed, byTicket: false, beenAway: true, found: [])
        }
        trip.beenAway = true
        if let from = start.from, !trip.found.contains(from.token) {
            trip.remember(from.token)
            events.append(.airportFound(token: from.token, how: .takeOff, at: start.departed))
        }
        self.trip = trip
        phase = .flying(Flight(from: start.from?.token, departed: start.departed, slowSince: nil))
        departure = nil
        dwell = nil
    }

    /// Whether a placed reading is surely slow: its speed, or the pace implied from the last placed reading,
    /// under ``groundSpeed``.
    private func isSurelySlow(_ reading: Reading) -> Bool {
        guard let speed = reading.speed ?? reading.implied?.speed else { return false }
        return speed < Self.groundSpeed
    }

    /// Keeps the airport last stood at: a placed reading inside grounds on the ground (under ``groundSpeed``
    /// by its speed or its implied pace, or with neither) sets it; a surely slow reading outside grounds far
    /// from it, or a reading long after it, forgets it.
    private mutating func noteDeparture(_ reading: Reading) {
        guard reading.placed else { return }
        let at = reading.fix.at
        if let airport = reading.here.first {
            let pace = reading.speed ?? reading.implied.flatMap { $0.seconds <= Self.pairTime ? $0.speed : nil }
            if pace.map({ $0 < Self.groundSpeed }) ?? true {
                departure = Departure(token: airport.token, point: airport.point, lastInside: at)
            }
        } else if let departure {
            let stale = at.timeIntervalSince(departure.lastInside) > Self.departureLookBack
            let elsewhere = isSurelySlow(reading)
                && Self.greatCircleMetres(reading.fix.point, departure.point) > Self.nearAirportMetres
            if stale || elsewhere { self.departure = nil }
        }
    }

    /// Ten minutes at a large airport with our own outline (§3).
    private mutating func trackDwell(_ reading: Reading, events: inout [FlightEvent]) {
        let at = reading.fix.at
        guard reading.placed else { return }
        // Bounded: `here` holds at most maxAirportsPerReading airports.
        let outlined = reading.here.first { $0.size == .large && $0.grounds.isOurOutline }
        guard let airport = outlined else {
            dwell = nil
            return
        }
        // Vaguer readings inside neither count nor break the run.
        guard reading.fix.accuracy <= Self.dwellAccuracy else { return }
        guard reading.speed.map({ $0 <= Self.walkingSpeed }) ?? true else {
            dwell = nil
            return
        }
        var run: Dwell
        if let dwell, dwell.token == airport.token, at.timeIntervalSince(dwell.lastAt) <= Self.dwellMaxGap {
            run = dwell
            run.lastAt = at
        } else {
            run = Dwell(token: airport.token, since: at, lastAt: at, found: false)
        }
        if !run.found, at.timeIntervalSince(run.since) >= Self.dwellTime {
            run.found = true
            events.append(.airportFound(token: airport.token, how: .dwell, at: at))
        }
        dwell = run
    }

    /// A trip's finds, and its end at home.
    private mutating func trackTrip(_ reading: Reading, isHome: (GeoPoint) -> Bool, events: inout [FlightEvent]) {
        guard var trip, reading.placed else { return }
        let at = reading.fix.at
        if let airport = reading.here.first {
            trip.beenAway = true
            if !trip.found.contains(airport.token) {
                trip.remember(airport.token)
                events.append(.airportFound(token: airport.token, how: .ticket, at: at))
            }
            self.trip = trip
        } else if case .ground = phase, trip.beenAway, isHome(reading.fix.point) {
            self.trip = nil
            events.append(.tripEnded(at: at))
        }
    }

    // MARK: Pace

    /// A good reading's speed: CoreLocation's own, else the pace from the anchor beyond both readings' accuracy.
    private func speed(of fix: FlightFix) -> Double? {
        guard fix.accuracy <= Self.goodAccuracy else { return nil }
        if let speed = fix.speed, speed.isFinite, speed >= 0 { return speed }
        guard let anchor else { return nil }
        let seconds = fix.at.timeIntervalSince(anchor.at)
        guard seconds >= Self.minPaceTime, seconds <= Self.pairTime else { return nil }
        let beyond = Self.greatCircleMetres(anchor.point, fix.point) - anchor.accuracy - fix.accuracy
        return max(0, beyond) / seconds
    }

    /// The straight line from the last placed reading to `fix`.
    private func implied(to fix: FlightFix) -> Implied? {
        guard let last = lastPlaced else { return nil }
        let seconds = fix.at.timeIntervalSince(last.at)
        guard seconds > 0 else { return nil }
        return Implied(metres: Self.greatCircleMetres(last.point, fix.point), seconds: seconds)
    }

    /// Remembers a taken reading: its time, where it was placed, and the pace anchor.
    private mutating func note(_ reading: Reading) {
        let fix = reading.fix
        lastAt = fix.at
        guard reading.placed else { return }
        let sample = Sample(point: fix.point, at: fix.at, accuracy: fix.accuracy, airport: reading.here.first?.token)
        lastPlaced = sample
        guard fix.accuracy <= Self.goodAccuracy else { return }
        if let anchor, fix.at.timeIntervalSince(anchor.at) < Self.minPaceTime { return }
        anchor = sample
    }

    // MARK: Geometry

    /// `airports` nearest first by reference point, at most ``maxAirportsPerReading``.
    private static func nearestFirst(_ airports: [WorldAirport], to point: GeoPoint) -> [WorldAirport] {
        // Bounded: at most maxAirportsPerReading airports are sorted.
        Array(airports.prefix(maxAirportsPerReading))
            .sorted { greatCircleMetres($0.point, point) < greatCircleMetres($1.point, point) }
    }

    /// The great-circle distance between two points, in metres (a flight's gap spans continents and may cross
    /// 180°, where ``GeoPoint/distance(to:)``'s flat step doesn't hold).
    static func greatCircleMetres(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let radius = 6_371_008.8
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, h.squareRoot()))
    }
}

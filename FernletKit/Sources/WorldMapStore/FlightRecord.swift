import Foundation

/// What the flight readers need to know about airports (World-Airports-Spec §9–§10): whether a code is in the
/// list and its zone, the airline table for an in-memory comparison, and, where the list has them, a country,
/// a point and a name. ``WorldAirports`` conforms; tests pass small fakes.
public nonisolated protocol FlightAirportLookup: Sendable {
    /// The zone of the airport with this IATA code, or nil for a code not in the list (the readers treat a
    /// code with no zone as unknown, never guessed).
    func timeZone(iata: String) -> TimeZone?
    /// The airline an event or export names by ICAO code, IATA code or name. It's only ever compared in
    /// memory, never kept.
    func airline(named text: String) -> WorldAirline?
    /// The airport's ISO country, or nil where the list doesn't say (the Flighty summary then leaves its
    /// countries tile out).
    func countryCode(iata: String) -> String?
    /// The airport's reference point, used only to let an event's structured location confirm a departure.
    func airportPoint(iata: String) -> GeoPoint?
    /// The airport's everyday English name, used only to let an event's location text confirm a departure.
    func airportName(iata: String) -> String?
}

public extension FlightAirportLookup {
    func countryCode(iata: String) -> String? { nil }
    func airportPoint(iata: String) -> GeoPoint? { nil }
    func airportName(iata: String) -> String? { nil }
}

extension WorldAirports: FlightAirportLookup {
    /// The airport's country (every IATA point carries one).
    public func countryCode(iata: String) -> String? {
        point(iata: iata)?.countryCode
    }

    public func airportPoint(iata: String) -> GeoPoint? {
        point(iata: iata)?.point
    }

    public func airportName(iata: String) -> String? {
        guard point(iata: iata)?.isUnlockable == true else { return nil }
        return airport(code: iata)?.englishName
    }
}

/// A calendar date with no time or zone: the day a flight leaves, local to its departure airport.
public nonisolated struct FlightDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// The day, or nil where it isn't a real Gregorian date (2026-02-30 is refused, never rolled over).
    public init?(year: Int, month: Int, day: Int) {
        guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              calendar.component(.day, from: date) == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `instant` falls on in `zone`.
    public init(_ instant: Date, in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    public static func < (lhs: FlightDay, rhs: FlightDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// One flight as a reader found it (spec §9.2, §10.4): only the day, the two airports and the gate-to-gate
/// instants. The airline, flight number, booking code and everything else a source holds never reach it.
public nonisolated struct FlightRecord: Equatable, Sendable {
    /// The departure airport's IATA code.
    public let from: String
    /// The airport it really landed at (a diversion's, where there was one).
    public let to: String
    /// The day it left, local to `from`.
    public let day: FlightDay
    /// When it left the gate (UTC instant), or nil where the source gives a date only.
    public let departure: Date?
    /// When it reached the gate, or nil where the source has none or it can't be trusted.
    public let arrival: Date?
    /// Whether the source's times disagree with themselves; the Flights page then shows no duration.
    public let timesUnsure: Bool

    public init(from: String, to: String, day: FlightDay, departure: Date?, arrival: Date?, timesUnsure: Bool) {
        self.from = from
        self.to = to
        self.day = day
        self.departure = departure
        self.arrival = arrival
        self.timesUnsure = timesUnsure
    }
}

/// Local wall-clock times read in an airport's zone, shared by both readers.
nonisolated enum FlightClock {
    /// The longest gate-to-gate time believed (spec §9.2): anything longer, or zero or less, isn't shown.
    static let maxDuration: TimeInterval = 20 * 3_600

    /// The instant a wall-clock time names in `zone`, or nil where the parts aren't a real time. A time
    /// skipped by a clock change resolves forward, as Foundation does.
    static func instant(year: Int, month: Int, day: Int, hour: Int, minute: Int, in zone: TimeZone) -> Date? {
        guard FlightDay(year: year, month: month, day: day) != nil, (0...23).contains(hour),
              (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }

    /// The same wall-clock reading as `instant` shows in `from`, read again in `to` (a floating event's times).
    static func rezoned(_ instant: Date, from: TimeZone, to: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = from
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour,
              let minute = parts.minute else { return nil }
        return Self.instant(year: year, month: month, day: day, hour: hour, minute: minute, in: to)
    }

    /// `arrival` where the trip it makes with `departure` is believable, else nil with the unsure flag.
    static func checked(departure: Date, arrival: Date?) -> (arrival: Date?, unsure: Bool) {
        guard let arrival else { return (nil, false) }
        let duration = arrival.timeIntervalSince(departure)
        guard duration > 0, duration <= maxDuration else { return (nil, true) }
        return (arrival, false)
    }
}

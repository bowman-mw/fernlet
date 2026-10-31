import Foundation

/// One flight as the travel-day rule reads it (World-Airports-Spec §13.1): when it left and landed, and the two
/// airports' time zones. Built by the composition root from a ticket, a calendar flight or a flight found by its
/// speed; never stored, never handed to the planner (only the rule's two yes/no answers are).
nonisolated struct TravelDayFlight: Equatable, Sendable {
    /// When it left.
    let departure: Date
    /// When it landed, or nil while unknown (a ticket, a flight under way); such a flight is never overnight.
    let arrival: Date?
    /// The departure airport's zone (the flight's date is the departure's date there).
    let originZone: TimeZone
    /// The arrival airport's zone.
    let destinationZone: TimeZone
}

/// Which kind of travel day a day is (§13.1): the flight's own date, or the day after an overnight flight. The
/// card's line differs (§13.2, §13.5); the planner hears only that it is a travel day. Not persisted.
nonisolated enum WorkoutTravelDayKind: Equatable, Sendable {
    /// A flight leaves today.
    case flightDay
    /// Yesterday's flight was in the air between midnight and 5 am.
    case afterOvernight
}

/// Today's travel-day answer: the two yes/no values the composition root works out (§13.1 wall), travel day and
/// long flight, plus which kind of day it is for the Move card's line.
nonisolated struct WorkoutTravelDay: Equatable, Sendable {
    /// Which kind of travel day today is, or nil when it isn't one.
    var kind: WorkoutTravelDayKind?
    /// A flight of today's lasted more than ``WorldTravelDayRule/longFlightSeconds`` (4 h).
    var longFlight = false

    /// Not a travel day.
    static let none = WorkoutTravelDay()

    /// The planner's yes/no.
    var isTravelDay: Bool { kind != nil }
}

/// The travel-day rule (World-Airports-Spec §13.1, owner 2026-10-31: "Day of flight or after an overnight
/// flight"), pure over made-up or real flights.
///
/// - **Which days:** the flight's date (its departure's date at the departure airport), plus the next day when
///   the flight is overnight. A daytime flight, even a long one, makes only its own date a travel day.
/// - **Overnight:** in the air at any time between midnight and 5 am in either airport's time.
/// - **When the next day ends:** at midnight where you are: days are calendar dates ("yyyy-MM-dd"), matched
///   against the person's own day key, which turns over at their local midnight.
/// - **Long flight:** more than 4 h from departure to arrival; unknown without an arrival.
nonisolated enum WorldTravelDayRule {
    /// The hour an overnight window ends (midnight to 5 am).
    static let overnightEndHour = 5
    /// More than this from take-off to landing is a long flight.
    static let longFlightSeconds: TimeInterval = 4 * 60 * 60
    /// The longest flight read (the passport refuses longer ones); bounds the overnight search.
    static let longestFlightSeconds: TimeInterval = 48 * 60 * 60
    /// The most flights one answer reads (a bound; the newest are passed).
    static let maxFlights = 256
    /// The most local days one flight's overnight search walks in one zone (48 h spans at most 3 dates).
    static let maxDaysPerZone = 4

    /// The day key of `instant` in `zone`, in Fernlet's "yyyy-MM-dd" form.
    static func dayKey(_ instant: Date, in zone: TimeZone) -> String {
        let parts = calendar(in: zone).dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// A Gregorian calendar in `zone`.
    static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Whether `flight` is in the air at any time between midnight and 5 am in either airport's zone.
    static func isOvernight(_ flight: TravelDayFlight) -> Bool {
        guard let arrival = flight.arrival, arrival > flight.departure,
              arrival.timeIntervalSince(flight.departure) <= longestFlightSeconds else { return false }
        return [flight.originZone, flight.destinationZone].contains { zone in
            inAirOvernight(from: flight.departure, to: arrival, in: zone)
        }
    }

    /// Whether the span `departure`…`arrival` overlaps any midnight-to-5-am window in `zone`.
    static func inAirOvernight(from departure: Date, to arrival: Date, in zone: TimeZone) -> Bool {
        let calendar = calendar(in: zone)
        var midnight = calendar.startOfDay(for: departure)
        // Bounded: a flight of at most 48 h touches at most three local dates.
        for _ in 0..<maxDaysPerZone where midnight < arrival {
            guard let windowEnd = calendar.date(byAdding: .hour, value: overnightEndHour, to: midnight) else { return false }
            if departure < windowEnd && arrival > midnight { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { return false }
            midnight = next
        }
        return false
    }

    /// Whether `flight` lasted more than 4 h.
    static func isLong(_ flight: TravelDayFlight) -> Bool {
        guard let arrival = flight.arrival else { return false }
        return arrival.timeIntervalSince(flight.departure) > longFlightSeconds
    }

    /// The travel days one flight makes: its date as a flight day, and after an overnight flight the next date.
    static func days(of flight: TravelDayFlight) -> [String: WorkoutTravelDayKind] {
        var days = [dayKey(flight.departure, in: flight.originZone): WorkoutTravelDayKind.flightDay]
        let calendar = calendar(in: flight.originZone)
        if isOvernight(flight),
           let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: flight.departure)) {
            let key = dayKey(next, in: flight.originZone)
            if days[key] == nil { days[key] = .afterOvernight }
        }
        return days
    }

    /// Every travel day `flights` make (at most ``maxFlights`` read); a flight's own date wins over another's
    /// next day.
    static func days(of flights: [TravelDayFlight]) -> [String: WorkoutTravelDayKind] {
        var days: [String: WorkoutTravelDayKind] = [:]
        // Bounded: at most `maxFlights` flights, two days each.
        for flight in flights.prefix(maxFlights) {
            for (key, kind) in Self.days(of: flight) where days[key] != .flightDay {
                days[key] = kind
            }
        }
        return days
    }

    /// Today's answer: `todayKey` is the person's own day key (it turns over at their local midnight).
    static func today(_ todayKey: String, flights: [TravelDayFlight]) -> WorkoutTravelDay {
        let read = Array(flights.prefix(maxFlights))
        guard let kind = days(of: read)[todayKey] else { return .none }
        let long = read.contains { days(of: $0)[todayKey] != nil && isLong($0) }
        return WorkoutTravelDay(kind: kind, longFlight: long)
    }
}

import Foundation

/// One flight in the passport (World-Airports-Spec §8–§10): two airports and the times, nothing else. A flight
/// Fernlet saw itself (its speed, or a ticket and a landing), one read from a Flighty export, or one found in the
/// calendar; the same flight from several of them is kept once (``isSameFlight(as:)``, spec §9.3), with every
/// source it came from, so removing one source never deletes a flight another also has (spec §9.5).
///
/// **Never kept:** an airline, a flight number, an aircraft, a seat, a cabin or a booking code (the owner approved
/// 24 A and 27 A). They may be compared in memory while one file or one calendar look is read, then dropped.
///
/// **FROZEN keys** (the passport's sealed file and its sealed backup carry them; never renamed, never reused):
/// - `f`: from, the departure airport's IATA code (3 ASCII capitals);
/// - `t`: to, the arrival airport's IATA code (3 ASCII capitals, never the same as `f`);
/// - `d`: the departure, in seconds since 1970 (UTC);
/// - `a`: the arrival, in seconds since 1970 (UTC), only when known, never before `d` nor more than
///   ``longestFlight`` after it;
/// - `s`: the sources, a bitmask (``Sources``: Fernlet 1, Flighty 2, Calendar 4; a newer Fernlet's bits are kept);
/// - `u`: `true` when the times are unsure (a calendar's notes disagreed with its event, spec §10.4); absent
///   otherwise;
/// - `h`: for a calendar flight only, the salted hash of the event's `calendarItemExternalIdentifier` (64
///   lowercase hex characters), so a later look knows the event without keeping its ID; absent otherwise.
///
/// A flight that breaks a rule is refused when it is made (the initialiser returns nil) and when it is read
/// (``PassportBook/BookError/badFlight``).
public nonisolated struct PassportFlight: Codable, Hashable, Sendable {
    /// Where a flight came from (frozen bits).
    public struct Sources: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Fernlet saw it: found by its speed, or a ticket, and a landing (spec §6, §7).
        public static let fernlet = Sources(rawValue: 1)
        /// Read from a Flighty export file (spec §9).
        public static let flighty = Sources(rawValue: 2)
        /// Found in the calendar (spec §10).
        public static let calendar = Sources(rawValue: 4)
        /// Both imports ("Remove imported flights", spec §9.5).
        public static let imported: Sources = [.flighty, .calendar]
        /// The largest mask kept (room for a newer Fernlet's sources, which this build keeps as they are).
        public static let maxRawValue = 0xFFFF
    }

    /// Two records of one flight are the same flight when their airports match and their departures are at most
    /// this far apart in UTC (spec §9.3: match on departure, never arrival; schedules change between sources).
    public static let sameFlightWindow: TimeInterval = 3 * 60 * 60
    /// The longest a flight may last from departure to arrival (the longest scheduled flights are under 20 h).
    public static let longestFlight: TimeInterval = 48 * 60 * 60
    /// The length of an event hash, in lowercase hex characters.
    public static let eventHashLength = 64

    /// The departure airport's IATA code.
    public let from: String
    /// The arrival airport's IATA code.
    public let to: String
    /// When it left (UTC).
    public let departure: Date
    /// When it arrived (UTC), or nil when that isn't known.
    public let arrival: Date?
    /// Where it came from: never empty.
    public let sources: Sources
    /// Whether the times are unsure (no duration is shown, spec §10.4).
    public let timesUnsure: Bool
    /// The calendar event's salted hash, for a calendar flight only.
    public let eventHash: String?

    /// A flight with every field given, or nil when one breaks a rule: either code not 3 ASCII capitals, the two
    /// codes the same, a time that isn't finite, an arrival before the departure or more than ``longestFlight``
    /// after it, no source (or a mask past ``Sources/maxRawValue``), or an event hash that isn't 64 lowercase hex
    /// characters on a flight from the calendar.
    public init?(from: String, to: String, departure: Date, arrival: Date? = nil, sources: Sources,
                 timesUnsure: Bool = false, eventHash: String? = nil) {
        guard Self.isValid(from: from, to: to, departure: departure, arrival: arrival, sources: sources,
                           eventHash: eventHash) else { return nil }
        self.init(unchecked: from, to: to, departure: departure, arrival: arrival, sources: sources,
                  timesUnsure: timesUnsure, eventHash: eventHash)
    }

    /// A flight whose fields already passed the rules.
    private init(unchecked from: String, to: String, departure: Date, arrival: Date?, sources: Sources,
                 timesUnsure: Bool, eventHash: String?) {
        self.from = from
        self.to = to
        self.departure = departure
        self.arrival = arrival
        self.sources = sources
        self.timesUnsure = timesUnsure
        self.eventHash = eventHash
    }

    // MARK: One flight, once

    /// The route as one token, "FROM>TO" (the sealed backup's record token).
    public var route: String { from + ">" + to }

    /// Whether `other` is this flight from another source: the same airports, departures at most
    /// ``sameFlightWindow`` apart.
    public func isSameFlight(as other: PassportFlight) -> Bool {
        from == other.from && to == other.to
            && abs(departure.timeIntervalSince(other.departure)) <= Self.sameFlightWindow
    }

    /// Whether this record's times beat `other`'s (spec §9.3, "the richer record wins"): a known arrival over
    /// none, then sure times over unsure ones, then times Fernlet saw over imported ones. Equal is not richer.
    public func isRicher(than other: PassportFlight) -> Bool {
        richness > other.richness
    }

    /// The richness rule as one number: a known arrival 4, sure times 2, times Fernlet saw 1.
    private var richness: Int {
        (arrival != nil ? 4 : 0) + (timesUnsure ? 0 : 2) + (sources.contains(.fernlet) ? 1 : 0)
    }

    /// This flight and `other` (the same flight) as one: the richer record's times (this one's on a tie), every
    /// source of both, and an event hash while a calendar is among them.
    public func merged(with other: PassportFlight) -> PassportFlight {
        let base = other.isRicher(than: self) ? other : self
        let sources = self.sources.union(other.sources)
        let hash = sources.contains(.calendar) ? (base.eventHash ?? eventHash ?? other.eventHash) : nil
        return PassportFlight(unchecked: base.from, to: base.to, departure: base.departure, arrival: base.arrival,
                              sources: sources, timesUnsure: base.timesUnsure, eventHash: hash)
    }

    /// This flight without `removed` among its sources, or nil when no source is left (the event hash goes with
    /// the calendar).
    public func removing(_ removed: Sources) -> PassportFlight? {
        let left = sources.subtracting(removed)
        guard !left.isEmpty else { return nil }
        return PassportFlight(unchecked: from, to: to, departure: departure, arrival: arrival, sources: left,
                              timesUnsure: timesUnsure, eventHash: left.contains(.calendar) ? eventHash : nil)
    }

    /// Earliest departure first, then the route, then the rest, so a list of flights always sorts the same.
    static func precedes(_ lhs: PassportFlight, _ rhs: PassportFlight) -> Bool {
        if lhs.departure != rhs.departure { return lhs.departure < rhs.departure }
        if lhs.route != rhs.route { return lhs.route < rhs.route }
        let left = lhs.arrival?.timeIntervalSince1970 ?? -.infinity
        let right = rhs.arrival?.timeIntervalSince1970 ?? -.infinity
        if left != right { return left < right }
        if lhs.sources.rawValue != rhs.sources.rawValue { return lhs.sources.rawValue < rhs.sources.rawValue }
        if lhs.timesUnsure != rhs.timesUnsure { return !lhs.timesUnsure }
        return (lhs.eventHash ?? "") < (rhs.eventHash ?? "")
    }

    // MARK: Rules

    /// Whether `code` is an IATA code: exactly 3 ASCII capitals.
    public static func isValidCode(_ code: String) -> Bool {
        code.utf8.count == 3 && code.utf8.allSatisfy { $0 >= 0x41 && $0 <= 0x5A }
    }

    /// Whether `hash` is 64 lowercase hex characters.
    public static func isValidEventHash(_ hash: String) -> Bool {
        hash.utf8.count == eventHashLength && hash.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Every rule a flight's fields must keep.
    private static func isValid(from: String, to: String, departure: Date, arrival: Date?, sources: Sources,
                                eventHash: String?) -> Bool {
        guard isValidCode(from), isValidCode(to), from != to, departure.timeIntervalSince1970.isFinite else { return false }
        guard sources.rawValue > 0, sources.rawValue <= Sources.maxRawValue else { return false }
        if let arrival {
            let length = arrival.timeIntervalSince(departure)
            guard length.isFinite, length >= 0, length <= longestFlight else { return false }
        }
        if let eventHash {
            guard sources.contains(.calendar), isValidEventHash(eventHash) else { return false }
        }
        return true
    }

    // MARK: Bytes

    /// FROZEN keys.
    enum CodingKeys: String, CodingKey {
        case from = "f"
        case to = "t"
        case departure = "d"
        case arrival = "a"
        case sources = "s"
        case timesUnsure = "u"
        case eventHash = "h"
    }

    /// Reads the frozen shape; a flight that breaks a rule is ``PassportBook/BookError/badFlight``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let from = try container.decode(String.self, forKey: .from)
        let to = try container.decode(String.self, forKey: .to)
        let departure = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .departure))
        let arrival = try container.decodeIfPresent(Double.self, forKey: .arrival).map(Date.init(timeIntervalSince1970:))
        let sources = Sources(rawValue: try container.decode(Int.self, forKey: .sources))
        let unsure = try container.decodeIfPresent(Bool.self, forKey: .timesUnsure) ?? false
        let hash = try container.decodeIfPresent(String.self, forKey: .eventHash)
        guard let flight = PassportFlight(from: from, to: to, departure: departure, arrival: arrival, sources: sources,
                                          timesUnsure: unsure, eventHash: hash) else {
            throw PassportBook.BookError.badFlight
        }
        self = flight
    }

    /// Writes the frozen shape (`a`, `u` and `h` only when set).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(departure.timeIntervalSince1970, forKey: .departure)
        try container.encodeIfPresent(arrival?.timeIntervalSince1970, forKey: .arrival)
        try container.encode(sources.rawValue, forKey: .sources)
        if timesUnsure { try container.encode(true, forKey: .timesUnsure) }
        try container.encodeIfPresent(eventHash, forKey: .eventHash)
    }
}

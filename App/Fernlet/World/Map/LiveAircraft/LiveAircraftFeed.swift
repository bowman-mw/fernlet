import Foundation
import WorldMapStore

/// One aircraft from the feed, as the map needs it. Held in memory only, for drawing; nothing about it is saved,
/// logged, synced or stamped (owner 2026-11-19: "Nothing about the planes is saved").
nonisolated struct LiveAircraft: Identifiable, Equatable, Sendable {
    /// The transponder's 24-bit address in hex ("a2b12d"), the feed's own key.
    let id: String
    /// The callsign as flown ("UAL1704"), trimmed; nil when the transponder sends none.
    let callsign: String?
    /// The registration ("N27260"), the tail number; nil when the feed has none.
    let registration: String?
    /// The ICAO type designator ("B38M"); nil when unknown.
    let typeCode: String?
    /// The ADS-B emitter category ("A3"); nil when unknown.
    let category: String?
    /// Where it was, at ``seenAt``.
    let position: GeoPoint
    /// Barometric altitude in feet.
    let altitudeFeet: Int
    /// Ground speed in knots; nil when not sent.
    let groundSpeedKnots: Double?
    /// Track over the ground in degrees from north; nil when not sent (then the nose points north).
    let trackDegrees: Double?
    /// When ``position`` was true: the fetch time less the feed's `seen_pos`.
    let seenAt: Date
}

/// What one fetch came to.
nonisolated enum LiveAircraftFetchOutcome: Equatable, Sendable {
    /// The aircraft in the air near the cell (none is a real answer: a quiet sky or no feeders).
    case planes([LiveAircraft])
    /// adsb.lol said too many requests (429): rest for at least this long.
    case rateLimited(retryAfter: TimeInterval?)
    /// The switch is off; no request was built.
    case notPermitted
    /// Anything else: network, timeout, a 3xx/5xx, a body that isn't the feed.
    case failed
}

/// Reads an adsb.lol `/v2/point` answer (readsb's JSON: `{"ac": [...], "now": ms, ...}`). Pure.
///
/// - **On the ground** (`alt_baro` is `"ground"`) is dropped: planes on the ground are not drawn (owner 2026-11-19).
/// - **Stale positions** (`seen_pos` over ``maxPositionAgeSeconds``) and entries with no position are dropped.
/// - Everything else in the feed is kept, private planes and registrations included (owner's call 5).
nonisolated enum LiveAircraftFeed {
    /// The most aircraft one answer may hold; the rest are ignored.
    static let maxAircraft = 600
    /// The oldest position worth drawing, in seconds.
    static let maxPositionAgeSeconds = 60.0
    /// The longest text field kept (callsign, registration, type), in characters.
    static let maxFieldLength = 12

    /// The outcome of an HTTP answer with `statusCode` and `body`, read at `now`.
    static func outcome(statusCode: Int, retryAfter: TimeInterval?, body: Data, now: Date = Date()) -> LiveAircraftFetchOutcome {
        if statusCode == 429 { return .rateLimited(retryAfter: retryAfter) }
        guard statusCode == 200, let planes = aircraft(in: body, now: now) else { return .failed }
        return .planes(planes)
    }

    /// The aircraft in `body`, or nil when it isn't the feed.
    static func aircraft(in body: Data, now: Date) -> [LiveAircraft]? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let list = root["ac"] as? [[String: Any]] else { return nil }
        return list.prefix(maxAircraft).compactMap { aircraft(from: $0, now: now) }
    }

    /// One entry as an aircraft, or nil when it is on the ground, stale or has no position.
    static func aircraft(from entry: [String: Any], now: Date) -> LiveAircraft? {
        guard let hex = text(entry["hex"]),
              let latitude = number(entry["lat"]), let longitude = number(entry["lon"]),
              let altitude = number(entry["alt_baro"]) else { return nil }   // "ground" isn't a number
        let position = GeoPoint(latitude, longitude)
        let age = number(entry["seen_pos"]) ?? 0
        guard position.isValid, age >= 0, age <= maxPositionAgeSeconds else { return nil }
        let track = number(entry["track"]) ?? number(entry["true_heading"]) ?? number(entry["mag_heading"])
        return LiveAircraft(
            id: hex.lowercased(), callsign: text(entry["flight"]), registration: text(entry["r"]),
            typeCode: text(entry["t"])?.uppercased(), category: text(entry["category"])?.uppercased(),
            position: position, altitudeFeet: Int(altitude.rounded()), groundSpeedKnots: number(entry["gs"]),
            trackDegrees: track, seenAt: now.addingTimeInterval(-age))
    }

    /// A trimmed, non-empty text field of at most ``maxFieldLength`` printable ASCII characters.
    static func text(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxFieldLength,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else { return nil }
        return trimmed
    }

    /// A finite number field (JSON numbers arrive as `NSNumber`; a Bool is not a number here).
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

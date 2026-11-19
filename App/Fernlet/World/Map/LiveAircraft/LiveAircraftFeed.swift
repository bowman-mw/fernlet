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
///
/// **The feed is not trusted** (release review 2026-11-18, F9): every number is range-checked before it is converted
/// or used, so no answer can trap. An entry whose address, position, altitude or age is out of range is dropped; a
/// speed or track out of range is left out and the plane kept; an entry that isn't an object is skipped. One bad
/// entry never costs the others.
nonisolated enum LiveAircraftFeed {
    /// The most aircraft one answer may hold; the rest are ignored.
    static let maxAircraft = 600
    /// The oldest position worth drawing, in seconds.
    static let maxPositionAgeSeconds = 60.0
    /// The longest text field kept (callsign, registration, type), in characters.
    static let maxFieldLength = 12
    /// The altitudes a drawn plane may have, in feet: from below the Dead Sea's shore to above any balloon. An
    /// altitude outside it is a broken reading, and the plane is dropped.
    static let altitudeFeetRange = -2_000.0...150_000.0
    /// The ground speeds kept, in knots (the fastest aircraft flown is under 4,000); one outside is left out.
    static let groundSpeedKnotsRange = 0.0...4_000.0
    /// The tracks kept, in degrees: readsb sends 0..<360; anything else is left out.
    static let trackDegreesRange = 0.0...360.0

    /// The outcome of an HTTP answer with `statusCode` and `body`, read at `now`.
    static func outcome(statusCode: Int, retryAfter: TimeInterval?, body: Data, now: Date = Date()) -> LiveAircraftFetchOutcome {
        if statusCode == 429 { return .rateLimited(retryAfter: retryAfter) }
        guard statusCode == 200, let planes = aircraft(in: body, now: now) else { return .failed }
        return .planes(planes)
    }

    /// The aircraft in `body`, or nil when it isn't the feed. Entries that aren't objects are skipped.
    static func aircraft(in body: Data, now: Date) -> [LiveAircraft]? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let list = root["ac"] as? [Any] else { return nil }
        return list.prefix(maxAircraft).compactMap { entry in
            (entry as? [String: Any]).flatMap { aircraft(from: $0, now: now) }
        }
    }

    /// One entry as an aircraft, or nil when it is on the ground, stale, has no position, or its position, altitude
    /// or age is out of range.
    static func aircraft(from entry: [String: Any], now: Date) -> LiveAircraft? {
        guard let hex = text(entry["hex"]),
              let latitude = number(entry["lat"], in: -90...90), let longitude = number(entry["lon"], in: -180...180),
              let altitude = altitudeFeet(entry["alt_baro"]) else { return nil }   // "ground" isn't a number
        let position = GeoPoint(latitude, longitude)
        var age = 0.0
        if let sent = entry["seen_pos"] {
            guard let seconds = number(sent, in: 0...maxPositionAgeSeconds) else { return nil }
            age = seconds
        }
        guard position.isValid else { return nil }
        let track = trackDegrees(entry["track"]) ?? trackDegrees(entry["true_heading"]) ?? trackDegrees(entry["mag_heading"])
        return LiveAircraft(
            id: hex.lowercased(), callsign: text(entry["flight"]), registration: text(entry["r"]),
            typeCode: text(entry["t"])?.uppercased(), category: text(entry["category"])?.uppercased(),
            position: position, altitudeFeet: altitude, groundSpeedKnots: number(entry["gs"], in: groundSpeedKnotsRange),
            trackDegrees: track, seenAt: now.addingTimeInterval(-age))
    }

    /// A barometric altitude in whole feet, or nil when it isn't a number inside ``altitudeFeetRange``. The range is
    /// checked before the conversion: `Int(_:)` traps on a `Double` it cannot hold (`1e30`).
    static func altitudeFeet(_ value: Any?) -> Int? {
        guard let feet = number(value, in: altitudeFeetRange) else { return nil }
        return Int(exactly: feet.rounded())
    }

    /// A track in degrees within 0..<360 (a sent 360 reads as north), or nil when it is out of range.
    static func trackDegrees(_ value: Any?) -> Double? {
        guard let degrees = number(value, in: trackDegreesRange) else { return nil }
        return degrees == 360 ? 0 : degrees
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

    /// A finite number field inside `range`, or nil.
    static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        guard let double = number(value), range.contains(double) else { return nil }
        return double
    }
}

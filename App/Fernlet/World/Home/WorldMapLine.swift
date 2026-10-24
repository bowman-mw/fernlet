import AppServices
import Foundation

/// The companion's line on the map, when the map has something of its own to say (designs
/// `b1-home-friend`, `b1-home-weather`, `b1-home-sick`, `b1-home-offline`, `b1-home-approx`,
/// `b1-home-denied`). Nil leaves the companion's usual line (`companionAmbientThought`, Home's own order).
///
/// A stamp just earned speaks first, as everywhere: that is the usual line's own first rule, so the map
/// stays quiet while one is waiting. Then a friend arriving, then the day marked unwell, then the
/// weather, then where the map is (no signal, approximate, location off).
enum WorldMapLine {
    /// The facts the line reads.
    struct Facts: Equatable, Sendable {
        var stampWaiting = false
        var friendName: String?
        var isUnwell = false
        var sky: AmbientSky?
        var presence: WorldMapPresence = .precise
        var isOffline = false
    }

    /// The map's own line for `facts`, or nil for the companion's usual one.
    static func line(_ facts: Facts) -> String? {
        guard !facts.stampWaiting else { return nil }
        if let name = facts.friendName {
            return String(localized: "worldLine.friend", defaultValue: "\(name)'s here!",
                          comment: "World Home, the companion's speech when a friend comes into range; their first name")
        }
        if facts.isUnwell {
            return String(localized: "worldLine.unwell", defaultValue: "Staying in today. The map will keep.",
                          comment: "World Home, the companion's speech on a day marked unwell")
        }
        if let weather = weatherLine(facts.sky) { return weather }
        return placeLine(facts)
    }

    /// The weather's line, for rain and snow only (the Today panel keeps the weather card).
    private static func weatherLine(_ sky: AmbientSky?) -> String? {
        switch sky {
        case .rain:
            return String(localized: "worldLine.rain", defaultValue: "Rain on the map. A cozy indoor day?",
                          comment: "World Home, the companion's speech while it rains where the person is")
        case .snow:
            return String(localized: "worldLine.snow", defaultValue: "Snow out there. Warm socks day?",
                          comment: "World Home, the companion's speech while it snows where the person is")
        default:
            return nil
        }
    }

    /// Where the map is: offline, approximate or off.
    private static func placeLine(_ facts: Facts) -> String? {
        if facts.presence == .off {
            return String(localized: "worldLine.off", defaultValue: "Here with you, wherever we are.",
                          comment: "World Home with location off: the companion's speech in its open scene")
        }
        if facts.isOffline {
            return String(localized: "worldLine.offline", defaultValue: "No signal? I still know the way.",
                          comment: "World Home offline: the companion's speech")
        }
        if facts.presence == .approximate {
            return String(localized: "worldLine.approximate", defaultValue: "Somewhere around here!",
                          comment: "World Home with approximate location: the companion's speech")
        }
        return nil
    }
}

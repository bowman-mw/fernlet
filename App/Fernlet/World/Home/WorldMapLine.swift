import AppServices
import Foundation

/// The companion's line on the map, when the map has something of its own to say (designs
/// `b1-home-friend`, `b1-home-weather`, `b1-home-sick`, `b1-home-offline`, `b1-home-approx`,
/// `b1-home-denied`). Nil leaves the companion's usual line (`companionAmbientThought`, Home's own order).
///
/// A stamp just earned speaks first, as everywhere: that is the usual line's own first rule, so the map
/// stays quiet while one is waiting. Then Sprout's greeting at a home or hotel (round 6), said once, then a
/// place found for the first time (round 7, World-Exploration-Spec §4, ``WorldDiscoveryRouter``), said once, then a
/// friend arriving, then the day marked unwell, then the night
/// (`b1-home-night`: the map's night or the companion's bedtime, so no day's line is said over the
/// sleepy face), then the weather, then where the map is (no signal, approximate, location off), and last the
/// week's new corner (round 7, spec §5), mentioned once when nothing else has a line, never at night or in rain.
enum WorldMapLine {
    /// The facts the line reads.
    struct Facts: Equatable, Sendable {
        var stampWaiting = false
        var friendName: String?
        var isUnwell = false
        var sky: AmbientSky?
        var presence: WorldMapPresence = .precise
        var isOffline = false
        /// The map's night, or the companion's own bedtime: it is winding down.
        var isNight = false
        /// Sprout's greeting on getting home or checking in at a hotel (round 6, `ref-home-arrive`,
        /// `ref-hotel`), said once.
        var homeGreeting: String?
        /// Sprout's line for a place found for the first time (round 7, spec §4), said once.
        var discovery: String?
        /// Sprout's mention of the week's new corner (round 7, spec §5), said once.
        var cornerNudge: String?
    }

    /// The map's own line for `facts`, or nil for the companion's usual one.
    static func line(_ facts: Facts) -> String? {
        guard !facts.stampWaiting else { return nil }
        if let greeting = facts.homeGreeting { return greeting }
        if let discovery = facts.discovery { return discovery }
        if let name = facts.friendName {
            return String(localized: "worldLine.friend", defaultValue: "\(name)'s here!",
                          comment: "World Home, the companion's speech when a friend comes into range; their first name")
        }
        if facts.isUnwell {
            return String(localized: "worldLine.unwell", defaultValue: "Staying in today. The map will keep.",
                          comment: "World Home, the companion's speech on a day marked unwell")
        }
        if facts.isNight {
            return String(localized: "worldLine.night", defaultValue: "Getting sleepy. Night soon.",
                          comment: "World Home at night or past the companion's bedtime: the companion's speech as it winds down")
        }
        if let weather = weatherLine(facts.sky) { return weather }
        return placeLine(facts) ?? facts.cornerNudge
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

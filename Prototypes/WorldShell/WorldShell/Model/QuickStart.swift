import Foundation

/// What a quick-start row does when tapped.
nonisolated enum QuickStartAction: Sendable, Equatable {
    /// Starts the guided runner (in the shell: a toast saying so).
    case workout(message: String)
    /// Starts the saved trail's hike, replayed from its recorded line.
    case hike
    /// Starts a walk together, replayed from the recorded walk for this spot.
    case walk
    /// Logs your usual meal here.
    case logUsual
    /// Searches the place's menu by name only.
    case menuSearch
}

/// One row on the quick-start card.
nonisolated struct QuickStartOption: Identifiable, Sendable {
    let id: String
    let icon: PixelSprite
    let title: String
    let subtitle: String
    let action: QuickStartAction
}

/// The blue button's brain: which known place you're standing at, and what it offers there.
///
/// Matching happens on the phone against your own places, within about 100 m (design page, "It
/// matches on this iPhone"). In the shell the places are fixtures and "where you are" is the
/// companion's fixture position. A decoy session knows no places, so it only offers a walk.
nonisolated enum QuickStart {
    /// The radius within which you count as "at" a place.
    static let matchRadius = 100.0

    /// The known place nearest `position`, if one is within ``matchRadius``.
    static func match(position: GeoPoint, level: TimeWithFernlet, decoy: Bool) -> FixtureSpot? {
        guard !decoy else { return nil }
        let known = FixtureSpot.allCases.filter { level.visits(to: $0) > 0 }
        let near = known.filter { $0.location.distance(to: position) <= matchRadius }
        return near.min { $0.location.distance(to: position) < $1.location.distance(to: position) }
    }

    /// The card's heading line under the place name.
    static func seenLine(for spot: FixtureSpot?, level: TimeWithFernlet) -> String {
        guard let spot else { return "Nothing saved here yet. It shows up once you've trained, hiked or eaten here a few times." }
        let visits = level.visits(to: spot)
        switch spot {
        case .home: return "Your Home space · trained here \(visits) times"
        case .gym: return "You've trained here \(visits) times"
        case .trail: return "You've walked this trail \(visits) times"
        case .noodle: return "You've logged meals here \(visits) times"
        case .fresh: return "Nowhere you've been before."
        }
    }

    /// The rows the card offers at `spot` (nil: nowhere known).
    static func options(at spot: FixtureSpot?, level: TimeWithFernlet) -> [QuickStartOption] {
        var rows: [QuickStartOption] = []
        switch spot {
        case .home:
            rows.append(QuickStartOption(id: "home", icon: PixelSprites.dumbbell, title: "Upper body",
                                         subtitle: "Your Home space · 6 exercises · about 40 min",
                                         action: .workout(message: "The guided runner starts with your Home equipment.")))
        case .gym:
            rows.append(QuickStartOption(id: "gym", icon: PixelSprites.dumbbell, title: "Upper body",
                                         subtitle: "Riverside Gym · 7 exercises · about 45 min",
                                         action: .workout(message: "The guided runner starts with Riverside Gym's equipment and weights.")))
        case .trail:
            rows.append(QuickStartOption(id: "hike", icon: PixelSprites.tree, title: "Hike the Oak Park loop",
                                         subtitle: "\(trailKilometres) km · your saved trail", action: .hike))
        case .noodle:
            rows.append(QuickStartOption(id: "usual", icon: PixelSprites.bowl, title: "Log your usual: tonkotsu ramen",
                                         subtitle: "From your \(level.visits(to: .noodle)) meals here", action: .logUsual))
            rows.append(QuickStartOption(id: "menu", icon: PixelSprites.bowl, title: "Find Hoshi Noodle Bar's menu",
                                         subtitle: "Searches the web by name. Your location isn't sent.", action: .menuSearch))
        case .fresh, .none:
            break
        }
        if spot != .trail && spot != .noodle {
            rows.append(QuickStartOption(id: "walk", icon: PixelSprites.boot, title: "Walk together",
                                         subtitle: "Precise location for this walk only", action: .walk))
        }
        return rows
    }

    /// The saved trail's length, from its recorded line.
    static let trailKilometres = String(format: "%.1f", Polyline(RecordedRoutes.parkLoop).length / 1_000)

    /// The blue button's icon at `spot`.
    static func buttonIcon(at spot: FixtureSpot?) -> PixelSprite {
        switch spot {
        case .home, .gym: PixelSprites.dumbbell
        case .trail: PixelSprites.tree
        case .noodle: PixelSprites.bowl
        case .fresh, .none: PixelSprites.boot
        }
    }
}

import Foundation
import WorldMapStore

/// A city's size class on the screens: the spec's five skylines (World-Exploration-Spec §2, `ex-skylines`)
/// from the pack's four sizes (a frozen token).
///
/// The pack sizes a city by its population (`AtlasCitySize`: a town under 100,000, a city, a large city from a
/// million, a megacity from ten million). The spec adds a **village**, so a `town` under ``villageCeiling``
/// people is a village (lane call, round 7: one shared mapping for the world view, Home's markers and the city
/// card). Each class has one pixel skyline (``WorldCitySkyline``): a spire, a clock tower, one tower, towers,
/// and a spire among towers.
nonisolated enum WorldCitySizeClass: String, CaseIterable, Comparable, Sendable {
    case village, town, city, bigCity, megacity

    /// The population a village stays under: a `town` with fewer people is a village.
    static let villageCeiling = 20_000

    /// The class of `city`: its pack size, with a small town counted a village.
    init(city: AtlasCity) {
        self.init(size: city.size, population: city.population)
    }

    /// The class of a city of pack size `size` with `population` people.
    init(size: AtlasCitySize, population: Int) {
        switch size {
        case .town: self = population < Self.villageCeiling ? .village : .town
        case .city: self = .city
        case .large: self = .bigCity
        case .mega: self = .megacity
        }
    }

    /// The class's place from the smallest (0, a village) to the biggest (4, a megacity): its skyline's index.
    var rank: Int {
        switch self {
        case .village: 0
        case .town: 1
        case .city: 2
        case .bigCity: 3
        case .megacity: 4
        }
    }

    /// Classes compare by ``rank``: a megacity is the biggest.
    static func < (lhs: WorldCitySizeClass, rhs: WorldCitySizeClass) -> Bool { lhs.rank < rhs.rank }

    /// The class's display name ("Village", "Big city"), for the city card and VoiceOver.
    var title: LocalizedStringResource {
        switch self {
        case .village:
            LocalizedStringResource("worldCity.size.village", defaultValue: "Village",
                                    comment: "World: a city's size class, the smallest (a town under 20,000 people)")
        case .town:
            LocalizedStringResource("worldCity.size.town", defaultValue: "Town",
                                    comment: "World: a city's size class, under 100,000 people")
        case .city:
            LocalizedStringResource("worldCity.size.city", defaultValue: "City",
                                    comment: "World: a city's size class, 100,000 to a million people")
        case .bigCity:
            LocalizedStringResource("worldCity.size.bigCity", defaultValue: "Big city",
                                    comment: "World: a city's size class, a million to ten million people")
        case .megacity:
            LocalizedStringResource("worldCity.size.megacity", defaultValue: "Megacity",
                                    comment: "World: a city's size class, ten million people or more")
        }
    }
}

import Foundation

/// Where the fixture says you're standing. Each spot is a real street corner around Laurelhurst
/// Park, Portland (a public park picked as a neutral example); the names are the design page's.
nonisolated enum FixtureSpot: String, CaseIterable, Identifiable, Sendable {
    case home, gym, trail, noodle, fresh

    var id: String { rawValue }

    /// The fixture control's label.
    var label: String {
        switch self {
        case .home: "Home space"
        case .gym: "Riverside Gym"
        case .trail: "Oak Park loop start"
        case .noodle: "Hoshi Noodle Bar"
        case .fresh: "Somewhere new"
        }
    }

    /// Where the spot is.
    var location: GeoPoint {
        switch self {
        case .home: GeoPoint(45.517934, -122.617795)
        case .gym: GeoPoint(45.516447, -122.629556)
        case .trail: GeoPoint(45.520273, -122.623031)
        case .noodle: GeoPoint(45.516440, -122.625855)
        case .fresh: GeoPoint(45.526447, -122.614988)
        }
    }

    /// The recorded walk the shell replays when you walk together from here.
    var walkRoute: [GeoPoint] {
        switch self {
        case .home: RecordedRoutes.walkTogether
        case .gym: RecordedRoutes.gymWalk
        case .trail: RecordedRoutes.parkLoop
        case .noodle: RecordedRoutes.noodleWalk
        case .fresh: RecordedRoutes.freshWalk
        }
    }
}

/// How long the fixture person has had Fernlet. It sets what history exists: coins, gold hearts,
/// friend photos, visit counts and saved trails (the design page's "Time with Fernlet" control).
nonisolated enum TimeWithFernlet: String, CaseIterable, Identifiable, Sendable {
    case dayOne, month, year

    var id: String { rawValue }

    /// The fixture control's label.
    var label: String {
        switch self {
        case .dayOne: "Day one"
        case .month: "A month"
        case .year: "A year"
        }
    }

    /// The coin balance (5 coins per active day, `CoinEconomy`).
    var coins: Int {
        switch self {
        case .dayOne: 5
        case .month: 135
        case .year: 1_180
        }
    }

    /// Gold hearts from friends in the last 12 hours, at most two.
    var goldHearts: Int {
        switch self {
        case .dayOne: 0
        case .month: 1
        case .year: 2
        }
    }

    /// How many times you've been to `spot` (0 means Fernlet doesn't know it yet).
    func visits(to spot: FixtureSpot) -> Int {
        switch (self, spot) {
        case (.dayOne, _), (_, .fresh): 0
        case (.month, .home): 6
        case (.month, .gym): 4
        case (.month, .trail): 3
        case (.month, .noodle): 4
        case (.year, .home): 52
        case (.year, .gym): 38
        case (.year, .trail): 17
        case (.year, .noodle): 31
        }
    }

    /// The saved routes and trails drawn on the map.
    var savedTrails: [[GeoPoint]] {
        switch self {
        case .dayOne: []
        case .month: [RecordedRoutes.homeToPark, RecordedRoutes.parkLoop]
        case .year: [RecordedRoutes.homeToPark, RecordedRoutes.parkLoop, RecordedRoutes.riverRoad]
        }
    }

    /// Whether the friend photo wall has anything on it yet.
    var hasPhotos: Bool { self != .dayOne }
}

/// A fixture photo: a two-colour wash and a symbol, standing in for a real picture.
nonisolated struct FixturePhoto: Identifiable, Sendable {
    let id: String
    let top: UInt32
    let bottom: UInt32
    let symbol: String
}

/// The shell's fixed fixture data that doesn't depend on a control.
nonisolated enum WorldFixtures {
    /// The fog grid's origin, near the park's east gate.
    static let grid = HexGrid(origin: GeoPoint(45.5200, -122.6230), radius: 35)

    /// Friend photos for the wall, picked "fresh each launch" in the app; fixed here.
    static let friendPhotos: [FixturePhoto] = [
        FixturePhoto(id: "Picnic", top: 0xE7C9A0, bottom: 0xC09862, symbol: "basket.fill"),
        FixturePhoto(id: "Lake day", top: 0xBFD3E0, bottom: 0x7FA7C4, symbol: "water.waves"),
        FixturePhoto(id: "Board games", top: 0xD9B8B0, bottom: 0xAF8478, symbol: "dice.fill"),
        FixturePhoto(id: "Market", top: 0xC9DBB8, bottom: 0x8DB27A, symbol: "carrot.fill"),
        FixturePhoto(id: "Hike", top: 0xE6D49B, bottom: 0xB49E58, symbol: "mountain.2.fill"),
    ]

    /// The Recent bites print that sits among the friend photos on the full wall.
    static let recentBite = FixturePhoto(id: "Lentil soup", top: 0xE2C08E, bottom: 0xB98A4E, symbol: "mug.fill")

    /// Your own lunch photo, where you ate it (beside the noodle bar).
    static let lunchPhoto = FixtureSpot.noodle.location.offset(east: 22, north: 6)

    /// Your own photo from the Oak Park loop, where you took it.
    static let hikePhoto = GeoPoint(45.5214, -122.6286)

    /// Today's macro targets in grams (MacroCard's protein, carbs, fat).
    static let macroTargets = (protein: 90, carbs: 230, fat: 65)
}

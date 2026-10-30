import AppServices
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Sprout's lines when you find somewhere new (World-Exploration-Spec §4) and the weekly corner's words and
/// mention (§5): the category mapping, the turns, once per place, the city over the biome, the specials, a decoy's
/// silence, the router's fan-out to the lines and the new-stamp hook, and the corner's VoiceOver words.
@MainActor
struct WorldDiscoveryLinesTests {
    nonisolated static let day = Date(timeIntervalSince1970: 1_793_275_200)

    /// Places whose names are their tokens; every city is a city-size city but `hood` (a village) and `tokyo`.
    static let places = WorldDiscoveryPlaces(
        city: { token in
            switch token {
            case "hood": (name: "Hood River", size: .village)
            case "tokyo": (name: "Tokyo", size: .megacity)
            case "nowhere": nil
            default: (name: token.capitalized, size: .city)
            }
        },
        landmark: { $0 == "eiffelTower" ? "Eiffel Tower" : nil },
        sea: { _ in "Salish Sea" },
        country: { $0 == "CA" ? "Canada" : $0 })

    /// A passport holding `discoveries`.
    static func book(_ discoveries: [AtlasDiscovery]) throws -> PassportBook {
        try PassportBook(discoveries: discoveries)
    }

    /// A discovery of `kind`/`token` `minutes` after ``day``.
    static func found(_ kind: AtlasDiscoveryKind, _ token: String, _ minutes: Double = 0) -> AtlasDiscovery {
        AtlasDiscovery(kind: kind, token: token, at: day.addingTimeInterval(minutes * 60))
    }

    // MARK: The categories

    @Test func everyTerrainClassHasItsCategoryAndCroplandNone() {
        let expected: [AtlasTerrain: WorldLineCategory] = [
            .water: .shore, .ice: .ice, .tundra: .tundra, .mountain: .mountain, .borealForest: .borealForest,
            .temperateForest: .temperateForest, .tropicalForest: .tropicalForest, .savanna: .grassland,
            .grassland: .grassland, .desert: .desert, .shrubland: .grassland
        ]
        for terrain in AtlasTerrain.allCases {
            #expect(WorldLineCategory(terrain: terrain) == expected[terrain], "\(terrain)")
        }
        #expect(!AtlasTerrain.allCases.contains { WorldLineCategory(terrain: $0) == .cropland }, "no land cover in the pack")
        #expect(WorldCitySizeClass.allCases.map { WorldLineCategory(size: $0) } == [.village, .town, .city, .bigCity, .megacity])
    }

    @Test func theBoardsHoldThe66LinesInTheMockupsOrder() {
        #expect(WorldLineBoard.allCases.map { $0.categories.count } == [5, 5, 5, 3, 4])
        #expect(WorldLineCategory.allCases.count * WorldDiscoveryLine.linesPerCategory == 66)
        for category in WorldLineCategory.allCases {
            let lines = WorldDiscoveryLinesCopy.lines(category, name: "Zed")
            #expect(lines.count == 3, "\(category)")
            #expect(Set(lines).count == 3 && lines.allSatisfy { !$0.isEmpty }, "\(category)")
        }
        #expect(WorldDiscoveryLinesCopy.line(.desert, index: 0, name: "") == "Sand! Everything's so quiet here.")
        #expect(WorldDiscoveryLinesCopy.line(.village, index: 1, name: "Hood River") == "Hood River! Small and sweet.")
        #expect(WorldDiscoveryLinesCopy.line(.ocean, index: 0, name: "Pacific") == "The Pacific! Hello, big water.")
        #expect(WorldDiscoveryLinesCopy.line(.allOceans, index: 2, name: "") == "The whole world's water. Wow.")
        #expect(WorldDiscoveryLinesCopy.line(.city, index: 3, name: "X") == WorldDiscoveryLinesCopy.line(.city, index: 0, name: "X"),
                "turns wrap")
    }

    @Test func theNameIsFilledInWhereTheLineHasOne() throws {
        let tokyo = Self.found(.city, "tokyo")
        let line = try #require(WorldLinePicker.line(for: tokyo, in: try Self.book([tokyo]), places: Self.places, isDecoy: false))
        #expect(line.category == .megacity && line.name == "Tokyo")
        #expect(line.text == "Tokyo! I don't think it ends.")
        let canada = Self.found(.country, "CA")
        let country = try #require(WorldLinePicker.line(for: canada, in: try Self.book([canada]), places: Self.places, isDecoy: false))
        #expect(country.text == "A new country! Canada.")
    }

    // MARK: Once per place, turns, decoy

    @Test func sproutTakesTurnsByThePassportsOwnOrder() throws {
        let cities = (0..<4).map { Self.found(.city, "c\($0)", Double($0)) }
        let book = try Self.book(cities)
        let turns = try cities.map { try #require(WorldLinePicker.line(for: $0, in: book, places: Self.places, isDecoy: false)).index }
        #expect(turns == [0, 1, 2, 0])
    }

    @Test func aLineOnlyForTheFirstVisitTheBookHolds() throws {
        let desert = Self.found(.terrain, AtlasTerrain.desert.rawValue)
        let book = try Self.book([desert])
        #expect(WorldLinePicker.line(for: desert, in: book, places: Self.places, isDecoy: false)?.category == .desert)
        let later = Self.found(.terrain, AtlasTerrain.desert.rawValue, 90)
        #expect(WorldLinePicker.line(for: later, in: book, places: Self.places, isDecoy: false) == nil,
                "a date the book doesn't hold for it (a restore, a repeat) says nothing")
        #expect(WorldLinePicker.line(for: desert, in: PassportBook(), places: Self.places, isDecoy: false) == nil)
        #expect(WorldLinePicker.line(for: desert, in: book, places: Self.places, isDecoy: true) == nil, "a decoy says nothing")
        let unknown = Self.found(.city, "nowhere")
        #expect(WorldLinePicker.line(for: unknown, in: try Self.book([unknown]), places: Self.places, isDecoy: false) == nil)
    }

    @Test func theSpecialsReplaceTheLastContinentAndOcean() throws {
        let continents = AtlasContinent.allCases.enumerated().map { Self.found(.continent, $1.rawValue, Double($0)) }
        let book = try Self.book(continents)
        let last = try #require(continents.last)
        #expect(WorldLinePicker.line(for: last, in: book, places: Self.places, isDecoy: false)?.category == .allContinents)
        #expect(WorldLinePicker.line(for: continents[0], in: book, places: Self.places, isDecoy: false)?.category == .continent)
        #expect(WorldLinePicker.stamps(for: last, in: book).map(\.kind) == [.continent, .allContinents])
        let oceans = AtlasOcean.allCases.enumerated().map { Self.found(.ocean, $1.rawValue, Double($0)) }
        let seas = try Self.book(oceans)
        let fifth = try #require(oceans.last)
        #expect(WorldLinePicker.line(for: fifth, in: seas, places: Self.places, isDecoy: false)?.category == .allOceans)
        #expect(WorldLinePicker.stamps(for: fifth, in: seas).map(\.kind) == [.ocean, .allOceans])
        #expect(WorldLinePicker.line(for: oceans[0], in: seas, places: Self.places, isDecoy: false)?.text
                == "The Pacific! Hello, big water.")
    }

    // MARK: The router

    @Test func theCityBeatsTheBiomeEitherWayRound() throws {
        let city = Self.found(.city, "portland"), ground = Self.found(.terrain, AtlasTerrain.temperateForest.rawValue)
        let book = try Self.book([city, ground])
        for order in [[city, ground], [ground, city]] {
            let router = WorldDiscoveryRouter()
            for discovery in order { router.route(.firstVisit(discovery), book: book, places: Self.places, isDecoy: false) }
            #expect(router.line?.category == .city, "\(order.map(\.kind))")
        }
    }

    @Test func oneLineAtATimeAndTheNextFixReplacesIt() throws {
        let country = Self.found(.country, "CA"), city = Self.found(.city, "victoria"), next = Self.found(.terrain, "ice", 30)
        let book = try Self.book([country, city, next])
        let router = WorldDiscoveryRouter()
        router.route(.firstVisit(country), book: book, places: Self.places, isDecoy: false)
        router.route(.firstVisit(city), book: book, places: Self.places, isDecoy: false)
        #expect(router.line?.category == .country, "a new country beats a city")
        router.route(.firstVisit(next), book: book, places: Self.places, isDecoy: false)
        #expect(router.line?.category == .ice, "a later fix's line comes next")
        router.clearLine()
        #expect(router.line == nil)
    }

    @Test func linesHearFirstVisitsOnlyAndTheStampHookHearsStampsAndTrips() throws {
        let canada = Self.found(.country, "CA"), america = Self.found(.continent, AtlasContinent.northAmerica.rawValue)
        let sea = Self.found(.sea, "Q1"), city = Self.found(.city, "victoria"), park = Self.found(.landmark, "eiffelTower")
        let ground = Self.found(.terrain, "ice")
        let book = try Self.book([canada, america, sea, city, park, ground])
        let router = WorldDiscoveryRouter()
        var stamps: [PassportStamp] = []
        router.onNewStamp = { stamps.append($0) }
        let trip = PassportStamp(kind: .country, token: "CA", date: Self.day.addingTimeInterval(9 * 86_400), trip: 2)
        router.route(.newTrip(trip), book: book, places: Self.places, isDecoy: false)
        #expect(router.line == nil, "a new trip says nothing")
        for discovery in [canada, america, sea, city, park, ground] {
            router.route(.firstVisit(discovery), book: book, places: Self.places, isDecoy: false)
        }
        #expect(stamps.map(\.kind) == [.country, .country, .continent, .sea])
        #expect(stamps.first?.trip == 2 && stamps.dropFirst().allSatisfy { $0.trip == 1 })
        #expect(router.line?.category == .continent)
        let silent = WorldDiscoveryRouter()
        var heard = 0
        silent.onNewStamp = { _ in heard += 1 }
        silent.route(.firstVisit(canada), book: book, places: Self.places, isDecoy: true)
        silent.route(.newTrip(trip), book: book, places: Self.places, isDecoy: true)
        #expect(silent.line == nil && heard == 0, "a decoy hears nothing")
    }

    @Test func aLandmarksLinePlaysOnce() throws {
        let park = Self.found(.landmark, "eiffelTower")
        let book = try Self.book([park])
        let router = WorldDiscoveryRouter()
        router.route(.firstVisit(park), book: book, places: Self.places, isDecoy: false, now: Self.day)
        #expect(router.line?.text == "Eiffel Tower! I've heard about this.")
        router.route(.firstVisit(park), book: book, places: Self.places, isDecoy: false, now: Self.day.addingTimeInterval(5))
        #expect(router.lineArrived == Self.day, "the same find again is not a second line")
        // The cities piece's `WorldExploreState.onLandmarkFound` stays unattached (Home sets nothing on it): the
        // stream is the one source of a landmark's line.
    }

    @Test func aLineThatWaitedTooLongIsStale() throws {
        let desert = Self.found(.terrain, "desert")
        let router = WorldDiscoveryRouter()
        router.route(.firstVisit(desert), book: try Self.book([desert]), places: Self.places, isDecoy: false, now: Self.day)
        #expect(!router.isStale(at: Self.day.addingTimeInterval(60)))
        #expect(router.isStale(at: Self.day.addingTimeInterval(WorldDiscoveryRouter.staleAfter + 1)))
    }

    // MARK: The week's corner

    @Test func theCornersVoiceOverWords() {
        #expect(WorldCornerCopy.spoken(FogCornerBearing(metres: 304, compass: .ne)) == "A new corner, 300 metres north-east")
        #expect(WorldCornerCopy.spoken(FogCornerBearing(metres: 980, compass: .sw)) == "A new corner, 1000 metres south-west")
        #expect(WorldCornerCopy.rounded(126) == 150 && WorldCornerCopy.rounded(74) == 70 && WorldCornerCopy.rounded(.nan) == 0)
        #expect(Set(CompassPoint.allCases.map { String(localized: WorldCornerCopy.compass($0)) }).count == 8)
        #expect(String(localized: WorldCornerCopy.bubble) == "There's a new corner nearby. Fancy a look?")
    }

    @Test func sproutMentionsANewPickOnceAndNeverALoadedOne() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldCornerNudgeTests.keeper(vault)
        let cell = try #require(keeper.current(home: WorldCornerNudgeTests.home, revealed: [], now: WorldCornerNudgeTests.thursday))
        #expect(keeper.unannounced == cell)
        #expect(keeper.takeUnannounced() == cell)
        #expect(keeper.takeUnannounced() == nil, "once")
        _ = keeper.current(home: WorldCornerNudgeTests.home, revealed: [], now: WorldCornerNudgeTests.thursday)
        #expect(keeper.unannounced == nil, "the same week's corner again is not new")
        let relaunched = WorldCornerNudgeTests.keeper(vault)
        _ = relaunched.current(home: WorldCornerNudgeTests.home, revealed: [], now: WorldCornerNudgeTests.thursday)
        #expect(relaunched.unannounced == nil, "a corner read from the file was mentioned before")
        let nextWeek = WorldCornerNudgeTests.thursday.addingTimeInterval(WorldCornerNudgeTests.week)
        let next = try #require(relaunched.current(home: WorldCornerNudgeTests.home, revealed: [], now: nextWeek))
        #expect(relaunched.unannounced == next)
        relaunched.noteRevealed([next])
        #expect(relaunched.takeUnannounced() == nil, "walked into before Sprout said it: nothing to say")
    }

    @Test func noCornerMentionInADecoyOrAfterAWipe() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldCornerNudgeTests.keeper(vault)
        _ = try #require(keeper.current(home: WorldCornerNudgeTests.home, revealed: [], now: WorldCornerNudgeTests.thursday))
        keeper.setDecoy(true)
        #expect(keeper.takeUnannounced() == nil)
        keeper.setDecoy(false)
        let other = WorldCornerNudgeTests.keeper(WorldMapVault.ephemeral())
        _ = other.current(home: WorldCornerNudgeTests.home, revealed: [], now: WorldCornerNudgeTests.thursday)
        _ = other.clearAll()
        #expect(other.takeUnannounced() == nil)
        #expect(keeper.current(home: nil, revealed: [], now: WorldCornerNudgeTests.thursday) == nil, "no home: nothing")
    }

    @Test func theMapsLineOrderPutsTheDiscoveryAfterTheGreetingAndTheCornerLast() {
        var facts = WorldMapLine.Facts()
        facts.cornerNudge = "corner"
        #expect(WorldMapLine.line(facts) == "corner")
        facts.discovery = "found"
        #expect(WorldMapLine.line(facts) == "found")
        facts.homeGreeting = "home"
        #expect(WorldMapLine.line(facts) == "home")
        facts.stampWaiting = true
        #expect(WorldMapLine.line(facts) == nil, "a stamp waiting speaks first")
        var rainy = WorldMapLine.Facts()
        rainy.cornerNudge = "corner"
        rainy.sky = .rain
        #expect(WorldMapLine.line(rainy) != "corner", "never in rain")
        rainy.sky = nil
        rainy.isNight = true
        #expect(WorldMapLine.line(rainy) != "corner", "never at night")
    }
}

import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Made-up grounds for the trip keeper's tests.
private nonisolated struct TripGrounds: AirportGroundsLookup {
    let all: [WorldAirport]

    func airports(containing point: GeoPoint) -> [WorldAirport] {
        // Bounded: one airport.
        all.filter { $0.contains(point) }
    }
}

/// Take a trip (World-Airports-Spec §5, §7, §10.7) with made-up airports (Cedar Field near a Portland-ish town,
/// Fernhaven's three in the United Kingdom, Bogotá's one; a Portland traveller on Cedar Air, never anyone's real
/// flights): the ticket's suggestion search, the destination's codes, Sprout's boarding pass, the barcode, the blue
/// button's trip row, and the keeper sealing the ticket (and nothing in a decoy).
@MainActor
struct WorldTripTests {
    nonisolated static let day = Date(timeIntervalSince1970: 1_793_275_200)

    /// A made-up airport.
    nonisolated static func airport(_ code: String?, _ point: GeoPoint, city: String, name: String, country: String = "GB",
                        size: WorldAirportSize = .large, spanishCity: String? = nil) -> WorldAirport {
        WorldAirport(token: code ?? "X" + name, iata: code, ident: "E" + (code ?? name), point: point, countryCode: country,
                     size: size, timeZoneIdentifier: "Europe/London", englishName: name, spanishName: nil,
                     englishCity: city, spanishCity: spanishCity, grounds: .circle(radiusMetres: 1_500))
    }

    nonisolated static let cedarPoint = GeoPoint(45.6, -122.6)
    nonisolated static let cedar = airport("CED", cedarPoint, city: "Cedarville", name: "Cedar Field International", country: "US")
    nonisolated static let fernA = airport("FHA", GeoPoint(51.47, -0.45), city: "Fernhaven", name: "Fernhaven Heath",
                               spanishCity: "Helechal")
    nonisolated static let fernB = airport("FHB", GeoPoint(51.15, -0.18), city: "Fernhaven", name: "Gatefern")
    nonisolated static let fernC = airport("FHC", GeoPoint(51.88, 0.23), city: "Fernhaven", name: "Stanfern", size: .medium)
    nonisolated static let fernhill = airport("FHL", GeoPoint(47.0, -120.0), city: "Fernhill", name: "Fernhill Municipal",
                                  country: "US", size: .medium)
    nonisolated static let bogota = airport("BGX", GeoPoint(4.7, -74.1), city: "Bogotá", name: "El Dorado Pequeño", country: "CO")
    nonisolated static let noCode = airport(nil, GeoPoint(51.0, 0.0), city: "Fernhaven", name: "Fernhaven Strip")
    nonisolated static let all = [cedar, fernA, fernB, fernC, fernhill, bogota, noCode]

    // MARK: Suggestions

    @Test func aCityWithSeveralAirportsComesFirstThenItsAirports() {
        let found = WorldTripSuggestions.search("Fern", in: Self.all, spanish: false, limit: 3)
        #expect(found.count == 3)
        #expect(found.first?.destination == WorldTripDestination.city(codes: ["FHA", "FHB", "FHC"]))
        #expect(found.first?.city == "Fernhaven")
        #expect(found.dropFirst().map(\.destination.code) == ["FHA", "FHB"], "larger airports first, then by code")
        #expect(WorldTripCopy.title(found[0]).hasPrefix("Fernhaven · "))
        #expect(WorldTripCopy.detail(found[0]) == "FHA, FHB, FHC")
        #expect(WorldTripCopy.title(found[1]) == "FHA · Fernhaven Heath")
        #expect(WorldTripCopy.detail(found[1]) == "Fernhaven")
    }

    @Test func twoSuggestionsAtTheLargestText() {
        #expect(WorldTripSuggestions.limit(accessibilitySize: true) == 2)
        #expect(WorldTripSuggestions.limit(accessibilitySize: false) == 3)
        let found = WorldTripSuggestions.search("fern", in: Self.all, spanish: false, limit: 2)
        #expect(found.map(\.destination.kind) == [.city, .airport])
    }

    @Test func anExactCodeLeadsAndAirportsWithoutACodeNeverShow() {
        let found = WorldTripSuggestions.search(" fhc ", in: Self.all, spanish: false, limit: 3)
        #expect(found.first?.destination == .airport("FHC"))
        #expect(!WorldTripSuggestions.search("Fernhaven Strip", in: Self.all, spanish: false, limit: 3)
            .contains { $0.name == "Fernhaven Strip" })
        #expect(WorldTripSuggestions.search("", in: Self.all, spanish: false, limit: 3).isEmpty)
        #expect(WorldTripSuggestions.search("   ", in: Self.all, spanish: false, limit: 3).isEmpty)
        #expect(WorldTripSuggestions.search("Fern", in: Self.all, spanish: false, limit: 0).isEmpty)
    }

    @Test func accentsCaseSpanishCitiesAndNameWordsMatch() {
        #expect(WorldTripSuggestions.search("bogota", in: Self.all, spanish: false, limit: 3).first?.destination == .airport("BGX"))
        #expect(WorldTripSuggestions.search("helech", in: Self.all, spanish: true, limit: 3).first?.city == "Helechal")
        let byName = WorldTripSuggestions.search("intern", in: Self.all, spanish: false, limit: 3)
        #expect(byName.map(\.destination.code) == ["CED"])
        #expect(WorldTripSuggestions.rank(Self.cedar, query: "zzz") == nil)
    }

    // MARK: The destination

    @Test func aCityNeedsTwoAirportsAndKeepsFive() throws {
        #expect(WorldTripDestination.city(codes: ["FHA"]) == nil)
        let city = try #require(WorldTripDestination.city(codes: ["fha", "FHB", "FHC", "FHD", "FHE", "FHF"]))
        #expect(city.code == "FHA" && city.cityCodes.count == WorldTripDestination.maxCityCodes)
        #expect(city.includes("fhb") && !city.includes("FHF"))
        #expect(WorldTripDestination.airport("ced").includes("CED"))
        let ticket = WorldTripTicket(destination: city, startedAt: Self.day)
        let back = try JSONDecoder().decode(WorldTripTicket.self, from: JSONEncoder().encode(ticket))
        #expect(back == ticket)
    }

    // MARK: The boarding pass

    static func flight(_ from: String, _ to: String, hoursAfter: Double, sources: PassportFlight.Sources = .fernlet) -> PassportFlight? {
        PassportFlight(from: from, to: to, departure: day.addingTimeInterval(hoursAfter * 3_600),
                       arrival: day.addingTimeInterval((hoursAfter + 9) * 3_600), sources: sources)
    }

    @Test func offATripThePassWaitsWhereverYouLand() {
        let pass = WorldBoardingPassRule.pass(at: Self.cedar, isOnTrip: false, destination: .airport("FHA"),
                                              tripStartedAt: nil, flights: [], airports: nil, spanish: false, now: Self.day)
        #expect(pass.from == WorldBoardingPass.Stop(code: "CED", place: "Cedarville"))
        #expect(pass.to == .wherever && !pass.landed && pass.date == Self.day)
    }

    @Test func onATripBeforeLandingToIsTheTicketsDestination() {
        let pass = WorldBoardingPassRule.pass(at: Self.cedar, isOnTrip: true, destination: .airport("FHA"),
                                              tripStartedAt: Self.day, flights: [], airports: nil, spanish: false, now: Self.day)
        #expect(pass.to == .stop(WorldBoardingPass.Stop(code: "FHA", place: "")), "no list: the code alone")
        #expect(!pass.landed)
    }

    @Test func aLandingFillsThePassInWithWhereYouReallyLanded() {
        let flights = [Self.flight("CED", "FHB", hoursAfter: -30), Self.flight("CED", "FHC", hoursAfter: 1),
                       Self.flight("CED", "FHA", hoursAfter: 2, sources: .flighty)].compactMap { $0 }
        let pass = WorldBoardingPassRule.pass(at: Self.cedar, isOnTrip: true, destination: .airport("FHA"),
                                              tripStartedAt: Self.day, flights: flights, airports: nil, spanish: false,
                                              now: Self.day.addingTimeInterval(12 * 3_600))
        #expect(pass.from?.code == "CED")
        #expect(pass.to == .stop(WorldBoardingPass.Stop(code: "FHC", place: "")),
                "the trip's own flight, not the ticket's To, an older flight or an imported one")
        #expect(pass.landed && pass.date == Self.day.addingTimeInterval(3_600))
    }

    @Test func aCityDestinationShowsItsNameOverItsCodes() throws {
        let city = try #require(WorldTripDestination.city(codes: ["FHA", "FHB"]))
        let stop = WorldBoardingPassRule.stop(city, airports: nil, spanish: false)
        #expect(stop == WorldBoardingPass.Stop(code: "FHA", place: "FHA, FHB"))
        #expect(WorldBoardingPassRule.city(of: city, airports: nil, spanish: false) == "FHA")
    }

    @Test func theBarcodeIsTheSameEveryTimeAndFitsItsStub() {
        let bars = WorldPassBarcode.bars()
        #expect(bars.map(\.x) == WorldPassBarcode.bars().map(\.x) && bars.map(\.width) == WorldPassBarcode.bars().map(\.width))
        #expect(bars.first?.x == 0)
        #expect(bars.count > 20 && bars.count <= Int(WorldPassBarcode.width / 2))
        #expect(bars.allSatisfy { $0.x < WorldPassBarcode.width && (1...3).contains($0.width) })
        #expect(zip(bars, bars.dropFirst()).allSatisfy { $1.x >= $0.x + $0.width + 1 }, "a gap between bars")
    }

    // MARK: The blue button's row

    static func context(airport: String? = nil, trip: WorldQuickStartOption? = .takeATrip(companion: "Sprout")) -> WorldQuickStartContext {
        var context = WorldQuickStartContext()
        context.canWalk = true
        context.airportName = airport
        context.tripOption = trip
        return context
    }

    @Test func atAnAirportTakeATripLeadsItsCard() throws {
        let card = try #require(WorldQuickStart.card(for: Self.context(airport: "Cedar Field International")))
        #expect(card.heading == .airport("Cedar Field International") && card.note == .atAirport)
        #expect(card.options == [.takeATrip(companion: "Sprout"), .walkTogether])
        #expect(WorldQuickStart.glyph(for: Self.context(airport: "Cedar Field International")) == .walk)
        #expect(WorldQuickStartCopy.detail(.takeATrip(companion: "Sprout")) == "Sprout's boarding pass: say where you're going")
    }

    @Test func elsewhereTakeATripIsTheLastRow() throws {
        var context = Self.context()
        #expect(try #require(WorldQuickStart.card(for: context)).options == [.walkTogether, .takeATrip(companion: "Sprout")])
        context.canMeetFriends = true
        #expect(try #require(WorldQuickStart.card(for: context)).options
            == [.walkTogether, .friendsNearby, .takeATrip(companion: "Sprout")])
        context.nearbyFriends = ["Sam"]
        #expect(try #require(WorldQuickStart.card(for: context)).options.last == .takeATrip(companion: "Sprout"))
    }

    @Test func onATripTheRowEndsItAndADecoyNeverOffersIt() throws {
        let card = try #require(WorldQuickStart.card(for: Self.context(airport: "Cedar Field International", trip: .endTrip(city: "Fernhaven"))))
        #expect(card.options.first == .endTrip(city: "Fernhaven"))
        #expect(WorldQuickStartCopy.title(.endTrip(city: "Fernhaven")) == "End trip · Fernhaven")
        #expect(WorldQuickStartCopy.title(.endTrip(city: nil)) == "End trip")
        var decoy = Self.context(airport: "Cedar Field International")
        decoy.isDecoy = true
        #expect(try #require(WorldQuickStart.card(for: decoy)).options == [.walkTogether])
        let withoutTrip = try #require(WorldQuickStart.card(for: Self.context(airport: "Cedar Field International", trip: nil)))
        #expect(withoutTrip.heading == .walk, "with the switch off the airport's card doesn't lead")
    }

    @Test func theTripLabelNamesTheButton() {
        #expect(WorldQuickStartLabel.buttonName(for: .walk, trip: "Trip to Fernhaven") == "Quick start, Trip to Fernhaven")
        #expect(WorldQuickStartLabel.buttonName(for: .walk) == "Quick start")
        #expect(WorldTripCopy.tripTo("Fernhaven") == "Trip to Fernhaven")
        #expect(WorldTripCopy.todayLine("Fernhaven") == "Fernhaven today? Your ticket's ready!")
    }

    // MARK: The keeper

    static func keeper(vault: WorldMapVault, home: GeoPoint? = nil) -> WorldFlightKeeper {
        let keeper = WorldFlightKeeper(grounds: { TripGrounds(all: [Self.cedar]) }, iataCode: { $0 })
        keeper.attach(vault: vault)
        if let home { keeper.isHome = { $0.distance(to: home) < 200 } }
        return keeper
    }

    static func fix(_ point: GeoPoint, minutes: Double) -> WorldFix {
        WorldFix(point: point, accuracy: 10, at: day.addingTimeInterval(minutes * 60), isPrecise: true)
    }

    @Test func startTripSealsTheTicketAndEndTripForgetsIt() throws {
        let vault = WorldMapVault.ephemeral()
        let keeper = Self.keeper(vault: vault)
        _ = keeper.admits(Self.fix(Self.cedarPoint, minutes: 0))
        #expect(keeper.startTrip(to: .airport("FHA"), at: Self.day.addingTimeInterval(60)))
        #expect(keeper.isOnTrip && keeper.showsTravelLook, "the ticket brings the travel look at the airport at once")
        #expect(keeper.latestFind?.token == "CED" && keeper.latestFind?.how == .ticket)
        #expect(keeper.tripDestination == .airport("FHA"))
        #expect(try vault.read(WorldFlightKeeper.tripFile) != nil)
        #expect(!keeper.startTrip(to: nil), "one trip at a time")
        let again = Self.keeper(vault: vault)
        #expect(again.isOnTrip && again.tripDestination == .airport("FHA"), "kept across relaunches")
        keeper.endTrip()
        #expect(!keeper.isOnTrip && keeper.tripDestination == nil)
        #expect(try vault.read(WorldFlightKeeper.tripFile) == nil)
        #expect(vault.clearAll())
    }

    @Test func aTripEndsByItselfAtHomeAndTakesItsTicket() throws {
        let vault = WorldMapVault.ephemeral()
        let home = Self.cedarPoint.offset(east: 20_000, north: 0)
        let keeper = Self.keeper(vault: vault, home: home)
        _ = keeper.admits(Self.fix(Self.cedarPoint, minutes: 0))
        #expect(keeper.startTrip(to: .airport("FHA"), at: Self.day.addingTimeInterval(60)))
        _ = keeper.admits(Self.fix(home, minutes: 90))
        #expect(!keeper.isOnTrip && keeper.tripDestination == nil)
        #expect(try vault.read(WorldFlightKeeper.tripFile) == nil)
        #expect(vault.clearAll())
    }

    @Test func aDecoyStartsNoTripAndWritesNothing() throws {
        let vault = WorldMapVault.ephemeral()
        let keeper = Self.keeper(vault: vault)
        keeper.mayWrite = { false }
        _ = keeper.admits(Self.fix(Self.cedarPoint, minutes: 0))
        #expect(!keeper.startTrip(to: .airport("FHA")))
        #expect(!keeper.isOnTrip && keeper.tripDestination == nil)
        #expect(try vault.read(WorldFlightKeeper.tripFile) == nil)
        #expect(try vault.read(WorldFlightKeeper.stateFile) == nil)
        #expect(vault.clearAll())
    }
}

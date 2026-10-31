import CoreGraphics
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Home at an airport (World-Airports-Spec §2.3, §3, §5, §6.3), the pure parts, with made-up airports (Cedar Field
/// near a Portland-ish town, Fernhaven in the United Kingdom; never anyone's real flights): when the dotted fence
/// shows, which airports stand near the view and which way their runways run, the planes' two-minute beat, the
/// layover counter's words, the banners' words, and Sprout's new-airport and landing lines taking turns.
@MainActor
struct WorldAirportHomeTests {
    nonisolated static let day = Date(timeIntervalSince1970: 1_793_275_200)

    /// A made-up airport at `point` with `grounds`.
    static func airport(_ token: String, _ point: GeoPoint, country: String = "US", name: String = "Cedar Field",
                        city: String = "Cedarville", grounds: WorldAirportGrounds = .circle(radiusMetres: 1_500)) -> WorldAirport {
        WorldAirport(token: token, iata: token, ident: "K" + token, point: point, countryCode: country, size: .large,
                     timeZoneIdentifier: "America/Los_Angeles", englishName: name, spanishName: nil, englishCity: city,
                     spanishCity: nil, grounds: grounds)
    }

    static let cedarPoint = GeoPoint(45.6, -122.6)
    /// A 4 km × 2 km outline round Cedar Field (our own, approved).
    static let cedarRing = [
        cedarPoint.offset(east: -2_000, north: -1_000), cedarPoint.offset(east: 2_000, north: -1_000),
        cedarPoint.offset(east: 2_000, north: 1_000), cedarPoint.offset(east: -2_000, north: 1_000),
    ]
    static let cedar = airport("CED", cedarPoint, grounds: .outline(cedarRing))

    // MARK: The fence

    @Test func theFenceShowsOnlyWhenTheOutlineSpansAThirdOfTheScreen() {
        let screen = CGSize(width: 402, height: 874)
        #expect(WorldAirportSelection.fenceShows(bounds: CGRect(x: 0, y: 0, width: 200, height: 100), screen: screen))
        #expect(WorldAirportSelection.fenceShows(bounds: CGRect(x: -900, y: -900, width: 3_000, height: 3_000), screen: screen),
                "zoomed right in, the outline runs off the screen")
        #expect(WorldAirportSelection.fenceShows(bounds: CGRect(x: 10, y: 10, width: 60, height: 300), screen: screen),
                "tall enough")
        #expect(!WorldAirportSelection.fenceShows(bounds: CGRect(x: 10, y: 10, width: 120, height: 120), screen: screen))
        #expect(!WorldAirportSelection.fenceShows(bounds: .null, screen: screen))
        #expect(!WorldAirportSelection.fenceShows(bounds: CGRect(x: 0, y: 0, width: 200, height: 100), screen: .zero))
    }

    @Test func onlyOurOwnOutlineIsAFence() {
        #expect(WorldAirportSelection.fenceOutline(of: Self.cedar) == Self.cedarRing)
        #expect(WorldAirportSelection.fenceOutline(of: Self.airport("RWY", Self.cedarPoint, grounds: .runways(Self.cedarRing))) == nil)
        #expect(WorldAirportSelection.fenceOutline(of: Self.airport("CIR", Self.cedarPoint)) == nil)
        let points = [CGPoint(x: 10, y: 40), CGPoint(x: 50, y: 5), CGPoint(x: 30, y: 90)]
        #expect(WorldAirportSelection.bounds(of: points) == CGRect(x: 10, y: 5, width: 40, height: 85))
        #expect(WorldAirportSelection.bounds(of: []).isNull)
    }

    // MARK: Near the view and the runway

    @Test func theNearestAirportsWithinReachComeFirst() {
        let near = Self.airport("NER", Self.cedarPoint.offset(east: 3_000, north: 0))
        let far = Self.airport("FAR", Self.cedarPoint.offset(east: 0, north: 60_000))
        let found = WorldAirportSelection.near([far, near, Self.cedar], centre: Self.cedarPoint, withinMetres: 10_000)
        #expect(found.map(\.token) == ["CED", "NER"])
        #expect(WorldAirportSelection.near([Self.cedar], centre: Self.cedarPoint, withinMetres: 0).isEmpty)
    }

    @Test func theRunwayRunsBetweenTheRingsFarthestPoints() {
        let (a, b) = WorldAirportSelection.runwayAxis(of: Self.cedar)
        #expect(abs(a.distance(to: b) - Self.cedarRing[0].distance(to: Self.cedarRing[2])) < 1, "the outline's diagonal")
        let (c, d) = WorldAirportSelection.runwayAxis(of: Self.airport("CIR", Self.cedarPoint))
        #expect(abs(c.distance(to: d) - WorldAirportSelection.circleRunwayMetres) < 1)
        #expect(abs(c.latitude - d.latitude) < 1e-9, "east–west")
    }

    // MARK: The planes

    @Test func aPlaneTakesOffEveryTwoMinutesOnTheAirportsOwnBeat() throws {
        let offset = WorldAirportPlaneSchedule.offset(for: "CED")
        #expect(offset >= 0 && offset < WorldAirportPlaneSchedule.period)
        #expect(offset == WorldAirportPlaneSchedule.offset(for: "CED"), "the same every time")
        let next = WorldAirportPlaneSchedule.nextTakeOff(after: Self.day, token: "CED")
        #expect(next >= Self.day && next.timeIntervalSince(Self.day) <= WorldAirportPlaneSchedule.period)
        #expect(WorldAirportPlaneSchedule.nextTakeOff(after: next, token: "CED") == next, "a take-off now is the next one")
        let after = WorldAirportPlaneSchedule.nextTakeOff(after: next.addingTimeInterval(1), token: "CED")
        #expect(after.timeIntervalSince(next) == WorldAirportPlaneSchedule.period)
        let start = try #require(WorldAirportPlaneSchedule.progress(at: next, token: "CED"))
        #expect(abs(start) < 1e-9)
        let half = try #require(WorldAirportPlaneSchedule.progress(at: next.addingTimeInterval(4.5), token: "CED"))
        #expect(abs(half - 0.5) < 1e-9)
        #expect(WorldAirportPlaneSchedule.progress(at: next.addingTimeInterval(10), token: "CED") == nil, "between take-offs")
    }

    @Test func theRollSpeedsUpThenLiftsAndFades() {
        #expect(WorldAirportPlaneSchedule.runwayShare(0) == WorldAirportPlaneSchedule.rollSpan.lowerBound)
        #expect(WorldAirportPlaneSchedule.runwayShare(1) == WorldAirportPlaneSchedule.rollSpan.upperBound)
        #expect(WorldAirportPlaneSchedule.runwayShare(0.5) < 0.525, "slower in the first half")
        #expect(WorldAirportPlaneSchedule.liftScale(0.3) == 1 && WorldAirportPlaneSchedule.liftScale(1) == 1.5)
        #expect(WorldAirportPlaneSchedule.liftOpacity(0.5) == 1 && WorldAirportPlaneSchedule.liftOpacity(1) == 0)
    }

    // MARK: The layover counter

    @Test func theLayoverCountsUpByTheMinute() {
        #expect(WorldAirportCopy.duration(minutes: 14) == "14 min")
        #expect(WorldAirportCopy.duration(minutes: 134) == "2 h 14 min")
        #expect(WorldAirportCopy.duration(minutes: 120) == "2 h")
        #expect(WorldAirportCopy.duration(minutes: -5) == "0 min")
        #expect(WorldAirportCopy.layover(city: "Fernhaven", minutes: 134) == "Layover at Fernhaven · 2 h 14 min")
    }

    @Test func theKeeperMirrorsAFreshDetectorAsNothing() {
        let state = WorldFlightGateState(FlightDetector(), at: Self.day)
        #expect(state == WorldFlightGateState())
        #expect(WorldFlightKeeper(grounds: { NoAirports() }, iataCode: { _ in nil }).layoverDuration(at: Self.day) == nil)
    }

    // MARK: Banners

    @Test func aStampIsALandingOnlyAtTheLandingsOwnReading() {
        let landing = WorldAirportFind(token: "FHV", how: .landing, at: Self.day)
        #expect(WorldAirportMoments.how(token: "FHV", at: Self.day, latest: landing) == .landing)
        #expect(WorldAirportMoments.how(token: "CED", at: Self.day, latest: landing) == nil)
        #expect(WorldAirportMoments.how(token: "FHV", at: Self.day.addingTimeInterval(600), latest: landing) == nil)
        #expect(WorldAirportMoments.how(token: "FHV", at: Self.day, latest: nil) == nil)
    }

    @Test func theBannersSayHowTheAirportWasFound() throws {
        let dwell = WorldAirportBannerModel.make(airport: Self.cedar, how: .dwell, at: Self.day, continent: nil, countryCode: nil,
                                                 companion: "Sprout")
        #expect(dwell.title == "New stamp: Cedar Field" && !dwell.isLanding)
        #expect(dwell.detail == "Ten minutes at the airport found it. It's in Sprout's passport.")
        let ticket = WorldAirportBannerModel.make(airport: Self.cedar, how: .ticket, at: Self.day, continent: nil, countryCode: nil,
                                                  companion: "Sprout")
        #expect(ticket.detail == "It's in Sprout's passport.")
        let fernhaven = Self.airport("FHV", GeoPoint(51.4, -0.4), country: "GB", name: "Fernhaven", city: "Fernhaven")
        let landed = WorldAirportBannerModel.make(airport: fernhaven, how: .landing, at: Self.day, continent: "Europe",
                                                  countryCode: "GB", companion: "Sprout")
        #expect(landed.title == "Landed at Fernhaven" && landed.isLanding)
        #expect(landed.detail.hasPrefix("New stamp: Fernhaven. Europe's and the "))
        #expect(landed.detail.hasSuffix("'s come when you leave the airport."))
        let nothingWaits = WorldAirportBannerModel.make(airport: fernhaven, how: .landing, at: Self.day, continent: nil,
                                                        countryCode: nil, companion: "Sprout")
        #expect(nothingWaits.detail == "New stamp: Fernhaven. It's in Sprout's passport.")
    }

    @Test func aLandingLeavesTheCountryWaitingOnlyWhenItIsNew() throws {
        let fernhaven = Self.airport("FHV", GeoPoint(51.4, -0.4), country: "GB")
        #expect(WorldAirportMoments.waitingCountry(of: fernhaven, book: PassportBook()) == "GB")
        let visited = try PassportBook(discoveries: [AtlasDiscovery(kind: .country, token: "GB", at: Self.day)])
        #expect(WorldAirportMoments.waitingCountry(of: fernhaven, book: visited) == nil)
        #expect(WorldAirportMoments.waitingContinent(of: fernhaven, book: PassportBook(), atlas: nil) == nil, "no atlas, no claim")
        #expect(WorldAirportCopy.bannerCountry(code: "GB", atStart: true, spanish: false).hasPrefix("The "))
        #expect(!WorldAirportCopy.bannerCountry(code: "GB", atStart: false, spanish: true).hasPrefix("the "))
    }

    // MARK: Sprout's lines

    @Test func theLandingLinesTakeTurns() throws {
        #expect([0, 1, 2, 3, 4].map { WorldAirportMoments.landingTurn(fernletFlights: $0) } == [0, 0, 1, 2, 0])
        let landing = WorldAirportFind(token: "FHV", how: .landing, at: Self.day)
        let line = try #require(WorldAirportMoments.landingLine(for: landing, fernletFlights: 2))
        #expect(line.category == .landing && line.index == 1 && line.at == Self.day)
        #expect(line.text == "Touchdown! Where are we?")
        #expect(WorldAirportMoments.landingLine(for: WorldAirportFind(token: "CED", how: .dwell, at: Self.day), fernletFlights: 2) == nil)
        #expect(WorldDiscoveryLinesCopy.line(.airport, index: 0, name: "") == "An airport! Are we going somewhere?")
        #expect(WorldDiscoveryLinesCopy.line(.landing, index: 0, name: "") == "We flew! My leaf's all fluffy.")
    }

    @Test func eachNewAirportTakesTheNextLineOnce() throws {
        let first = AtlasDiscovery(kind: .airport, token: "CED", at: Self.day)
        let second = AtlasDiscovery(kind: .airport, token: "FHV", at: Self.day.addingTimeInterval(86_400))
        let book = try PassportBook(discoveries: [first, second])
        let places = WorldDiscoveryLinesTests.places
        let one = try #require(WorldLinePicker.line(for: first, in: book, places: places, isDecoy: false))
        let two = try #require(WorldLinePicker.line(for: second, in: book, places: places, isDecoy: false))
        #expect(one.category == .airport && one.index == 0 && two.index == 1)
        #expect(two.text == "So many planes. Which one is ours?")
        #expect(WorldLinePicker.line(for: first, in: book, places: places, isDecoy: true) == nil, "a decoy says nothing")
    }

    @Test func theRouterHandsAirportStampsToHomeAndALandingBeatsTheNewAirportLine() throws {
        let router = WorldDiscoveryRouter()
        var airportStamps: [String] = []
        var otherStamps: [PassportStamp] = []
        router.onAirportStamp = { token, _ in airportStamps.append(token) }
        router.onNewStamp = { otherStamps.append($0) }
        let found = AtlasDiscovery(kind: .airport, token: "FHV", at: Self.day)
        let book = try PassportBook(discoveries: [found])
        router.route(.firstVisit(found), book: book, places: WorldDiscoveryLinesTests.places, isDecoy: false)
        #expect(airportStamps == ["FHV"] && router.line?.category == .airport)
        #expect(otherStamps.isEmpty, "the passport's own banner never shows an airport's stamp too")
        router.offer(WorldDiscoveryLine(category: .landing, index: 0, name: "", at: Self.day))
        #expect(router.line?.category == .landing)
        router.offer(WorldDiscoveryLine(category: .airport, index: 0, name: "", at: Self.day))
        #expect(router.line?.category == .landing, "the airport line of the same reading never replaces it")
        router.route(.newTrip(PassportStamp(kind: .airport, token: "FHV", date: Self.day, trip: 2)), book: book,
                     places: WorldDiscoveryLinesTests.places, isDecoy: false)
        #expect(airportStamps == ["FHV", "FHV"] && otherStamps.isEmpty)
        router.route(.firstVisit(found), book: book, places: WorldDiscoveryLinesTests.places, isDecoy: true)
        #expect(airportStamps.count == 2, "nothing in a decoy")
    }

    // MARK: The art

    @Test func theSpritesKeepTheMockupsSizes() {
        let tower = WorldAirportSprites.tower(found: false, dark: false)
        #expect(tower.width == 15 && tower.height == 19, "13 × 17 with its halo")
        #expect(Set(tower.palette.values).count == 3, "grey lines, grey fill and the halo before it's found")
        #expect(WorldAirportSprites.tower(found: true, dark: true).palette[WorldAirportSprites.haloKey] == 0xF3E6C8)
        #expect(WorldAirportSprites.rollingJet(tail: 0).width == 12 && WorldAirportSprites.rollingJet(tail: 0).height == 11)
        #expect(WorldAirportSprites.parkedJet(tail: 5).palette["h"] == WorldAirportSprites.tails[1], "tails wrap")
        #expect(WorldAirportSprites.suitcase.width == 7 && WorldAirportSprites.suitcase.height == 11)
        #expect(WorldAirportSprites.sleepMask.width == 14 && WorldAirportSprites.sleepMask.height == 4)
        #expect(WorldAirportSprites.haloed(["k"]) == ["OOO", "OkO", "OOO"])
    }
}

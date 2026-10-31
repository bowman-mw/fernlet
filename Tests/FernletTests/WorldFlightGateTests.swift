import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Made-up airports for the flight gate: well-known codes on simple 3 km circles and one square outline, not the
/// shipped pack's. None comes from the owner's own flights.
private nonisolated struct GateAirports: AirportGroundsLookup {
    let all: [WorldAirport]

    func airports(containing point: GeoPoint) -> [WorldAirport] {
        // Bounded: three airports.
        all.filter { $0.contains(point) }
    }
}

/// The flight gate (World-Airports-Spec §6.1; owner 2026-10-31: "Don't track anything that the user flies over"):
/// synthetic journeys through `WorldLocationSource` and a test store. A walk recorded to the gate stops at
/// take-off and nothing flown over reaches the fog, the walk, the passport or Home's last place; a drive on the
/// taxiway ends at take-off; a landing finds the airport and keeps the flight as two airports and times; the
/// country waits until the person leaves the grounds; a drive past an airport never counts as a visit; and a
/// train leaving an airport's station is no flight without a climb.
@MainActor
struct WorldFlightGateTests {
    private static let pdxPoint = GeoPoint(45.5887, -122.5975)
    private static let cdgPoint = GeoPoint(49.0097, 2.5479)
    private static let helPoint = GeoPoint(60.3172, 24.9633)
    /// Over Lyon, from a window seat.
    private static let overFrance = GeoPoint(45.7640, 4.8357)
    private static let start = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private static func airport(_ code: String, _ point: GeoPoint, _ grounds: WorldAirportGrounds,
                                _ country: String) -> WorldAirport {
        WorldAirport(token: code, iata: code, ident: "X" + code, point: point, countryCode: country, size: .large,
                     timeZoneIdentifier: "UTC", englishName: code, spanishName: nil, englishCity: code,
                     spanishCity: nil, grounds: grounds)
    }

    private static let airports = GateAirports(all: [
        airport("PDX", pdxPoint, .circle(radiusMetres: 3_000), "US"),
        airport("CDG", cdgPoint, .circle(radiusMetres: 3_000), "FR"),
        airport("HEL", helPoint, .outline([
            helPoint.offset(east: -2_500, north: -2_500), helPoint.offset(east: 2_500, north: -2_500),
            helPoint.offset(east: 2_500, north: 2_500), helPoint.offset(east: -2_500, north: 2_500),
        ]), "FI"),
    ])

    private static func reading(_ point: GeoPoint, _ second: Double, kmh: Double) -> WorldFix {
        WorldFix(point: point, accuracy: 10, at: start.addingTimeInterval(second), isPrecise: true, speed: kmh / 3.6)
    }

    /// A test store whose gate places readings among ``airports``, with the fog loaded.
    private static func store() -> FernletStore {
        let store = makeTestStore()
        store.wireWorldRides()
        store.worldLocation.flights.useAirports({ Self.airports }, iataCode: { $0 })
        store.worldFog.load()
        return store
    }

    /// Walks recorded to PDX's gate (five minutes), taxis at 36 km/h for a minute (car detection calls it a drive),
    /// takes off, crosses France and lands at CDG.
    private static func flyPortlandToParis(_ store: FernletStore) {
        let source = store.worldLocation
        store.worldWalk.start(at: start)
        for step in 0...30 {
            let second = Double(step) * 10
            source.deliver(reading(pdxPoint.offset(east: -2_000 + second * 1.4, north: 0), second, kmh: 5))
        }
        for step in 1...7 {
            let second = 300 + Double(step) * 10
            source.deliver(reading(pdxPoint.offset(east: Double(step) * 100, north: 0), second, kmh: 36))
        }
        source.deliver(reading(pdxPoint.offset(east: 5_000, north: 0), 400, kmh: 330))
        for step in 1...4 {
            source.deliver(reading(overFrance.offset(east: Double(step) * 2_000, north: 0), 8 * 3_600 + Double(step) * 60, kmh: 870))
        }
        source.deliver(reading(cdgPoint.offset(east: -2_000, north: 0), 9 * 3_600, kmh: 260))
        source.deliver(reading(cdgPoint, 9 * 3_600 + 60, kmh: 40))
    }

    /// A walk recorded to the gate stops at take-off: in the air nothing reaches the fog, the walk's line or
    /// Home's last place, the taxiway's "drive" ends, and Home can read that a flight is under way; the landing
    /// is kept again.
    @Test func aWalkToTheGateThenTakeOffKeepsNothingUntilTheLanding() throws {
        let store = Self.store()
        let source = store.worldLocation
        var kept: [WorldFix] = []
        let lift = source.onFix
        source.onFix = { fix in
            kept.append(fix)
            lift?(fix)
        }
        let sourceFlights = source.flights
        var sawFlying = false, droveInTheAir = false
        source.rides.onDrivingChanged = { driving in
            if driving, sourceFlights.isFlying { droveInTheAir = true }
        }
        let walk = store.worldWalk
        source.flights.onEvents = { events in
            if sourceFlights.isFlying { sawFlying = true }
            store.recordWorldFlightEvents(events)
        }
        Self.flyPortlandToParis(store)

        #expect(sawFlying && !droveInTheAir && !source.flights.isFlying)
        #expect(kept.count == 31 + 7 + 1, "the walk, the taxi and the landing; nothing from the air")
        #expect(kept.allSatisfy { $0.point.distance(to: Self.pdxPoint) < 3_000 || $0.point.distance(to: Self.cdgPoint) < 3_000 })
        #expect(walk.points.allSatisfy { $0.point.distance(to: Self.overFrance) > 100_000 }, "the walk's line has no flight in it")
        let fog = store.worldFog.visibleCells
        #expect(!fog.contains(MercatorHexGrid.cell(containing: Self.overFrance.offset(east: 4_000, north: 0))))
        #expect(!fog.contains(MercatorHexGrid.cell(containing: Self.pdxPoint.offset(east: 5_000, north: 0))), "the climb-out")
        #expect(fog.contains(MercatorHexGrid.cell(containing: Self.cdgPoint)), "the landing lifts as any reading")
        #expect(source.latest?.point == Self.cdgPoint)
        #expect(!source.rides.isDriving)
    }

    /// A window seat over France stamps nothing; the landing finds CDG and keeps PDX to CDG as two airports and
    /// times; France waits inside the grounds and is stamped once the person leaves them.
    @Test func aWindowSeatOverFranceStampsNothingAndTheCountryWaitsForTheExit() throws {
        let store = Self.store()
        Self.flyPortlandToParis(store)
        let atlas = store.worldFog.atlas
        #expect(atlas.book.trips(inCountry: "FR").isEmpty, "over France, and inside CDG's grounds")
        #expect(!atlas.book.trips(atAirport: "CDG").isEmpty && !atlas.book.trips(atAirport: "PDX").isEmpty)
        let flight = try #require(atlas.book.flights.first)
        #expect(atlas.book.flights.count == 1 && flight.route == "PDX>CDG" && flight.sources == .fernlet)
        #expect(flight.departure == Self.start.addingTimeInterval(370) && flight.arrival == Self.start.addingTimeInterval(9 * 3_600 + 60))

        store.worldLocation.deliver(Self.reading(Self.cdgPoint.offset(east: 400, north: 0), 9 * 3_600 + 600, kmh: 5))
        #expect(atlas.book.trips(inCountry: "FR").isEmpty, "still inside the grounds")
        store.worldLocation.deliver(Self.reading(Self.cdgPoint.offset(east: 4_000, north: 0), 9 * 3_600 + 1_800, kmh: 5))
        #expect(!atlas.book.trips(inCountry: "FR").isEmpty, "out of the airport: France")
    }

    /// A drive along a road through HEL's own outline and up its edge (seven and a half minutes at 90 km/h) never
    /// finds it: every reading is kept, and nothing is found.
    @Test func aDrivePastAnAirportNeverCountsAsAVisit() {
        let source = WorldLocationSource()
        source.flights.useAirports({ Self.airports }, iataCode: { $0 })
        var events: [FlightEvent] = []
        source.flights.onEvents = { events += $0 }
        var kept = 0
        source.onFix = { _ in kept += 1 }
        // In along a road 1.5 km south of the middle, then north just inside the eastern edge: 11.4 km at 90 km/h.
        for step in 0...91 {
            let along = Double(step) * 125
            let point = along <= 8_400 ? Self.helPoint.offset(east: -6_000 + along, north: -1_500)
                : Self.helPoint.offset(east: 2_400, north: -1_500 + along - 8_400)
            source.deliver(Self.reading(point, Double(step) * 5, kmh: 90))
        }
        #expect(kept == 92)
        #expect(events.isEmpty, "\(events)")
        #expect(!source.flights.isFlying && source.rides.isDriving)
    }

    // MARK: A train from an airport's station (open question a, carbike and ideas-data 2026-10-31)

    /// Five minutes in CDG's station, on the ground with GPS altitudes jumping round 110 m (the last one dipping
    /// to 60), then out of the grounds at 320 km/h `climb` metres above that ground, with the altitude's accuracy
    /// `vertical`: whether a flight started.
    private static func leaveCDGByRail(climb: Double, vertical: Double? = 10, groundKnown: Bool = true) -> Bool {
        var detector = FlightDetector()
        let ground = [110.0, 125, 95, 105, 118, 60]
        for (index, altitude) in ground.enumerated() {
            let fix = FlightFix(point: cdgPoint.offset(east: Double(index) * 20, north: 0),
                                at: start.addingTimeInterval(Double(index) * 60), accuracy: 10, speed: 1,
                                altitude: groundKnown ? altitude : nil, verticalAccuracy: groundKnown ? 8 : nil)
            _ = detector.observe(fix, airports: airports)
        }
        let away = FlightFix(point: cdgPoint.offset(east: 6_000, north: 0), at: start.addingTimeInterval(400),
                             accuracy: 10, speed: 320 / 3.6, altitude: 110 + climb, verticalAccuracy: vertical)
        _ = detector.observe(away, airports: airports)
        return detector.isFlying
    }

    /// A TGV at 320 km/h leaving an airport's station is no flight unless it is 300 m above the station's ground:
    /// +250 m is none and +350 m is one. The ground is the median of the last readings there, so one reading
    /// dipping to 60 m never hands the train its climb (+250 m over the median is +300 m over that reading). With
    /// the altitude unknown (no accuracy, or worse than 50 m) or no ground known, the speed decides as before.
    @Test func aTrainFromAnAirportStationIsNoFlightWithoutAClimb() {
        #expect(!Self.leaveCDGByRail(climb: 250), "a TGV on an embankment")
        #expect(Self.leaveCDGByRail(climb: 350), "a plane climbing out")
        #expect(Self.leaveCDGByRail(climb: 0, vertical: nil), "altitude unknown: the speed decides")
        #expect(Self.leaveCDGByRail(climb: 0, vertical: 80), "altitude too vague: the speed decides")
        #expect(Self.leaveCDGByRail(climb: 0, groundKnown: false), "no ground known: the speed decides")
        #expect(FlightDetector.climbMetres == 300 && FlightDetector.altitudeAccuracy == 50)
    }

    /// A late reading (a visit's arrival, delivered after newer ones) inside a flight is refused; one from before
    /// the flight is kept.
    @Test func aLateReadingInsideAFlightIsRefused() {
        let store = Self.store()
        Self.flyPortlandToParis(store)
        let source = store.worldLocation
        var kept: [WorldFix] = []
        source.onFix = { kept.append($0) }
        source.deliver(Self.reading(Self.overFrance, 8 * 3_600, kmh: 0))
        source.deliver(Self.reading(Self.pdxPoint.offset(east: -2_500, north: 0), 100, kmh: 0))
        #expect(kept.map(\.at) == [Self.start.addingTimeInterval(100)])
    }
}

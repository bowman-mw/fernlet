import Foundation
import Testing
import WorldMapStore

/// A few made-up airports for the flight detector: well-known codes on simple grounds (circles and one
/// square outline), not the shipped pack's. None comes from the owner's own flights.
private nonisolated struct FakeAirports: AirportGroundsLookup {
    let all: [WorldAirport]

    func airports(containing point: GeoPoint) -> [WorldAirport] {
        // Bounded: four airports.
        all.filter { $0.contains(point) }
    }
}

/// The flight detector (World-Airports-Spec §3, §5, §6, §7): a flight starts past 300 km/h after leaving an
/// airport or past 450 km/h anywhere, never for a high-speed train; every reading in the air is refused; a
/// gap between two far airports is a flight; a landing finds the airport, a layover becomes a transit or an
/// arrival; ten minutes find only a large airport with our own outline; a ticket finds the airport it is
/// at; and the state survives a relaunch mid-flight. The sample traveller lives in Portland.
@MainActor
struct FlightDetectorTests {
    // MARK: Fixtures

    private static let pdxPoint = GeoPoint(45.5887, -122.5975)
    private static let lhrPoint = GeoPoint(51.4700, -0.4543)
    private static let helPoint = GeoPoint(60.3172, 24.9633)
    private static let mexPoint = GeoPoint(19.4363, -99.0721)

    private static func airport(_ code: String, _ point: GeoPoint, _ size: WorldAirportSize,
                                _ grounds: WorldAirportGrounds, _ country: String) -> WorldAirport {
        WorldAirport(token: code, iata: code, ident: "X" + code, point: point, countryCode: country, size: size,
                     timeZoneIdentifier: "UTC", englishName: code, spanishName: nil, englishCity: code,
                     spanishCity: nil, grounds: grounds)
    }

    /// Large, runway grounds only (no approved outline yet): a 3 km circle.
    private static let pdx = airport("PDX", pdxPoint, .large, .circle(radiusMetres: 3_000), "US")
    private static let lhr = airport("LHR", lhrPoint, .large, .circle(radiusMetres: 3_000), "GB")
    /// Large with our own approved outline: a 5 km square.
    private static let hel = airport("HEL", helPoint, .large, .outline([
        helPoint.offset(east: -2_500, north: -2_500), helPoint.offset(east: 2_500, north: -2_500),
        helPoint.offset(east: 2_500, north: 2_500), helPoint.offset(east: -2_500, north: 2_500),
    ]), "FI")
    /// Medium: found only by a ticket or a landing.
    private static let mex = airport("MEX", mexPoint, .medium, .circle(radiusMetres: 3_000), "MX")
    private static let airports = FakeAirports(all: [pdx, lhr, hel, mex])

    /// The traveller's home, in Portland, 15 km from the airport.
    private static let home = pdxPoint.offset(east: -12_000, north: -9_000)

    private static let start = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        Self.start.addingTimeInterval(seconds)
    }

    private func fix(_ point: GeoPoint, _ seconds: TimeInterval, kmh: Double? = nil,
                     accuracy: Double = 10) -> FlightFix {
        FlightFix(point: point, at: at(seconds), accuracy: accuracy, speed: kmh.map { $0 / 3.6 })
    }

    @discardableResult
    private func feed(_ detector: inout FlightDetector, _ point: GeoPoint, _ seconds: TimeInterval,
                      kmh: Double? = nil, accuracy: Double = 10) -> FlightVerdict {
        detector.observe(fix(point, seconds, kmh: kmh, accuracy: accuracy), airports: Self.airports) { spot in
            spot.distance(to: Self.home) < 500
        }
    }

    /// Standing at PDX (0–60 s), then out past the grounds at 330 km/h at 100 s: a flight from PDX that left
    /// at 60 s.
    private func takeOffFromPortland(_ detector: inout FlightDetector) -> FlightVerdict {
        feed(&detector, Self.pdxPoint, 0, kmh: 0)
        feed(&detector, Self.pdxPoint.offset(east: 500, north: 0), 30, kmh: 20)
        feed(&detector, Self.pdxPoint.offset(east: 1_000, north: 0), 60, kmh: 40)
        return feed(&detector, Self.pdxPoint.offset(east: 5_000, north: 0), 100, kmh: 330)
    }

    // MARK: Take-off and landing

    /// Leaving PDX's grounds and passing 300 km/h starts a flight from PDX (a climb-out at 250 km/h waits, and
    /// is refused); readings in the air are refused; an approach over LHR is no landing; the first reading
    /// there on the ground lands, finds LHR and keeps the flight as its two airports and times.
    @Test func takeOffAndLanding() {
        var detector = FlightDetector()
        let standing = feed(&detector, Self.pdxPoint, 0, kmh: 0)
        #expect(standing == FlightVerdict(mayKeep: true, events: [], airport: "PDX"))
        feed(&detector, Self.pdxPoint.offset(east: 500, north: 0), 30, kmh: 20)
        feed(&detector, Self.pdxPoint.offset(east: 1_000, north: 0), 60, kmh: 40)
        let climbing = feed(&detector, Self.pdxPoint.offset(east: 4_000, north: 0), 90, kmh: 250)
        #expect(climbing == .ignored, "a climb-out under 300 km/h starts nothing and is never kept")
        #expect(!detector.isFlying)

        let takeOff = feed(&detector, Self.pdxPoint.offset(east: 5_000, north: 0), 100, kmh: 330)
        #expect(takeOff.events == [
            .flightStarted(from: "PDX", departed: at(60)),
            .tripStarted(at: at(60), byTicket: false),
            .airportFound(token: "PDX", how: .takeOff, at: at(60)),
        ])
        #expect(!takeOff.mayKeep && takeOff.airport == nil)
        #expect(detector.isFlying && detector.flightOrigin == "PDX" && detector.flightDeparted == at(60))
        #expect(detector.isOnTrip && !detector.isTripByTicket && !detector.showsTravelLook)

        let cruising = feed(&detector, GeoPoint(62, -60), 3 * 3_600, kmh: 870)
        #expect(cruising == .ignored)
        let approach = feed(&detector, Self.lhrPoint.offset(east: -2_000, north: 0), 9 * 3_600, kmh: 260)
        #expect(approach == .ignored, "over the grounds at 260 km/h is still the air")

        let landing = feed(&detector, Self.lhrPoint, 9 * 3_600 + 60, kmh: 40)
        #expect(landing.events == [
            .airportFound(token: "LHR", how: .landing, at: at(9 * 3_600 + 60)),
            .landed(token: "LHR", from: "PDX", departed: at(60), at: at(9 * 3_600 + 60)),
        ])
        #expect(landing.mayKeep && landing.airport == "LHR")
        #expect(!detector.isFlying && detector.layoverAirport == "LHR")
        // Date arithmetic leaves a hair under or over two hours.
        #expect(abs((detector.layoverDuration(at: at(11 * 3_600 + 60)) ?? 0) - 2 * 3_600) < 0.001)
        #expect(detector.showsTravelLook)
    }

    /// Over 450 km/h is a flight anywhere, from no known airport; readings under 150 km/h spanning five
    /// minutes end it with no airport, and the reading that ends it is kept.
    @Test func over450IsAFlightAnywhereAndSlowReadingsEndIt() {
        var detector = FlightDetector()
        let nowhere = GeoPoint(44.0, -110.0)
        let fast = feed(&detector, nowhere, 0, kmh: 480)
        #expect(fast.events == [.flightStarted(from: nil, departed: at(0)), .tripStarted(at: at(0), byTicket: false)])
        #expect(!fast.mayKeep && detector.isFlying)

        let ground = GeoPoint(40.0, -105.0)
        #expect(feed(&detector, ground, 3_000, kmh: 30) == .ignored)
        #expect(feed(&detector, ground.offset(east: 100, north: 0), 3_200, kmh: 10) == .ignored)
        let ended = feed(&detector, ground.offset(east: 200, north: 0), 3_300, kmh: 5)
        #expect(ended.events == [.endedWithoutAirport(from: nil, departed: at(0), at: at(3_300))])
        #expect(ended.mayKeep && !detector.isFlying)
    }

    /// A fast reading between slow ones starts the five minutes again.
    @Test func aFastReadingRestartsTheSlowCount() {
        var detector = FlightDetector()
        _ = takeOffFromPortland(&detector)
        let ground = GeoPoint(40.0, -105.0)
        feed(&detector, ground, 4_000, kmh: 20)
        feed(&detector, ground, 4_200, kmh: 200)
        #expect(feed(&detector, ground, 4_400, kmh: 20) == .ignored)
        #expect(feed(&detector, ground, 4_600, kmh: 20) == .ignored)
        let ended = feed(&detector, ground, 4_700, kmh: 20)
        #expect(ended.events == [.endedWithoutAirport(from: "PDX", departed: at(60), at: at(4_700))])
    }

    // MARK: Trains

    /// A 320 km/h train whose line crosses PDX's grounds was never on the ground there, so leaving them is no
    /// take-off: no flight, no event (its readings are refused, as anything over 300 km/h is).
    @Test func aTrainThroughAirportGroundsIsNoFlight() {
        var detector = FlightDetector()
        // Bounded: 15 readings, 888 m apart, from 6 km west of PDX to 6 km east.
        for step in 0..<15 {
            let point = Self.pdxPoint.offset(east: -6_000 + Double(step) * 888, north: 0)
            let verdict = feed(&detector, point, Double(step) * 10, kmh: 320)
            #expect(verdict.events.isEmpty && !verdict.mayKeep)
        }
        #expect(!detector.isFlying && !detector.isOnTrip)
    }

    /// A 320 km/h train far from any airport is no flight either.
    @Test func aTrainAwayFromAirportsIsNoFlight() {
        var detector = FlightDetector()
        let line = GeoPoint(47.0, -121.0)
        // Bounded: 30 readings, 888 m apart.
        for step in 0..<30 {
            let verdict = feed(&detector, line.offset(east: Double(step) * 888, north: 0), Double(step) * 10, kmh: 320)
            #expect(verdict.events.isEmpty)
        }
        #expect(!detector.isFlying)
    }

    // MARK: The gap rule

    /// A last reading at PDX and the next at HEL eleven hours later (flight mode) is a flight PDX → HEL; a
    /// gap that implies under 150 km/h is not.
    @Test func aGapBetweenTwoFarAirportsIsAFlight() {
        var detector = FlightDetector()
        feed(&detector, Self.pdxPoint, 0, kmh: 0)
        let landed = feed(&detector, Self.helPoint, 11 * 3_600, kmh: 0)
        #expect(landed.events == [
            .flightStarted(from: "PDX", departed: at(0)),
            .tripStarted(at: at(0), byTicket: false),
            .airportFound(token: "PDX", how: .takeOff, at: at(0)),
            .airportFound(token: "HEL", how: .landing, at: at(11 * 3_600)),
            .landed(token: "HEL", from: "PDX", departed: at(0), at: at(11 * 3_600)),
        ])
        #expect(landed.mayKeep && landed.airport == "HEL" && detector.layoverAirport == "HEL")

        var slow = FlightDetector()
        feed(&slow, Self.pdxPoint, 0, kmh: 0)
        let overland = feed(&slow, Self.mexPoint, 60 * 3_600, kmh: 0)
        #expect(overland.events.isEmpty && overland.mayKeep && overland.airport == "MEX",
                "3,600 km in 60 hours is no flight")
        #expect(!slow.isFlying && !slow.isOnTrip)
    }

    /// A gap from PDX to a far place that is no airport, at a plane's pace, is a flight still on: the reading
    /// is refused until five slow minutes end it.
    @Test func aGapToNoAirportIsAFlightStillOn() {
        var detector = FlightDetector()
        feed(&detector, Self.pdxPoint, 0, kmh: 0)
        let away = GeoPoint(21.3, -157.8)
        let first = feed(&detector, away, 6 * 3_600, kmh: 0)
        #expect(first.events.prefix(1) == [.flightStarted(from: "PDX", departed: at(0))])
        #expect(!first.mayKeep && detector.isFlying)
        let ended = feed(&detector, away, 6 * 3_600 + 300, kmh: 0)
        #expect(ended.events == [.endedWithoutAirport(from: "PDX", departed: at(0), at: at(6 * 3_600 + 300))])
    }

    // MARK: Layovers

    /// Landed at HEL and still inside: a layover with a counter; a 250 km/h climb-out waits and is refused;
    /// past 300 km/h it was a transit, and the next landing names HEL as where the flight left.
    @Test func aLayoverBecomesATransit() {
        var detector = FlightDetector()
        feed(&detector, Self.pdxPoint, 0, kmh: 0)
        let landedAt = 11.0 * 3_600
        feed(&detector, Self.helPoint, landedAt, kmh: 0)
        // Bounded: 12 readings, ten minutes apart.
        for step in 1...12 {
            let verdict = feed(&detector, Self.helPoint.offset(east: 300, north: 0), landedAt + Double(step) * 600, kmh: 1)
            #expect(verdict.events.isEmpty && verdict.mayKeep, "no dwell find during a layover")
        }
        #expect(detector.layoverAirport == "HEL" && detector.layoverDuration(at: at(landedAt + 7_200)) == 7_200)

        let lastInside = landedAt + 7_200
        let climbing = feed(&detector, Self.helPoint.offset(east: 4_000, north: 0), lastInside + 40, kmh: 250)
        #expect(climbing == .ignored && detector.layoverAirport == "HEL", "a climb-out is no arrival")
        let takeOff = feed(&detector, Self.helPoint.offset(east: 6_000, north: 0), lastInside + 60, kmh: 340)
        #expect(takeOff.events == [
            .layoverBecameTransit(token: "HEL", at: at(lastInside)),
            .flightStarted(from: "HEL", departed: at(lastInside)),
        ])
        let landing = feed(&detector, Self.lhrPoint, lastInside + 3 * 3_600, kmh: 30)
        #expect(landing.events.last == .landed(token: "LHR", from: "HEL", departed: at(lastInside),
                                               at: at(lastInside + 3 * 3_600)))
    }

    /// Landed at LHR, then out of the grounds at a car's pace: an arrival (the country's stamps may come).
    @Test func aLayoverBecomesAnArrival() {
        var detector = FlightDetector()
        _ = takeOffFromPortland(&detector)
        let landedAt = 9.0 * 3_600
        feed(&detector, Self.lhrPoint, landedAt, kmh: 30)
        feed(&detector, Self.lhrPoint.offset(east: 0, north: 1_000), landedAt + 1_800, kmh: 4)
        let leaving = feed(&detector, Self.lhrPoint.offset(east: 0, north: 4_000), landedAt + 2_400, kmh: 50)
        #expect(leaving.events == [.arrived(token: "LHR", at: at(landedAt + 2_400))])
        #expect(leaving.mayKeep && leaving.airport == nil)
        #expect(detector.layoverAirport == nil && detector.layoverDuration(at: at(landedAt + 3_000)) == nil)
        #expect(detector.isOnTrip && !detector.showsTravelLook, "the travel look shows only inside grounds")
    }

    // MARK: Ten minutes at a large airport

    /// Ten walking minutes inside HEL's own outline find it, once; the same at PDX (large, no outline yet) or
    /// MEX (medium) finds nothing.
    @Test func tenMinutesFindOnlyALargeAirportWithOurOutline() {
        var hel = FlightDetector()
        var found: [FlightEvent] = []
        // Bounded: 16 readings, a minute apart.
        for minute in 0...15 {
            let verdict = feed(&hel, Self.helPoint.offset(east: Double(minute) * 40, north: 0), Double(minute) * 60,
                               kmh: 4)
            if minute < 10 { #expect(verdict.events.isEmpty) }
            found += verdict.events
        }
        #expect(found == [.airportFound(token: "HEL", how: .dwell, at: at(600))])

        // Bounded: two airports, 16 readings each.
        for (airport, point) in [("PDX", Self.pdxPoint), ("MEX", Self.mexPoint)] {
            var detector = FlightDetector()
            for minute in 0...15 {
                let verdict = feed(&detector, point, Double(minute) * 60, kmh: 0)
                #expect(verdict.events.isEmpty, "\(airport) is never found by time")
                #expect(verdict.airport == airport)
            }
        }
    }

    /// Driving through the outline for twelve minutes counts nothing, and a six-minute gap starts the ten
    /// minutes again.
    @Test func drivingPastOrAGapDoesNotCount() {
        var driving = FlightDetector()
        // Bounded: 13 readings, a minute apart.
        for minute in 0...12 {
            let verdict = feed(&driving, Self.helPoint.offset(east: -2_000 + Double(minute) * 300, north: 0),
                               Double(minute) * 60, kmh: 40)
            #expect(verdict.events.isEmpty)
        }

        var gap = FlightDetector()
        var found: [FlightEvent] = []
        // Bounded: five readings, then 11 more after a six-minute gap.
        for minute in 0...4 { found += feed(&gap, Self.helPoint, Double(minute) * 60, kmh: 1).events }
        for minute in 10...20 { found += feed(&gap, Self.helPoint, Double(minute) * 60, kmh: 1).events }
        #expect(found == [.airportFound(token: "HEL", how: .dwell, at: at(20 * 60))])
    }

    // MARK: The ticket

    /// A ticket at MEX (medium) finds it at once and brings on the travel look; at home, a ticket finds
    /// nothing until the first reading at an airport, and getting home ends the trip only once it has been
    /// to one.
    @Test func aTicketFindsTheAirportAndGettingHomeEndsTheTrip() {
        var atMexico = FlightDetector()
        feed(&atMexico, Self.mexPoint, 0, kmh: 0)
        #expect(atMexico.startTrip(at: at(60)) == [
            .tripStarted(at: at(60), byTicket: true),
            .airportFound(token: "MEX", how: .ticket, at: at(60)),
        ])
        #expect(atMexico.isOnTrip && atMexico.isTripByTicket && atMexico.showsTravelLook)
        #expect(feed(&atMexico, Self.mexPoint, 120, kmh: 0).events.isEmpty, "found once per trip")
        #expect(atMexico.startTrip(at: at(180)).isEmpty, "a trip is already on")

        var fromHome = FlightDetector()
        feed(&fromHome, Self.home, 0, kmh: 0)
        #expect(fromHome.startTrip(at: at(30)) == [.tripStarted(at: at(30), byTicket: true)])
        #expect(feed(&fromHome, Self.home, 60, kmh: 0).events.isEmpty, "home before the airport ends nothing")
        let atPortland = feed(&fromHome, Self.pdxPoint, 1_800, kmh: 0)
        #expect(atPortland.events == [.airportFound(token: "PDX", how: .ticket, at: at(1_800))])
        #expect(fromHome.showsTravelLook)
        feed(&fromHome, Self.pdxPoint.offset(east: 0, north: 8_000), 2_400, kmh: 30)
        #expect(fromHome.isOnTrip && !fromHome.showsTravelLook)
        let back = feed(&fromHome, Self.home, 4_000, kmh: 0)
        #expect(back.events == [.tripEnded(at: at(4_000))])
        #expect(!fromHome.isOnTrip)

        #expect(atMexico.endTrip(at: at(600)) == [.tripEnded(at: at(600))])
        #expect(atMexico.endTrip(at: at(660)).isEmpty)
    }

    // MARK: Nothing from the air

    /// Every reading in the air is refused and changes nothing, over a medium airport's grounds too, and
    /// however vague.
    @Test func readingsInTheAirAreRefused() {
        var detector = FlightDetector()
        _ = takeOffFromPortland(&detector)
        // Bounded: 20 readings, three seconds apart.
        for step in 0..<20 {
            let point = Self.mexPoint.offset(east: -8_000 + Double(step) * 800, north: 0)
            let verdict = feed(&detector, point, 3_600 + Double(step) * 3, kmh: 850,
                               accuracy: step.isMultiple(of: 5) ? 1_500 : 10)
            #expect(verdict == .ignored)
        }
        #expect(detector.isFlying && detector.currentAirport == nil)
    }

    /// Out-of-order, duplicate and invalid readings are passed by.
    @Test func badReadingsArePassedBy() {
        var detector = FlightDetector()
        #expect(feed(&detector, Self.pdxPoint, 100, kmh: 0).mayKeep)
        #expect(feed(&detector, Self.pdxPoint, 100, kmh: 0) == .ignored)
        #expect(feed(&detector, Self.pdxPoint, 50, kmh: 0) == .ignored)
        #expect(feed(&detector, GeoPoint(120, 0), 200, kmh: 0) == .ignored)
        #expect(feed(&detector, Self.pdxPoint, 300, kmh: 0, accuracy: -1) == .ignored)
        #expect(feed(&detector, Self.pdxPoint, 400, kmh: 0).mayKeep)
    }

    // MARK: Relaunch

    /// Saved mid-flight and read back, the detector is the same: it still refuses readings in the air and
    /// lands at LHR with PDX as where the flight left.
    @Test func codableRoundTripMidFlight() throws {
        var detector = FlightDetector()
        _ = takeOffFromPortland(&detector)
        feed(&detector, GeoPoint(62, -60), 3 * 3_600, kmh: 870)
        let data = try JSONEncoder().encode(detector)
        var restored = try JSONDecoder().decode(FlightDetector.self, from: data)
        #expect(restored == detector)
        #expect(restored.isFlying && restored.flightOrigin == "PDX")
        #expect(feed(&restored, GeoPoint(58, -20), 6 * 3_600, kmh: 880) == .ignored)
        let landing = feed(&restored, Self.lhrPoint, 9 * 3_600, kmh: 30)
        #expect(landing.events.last == .landed(token: "LHR", from: "PDX", departed: at(60), at: at(9 * 3_600)))
    }
}

import Foundation
import Testing
import WorldMapStore

/// A few made-up airports for the pace cap's tests (not the shipped pack's).
private nonisolated struct PaceTestAirports: AirportGroundsLookup {
    let all: [WorldAirport]

    func airports(containing point: GeoPoint) -> [WorldAirport] {
        // Bounded: two airports.
        all.filter { $0.contains(point) }
    }
}

/// The flight detector's believable pace (World-Airports-Spec §3, §6.1): a jump between two readings faster than
/// any airliner (a location glitch, or a simulator moved from Portland to Helsinki) starts no flight and finds no
/// airport, so it can't stamp the airport just left; a real take-off still does. The traveller is made up.
@MainActor
struct FlightDetectorPaceTests {
    private static let pdxPoint = GeoPoint(45.5887, -122.5975)
    private static let helPoint = GeoPoint(60.3172, 24.9633)

    private static func airport(_ code: String, _ point: GeoPoint, _ country: String) -> WorldAirport {
        WorldAirport(token: code, iata: code, ident: "X" + code, point: point, countryCode: country, size: .large,
                     timeZoneIdentifier: "UTC", englishName: code, spanishName: nil, englishCity: code,
                     spanishCity: nil, grounds: .circle(radiusMetres: 3_000))
    }

    private static let airports = PaceTestAirports(all: [airport("PDX", pdxPoint, "US"), airport("HEL", helPoint, "FI")])
    private static let start = Date(timeIntervalSinceReferenceDate: 815_000_000)

    /// Feeds a reading with no CoreLocation speed (the simulator's), so any speed comes from the pace.
    @discardableResult
    private func feed(_ detector: inout FlightDetector, _ point: GeoPoint, _ seconds: TimeInterval) -> FlightVerdict {
        let fix = FlightFix(point: point, at: Self.start.addingTimeInterval(seconds), accuracy: 5)
        return detector.observe(fix, airports: Self.airports) { _ in false }
    }

    /// Forty seconds at PDX, then a reading at Helsinki thirty seconds later: no flight, no airport found.
    @Test func aJumpAcrossTheWorldIsNoFlight() {
        var detector = FlightDetector()
        let pdx = (0 ..< 5).flatMap { feed(&detector, Self.pdxPoint.offset(east: Double($0) * 5, north: 0), Double($0) * 10).events }
        let hel = feed(&detector, Self.helPoint, 70)
        #expect(pdx.isEmpty)
        #expect(!hel.events.contains { if case .airportFound = $0 { return true }; return false })
        #expect(!hel.events.contains { if case .flightStarted = $0 { return true }; return false })
        #expect(!detector.isFlying)
    }

    /// A pace under the cap still counts: leaving PDX at about 475 km/h (no CoreLocation speed) is a take-off that
    /// finds PDX, as before.
    @Test func aBelievablePaceStillTakesOff() {
        var detector = FlightDetector()
        feed(&detector, Self.pdxPoint, 0)
        feed(&detector, Self.pdxPoint.offset(east: 200, north: 0), 20)
        let out = feed(&detector, Self.pdxPoint.offset(east: 5_500, north: 0), 60)
        #expect(out.events.contains(.airportFound(token: "PDX", how: .takeOff, at: Self.start.addingTimeInterval(20))))
        #expect(detector.isFlying)
    }
}

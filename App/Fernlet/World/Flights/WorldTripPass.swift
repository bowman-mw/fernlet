import Foundation
import WorldMapStore

/// What Sprout's boarding pass shows (World-Airports-Spec §5, screen 6): From, To, the date, and whether a landing
/// filled it in. Never a gate or a flight number. Facts only; the card draws them (``WorldBoardingPassCard``).
nonisolated struct WorldBoardingPass: Equatable, Sendable {
    /// One end of the pass: the big code ("PDX", or a city's name for every airport of a city) and the line under
    /// it (the city, or a city's codes).
    struct Stop: Equatable, Sendable {
        let code: String
        let place: String
    }

    /// The To side.
    enum To: Equatable, Sendable {
        /// Blank before a landing, with no destination ("Wherever you land").
        case wherever
        case stop(Stop)
    }

    /// The departure; nil only on a ticket away from an airport ("Fills in at the airport you leave from").
    let from: Stop?
    let to: To
    let date: Date
    /// Whether a landing filled it in (the stub's "Fills in when you land" line goes).
    let landed: Bool
}

/// How the pass is filled in (§5, §7), pure:
///
/// - **On a trip, after a flight** through the tapped airport: the trip's latest flight landing there or leaving
///   from there, as flown. If the person landed somewhere other than To, the pass shows where they really landed.
/// - **Otherwise** From is the tapped airport, To the ticket's destination while a trip is on, else blank, and the
///   date today.
///
/// The trip's flights are Fernlet's own (found by speed), from the ticket's start (or the last ``lookBack`` for a
/// trip found by its speed alone), at most the newest ``maxFlightsRead``.
nonisolated enum WorldBoardingPassRule {
    /// How far back a trip found by its speed alone reads its flights.
    static let lookBack: TimeInterval = 48 * 60 * 60
    /// A flight may have left a little before the ticket's Start trip was tapped (a slow tap on board).
    static let startSlack: TimeInterval = 60 * 60
    /// The most flights read (a bound).
    static let maxFlightsRead = 64

    /// The pass for the tower of `airport`.
    static func pass(at airport: WorldAirport, isOnTrip: Bool, destination: WorldTripDestination?, tripStartedAt: Date?,
                     flights: [PassportFlight], airports: WorldAirports?, spanish: Bool, now: Date) -> WorldBoardingPass {
        let here = WorldBoardingPass.Stop(code: airport.code, place: airport.city(spanish: spanish))
        guard isOnTrip else { return WorldBoardingPass(from: here, to: .wherever, date: now, landed: false) }
        let since = (tripStartedAt ?? now.addingTimeInterval(-lookBack)).addingTimeInterval(-startSlack)
        let code = airport.code.uppercased()
        let flown = flights.suffix(maxFlightsRead).filter {
            $0.sources.contains(.fernlet) && $0.departure >= since && ($0.from == code || $0.to == code)
        }
        if let flight = flown.max(by: { $0.departure < $1.departure }) {
            return WorldBoardingPass(from: stop(code: flight.from, airports: airports, spanish: spanish),
                                     to: .stop(stop(code: flight.to, airports: airports, spanish: spanish)),
                                     date: flight.departure, landed: true)
        }
        let to = destination.map { WorldBoardingPass.To.stop(stop($0, airports: airports, spanish: spanish)) } ?? .wherever
        return WorldBoardingPass(from: here, to: to, date: now, landed: false)
    }

    /// An airport by its code: the code and its city, or the code alone where the list has no city for it.
    static func stop(code: String, airports: WorldAirports?, spanish: Bool) -> WorldBoardingPass.Stop {
        let place = airports?.airport(code: code)?.city(spanish: spanish) ?? ""
        return WorldBoardingPass.Stop(code: code, place: place)
    }

    /// A destination: an airport as ``stop(code:airports:spanish:)``, a city by its name over its codes.
    static func stop(_ destination: WorldTripDestination, airports: WorldAirports?, spanish: Bool) -> WorldBoardingPass.Stop {
        guard destination.kind == .city else { return stop(code: destination.code, airports: airports, spanish: spanish) }
        let city = airports?.airport(code: destination.code)?.city(spanish: spanish) ?? destination.code
        return WorldBoardingPass.Stop(code: city, place: WorldTripCopy.codes(destination))
    }

    /// The destination's city in the app's language ("London"), or its code where the list has none.
    static func city(of destination: WorldTripDestination, airports: WorldAirports?, spanish: Bool) -> String {
        airports?.airport(code: destination.code)?.city(spanish: spanish) ?? destination.code
    }
}

/// The barcode on the pass's stub (the mockup's `bars()`): decoration only, the same bars every time.
nonisolated enum WorldPassBarcode {
    /// The barcode's size in points.
    static let width: Double = 150
    static let height: Double = 26

    /// Each bar's left edge and width, left to right (the mockup's seed and steps, in 32-bit arithmetic).
    static func bars() -> [(x: Double, width: Double)] {
        var out: [(x: Double, width: Double)] = []
        var x: UInt32 = 0
        var seed: UInt32 = 7
        // Bounded: every step moves x on by at least 2, so at most `width / 2` bars.
        for _ in 0..<Int(width / 2) where Double(x) < width {
            seed = seed &* 1_103_515_245 &+ 12_345
            let bar = 1 + seed % 3
            out.append((Double(x), Double(bar)))
            x += bar + 1 + (seed >> 5) % 3
        }
        return out
    }
}

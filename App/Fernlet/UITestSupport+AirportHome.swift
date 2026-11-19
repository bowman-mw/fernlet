import Foundation
import WorldMapStore

//  Home at an airport: DEBUG screenshot hooks (World-Airports-Spec §3, §5, §6.3), beside `UITestSupport`'s own:
//  wrapped in `#if DEBUG`, with a release no-op, so nothing of it ships.

extension UITestSupport {
    #if DEBUG
    /// `FERNLET_UI_TEST_AIRPORT=<at|trip|layover|landed|flying>` stands a made-up flight gate in on the keeper, with no
    /// readings: `at` just found Portland International (PDX) by ten minutes inside it, with its banner and Sprout's
    /// first airport line (screen 1); `trip` is at PDX on a trip, in the travel look (screen 5); `layover` has landed
    /// at Helsinki (HEL) 2 h 14 min ago (screen 7); `landed` has just landed at Heathrow (LHR), with its banner and
    /// Sprout's landing line (screen 9); `flying` is in the air. Display only: the passport, the fog and the gate's
    /// sealed state are never written. Pair it with the simulator's location at the airport so the map stands there.
    /// Consumed by `WorldFlightKeeper` and `WorldAirportHomeDriver`.
    static var airportHomeScene: String? {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_AIRPORT"]
    }

    /// The scene's made-up gate state at `now`, or nil without a scene.
    static func airportHomeState(now: Date) -> WorldFlightGateState? {
        switch airportHomeScene {
        case "at": WorldFlightGateState(currentAirport: "PDX")
        case "trip": WorldFlightGateState(currentAirport: "PDX", isOnTrip: true, showsTravelLook: true)
        case "layover": WorldFlightGateState(layoverAirport: "HEL", layoverStart: now.addingTimeInterval(-(2 * 3_600 + 14 * 60)),
                                             currentAirport: "HEL", isOnTrip: true, showsTravelLook: true)
        case "landed": WorldFlightGateState(layoverAirport: "LHR", layoverStart: now, currentAirport: "LHR",
                                            isOnTrip: true, showsTravelLook: true)
        case "flying": WorldFlightGateState(isFlying: true, isOnTrip: true)
        case "cycle": WorldFlightGateState(isFlying: isCycleInTheAir(now: now), isOnTrip: true)
        default: nil
        }
    }

    /// `FERNLET_UI_TEST_AIRPORT=cycle`: on the ground and in the air in turn, ``airportCycleSeconds`` each, while the
    /// app stays open, so the boarding hop plays over Home switching live (owner 2026-11-18). Display only.
    static var airportCycleSeconds: TimeInterval? {
        guard airportHomeScene == "cycle" else { return nil }
        let asked = ProcessInfo.processInfo.environment["FERNLET_UI_TEST_AIRPORT_CYCLE"].flatMap(Double.init) ?? 20
        return max(asked, 8)
    }

    /// Whether the cycle is in its air half at `now`.
    static func isCycleInTheAir(now: Date) -> Bool {
        guard let seconds = airportCycleSeconds else { return false }
        return Int(now.timeIntervalSince1970 / seconds) % 2 == 1
    }

    /// The scene's made-up latest find: PDX by ten minutes (`at`), LHR by a landing (`landed`); nil otherwise.
    static func airportHomeFind(now: Date) -> WorldAirportFind? {
        switch airportHomeScene {
        case "at": WorldAirportFind(token: "PDX", how: .dwell, at: now)
        case "landed": WorldAirportFind(token: "LHR", how: .landing, at: now)
        default: nil
        }
    }
    #else
    static var airportHomeScene: String? { nil }
    static func airportHomeState(now: Date) -> WorldFlightGateState? { nil }
    static var airportCycleSeconds: TimeInterval? { nil }
    static func airportHomeFind(now: Date) -> WorldAirportFind? { nil }
    #endif
}

import Foundation
import WorldMapStore

//  Take a trip: DEBUG screenshot hooks (World-Airports-Spec §5, §7, §10.7), beside `UITestSupport`'s own: wrapped in
//  `#if DEBUG`, with a release no-op, so nothing of it ships.

extension UITestSupport {
    #if DEBUG
    /// `FERNLET_UI_TEST_TRIP=<card|endcard|ticket|pass|today>`, paired with `FERNLET_UI_TEST_AIRPORT=at` (or `trip`)
    /// and the simulator's location at Portland International: `card` opens the blue button's card at PDX, Take a
    /// trip first (screen 16); `endcard` (with `AIRPORT=trip`) opens it on a trip to London, "End trip · London";
    /// `ticket` opens Fernlet's ticket with "Lon" typed and its suggestions (screen 17); `pass` opens Sprout's
    /// boarding pass for PDX (screen 6); `today` stands in a calendar flight to Honolulu leaving in three hours, so
    /// the blue button's "Trip to Honolulu" stays out and Sprout says its line (screen 29). Display only: no trip
    /// starts, and nothing is written. Consumed by `WorldTripHomeDriver`, `WorldFlightKeeper` and the store.
    static var tripScene: String? {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_TRIP"]
    }

    /// The scene's made-up destination: London's airports for `endcard`; nil otherwise.
    static var tripSceneDestination: WorldTripDestination? {
        tripScene == "endcard" ? WorldTripDestination.city(codes: ["LHR", "LGW", "STN", "LCY", "LTN"]) : nil
    }

    /// The scene's made-up calendar flight for `today`: to Honolulu (HNL), leaving three hours after `now`.
    static func tripSceneToday(now: Date) -> (destination: String, departure: Date)? {
        tripScene == "today" ? ("HNL", now.addingTimeInterval(3 * 3_600)) : nil
    }
    #else
    static var tripScene: String? { nil }
    static var tripSceneDestination: WorldTripDestination? { nil }
    static func tripSceneToday(now: Date) -> (destination: String, departure: Date)? { nil }
    #endif
}

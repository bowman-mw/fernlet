import Foundation
import SwiftUI
import WorldMapStore

//  Page 1 of Sprout's passport's DEBUG screenshot hooks (round 7, World-Passport-Spec §4), beside
//  `UITestSupport`'s own: wrapped in `#if DEBUG`, with a release no-op, so nothing of it ships.

extension UITestSupport {
    #if DEBUG
    /// `FERNLET_UI_TEST_PASSPORT_SPROUT=sprout|decoy` — the app opens on ``PassportSproutHarness``: page 1 in a
    /// plain book-sized frame over the parchment (the book itself is another piece's). `decoy` draws the decoy's
    /// fresh passport without a duress unlock.
    static var passportSproutScene: String? {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PASSPORT_SPROUT"]
    }

    /// Whether the harness asks page 1 for a decoy's fresh passport.
    static var passportSproutShowsDecoy: Bool { passportSproutScene == "decoy" }

    /// `FERNLET_UI_TEST_PASSPORT_PLACE=away|home:<name>|hotel:<name>` — where page 1's bottom row thinks the
    /// person stands (`ps-sprout-home`), instead of the map's reading and the homes.
    static var passportSproutPlace: WorldCloseUpPlace? {
        guard let raw = ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PASSPORT_PLACE"] else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "away": return .away(GeoPoint(45.5205, -122.6255))
        case "home": return .home(name: parts.count > 1 ? parts[1] : "Home")
        case "hotel": return .hotel(name: parts.count > 1 ? parts[1] : "Ace")
        default: return nil
        }
    }
    #else
    static var passportSproutScene: String? { nil }
    static var passportSproutShowsDecoy: Bool { false }
    static var passportSproutPlace: WorldCloseUpPlace? { nil }
    #endif
}

/// Hosts ``PassportSproutHarness`` over the app when the DEBUG hook asks for it; nothing otherwise, and nothing at
/// all in Release.
struct PassportSproutHarnessHost: View {
    var store: FernletStore

    var body: some View {
        #if DEBUG
        if UITestSupport.passportSproutScene != nil {
            PassportSproutHarness(store: store)
        }
        #endif
    }
}

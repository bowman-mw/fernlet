import Foundation
import Testing
@testable import Fernlet

/// Home map's "Log my bike rides" row and the background row's driving subtitle (round 7, car and bike
/// detection; `b1-settings-map`): what a turn of the switch does for each Motion & Fitness answer, the two
/// keys going with the map's other settings, and the page drawing the approved copy.
@MainActor
struct HomeMapBikeRidesSettingsTests {
    /// The page's source, read for the copy and the wiring a view test cannot reach.
    private static func page() throws -> String {
        try RepoRoot.source("App/Fernlet/World/Settings/HomeMapSettingsView.swift")
    }

    /// Off always asks the store; on asks it unless Motion was declined or is restricted, when iOS won't
    /// ask again and Fernlet's page in the Settings app opens instead. On an iPhone without motion activity
    /// it stays off and says why (owner 2026-10-29). A decoy always asks the store.
    @Test func aTurnAsksTheStoreUnlessIOSWontAskAgain() {
        let all: [WorldMotionPermission] = [.notAsked, .denied, .allowed, .unavailable]
        for permission in all {
            #expect(HomeMapBikeRideStep.step(turningOn: false, permission: permission, isDecoy: false) == .ask)
            #expect(HomeMapBikeRideStep.step(turningOn: true, permission: permission, isDecoy: true) == .ask)
        }
        #expect(HomeMapBikeRideStep.step(turningOn: true, permission: .notAsked, isDecoy: false) == .ask)
        #expect(HomeMapBikeRideStep.step(turningOn: true, permission: .allowed, isDecoy: false) == .ask)
        #expect(HomeMapBikeRideStep.step(turningOn: true, permission: .unavailable, isDecoy: false) == .staysOff)
        #expect(HomeMapBikeRideStep.step(turningOn: true, permission: .denied, isDecoy: false) == .openSettings)
    }

    /// "Log my bike rides" and the motion history's last check are device-only and go with the map's
    /// other settings (Delete everything's `WorldMapPreferences.clearAll`).
    @Test func theBikeRideKeysAreCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "HomeMapBikeRidesSettingsTests.\(UUID().uuidString)"))
        WorldMapPreferences.setLogsBikeRides(true, in: defaults)
        WorldMapPreferences.setBikeRidesCheckedThrough(Date(timeIntervalSince1970: 2_000_000_000), in: defaults)
        #expect(WorldMapPreferences.logsBikeRides(in: defaults))
        #expect(WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) != nil)
        WorldMapPreferences.clearAll(in: defaults)
        #expect(!WorldMapPreferences.logsBikeRides(in: defaults))
        #expect(WorldMapPreferences.bikeRidesCheckedThrough(in: defaults) == nil)
    }

    /// The page draws the approved copy (owner, 2026-10-26) and its identifier, and the switch shows the
    /// store's answer in both directions rather than writing the preference itself.
    @Test func thePageDrawsTheApprovedRowsAndAsksTheStore() throws {
        let page = try Self.page()
        #expect(page.contains("detail: \"Always. Low power, except while driving or riding.\""))
        #expect(!page.contains("Always, in low power. Fills the fog along your day."))
        #expect(page.contains("FernletRowLabel(\"Log my bike rides\", detail: \"Asks for Motion & Fitness when you turn it on.\")"))
        #expect(page.contains(".accessibilityIdentifier(\"settings.homeMap.bikeRides\")"))
        #expect(page.contains("logsBikeRides = await store.setWorldBikeRides(on)"))
        #expect(!page.contains("WorldMapPreferences.setLogsBikeRides"), "the store owns the switch's preference")
        // As drawn: the bike row follows Save new routes in The map.
        let saveRoutes = try #require(page.range(of: "\"settings.homeMap.saveRoutes\""))
        let bikeRides = try #require(page.range(of: "\"settings.homeMap.bikeRides\""))
        let storedRoutes = try #require(page.range(of: "\"Routes stored on this iPhone\""))
        #expect(saveRoutes.upperBound < bikeRides.lowerBound && bikeRides.upperBound < storedRoutes.lowerBound)
    }
}

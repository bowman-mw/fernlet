import Foundation
import Testing
import PrivateHealthStore
@testable import Fernlet

/// Advanced period tracking (World `b3-period-settings`, `b3-log-period` draft 2): which fields Log
/// period offers with the switch off and on, that a value already in the draft is never hidden, and
/// that the switch is device-only, cleared by Delete everything, and inert in a decoy session.
struct LogPeriodFieldVisibilityTests {
    /// A throwaway defaults suite, so the tests never touch the simulator's real switch.
    private func scratchDefaults() throws -> UserDefaults {
        let name = "LogPeriodFieldVisibilityTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test func offShowsTheCommonFourInTheSheetsOrder() {
        let shown = LogPeriodFieldVisibility.symptoms(advanced: false, selected: [])
        #expect(shown == [.cramps, .bloating, .headache, .fatigue])
    }

    @Test func offStillShowsASymptomTheEntryAlreadyHas() {
        let shown = LogPeriodFieldVisibility.symptoms(advanced: false, selected: [.acne, .cramps])
        #expect(shown == [.cramps, .bloating, .headache, .fatigue, .acne])
    }

    @Test func onShowsEverySymptom() {
        #expect(LogPeriodFieldVisibility.symptoms(advanced: true, selected: []) == PeriodSymptom.allCases)
    }

    @Test func unspecifiedFlowWaitsForAdvancedUnlessAlreadyChosen() {
        #expect(!LogPeriodFieldVisibility.flowLevels(advanced: false, selected: nil).contains(.unspecified))
        #expect(LogPeriodFieldVisibility.flowLevels(advanced: false, selected: .unspecified).contains(.unspecified))
        #expect(LogPeriodFieldVisibility.flowLevels(advanced: true, selected: nil) == PeriodFlowLevel.allCases)
    }

    @Test func observationsSpottingAndTemperatureFollowTheSwitchOrTheirValue() {
        #expect(!LogPeriodFieldVisibility.showsObservations(advanced: false, hasMucus: false, hasOvulationTest: false))
        #expect(LogPeriodFieldVisibility.showsObservations(advanced: false, hasMucus: true, hasOvulationTest: false))
        #expect(LogPeriodFieldVisibility.showsObservations(advanced: true, hasMucus: false, hasOvulationTest: false))
        #expect(!LogPeriodFieldVisibility.showsSpotting(advanced: false, isOn: false))
        #expect(LogPeriodFieldVisibility.showsSpotting(advanced: false, isOn: true))
        #expect(!LogPeriodFieldVisibility.showsTemperature(advanced: false, temperatureText: "  "))
        #expect(LogPeriodFieldVisibility.showsTemperature(advanced: false, temperatureText: "97.8"))
    }

    @Test func theSwitchIsOffByDefaultAndClearedByDeleteEverything() throws {
        let defaults = try scratchDefaults()
        #expect(!CyclePreferences.advancedTracking(duressSessionActive: false, in: defaults))
        CyclePreferences.setAdvancedTracking(true, duressSessionActive: false, in: defaults)
        #expect(CyclePreferences.advancedTracking(duressSessionActive: false, in: defaults))
        CyclePreferences.clearAll(in: defaults)
        #expect(!CyclePreferences.advancedTracking(duressSessionActive: false, in: defaults))
    }

    @Test func aDecoySessionNeitherReadsNorWritesIt() throws {
        let defaults = try scratchDefaults()
        CyclePreferences.setAdvancedTracking(true, duressSessionActive: false, in: defaults)
        #expect(!CyclePreferences.advancedTracking(duressSessionActive: true, in: defaults))
        CyclePreferences.setAdvancedTracking(false, duressSessionActive: true, in: defaults)
        #expect(CyclePreferences.advancedTracking(duressSessionActive: false, in: defaults))
    }
}

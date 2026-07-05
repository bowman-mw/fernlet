//
//  PetInteractionGovernorTests.swift
//  FernletTests
//
//  Batch D companion care: the pet time-lock state machine (rolling-window counting,
//  the 5th-pet settle, the once-per-settle soft line, cooldown expiry + re-arm, and
//  persistence round-trips via injected defaults/clock) plus the ambience pure
//  functions (hour → day phase, WeatherKit condition → sky bucket, nil fallbacks).
//

import Foundation
import Testing
import AppServices
#if canImport(WeatherKit)
import WeatherKit
#endif
@testable import Fernlet

// MARK: - Pet time-lock governor

struct PetInteractionGovernorTests {

    /// Mutable reference clock so tests can advance time deterministically.
    private final class FakeClock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(_ interval: TimeInterval) { now.addTimeInterval(interval) }
    }

    /// A throwaway, isolated defaults suite per test.
    private func makeDefaults() -> UserDefaults {
        let name = "PetGovernorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeGovernor(
        defaults: UserDefaults? = nil,
        clock: FakeClock
    ) -> PetInteractionGovernor {
        PetInteractionGovernor(defaults: defaults ?? makeDefaults(), now: { clock.now })
    }

    // MARK: Window counting + cap trigger

    @Test func firstFourPetsBouncePlayfully() {
        let clock = FakeClock()
        let governor = makeGovernor(clock: clock)
        for _ in 0..<4 {
            #expect(governor.registerPet() == .bounce)
            clock.advance(2)
        }
        #expect(!governor.isSettled)
    }

    @Test func fifthPetWithinWindowSettles() {
        let clock = FakeClock()
        let governor = makeGovernor(clock: clock)
        for _ in 0..<4 {
            _ = governor.registerPet()
            clock.advance(2)
        }
        #expect(governor.registerPet() == .settling)
        #expect(governor.isSettled)
    }

    @Test func quietSpellResetsTheRollingWindow() {
        let clock = FakeClock()
        let governor = makeGovernor(clock: clock)
        for _ in 0..<4 {
            _ = governor.registerPet()
            clock.advance(2)
        }
        // Walk away past the window: the count starts fresh, so the next pet is a
        // plain bounce and it takes a full five more to settle.
        clock.advance(governor.window + 1)
        for _ in 0..<4 {
            #expect(governor.registerPet() == .bounce)
            clock.advance(2)
        }
        #expect(governor.registerPet() == .settling)
    }

    // MARK: Settled period behavior

    @Test func petsWhileSettledAreCalmAndTheSoftLineShowsOnce() {
        let clock = FakeClock()
        let governor = makeGovernor(clock: clock)
        for _ in 0..<5 { _ = governor.registerPet() }
        #expect(governor.isSettled)

        clock.advance(5)
        #expect(governor.registerPet() == .calmIdle(showsSettledLine: true))
        clock.advance(5)
        #expect(governor.registerPet() == .calmIdle(showsSettledLine: false))
        clock.advance(5)
        #expect(governor.registerPet() == .calmIdle(showsSettledLine: false))
    }

    @Test func settleExpiryReArmsPlayfulPetting() {
        let clock = FakeClock()
        let governor = makeGovernor(clock: clock)
        for _ in 0..<5 { _ = governor.registerPet() }
        _ = governor.registerPet() // consume the soft line for this settle

        clock.advance(governor.settleDuration + 1)
        #expect(!governor.isSettled)
        // Fresh window: playful again, and a whole new count before settling.
        for _ in 0..<4 {
            #expect(governor.registerPet() == .bounce)
            clock.advance(2)
        }
        #expect(governor.registerPet() == .settling)
        // The soft line resets with the new settle period.
        clock.advance(5)
        #expect(governor.registerPet() == .calmIdle(showsSettledLine: true))
    }

    // MARK: Persistence round-trips (injected defaults + clock)

    @Test func windowCountSurvivesRelaunch() {
        let clock = FakeClock()
        let defaults = makeDefaults()

        let first = makeGovernor(defaults: defaults, clock: clock)
        for _ in 0..<3 {
            _ = first.registerPet()
            clock.advance(2)
        }

        // "Relaunch": a new governor over the same defaults continues the count.
        let second = makeGovernor(defaults: defaults, clock: clock)
        #expect(second.registerPet() == .bounce)
        clock.advance(2)
        #expect(second.registerPet() == .settling)
    }

    @Test func settledStateAndSoftLineFlagSurviveRelaunch() {
        let clock = FakeClock()
        let defaults = makeDefaults()

        let first = makeGovernor(defaults: defaults, clock: clock)
        for _ in 0..<5 { _ = first.registerPet() }
        clock.advance(5)
        #expect(first.registerPet() == .calmIdle(showsSettledLine: true))

        // Relaunch mid-settle: still settled, and the line does NOT repeat.
        let second = makeGovernor(defaults: defaults, clock: clock)
        #expect(second.isSettled)
        clock.advance(5)
        #expect(second.registerPet() == .calmIdle(showsSettledLine: false))
    }

    @Test func clearPersistentStateResetsEverything() {
        let clock = FakeClock()
        let defaults = makeDefaults()

        let governor = makeGovernor(defaults: defaults, clock: clock)
        for _ in 0..<5 { _ = governor.registerPet() }
        #expect(governor.isSettled)

        PetInteractionGovernor.clearPersistentState(in: defaults)
        #expect(!governor.isSettled)
        #expect(governor.registerPet() == .bounce)
    }
}

// MARK: - Ambience pure functions

@MainActor
struct CompanionAmbienceTests {

    @Test func hourToPhaseMappingPinsTheBoundaries() {
        #expect(CompanionDayPhase.phase(forHour: 0) == .night)
        #expect(CompanionDayPhase.phase(forHour: 4) == .night)
        #expect(CompanionDayPhase.phase(forHour: 5) == .dawn)
        #expect(CompanionDayPhase.phase(forHour: 7) == .dawn)
        #expect(CompanionDayPhase.phase(forHour: 8) == .day)
        #expect(CompanionDayPhase.phase(forHour: 16) == .day)
        #expect(CompanionDayPhase.phase(forHour: 17) == .dusk)
        #expect(CompanionDayPhase.phase(forHour: 20) == .dusk)
        #expect(CompanionDayPhase.phase(forHour: 21) == .night)
        #expect(CompanionDayPhase.phase(forHour: 23) == .night)
    }

    @Test func currentPhaseReadsTheCalendarHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = DateComponents(calendar: calendar, year: 2026, month: 7, day: 5, hour: 12).date!
        let midnight = DateComponents(calendar: calendar, year: 2026, month: 7, day: 5, hour: 0).date!
        #expect(CompanionDayPhase.current(date: noon, calendar: calendar) == .day)
        #expect(CompanionDayPhase.current(date: midnight, calendar: calendar) == .night)
    }

    @Test func everyPhaseHasAUsableTintGradient() {
        for phase in CompanionDayPhase.allCases {
            #expect(CompanionAmbienceLayer.tintColors(for: phase).count >= 2)
        }
    }

    #if canImport(WeatherKit)
    @Test func conditionsMapToCoarseSkyBuckets() {
        #expect(WeatherKitService.ambientSky(for: .rain) == .rain)
        #expect(WeatherKitService.ambientSky(for: .drizzle) == .rain)
        #expect(WeatherKitService.ambientSky(for: .thunderstorms) == .rain)
        #expect(WeatherKitService.ambientSky(for: .snow) == .snow)
        #expect(WeatherKitService.ambientSky(for: .flurries) == .snow)
        #expect(WeatherKitService.ambientSky(for: .sleet) == .snow)
        #expect(WeatherKitService.ambientSky(for: .cloudy) == .clouds)
        #expect(WeatherKitService.ambientSky(for: .partlyCloudy) == .clouds)
        #expect(WeatherKitService.ambientSky(for: .foggy) == .clouds)
        #expect(WeatherKitService.ambientSky(for: .clear) == .clear)
        #expect(WeatherKitService.ambientSky(for: .mostlyClear) == .clear)
        // Not gloomy, not a sky accent — open-sky extremes stay calm/clear.
        #expect(WeatherKitService.ambientSky(for: .hot) == .clear)
        #expect(WeatherKitService.ambientSky(for: .windy) == .clear)
    }

    /// The unauthorized/no-entitlement path: no cached conditions ⇒ `nil`, and the
    /// layer's contract is "nil ambient = time-tint only" (the optional simply drops
    /// the accents pass). Same nil-on-any-failure contract as `currentComfort`.
    @MainActor
    @Test func unavailableWeatherFallsBackToTimeTintOnly() async {
        // The test host never has location authorization, so the shared conditions
        // fetch must degrade to nil — never throw, never block the caller.
        #expect(await WeatherKitService.shared.currentAmbient() == nil)
    }
    #endif
}

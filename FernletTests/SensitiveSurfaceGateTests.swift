import Foundation
import Testing
import FernletDomainModel
import FernletLock
import HealthKitGateway
import LocalPersistence
@testable import Fernlet

/// The hide gate for period (#4) + intimacy (#5). The rule these enforce: hiding is a HARD gate —
/// Fernlet reads nothing, derives nothing, holds nothing — and hiding NEVER deletes.
@MainActor
struct SensitiveSurfaceGateTests {

    private func makeStore(_ name: String) -> FernletStore {
        FernletStore(repository: LocalFernletRepository(fileURL: temporaryDatabaseURL(name)))
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    // MARK: - Visibility derivation

    @Test func periodVisibilityDerivesFromSexWhenUnset() {
        let store = makeStore("gate-derive-sex")
        store.settings.periodTrackingVisible = nil

        store.settings.userProfile.sex = .female
        #expect(store.isPeriodTrackingVisible)

        store.settings.userProfile.sex = .male
        #expect(!store.isPeriodTrackingVisible)
    }

    /// An explicit choice must outrank `sex` in BOTH directions. This matters because the HealthKit
    /// body-profile auto-import rewrites `sex` on launch — without the override winning, Health could
    /// silently overturn the user's Settings choice on the next cold start.
    @Test func explicitPeriodChoiceOutranksSex() {
        let store = makeStore("gate-explicit-outranks-sex")

        store.settings.userProfile.sex = .male
        store.settings.periodTrackingVisible = true
        #expect(store.isPeriodTrackingVisible)

        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = false
        #expect(!store.isPeriodTrackingVisible)
    }

    /// Turning the toggle on/off must always write an explicit value — including when the chosen value
    /// matches what `sex` would have derived — or a later `sex` change would silently overturn it.
    @Test func togglingAlwaysRecordsAnExplicitChoice() {
        let store = makeStore("gate-records-explicit")
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = nil

        store.setPeriodTrackingVisible(true)

        #expect(store.settings.periodTrackingVisible == true)
        store.settings.userProfile.sex = .male
        #expect(store.isPeriodTrackingVisible)
    }

    // MARK: - Age vs preference (intimacy)

    /// Age is a floor, not a preference: an adult who hides and a minor are both invisible, but only
    /// the adult can turn it back on.
    @Test func intimacyVisibilityRequiresBothAgeAndPreference() {
        let store = makeStore("gate-intimacy-age")

        store.settings.userProfile.age = 17
        store.settings.intimacyTrackingVisible = true
        #expect(!store.isIntimacyTrackingVisible)

        store.settings.userProfile.age = 18
        #expect(store.isIntimacyTrackingVisible)

        store.settings.intimacyTrackingVisible = false
        #expect(!store.isIntimacyTrackingVisible)
    }

    @Test func intimacyDefaultsToVisibleForAdults() {
        let store = makeStore("gate-intimacy-default")
        store.settings.userProfile.age = 30

        // Default ON preserves today's behavior, and means the flag only ever deviates from its
        // default in the benign direction (OFF) when it rides the synced blob.
        #expect(store.settings.intimacyTrackingVisible)
        #expect(store.isIntimacyTrackingVisible)
    }

    // MARK: - Ambient HealthKit reads (G4)

    @Test func hiddenSurfacesAreSubtractedFromHealthCapabilities() {
        let store = makeStore("gate-capabilities")
        store.settings.userProfile.age = 30
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = true
        store.settings.intimacyTrackingVisible = true

        let all = Set(HealthCapability.allCases)
        // Baseline: nothing hidden, and the store must be unlocked or the lock gate confounds this.
        #expect(store.allowedHealthCapabilities(from: all).contains(.cycleTracking) == (store.lockState == .unlocked))

        store.settings.periodTrackingVisible = false
        #expect(!store.allowedHealthCapabilities(from: all).contains(.cycleTracking))

        store.settings.intimacyTrackingVisible = false
        #expect(!store.allowedHealthCapabilities(from: all).contains(.intimateLogging))
    }

    // MARK: - Derived leaks

    /// `HealthDailyContext.merge` coalesces with `other.x ?? x`, so simply not FETCHING a dimension
    /// freezes its last value forever. Hiding must explicitly nil it, or a day that recorded cycle
    /// data before the user hid the feature keeps serving it.
    @Test func scrubbingClearsHiddenHealthContextDimensions() {
        let store = makeStore("gate-scrub-context")
        store.settings.userProfile.age = 30
        store.day.healthContext = HealthDailyContext(
            cycle: HealthCycleContext(),
            intimate: HealthIntimateContext(eventCount: 2)
        )

        store.settings.periodTrackingVisible = false
        store.settings.intimacyTrackingVisible = false
        store.scrubHiddenHealthContext()

        #expect(store.day.healthContext?.cycle == nil)
        #expect(store.day.healthContext?.intimate == nil)
    }

    @Test func scrubbingLeavesVisibleDimensionsAlone() {
        let store = makeStore("gate-scrub-keeps-visible")
        store.settings.userProfile.age = 30
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = true
        store.settings.intimacyTrackingVisible = true
        store.day.healthContext = HealthDailyContext(
            cycle: HealthCycleContext(),
            intimate: HealthIntimateContext(eventCount: 3)
        )

        store.scrubHiddenHealthContext()

        #expect(store.day.healthContext?.intimate?.eventCount == 3)
    }

    // MARK: - Quick log is display-only

    /// Hiding must not rewrite the user's saved quick-log layout. The filter is for rendering only —
    /// if hiding stripped the shortcut from the STORED array, un-hiding could not restore it and the
    /// user's choice would be silently destroyed.
    @Test func hidingFiltersQuickLogForDisplayWithoutMutatingStoredItems() {
        let store = makeStore("gate-quicklog-display-only")
        store.settings.userProfile.age = 30
        let chosen: [FernletShortcut] = [.meal, .water, .intimacyTracking, .periodTracking]
        store.setQuickLogItems(chosen)

        store.settings.intimacyTrackingVisible = false
        store.settings.periodTrackingVisible = false

        let rendered = FernletShortcut.visibleQuickLog(
            store.settings.quickLogItems,
            visibility: store.sensitiveSurfaceVisibility
        )
        #expect(!rendered.contains(.intimacyTracking))
        #expect(!rendered.contains(.periodTracking))

        // The saved choice survives untouched...
        #expect(store.settings.quickLogItems.contains(.intimacyTracking))
        #expect(store.settings.quickLogItems.contains(.periodTracking))

        // ...and comes back on un-hide.
        store.settings.intimacyTrackingVisible = true
        store.settings.periodTrackingVisible = true
        let restored = FernletShortcut.visibleQuickLog(
            store.settings.quickLogItems,
            visibility: store.sensitiveSurfaceVisibility
        )
        #expect(restored.contains(.intimacyTracking))
        #expect(restored.contains(.periodTracking))
    }

    // MARK: - Regressions found by adversarial review

    /// The gate is DERIVED, so the Settings toggle is only one of its inputs — editing Gender/Age in the
    /// profile editor, or a HealthKit body-profile auto-import, flips it just as surely. Keying the
    /// scrub to `setPeriodTrackingVisible` alone left those paths hiding the UI while the data stayed
    /// live, so the scrub must be driven off the VALUE. This asserts the value moves; ContentView's
    /// `.onChange(of: store.sensitiveSurfaceVisibility)` is what acts on it.
    @Test func editingProfileSexFlipsTheDerivedGate() {
        let store = makeStore("gate-derived-flip-sex")
        store.settings.periodTrackingVisible = nil
        store.settings.userProfile.sex = .female
        #expect(store.sensitiveSurfaceVisibility.period)

        // No call to setPeriodTrackingVisible — this is the profile-editor / HealthKit-import path.
        store.settings.userProfile.sex = .male

        #expect(!store.sensitiveSurfaceVisibility.period)
    }

    @Test func agingBelowTheFloorFlipsTheDerivedIntimacyGate() {
        let store = makeStore("gate-derived-flip-age")
        store.settings.userProfile.age = 30
        store.settings.intimacyTrackingVisible = true
        #expect(store.sensitiveSurfaceVisibility.intimacy)

        store.settings.userProfile.age = 17

        #expect(!store.sensitiveSurfaceVisibility.intimacy)
    }

    /// The scrub must be reachable from the derived flip, not only the setter — this is the exact hole
    /// that made the first fix incomplete.
    @Test func scrubbingAfterADerivedFlipClearsHealthContext() {
        let store = makeStore("gate-derived-flip-scrub")
        store.settings.periodTrackingVisible = nil
        store.settings.userProfile.sex = .female
        store.day.healthContext = HealthDailyContext(cycle: HealthCycleContext())

        store.settings.userProfile.sex = .male
        // Stands in for ContentView's .onChange(of: store.sensitiveSurfaceVisibility).
        store.scrubHiddenHealthContext()

        #expect(store.day.healthContext?.cycle == nil)
    }

    /// `allows(_:)` used a `default: true`, which failed OPEN for `.logPeriod` — a live period-LOGGING
    /// tile stayed on Home while the feature was hidden, and tapping it opened a sheet whose save was
    /// guaranteed to throw. Every gated shortcut must be enumerated.
    @Test func logPeriodShortcutIsGatedWithPeriodSurfaces() {
        let hidden = SensitiveSurfaceVisibility(intimacy: true, period: false)

        #expect(!hidden.allows(FernletShortcut.logPeriod))
        #expect(!hidden.allows(FernletShortcut.periodTracking))
        #expect(hidden.allows(FernletShortcut.intimacyTracking))
        // Ungated shortcuts are unaffected.
        #expect(hidden.allows(FernletShortcut.meal))
        #expect(hidden.allows(FernletShortcut.worryBox))
    }

    @Test func hiddenPeriodFiltersLogPeriodOutOfQuickLog() {
        let store = makeStore("gate-logperiod-quicklog")
        store.settings.periodTrackingVisible = false

        let rendered = FernletShortcut.visibleQuickLog(
            [.meal, .water, .logPeriod, .move, .sleep, .journal],
            visibility: store.sensitiveSurfaceVisibility
        )
        #expect(!rendered.contains(.logPeriod))
    }

    /// Settings > Health listed a Cycle row while hidden whose "Update data" action re-read HealthKit
    /// and wrote straight back into `healthContext.cycle` — undoing the scrub rather than merely
    /// ignoring the gate.
    @Test func hiddenSurfacesAreNotOfferedAsHealthRows() {
        let store = makeStore("gate-visible-capabilities")
        store.settings.userProfile.age = 30
        store.settings.userProfile.sex = .female
        store.settings.periodTrackingVisible = true
        store.settings.intimacyTrackingVisible = true

        #expect(store.visibleHealthCapabilities.contains(.cycleTracking))
        #expect(store.visibleHealthCapabilities.contains(.intimateLogging))

        store.settings.periodTrackingVisible = false
        store.settings.intimacyTrackingVisible = false

        #expect(!store.visibleHealthCapabilities.contains(.cycleTracking))
        #expect(!store.visibleHealthCapabilities.contains(.intimateLogging))
        // Ungated rows survive.
        #expect(store.visibleHealthCapabilities.contains(.activityContext))
    }

    @Test func hubSectionsFollowVisibility() {
        #expect(PrivateHubSection.visibleSections(visibility: .all) == PrivateHubSection.allCases)

        let hidden = PrivateHubSection.visibleSections(
            visibility: SensitiveSurfaceVisibility(intimacy: false, period: false)
        )
        #expect(!hidden.contains(.intimacy))
        #expect(!hidden.contains(.period))
        // Ungated sections are unaffected.
        #expect(hidden.contains(.journal))
        #expect(hidden.contains(.worryBox))
    }
}

/// Settings decode: a fresh install derives from `sex`, but an EXISTING user must never silently lose
/// period tracking just because `sex` defaults to `.male`.
struct SensitiveSurfaceGateDecodeTests {

    private func decode(_ json: String) throws -> FernletSettings {
        try JSONDecoder().decode(FernletSettings.self, from: Data(json.utf8))
    }

    /// A blob from a build that predates the gate: no `periodTrackingVisible` AND no migration marker.
    /// Such a user may have been tracking cycles for months while `sex` sat at its `.male` default, so
    /// they must be pinned visible rather than silently losing the feature.
    @Test func legacySettingsPinPeriodTrackingVisible() throws {
        let settings = try decode(#"{"hasCompletedOnboarding": true}"#)

        #expect(settings.periodTrackingVisible == true)
        #expect(settings.didMigratePeriodVisibility)
    }

    /// Regression: the marker was originally `hasCompletedOnboarding`, which is NOT a proxy for
    /// "existing user" — it turns true for new users the moment they finish onboarding. That pinned
    /// every new user to visible on their second launch and meant the `sex` derivation never ran.
    /// A post-gate blob must leave visibility unset so it keeps deriving.
    @Test func completedOnboardingAloneDoesNotPinVisibility() throws {
        let settings = try decode(#"{"hasCompletedOnboarding": true, "didMigratePeriodVisibility": true}"#)

        #expect(settings.periodTrackingVisible == nil)
    }

    @Test func freshInstallLeavesPeriodVisibilityUnsetSoItDerivesFromSex() throws {
        // A fresh install writes the marker on its first save, so subsequent decodes must not migrate.
        let settings = try decode(#"{"didMigratePeriodVisibility": true}"#)

        #expect(settings.periodTrackingVisible == nil)
    }

    /// The migration must run at most once: a legacy user who migrates, then deliberately hides, must
    /// stay hidden rather than being re-pinned to visible on the next launch.
    @Test func migrationDoesNotOverrideALaterExplicitChoice() throws {
        let settings = try decode(#"{"didMigratePeriodVisibility": true, "periodTrackingVisible": false}"#)

        #expect(settings.periodTrackingVisible == false)
    }

    @Test func migrationMarkerRoundTripsSoItNeverRunsTwice() throws {
        let migrated = try decode(#"{"hasCompletedOnboarding": true}"#)
        let data = try JSONEncoder().encode(migrated)
        let reloaded = try JSONDecoder().decode(FernletSettings.self, from: data)

        #expect(reloaded.didMigratePeriodVisibility)
        #expect(reloaded.periodTrackingVisible == true)
    }

    @Test func explicitStoredChoiceSurvivesDecode() throws {
        let hidden = try decode(#"{"hasCompletedOnboarding": true, "periodTrackingVisible": false}"#)
        #expect(hidden.periodTrackingVisible == false)

        let shown = try decode(#"{"hasCompletedOnboarding": false, "periodTrackingVisible": true}"#)
        #expect(shown.periodTrackingVisible == true)
    }

    @Test func intimacyVisibilityDefaultsToTrueWhenAbsent() throws {
        let settings = try decode(#"{}"#)

        #expect(settings.intimacyTrackingVisible)
    }

    @Test func settingsRoundTripPreservesVisibility() throws {
        var settings = FernletSettings()
        settings.periodTrackingVisible = false
        settings.intimacyTrackingVisible = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: data)

        #expect(decoded.periodTrackingVisible == false)
        #expect(!decoded.intimacyTrackingVisible)
    }
}

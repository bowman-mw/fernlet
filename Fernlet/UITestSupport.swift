//
//  UITestSupport.swift
//  Fernlet
//
//  DEBUG-only launch hooks used by the UX *appearance* UI tests (FernletUITests/
//  ScreenAppearance*). They let a test put the app into a deterministic, populated
//  state and jump straight to any screen so its layout can be checked and a labeled
//  screenshot captured.
//
//  The entire surface is wrapped in `#if DEBUG`; in release builds every flag is a
//  hard-coded no-op, so none of this — including `seedDemoContent()` — ships. This
//  mirrors the existing `-completeOnboarding` / `FERNLET_UI_TEST_*` conventions
//  consumed in FernletApp.swift, ContentView.swift and PrivacyDataSettingsView.swift.
//

import Foundation
import FernletDomainModel

/// Central reader for the UX-appearance-test launch flags.
///
/// Keep all new `FERNLET_UI_TEST_*` reads here so the app source has a single, auditable seam.
/// DEBUG-only: in release builds every flag is a hard-coded no-op, so none of the hooks (or the
/// demo seed they enable) ships. Consumed by `FernletApp`, `ContentView`, and `HomeView`.
enum UITestSupport {
    #if DEBUG
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// `FERNLET_UI_TEST_SEED_DEMO=1` — populate today's diary with representative
    /// meals/water/sleep/journal/workout/hygiene/memories so every tab renders real
    /// cards (not empty states) and the companion reads as thriving.
    static var shouldSeedDemoContent: Bool { env["FERNLET_UI_TEST_SEED_DEMO"] == "1" }

    /// `FERNLET_UI_TEST_BYPASS_PRIVATE_LOCK=1` — render the Private hub's
    /// Journal/Cycle screens without configuring an app passcode. This only
    /// disables the *gate overlay* for appearance review; it does not unseal real
    /// private data (sealed cycle/intimacy content stays encrypted).
    static var bypassPrivateLockGate: Bool { env["FERNLET_UI_TEST_BYPASS_PRIVATE_LOCK"] == "1" }

    /// `FERNLET_UI_TEST_HIDE_PERIOD=1` — seed the demo persona with the period surface explicitly
    /// hidden, so the appearance gallery can review the merged Cycle page's intimacy-only
    /// rendering. Consumed by `FernletStore.seedDemoContent` on every seeded launch.
    static var hidePeriodSurface: Bool { env["FERNLET_UI_TEST_HIDE_PERIOD"] == "1" }

    /// `FERNLET_UI_TEST_HIDE_INTIMACY=1` — seed the demo persona with the intimacy surface
    /// explicitly hidden, for the Cycle page's period-only rendering. Consumed by
    /// `FernletStore.seedDemoContent` on every seeded launch.
    static var hideIntimacySurface: Bool { env["FERNLET_UI_TEST_HIDE_INTIMACY"] == "1" }

    /// `FERNLET_UI_TEST_OPEN_SHEET=<FernletSheet.id>` — present a sheet directly on
    /// launch (e.g. "workout", "settings", "trends"). Generalizes the older
    /// `FERNLET_UI_TEST_OPEN_SETTINGS=1` hook, which is still honored for back-compat.
    static var initialSheet: FernletSheet? {
        if env["FERNLET_UI_TEST_OPEN_SETTINGS"] == "1" { return .settings }
        guard let id = env["FERNLET_UI_TEST_OPEN_SHEET"] else { return nil }
        return FernletSheet(uiTestID: id)
    }

    /// `FERNLET_UI_TEST_OPEN_CUSTOMIZE=1` — open the companion customization sheet on Home launch.
    /// The sheet is only reachable by a long-press on the hero companion, which XCUITest can't
    /// synthesize; this hook lets the item-creation flow (slot picker → Wardrobe → studio) be driven.
    static var shouldOpenCustomize: Bool { env["FERNLET_UI_TEST_OPEN_CUSTOMIZE"] == "1" }

    /// `FERNLET_UI_TEST_SEED_STUDIO_CANVAS=1` — open the Creation Studio's editor with a pre-painted
    /// canvas. XCUITest can't drive the custom zoomable canvas's paint gesture, and "Next" stays disabled
    /// while the canvas is blank, so without this the naming / shop-listing confirmation step (and its
    /// moderation alert) is unreachable from a UI test.
    static var shouldSeedStudioCanvas: Bool { env["FERNLET_UI_TEST_SEED_STUDIO_CANVAS"] == "1" }

    /// True when a test harness owns this process: an XCTest runner is attached (the unit-test
    /// host app), or the app was launched by a UI test (`XCTestSessionIdentifier`, the
    /// `-completeOnboarding`/`-resetOnboarding` arguments, or any `FERNLET_UI_TEST_*` hook).
    ///
    /// Consumed by `FernletApp` to suppress the one-time backup-exclusion launch gate
    /// (`BackupExclusionLaunchGate`): an unanswered launch alert would deadlock every UI test,
    /// and a unit-test host running the gate would mutate the REAL storage-preferences keychain
    /// blob and prior-use marker on the test simulator. Release builds hard-code `false`, so the
    /// gate always runs for real users.
    static var isTestHarnessActive: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || arguments.contains("-completeOnboarding")
            || arguments.contains("-resetOnboarding")
            || env.keys.contains { $0.hasPrefix("FERNLET_UI_TEST_") }
    }
    #else
    static var shouldSeedDemoContent: Bool { false }
    static var bypassPrivateLockGate: Bool { false }
    static var hidePeriodSurface: Bool { false }
    static var hideIntimacySurface: Bool { false }
    static var initialSheet: FernletSheet? { nil }
    static var shouldOpenCustomize: Bool { false }
    static var shouldSeedStudioCanvas: Bool { false }
    static var isTestHarnessActive: Bool { false }
    #endif
}

#if DEBUG
extension FernletSheet {
    /// Maps a `FERNLET_UI_TEST_OPEN_SHEET` id back to a sheet case. The two
    /// recipe-editor cases carry a synthetic fixture so the editor renders without
    /// needing a real saved recipe.
    init?(uiTestID id: String) {
        switch id {
        case "meal":              self = .meal
        case "recipe":            self = .recipe
        case "water":             self = .water
        case "sleep":             self = .sleep
        case "journal":           self = .journal
        case "quickExercise":     self = .quickExercise
        case "workout":           self = .workout
        case "workoutSuggestion": self = .workoutSuggestion
        case "goals":             self = .goals
        case "hygiene":           self = .hygiene
        case "settings":          self = .settings
        case "recipeBook":        self = .recipeBook
        case "trends":            self = .trends
        case "stressExplainer":   self = .stressExplainer
        case "firstAid":          self = .firstAid(nil)
        case "logPeriod":         self = .logPeriod(targetDate: nil, editingEntry: nil)
        case "logIntimacy":       self = .logIntimacy
        case "editRecipe":        self = .editRecipe(Self.uiTestRecipeFixture())
        case "editSavedRecipe":   self = .editSavedRecipe(Self.uiTestRecipeFixture())
        default:                  return nil
        }
    }

    /// A minimal, deterministic recipe used only to render the recipe-editor sheets in
    /// appearance tests.
    private static func uiTestRecipeFixture() -> RecipeDefinition {
        RecipeDefinition(
            name: "Demo recipe",
            servings: 2,
            ingredients: [],
            notes: "Seeded for UX appearance tests.",
            source: "manual",
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
#endif

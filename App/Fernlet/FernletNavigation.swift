//
//  FernletNavigation.swift
//  Fernlet
//
//  App navigation enums, split out of the design system when it moved into the
//  `FernletUI` package target (SPM carve-up §14): `FernletSheet` references
//  app-resident payloads (`FirstAidTool`) so these stay in the app, per the
//  plan's §5c "NavigationEnums → app target" rule.
//

import SwiftUI
import FernletDomainModel
import PrivateHealthStore

/// How Fernlet picks light or dark: follow the phone, or force one.
///
/// Stored as a raw string under ``storageKey`` and read with `@AppStorage`; `.system` (the default)
/// maps to a `nil` `preferredColorScheme`, which is the only value that lets the OS decide. The app
/// previously had a Dark-mode Bool that ContentView passed to `preferredColorScheme` as
/// `.dark`/`.light` — never `nil` — so a phone in Dark Mode still got a fully light app, with no
/// "match system" choice anywhere and a dark onboarding handing over to a light app on step 8.
///
/// ``migrateLegacyDarkModePreferenceIfNeeded(defaults:)`` carries the old Bool over once at launch,
/// so an existing user's dark app stays dark.
enum FernletAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// `@AppStorage` key for the stored choice.
    static let storageKey = "fernletAppearanceMode"
    /// The pre-three-way Bool this replaces. Read once by the migration below, then left alone.
    static let legacyDarkModeKey = "fernletDarkModeEnabled"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The value to hand `preferredColorScheme`. `nil` for ``system`` — passing a concrete scheme
    /// is exactly what pinned the app to one appearance regardless of the phone.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// One-time carry-over of the legacy Dark-mode Bool.
    ///
    /// Only runs when no mode has been stored yet AND the old key exists, so a fresh install
    /// defaults to ``system`` while an existing user keeps the appearance they chose. Idempotent.
    static func migrateLegacyDarkModePreferenceIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == nil,
              defaults.object(forKey: legacyDarkModeKey) != nil else { return }
        let mode: FernletAppearanceMode = defaults.bool(forKey: legacyDarkModeKey) ? .dark : .light
        defaults.set(mode.rawValue, forKey: storageKey)
    }
}

/// The five top-level tabs (Home / Food / Move / Friends / Private) in display order.
///
/// `ContentView` keys the paged `TabView`, the custom floating tab bar, and the per-tab
/// listener/health-refresh gating on this; the raw value doubles as a stable identifier for
/// per-tab reset tokens. `next`/`previous` support ordered paging helpers.
enum FernletTab: String, CaseIterable, Hashable, Identifiable {
    case home
    case food
    case move
    case social
    case personal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .food: "Food"
        case .move: "Move"
        case .social: "Friends"
        case .personal: "Private"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "leaf.fill"
        case .food: "fork.knife"
        case .move: "figure.walk"
        case .social: "person.2.fill"
        case .personal: "lock.fill"
        }
    }

    var label: Label<Text, Image> {
        Label(title, systemImage: systemImage)
    }

    var next: FernletTab? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        return nextIndex < Self.allCases.endIndex ? Self.allCases[nextIndex] : nil
    }

    var previous: FernletTab? {
        guard let index = Self.allCases.firstIndex(of: self), index > Self.allCases.startIndex else { return nil }
        let previousIndex = Self.allCases.index(before: index)
        return Self.allCases[previousIndex]
    }
}

/// Every modal sheet the app can present, routed through `ContentView`'s single
/// `activeSheet` slot (one sheet at a time; chained handoffs dismiss-then-represent).
///
/// Cases with payloads carry the edit target (recipe, period entry) or a deep-link hint
/// (`firstAid`'s optional tool). The string `id` is also the contract for the
/// `FERNLET_UI_TEST_OPEN_SHEET` launch hook (see `UITestSupport`) and the notification/App
/// Intent deep-link tokens, so renaming an id is a cross-file change.
enum FernletSheet: Identifiable {
    case meal
    case recipe
    case water
    case sleep
    case journal
    case workout
    case workoutSuggestion
    case goals
    case hygiene
    case settings
    case recipeBook
    case trends
    /// Lifetime milestones as a large sheet (2026-08-21 artboard 3f): one rule for read-only
    /// destinations from Home — they present as sheets, matching Trends, First aid and the gear.
    case milestones
    case stressExplainer
    /// Calm first-aid tools (breathing / grounding / worry box); the optional tool deep-links
    /// straight into one of them (gentle-offer cards use it).
    case firstAid(FirstAidTool?)
    case logPeriod(targetDate: Date?, editingEntry: CycleDayEntry?)
    case logIntimacy
    case editRecipe(RecipeDefinition)
    case editSavedRecipe(RecipeDefinition)

    /// Stable string identity per case (edit cases append the payload id so distinct edits
    /// re-present). Also the public id space for UI-test and deep-link routing — keep in sync
    /// with `FernletSheet(uiTestID:)`.
    var id: String {
        switch self {
        case .meal: "meal"
        case .recipe: "recipe"
        case .water: "water"
        case .sleep: "sleep"
        case .journal: "journal"
        case .workout: "workout"
        case .workoutSuggestion: "workoutSuggestion"
        case .goals: "goals"
        case .hygiene: "hygiene"
        case .settings: "settings"
        case .recipeBook: "recipeBook"
        case .trends: "trends"
        case .milestones: "milestones"
        case .stressExplainer: "stressExplainer"
        case .firstAid: "firstAid"
        case .logPeriod: "logPeriod"
        case .logIntimacy: "logIntimacy"
        case .editRecipe(let r): "editRecipe-\(r.id)"
        case .editSavedRecipe(let r): "editSavedRecipe-\(r.id)"
        }
    }
}

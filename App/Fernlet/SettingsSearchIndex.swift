// SettingsSearchIndex.swift
// Addressable routing + a searchable leaf catalog for the Settings hub (TF feedback item 10).
//
// `SettingsRoute` is the single Hashable value driving value-based navigation out of the hub:
// every sub-page link and every search result pushes one of these, resolved by the hub's lone
// `.navigationDestination(for: SettingsRoute.self)`.
//
// `SettingsSearchIndex.entries` is a hand-written catalog at LEAF granularity — one entry per
// meaningful control across the hub's sections AND the Privacy & Data sub-page's top-level cards —
// each carrying the synonyms a user would actually type ("dark mode", "face id", "icloud", …).
// Matching mirrors `FernletDomainModel.FoodItemSearch`'s token style (diacritic/case-insensitive,
// prefix-AND over title + keywords) but is deliberately self-contained: no food-catalog import.
//
// LOCALIZATION: `title` and `breadcrumb` were each one string doing two jobs — a token (the matching
// input, the row identity) AND the text of the result row. They are FORKED here (the localization
// wall's rule, see `Tests/FernletTests/LocalizationBoundaryTests`): `title`, `keywords` and the
// breadcrumb's `token` stay frozen English tokens, and the row renders only the display halves,
// ``SettingsSearchEntry/displayTitle`` and ``SettingsSearchEntry/displayBreadcrumb`` — explicit
// semantic catalog keys (`settings.search.title.*`, `settings.search.breadcrumb.*`), never a key
// built from the token at runtime, so rewording a token can never orphan a translation. The search
// synonyms stay English: matching vocabulary is per-language curation, not translation (Spanish
// round, 2026-10-20) — so each language beyond English curates its own in `SettingsSearchSynonyms`,
// keyed by the frozen title and matched while that language is an input language (localization
// plan §5, Phase 3).

import Foundation
import SwiftUI
import FernletDomainModel

/// Every addressable destination reachable from the Settings hub.
///
/// The single Hashable value driving value-based navigation: every sub-page link and every search
/// result pushes one of these, resolved by the hub's lone
/// `.navigationDestination(for: SettingsRoute.self)`. Adding a case is a compile-time prompt to
/// (a) return its view from `SettingsSheet.destination(for:)` and (b) give it at least one
/// ``SettingsSearchIndex`` entry (asserted in `SettingsSearchIndexTests`).
nonisolated enum SettingsRoute: Hashable, CaseIterable {
    case appearance
    case goalNutrition
    case personalCare
    case layoutShortcuts
    case soundsHaptics
    /// Home map (World build step 5c, `b1-settings-map`): location, the fog, routes and places.
    case homeMap
    case aiDataSources
    case health
    case coreMemory
    case signals
    case debug
    case connectionInspector
    case connectionHistory
    case privacyData
    case aiAuditLog
    case privacyPolicy
    case safetyReporting
    case appLock
    case sharing
    case nearbyFriends
    /// Friends & Blocks (`b4-mem-settings-friends`): the friend list and the name you appear as, moved
    /// here from the Friends tab's header.
    case friendsBlocks
    case periodSensitive
}

/// One searchable leaf: the frozen English label it is FOUND by, its search synonyms, a breadcrumb
/// subtitle for context, and the route the row navigates to.
///
/// Instances live only in ``SettingsSearchIndex/entries``; ``SettingsSheet`` renders matches as
/// navigation rows. `searchableTokens` is precomputed at construction so per-keystroke matching
/// never re-normalizes the catalog.
///
/// **Token/display fork.** `title` and `breadcrumb` used to be the localization wall's forbidden
/// one-string-two-jobs shape: tokens AND the text drawn on the result row. The split is:
/// - `title`, `keywords` and `breadcrumb` are TOKENS. Frozen English forever — `title` and
///   `keywords` feed ``SettingsSearchIndex/tokens(in:)``, and `title` and `breadcrumb` make up `id`
///   (the `ForEach` identity). A translated token would stop matching the queries the catalog was
///   written for and would re-identify every row on a language change.
/// - ``displayTitle`` and ``displayBreadcrumb`` are DISPLAY. The only things a person reads, and the
///   only halves that localize.
///
/// The display halves are explicit semantic keys rather than `LocalizedStringKey(title)`. Keying the
/// row on the token itself (the first cut of this fork) had two silent failures: the build-time
/// extractor cannot see a key formed from a variable, so 25 of the 79 titles never reached the
/// catalog and rendered English in every language; and any English rewording of a token would have
/// orphaned the translation keyed by its old spelling. So an edit to `title` is a behaviour change
/// (search + identity), never a copy change; new wording belongs in the display key's default value.
nonisolated struct SettingsSearchEntry: Identifiable {
    /// Frozen English matching token; also part of ``id``.
    let title: String
    /// Frozen English search synonyms.
    let keywords: [String]
    /// Frozen English breadcrumb token; part of ``id``.
    let breadcrumb: String
    /// The page the row navigates to.
    let route: SettingsRoute
    /// The localized label the result row renders — the display half of `title`.
    let displayTitle: LocalizedStringResource
    /// The localized context line under the label — the display half of `breadcrumb`.
    let displayBreadcrumb: LocalizedStringResource
    /// `title` + `keywords`, normalized once at construction.
    let searchableTokens: [String]
    /// Each language's ``SettingsSearchSynonyms`` for this entry, normalized once at construction;
    /// matched only while that language is an input language.
    let synonymTokens: [FernletLanguage: [String]]

    init(title: String, display: LocalizedStringResource, keywords: [String],
         breadcrumb: SettingsSearchBreadcrumb, route: SettingsRoute) {
        self.title = title
        self.keywords = keywords
        self.breadcrumb = breadcrumb.token
        self.route = route
        self.displayTitle = display
        self.displayBreadcrumb = breadcrumb.display
        self.searchableTokens = SettingsSearchIndex.tokens(in: ([title] + keywords).joined(separator: " "))
        self.synonymTokens = Dictionary(uniqueKeysWithValues: FernletLanguage.allCases.map { language in
            let synonyms = SettingsSearchSynonyms.table(for: language)[title, default: []]
            return (language, SettingsSearchIndex.tokens(in: synonyms.joined(separator: " ")))
        })
    }

    /// The tokens a query is matched against in `languages`: the frozen English ones, then each active
    /// language's synonyms.
    func matchableTokens(in languages: InputLanguages) -> [String] {
        searchableTokens + languages.languages.flatMap { synonymTokens[$0] ?? [] }
    }

    // Stable and unique across the catalog (no two entries share route + breadcrumb + title), so
    // `ForEach` keeps rows identified without a per-launch UUID that would break value equality.
    // Built from the frozen tokens, never the display halves: a row's identity must not change with
    // the user's language.
    var id: String { "\(route)|\(breadcrumb)|\(title)" }
}

/// Where a search result lives, as the row's context line says it: a frozen English `token` (part
/// of ``SettingsSearchEntry/id``) and the localized `display` the row draws.
///
/// One named constant per path (`SettingsSearchBreadcrumb.appearanceBackgrounds`, …) so the 42
/// distinct paths are each spelled once — token and key side by side — rather than repeated across
/// the 79 entries that share them.
nonisolated struct SettingsSearchBreadcrumb: Sendable {
    /// Frozen English path, e.g. "Appearance › Backgrounds". Identity only; never drawn.
    let token: String
    /// The drawn path, an explicit `settings.search.breadcrumb.*` catalog key.
    let display: LocalizedStringResource
}

/// Namespace holding the hand-written settings search catalog and its matching/normalization logic.
///
/// ``SettingsSheet`` calls ``results(for:)`` whenever the search field is non-empty and renders one
/// navigation row per match. The catalog is leaf-granular — one ``SettingsSearchEntry`` per
/// meaningful control, including the Privacy & Data sub-page's cards — and ordered to mirror the hub
/// top-to-bottom so results read in the same order the settings appear. Matching mirrors
/// `FernletDomainModel.FoodItemSearch`'s token style (diacritic/case-insensitive, prefix-AND) but is
/// deliberately self-contained, with no food-catalog import. `SettingsSearchIndexTests` asserts
/// every ``SettingsRoute`` case has at least one entry.
nonisolated enum SettingsSearchIndex {
    /// Prefix-AND match over `title + keywords` and, for each active language, the entry's
    /// ``SettingsSearchSynonyms``: an entry is returned iff every query token is a prefix of (or equal
    /// to) some matchable token. Empty/whitespace queries return nothing (the caller keeps showing the
    /// Form). Catalog order is preserved so results are stable.
    ///
    /// - Parameter languages: The input languages (English plus the app's language by default), so a
    ///   Spanish interface finds "Modo oscuro" and an English one reads exactly what it always did.
    static func results(for query: String, languages: InputLanguages = .current) -> [SettingsSearchEntry] {
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }
        return entries.filter { entry in
            // The hub's Debug row compiles out of release builds; search must not be the back door
            // that puts the development page in a shipping user's hands anyway. Since the 2026-08-21
            // hub restructure (SETT-28) the Connection log pages ride the same DEBUG-only "Advanced"
            // section, so their entries are withheld from release search too.
            #if !DEBUG
            if entry.route == .debug || entry.route == .connectionInspector || entry.route == .connectionHistory {
                return false
            }
            #endif
            let tokens = entry.matchableTokens(in: languages)
            return queryTokens.allSatisfy { queryToken in
                tokens.contains { $0 == queryToken || $0.hasPrefix(queryToken) }
            }
        }
    }

    /// Diacritic/case-insensitive fold, non-alphanumerics collapsed to single spaces. Mirrors
    /// `FoodItemSearch.normalized` without importing it (kept self-contained by design) — including
    /// its load-bearing `locale: nil`. The catalog's frozen English tokens and the typed query both
    /// fold through here, but locale-sensitive case rules break their agreement across case
    /// variants: Turkish case-folds "I" to dotless "ı", so `.current` indexed "Face ID" as
    /// "face ıd" while a typed "id" stayed "id" — the query silently missed. `FoodItemSearch`'s
    /// doc comment carries the full record of the same bug.
    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(in text: String) -> [String] {
        normalized(text).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Catalog

    // Ordered by route (hub top-to-bottom, then the Privacy & Data cards) so results read in the same
    // order the settings themselves appear. Synonyms cover the phrasings a user actually types.
    static let entries: [SettingsSearchEntry] = [
        // Appearance
        SettingsSearchEntry(
            title: "Dark mode",
            display: LocalizedStringResource(
                "settings.search.title.darkMode", defaultValue: "Dark mode",
                comment: "Settings search result: the name of a setting a search can find, on the Appearance page. Short, sentence case, like the row it leads to."),
            keywords: ["dark mode", "night mode", "theme", "light mode", "appearance", "display"],
            breadcrumb: .appearance,
            route: .appearance
        ),
        SettingsSearchEntry(
            title: "Light mode background",
            display: LocalizedStringResource(
                "settings.search.title.lightModeBackground", defaultValue: "Light mode background",
                comment: "Settings search result: the name of a setting a search can find, on the Appearance › Backgrounds page. Short, sentence case, like the row it leads to."),
            keywords: ["background", "color", "colour", "light background", "custom color", "theme color", "hex", "parchment"],
            breadcrumb: .appearanceBackgrounds,
            route: .appearance
        ),
        SettingsSearchEntry(
            title: "Dark mode background",
            display: LocalizedStringResource(
                "settings.search.title.darkModeBackground", defaultValue: "Dark mode background",
                comment: "Settings search result: the name of a setting a search can find, on the Appearance › Backgrounds page. Short, sentence case, like the row it leads to."),
            keywords: ["background", "color", "colour", "dark background", "custom color", "theme color", "hex"],
            breadcrumb: .appearanceBackgrounds,
            route: .appearance
        ),
        // The companion's feelings (2026-09-24): the hunger and thirst cues switch and the bedtime window.
        SettingsSearchEntry(
            title: "Companion feelings",
            display: LocalizedStringResource(
                "settings.search.title.companionFeelings", defaultValue: "Companion feelings",
                comment: "Settings search result: the name of a setting a search can find, on the Appearance › Companion feelings page. Short, sentence case, like the row it leads to."),
            keywords: ["companion", "feelings", "emotions", "mood", "hungry", "hunger", "thirsty", "thirst",
                       "appetite", "cues", "sleepy", "bedtime", "wake up", "tamagotchi"],
            breadcrumb: .appearanceCompanionFeelings,
            route: .appearance
        ),
        // Home-widget layout moved onto the Appearance page in the 2026-08-21 hub restructure
        // (SETT-14): the old Layout & shortcuts page became the Quick-log shortcuts editor (5g).
        SettingsSearchEntry(
            title: "Home widgets",
            display: LocalizedStringResource(
                "settings.search.title.homeWidgets", defaultValue: "Home widgets",
                comment: "Settings search result: the name of a setting a search can find, on the Appearance › Home widgets page. Short, sentence case, like the row it leads to."),
            keywords: ["home widgets", "widgets", "home screen", "layout", "main page", "rearrange", "order"],
            breadcrumb: .appearanceHomeWidgets,
            route: .appearance
        ),

        // Goal & nutrition
        SettingsSearchEntry(
            title: "Goal",
            display: LocalizedStringResource(
                "settings.search.title.goal", defaultValue: "Goal",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition page. Short, sentence case, like the row it leads to."),
            keywords: ["goal", "preset", "weight loss", "lose weight", "maintain", "gain", "build muscle", "muscle", "sports", "training", "nutrition plan"],
            breadcrumb: .goalNutrition,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Sick mode",
            display: LocalizedStringResource(
                "settings.search.title.sickMode", defaultValue: "Sick mode",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition page. Short, sentence case, like the row it leads to."),
            keywords: ["sick", "illness", "unwell", "sick mode", "rest", "recovery"],
            breadcrumb: .goalNutrition,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Show calories",
            display: LocalizedStringResource(
                "settings.search.title.showCalories", defaultValue: "Show calories",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition page. Short, sentence case, like the row it leads to."),
            keywords: ["calories", "show calories", "kcal", "calorie", "numbers"],
            breadcrumb: .goalNutrition,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Body & measurements",
            display: LocalizedStringResource(
                "settings.search.title.bodyMeasurements", defaultValue: "Body & measurements",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Body & preferences page. Short, sentence case, like the row it leads to."),
            keywords: ["body", "height", "weight", "age", "sex", "profile", "measurements"],
            breadcrumb: .goalNutritionBodyPreferences,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Dietary preferences",
            display: LocalizedStringResource(
                "settings.search.title.dietaryPreferences", defaultValue: "Dietary preferences",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Body & preferences page. Short, sentence case, like the row it leads to."),
            keywords: ["dietary", "preferences", "allergies", "vegetarian", "vegan", "diet", "restrictions"],
            breadcrumb: .goalNutritionBodyPreferences,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Nutrition targets",
            display: LocalizedStringResource(
                "settings.search.title.nutritionTargets", defaultValue: "Nutrition targets",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Nutrition targets page. Short, sentence case, like the row it leads to."),
            keywords: ["nutrition targets", "macros", "macro", "protein", "carbs", "carbohydrates", "fat", "fiber", "calorie target", "custom targets"],
            breadcrumb: .goalNutritionNutritionTargets,
            route: .goalNutrition
        ),
        // The Weight Management deficit stepper on the Nutrition targets card (2026-09-24).
        SettingsSearchEntry(
            title: "Calorie deficit",
            display: LocalizedStringResource(
                "settings.search.title.calorieDeficit", defaultValue: "Calorie deficit",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Nutrition targets page. Short, sentence case, like the row it leads to."),
            keywords: ["deficit", "calorie deficit", "weight management", "lose weight", "cut", "percent", "maintenance"],
            breadcrumb: .goalNutritionNutritionTargets,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Daily check-in reminder",
            display: LocalizedStringResource(
                "settings.search.title.dailyCheckInReminder", defaultValue: "Daily check-in reminder",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Reminders page. Short, sentence case, like the row it leads to."),
            keywords: ["reminder", "daily check-in", "check in", "nudge", "alert", "notify"],
            breadcrumb: .goalNutritionReminders,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Notifications",
            display: LocalizedStringResource(
                "settings.search.title.notifications", defaultValue: "Notifications",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Reminders page. Short, sentence case, like the row it leads to."),
            keywords: ["notifications", "notification", "alerts", "reminders", "push notifications"],
            breadcrumb: .goalNutritionReminders,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Reminder time",
            display: LocalizedStringResource(
                "settings.search.title.reminderTime", defaultValue: "Reminder time",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Reminders page. Short, sentence case, like the row it leads to."),
            keywords: ["reminder time", "time", "when", "schedule", "notification time"],
            breadcrumb: .goalNutritionReminders,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Water bottle size",
            display: LocalizedStringResource(
                "settings.search.title.waterBottleSize", defaultValue: "Water bottle size",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Hydration page. Short, sentence case, like the row it leads to."),
            keywords: ["water", "hydration", "bottle", "ounces", "oz", "drink", "bottle size"],
            breadcrumb: .goalNutritionHydration,
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Daily water target",
            display: LocalizedStringResource(
                "settings.search.title.dailyWaterTarget", defaultValue: "Daily water target",
                comment: "Settings search result: the name of a setting a search can find, on the Goal & nutrition › Hydration page. Short, sentence case, like the row it leads to."),
            keywords: ["water", "hydration", "target", "bottles", "daily target", "drink", "goal"],
            breadcrumb: .goalNutritionHydration,
            route: .goalNutrition
        ),
        // Personal care tasks (its own hub row under "Your day" since 2026-08-21, SETT-14)
        SettingsSearchEntry(
            title: "Personal care tasks",
            display: LocalizedStringResource(
                "settings.search.title.personalCareTasks", defaultValue: "Personal care tasks",
                comment: "Settings search result: the name of a setting a search can find, on the Personal care tasks page. Short, sentence case, like the row it leads to."),
            keywords: ["personal care", "tasks", "moisturizer", "meds", "medication", "stretch", "hygiene", "care task", "habit", "routine"],
            breadcrumb: .personalCareTasks,
            route: .personalCare
        ),

        // Quick-log shortcuts (the old Layout & shortcuts page, rebuilt as the 5g editor)
        SettingsSearchEntry(
            title: "Quick log shortcuts",
            display: LocalizedStringResource(
                "settings.search.title.quickLogShortcuts", defaultValue: "Quick log shortcuts",
                comment: "Settings search result: the name of a setting a search can find, on the Quick-log shortcuts page. Short, sentence case, like the row it leads to."),
            keywords: ["quick log", "shortcuts", "quick actions", "home shortcuts", "buttons", "log shortcuts"],
            breadcrumb: .quickLogShortcuts,
            route: .layoutShortcuts
        ),

        // Sounds & haptics (2026-10-20, the app-wide haptics pass): the Haptics level plus the
        // workout and breathing switches it shows, bound to their own keys.
        SettingsSearchEntry(
            title: "Sounds & haptics",
            display: LocalizedStringResource(
                "settings.search.title.soundsHaptics", defaultValue: "Sounds & haptics",
                comment: "Settings search result: the name of a setting a search can find, on the Sounds & haptics page. Short, sentence case, like the row it leads to."),
            keywords: ["sounds", "sound", "haptics", "haptic", "vibration", "vibrate", "buzz", "taps", "feedback"],
            breadcrumb: .soundsHaptics,
            route: .soundsHaptics
        ),
        SettingsSearchEntry(
            title: "Haptics",
            display: LocalizedStringResource(
                "settings.search.title.haptics", defaultValue: "Haptics",
                comment: "Settings search result: the name of a setting a search can find, on the Sounds & haptics page. Short, sentence case, like the row it leads to."),
            keywords: ["haptics", "vibration", "vibrate", "buzz", "taps", "fewer"],
            breadcrumb: .soundsHaptics,
            route: .soundsHaptics
        ),
        SettingsSearchEntry(
            title: "Workout haptics",
            display: LocalizedStringResource(
                "settings.search.title.workoutHaptics", defaultValue: "Workout haptics",
                comment: "Settings search result: the name of a setting a search can find, on the Sounds & haptics › During a workout page. Short, sentence case, like the row it leads to."),
            keywords: ["workout haptics", "rest timer", "vibration", "haptics", "taps"],
            breadcrumb: .soundsHapticsDuringAWorkout,
            route: .soundsHaptics
        ),
        SettingsSearchEntry(
            title: "Workout sounds",
            display: LocalizedStringResource(
                "settings.search.title.workoutSounds", defaultValue: "Workout sounds",
                comment: "Settings search result: the name of a setting a search can find, on the Sounds & haptics › During a workout page. Short, sentence case, like the row it leads to."),
            keywords: ["workout sounds", "sound", "sounds", "chime", "audio", "rest timer"],
            breadcrumb: .soundsHapticsDuringAWorkout,
            route: .soundsHaptics
        ),
        SettingsSearchEntry(
            title: "Spoken cues",
            display: LocalizedStringResource(
                "settings.search.title.spokenCues", defaultValue: "Spoken cues",
                comment: "Settings search result: the name of a setting a search can find, on the Sounds & haptics › During a workout page. Short, sentence case, like the row it leads to."),
            keywords: ["spoken cues", "voice", "speak", "speech", "talk", "read aloud", "say"],
            breadcrumb: .soundsHapticsDuringAWorkout,
            route: .soundsHaptics
        ),
        SettingsSearchEntry(
            title: "Cooking timer sound",
            display: LocalizedStringResource(
                "settings.search.title.cookingTimerSound", defaultValue: "Cooking timer sound",
                comment: "Settings search result: the name of a setting a search can find, on the Sounds & haptics › Cooking page. Short, sentence case, like the row it leads to."),
            keywords: ["cooking timer sound", "cooking", "cook", "kitchen timer", "timer sound", "chime", "sound"],
            breadcrumb: .soundsHapticsCooking,
            route: .soundsHaptics
        ),
        SettingsSearchEntry(
            title: "Breathing haptics",
            display: LocalizedStringResource(
                "settings.search.title.breathingHaptics", defaultValue: "Breathing haptics",
                comment: "Settings search result: the name of a setting a search can find, on the Sounds & haptics › Breathing page. Short, sentence case, like the row it leads to."),
            keywords: ["breathing haptics", "breathing", "pacer", "vibration", "haptics", "taps"],
            breadcrumb: .soundsHapticsBreathing,
            route: .soundsHaptics
        ),

        // Home map (World build step 5c, `b1-settings-map`): location, the fog, routes and places.
        SettingsSearchEntry(
            title: "Home map",
            display: LocalizedStringResource(
                "settings.search.title.homeMap", defaultValue: "Home map",
                comment: "Settings search result: the name of a setting a search can find, on the Home map page. Short, sentence case, like the row it leads to."),
            keywords: ["map", "home map", "location", "gps", "places", "pins", "where you've been"],
            breadcrumb: .homeMap,
            route: .homeMap
        ),
        SettingsSearchEntry(
            title: "Map the world in the background",
            display: LocalizedStringResource(
                "settings.search.title.backgroundMapping", defaultValue: "Map the world in the background",
                comment: "Settings search result: the name of a setting a search can find, on the Home map page. Short, sentence case, like the row it leads to."),
            keywords: ["background mapping", "always location", "low power", "visits"],
            breadcrumb: .homeMap,
            route: .homeMap
        ),
        SettingsSearchEntry(
            title: "Uncover the map as you go",
            display: LocalizedStringResource(
                "settings.search.title.uncoverMap", defaultValue: "Uncover the map as you go",
                comment: "Settings search result: the name of a setting a search can find, on the Home map page. Short, sentence case, like the row it leads to."),
            keywords: ["fog", "uncover", "explore"],
            breadcrumb: .homeMap,
            route: .homeMap
        ),
        SettingsSearchEntry(
            title: "Save new routes",
            display: LocalizedStringResource(
                "settings.search.title.saveRoutes", defaultValue: "Save new routes",
                comment: "Settings search result: the name of a setting a search can find, on the Home map page. Short, sentence case, like the row it leads to."),
            keywords: ["routes", "route", "walk lines", "run lines", "trails", "delete routes"],
            breadcrumb: .homeMap,
            route: .homeMap
        ),
        SettingsSearchEntry(
            title: "Remember places I stop at",
            display: LocalizedStringResource(
                "settings.search.title.rememberPlaces", defaultValue: "Remember places I stop at",
                comment: "Settings search result: the name of a setting a search can find, on the Home map page. Short, sentence case, like the row it leads to."),
            keywords: ["places", "visits", "where you've been", "stop collecting places", "timeline"],
            breadcrumb: .homeMap,
            route: .homeMap
        ),
        SettingsSearchEntry(
            title: "Delete map history",
            display: LocalizedStringResource(
                "settings.search.title.deleteMapHistory", defaultValue: "Delete map history",
                comment: "Settings search result: the name of a setting a search can find, on the Home map page. Short, sentence case, like the row it leads to."),
            keywords: ["map history", "forget workout spaces", "clear map"],
            breadcrumb: .homeMap,
            route: .homeMap
        ),

        // AI & data sources (the grouping page that took the AI/web/weather/body-signal switches
        // out from under the nutrition heading, SETT-14)
        SettingsSearchEntry(
            title: "AI status",
            display: LocalizedStringResource(
                "settings.search.title.aiStatus", defaultValue: "AI status",
                comment: "Settings search result: the name of a setting a search can find, on the AI & data sources page. Short, sentence case, like the row it leads to."),
            keywords: ["ai", "artificial intelligence", "on device", "assistant", "status"],
            breadcrumb: .aiDataSources,
            route: .aiDataSources
        ),
        SettingsSearchEntry(
            title: "Turn AI off",
            display: LocalizedStringResource(
                "settings.search.title.turnAIOff", defaultValue: "Turn AI off",
                comment: "Settings search result: the name of a setting a search can find, on the AI & data sources page. Short, sentence case, like the row it leads to."),
            keywords: ["ai off", "turn off ai", "disable ai", "manual off", "manual off mode"],
            breadcrumb: .aiDataSources,
            route: .aiDataSources
        ),
        SettingsSearchEntry(
            title: "Web nutrition lookup",
            display: LocalizedStringResource(
                "settings.search.title.webNutritionLookup", defaultValue: "Web nutrition lookup",
                comment: "Settings search result: the name of a setting a search can find, on the AI & data sources page. Short, sentence case, like the row it leads to."),
            keywords: ["web nutrition", "web lookup", "internet", "online", "search provider", "packaged food", "chain food", "web", "barcode", "open food facts", "upc"],
            breadcrumb: .aiDataSources,
            route: .aiDataSources
        ),
        SettingsSearchEntry(
            title: "Weather-aware recovery prompts",
            display: LocalizedStringResource(
                "settings.search.title.weatherAwareRecoveryPrompts", defaultValue: "Weather-aware recovery prompts",
                comment: "Settings search result: the name of a setting a search can find, on the AI & data sources page. Short, sentence case, like the row it leads to."),
            keywords: ["weather", "recovery", "gloomy", "rain", "location", "prompts"],
            breadcrumb: .aiDataSources,
            route: .aiDataSources
        ),
        SettingsSearchEntry(
            title: "Notice body tension",
            display: LocalizedStringResource(
                "settings.search.title.noticeBodyTension", defaultValue: "Notice body tension",
                comment: "Settings search result: the name of a setting a search can find, on the AI & data sources › Body signals page. Short, sentence case, like the row it leads to."),
            keywords: ["stress", "body tension", "tension", "hrv", "heart rate variability", "resting heart rate", "respiration", "body signals", "anxiety"],
            breadcrumb: .aiDataSourcesBodySignals,
            route: .aiDataSources
        ),

        // Health
        SettingsSearchEntry(
            title: "Health access",
            display: LocalizedStringResource(
                "settings.search.title.healthAccess", defaultValue: "Health access",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["health", "healthkit", "apple health", "permissions", "access", "integration"],
            breadcrumb: .health,
            route: .health
        ),
        SettingsSearchEntry(
            title: "Cycle & period access",
            display: LocalizedStringResource(
                "settings.search.title.cyclePeriodAccess", defaultValue: "Cycle & period access",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["cycle", "period", "menstrual", "menstruation", "cycle tracking", "health"],
            breadcrumb: .health,
            route: .health
        ),
        SettingsSearchEntry(
            title: "Intimate logging access",
            display: LocalizedStringResource(
                "settings.search.title.intimateLoggingAccess", defaultValue: "Intimate logging access",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["intimate", "intimacy", "sexual", "private", "health", "age", "16"],
            breadcrumb: .health,
            route: .health
        ),
        SettingsSearchEntry(
            title: "Activity & steps access",
            display: LocalizedStringResource(
                "settings.search.title.activityStepsAccess", defaultValue: "Activity & steps access",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["activity", "steps", "move", "walking", "health"],
            breadcrumb: .health,
            route: .health
        ),
        SettingsSearchEntry(
            title: "Workout access",
            display: LocalizedStringResource(
                "settings.search.title.workoutAccess", defaultValue: "Workout access",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["workout", "exercise", "fitness", "training", "health"],
            breadcrumb: .health,
            route: .health
        ),
        SettingsSearchEntry(
            title: "Mindfulness access",
            display: LocalizedStringResource(
                "settings.search.title.mindfulnessAccess", defaultValue: "Mindfulness access",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["mindfulness", "meditation", "breathing", "mindful", "health"],
            breadcrumb: .health,
            route: .health
        ),
        SettingsSearchEntry(
            title: "Body vitals access",
            display: LocalizedStringResource(
                "settings.search.title.bodyVitalsAccess", defaultValue: "Body vitals access",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["body context", "vitals", "heart rate", "respiration", "temperature", "health"],
            breadcrumb: .health,
            route: .health
        ),
        // The master switch and its jump into the Health app moved onto the one Health surface
        // (SETT-27); the frozen titles stay so saved queries keep resolving.
        SettingsSearchEntry(
            title: "Health integration",
            display: LocalizedStringResource(
                "settings.search.title.healthIntegration", defaultValue: "Health integration",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["health", "healthkit", "apple health", "health integration", "permissions"],
            breadcrumb: .health,
            route: .health
        ),
        SettingsSearchEntry(
            title: "Open Health Privacy Settings",
            display: LocalizedStringResource(
                "settings.search.title.openHealthPrivacySettings", defaultValue: "Open Health Privacy Settings",
                comment: "Settings search result: the name of a setting a search can find, on the Health page. Short, sentence case, like the row it leads to."),
            keywords: ["health privacy", "ios settings", "revoke health", "health permissions"],
            breadcrumb: .health,
            route: .health
        ),

        // Core memory (reached through AI & data sources since 2026-08-21)
        SettingsSearchEntry(
            title: "Core memory",
            display: LocalizedStringResource(
                "settings.search.title.coreMemory", defaultValue: "Core memory",
                comment: "Settings search result: the name of a setting a search can find, on the AI & data sources › Core memory page. Short, sentence case, like the row it leads to."),
            keywords: ["memory", "memories", "core memory", "remember", "notes", "journal memory"],
            breadcrumb: .aiDataSourcesCoreMemory,
            route: .coreMemory
        ),
        SettingsSearchEntry(
            title: "Forget a memory",
            display: LocalizedStringResource(
                "settings.search.title.forgetAMemory", defaultValue: "Forget a memory",
                comment: "Settings search result: the name of a setting a search can find, on the AI & data sources › Core memory page. Short, sentence case, like the row it leads to."),
            keywords: ["forget", "delete memory", "remove memory", "erase memory"],
            breadcrumb: .aiDataSourcesCoreMemory,
            route: .coreMemory
        ),

        // Signals (reached through AI & data sources since 2026-08-21)
        SettingsSearchEntry(
            title: "Signals",
            display: LocalizedStringResource(
                "settings.search.title.signals", defaultValue: "Signals",
                comment: "Settings search result: the name of a setting a search can find, on the AI & data sources › Signals page. Short, sentence case, like the row it leads to."),
            keywords: ["signals", "trends", "derived signals", "insights", "patterns"],
            breadcrumb: .aiDataSourcesSignals,
            route: .signals
        ),

        // Debug
        SettingsSearchEntry(
            title: "Proximity debug tools",
            display: LocalizedStringResource(
                "settings.search.title.proximityDebugTools", defaultValue: "Proximity debug tools",
                comment: "Settings search result: the name of a setting a search can find, on the Debug page. Short, sentence case, like the row it leads to."),
            keywords: ["debug", "proximity debug", "developer", "diagnostics", "force override", "tools"],
            breadcrumb: .debug,
            route: .debug
        ),
        SettingsSearchEntry(
            title: "Tier 2 memory",
            display: LocalizedStringResource(
                "settings.search.title.tier2Memory", defaultValue: "Tier 2 memory",
                comment: "Settings search result: the name of a setting a search can find, on the Debug › Tier 2 memory page. Short, sentence case, like the row it leads to."),
            keywords: ["tier 2", "tier two", "memory", "inferred", "debug"],
            breadcrumb: .debugTier2Memory,
            route: .debug
        ),
        SettingsSearchEntry(
            title: "Derived signals",
            display: LocalizedStringResource(
                "settings.search.title.derivedSignals", defaultValue: "Derived signals",
                comment: "Settings search result: the name of a setting a search can find, on the Debug › Derived signals page. Short, sentence case, like the row it leads to."),
            keywords: ["derived signals", "signals", "debug", "trends"],
            breadcrumb: .debugDerivedSignals,
            route: .debug
        ),

        // Connection log (the folded Debug + Connection Inspector row, DEBUG-only — SETT-28;
        // `results(for:)` withholds these routes from release search)
        SettingsSearchEntry(
            title: "Connection Inspector",
            display: LocalizedStringResource(
                "settings.search.title.connectionInspector", defaultValue: "Connection Inspector",
                comment: "Settings search result: the name of a setting a search can find, on the Connection log page. Short, sentence case, like the row it leads to."),
            keywords: ["connection inspector", "proximity", "pairing", "diagnostics", "mesh", "nearby", "inspector"],
            breadcrumb: .connectionLog,
            route: .connectionInspector
        ),
        SettingsSearchEntry(
            title: "Connection History",
            display: LocalizedStringResource(
                "settings.search.title.connectionHistory", defaultValue: "Connection History",
                comment: "Settings search result: the name of a setting a search can find, on the Connection log › History page. Short, sentence case, like the row it leads to."),
            keywords: ["connection history", "history", "past connections", "sessions", "log", "connections"],
            breadcrumb: .connectionLogHistory,
            route: .connectionHistory
        ),

        // Privacy & Data
        SettingsSearchEntry(
            title: "Sync to iCloud",
            display: LocalizedStringResource(
                "settings.search.title.syncToICloud", defaultValue: "Sync to iCloud",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › iCloud page. Short, sentence case, like the row it leads to."),
            keywords: ["icloud", "sync", "cloud", "sync to icloud", "cross device", "backup"],
            breadcrumb: .privacyDataICloud,
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Delete iCloud data",
            display: LocalizedStringResource(
                "settings.search.title.deleteICloudData", defaultValue: "Delete iCloud data",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › iCloud page. Short, sentence case, like the row it leads to."),
            keywords: ["delete icloud", "delete cloud data", "remove icloud", "wipe cloud", "icloud"],
            breadcrumb: .privacyDataICloud,
            route: .privacyData
        ),
        // Takes over the generic "encrypted backup" synonyms from the retired sensitive-notes entry
        // (removed 2026-09-23 with its switch), so those searches still land on a live backup switch.
        SettingsSearchEntry(
            title: "Sealed backup for journal entries",
            display: LocalizedStringResource(
                "settings.search.title.sealedBackupForJournalEntries", defaultValue: "Sealed backup for journal entries",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › iCloud page. Short, sentence case, like the row it leads to."),
            keywords: ["sealed backup", "encrypted backup", "backup", "journal backup", "encryption", "encrypted"],
            breadcrumb: .privacyDataICloud,
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Sealed backup for period data",
            display: LocalizedStringResource(
                "settings.search.title.sealedBackupForPeriodData", defaultValue: "Sealed backup for period data",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › iCloud page. Short, sentence case, like the row it leads to."),
            keywords: ["sealed backup", "period backup", "encrypted period", "cycle backup", "period", "backup"],
            breadcrumb: .privacyDataICloud,
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Multiple devices",
            display: LocalizedStringResource(
                "settings.search.title.multipleDevices", defaultValue: "Multiple devices",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › Multiple devices page. Short, sentence case, like the row it leads to."),
            keywords: ["multiple devices", "two devices", "sync warning", "devices", "multi device"],
            breadcrumb: .privacyDataMultipleDevices,
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Encrypted backup status",
            display: LocalizedStringResource(
                "settings.search.title.encryptedBackupStatus", defaultValue: "Encrypted backup status",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › Encrypted backup status page. Short, sentence case, like the row it leads to."),
            keywords: ["backup status", "restore", "escrow", "sealed backup status", "recover"],
            breadcrumb: .privacyDataEncryptedBackupStatus,
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Include local data in iOS backup",
            display: LocalizedStringResource(
                "settings.search.title.includeLocalDataInIOSBackup", defaultValue: "Include local data in iOS backup",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › Local backup page. Short, sentence case, like the row it leads to."),
            keywords: ["local backup", "ios backup", "device backup", "icloud backup", "exclude backup", "backup"],
            breadcrumb: .privacyDataLocalBackup,
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Export my data",
            display: LocalizedStringResource(
                "settings.search.title.exportMyData", defaultValue: "Export my data",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › Your data page. Short, sentence case, like the row it leads to."),
            keywords: ["export", "export data", "download data", "json", "my data", "data export", "download"],
            breadcrumb: .privacyDataYourData,
            route: .privacyData
        ),
        // Sharing settings
        SettingsSearchEntry(
            title: "Share with a trainer",
            display: LocalizedStringResource(
                "settings.search.title.shareWithATrainer", defaultValue: "Share with a trainer",
                comment: "Settings search result: the name of a setting a search can find, on the Sharing settings page. Short, sentence case, like the row it leads to."),
            keywords: ["trainer", "coach", "share", "nutritionist", "trainer summary"],
            breadcrumb: .sharingSettings,
            route: .sharing
        ),
        SettingsSearchEntry(
            title: "Manual plan exchange",
            display: LocalizedStringResource(
                "settings.search.title.manualPlanExchange", defaultValue: "Manual plan exchange",
                comment: "Settings search result: the name of a setting a search can find, on the Sharing settings page. Short, sentence case, like the row it leads to."),
            keywords: ["copy prompt", "paste plan", "ai plan", "coach exchange", "manual exchange"],
            breadcrumb: .sharingSettings,
            route: .sharing
        ),
        SettingsSearchEntry(
            title: "Also include in trainer summaries",
            display: LocalizedStringResource(
                "settings.search.title.alsoIncludeInTrainerSummaries", defaultValue: "Also include in trainer summaries",
                comment: "Settings search result: the name of a setting a search can find, on the Sharing settings page. Short, sentence case, like the row it leads to."),
            keywords: ["summary contents", "goal", "sleep", "sickness", "wellbeing", "trainer options"],
            breadcrumb: .sharingSettings,
            route: .sharing
        ),
        // The recipe-sharing switches (notes, picture) moved from each share to Settings › Sharing
        // (owner decision, world-ui; the card is "Recipes you share").
        SettingsSearchEntry(
            title: "Recipes you share",
            display: LocalizedStringResource(
                "settings.search.title.recipesYouShare", defaultValue: "Recipes you share",
                comment: "Settings search result: the name of a setting a search can find, on the Sharing settings page (whether shared recipes carry your notes and their picture). Short, sentence case, like the row it leads to."),
            keywords: ["include notes", "include picture", "recipe notes", "recipe photo", "recipe picture",
                       "recipe sharing", "shared recipes"],
            breadcrumb: .sharingSettings,
            route: .sharing
        ),
        SettingsSearchEntry(
            title: "Delete everything",
            display: LocalizedStringResource(
                "settings.search.title.deleteEverything", defaultValue: "Delete everything",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy & Data › App lock data page. Short, sentence case, like the row it leads to."),
            keywords: ["delete everything", "delete all", "erase", "wipe", "reset", "remove all data", "delete", "reset everything"],
            breadcrumb: .privacyDataAppLockData,
            route: .privacyData
        ),

        // AI activity log
        SettingsSearchEntry(
            title: "AI activity log",
            display: LocalizedStringResource(
                "settings.search.title.aiActivityLog", defaultValue: "AI activity log",
                comment: "Settings search result: the name of a setting a search can find, on the AI activity log page. Short, sentence case, like the row it leads to."),
            keywords: ["ai activity", "ai log", "ai calls", "ai history", "audit", "ai audit",
                       "what left my device", "left my device", "on device model", "sent"],
            breadcrumb: .aiActivityLog,
            route: .aiAuditLog
        ),

        // Privacy Policy
        SettingsSearchEntry(
            title: "Privacy Policy",
            display: LocalizedStringResource(
                "settings.search.title.privacyPolicy", defaultValue: "Privacy Policy",
                comment: "Settings search result: the name of a setting a search can find, on the Privacy Policy page. Short, sentence case, like the row it leads to."),
            keywords: ["privacy policy", "policy", "terms", "legal", "data policy", "privacy"],
            breadcrumb: .privacyPolicy,
            route: .privacyPolicy
        ),

        // Safety & reporting — it opens on the crisis-line card (`CrisisSupportCard`), so the words a
        // person in distress might type land on a page that carries the line.
        SettingsSearchEntry(
            title: "Safety & reporting",
            display: LocalizedStringResource(
                "settings.search.title.safetyReporting", defaultValue: "Safety & reporting",
                comment: "Settings search result: the name of a setting a search can find, on the Safety & reporting page. Short, sentence case, like the row it leads to."),
            keywords: ["safety", "reporting", "report", "block", "abuse", "crisis", "help", "blocked",
                       "988", "suicide", "hotline", "first aid"],
            breadcrumb: .safetyReporting,
            route: .safetyReporting
        ),

        // App lock
        SettingsSearchEntry(
            title: "App lock",
            display: LocalizedStringResource(
                "settings.search.title.appLock", defaultValue: "App lock",
                comment: "Settings search result: the name of a setting a search can find, on the App lock page. Short, sentence case, like the row it leads to."),
            keywords: ["app lock", "lock", "passcode", "pin", "password", "security", "unlock", "protect"],
            breadcrumb: .appLock,
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Set up app lock",
            display: LocalizedStringResource(
                "settings.search.title.setUpAppLock", defaultValue: "Set up app lock",
                comment: "Settings search result: the name of a setting a search can find, on the App lock › Setup page. Short, sentence case, like the row it leads to."),
            keywords: ["set up", "setup", "create passcode", "new passcode", "enable lock"],
            breadcrumb: .appLockSetup,
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Passcode type",
            display: LocalizedStringResource(
                "settings.search.title.passcodeType", defaultValue: "Passcode type",
                comment: "Settings search result: the name of a setting a search can find, on the App lock › Setup page. Short, sentence case, like the row it leads to."),
            keywords: ["pin", "4 digit", "6 digit", "password", "passcode type", "alphanumeric"],
            breadcrumb: .appLockSetup,
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Change passcode",
            display: LocalizedStringResource(
                "settings.search.title.changePasscode", defaultValue: "Change passcode",
                comment: "Settings search result: the name of a setting a search can find, on the App lock › Manage page. Short, sentence case, like the row it leads to."),
            keywords: ["change passcode", "change pin", "change password", "new passcode"],
            breadcrumb: .appLockManage,
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Lock now",
            display: LocalizedStringResource(
                "settings.search.title.lockNow", defaultValue: "Lock now",
                comment: "Settings search result: the name of a setting a search can find, on the App lock › Manage page. Short, sentence case, like the row it leads to."),
            keywords: ["lock now", "lock", "lock app"],
            breadcrumb: .appLockManage,
            route: .appLock
        ),
        // Period-data design 2026-09-30, §9.19: the passcode is optional, so turning it off is a
        // named action of its own (the key moves back to device custody; nothing is deleted).
        SettingsSearchEntry(
            title: "Turn off passcode",
            display: LocalizedStringResource(
                "settings.search.title.turnOffPasscode", defaultValue: "Turn off passcode",
                comment: "Settings search result: the name of a setting a search can find, on the App lock › Manage page. Short, sentence case, like the row it leads to."),
            keywords: ["turn off passcode", "remove passcode", "disable passcode", "no passcode", "open with a tap"],
            breadcrumb: .appLockManage,
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Face ID / Touch ID",
            display: LocalizedStringResource(
                "settings.search.title.faceIDTouchID", defaultValue: "Face ID / Touch ID",
                comment: "Settings search result: the name of a setting a search can find, on the App lock › Biometrics page. Short, sentence case, like the row it leads to."),
            keywords: ["face id", "touch id", "biometric", "biometrics", "fingerprint", "optic id"],
            breadcrumb: .appLockBiometrics,
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Reset app lock",
            display: LocalizedStringResource(
                "settings.search.title.resetAppLock", defaultValue: "Reset app lock",
                comment: "Settings search result: the name of a setting a search can find, on the App lock › Danger zone page. Short, sentence case, like the row it leads to."),
            keywords: ["reset app lock", "reset lock", "forgot passcode", "remove lock"],
            breadcrumb: .appLockDangerZone,
            route: .appLock
        ),

        // Nearby friends (the six in-person sharing consents left the Privacy list for their own
        // sub-page in the 2026-08-21 hub restructure, SETT-29)
        SettingsSearchEntry(
            title: "Nearby friends",
            display: LocalizedStringResource(
                "settings.search.title.nearbyFriends", defaultValue: "Nearby friends",
                comment: "Settings search result: the name of a setting a search can find, on the Nearby friends page. Short, sentence case, like the row it leads to."),
            keywords: ["nearby friends", "nearby", "friends", "presence", "proximity", "sharing"],
            breadcrumb: .nearbyFriends,
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            title: "Share your vibe",
            display: LocalizedStringResource(
                "settings.search.title.shareYourVibe", defaultValue: "Share your vibe",
                comment: "Settings search result: the name of a setting a search can find, on the Nearby friends page. Short, sentence case, like the row it leads to."),
            keywords: ["vibe", "mood", "share vibe", "friend state", "friends"],
            breadcrumb: .nearbyFriends,
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            title: "Nearby hearts",
            display: LocalizedStringResource(
                "settings.search.title.nearbyHearts", defaultValue: "Nearby hearts",
                comment: "Settings search result: the name of a setting a search can find, on the Nearby friends page. Short, sentence case, like the row it leads to."),
            keywords: ["hearts", "heart", "send heart", "nearby hearts", "friends"],
            breadcrumb: .nearbyFriends,
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            // Frozen token, deliberately NOT the setting's current name: the toggle was renamed
            // "Deliver hearts later" (artboard 5b, 2026-08-21) and the row displays that through its
            // own display key — the token itself never rewords.
            title: "Deliver hearts when apart",
            display: LocalizedStringResource(
                "settings.search.title.deliverHeartsWhenApart", defaultValue: "Deliver hearts later",
                comment: "Settings search result: the name of a setting a search can find, on the Nearby friends page. Short, sentence case, like the row it leads to."),
            keywords: ["hearts", "away", "apart", "deliver", "drop off", "later"],
            breadcrumb: .nearbyFriends,
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            title: "Nearby recipe shares",
            display: LocalizedStringResource(
                "settings.search.title.nearbyRecipeShares", defaultValue: "Nearby recipe shares",
                comment: "Settings search result: the name of a setting a search can find, on the Nearby friends page. Short, sentence case, like the row it leads to."),
            keywords: ["recipe share", "share recipes", "nearby recipes", "recipes", "friends"],
            breadcrumb: .nearbyFriends,
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            title: "Clothing shops with friends",
            display: LocalizedStringResource(
                "settings.search.title.clothingShopsWithFriends", defaultValue: "Clothing shops with friends",
                comment: "Settings search result: the name of a setting a search can find, on the Nearby friends page. Short, sentence case, like the row it leads to."),
            keywords: ["clothing", "shop", "shops", "designs", "share clothing", "friends"],
            breadcrumb: .nearbyFriends,
            route: .nearbyFriends
        ),

        // Friends & Blocks (World Review Batch 4, b4-mem-settings-friends: the page moved from the
        // Friends tab's header to Settings' Friends group, with the name you appear as on it)
        SettingsSearchEntry(
            title: "Friends & Blocks",
            display: LocalizedStringResource(
                "settings.search.title.friendsBlocks", defaultValue: "Friends & Blocks",
                comment: "Settings search result: the name of a setting a search can find, on the Friends & Blocks page. Short, like the row it leads to."),
            keywords: ["friends", "friend list", "blocks", "block", "blocked", "unblock", "remove friend", "report"],
            breadcrumb: .friendsBlocks,
            route: .friendsBlocks
        ),
        SettingsSearchEntry(
            title: "Change name",
            display: LocalizedStringResource(
                "settings.search.title.changeName", defaultValue: "Change name",
                comment: "Settings search result: the name of a setting a search can find, on the Friends & Blocks page (the name friends nearby see). Short, sentence case, like the row it leads to."),
            keywords: ["name", "display name", "you appear as", "nickname", "change name", "friends see"],
            breadcrumb: .friendsBlocks,
            route: .friendsBlocks
        ),

        // Period & sensitive content (the visibility gates as a first-class hub page, SETT-14)
        SettingsSearchEntry(
            title: "Period tracking",
            display: LocalizedStringResource(
                "settings.search.title.periodTracking", defaultValue: "Period tracking",
                comment: "Settings search result: the name of a setting a search can find, on the Period & sensitive content page. Short, sentence case, like the row it leads to."),
            keywords: ["period", "cycle", "menstrual", "visibility", "hide period", "period tracking"],
            breadcrumb: .periodSensitiveContent,
            route: .periodSensitive
        ),
        SettingsSearchEntry(
            title: "Intimacy tracking",
            display: LocalizedStringResource(
                "settings.search.title.intimacyTracking", defaultValue: "Intimacy tracking",
                comment: "Settings search result: the name of a setting a search can find, on the Period & sensitive content page. Short, sentence case, like the row it leads to."),
            keywords: ["intimacy", "intimate", "visibility", "hide intimacy", "sensitive"],
            breadcrumb: .periodSensitiveContent,
            route: .periodSensitive
        ),
        // The Advanced period tracking switch (owner decision, world-ui): every symptom, cervical mucus,
        // ovulation tests, basal temperature and spotting on Log period.
        SettingsSearchEntry(
            title: "Advanced period tracking",
            display: LocalizedStringResource(
                "settings.search.title.advancedPeriodTracking", defaultValue: "Advanced period tracking",
                comment: "Settings search result: the name of a setting a search can find, on the Period & sensitive content page. Short, sentence case, like the row it leads to."),
            keywords: ["advanced", "symptoms", "cervical mucus", "mucus", "ovulation", "ovulation test",
                       "basal temperature", "bbt", "spotting", "fertility", "period"],
            breadcrumb: .periodSensitiveContent,
            route: .periodSensitive
        ),
    ]
}

// MARK: - Breadcrumbs

// Each path once: the frozen token beside its display key, in the order the entries first use them.
nonisolated extension SettingsSearchBreadcrumb {
    static let appearance = SettingsSearchBreadcrumb(
        token: "Appearance",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appearance", defaultValue: "Appearance",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let appearanceBackgrounds = SettingsSearchBreadcrumb(
        token: "Appearance › Backgrounds",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appearanceBackgrounds", defaultValue: "Appearance › Backgrounds",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let appearanceCompanionFeelings = SettingsSearchBreadcrumb(
        token: "Appearance › Companion feelings",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appearanceCompanionFeelings", defaultValue: "Appearance › Companion feelings",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let appearanceHomeWidgets = SettingsSearchBreadcrumb(
        token: "Appearance › Home widgets",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appearanceHomeWidgets", defaultValue: "Appearance › Home widgets",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let goalNutrition = SettingsSearchBreadcrumb(
        token: "Goal & nutrition",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.goalNutrition", defaultValue: "Goal & nutrition",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let goalNutritionBodyPreferences = SettingsSearchBreadcrumb(
        token: "Goal & nutrition › Body & preferences",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.goalNutritionBodyPreferences", defaultValue: "Goal & nutrition › Body & preferences",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let goalNutritionNutritionTargets = SettingsSearchBreadcrumb(
        token: "Goal & nutrition › Nutrition targets",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.goalNutritionNutritionTargets", defaultValue: "Goal & nutrition › Nutrition targets",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let goalNutritionReminders = SettingsSearchBreadcrumb(
        token: "Goal & nutrition › Reminders",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.goalNutritionReminders", defaultValue: "Goal & nutrition › Reminders",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let goalNutritionHydration = SettingsSearchBreadcrumb(
        token: "Goal & nutrition › Hydration",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.goalNutritionHydration", defaultValue: "Goal & nutrition › Hydration",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let personalCareTasks = SettingsSearchBreadcrumb(
        token: "Personal care tasks",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.personalCareTasks", defaultValue: "Personal care tasks",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let quickLogShortcuts = SettingsSearchBreadcrumb(
        token: "Quick-log shortcuts",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.quickLogShortcuts", defaultValue: "Quick-log shortcuts",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let soundsHaptics = SettingsSearchBreadcrumb(
        token: "Sounds & haptics",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.soundsHaptics", defaultValue: "Sounds & haptics",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let soundsHapticsDuringAWorkout = SettingsSearchBreadcrumb(
        token: "Sounds & haptics › During a workout",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.soundsHapticsDuringAWorkout", defaultValue: "Sounds & haptics › During a workout",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let soundsHapticsCooking = SettingsSearchBreadcrumb(
        token: "Sounds & haptics › Cooking",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.soundsHapticsCooking", defaultValue: "Sounds & haptics › Cooking",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let soundsHapticsBreathing = SettingsSearchBreadcrumb(
        token: "Sounds & haptics › Breathing",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.soundsHapticsBreathing", defaultValue: "Sounds & haptics › Breathing",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let aiDataSources = SettingsSearchBreadcrumb(
        token: "AI & data sources",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.aiDataSources", defaultValue: "AI & data sources",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let aiDataSourcesBodySignals = SettingsSearchBreadcrumb(
        token: "AI & data sources › Body signals",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.aiDataSourcesBodySignals", defaultValue: "AI & data sources › Body signals",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let health = SettingsSearchBreadcrumb(
        token: "Health",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.health", defaultValue: "Health",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let aiDataSourcesCoreMemory = SettingsSearchBreadcrumb(
        token: "AI & data sources › Core memory",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.aiDataSourcesCoreMemory", defaultValue: "AI & data sources › Core memory",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let aiDataSourcesSignals = SettingsSearchBreadcrumb(
        token: "AI & data sources › Signals",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.aiDataSourcesSignals", defaultValue: "AI & data sources › Signals",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let debug = SettingsSearchBreadcrumb(
        token: "Debug",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.debug", defaultValue: "Debug",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let debugTier2Memory = SettingsSearchBreadcrumb(
        token: "Debug › Tier 2 memory",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.debugTier2Memory", defaultValue: "Debug › Tier 2 memory",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let debugDerivedSignals = SettingsSearchBreadcrumb(
        token: "Debug › Derived signals",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.debugDerivedSignals", defaultValue: "Debug › Derived signals",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let connectionLog = SettingsSearchBreadcrumb(
        token: "Connection log",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.connectionLog", defaultValue: "Connection log",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let connectionLogHistory = SettingsSearchBreadcrumb(
        token: "Connection log › History",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.connectionLogHistory", defaultValue: "Connection log › History",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let privacyDataICloud = SettingsSearchBreadcrumb(
        token: "Privacy & Data › iCloud",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.privacyDataICloud", defaultValue: "Privacy & Data › iCloud",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let privacyDataMultipleDevices = SettingsSearchBreadcrumb(
        token: "Privacy & Data › Multiple devices",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.privacyDataMultipleDevices", defaultValue: "Privacy & Data › Multiple devices",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let privacyDataEncryptedBackupStatus = SettingsSearchBreadcrumb(
        token: "Privacy & Data › Encrypted backup status",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.privacyDataEncryptedBackupStatus", defaultValue: "Privacy & Data › Encrypted backup status",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let privacyDataLocalBackup = SettingsSearchBreadcrumb(
        token: "Privacy & Data › Local backup",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.privacyDataLocalBackup", defaultValue: "Privacy & Data › Local backup",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let privacyDataYourData = SettingsSearchBreadcrumb(
        token: "Privacy & Data › Your data",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.privacyDataYourData", defaultValue: "Privacy & Data › Your data",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let sharingSettings = SettingsSearchBreadcrumb(
        token: "Sharing settings",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.sharingSettings", defaultValue: "Sharing settings",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let privacyDataAppLockData = SettingsSearchBreadcrumb(
        token: "Privacy & Data › App lock data",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.privacyDataAppLockData", defaultValue: "Privacy & Data › App lock data",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let aiActivityLog = SettingsSearchBreadcrumb(
        token: "AI activity log",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.aiActivityLog", defaultValue: "AI activity log",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let privacyPolicy = SettingsSearchBreadcrumb(
        token: "Privacy Policy",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.privacyPolicy", defaultValue: "Privacy Policy",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let safetyReporting = SettingsSearchBreadcrumb(
        token: "Safety & reporting",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.safetyReporting", defaultValue: "Safety & reporting",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let appLock = SettingsSearchBreadcrumb(
        token: "App lock",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appLock", defaultValue: "App lock",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let appLockSetup = SettingsSearchBreadcrumb(
        token: "App lock › Setup",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appLockSetup", defaultValue: "App lock › Setup",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let appLockManage = SettingsSearchBreadcrumb(
        token: "App lock › Manage",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appLockManage", defaultValue: "App lock › Manage",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let appLockBiometrics = SettingsSearchBreadcrumb(
        token: "App lock › Biometrics",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appLockBiometrics", defaultValue: "App lock › Biometrics",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let appLockDangerZone = SettingsSearchBreadcrumb(
        token: "App lock › Danger zone",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.appLockDangerZone", defaultValue: "App lock › Danger zone",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let homeMap = SettingsSearchBreadcrumb(
        token: "Home map",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.homeMap", defaultValue: "Home map",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let nearbyFriends = SettingsSearchBreadcrumb(
        token: "Nearby friends",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.nearbyFriends", defaultValue: "Nearby friends",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let friendsBlocks = SettingsSearchBreadcrumb(
        token: "Friends & Blocks",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.friendsBlocks", defaultValue: "Friends & Blocks",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
    static let periodSensitiveContent = SettingsSearchBreadcrumb(
        token: "Period & sensitive content",
        display: LocalizedStringResource(
            "settings.search.breadcrumb.periodSensitiveContent", defaultValue: "Period & sensitive content",
            comment: "Settings search: the context line under a result, naming where the setting lives. '›' separates a page from the card on it; keep it."))
}

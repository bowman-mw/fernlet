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
// LOCALIZATION: `title` and `keywords` were one string doing two jobs — the matching input AND the
// text of the result row. They are FORKED here (the localization wall's rule, see
// `Tests/FernletTests/LocalizationBoundaryTests`): both stay frozen English tokens, and the display
// half moved to ``SettingsSearchEntry/displayTitle``, which is the only thing the row renders.

import Foundation
import SwiftUI

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
    case nearbyFriends
    case periodSensitive
}

/// One searchable leaf: the frozen English label it is FOUND by, its search synonyms, a breadcrumb
/// subtitle for context, and the route the row navigates to.
///
/// Instances live only in ``SettingsSearchIndex/entries``; ``SettingsSheet`` renders matches as
/// navigation rows. `searchableTokens` is precomputed at construction so per-keystroke matching
/// never re-normalizes the catalog.
///
/// **Token/display fork.** `title` used to be both halves of the localization wall's forbidden
/// one-string-two-jobs shape: the matching input AND the text drawn on the result row. The split is:
/// - `title` and `keywords` are TOKENS. Frozen English forever — they feed
///   ``SettingsSearchIndex/tokens(in:)``, and `title` is also a component of `id` (the `ForEach`
///   identity). A translated token would stop matching the queries the catalog was written for and
///   would re-identify every row on a language change.
/// - ``displayTitle`` is DISPLAY. The only thing a person reads, and the only half that localizes.
///
/// So an edit to `title` is a behaviour change (search + identity), never a copy change; new wording
/// belongs in the string catalog against the existing key.
nonisolated struct SettingsSearchEntry: Identifiable {
    let title: String
    let keywords: [String]
    let breadcrumb: String
    let route: SettingsRoute
    let searchableTokens: [String]

    init(title: String, keywords: [String], breadcrumb: String, route: SettingsRoute) {
        self.title = title
        self.keywords = keywords
        self.breadcrumb = breadcrumb
        self.route = route
        self.searchableTokens = SettingsSearchIndex.tokens(in: ([title] + keywords).joined(separator: " "))
    }

    /// The localized label the result row renders — the display half of the fork.
    ///
    /// The frozen English `title` IS the catalog key: `Text` resolves a `LocalizedStringKey` built
    /// from a `String` at render time against the app bundle's table, and falls back to the key
    /// itself when no translation exists (which is why an English run is byte-identical to the
    /// pre-fork behaviour). Because the key is formed from a variable rather than a literal, the
    /// build-time extractor cannot see these strings — every title is listed in the round's
    /// `stringsAdded` so the catalog sync seeds them by hand; an unseeded title simply renders its
    /// English self.
    ///
    /// Computed rather than stored so the display can never silently drift away from the token it is
    /// keyed by. Deliberately confined to `title`: `breadcrumb` stays English until the search
    /// catalog's 369 synonyms get their per-language curation pass (`Docs/Localization-Plan-2026-07-19.md` §3).
    var displayTitle: LocalizedStringKey { LocalizedStringKey(title) }

    // Stable and unique across the catalog (no two entries share route + breadcrumb + title), so
    // `ForEach` keeps rows identified without a per-launch UUID that would break value equality.
    // Built from the frozen tokens, never `displayTitle`: a row's identity must not change with the
    // user's language.
    var id: String { "\(route)|\(breadcrumb)|\(title)" }
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
    /// Prefix-AND match over `title + keywords`: an entry is returned iff every query token is a
    /// prefix of (or equal to) some searchable token. Empty/whitespace queries return nothing (the
    /// caller keeps showing the Form). Catalog order is preserved so results are stable.
    static func results(for query: String) -> [SettingsSearchEntry] {
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
            return queryTokens.allSatisfy { queryToken in
                entry.searchableTokens.contains { $0 == queryToken || $0.hasPrefix(queryToken) }
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
            keywords: ["dark mode", "night mode", "theme", "light mode", "appearance", "display"],
            breadcrumb: "Appearance",
            route: .appearance
        ),
        SettingsSearchEntry(
            title: "Light mode background",
            keywords: ["background", "color", "colour", "light background", "custom color", "theme color", "hex", "parchment"],
            breadcrumb: "Appearance › Backgrounds",
            route: .appearance
        ),
        SettingsSearchEntry(
            title: "Dark mode background",
            keywords: ["background", "color", "colour", "dark background", "custom color", "theme color", "hex"],
            breadcrumb: "Appearance › Backgrounds",
            route: .appearance
        ),
        // Home-widget layout moved onto the Appearance page in the 2026-08-21 hub restructure
        // (SETT-14): the old Layout & shortcuts page became the Quick-log shortcuts editor (5g).
        SettingsSearchEntry(
            title: "Home widgets",
            keywords: ["home widgets", "widgets", "home screen", "layout", "main page", "rearrange", "order"],
            breadcrumb: "Appearance › Home widgets",
            route: .appearance
        ),

        // Goal & nutrition
        SettingsSearchEntry(
            title: "Goal",
            keywords: ["goal", "preset", "weight loss", "lose weight", "maintain", "gain", "build muscle", "muscle", "sports", "training", "nutrition plan"],
            breadcrumb: "Goal & nutrition",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Sick mode",
            keywords: ["sick", "illness", "unwell", "sick mode", "rest", "recovery"],
            breadcrumb: "Goal & nutrition",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Show calories",
            keywords: ["calories", "show calories", "kcal", "calorie", "numbers"],
            breadcrumb: "Goal & nutrition",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Body & measurements",
            keywords: ["body", "height", "weight", "age", "sex", "profile", "measurements"],
            breadcrumb: "Goal & nutrition › Body & preferences",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Dietary preferences",
            keywords: ["dietary", "preferences", "allergies", "vegetarian", "vegan", "diet", "restrictions"],
            breadcrumb: "Goal & nutrition › Body & preferences",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Nutrition targets",
            keywords: ["nutrition targets", "macros", "macro", "protein", "carbs", "carbohydrates", "fat", "fiber", "calorie target", "custom targets"],
            breadcrumb: "Goal & nutrition › Nutrition targets",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Daily check-in reminder",
            keywords: ["reminder", "daily check-in", "check in", "nudge", "alert", "notify"],
            breadcrumb: "Goal & nutrition › Reminders",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Notifications",
            keywords: ["notifications", "notification", "alerts", "reminders", "push notifications"],
            breadcrumb: "Goal & nutrition › Reminders",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Reminder time",
            keywords: ["reminder time", "time", "when", "schedule", "notification time"],
            breadcrumb: "Goal & nutrition › Reminders",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Water bottle size",
            keywords: ["water", "hydration", "bottle", "ounces", "oz", "drink", "bottle size"],
            breadcrumb: "Goal & nutrition › Hydration",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Daily water target",
            keywords: ["water", "hydration", "target", "bottles", "daily target", "drink", "goal"],
            breadcrumb: "Goal & nutrition › Hydration",
            route: .goalNutrition
        ),
        // Personal care tasks (its own hub row under "Your day" since 2026-08-21, SETT-14)
        SettingsSearchEntry(
            title: "Personal care tasks",
            keywords: ["personal care", "tasks", "moisturizer", "meds", "medication", "stretch", "hygiene", "care task", "habit", "routine"],
            breadcrumb: "Personal care tasks",
            route: .personalCare
        ),

        // Quick-log shortcuts (the old Layout & shortcuts page, rebuilt as the 5g editor)
        SettingsSearchEntry(
            title: "Quick log shortcuts",
            keywords: ["quick log", "shortcuts", "quick actions", "home shortcuts", "buttons", "log shortcuts"],
            breadcrumb: "Quick-log shortcuts",
            route: .layoutShortcuts
        ),

        // AI & data sources (the grouping page that took the AI/web/weather/body-signal switches
        // out from under the nutrition heading, SETT-14)
        SettingsSearchEntry(
            title: "AI status",
            keywords: ["ai", "artificial intelligence", "on device", "assistant", "status"],
            breadcrumb: "AI & data sources",
            route: .aiDataSources
        ),
        SettingsSearchEntry(
            title: "Turn AI off",
            keywords: ["ai off", "turn off ai", "disable ai", "manual off", "manual off mode"],
            breadcrumb: "AI & data sources",
            route: .aiDataSources
        ),
        SettingsSearchEntry(
            title: "Web nutrition lookup",
            keywords: ["web nutrition", "web lookup", "internet", "online", "search provider", "packaged food", "chain food", "web"],
            breadcrumb: "AI & data sources",
            route: .aiDataSources
        ),
        SettingsSearchEntry(
            title: "Weather-aware recovery prompts",
            keywords: ["weather", "recovery", "gloomy", "rain", "location", "prompts"],
            breadcrumb: "AI & data sources",
            route: .aiDataSources
        ),
        SettingsSearchEntry(
            title: "Notice body tension",
            keywords: ["stress", "body tension", "tension", "hrv", "heart rate variability", "resting heart rate", "respiration", "body signals", "anxiety"],
            breadcrumb: "AI & data sources › Body signals",
            route: .aiDataSources
        ),

        // Health
        SettingsSearchEntry(
            title: "Health access",
            keywords: ["health", "healthkit", "apple health", "permissions", "access", "integration"],
            breadcrumb: "Health",
            route: .health
        ),
        SettingsSearchEntry(
            title: "Cycle & period access",
            keywords: ["cycle", "period", "menstrual", "menstruation", "cycle tracking", "health"],
            breadcrumb: "Health",
            route: .health
        ),
        SettingsSearchEntry(
            title: "Intimate logging access",
            keywords: ["intimate", "intimacy", "sexual", "private", "health", "age", "16"],
            breadcrumb: "Health",
            route: .health
        ),
        SettingsSearchEntry(
            title: "Activity & steps access",
            keywords: ["activity", "steps", "move", "walking", "health"],
            breadcrumb: "Health",
            route: .health
        ),
        SettingsSearchEntry(
            title: "Workout access",
            keywords: ["workout", "exercise", "fitness", "training", "health"],
            breadcrumb: "Health",
            route: .health
        ),
        SettingsSearchEntry(
            title: "Mindfulness access",
            keywords: ["mindfulness", "meditation", "breathing", "mindful", "health"],
            breadcrumb: "Health",
            route: .health
        ),
        SettingsSearchEntry(
            title: "Body vitals access",
            keywords: ["body context", "vitals", "heart rate", "respiration", "temperature", "health"],
            breadcrumb: "Health",
            route: .health
        ),
        // The master switch and its jump into the Health app moved onto the one Health surface
        // (SETT-27); the frozen titles stay so saved queries keep resolving.
        SettingsSearchEntry(
            title: "Health integration",
            keywords: ["health", "healthkit", "apple health", "health integration", "permissions"],
            breadcrumb: "Health",
            route: .health
        ),
        SettingsSearchEntry(
            title: "Open Health Privacy Settings",
            keywords: ["health privacy", "ios settings", "revoke health", "health permissions"],
            breadcrumb: "Health",
            route: .health
        ),

        // Core memory (reached through AI & data sources since 2026-08-21)
        SettingsSearchEntry(
            title: "Core memory",
            keywords: ["memory", "memories", "core memory", "remember", "notes", "journal memory"],
            breadcrumb: "AI & data sources › Core memory",
            route: .coreMemory
        ),
        SettingsSearchEntry(
            title: "Forget a memory",
            keywords: ["forget", "delete memory", "remove memory", "erase memory"],
            breadcrumb: "AI & data sources › Core memory",
            route: .coreMemory
        ),

        // Signals (reached through AI & data sources since 2026-08-21)
        SettingsSearchEntry(
            title: "Signals",
            keywords: ["signals", "trends", "derived signals", "insights", "patterns"],
            breadcrumb: "AI & data sources › Signals",
            route: .signals
        ),

        // Debug
        SettingsSearchEntry(
            title: "Proximity debug tools",
            keywords: ["debug", "proximity debug", "developer", "diagnostics", "force override", "tools"],
            breadcrumb: "Debug",
            route: .debug
        ),
        SettingsSearchEntry(
            title: "Tier 2 memory",
            keywords: ["tier 2", "tier two", "memory", "inferred", "debug"],
            breadcrumb: "Debug › Tier 2 memory",
            route: .debug
        ),
        SettingsSearchEntry(
            title: "Derived signals",
            keywords: ["derived signals", "signals", "debug", "trends"],
            breadcrumb: "Debug › Derived signals",
            route: .debug
        ),

        // Connection log (the folded Debug + Connection Inspector row, DEBUG-only — SETT-28;
        // `results(for:)` withholds these routes from release search)
        SettingsSearchEntry(
            title: "Connection Inspector",
            keywords: ["connection inspector", "proximity", "pairing", "diagnostics", "mesh", "nearby", "inspector"],
            breadcrumb: "Connection log",
            route: .connectionInspector
        ),
        SettingsSearchEntry(
            title: "Connection History",
            keywords: ["connection history", "history", "past connections", "sessions", "log", "connections"],
            breadcrumb: "Connection log › History",
            route: .connectionHistory
        ),

        // Privacy & Data
        SettingsSearchEntry(
            title: "Sync to iCloud",
            keywords: ["icloud", "sync", "cloud", "sync to icloud", "cross device", "backup"],
            breadcrumb: "Privacy & Data › iCloud",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Delete iCloud data",
            keywords: ["delete icloud", "delete cloud data", "remove icloud", "wipe cloud", "icloud"],
            breadcrumb: "Privacy & Data › iCloud",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Sealed backup for sensitive notes",
            keywords: ["sealed backup", "encrypted backup", "backup", "sensitive notes", "journal backup", "encryption", "encrypted"],
            breadcrumb: "Privacy & Data › iCloud",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Sealed backup for period data",
            keywords: ["sealed backup", "period backup", "encrypted period", "cycle backup", "period", "backup"],
            breadcrumb: "Privacy & Data › iCloud",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Multiple devices",
            keywords: ["multiple devices", "two devices", "sync warning", "devices", "multi device"],
            breadcrumb: "Privacy & Data › Multiple devices",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Encrypted backup status",
            keywords: ["backup status", "restore", "escrow", "sealed backup status", "recover"],
            breadcrumb: "Privacy & Data › Encrypted backup status",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Include local data in iOS backup",
            keywords: ["local backup", "ios backup", "device backup", "icloud backup", "exclude backup", "backup"],
            breadcrumb: "Privacy & Data › Local backup",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Export my data",
            keywords: ["export", "export data", "download data", "json", "my data", "data export", "download"],
            breadcrumb: "Privacy & Data › Your data",
            route: .privacyData
        ),
        // The coach toggles live on the trainer screen itself now (Move tab › Share, SETT-14).
        // The route stays `.privacyData`: search can only push Settings destinations, the frozen
        // "export" keyword pins every export hit to `.privacyData` (SettingsSearchIndexTests), and
        // Privacy & Data still holds the neighbouring "Export my data" card. The breadcrumb tells
        // the user where the feature actually lives.
        SettingsSearchEntry(
            title: "Share with a trainer",
            keywords: ["trainer", "coach", "share", "nutritionist", "trainer export", "export"],
            breadcrumb: "Move tab › Share with a trainer",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Delete everything",
            keywords: ["delete everything", "delete all", "erase", "wipe", "reset", "remove all data", "delete", "reset everything"],
            breadcrumb: "Privacy & Data › App lock data",
            route: .privacyData
        ),

        // AI activity log
        SettingsSearchEntry(
            title: "AI activity log",
            keywords: ["ai activity", "ai log", "ai calls", "ai history", "audit", "ai audit",
                       "what left my device", "left my device", "on device model", "sent"],
            breadcrumb: "AI activity log",
            route: .aiAuditLog
        ),

        // Privacy Policy
        SettingsSearchEntry(
            title: "Privacy Policy",
            keywords: ["privacy policy", "policy", "terms", "legal", "data policy", "privacy"],
            breadcrumb: "Privacy Policy",
            route: .privacyPolicy
        ),

        // Safety & reporting
        SettingsSearchEntry(
            title: "Safety & reporting",
            keywords: ["safety", "reporting", "report", "block", "abuse", "crisis", "help", "blocked"],
            breadcrumb: "Safety & reporting",
            route: .safetyReporting
        ),

        // App lock
        SettingsSearchEntry(
            title: "App lock",
            keywords: ["app lock", "lock", "passcode", "pin", "password", "security", "unlock", "protect"],
            breadcrumb: "App lock",
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Set up app lock",
            keywords: ["set up", "setup", "create passcode", "new passcode", "enable lock"],
            breadcrumb: "App lock › Setup",
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Passcode type",
            keywords: ["pin", "4 digit", "6 digit", "password", "passcode type", "alphanumeric"],
            breadcrumb: "App lock › Setup",
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Change passcode",
            keywords: ["change passcode", "change pin", "change password", "new passcode"],
            breadcrumb: "App lock › Manage",
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Lock now",
            keywords: ["lock now", "lock", "lock app"],
            breadcrumb: "App lock › Manage",
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Face ID / Touch ID",
            keywords: ["face id", "touch id", "biometric", "biometrics", "fingerprint", "optic id"],
            breadcrumb: "App lock › Biometrics",
            route: .appLock
        ),
        SettingsSearchEntry(
            title: "Reset app lock",
            keywords: ["reset app lock", "reset lock", "forgot passcode", "remove lock"],
            breadcrumb: "App lock › Danger zone",
            route: .appLock
        ),

        // Nearby friends (the six in-person sharing consents left the Privacy list for their own
        // sub-page in the 2026-08-21 hub restructure, SETT-29)
        SettingsSearchEntry(
            title: "Nearby friends",
            keywords: ["nearby friends", "nearby", "friends", "presence", "proximity", "sharing"],
            breadcrumb: "Nearby friends",
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            title: "Share your vibe",
            keywords: ["vibe", "mood", "share vibe", "friend state", "friends"],
            breadcrumb: "Nearby friends",
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            title: "Nearby hearts",
            keywords: ["hearts", "heart", "send heart", "nearby hearts", "friends"],
            breadcrumb: "Nearby friends",
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            // Frozen token, deliberately NOT the setting's current name: the toggle was renamed
            // "Deliver hearts later" (artboard 5b, 2026-08-21) and the row displays that via the
            // string catalog's en value for this key — the token itself never rewords.
            title: "Deliver hearts when apart",
            keywords: ["hearts", "away", "apart", "deliver", "drop off", "later"],
            breadcrumb: "Nearby friends",
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            title: "Nearby recipe shares",
            keywords: ["recipe share", "share recipes", "nearby recipes", "recipes", "friends"],
            breadcrumb: "Nearby friends",
            route: .nearbyFriends
        ),
        SettingsSearchEntry(
            title: "Clothing shops with friends",
            keywords: ["clothing", "shop", "shops", "designs", "share clothing", "friends"],
            breadcrumb: "Nearby friends",
            route: .nearbyFriends
        ),

        // Period & sensitive content (the visibility gates as a first-class hub page, SETT-14)
        SettingsSearchEntry(
            title: "Period tracking",
            keywords: ["period", "cycle", "menstrual", "visibility", "hide period", "period tracking"],
            breadcrumb: "Period & sensitive content",
            route: .periodSensitive
        ),
        SettingsSearchEntry(
            title: "Intimacy tracking",
            keywords: ["intimacy", "intimate", "visibility", "hide intimacy", "sensitive"],
            breadcrumb: "Period & sensitive content",
            route: .periodSensitive
        ),
    ]
}

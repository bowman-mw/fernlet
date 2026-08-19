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

import Foundation

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
    case layoutShortcuts
    case health
    case sleep
    case move
    case coreMemory
    case signals
    case debug
    case connectionInspector
    case connectionHistory
    case privacyData
    case privacyPolicy
    case safetyReporting
    case appLock
}

/// One searchable leaf: the label shown in results, its search synonyms, a breadcrumb subtitle for
/// context, and the route the row navigates to.
///
/// Instances live only in ``SettingsSearchIndex/entries``; ``SettingsSheet`` renders matches as
/// navigation rows. `searchableTokens` is precomputed at construction so per-keystroke matching
/// never re-normalizes the catalog.
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

    // Stable and unique across the catalog (no two entries share route + breadcrumb + title), so
    // `ForEach` keeps rows identified without a per-launch UUID that would break value equality.
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
            // that puts the development page in a shipping user's hands anyway.
            #if !DEBUG
            if entry.route == .debug { return false }
            #endif
            return queryTokens.allSatisfy { queryToken in
                entry.searchableTokens.contains { $0 == queryToken || $0.hasPrefix(queryToken) }
            }
        }
    }

    /// Diacritic/case-insensitive fold, non-alphanumerics collapsed to single spaces. Mirrors
    /// `FoodItemSearch.normalized` without importing it (kept self-contained by design).
    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
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
            title: "AI status",
            keywords: ["ai", "artificial intelligence", "on device", "assistant", "status"],
            breadcrumb: "Goal & nutrition › AI",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Turn AI off",
            keywords: ["ai off", "turn off ai", "disable ai", "manual off", "manual off mode"],
            breadcrumb: "Goal & nutrition › AI",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Web nutrition lookup",
            keywords: ["web nutrition", "web lookup", "internet", "online", "search provider", "packaged food", "chain food", "web"],
            breadcrumb: "Goal & nutrition › AI",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Weather-aware recovery prompts",
            keywords: ["weather", "recovery", "gloomy", "rain", "location", "prompts"],
            breadcrumb: "Goal & nutrition › AI",
            route: .goalNutrition
        ),
        SettingsSearchEntry(
            title: "Notice body tension",
            keywords: ["stress", "body tension", "tension", "hrv", "heart rate variability", "resting heart rate", "respiration", "body signals", "anxiety"],
            breadcrumb: "Goal & nutrition › Body signals",
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
        SettingsSearchEntry(
            title: "Personal care tasks",
            keywords: ["personal care", "tasks", "moisturizer", "meds", "medication", "stretch", "hygiene", "care task", "habit", "routine"],
            breadcrumb: "Goal & nutrition › Personal care",
            route: .goalNutrition
        ),

        // Layout & shortcuts
        SettingsSearchEntry(
            title: "Home widgets",
            keywords: ["home widgets", "widgets", "home screen", "layout", "main page", "rearrange", "order"],
            breadcrumb: "Layout & shortcuts",
            route: .layoutShortcuts
        ),
        SettingsSearchEntry(
            title: "Quick log shortcuts",
            keywords: ["quick log", "shortcuts", "quick actions", "home shortcuts", "buttons", "log shortcuts"],
            breadcrumb: "Layout & shortcuts",
            route: .layoutShortcuts
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

        // Sleep
        SettingsSearchEntry(
            title: "Sleep",
            keywords: ["sleep", "rest", "hours", "sleep quality", "bedtime", "nap"],
            breadcrumb: "Sleep",
            route: .sleep
        ),

        // Move
        SettingsSearchEntry(
            title: "Apple Fitness sync",
            keywords: ["move", "workout", "fitness", "apple fitness", "exercise", "activity sync", "sync"],
            breadcrumb: "Move",
            route: .move
        ),

        // Core memory
        SettingsSearchEntry(
            title: "Core memory",
            keywords: ["memory", "memories", "core memory", "remember", "notes", "journal memory"],
            breadcrumb: "Core memory",
            route: .coreMemory
        ),
        SettingsSearchEntry(
            title: "Forget a memory",
            keywords: ["forget", "delete memory", "remove memory", "erase memory"],
            breadcrumb: "Core memory",
            route: .coreMemory
        ),

        // Signals
        SettingsSearchEntry(
            title: "Signals",
            keywords: ["signals", "trends", "derived signals", "insights", "patterns"],
            breadcrumb: "Signals",
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

        // Connection Inspector
        SettingsSearchEntry(
            title: "Connection Inspector",
            keywords: ["connection inspector", "proximity", "pairing", "diagnostics", "mesh", "nearby", "inspector"],
            breadcrumb: "Connection Inspector",
            route: .connectionInspector
        ),

        // Connection History
        SettingsSearchEntry(
            title: "Connection History",
            keywords: ["connection history", "history", "past connections", "sessions", "log", "connections"],
            breadcrumb: "Connection History",
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
            title: "Health integration",
            keywords: ["health", "healthkit", "apple health", "health integration", "permissions"],
            breadcrumb: "Privacy & Data › HealthKit",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Open Health Privacy Settings",
            keywords: ["health privacy", "ios settings", "revoke health", "health permissions"],
            breadcrumb: "Privacy & Data › HealthKit",
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
        SettingsSearchEntry(
            title: "Share with a trainer",
            keywords: ["trainer", "coach", "share", "nutritionist", "trainer export", "export"],
            breadcrumb: "Privacy & Data › Share with a trainer",
            route: .privacyData
        ),
        SettingsSearchEntry(
            title: "Delete everything",
            keywords: ["delete everything", "delete all", "erase", "wipe", "reset", "remove all data", "delete", "reset everything"],
            breadcrumb: "Privacy & Data › App lock data",
            route: .privacyData
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
    ]
}

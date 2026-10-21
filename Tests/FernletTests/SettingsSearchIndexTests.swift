// SettingsSearchIndexTests.swift
// FernletTests
//
// Item 10 (Settings search): the addressable-route enum and its searchable leaf catalog. These are
// pure value-logic checks — every route is reachable from search, representative queries resolve to
// the route a user expects, and no entry ships with an empty label the results List would render blank.
//
// Plus the localization wall's local half: `SettingsSearchEntry.title` and `.breadcrumb` are FORKED
// into frozen English tokens and localized `displayTitle` / `displayBreadcrumb` halves keyed by
// explicit `settings.search.*` catalog keys. The fork tests at the bottom pin both halves — matching
// reads only the frozen tokens, the row renders only the display halves, and every display key is in
// the committed catalog — because each regression is silent: a translated token quietly stops
// matching the queries the catalog was written for, `Text(entry.title)` quietly renders English
// forever on a clean build, and a display key the sync never harvested renders English forever too.

import Foundation
import SwiftUI
import Testing
@testable import Fernlet

@MainActor
struct SettingsSearchIndexTests {

    @Test func everyRouteHasAtLeastOneCatalogEntry() {
        for route in SettingsRoute.allCases {
            let hasEntry = SettingsSearchIndex.entries.contains { $0.route == route }
            #expect(hasEntry, "SettingsRoute.\(route) has no SettingsSearchIndex entry")
        }
    }

    @Test func noEntryHasEmptyTitleOrBreadcrumb() {
        for entry in SettingsSearchIndex.entries {
            #expect(!entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "entry with empty title (breadcrumb: \(entry.breadcrumb))")
            #expect(!entry.breadcrumb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "entry '\(entry.title)' has an empty breadcrumb")
            // Every leaf carries at least one synonym; a keyword-less entry is only findable by its
            // exact title, defeating the point of the catalog.
            #expect(!entry.keywords.isEmpty, "entry '\(entry.title)' has no keywords")
        }
    }

    @Test func representativeQueriesResolveToExpectedRoute() {
        let cases: [(query: String, expected: SettingsRoute)] = [
            ("dark", .appearance),
            ("passcode", .appLock),
            ("icloud", .privacyData),
            ("hydration", .goalNutrition),
            ("face id", .appLock),
            ("export", .privacyData),
            // The Sounds & haptics page (2026-10-20): the four words people type for it.
            ("haptics", .soundsHaptics),
            ("vibration", .soundsHaptics),
            ("sound", .soundsHaptics),
            ("voice", .soundsHaptics),
        ]
        for testCase in cases {
            let results = SettingsSearchIndex.results(for: testCase.query)
            #expect(!results.isEmpty, "query '\(testCase.query)' returned no results")
            #expect(results.first?.route == testCase.expected,
                    "query '\(testCase.query)' top hit routed to \(String(describing: results.first?.route)), expected \(testCase.expected)")
            #expect(results.allSatisfy { $0.route == testCase.expected },
                    "query '\(testCase.query)' leaked into routes other than \(testCase.expected)")
        }
    }

    /// Bug confirmation 2026-10-15, safety §2b: "crisis" used to open Safety & reporting, a page whose
    /// only contact was the developer's email, and "988", "suicide", "hotline" and "first aid" found
    /// nothing. Every one of these words now lands on that page, and the page opens on the same
    /// crisis-line card First Aid shows.
    @Test func crisisQueriesLandOnAPageThatCarriesTheCrisisLine() throws {
        for query in ["crisis", "help", "988", "suicide", "hotline", "first aid"] {
            let results = SettingsSearchIndex.results(for: query)
            #expect(!results.isEmpty, "query '\(query)' returned no results")
            #expect(results.allSatisfy { $0.route == .safetyReporting },
                    "query '\(query)' reached a page without the crisis line: \(results.map(\.route))")
        }
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        #expect(sheet.contains("case .safetyReporting:\n            SafetyReportingView()"),
                "the .safetyReporting route no longer opens SafetyReportingView")
        let page = try RepoRoot.source("App/Fernlet/SafetyReportingView.swift")
        let firstItem = try #require(page.range(of: "VStack(alignment: .leading, spacing: 16) {"))
        #expect(page[firstItem.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("CrisisSupportCard(identifierPrefix: \"safety.support\")"),
                "Safety & reporting no longer opens on the crisis-line card")
        let firstAid = try RepoRoot.source("App/Fernlet/FirstAidView.swift")
        #expect(firstAid.contains("CrisisSupportCard(identifierPrefix: \"firstAid.support\")"),
                "First Aid and Safety & reporting no longer share one card")
    }

    @Test func prefixMatchingFindsPartialTokens() {
        // "notif" should still reach the notifications/check-in leaves via prefix match.
        let results = SettingsSearchIndex.results(for: "notif")
        #expect(results.contains { $0.route == .goalNutrition })
    }

    @Test func emptyAndWhitespaceQueriesReturnNothing() {
        #expect(SettingsSearchIndex.results(for: "").isEmpty)
        #expect(SettingsSearchIndex.results(for: "   ").isEmpty)
    }

    @Test func matchingIsDiacriticAndCaseInsensitive() {
        // Uppercase + a stray diacritic must fold to the same tokens as the plain query.
        #expect(!SettingsSearchIndex.results(for: "DÁRK").isEmpty)
        #expect(SettingsSearchIndex.results(for: "DÁRK").first?.route == .appearance)
    }

    /// The fold is locale-independent (`locale: nil`), mirroring `FoodItemSearch.normalized` —
    /// whose doc comment records the live bug this pins against: `.current` case-folds by the
    /// user's locale, and under Turkish rules "I" folds to dotless "ı", so the catalog's
    /// "Face ID" tokens ("face ıd") and a typed "id" stopped agreeing and the query missed.
    /// The behavioural fixture is green-regardless on an English runner (en `.current` folding
    /// matches nil folding), so the source pin is the half that actually catches a regression —
    /// same reasoning as `hubRowsTakeALocalizedTitleNotAString` below.
    @Test func normalizationFoldsLocaleIndependently() throws {
        // Dotted capital İ decomposes to I + a combining dot; the locale-independent fold strips
        // the mark and case-folds to plain "i". Turkish-locale folding would keep İ→i but send
        // the plain capital I of "ID" to dotless "ı".
        #expect(SettingsSearchIndex.normalized("FACE ID İÇ") == "face id ic")
        let source = try RepoRoot.source("App/Fernlet/SettingsSearchIndex.swift")
        #expect(source.contains(".folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)"),
                "normalized no longer folds with locale: nil — settings search goes quietly empty on locales whose case rules differ from English")
    }

    // MARK: - Token/display fork

    /// The MATCHING half: every searchable token comes from `title` + `keywords` and nothing else, so
    /// translating a result row can never change what a query finds.
    ///
    /// The entry is also findable by its own frozen title — the property that makes the catalog's
    /// hand-written English queries (and the ones in this file) keep meaning what they say.
    @Test func matchingRunsOnTheFrozenEnglishTokensOnly() {
        for entry in SettingsSearchIndex.entries {
            let frozenInputs = ([entry.title] + entry.keywords).joined(separator: " ")
            #expect(entry.searchableTokens == SettingsSearchIndex.tokens(in: frozenInputs),
                    "entry '\(entry.title)' matches on something other than its frozen title + keywords")
            // Mirror the catalog's own release-build exclusion: the Debug page is unsearchable there.
            #if !DEBUG
            if entry.route == .debug { continue }
            #endif
            let selfHits = SettingsSearchIndex.results(for: entry.title)
            #expect(selfHits.contains { $0.id == entry.id },
                    "entry '\(entry.title)' is no longer findable by its own frozen title")
        }
    }

    /// The English a renamed setting's result row draws in place of its frozen title. The token
    /// keeps the old wording so saved queries and row ids hold; the row shows the setting's name.
    static let renamedDisplayTitles: [String: String] = [
        "Deliver hearts when apart": "Deliver hearts later",
    ]

    /// The FORK itself: tokens stay frozen English, and each display half is its own semantic key
    /// whose English is exactly what the row drew before the fork.
    ///
    /// ASCII-only is the cheap detector for the failure this guards — a token translated in place
    /// ("Modo oscuro", "Réglages") stops matching every query written against it, and nothing else in
    /// the suite would go red. Row identity is pinned too: `id` rides the frozen halves, so a language
    /// change must not re-identify (and so re-animate) every row in the results `ForEach`.
    @Test func frozenTitlesStayEnglishAndCarryALocalizedDisplayHalf() {
        var seenIDs = Set<String>()
        for entry in SettingsSearchIndex.entries {
            #expect(entry.title.allSatisfy { $0.isASCII },
                    "frozen title '\(entry.title)' is no longer plain English — tokens never localize")
            #expect(entry.keywords.allSatisfy { keyword in keyword.allSatisfy { $0.isASCII } },
                    "entry '\(entry.title)' has a non-English keyword — matching inputs never localize")
            #expect(entry.displayTitle.key.hasPrefix("settings.search.title."),
                    "entry '\(entry.title)' displays through '\(entry.displayTitle.key)', not a semantic key")
            #expect(entry.displayBreadcrumb.key.hasPrefix("settings.search.breadcrumb."),
                    "entry '\(entry.title)' breadcrumb displays through '\(entry.displayBreadcrumb.key)'")
            let drawnTitle = Self.renamedDisplayTitles[entry.title] ?? entry.title
            #expect(String(localized: entry.displayTitle) == drawnTitle,
                    "entry '\(entry.title)' no longer draws the English it drew before the fork")
            #expect(String(localized: entry.displayBreadcrumb) == entry.breadcrumb,
                    "entry '\(entry.title)' breadcrumb draws something other than its frozen path")
            #expect(entry.id.contains(entry.title), "entry '\(entry.title)' identity dropped its frozen title")
            // Hoisted: `#expect` evaluates its expression inside a `@Sendable` closure, which cannot
            // mutate a captured `var`.
            let isFirstSighting = seenIDs.insert(entry.id).inserted
            #expect(isFirstSighting, "duplicate catalog id '\(entry.id)'")
        }
        // Canaries: the exact frozen titles this suite's queries and `AIAuditLogScreenTests` resolve
        // through. Editing one is a behaviour change (search + row identity), not a copy change —
        // new wording belongs in the string catalog against the existing key.
        let titles = Set(SettingsSearchIndex.entries.map(\.title))
        for canary in ["Dark mode", "Face ID / Touch ID", "Change passcode", "Sync to iCloud",
                       "Export my data", "AI activity log", "Delete everything", "App lock",
                       "Sounds & haptics", "Haptics"] {
            #expect(titles.contains(canary),
                    "frozen title '\(canary)' was renamed — search queries and row ids depend on it")
        }
    }

    /// The DISPLAY half reaches the screen. `Text(entry.title)` takes `Text`'s verbatim `String`
    /// initializer, which renders English forever with a clean build — the regression this fork
    /// removed, invisible to every value-level assertion because it is a rendering choice rather than
    /// a value. Read off disk for the same reason the other walls are: no type system spans it.
    @Test func searchResultRowsRenderTheDisplayHalf() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        #expect(sheet.contains("Text(entry.displayTitle)"),
                "the settings-search result row no longer renders the localized display half")
        #expect(!sheet.contains("Text(entry.title)"),
                "the settings-search result row renders the frozen token — it will never localize")
        #expect(sheet.contains("Text(entry.displayBreadcrumb)"),
                "the settings-search result row no longer renders the localized breadcrumb")
        #expect(!sheet.contains("Text(entry.breadcrumb)"),
                "the settings-search result row renders the frozen breadcrumb token — it will never localize")
    }

    /// Every display key a result row draws is in the committed app catalog (Spanish round,
    /// 2026-10-20).
    ///
    /// The first cut of the fork keyed each row on `LocalizedStringKey(entry.title)`, a key built from
    /// a variable that the build-time extractor cannot see: 25 of the 79 titles never reached the
    /// catalog, so a translator was never shown them and they drew English in every language, with a
    /// clean build and no red test. Reading the catalog is the only place that is observable. A
    /// failure here means a display key was added or renamed without re-running
    /// `Scripts/sync-string-catalogs.sh` and committing the catalog.
    @Test func everyDisplayKeyIsInTheAppCatalog() throws {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any] ?? [:]
        #expect(strings.count > 1_000, "the app catalog parsed to \(strings.count) keys — it moved or broke")
        var missing: [String] = []
        for entry in SettingsSearchIndex.entries {
            for key in [entry.displayTitle.key, entry.displayBreadcrumb.key] where strings[key] == nil {
                missing.append("\(key)  ← '\(entry.title)'")
            }
        }
        #expect(missing.isEmpty, "settings-search display keys missing from the app catalog:\n\(Set(missing).sorted().joined(separator: "\n"))")
    }

    /// The hub rows' half of the same rule. Reverting `hubLink` or `hubToggle` to a `String`
    /// parameter still COMPILES — every call site passes a literal, `String` is a literal's default
    /// type, and the hub then renders English forever with no warning and no red test. Only a
    /// source pin catches it.
    @Test func hubRowsTakeALocalizedTitleNotAString() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        #expect(sheet.contains("func hubLink(_ title: LocalizedStringKey,"),
                "hubLink's title is no longer a LocalizedStringKey — the ~15 hub labels stopped localizing")
        #expect(sheet.contains("func hubToggle(_ title: LocalizedStringKey,"),
                "hubToggle's title is no longer a LocalizedStringKey — the 11 hub switch labels stopped localizing")
    }

    /// The Sounds & haptics hub row routes to its page, and the page shows the workout and breathing
    /// switches through the views that own their keys — never a second `@AppStorage` of those keys on
    /// the page itself, which would be a copy the wipe wall cannot resolve.
    @Test func soundsAndHapticsRowRoutesToItsPageAndBindsTheSurfaceKeys() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        #expect(sheet.contains("hubLink(\"Sounds & haptics\", subtitle: Text(\"Haptics, workout sounds, spoken cues\"), .soundsHaptics)"),
                "the Your day section lost its Sounds & haptics row")
        #expect(sheet.contains("case .soundsHaptics:\n            SoundsHapticsSettingsView()"),
                "the .soundsHaptics route no longer opens SoundsHapticsSettingsView")
        let page = try RepoRoot.source("App/Fernlet/SoundsHapticsSettingsView.swift")
        #expect(page.contains("@AppStorage(FernletHapticsLevel.storageKey)"))
        #expect(page.contains("WorkoutCueSwitches()") && page.contains("BreathingHapticsSwitch()"))
        for copied in ["WorkoutCuePreferences.hapticsKey", "WorkoutCuePreferences.soundsKey",
                       "WorkoutCuePreferences.spokenKey", "BreathingPreferences.hapticsKey", "fernlet.breathing.haptics"] {
            #expect(!page.contains(copied), "the page binds \(copied) itself; bind it through the view beside the key")
        }
    }
}

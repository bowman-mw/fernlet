// SettingsSearchIndexTests.swift
// FernletTests
//
// Item 10 (Settings search): the addressable-route enum and its searchable leaf catalog. These are
// pure value-logic checks — every route is reachable from search, representative queries resolve to
// the route a user expects, and no entry ships with an empty label the results List would render blank.
//
// Plus the localization wall's local half: `SettingsSearchEntry.title` is FORKED into a frozen
// English matching token and a localized `displayTitle`. The three fork tests at the bottom pin both
// halves — matching reads only the frozen tokens, and the row renders only the display half — because
// both regressions are silent: a translated token quietly stops matching the queries the catalog was
// written for, and `Text(entry.title)` quietly renders English forever on a clean build.

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

    /// The FORK itself: tokens stay frozen English, display exists and is keyed by the token.
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
            let display = entry.displayTitle
            let keyedOnTheToken = LocalizedStringKey(entry.title)
            #expect(display == keyedOnTheToken,
                    "entry '\(entry.title)' display half drifted off the token it is keyed by")
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
                       "Export my data", "AI activity log", "Delete everything", "App lock"] {
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
    }

    /// The hub rows' half of the same rule. Reverting `hubLink` to a `String` parameter still
    /// COMPILES — every call site passes a literal, `String` is a literal's default type, and the
    /// hub then renders English forever with no warning and no red test. Only a source pin catches it.
    @Test func hubRowsTakeALocalizedTitleNotAString() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        #expect(sheet.contains("func hubLink(_ title: LocalizedStringKey,"),
                "hubLink's title is no longer a LocalizedStringKey — the ~15 hub labels stopped localizing")
    }
}

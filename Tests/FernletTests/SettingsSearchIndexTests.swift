// SettingsSearchIndexTests.swift
// FernletTests
//
// Item 10 (Settings search): the addressable-route enum and its searchable leaf catalog. These are
// pure value-logic checks — every route is reachable from search, representative queries resolve to
// the route a user expects, and no entry ships with an empty label the results List would render blank.

import Foundation
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
}

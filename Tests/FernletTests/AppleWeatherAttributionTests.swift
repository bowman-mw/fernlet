//
//  AppleWeatherAttributionTests.swift
//  FernletTests
//
//  The Apple Weather credit (the owner's pick, 2026-10-25). WeatherKit's terms ask an app that shows
//  anything made from Apple's weather data to credit " Weather" and to say the data was modified;
//  Fernlet links Apple's legal page of weather data sources too. The two weather-made Home cards carry
//  the caption; Settings → AI & data sources and Acknowledgments carry the mark, the notice and the link.
//  The link's host is a "not fetched" row of `NoTrackingBoundaryTests.permittedDestinations`.
//

import Foundation
import Testing
import AppServices
@testable import Fernlet

/// Pins the Apple Weather credit: what the mark is, where the legal page points, where each piece is
/// drawn, that the Acknowledgments copy matches the daily weather budget, and that every new string
/// has a Spanish draft while the trademark itself stays out of the catalogs.
@MainActor
@Suite
struct AppleWeatherAttributionTests {

    private static let appCatalog = "App/Fernlet/Localizable.xcstrings"
    private static let servicesCatalog = "FernletKit/Sources/AppServices/Localizable.xcstrings"

    /// The Acknowledgments weather paragraph, exactly as the screen draws it.
    private static let acknowledgmentsParagraph = "When weather-aware recovery prompts are on, Fernlet asks Apple Weather for the current conditions near you, at most ten times a day. Fernlet modifies the data Apple provides: it becomes the weather on your map, the gentler-day note and the short-walk idea, never a forecast."

    /// Every display string this credit added, with the catalog it must reach.
    private static let newCopy: [(catalog: String, key: String)] = [
        (appCatalog, "From %@, modified by Fernlet"),
        (appCatalog, "Fernlet modifies the data Apple provides into its own gentle signals, never a forecast."),
        (appCatalog, "Weather data sources"),
        (appCatalog, "Opens Apple's page in Safari"),
        (appCatalog, "Weather"),
        (appCatalog, acknowledgmentsParagraph),
        (servicesCatalog, "weather.gentlerDay.prompt"),
    ]

    // MARK: - The mark and the page

    /// The mark is Apple's text form, the Apple logo and "Weather", spoken as WeatherKit's service
    /// name; the legal page is Apple's, over HTTPS, on the host the no-tracking wall lists as not fetched.
    @Test func theMarkIsApplesTextFormAndThePageIsApples() throws {
        #expect(AppleWeatherAttribution.mark == "\u{F8FF} Weather")
        #expect(AppleWeatherAttribution.spokenMark == "Apple Weather")
        let page = try #require(AppleWeatherAttribution.legalPageURL)
        #expect(page.scheme == "https")
        #expect(page.host() == "weather-data.apple.com")
    }

    // MARK: - Where it is drawn

    /// The gentler-day card ends with the caption, and the gentle offer carries it for the walk alone,
    /// the one offer the weather decides. Nothing else draws it.
    @Test func theWeatherMadeCardsCarryTheCaption() throws {
        let cards = try RepoRoot.source("App/Fernlet/AmbientCards.swift")
        let weatherCard = try Self.section(of: cards, from: "private var weatherCard: some View", to: "// MARK: - Period outlook")
        #expect(weatherCard.contains("AppleWeatherCaption()"), "the gentler-day card lost its Apple Weather caption")
        let offerCard = try Self.section(of: cards, from: "private var gentleOfferCard: some View", to: "private var activeGentleOffer")
        #expect(offerCard.contains("if kind == .shortWalk { AppleWeatherCaption() }"),
                "the short-walk offer lost its Apple Weather caption, or another offer gained it")
        #expect(cards.components(separatedBy: "AppleWeatherCaption()").count == 3, "AmbientCards should draw the caption in exactly two places")
    }

    /// The caption says the mark by name. Interpolated into the sentence, the mark loses its own label
    /// (XCUITest read the bare logo character, 2026-10-25), so the caption carries the whole spoken
    /// sentence, from the same key the drawn caption uses.
    @Test func theCaptionSpeaksTheMarkByName() throws {
        let source = try RepoRoot.source("App/Fernlet/AppleWeatherAttribution.swift")
        let caption = try Self.section(of: source, from: "struct AppleWeatherCaption: View", to: "struct AppleWeatherNotice: View")
        #expect(caption.contains(#".accessibilityLabel(Text("From \(Text(verbatim: AppleWeatherAttribution.spokenMark)), modified by Fernlet"))"#),
                "the caption no longer speaks the mark as \"Apple Weather\"")
    }

    /// Settings draws the notice inside the AI card, after the weather switch; Acknowledgments draws
    /// the weather section after the food data, with the mark, the paragraph and the link.
    @Test func settingsAndAcknowledgmentsCarryTheNoticeAndTheLink() throws {
        let sheet = try RepoRoot.source("App/Fernlet/SettingsSheet.swift")
        let aiCard = try Self.section(of: sheet, from: #"Toggle("Weather-aware recovery prompts""#, to: "private var webNutritionLookupBinding")
        #expect(aiCard.contains("AppleWeatherNotice()"), "the Apple Weather notice left its place under the weather switch")
        let acknowledgments = try RepoRoot.source("App/Fernlet/AcknowledgmentsView.swift")
        #expect(acknowledgments.contains("foodDataSection\n                weatherSection"), "the weather section left its place after the food data")
        let section = try Self.section(of: acknowledgments, from: "private var weatherSection: some View", to: "// MARK: - Pieces")
        #expect(section.contains("AppleWeatherAttribution.markText("), "the weather section lost the Apple Weather mark")
        #expect(section.contains(Self.acknowledgmentsParagraph), "the weather section's paragraph changed; update this suite and its Spanish draft")
        #expect(section.contains("AppleWeatherSourcesLink()"), "the weather section lost Apple's legal page")
        let notice = try RepoRoot.source("App/Fernlet/AppleWeatherAttribution.swift")
        #expect(notice.contains("AppleWeatherSourcesLink()"), "the Settings notice lost Apple's legal page")
        // Main-merge-2 follow-up 3: framed rows like the switches above it, the link in a row of its own.
        let row = try Self.section(of: notice, from: "struct AppleWeatherNotice: View", to: "struct AppleWeatherSourcesLink: View")
        #expect(row.contains("FernletRowLabel(title: AppleWeatherAttribution.markText("), "the Settings notice left the framed row's words")
        #expect(!row.contains("VStack"), "the Settings notice wraps its rows in one container again, so the section draws no hairline between them")
    }

    /// Acknowledgments says Fernlet asks Apple Weather "at most ten times a day": that is the budget.
    @Test func theAcknowledgmentsCountIsTheDailyBudget() {
        #expect(WeatherRequestBudget.dailyLimit == 10,
                "the weather budget moved; Acknowledgments still says ten times a day, so reword it and its Spanish draft")
    }

    // MARK: - Localization

    /// Every new string reached its catalog with a Spanish draft (a format keeps its `%@`), and the mark
    /// is in no catalog: a trademark is drawn verbatim and never offered for translation.
    @Test func theNewCopyHasSpanishDraftsAndTheMarkStaysOutOfTheCatalogs() throws {
        let catalogs = [Self.appCatalog: try Self.catalogStrings(Self.appCatalog),
                        Self.servicesCatalog: try Self.catalogStrings(Self.servicesCatalog)]
        // R2: bounded by the new-copy table.
        for (path, key) in Self.newCopy {
            let entry = catalogs[path]?[key] as? [String: Any]
            #expect(entry != nil, "\(key) is not in \(path); re-run Scripts/sync-string-catalogs.sh")
            let spanish = ((entry?["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = spanish?["value"] as? String ?? ""
            #expect(!value.isEmpty, "\(key) has no Spanish draft in \(path)")
            #expect(!key.contains("%@") || value.contains("%@"), "the Spanish draft of \(key) dropped the mark's %@")
        }
        // R2: bounded by the two catalogs.
        for (path, strings) in catalogs {
            #expect(!strings.keys.contains { $0.contains("\u{F8FF}") }, "\(path) offers the Apple Weather mark for translation")
        }
    }

    // MARK: - Helpers

    /// The `strings` table of a repo-relative `.xcstrings` file.
    private static func catalogStrings(_ path: String) throws -> [String: Any] {
        let data = Data(try RepoRoot.source(path).utf8)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(path) is not a JSON object")
        return try #require(root["strings"] as? [String: Any], "\(path) has no strings table")
    }

    /// The source from `start` up to the next `end` after it.
    private static func section(of source: String, from start: String, to end: String) throws -> Substring {
        let open = try #require(source.range(of: start), "\(start) is gone")
        let close = try #require(source.range(of: end, range: open.upperBound..<source.endIndex), "\(end) no longer follows \(start)")
        return source[open.lowerBound..<close.lowerBound]
    }
}

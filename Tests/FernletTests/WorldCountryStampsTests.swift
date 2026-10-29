import CoreText
import Foundation
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// The country stamps (World-Exploration-Spec §3, the design session's `World-Country-Stamps.json`, batch by
/// batch): the bundled file loads, every key is a country of the shipped atlas, every symbol is 14 × 14, every ink
/// follows the rule, every stamp has its names, a country whose batch hasn't landed has none, and a broken file is
/// refused.
@MainActor
struct WorldCountryStampsTests {
    /// North America's 23, the first approved batch (2026-10-29).
    static let northAmerica: Set<String> = [
        "AG", "BB", "BS", "BZ", "CA", "CR", "CU", "DM", "DO", "GD", "GT", "HN", "HT", "JM", "KN", "LC", "MX", "NI",
        "PA", "SV", "TT", "US", "VC",
    ]

    /// Europe's first 33 (2026-10-29); the other 11 of board st-eu-2 are being redrawn.
    static let europeFirst: Set<String> = [
        "GB", "FR", "IE", "IS", "NO", "SE", "FI", "DK", "EE", "LV", "LT", "IT", "VA", "SM", "MT", "SI", "HR", "BA",
        "RS", "ME", "AL", "MK", "GR", "BG", "RO", "MD", "HU", "SK", "CZ", "PL", "UA", "BY", "RU",
    ]

    /// Europe's last 11, redrawn and approved (2026-10-29).
    static let europeRest: Set<String> = ["NL", "BE", "LU", "DE", "CH", "AT", "LI", "MC", "PT", "ES", "AD"]

    /// Every label character has a glyph in the face the passport draws labels in (design session, 2026-10-29:
    /// the art assumed Pixelify Sans, which has no Ə or Ệ; Fernlet never adds fonts, so the bundled face is the
    /// one to hold). The accented capitals the labels use today are named, so a face swap that drops one fails.
    @Test func everyLabelCharacterHasAGlyphInTheStampFace() throws {
        let stamps = try #require(WorldCountryStampsLoader.bundled())
        let face = try #require(UIFont(name: WorldCountryStampsLoader.labelFontName, size: 12))
        #expect(face.fontName == WorldCountryStampsLoader.labelFontName, "the stamp face is registered")
        let font = CTFontCreateWithName(face.fontName as CFString, 12, nil)
        let used = Set(stamps.stamps.values.flatMap { $0.label.joined() })
        let named: Set<Character> = ["Č", "İ", "Ë", "Ñ", "À", "É", "Í", "Ö", "Â"]
        for character in used.union(named) {
            let units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            #expect(CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), "no glyph for \(character)")
        }
    }

    @Test func theBundledStampsLoadAndKeepTheirRules() throws {
        let stamps = try #require(WorldCountryStampsLoader.bundled())
        #expect(Self.northAmerica.isSubset(of: Set(stamps.stamps.keys)))
        #expect(Self.europeFirst.isSubset(of: Set(stamps.stamps.keys)))
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        let atlas = try WorldAtlas(data: Data(contentsOf: url))
        for (code, stamp) in stamps.stamps {
            #expect(stamp.code == code && atlas.country(code: code) != nil, "\(code) is an atlas country")
            #expect(stamp.symbol.count == 14 && stamp.symbol.allSatisfy { $0.count == 14 }, "\(code) is 14 × 14")
            #expect(stamp.symbol.joined().contains(true), "\(code) has ink")
            let index = try #require(WorldCountryStamps.inkIndex(for: code))
            #expect(stamp.ink == stamps.inks[index], "\(code)'s ink follows the rule")
            #expect(!stamp.englishName.isEmpty && !stamp.spanishName.isEmpty && !stamp.label.isEmpty)
        }
        #expect(stamps.stamp(for: "us")?.englishName == "United States")
        #expect(stamps.stamp(for: "MX")?.label.joined(separator: " ").contains("MÉXICO") == true)
        #expect(Self.europeRest.isSubset(of: Set(stamps.stamps.keys)), "Europe is complete")
        #expect(stamps.stamp(for: "JP") == nil, "Asia's batch hasn't landed: no stamp, a dashed space")
        #expect(stamps.stamp(for: "VA")?.batch == "eu", "the smallest of the 195 has its stamp")
    }

    /// The rule on its own: (first letter + second letter) mod 4, either case.
    @Test func theInkRule() {
        #expect(WorldCountryStamps.inkIndex(for: "us") == 0)
        #expect(WorldCountryStamps.inkIndex(for: "MX") == 1)
        #expect(WorldCountryStamps.inkIndex(for: "hn") == 2)
        #expect(WorldCountryStamps.inkIndex(for: "gt") == 3)
        #expect(WorldCountryStamps.inkIndex(for: "u") == nil && WorldCountryStamps.inkIndex(for: "u1") == nil)
    }

    @Test func aBrokenFileIsRefused() throws {
        let url = try #require(Bundle.main.url(forResource: WorldCountryStampsLoader.resource,
                                               withExtension: WorldCountryStampsLoader.fileExtension))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func refused(_ change: (inout [String: Any]) -> Void) throws -> WorldCountryStamps.StampError? {
            var copy = object
            change(&copy)
            do {
                _ = try WorldCountryStamps(data: JSONSerialization.data(withJSONObject: copy))
                return nil
            } catch let error as WorldCountryStamps.StampError {
                return error
            }
        }
        func editing(_ code: String, _ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
            { file in
                var countries = file["countries"] as? [String: Any] ?? [:]
                var stamp = countries[code] as? [String: Any] ?? [:]
                change(&stamp)
                countries[code] = stamp
                file["countries"] = countries
            }
        }
        #expect(try refused { $0["version"] = 2 } == .unsupportedVersion(2))
        #expect(try refused { $0["inks"] = ["#2F6FA3"] } == .badInks)
        #expect(try refused(editing("us") { $0["ink"] = "#B3343A" }) == .badStamp("us"), "an ink off the rule")
        #expect(try refused(editing("us") { $0["rows"] = ["kkk"] }) == .badStamp("us"), "not 14 × 14")
        #expect(try refused(editing("us") { $0["es"] = "" }) == .badStamp("us"), "no Spanish name")
        #expect(try refused(editing("us") { $0["label"] = ["A", "B", "C"] }) == .badStamp("us"), "three lines")
        #expect(try refused { file in
            var countries = file["countries"] as? [String: Any] ?? [:]
            countries["usa"] = countries["us"]
            file["countries"] = countries
        } == .badStamp("usa"))
    }
}

import CoreText
import Foundation
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// The country stamps (World-Exploration-Spec §3, the design session's `World-Country-Stamps.json`, batch by
/// batch, all 194 approved 2026-10-29): the bundled file loads, its stamps are exactly the passport's countries,
/// every symbol is 14 × 14, every ink follows the rule, every stamp has its names, and a broken file is refused.
@MainActor
struct WorldCountryStampsTests {
    /// The file's `excluded` block is the passport's own exclusion: North Korea has no stamp and is not counted, so
    /// the atlas's passport countries are the 195 without exactly the excluded ones, 194 in all.
    @Test func theExcludedBlockKeepsNorthKoreaOut() throws {
        let stamps = try #require(WorldCountryStampsLoader.bundled())
        #expect(stamps.excluded == ["KP"] && stamps.excluded == WorldAtlas.excludedFromPassport)
        #expect(stamps.stamp(for: "KP") == nil)
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        let atlas = try WorldAtlas(data: Data(contentsOf: url))
        let counted = Set(atlas.countries.filter(\.countsInPassport).map(\.code))
        #expect(counted.isDisjoint(with: stamps.excluded))
        #expect(counted.count == WorldAtlas.passportCountryTotal && counted.count == 195 - stamps.excluded.count)
        #expect(Set(stamps.stamps.keys) == counted, "every passport country, and only they, has a stamp")
        #expect(counted.filter { atlas.country(code: $0)?.continent == .asia }.count == 47)
    }

    /// The label's size (the file's `style.name`, DM Sans Bold approved): the smaller of 5.6 pt for one line or
    /// 4.6 pt for two, and 44 / (0.7 × the longest line's letters).
    @Test func theLabelSizingRule() throws {
        #expect(WorldCountryStamps.labelPointSize(for: ["MÉXICO"]) == 5.6)
        let unitedStates = try #require(WorldCountryStamps.labelPointSize(for: ["UNITED STATES"]))
        #expect(abs(unitedStates - 44 / (0.7 * 13)) < 1e-9 && unitedStates < 5.6)
        #expect(WorldCountryStamps.labelPointSize(for: ["ANTIGUA AND", "BARBUDA"]) == 4.6)
        let long = try #require(WorldCountryStamps.labelPointSize(for: ["SAINT VINCENT AND", "THE GRENADINES"]))
        #expect(abs(long - 44 / (0.7 * 17)) < 1e-9)
        #expect(WorldCountryStamps.labelPointSize(for: []) == nil)
        #expect(WorldCountryStamps.labelLetterSpacing == 0.15 && WorldCountryStamps.oneLineBaseline == 38.6)
        #expect(WorldCountryStamps.twoLineBaselines.first == 35.3 && WorldCountryStamps.twoLineBaselines.second == 39.7)
        let stamps = try #require(WorldCountryStampsLoader.bundled())
        for stamp in stamps.stamps.values {
            let size = try #require(WorldCountryStamps.labelPointSize(for: stamp.label), "\(stamp.code) sizes")
            #expect(size > 0 && size <= 5.6)
        }
    }

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

    /// Every passport country has its stamp and nothing else does (all 194 approved, 2026-10-29: no placeholder,
    /// no dashed space); each stamp keeps the file's rules.
    @Test func everyPassportCountryHasItsStamp() throws {
        let stamps = try #require(WorldCountryStampsLoader.bundled())
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        let atlas = try WorldAtlas(data: Data(contentsOf: url))
        let counted = Set(atlas.countries.filter(\.countsInPassport).map(\.code))
        #expect(Set(stamps.stamps.keys) == counted, "the stamps are exactly the passport's countries")
        #expect(stamps.stamps.count == WorldAtlas.passportCountryTotal)
        for (code, stamp) in stamps.stamps {
            #expect(stamp.code == code && !stamps.excluded.contains(code))
            #expect(stamp.symbol.count == 14 && stamp.symbol.allSatisfy { $0.count == 14 }, "\(code) is 14 × 14")
            #expect(stamp.symbol.joined().contains(true), "\(code) is drawn, not a placeholder")
            let index = try #require(WorldCountryStamps.inkIndex(for: code))
            #expect(stamp.ink == stamps.inks[index], "\(code)'s ink follows the rule")
            #expect(!stamp.englishName.isEmpty && !stamp.spanishName.isEmpty && !stamp.label.isEmpty)
        }
        #expect(stamps.stamp(for: "us")?.englishName == "United States")
        #expect(stamps.stamp(for: "MX")?.label == ["MÉXICO"] && stamps.stamp(for: "AZ")?.label == ["AZƏRBAYCAN"])
        #expect(stamps.stamp(for: "CM")?.label == ["CAMEROUN", "CAMEROON"])
        #expect(stamps.stamp(for: "CG")?.label == ["CONGO"] && stamps.stamp(for: "CD")?.label == ["RD CONGO"])
        #expect(stamps.stamp(for: "PG")?.label == ["PAPUA NEW", "GUINEA"])
        #expect(stamps.stamp(for: "SB")?.label.count == 2 && stamps.stamp(for: "MH")?.label.count == 2)
        #expect(stamps.stamp(for: "VA")?.batch == "eu", "the smallest of the passport's countries has its stamp")
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

import Foundation

/// One country's passport stamp, as the design session drew it (World-Exploration-Spec §3, `ex-pass-country`).
public nonisolated struct CountryStamp: Hashable, Sendable {
    /// The country's ISO 3166-1 alpha-2 code, upper case: the passport's frozen token.
    public let code: String
    /// The English name (data from the stamp file).
    public let englishName: String
    /// The Spanish name.
    public let spanishName: String
    /// The name in pixel capitals, one or two lines, as printed on the stamp (the country's own Latin name).
    public let label: [String]
    /// What the symbol shows, in words (for review; the screen reads ``englishName``).
    public let symbolDescription: String
    /// The stamp's ink, one of ``WorldCountryStamps/inks`` by ``WorldCountryStamps/inkIndex(for:)``.
    public let ink: LandmarkArtColour
    /// The 14 × 14 symbol, top row first: true where the ink is.
    public let symbol: [[Bool]]
    /// The batch it was approved in (`na`, then the next continents), a frozen token.
    public let batch: String
}

/// The country stamps approved so far (`World-Country-Stamps.json`, bundled as `WorldCountryStamps.json`): one
/// rounded-rectangle postmark per country in one of four inks, its name in pixel capitals and a 14 × 14 symbol.
/// Batches land in the same file (North America first); a country with no stamp yet has none here, and the
/// passport draws its dashed space.
///
/// **The ink rule** (the file's `style.ink`): the stamp's ink is ``inks``[(first letter + second letter of the
/// code, as ASCII) mod 4]. A stamp whose ink breaks the rule is refused. The postmark geometry, name sizes, wear
/// and tilt are the screen's, from the file's `style` notes.
///
/// **Refused, never trapped.** ``init(data:)`` throws ``StampError`` for a file over ``maxFileBytes``, another
/// version, inks that are not four `#RRGGBB`s, a key that is not two ASCII letters, an empty name or label, a label
/// of more than two lines, an ink off the rule, a symbol that is not 14 rows of 14 `k` or `.`, more than
/// ``maxStamps`` stamps, or an excluded country that is not a code or still has a stamp.
public nonisolated struct WorldCountryStamps: Sendable {
    /// The file format this build reads.
    public static let version = 1
    /// The largest file read.
    public static let maxFileBytes = 512 * 1_024
    /// The most stamps (every country and territory the atlas knows, with room).
    public static let maxStamps = 300
    /// A symbol's side, in pixels.
    public static let symbolSide = 14
    /// The longest label line, in characters.
    public static let maxLabelCharacters = 24
    /// The label's letter-spacing, in points (the file's `style.name`; owner approved DM Sans Bold, st-face).
    public static let labelLetterSpacing = 0.15
    /// The label's centre on the 56 × 44 pt postmark.
    public static let labelCentreX = 28.0
    /// A one-line label's baseline; a two-line label's two baselines.
    public static let oneLineBaseline = 38.6
    /// The two baselines of a two-line label.
    public static let twoLineBaselines = (first: 35.3, second: 39.7)

    /// The label's point size (the file's `style.name`): the smaller of 5.6 pt for one line or 4.6 pt for two,
    /// and 44 / (0.7 × the longest line's letter count), counting every character of the line as printed,
    /// spaces and hyphens included. Nil for an empty label.
    public static func labelPointSize(for label: [String]) -> Double? {
        guard (1...2).contains(label.count), let longest = label.map(\.count).max(), longest > 0 else { return nil }
        let cap = label.count == 1 ? 5.6 : 4.6
        return min(cap, 44 / (0.7 * Double(longest)))
    }

    /// Why a stamp file was refused.
    public enum StampError: Error, Equatable {
        /// Over ``maxFileBytes``.
        case tooLarge
        /// Not a stamp file (bad JSON, a missing field, a wrong type).
        case malformed
        /// A version this build does not read.
        case unsupportedVersion(Int)
        /// The inks are not exactly four `#RRGGBB` colours.
        case badInks
        /// More than ``maxStamps`` stamps.
        case overCap
        /// A stamp with a bad key, name, label, ink or symbol (named by its key).
        case badStamp(String)
    }

    /// The four inks, in the rule's order.
    public let inks: [LandmarkArtColour]
    /// The stamps by upper-case alpha-2 code.
    public let stamps: [String: CountryStamp]
    /// Countries the file records as out of the passport (its `excluded` block, upper case): no stamp, not
    /// counted. North Korea since 2026-10-29; it matches `WorldAtlas.excludedFromPassport`.
    public let excluded: Set<String>

    /// The ink index the rule gives `code` (two ASCII letters, either case), or nil for anything else.
    public static func inkIndex(for code: String) -> Int? {
        let bytes = Array(code.lowercased().utf8)
        guard bytes.count == 2, bytes.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) else {
            return nil
        }
        return (Int(bytes[0]) + Int(bytes[1])) % 4
    }

    /// The stamps in `data` (the bundled file), or the reason it is refused. Bounded: at most ``maxStamps`` stamps
    /// of ``symbolSide`` × ``symbolSide`` pixels.
    public init(data: Data) throws {
        guard data.count <= Self.maxFileBytes else { throw StampError.tooLarge }
        let file: StampFile
        do {
            file = try JSONDecoder().decode(StampFile.self, from: data)
        } catch {
            throw StampError.malformed
        }
        guard file.version == Self.version else { throw StampError.unsupportedVersion(file.version) }
        let inks = file.inks.compactMap(LandmarkArtColour.init(hex:))
        guard file.inks.count == 4, inks.count == 4 else { throw StampError.badInks }
        guard file.countries.count <= Self.maxStamps else { throw StampError.overCap }
        var stamps: [String: CountryStamp] = [:]
        for (key, raw) in file.countries {
            let stamp = try Self.stamp(raw, key: key, inks: inks)
            stamps[stamp.code] = stamp
        }
        let excluded = Set((file.excluded ?? [:]).keys.map { $0.uppercased() })
        guard excluded.count <= Self.maxStamps else { throw StampError.overCap }
        for code in excluded where Self.inkIndex(for: code) == nil || stamps[code] != nil {
            throw StampError.badStamp(code.lowercased())
        }
        self.inks = inks
        self.stamps = stamps
        self.excluded = excluded
    }

    /// The stamp for `code` (either case), or nil when its batch hasn't landed.
    public func stamp(for code: String) -> CountryStamp? {
        stamps[code.uppercased()]
    }

    /// One stamp, checked, or the reason it is refused.
    private static func stamp(_ raw: StampFileCountry, key: String, inks: [LandmarkArtColour]) throws -> CountryStamp {
        guard let index = inkIndex(for: key), !raw.batch.isEmpty else { throw StampError.badStamp(key) }
        guard !raw.en.isEmpty, !raw.es.isEmpty, (1...2).contains(raw.label.count),
              raw.label.allSatisfy({ !$0.isEmpty && $0.count <= maxLabelCharacters }),
              LandmarkArtColour(hex: raw.ink) == inks[index] else { throw StampError.badStamp(key) }
        return CountryStamp(code: key.uppercased(), englishName: raw.en, spanishName: raw.es, label: raw.label,
                            symbolDescription: raw.symbol, ink: inks[index],
                            symbol: try symbol(raw.rows, key: key), batch: raw.batch)
    }

    /// The 14 × 14 symbol as ink flags, or the reason it is refused. Bounded: ``symbolSide`` rows.
    private static func symbol(_ rows: [String], key: String) throws -> [[Bool]] {
        guard rows.count == symbolSide else { throw StampError.badStamp(key) }
        var symbol: [[Bool]] = []
        for row in rows {
            let letters = Array(row)
            guard letters.count == symbolSide, letters.allSatisfy({ $0 == "k" || $0 == "." }) else {
                throw StampError.badStamp(key)
            }
            symbol.append(letters.map { $0 == "k" })
        }
        return symbol
    }
}

/// The stamp file's top level (frozen keys; `about` and `style` are read by people, not this decoder).
private nonisolated struct StampFile: Decodable {
    /// The format version.
    let version: Int
    /// The four inks, `#RRGGBB`.
    let inks: [String]
    /// The stamps by lower-case alpha-2 code.
    let countries: [String: StampFileCountry]
    /// Countries out of the passport, by lower-case code, each with a note (optional).
    let excluded: [String: String]?
}

/// A stamp as the file spells it.
private nonisolated struct StampFileCountry: Decodable {
    /// The English name.
    let en: String
    /// The Spanish name.
    let es: String
    /// The printed name's lines.
    let label: [String]
    /// What the symbol shows.
    let symbol: String
    /// The ink, `#RRGGBB`.
    let ink: String
    /// The 14 symbol rows of `k` and `.`.
    let rows: [String]
    /// The approval batch.
    let batch: String
}

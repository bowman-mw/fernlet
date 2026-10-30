import Foundation
import FernletDomainModel
import WorldMapStore

/// The passport's fixed facts about each continent (World-Exploration-Spec §3, the mockup's `CONT` table): its
/// place in the passport's order, the key its stamp's tilt and wear are seeded from, its ink, the box its
/// silhouette is drawn from, and the country count the spec gives it. Display names are ``PassportCopy``'s.
extension AtlasContinent {
    /// The passport's order: the spreads, the progress and the stamp boards (the mockup's `CONT` order).
    nonisolated static let passportOrder: [AtlasContinent] = [.northAmerica, .southAmerica, .europe, .africa, .asia, .oceania,
                                                  .antarctica]

    /// The stamp's seed key, the mockup's own (`na`, `sa`, `eu`, `af`, `as`, `oc`, `an`): a frozen token, never
    /// shown, so a stamp lands at the tilt the approved drawing shows.
    nonisolated var stampKey: String {
        switch self {
        case .northAmerica: "na"
        case .southAmerica: "sa"
        case .europe: "eu"
        case .africa: "af"
        case .asia: "as"
        case .oceania: "oc"
        case .antarctica: "an"
        }
    }

    /// The stamp's ink in light mode (the spec's continent table).
    nonisolated var stampInk: UInt32 {
        switch self {
        case .northAmerica: 0x2F6FA3
        case .southAmerica: 0x2E8B57
        case .europe: 0x7B4BA8
        case .africa: 0xC2662D
        case .asia: 0xB3343A
        case .oceania: 0x1F8A8A
        case .antarctica: 0x5A7FA6
        }
    }

    /// The box the silhouette is drawn from, west, east, south, north in degrees (the mockup's `CONT` boxes); nil
    /// for Antarctica, which is drawn round the pole.
    nonisolated var silhouetteBox: (west: Double, east: Double, south: Double, north: Double)? {
        switch self {
        case .northAmerica: (-170, -15, 8, 84)
        case .southAmerica: (-82, -34, -56, 12)
        case .europe: (-25, 62, 34, 72)
        case .africa: (-18, 52, -35, 38)
        case .asia: (25, 180, -8, 78)
        case .oceania: (110, 180, -48, 0)
        case .antarctica: nil
        }
    }

    /// The silhouette's width in pixels: 22, Antarctica 18 (the mockup's `contStamp`).
    nonisolated var silhouetteWidth: Int { self == .antarctica ? 18 : 22 }

    /// The spec's country count (23, 12, 44, 54, 47, 14 and none: 194 in all, North Korea out). The screens count
    /// from the atlas; this is the fallback with no atlas and what the tests hold the atlas to.
    nonisolated var specCountryTotal: Int {
        switch self {
        case .northAmerica: 23
        case .southAmerica: 12
        case .europe: 44
        case .africa: 54
        case .asia: 47
        case .oceania: 14
        case .antarctica: 0
        }
    }

    /// The continent's name for the screen.
    nonisolated var passportName: LocalizedStringResource {
        switch self {
        case .northAmerica: LocalizedStringResource("North America", comment: "Passport: a continent's name")
        case .southAmerica: LocalizedStringResource("South America", comment: "Passport: a continent's name")
        case .europe: LocalizedStringResource("Europe", comment: "Passport: a continent's name")
        case .africa: LocalizedStringResource("Africa", comment: "Passport: a continent's name")
        case .asia: LocalizedStringResource("Asia", comment: "Passport: a continent's name")
        case .oceania: LocalizedStringResource("Oceania", comment: "Passport: a continent's name")
        case .antarctica: LocalizedStringResource("Antarctica", comment: "Passport: a continent's name")
        }
    }
}

/// The passport's fixed facts about each ocean (the mockup's `OCEAN` table): order, ink and name. Its sign is
/// ``PassportStampArt/oceanSign(_:)``.
extension AtlasOcean {
    /// The passport's order (the mockup's): Pacific, Atlantic, Indian, Southern, Arctic.
    nonisolated static let passportOrder: [AtlasOcean] = [.pacific, .atlantic, .indian, .southern, .arctic]

    /// The stamp's deep-blue ink in light mode (the spec's table; each 5:1 or more on both passport papers).
    nonisolated var stampInk: UInt32 {
        switch self {
        case .pacific: 0x1B3F8B
        case .atlantic: 0x17566F
        case .indian: 0x33409C
        case .southern: 0x24476B
        case .arctic: 0x3B6893
        }
    }

    /// The ocean's name for the screen ("Pacific").
    nonisolated var passportName: LocalizedStringResource {
        switch self {
        case .pacific: LocalizedStringResource("Pacific", comment: "Passport: an ocean's name on its stamp")
        case .atlantic: LocalizedStringResource("Atlantic", comment: "Passport: an ocean's name on its stamp")
        case .indian: LocalizedStringResource("Indian", comment: "Passport: an ocean's name on its stamp")
        case .southern: LocalizedStringResource("Southern", comment: "Passport: an ocean's name on its stamp")
        case .arctic: LocalizedStringResource("Arctic", comment: "Passport: an ocean's name on its stamp")
        }
    }
}

extension AtlasOcean {
    /// The ocean's full name, under its stamp on a page ("Pacific Ocean"; the mockup's caption).
    nonisolated var passportFullName: LocalizedStringResource {
        switch self {
        case .pacific: LocalizedStringResource("Pacific Ocean", comment: "Passport: the name under an ocean's stamp")
        case .atlantic: LocalizedStringResource("Atlantic Ocean", comment: "Passport: the name under an ocean's stamp")
        case .indian: LocalizedStringResource("Indian Ocean", comment: "Passport: the name under an ocean's stamp")
        case .southern: LocalizedStringResource("Southern Ocean", comment: "Passport: the name under an ocean's stamp")
        case .arctic: LocalizedStringResource("Arctic Ocean", comment: "Passport: the name under an ocean's stamp")
        }
    }
}

/// A stamp's date as the passport prints it (World-Passport-Spec §6 and §10): "14 AUG 2026" / "14 AGO 2026" in its
/// date box, and "2 September 2026" / "2 de septiembre de 2026" for VoiceOver. The month names are the spec's own
/// per-language tables (data like the atlas's names, so "SEP" never becomes ICU's "SEPT."), by ``FernletLanguage``.
nonisolated enum PassportDates {
    /// The months in capitals, January first.
    static func shortMonths(_ language: FernletLanguage) -> [String] {
        switch language {
        case .english: ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        case .spanish: ["ENE", "FEB", "MAR", "ABR", "MAY", "JUN", "JUL", "AGO", "SEP", "OCT", "NOV", "DIC"]
        }
    }

    /// The months in full, January first.
    static func longMonths(_ language: FernletLanguage) -> [String] {
        switch language {
        case .english: ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                        "October", "November", "December"]
        case .spanish: ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre",
                        "octubre", "noviembre", "diciembre"]
        }
    }

    /// The date box's words: "14 AUG 2026".
    static func short(_ date: Date, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        let parts = calendar.dateComponents([.day, .month, .year], from: date)
        let months = shortMonths(language), month = min(max((parts.month ?? 1) - 1, 0), months.count - 1)
        return "\(parts.day ?? 1) \(months[month]) \(parts.year ?? 0)"
    }

    /// VoiceOver's words: "2 September 2026" / "2 de septiembre de 2026".
    static func long(_ date: Date, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        let parts = calendar.dateComponents([.day, .month, .year], from: date)
        let months = longMonths(language), month = min(max((parts.month ?? 1) - 1, 0), months.count - 1)
        let day = parts.day ?? 1, year = parts.year ?? 0
        return language == .spanish ? "\(day) de \(months[month]) de \(year)" : "\(day) \(months[month]) \(year)"
    }
}

/// Names that come as data (a country's from the stamp file, a sea's from the atlas), in the app's language.
nonisolated enum PassportNames {
    /// `stamp`'s country name in the app's language (the stamp file carries English and Spanish).
    static func country(_ stamp: CountryStamp, language: FernletLanguage = .app) -> String {
        language == .spanish ? stamp.spanishName : stamp.englishName
    }

    /// `sea`'s name in the app's language (the atlas's Spanish where it has one, else English).
    static func sea(_ sea: AtlasSea, language: FernletLanguage = .app) -> String {
        language == .spanish && !sea.names.spanish.isEmpty ? sea.names.spanish : sea.names.english
    }
}

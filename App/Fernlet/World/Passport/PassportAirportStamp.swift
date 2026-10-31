import FernletDomainModel
import Foundation
import WorldMapStore

/// An airport's ticket stamp, the pure half (World-Airports-Spec §4.1; the mockup's `apStamp`, `apEntry` and
/// `inkOf`): which of the four stamp inks it takes, the keys its tilt, nudge and wear are seeded from, its art (a
/// small jet in profile, or a famous airport's own picture), its lettering's size, and which pixels wear away.
///
/// Everything is seeded from the airport's frozen token (its IATA code when it was first frozen), with the
/// passport's own stable hash (``PassportStampSeed``), so a stamp looks the same on every launch and device:
/// - the ink: `seed("ap:" + token) mod 4`;
/// - the tilt and the nudge on a page: `seed("ap:" + token)`, a layover's `seed("ap:" + token + "t")`;
/// - the wear (about 7 % of the art's pixels): `seed(token)`, as the mockup seeds it.
nonisolated enum PassportAirportStamp {
    /// The four stamp inks (the exploration mockup's `INKS`): blue, red, green, violet.
    static let inks: [UInt32] = [0x2F6FA3, 0xB3343A, 0x2E8B57, 0x7B4BA8]
    /// The longest city line set at the full 4.2 pt; a longer one is set at 3.5.
    static let maxFullSizeCity = 11
    /// The code's size and letter-spacing, in stamp points.
    static let codeSize = 9.6
    static let codeTracking = 1.1
    /// The city's sizes and letter-spacing, in stamp points.
    static let citySize = 4.2
    static let longCitySize = 3.5
    static let cityTracking = 0.3
    /// The most pixels across or down an art.
    static let maxArtSide = 48

    /// The key the tilt and nudge are seeded from: "ap:PDX", a layover's "ap:HELt" (the mockup's `apEntry`).
    static func seedKey(_ token: String, transit: Bool) -> String {
        "ap:" + token + (transit ? "t" : "")
    }

    /// The light-mode ink: one of ``inks`` by `seed("ap:" + token) mod 4` (dark mode lifts it with `mix2`).
    static func ink(for token: String) -> UInt32 {
        inks[Int(PassportStampSeed.seed("ap:" + token) % UInt32(inks.count))]
    }

    /// The tilt in whole degrees, −6…+6.
    static func tilt(_ token: String, transit: Bool) -> Int {
        PassportStampSeed.tilt(seedKey(token, transit: transit))
    }

    /// The key the wear is seeded from: the token itself (the mockup's `PP.seedOf(a.code)`).
    static func wearKey(_ token: String) -> String { token }

    /// Whether the airport has its own approved picture (Denver, LAX, Changi, JFK) in place of the jet.
    static func hasOwnArt(_ token: String) -> Bool {
        famous[token.uppercased()] != nil
    }

    /// The art: a famous airport's picture, else the jet in profile. Rows top first; `true` is ink.
    static func art(for token: String) -> [[Bool]] {
        PassportStampArt.pixels(famous[token.uppercased()] ?? jetSide)
    }

    /// `art` with the worn pixels dropped: the generator steps once per ink pixel, row by row, from
    /// `seed(wearKey)`, and drops about 7 % (``PassportStampSeed/isWorn(_:)``). Bounded by the art's size.
    static func worn(_ art: [[Bool]], wearKey: String) -> [[Bool]] {
        var value = PassportStampSeed.seed(wearKey)
        return art.prefix(maxArtSide).map { row in
            row.prefix(maxArtSide).map { ink in
                guard ink else { return false }
                value = PassportStampSeed.next(value)
                return !PassportStampSeed.isWorn(value)
            }
        }
    }

    /// The city line's size: 4.2 pt, or 3.5 for a line longer than ``maxFullSizeCity`` characters.
    static func citySize(for line: String) -> Double {
        line.count > maxFullSizeCity ? longCitySize : citySize
    }

    /// The city as the ticket prints it, in capitals in `language` ("MEXICO CITY", "CIUDAD DE MÉXICO").
    static func cityLine(_ city: String, language: FernletLanguage = .app) -> String {
        city.uppercased(with: Locale(identifier: language.rawValue))
    }

    /// Whether the banner may say the airport was found on the ground ("Ten minutes at the airport found it",
    /// World-Airports-Spec §3): the airport's first trip, with no flight in `flights` landing at `code` from a day
    /// before `date` to an hour after it (a landing finds an airport too, and gets its own banner). Bounded by
    /// ``PassportBook/maxFlights``.
    static func foundOnTheGround(code: String, at date: Date, trip: Int, flights: [PassportFlight]) -> Bool {
        guard trip == 1 else { return false }
        let window = date.addingTimeInterval(-86_400) ... date.addingTimeInterval(3_600)
        return !flights.prefix(PassportBook.maxFlights).contains { flight in
            flight.to == code && window.contains(flight.arrival ?? flight.departure)
        }
    }

    /// The index's everyday name: the airport's name without "International" or "Airport" ("Portland",
    /// "Heathrow", "Helsinki"; Spanish "Portland", "Helsinki"), or the name as it is when nothing is left.
    static func shortName(_ name: String, spanish: Bool) -> String {
        let prefixes = spanish ? ["Aeropuerto Internacional de ", "Aeropuerto de ", "Internacional de "] : []
        let suffixes = spanish ? [" Internacional"] : [" International Airport", " International", " Airport"]
        var short = name
        if let prefix = prefixes.first(where: { short.hasPrefix($0) }) { short = String(short.dropFirst(prefix.count)) }
        if let suffix = suffixes.first(where: { short.hasSuffix($0) }) { short = String(short.dropLast(suffix.count)) }
        let trimmed = short.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    // MARK: The art (the mockup's `JET_SIDE` and `FAMOUS`, key for key)

    /// A small jet in profile, 15 × 7.
    static let jetSide = ["k..............", "kk.............", "kkk............", "kkkkkkkkkkkkkk.",
                          ".kkkkkkkkkkkkkk", "......kkk......", ".....kkk......."]

    /// The four approved famous airports' pictures, by IATA code: Denver's tent roof, the LAX Theme Building,
    /// Singapore Changi's Jewel, JFK's TWA Flight Center.
    static let famous: [String: [String]] = [
        "DEN": ["..k...k...k...k..", ".kkk.kkk.kkk.kkk.", "kk.kkk.kkk.kkk.kk", "k...............k",
                "k.k.k.k.k.k.k.k.k", "k.k.k.k.k.k.k.k.k", "kkkkkkkkkkkkkkkkk"],
        "LAX": [".....kkkkkkk.....", "..kkkkkkkkkkkkk..", "kkkkkkkkkkkkkkkkk", "..kkkkkkkkkkkkk..",
                "...k..k...k..k...", "..k...k...k...k..", "..k..k.....k..k..", ".k...k.....k...k.",
                ".k..k.......k..k.", "k...k.......k...k", "kkkkkkkkkkkkkkkkk"],
        "SIN": ["....kkkkkkk....", "..kk.k.k.k.kk..", ".k.k...k...k.k.", "k...k.kkk.k...k", "k.k....k....k.k",
                "k......k......k", "k.k....k....k.k", "k......k......k", "k...k..k..k...k", ".k....kkk....k.",
                "..kkkkkkkkkkk.."],
        "JFK": ["k...............k", "kk.............kk", ".kkk.........kkk.", "..kkkkk...kkkkk..",
                "...kkkkkkkkkkk...", "....kk.kkk.kk....", "....k..k.k..k....", "kkkkkkkkkkkkkkkkk"]
    ]
}

extension PassportNames {
    /// `airport`'s everyday name in the app's language ("Portland International", "Internacional de Portland").
    static func airport(_ airport: WorldAirport, language: FernletLanguage = .app) -> String {
        airport.name(spanish: language == .spanish)
    }

    /// The city `airport` serves, in the app's language ("Portland", "Ciudad de México").
    static func airportCity(_ airport: WorldAirport, language: FernletLanguage = .app) -> String {
        airport.city(spanish: language == .spanish)
    }
}

/// The airport stamps' words (World-Airports-Spec §3, §4; Spanish drafts in `r7-airports-ui-es-stamps.json`).
nonisolated enum PassportAirportCopy {
    /// "TRANSIT" (a layover's ticket, where the city goes).
    static let transit = LocalizedStringResource("TRANSIT",
                                                 comment: "Sprout's passport: printed on a layover's airport stamp where the city goes (capitals; Spanish TRÁNSITO)")

    /// "Ten minutes at the airport found it. It's in Sprout's passport." (the new-stamp banner's line).
    static func foundOnTheGround(companion: String) -> LocalizedStringResource {
        LocalizedStringResource("passport.newStampBanner.airportDetail",
                                defaultValue: "Ten minutes at the airport found it. It's in \(companion)'s passport.",
                                comment: "Home banner's second line when ten minutes at a big airport stamped it; the companion's name")
    }
}

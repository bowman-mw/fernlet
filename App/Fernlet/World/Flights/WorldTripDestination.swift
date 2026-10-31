import Foundation
import WorldMapStore

/// Where a trip is going, as the ticket's To field took it (World-Airports-Spec §7): one airport ("LHR · Heathrow"),
/// or a city with several ("London · every airport"). Kept only in the flight keeper's sealed vault state (its own
/// file, ``WorldFlightKeeper/tripFile``) while the trip is on, never in UserDefaults, a widget or a notification;
/// it goes when the trip ends. Codes only (tokens, never display text): the names come from the bundled list.
nonisolated struct WorldTripDestination: Codable, Equatable, Hashable, Sendable {
    /// One airport, or a city with several.
    enum Kind: String, Codable, Sendable {
        case airport
        case city
    }

    let kind: Kind
    /// The airport's IATA code; for a city, its largest airport's (the city is named from it again).
    let code: String
    /// For a city, its airports' IATA codes, largest first (at most ``maxCityCodes``); empty for an airport.
    let cityCodes: [String]

    /// The most codes a city carries (the mockup's "LHR, LGW, STN, LCY, LTN").
    static let maxCityCodes = 5

    /// One airport, by its IATA code.
    static func airport(_ code: String) -> WorldTripDestination {
        WorldTripDestination(kind: .airport, code: code.uppercased(), cityCodes: [])
    }

    /// A city, by its airports' IATA codes, largest first; nil with fewer than two.
    static func city(codes: [String]) -> WorldTripDestination? {
        let codes = Array(codes.prefix(maxCityCodes)).map { $0.uppercased() }
        guard codes.count >= 2, let first = codes.first else { return nil }
        return WorldTripDestination(kind: .city, code: first, cityCodes: codes)
    }

    /// Whether `iata` is this destination (the airport, or one of the city's).
    func includes(_ iata: String) -> Bool {
        let wanted = iata.uppercased()
        return kind == .airport ? code == wanted : cityCodes.contains(wanted)
    }
}

/// The ticket the keeper seals while a trip is on: where it's going (nil: "Leave To blank; it fills in when you
/// land") and when it started (the boarding pass reads the trip's flights from then).
nonisolated struct WorldTripTicket: Codable, Equatable, Sendable {
    var destination: WorldTripDestination?
    let startedAt: Date
}

/// One suggestion under the ticket's To field (§7, screen 17): a city with several airports ("London · every
/// airport", its codes under it) or one airport ("LHR · Heathrow", its city under it). Facts only; the words are
/// ``WorldTripCopy``'s.
nonisolated struct WorldTripSuggestion: Equatable, Hashable, Sendable, Identifiable {
    let destination: WorldTripDestination
    /// The city's name in the app's language.
    let city: String
    /// The airport's everyday name (for an airport).
    let name: String

    /// A stable id per destination (a token).
    var id: String { "\(destination.kind.rawValue):\(destination.code)" }
}

/// The ticket's suggestion search (§7): the bundled airport list on the phone, nothing asked of anyone. Pure, so it
/// is tested with made-up airports.
///
/// - **Matches** an airport by its IATA code (the whole code, or its start), its city's start (English or Spanish),
///   or the start of a word in its name; case and accents are ignored. Only airports with an IATA code.
/// - **Order:** a city with several matching airports comes first (at most one such row), then the airports: the
///   exact code, then city matches, then code starts, then name matches; larger airports first within each, then
///   by code.
nonisolated enum WorldTripSuggestions {
    /// How many suggestions show: three, or two at the largest text (§7, §12).
    static func limit(accessibilitySize: Bool) -> Int { accessibilitySize ? 2 : 3 }

    /// The suggestions for `text` among `airports`, at most `limit`.
    static func search(_ text: String, in airports: [WorldAirport], spanish: Bool, limit: Int) -> [WorldTripSuggestion] {
        let query = fold(text)
        guard !query.isEmpty, limit > 0 else { return [] }
        var hits: [(airport: WorldAirport, rank: Int)] = []
        // Bounded: the pack holds at most `WorldAirports.maxAirports` airports.
        for airport in airports.prefix(WorldAirports.maxAirports) {
            if let rank = rank(airport, query: query) { hits.append((airport, rank)) }
        }
        hits.sort { ($0.rank, $0.airport.size.rawValue, $0.airport.code) < ($1.rank, $1.airport.size.rawValue, $1.airport.code) }
        var out: [WorldTripSuggestion] = []
        if let city = cityRow(hits.filter { $0.rank == Rank.city }.map(\.airport), spanish: spanish) { out.append(city) }
        for hit in hits.prefix(limit) where out.count < limit {
            guard let iata = hit.airport.iata else { continue }
            out.append(WorldTripSuggestion(destination: .airport(iata), city: hit.airport.city(spanish: spanish),
                                           name: hit.airport.name(spanish: spanish)))
        }
        return out
    }

    /// The ranks of a match, best first.
    enum Rank {
        static let exactCode = 0
        static let city = 1
        static let codeStart = 2
        static let name = 3
    }

    /// How `airport` matches `query` (already folded), or nil.
    static func rank(_ airport: WorldAirport, query: String) -> Int? {
        guard let iata = airport.iata else { return nil }
        let code = fold(iata)
        if code == query { return Rank.exactCode }
        let cities = [fold(airport.englishCity)] + (airport.spanishCity.map { [fold($0)] } ?? [])
        if cities.contains(where: { $0.hasPrefix(query) }) { return Rank.city }
        if code.hasPrefix(query) { return Rank.codeStart }
        let names = [airport.englishName] + (airport.spanishName.map { [$0] } ?? [])
        let words = names.flatMap { fold($0).split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        return words.contains(where: { $0.hasPrefix(query) }) ? Rank.name : nil
    }

    /// The city row: the first city (in `matches`' order) with two or more airports among them, its codes largest
    /// first; nil when no city has two.
    static func cityRow(_ matches: [WorldAirport], spanish: Bool) -> WorldTripSuggestion? {
        var groups: [String: [WorldAirport]] = [:]
        var order: [String] = []
        // Bounded: `matches` comes from the pack's airports.
        for airport in matches.prefix(WorldAirports.maxAirports) {
            let key = "\(airport.countryCode)|\(airport.englishCity)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(airport)
        }
        for key in order {
            guard let group = groups[key], group.count >= 2, let first = group.first,
                  let destination = WorldTripDestination.city(codes: group.compactMap(\.iata)) else { continue }
            return WorldTripSuggestion(destination: destination, city: first.city(spanish: spanish), name: "")
        }
        return nil
    }

    /// `text` trimmed, lowercased and without accents ("Bogotá" and "bogota" match).
    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

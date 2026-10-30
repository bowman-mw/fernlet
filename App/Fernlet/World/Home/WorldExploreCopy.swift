import Foundation
import WorldMapStore

/// The words of Home's cities and landmarks (World-Exploration-Spec §2; the mockup's `T()` pairs carry the
/// approved Spanish, drafted in `r7-explore-ui-es-cities.json`). Names are data from the atlas and the landmark
/// list: Spanish when the app shows Spanish, else English.
enum WorldExploreCopy {
    /// Whether the app is showing Spanish (its own language, not the system's).
    static var showsSpanish: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("es") ?? false
    }

    /// A landmark's name in the app's language.
    static func name(of landmark: AtlasLandmark, spanish: Bool = showsSpanish) -> String {
        spanish ? landmark.spanishName : landmark.englishName
    }

    /// A city's name in the app's language (its Spanish name when the atlas has one).
    static func name(of city: AtlasCity, spanish: Bool = showsSpanish) -> String {
        spanish && !city.names.spanish.isEmpty ? city.names.spanish : city.names.english
    }

    /// A country's name in the app's language, from its alpha-2 code (the code itself when the system has no name).
    static func country(code: String, locale: Locale = .current) -> String {
        let language = showsSpanish ? Locale(identifier: "es") : locale
        return language.localizedString(forRegionCode: code) ?? code
    }

    // MARK: Landmarks on the map

    /// VoiceOver for a landmark on the map: "Eiffel Tower, landmark, found" (a button), or "Landmark, not found
    /// yet", never named before it is found.
    static func spoken(_ landmark: AtlasLandmark, found: Bool, spanish: Bool = showsSpanish) -> String {
        guard found else { return String(localized: notFound) }
        let name = name(of: landmark, spanish: spanish)
        return String(localized: "worldLandmark.found.spoken", defaultValue: "\(name), landmark, found",
                      comment: "World Home, VoiceOver: a found landmark on the map, a button that opens its card; its name")
    }

    /// "Landmark, not found yet": VoiceOver for a landmark standing grey through the fog.
    static let notFound = LocalizedStringResource("worldLandmark.notFound.spoken", defaultValue: "Landmark, not found yet",
                                                  comment: "World Home, VoiceOver: a landmark not found yet, drawn grey and unnamed through the fog")

    // MARK: The landmark card

    /// The card's kind line: "Landmark · Portland", or "Landmark" with no city.
    static func cardKind(city: String?) -> String {
        guard let city, !city.isEmpty else { return String(localized: landmarkWord) }
        return String(localized: "worldLandmark.card.kind", defaultValue: "Landmark · \(city)",
                      comment: "World landmark card: the line under the landmark's name; its city's name")
    }

    /// "Landmark": the card's kind line without a city.
    static let landmarkWord = LocalizedStringResource("worldLandmark.card.kindAlone", defaultValue: "Landmark",
                                                      comment: "World landmark card: the line under a landmark's name when its city is unknown")

    /// The card's sentence (approved: "Found on your walk today. Your passport keeps it with Portland."); found
    /// another day, the day stands in for "today" ("Found on your walk on 12 October."). The passport keeps no
    /// "how", so every find reads "on your walk", as approved.
    static func cardFound(on date: Date, city: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let found: String
        if calendar.isDate(date, inSameDayAs: now) {
            found = String(localized: foundToday)
        } else {
            let day = dayMonth(date, now: now, calendar: calendar)
            found = String(localized: "worldLandmark.card.foundOn", defaultValue: "Found on your walk on \(day).",
                           comment: "World landmark card: when it was found, another day; the day and month (12 October)")
        }
        guard let city, !city.isEmpty else { return found }
        let keeps = String(localized: "worldLandmark.card.keeps", defaultValue: "Your passport keeps it with \(city).",
                           comment: "World landmark card: the passport keeps the landmark with its city; the city's name")
        return "\(found) \(keeps)"
    }

    /// "Found on your walk today.": the approved sentence's first half.
    static let foundToday = LocalizedStringResource("worldLandmark.card.foundToday", defaultValue: "Found on your walk today.",
                                                    comment: "World landmark card: the landmark was found today")

    // MARK: The city card and the city view

    /// The card's subtitle: "City · United States".
    static func cityKind(sizeName: String, country: String) -> String {
        String(localized: "worldCity.card.kind", defaultValue: "\(sizeName) · \(country)",
               comment: "World city card: under the city's name, its size class (City) and its country")
    }

    /// The Discovered row's value: the passport's first-visit date ("12 October", with the year when it isn't
    /// this year). The mockup's "On a walk," is left out: the passport keeps the date only, not how.
    static func discovered(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        dayMonth(date, now: now, calendar: calendar)
    }

    /// The Landmarks row's value: "2 of 6 found".
    static func landmarksFound(_ found: Int, of total: Int) -> String {
        String(localized: "worldCity.card.landmarksFound", defaultValue: "\(found) of \(total) found",
               comment: "World city card: how many of the city's landmarks have been found, of how many")
    }

    /// The Uncovered row's value: "3% of the city" (under 1% but some: "Under 1% of the city").
    static func uncovered(_ share: Double) -> String {
        guard share.isFinite, share > 0 else { return percent(0) }
        guard share >= 0.01 else { return String(localized: underOnePercent) }
        return percent(Int((min(share, 1) * 100).rounded()))
    }

    /// "Under 1% of the city": some of the city uncovered, but less than one per cent.
    static let underOnePercent = LocalizedStringResource("worldCity.card.uncoveredUnderOne", defaultValue: "Under 1% of the city",
                                                         comment: "World city card: less than one per cent of the city is uncovered, but some")

    /// "3% of the city".
    private static func percent(_ whole: Int) -> String {
        String(localized: "worldCity.card.uncovered", defaultValue: "\(whole)% of the city",
               comment: "World city card: how much of the city's urban area the person has uncovered, a whole per cent")
    }

    /// VoiceOver for the landmarks not found yet in the card's list: "4 more not found yet" (never named).
    static func moreNotFound(_ count: Int) -> String {
        String(localized: "worldCity.card.moreNotFound", defaultValue: "\(count) more not found yet",
               comment: "World city card, VoiceOver: the question marks of the city's landmarks not found yet; how many")
    }

    /// The city view's plate: "Portland · 2 of 6 landmarks" (the city alone when it has no landmarks listed).
    static func cityPlate(city: String, found: Int, total: Int) -> String {
        guard total > 0 else { return city }
        let landmarks = String(localized: "worldCity.plate.landmarks", defaultValue: "\(found) of \(total) landmarks",
                               comment: "World Home, the city view's plate after the city's name: landmarks found of the city's list")
        return "\(city) · \(landmarks)"
    }

    /// VoiceOver for a city marker: "Portland, city, button" reads the name and the size class (the button trait
    /// adds "button").
    static func cityMarkerSpoken(name: String, sizeName: String) -> String {
        String(localized: "worldCity.marker.spoken", defaultValue: "\(name), \(sizeName)",
               comment: "World Home, VoiceOver: a found city's marker zoomed out, a button that opens its card; its name and size class")
    }

    /// "12 October" (and the year when it is not `now`'s).
    static func dayMonth(_ date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = sameYear ? Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.wide)
            : Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.wide).year()
        return date.formatted(style)
    }
}

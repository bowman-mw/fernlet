import Foundation
import WorldMapStore

/// The words of Home at an airport (World-Airports-Spec §3, §5, §6.3; the mockup's `T()` pairs carry the approved
/// Spanish, and the lines the spec leaves in English have drafts, all in `r7-airports-ui-es-home.json`). Airport
/// names and cities are data from the bundled list: Spanish when the app shows Spanish, else English.
enum WorldAirportCopy {
    // MARK: Names

    /// The airport's everyday name in the app's language ("Portland International", "Heathrow").
    static func name(_ airport: WorldAirport, spanish: Bool = WorldExploreCopy.showsSpanish) -> String {
        airport.name(spanish: spanish)
    }

    /// The city it serves in the app's language ("Portland", "Londres").
    static func city(_ airport: WorldAirport, spanish: Bool = WorldExploreCopy.showsSpanish) -> String {
        airport.city(spanish: spanish)
    }

    /// The tower's plate: "PDX · Portland" (the code and the city, as the mockup's plate draws it).
    static func plate(_ airport: WorldAirport, spanish: Bool = WorldExploreCopy.showsSpanish) -> String {
        "\(airport.code) · \(city(airport, spanish: spanish))"
    }

    // MARK: The tower

    /// VoiceOver for a found tower: "Portland International, PDX, airport, found" (as the stamps read, §4.2).
    static func spokenTower(_ airport: WorldAirport, spanish: Bool = WorldExploreCopy.showsSpanish) -> String {
        let name = name(airport, spanish: spanish), code = airport.code
        return String(localized: "worldAirport.found.spoken", defaultValue: "\(name), \(code), airport, found",
                      comment: "World Home, VoiceOver: a found airport's tower on the map; its name, then its code")
    }

    /// "Airport, not found yet": VoiceOver for a tower standing grey through the fog (the mockup's label).
    static let notFound = LocalizedStringResource("worldAirport.notFound.spoken", defaultValue: "Airport, not found yet",
                                                  comment: "World Home, VoiceOver: an airport not found yet, its tower drawn grey and unnamed through the fog")

    // MARK: The tag

    /// "At the airport · PDX" (§5), beside the blue button while the person is inside an airport's grounds.
    static func tag(code: String) -> String {
        String(localized: "worldAirport.tag", defaultValue: "At the airport · \(code)",
               comment: "World Home, the place tag beside the blue button inside an airport's grounds; the airport's code")
    }

    /// What VoiceOver reads for the tag: "At the airport, PDX".
    static func spokenTag(code: String) -> String {
        String(localized: "worldAirport.tag.spoken", defaultValue: "At the airport, \(code)",
               comment: "World Home, VoiceOver: the place tag inside an airport's grounds; the airport's code")
    }

    // MARK: The layover counter

    /// "Layover at Helsinki · 2 h 14 min" (§5, screen 7): the city, then the time since landing.
    static func layover(city: String, minutes: Int) -> String {
        let since = duration(minutes: minutes)
        return String(localized: "worldAirport.layover.title", defaultValue: "Layover at \(city) · \(since)",
                      comment: "World Home, the layover counter after a landing; the airport's city, then the time since landing")
    }

    /// "Since you landed. Fly on, and its stamp says Transit." (the counter's second line).
    static let layoverDetail = LocalizedStringResource("worldAirport.layover.detail",
                                                       defaultValue: "Since you landed. Fly on, and its stamp says Transit.",
                                                       comment: "World Home, the layover counter's second line")

    /// A time since landing, to the minute: "14 min", "2 h", "2 h 14 min".
    static func duration(minutes: Int) -> String {
        let total = max(minutes, 0), hours = total / 60, rest = total % 60
        if hours == 0 {
            return String(localized: "worldAirport.duration.minutes", defaultValue: "\(rest) min",
                          comment: "World Home, the layover counter's time under an hour; minutes")
        }
        if rest == 0 {
            return String(localized: "worldAirport.duration.hours", defaultValue: "\(hours) h",
                          comment: "World Home, the layover counter's time on the hour; hours")
        }
        return String(localized: "worldAirport.duration.hoursMinutes", defaultValue: "\(hours) h \(rest) min",
                      comment: "World Home, the layover counter's time; hours, then minutes")
    }

    // MARK: Banners

    /// "Ten minutes at the airport found it. It's in Sprout's passport." (§3, the found banner's second line).
    static func dwellDetail(companion: String) -> String {
        String(localized: "worldAirport.banner.dwell", defaultValue: "Ten minutes at the airport found it. It's in \(companion)'s passport.",
               comment: "World Home banner for an airport found by ten minutes inside it, second line; the companion's name")
    }

    /// "Landed at Heathrow" (§6.3, the landing banner's title).
    static func landedTitle(_ name: String) -> String {
        String(localized: "worldAirport.banner.landed", defaultValue: "Landed at \(name)",
               comment: "World Home banner just after a flight lands; the airport's name")
    }

    /// The landing banner's second line (§6.3): "New stamp: Heathrow. Europe's and the United Kingdom's come when
    /// you leave the airport." when both wait; the country's alone when only it waits; else the stamp and the
    /// passport.
    static func landedDetail(_ name: String, continent: String?, country: String?, companion: String) -> String {
        switch (continent, country) {
        case (let continent?, let country?):
            String(localized: "worldAirport.banner.landed.both",
                   defaultValue: "New stamp: \(name). \(continent)'s and \(country)'s come when you leave the airport.",
                   comment: "World Home landing banner, second line; the airport's name, the continent's, then the country's (with 'the' in English where it takes one)")
        case (nil, let country?):
            String(localized: "worldAirport.banner.landed.country",
                   defaultValue: "New stamp: \(name). \(country)'s comes when you leave the airport.",
                   comment: "World Home landing banner, second line when only the country's stamp waits; the airport's name, then the country's (capitalised, with 'The' in English where it takes one)")
        default:
            String(localized: "worldAirport.banner.landed.none",
                   defaultValue: "New stamp: \(name). It's in \(companion)'s passport.",
                   comment: "World Home landing banner, second line when no country stamp waits; the airport's name, then the companion's")
        }
    }

    /// What VoiceOver hears for an airport banner: its two lines as one.
    static func spokenBanner(title: String, detail: String) -> String {
        String(localized: "worldAirport.banner.spoken", defaultValue: "\(title). \(detail)",
               comment: "VoiceOver: a Home airport banner; its title, then its second line")
    }

    /// The airport banner's VoiceOver hint.
    static let bannerHint = LocalizedStringResource("worldAirport.banner.hint", defaultValue: "Opens the passport.",
                                                    comment: "VoiceOver hint on a Home airport banner")

    // MARK: Country names in the landing banner

    /// The country names English puts "the" before (the regions whose everyday name is plural or a description).
    static let englishThe: Set<String> = ["GB", "US", "NL", "PH", "AE", "BS", "GM", "CF", "DO", "MV", "MH", "SB", "KM", "VA"]

    /// A country's name as the landing banner says it: "the United Kingdom" in English where the name takes "the"
    /// ("The United Kingdom" at the start of a sentence), else the name alone.
    static func bannerCountry(code: String, atStart: Bool, spanish: Bool = WorldExploreCopy.showsSpanish) -> String {
        let name = WorldExploreCopy.country(code: code)
        guard !spanish, englishThe.contains(code.uppercased()) else { return name }
        return (atStart ? "The " : "the ") + name
    }
}

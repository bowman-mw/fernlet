import Foundation
import WorldMapStore

/// The world map's words (World-Exploration-Spec §2, `ex-world` draft 3 and `ex-world-zoom` draft 2; the
/// mockup's `fullMap()` gives the Spanish). Display text only: the zoom levels' tokens stay English. The page is
/// opened from page 2 of Sprout's passport (World-Passport-Spec §5), whose world preview's words are here too.
nonisolated enum WorldViewCopy {
    /// The page's title chip: "Your world".
    static let title = LocalizedStringResource("worldView.title", defaultValue: "Your world",
                                               comment: "World view: the title chip of the full-screen map of every city the person has found")
    /// The back chip's word: "Passport".
    static let back = LocalizedStringResource("worldView.back", defaultValue: "Passport",
                                              comment: "World view: the back chip's word, top left, which returns to the passport's world page")
    /// The back chip's VoiceOver name: "Back to Passport".
    static let backSpoken = LocalizedStringResource("worldView.back.spoken", defaultValue: "Back to Passport",
                                                    comment: "World view: VoiceOver name of the back chip, top left")
    /// The world preview's chip: "Open the map".
    static let openMap = LocalizedStringResource("worldView.preview.open", defaultValue: "Open the map",
                                                 comment: "Passport, Your world page: the chip on the small world map that opens it full screen")
    /// The world preview's VoiceOver name: "Your world map. Opens full screen."
    static let previewSpoken = LocalizedStringResource("worldView.preview.spoken", defaultValue: "Your world map. Opens full screen.",
                                                       comment: "Passport, Your world page: VoiceOver name of the small world map, one button")

    /// The zoom control's VoiceOver name: "Zoom level".
    static let zoomLevel = LocalizedStringResource("worldView.zoom.level", defaultValue: "Zoom level",
                                                   comment: "World view: VoiceOver name of the zoom control's level; swipe up or down to change it")
    /// The + button: "Zoom in".
    static let zoomIn = LocalizedStringResource("worldView.zoom.in", defaultValue: "Zoom in",
                                                comment: "World view: the + button of the zoom control")
    /// The − button: "Zoom out".
    static let zoomOut = LocalizedStringResource("worldView.zoom.out", defaultValue: "Zoom out",
                                                 comment: "World view: the − button of the zoom control")

    /// A zoom level's name, shown in the control and spoken first in its value.
    static func level(_ level: AtlasZoomLevel) -> LocalizedStringResource {
        switch level {
        case .world:
            LocalizedStringResource("worldView.level.world", defaultValue: "World",
                                    comment: "World view: the zoom level showing the whole world")
        case .country:
            LocalizedStringResource("worldView.level.country", defaultValue: "Country",
                                    comment: "World view: the zoom level showing a country, with country lines")
        case .state:
            LocalizedStringResource("worldView.level.state", defaultValue: "State",
                                    comment: "World view: the zoom level showing a state or province, with its lines")
        case .city:
            LocalizedStringResource("worldView.level.city", defaultValue: "City",
                                    comment: "World view: the closest zoom level, about 270 km top to bottom")
        }
    }

    /// The plate's counts: "4 cities, 3 countries found".
    static func found(cities: Int, countries: Int) -> String {
        let cityWords = cities == 1
            ? String(localized: LocalizedStringResource("worldView.cities.one", defaultValue: "1 city",
                                                        comment: "World view plate: one city found"))
            : String(localized: LocalizedStringResource("worldView.cities.other", defaultValue: "\(cities) cities",
                                                        comment: "World view plate: the number of cities found (never one)"))
        let countryWords = countries == 1
            ? String(localized: LocalizedStringResource("worldView.countries.one", defaultValue: "1 country",
                                                        comment: "World view plate: one country found"))
            : String(localized: LocalizedStringResource("worldView.countries.other", defaultValue: "\(countries) countries",
                                                        comment: "World view plate: the number of countries found (never one)"))
        return String(localized: LocalizedStringResource("worldView.plate.found", defaultValue: "\(cityWords), \(countryWords) found",
                                                         comment: "World view plate: the cities and the countries found, e.g. 4 cities, 3 countries found"))
    }

    /// The plate's place from State in: "Oregon · United States".
    static func place(region: String, country: String) -> String {
        String(localized: LocalizedStringResource("worldView.plate.place", defaultValue: "\(region) · \(country)",
                                                  comment: "World view plate: the state or province, then the country, at the view's centre"))
    }

    /// The zoom level's spoken value: "World", "Country, United States" or "City, Oregon, United States".
    static func zoomValue(_ description: AtlasZoomDescription) -> String {
        let level = String(localized: Self.level(description.level))
        guard let place = description.place else { return level }
        let country = WorldViewNames.country(place.countryCode)
        guard let names = place.regionNames else {
            return String(localized: LocalizedStringResource("worldView.zoom.value.country", defaultValue: "\(level), \(country)",
                                                             comment: "World view: the zoom level then the country, spoken, e.g. Country, United States"))
        }
        let region = WorldViewNames.pick(names)
        return String(localized: LocalizedStringResource("worldView.zoom.value.region",
                                                         defaultValue: "\(level), \(region), \(country)",
                                                         comment: "World view: the zoom level, the state, then the country, spoken, e.g. City, Oregon, United States"))
    }

    /// A shared marker's plate: "Seattle +2".
    static func clusterPlate(name: String, others: Int) -> String {
        String(localized: LocalizedStringResource("worldView.marker.plate", defaultValue: "\(name) +\(others)",
                                                  comment: "World view: a marker shared by nearby cities, named for the biggest, then how many more"))
    }

    /// A shared marker's VoiceOver name: "Seattle and 2 more cities".
    static func clusterSpoken(name: String, others: Int) -> String {
        others == 1
            ? String(localized: LocalizedStringResource("worldView.marker.spoken.one", defaultValue: "\(name) and 1 more city",
                                                        comment: "World view: VoiceOver name of a marker shared by two cities"))
            : String(localized: LocalizedStringResource("worldView.marker.spoken.other",
                                                        defaultValue: "\(name) and \(others) more cities",
                                                        comment: "World view: VoiceOver name of a marker shared by several cities"))
    }

    /// A marker's hint farther out: "Zooms in".
    static let zoomsIn = LocalizedStringResource("worldView.marker.hint.zoom", defaultValue: "Zooms in",
                                                 comment: "World view: VoiceOver hint of a city marker before the closest zoom")
    /// A marker's hint at City: "Opens the city".
    static let opensCity = LocalizedStringResource("worldView.marker.hint.open", defaultValue: "Opens the city",
                                                   comment: "World view: VoiceOver hint of a city marker at the closest zoom")
}

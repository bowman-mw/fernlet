import FernletDomainModel
import Foundation
import WorldMapStore

/// What the world view draws, read once when it opens: the bundled atlas, the person's discovered cities
/// and counts from the sealed passport, the lifted fog, and where to open.
///
/// Everything comes from the passport (`store.worldFog.atlas.book`) and the fog history; a decoy shows an
/// empty book and no lifted fog, so its world view has no cities and no uncovered hexes (the atlas's land and
/// sea are public data that ships in the app). Nothing here is written anywhere.
nonisolated struct WorldViewContent: Sendable {
    /// The bundled atlas, or nil when the pack is missing (the view then shows only the sea).
    var atlas: WorldAtlas?
    /// The discovered cities.
    var pins: [WorldViewCityPin]
    /// How many cities the passport keeps.
    var cityCount: Int
    /// How many countries the passport keeps.
    var countryCount: Int
    /// The lifted fog cells (none in a decoy).
    var liftedCells: [HexCell]
    /// Where the view opens: the person's first home, else their latest fix, else nil (0°, 0°).
    var start: GeoPoint?

    /// Nothing at all: no atlas, no cities, no fog.
    static let empty = WorldViewContent(atlas: nil, pins: [], cityCount: 0, countryCount: 0, liftedCells: [], start: nil)

    /// The content for `book` and `cells` over `atlas`: each city the book keeps that the atlas knows, named
    /// in the app's language. Bounded: at most the book's own cap on cities.
    static func make(atlas: WorldAtlas?, book: PassportBook, cells: [HexCell], start: GeoPoint?) -> WorldViewContent {
        let tokens = book.visits(of: .city).keys.sorted().prefix(WorldViewCluster.maxPins)
        let pins = tokens.compactMap { token in
            atlas?.city(token: token).map { WorldViewCityPin(city: $0, name: WorldViewNames.city($0)) }
        }
        return WorldViewContent(atlas: atlas, pins: pins, cityCount: book.count(of: .city),
                                countryCount: book.count(of: .country),
                                liftedCells: Array(cells.prefix(WorldViewHexGrid.maxLiftedCells)), start: start)
    }
}

extension WorldViewContent {
    /// The person's world view from the store: the passport the screens show (empty in a decoy), the lifted
    /// fog (none in a decoy), and their first home (the latest fix in a decoy or with no home).
    @MainActor
    static func live(store: FernletStore) -> WorldViewContent {
        let fog = store.worldFog
        let decoy = fog.isDecoy
        let home = decoy ? nil : store.worldHomes.homes.first { $0.kind == .home }?.point
        return make(atlas: fog.atlas.openedAtlas, book: fog.atlas.book, cells: decoy ? [] : Array(fog.visibleCells),
                    start: home ?? store.worldLocation.latest?.point)
    }
}

/// The world view's display names from the atlas's data: a city's and a region's names in the app's language
/// (the pack carries English and Spanish), and a country's name from the system's own region names.
nonisolated enum WorldViewNames {
    /// The app's language.
    static var language: FernletLanguage { FernletLanguage.app }

    /// `names` in the app's language, English where the source has no translation.
    static func pick(_ names: AtlasCityNames, in language: FernletLanguage = language) -> String {
        switch language {
        case .spanish: names.spanish.isEmpty ? names.english : names.spanish
        case .english: names.english
        }
    }

    /// A city's name in the app's language.
    static func city(_ city: AtlasCity) -> String { pick(city.names) }

    /// The country named by alpha-2 `code`, in the app's language ("United States", "Estados Unidos"); the
    /// code itself when the system has no name for it.
    static func country(_ code: String, in language: FernletLanguage = language) -> String {
        Locale(identifier: language.rawValue).localizedString(forRegionCode: code) ?? code
    }
}

import FernletDomainModel
import FernletFoundation
import Foundation
import WorldMapStore

/// What the passport's stamps are drawn from (World-Exploration-Spec §3; round 7's reusable pieces, held for
/// Sprout's passport redesign): the bundled atlas (through the atlas keeper, which opens it once a session), the
/// country stamps, the atlas's passport countries, the continents' silhouettes, the sea inks, and the bundled
/// airport list's names and cities for the airports' tickets (World-Airports-Spec §4.1, through the airports shelf).
///
/// It reads none of the person's data itself: ``progress(of:)`` counts whatever book its caller hands it (the
/// screens hand it `store.worldFog.atlas.book`, empty in a decoy). Everything here is public data that ships in the app, cached the first time a page asks: the stamps file
/// once, the country table once, each silhouette once (7 at most), the sea inks once (one pass over the atlas's
/// sea raster). Main-actor bound, like the screens.
@MainActor
final class PassportLibrary {
    /// Opens (or hands over the already opened) atlas: `store.worldFog.atlas.openedAtlas`.
    private let openAtlas: @MainActor () -> WorldAtlas?
    /// Which seas touch, from the session's table (`store.worldFog.atlas.seaNeighbours()`); nil works them out from
    /// ``atlas`` here (the DEBUG gallery, which opens an atlas of its own).
    private let openSeaNeighbours: (@MainActor () -> [String: Set<String>])?
    /// Opens (or hands over) the bundled airport list: `store.worldLocation.flights.airportsShelf.pack()`, which
    /// opens it once; nil names airports by their tokens alone.
    private let openAirports: (@MainActor () -> WorldAirports?)?
    private var atlasState: WorldAtlas??
    private var stampsState: WorldCountryStamps??
    private var tableState: PassportCountryTable?
    private var silhouettes: [AtlasContinent: [[Bool]]] = [:]
    private var seaInksState: PassportSeaInks?

    /// A library over the atlas `openAtlas` gives (called once, on first use), its sea inks drawn from the table
    /// `seaNeighbours` gives (called once, on the first sea; nil works it out from the atlas), its airports named
    /// from the list `airports` opens (nil: by their tokens).
    init(openAtlas: @escaping @MainActor () -> WorldAtlas?,
         seaNeighbours: (@MainActor () -> [String: Set<String>])? = nil,
         airports: (@MainActor () -> WorldAirports?)? = nil) {
        self.openAtlas = openAtlas
        self.openSeaNeighbours = seaNeighbours
        self.openAirports = airports
    }

    /// The airport `token` from the bundled list, or nil (no list, or a token it doesn't hold).
    func airport(_ token: String) -> WorldAirport? {
        openAirports?()?.airport(token: token)
    }

    /// The bundled atlas, or nil when it is missing, unreadable (the keeper logs that) or still opening at launch;
    /// kept once there, asked again until then.
    var atlas: WorldAtlas? {
        if let atlasState { return atlasState }
        let opened = openAtlas()
        if let opened { atlasState = .some(opened) }
        return opened
    }

    /// The country stamps, or nil when the file is missing or refused (logged by the loader; the passport then
    /// draws dashed spaces for countries but still counts them).
    var stamps: WorldCountryStamps? {
        if let stampsState { return stampsState }
        let loaded = WorldCountryStampsLoader.bundled()
        stampsState = .some(loaded)
        return loaded
    }

    /// The atlas's passport countries (``PassportCountryTable/empty`` with no atlas).
    var countryTable: PassportCountryTable {
        if let tableState { return tableState }
        guard let atlas else { return .empty }
        let table = PassportCountryTable(atlas: atlas)
        tableState = table
        return table
    }

    /// How far `book` has come, counted against the atlas. The screens pass `store.worldFog.atlas.book`, the
    /// person's passport (an empty one in a decoy) and nothing else.
    func progress(of book: PassportBook) -> PassportProgress {
        PassportProgress(book: book, table: countryTable)
    }

    // MARK: Drawings

    /// `continent`'s stamp: its silhouette in its ink.
    func continentStamp(_ continent: AtlasContinent) -> PassportStampDrawing {
        PassportStampDrawing(ink: continent.stampInk, art: silhouette(continent), label: [], key: continent.stampKey)
    }

    /// `ocean`'s stamp: its sign in its deep blue.
    func oceanStamp(_ ocean: AtlasOcean) -> PassportStampDrawing {
        PassportStampDrawing(ink: ocean.stampInk, art: PassportStampArt.oceanSign(ocean), label: [],
                             key: ocean.rawValue)
    }

    /// The sea `token`'s stamp: the waves in its bright blue.
    func seaStamp(_ token: String) -> PassportStampDrawing {
        PassportStampDrawing(ink: seaInks.ink(for: token), art: PassportStampArt.seaWaves, label: [], key: token)
    }

    /// Country `code`'s stamp from the stamp file, or nil when the file has none (a dashed space is drawn).
    func countryStamp(_ code: String) -> CountryStamp? {
        stamps?.stamp(for: code)
    }

    /// `stamp` ready to draw: its ink, its 14 × 14 symbol and its label, seeded by its lower-case code.
    func countryDrawing(_ stamp: CountryStamp) -> PassportStampDrawing {
        PassportStampDrawing(ink: Self.hex(stamp.ink), art: stamp.symbol, label: stamp.label,
                             key: stamp.code.lowercased())
    }

    /// `token`'s ticket: its ink, its jet (or its own picture), its code and city (TRANSIT for a layover), seeded
    /// by its "ap:" key and worn by its token (World-Airports-Spec §4.1).
    func airportDrawing(_ token: String, transit: Bool) -> PassportStampDrawing {
        let city = airport(token).map { PassportAirportStamp.cityLine(PassportNames.airportCity($0)) } ?? ""
        let second = transit ? String(localized: PassportAirportCopy.transit) : city
        return PassportStampDrawing(ink: PassportAirportStamp.ink(for: token), art: PassportAirportStamp.art(for: token),
                                    label: second.isEmpty ? [airportCode(token)] : [airportCode(token), second],
                                    key: PassportAirportStamp.seedKey(token, transit: transit),
                                    wearKey: PassportAirportStamp.wearKey(token))
    }

    /// The code an airport's ticket prints ("PDX"): the list's IATA code or ident, else the token itself.
    func airportCode(_ token: String) -> String {
        airport(token)?.code ?? token
    }

    /// The postmark for `kind`, or nil for a special (a picture, not a postmark) or a country the stamp file has
    /// no stamp for.
    func drawing(of kind: PassportStampKind) -> PassportStampDrawing? {
        switch kind {
        case .airport(let token, let transit): airportDrawing(token, transit: transit)
        case .country(let code): countryStamp(code).map(countryDrawing)
        case .continent(let continent): continentStamp(continent)
        case .ocean(let ocean): oceanStamp(ocean)
        case .sea(let token): seaStamp(token)
        case .special: nil
        }
    }

    /// `kind`'s light-mode ink (a special's date box is gold, `#9A6E14`, as the mockup draws it).
    func ink(of kind: PassportStampKind) -> UInt32 {
        switch kind {
        case .airport(let token, _): PassportAirportStamp.ink(for: token)
        case .country(let code): countryStamp(code).map { Self.hex($0.ink) } ?? 0x4A2E1C
        case .continent(let continent): continent.stampInk
        case .ocean(let ocean): ocean.stampInk
        case .sea(let token): seaInks.ink(for: token)
        case .special: 0x9A6E14
        }
    }

    /// `kind`'s name in the app's language: a country's from the stamp file, a sea's from the atlas, an airport's
    /// everyday name from the airport list ("Portland International"). On a page (`onPage`) an ocean is named in
    /// full ("Pacific Ocean").
    func name(of kind: PassportStampKind, onPage: Bool = false) -> String {
        switch kind {
        case .airport(let token, _): airport(token).map { PassportNames.airport($0) } ?? token
        case .country(let code): countryStamp(code).map { PassportNames.country($0) } ?? code.uppercased()
        case .continent(let continent): String(localized: continent.passportName)
        case .ocean(let ocean): String(localized: onPage ? ocean.passportFullName : ocean.passportName)
        case .sea(let token): sea(token).map { PassportNames.sea($0) } ?? ""
        case .special(let allOceans): String(localized: PassportCopy.specialName(allOceans: allOceans))
        }
    }

    /// `kind`'s name in the index: an airport's without "International" or "Airport" ("Portland", "Heathrow"),
    /// every other as its page names it.
    func indexName(of kind: PassportStampKind) -> String {
        guard case .airport = kind else { return name(of: kind, onPage: true) }
        return PassportAirportStamp.shortName(name(of: kind), spanish: FernletLanguage.app == .spanish)
    }

    /// VoiceOver's name for `kind`'s stamp: "United States, stamp", an airport's "Heathrow, LHR, stamp".
    func stampLabel(of kind: PassportStampKind) -> LocalizedStringResource {
        guard case .airport(let token, _) = kind else { return PassportCopy.stamp(named: name(of: kind)) }
        return PassportCopy.airportStamp(named: name(of: kind), code: airportCode(token))
    }

    /// VoiceOver's words for `kind`'s stamp on a page on `date`: "Canada, stamp, 2 September 2026", an airport's
    /// "Heathrow, LHR, stamp, 3 October 2026" or a layover's "Helsinki Airport, HEL, transit stamp, 21 October 2026".
    func placedLabel(of kind: PassportStampKind, on date: String) -> LocalizedStringResource {
        let name = name(of: kind, onPage: true)
        guard case .airport(let token, let transit) = kind else { return PassportCopy.placed(named: name, on: date) }
        return transit ? PassportCopy.placedTransit(named: name, code: airportCode(token), on: date)
            : PassportCopy.placedAirport(named: name, code: airportCode(token), on: date)
    }

    /// An art colour as `0xRRGGBB`.
    private static func hex(_ colour: LandmarkArtColour) -> UInt32 {
        UInt32(colour.red) << 16 | UInt32(colour.green) << 8 | UInt32(colour.blue)
    }

    /// The sea `token`, from the atlas.
    func sea(_ token: String) -> AtlasSea? {
        atlas?.sea(token: token)
    }

    /// Every sea's ink, worked out once from the atlas's seas and which of them touch (the session's table when
    /// the library was given one: the pass over the atlas's sea raster is too slow for a page turn).
    var seaInks: PassportSeaInks {
        if let seaInksState { return seaInksState }
        guard let atlas else { return PassportSeaInks(tokens: [], neighbours: [:]) }
        let neighbours = openSeaNeighbours.map { $0() } ?? atlas.seaNeighbours()
        let inks = PassportSeaInks(tokens: atlas.seas.map(\.token), neighbours: neighbours)
        seaInksState = inks
        return inks
    }

    /// `continent`'s silhouette from the atlas (empty art with no atlas: the ring alone).
    private func silhouette(_ continent: AtlasContinent) -> [[Bool]] {
        if let cached = silhouettes[continent] { return cached }
        guard let atlas else { return [] }
        let art = PassportStampArt.silhouette(continent, width: continent.silhouetteWidth, atlas: atlas)
        silhouettes[continent] = art
        return art
    }
}

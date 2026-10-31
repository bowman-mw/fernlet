import FernletFoundation
import Foundation
import WorldMapStore

/// What the passport's stamps are drawn from (World-Exploration-Spec §3; round 7's reusable pieces, held for
/// Sprout's passport redesign): the bundled atlas (through the atlas keeper, which opens it once a session), the
/// country stamps, the atlas's passport countries, the continents' silhouettes and the sea inks.
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
    private var atlasState: WorldAtlas??
    private var stampsState: WorldCountryStamps??
    private var tableState: PassportCountryTable?
    private var silhouettes: [AtlasContinent: [[Bool]]] = [:]
    private var seaInksState: PassportSeaInks?

    /// A library over the atlas `openAtlas` gives (called once, on first use), its sea inks drawn from the table
    /// `seaNeighbours` gives (called once, on the first sea; nil works it out from the atlas).
    init(openAtlas: @escaping @MainActor () -> WorldAtlas?,
         seaNeighbours: (@MainActor () -> [String: Set<String>])? = nil) {
        self.openAtlas = openAtlas
        self.openSeaNeighbours = seaNeighbours
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

    /// The postmark for `kind`, or nil for a special (a picture, not a postmark) or a country the stamp file has
    /// no stamp for.
    func drawing(of kind: PassportStampKind) -> PassportStampDrawing? {
        switch kind {
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
        case .country(let code): countryStamp(code).map { Self.hex($0.ink) } ?? 0x4A2E1C
        case .continent(let continent): continent.stampInk
        case .ocean(let ocean): ocean.stampInk
        case .sea(let token): seaInks.ink(for: token)
        case .special: 0x9A6E14
        }
    }

    /// `kind`'s name in the app's language: a country's from the stamp file, a sea's from the atlas. On a page
    /// (`onPage`) an ocean is named in full ("Pacific Ocean").
    func name(of kind: PassportStampKind, onPage: Bool = false) -> String {
        switch kind {
        case .country(let code): countryStamp(code).map { PassportNames.country($0) } ?? code.uppercased()
        case .continent(let continent): String(localized: continent.passportName)
        case .ocean(let ocean): String(localized: onPage ? ocean.passportFullName : ocean.passportName)
        case .sea(let token): sea(token).map { PassportNames.sea($0) } ?? ""
        case .special(let allOceans): String(localized: PassportCopy.specialName(allOceans: allOceans))
        }
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

import Foundation
import WorldMapStore

/// The land under the fog (World-Exploration-Spec §1): which terrain set each fog hex draws, read from the
/// bundled atlas's coastline mask, climate bands and urban boundaries, and the season it shows today in its own
/// hemisphere (``AtlasSeason``).
///
/// The atlas is public data that ships in the app, so a decoy draws the same terrain; nothing here reads the
/// person's passport or history. With no atlas (the pack missing or unreadable) there is no `WorldTerrain` and
/// the fog is today's nature fog everywhere. The season is read from ``date``, fixed when the terrain is made
/// (Home makes it once a launch), unless the DEBUG screenshot override names one.
///
/// Decoration only: nothing here is shown to VoiceOver, and it never changes which hexes are clear.
final class WorldTerrain {
    let atlas: WorldAtlas
    /// The day whose season the map shows.
    let date: Date
    let calendar: Calendar
    /// A season every seasonal hex shows instead (DEBUG screenshots only; nil in a shipping build).
    let seasonOverride: AtlasSeason?
    private let classifier: AtlasTerrainClassifier

    /// Terrain from `atlas` showing `date`'s season (read in `calendar`), or `seasonOverride` everywhere.
    init(atlas: WorldAtlas, date: Date = Date(), calendar: Calendar = .current, seasonOverride: AtlasSeason? = nil) {
        self.atlas = atlas
        self.date = date
        self.calendar = calendar
        self.seasonOverride = seasonOverride
        classifier = AtlasTerrainClassifier(atlas: atlas)
    }

    /// Home's terrain from the opened atlas, or nil with none (the fog stays today's nature fog). The DEBUG season
    /// hook (`FERNLET_UI_TEST_TERRAIN_SEASON`) fixes the season for screenshots.
    static func home(_ atlas: WorldAtlas?) -> WorldTerrain? {
        atlas.map { WorldTerrain(atlas: $0, seasonOverride: UITestSupport.terrainSeasonOverride) }
    }

    /// The hex for fog cell `cell`, read from the atlas now; `urban` says whether its centre is in an urban
    /// boundary (the memo answers that from its own short list).
    func classify(_ cell: HexCell, urban: (GeoPoint) -> Bool) -> TerrainHex {
        let point = MercatorHexGrid.centreGeo(of: cell)
        let terrain = classifier.terrain(at: point)
        let land = terrain != .water
        let season = seasonOverride ?? AtlasSeason.season(at: point.latitude, on: date, calendar: calendar)
        let plants = land ? AtlasTerrainClassifier.flora(for: terrain, climateCode: atlas.climateCode(at: point), at: point) : []
        return TerrainHex.classify(terrain: terrain, urban: land && urban(point), plants: plants,
                                   latitude: point.latitude, season: season, forced: seasonOverride != nil)
    }
}

/// One tile book's terrain answers (World-Exploration-Spec §1, "classify each hex once"): every hex is read from
/// the atlas once and kept (at most ``memoLimit``, then forgotten), so pans and redrawn tiles never ask again.
/// The urban test keeps, per 0.1° atlas cell, the short list of urban boundaries whose box meets that cell
/// (at most ``bucketLimit`` cells), instead of passing over every boundary for every hex.
final class NatureTerrainMemo {
    /// The most hexes kept before the memo starts again.
    static let memoLimit = 60_000
    /// The most atlas cells whose urban short list is kept.
    static let bucketLimit = 256

    private let classify: (HexCell, NatureTerrainMemo) -> TerrainHex
    private let urbanAreas: [AtlasPolygon]
    private let grid: AtlasGrid?
    private var hexes: [HexCell: TerrainHex] = [:]
    private var buckets: [Int: [Int]] = [:]

    /// A memo over `terrain`.
    init(terrain: WorldTerrain) {
        urbanAreas = terrain.atlas.urbanAreas
        grid = terrain.atlas.grid
        classify = { cell, memo in terrain.classify(cell, urban: memo.isUrban) }
    }

    /// A memo answering `answer` for every hex (tests: a field of one set or season).
    init(answer: @escaping (HexCell) -> TerrainHex) {
        urbanAreas = []
        grid = nil
        classify = { cell, _ in answer(cell) }
    }

    /// The hex `cell` draws as.
    func hex(_ cell: HexCell) -> TerrainHex {
        if let known = hexes[cell] { return known }
        if hexes.count >= Self.memoLimit { hexes.removeAll(keepingCapacity: true) }
        let found = classify(cell, self)
        hexes[cell] = found
        return found
    }

    /// Whether `point` lies inside an urban boundary, testing only the boundaries whose box meets its atlas cell.
    func isUrban(_ point: GeoPoint) -> Bool {
        guard let grid, point.isValid else { return false }
        let spot = grid.spot(of: point), index = grid.index(row: spot.row, col: spot.col)
        let candidates = buckets[index] ?? bucket(row: spot.row, col: spot.col, grid: grid, index: index)
        return candidates.contains { urbanAreas.indices.contains($0) && urbanAreas[$0].contains(point) }
    }

    /// The boundaries whose box meets atlas cell (`row`, `col`), kept under `index`. Bounded: one pass over the
    /// pack's boundaries (capped at decode).
    private func bucket(row: Int, col: Int, grid: AtlasGrid, index: Int) -> [Int] {
        let unit = AtlasPolygon.unitsPerDegree, step = grid.step
        let north = (90 - Double(row) * step) * unit, south = north - step * unit
        let west = (-180 + Double(col) * step) * unit, east = west + step * unit
        let found = urbanAreas.indices.filter { at in
            let area = urbanAreas[at]
            return Double(area.minLon) <= east && Double(area.maxLon) >= west && Double(area.minLat) <= north
                && Double(area.maxLat) >= south
        }
        if buckets.count >= Self.bucketLimit { buckets.removeAll(keepingCapacity: true) }
        buckets[index] = found
        return found
    }
}

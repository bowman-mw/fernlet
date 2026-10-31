import Foundation
import Synchronization
import WorldMapStore

/// The land under the fog (World-Exploration-Spec §1): which terrain set each fog hex draws, read from the
/// bundled atlas's coastline mask, climate bands and urban boundaries, and the season it shows today in its own
/// hemisphere (``AtlasSeason``).
///
/// An immutable, `Sendable` snapshot made on the main actor (``home(_:)``) and read anywhere after: classifying a
/// hex is a pure function of the snapshot, so tile drawing may run off the main actor. The atlas is public data
/// that ships in the app, so a decoy draws the same terrain; nothing here reads the person's passport or history.
/// With no atlas (the pack missing or unreadable) there is no snapshot and the fog is today's nature fog. The
/// season is read from ``date`` in ``calendar``, both fixed when the snapshot is made (Home makes it once a
/// launch), unless the DEBUG screenshot override names one. ``generation`` tells two snapshots apart.
///
/// Decoration only: nothing here is shown to VoiceOver, and it never changes which hexes are clear.
nonisolated struct NatureFogTerrain: Sendable, Equatable {
    let atlas: WorldAtlas
    let classifier: AtlasTerrainClassifier
    /// The day whose season the map shows.
    let date: Date
    let calendar: Calendar
    /// A season every seasonal hex shows instead (DEBUG screenshots only; nil in a shipping build).
    let seasonOverride: AtlasSeason?
    /// Which snapshot this is: a new one is a new generation, and the fog's tiles redraw.
    let generation: Int

    /// Terrain from `atlas` showing `date`'s season (read in `calendar`), or `seasonOverride` everywhere.
    init(atlas: WorldAtlas, date: Date = Date(), calendar: Calendar = .current, seasonOverride: AtlasSeason? = nil,
         generation: Int = 1) {
        self.atlas = atlas
        classifier = AtlasTerrainClassifier(atlas: atlas)
        self.date = date
        self.calendar = calendar
        self.seasonOverride = seasonOverride
        self.generation = generation
    }

    /// Home's terrain from the opened atlas, or nil with none (the fog stays today's nature fog). The DEBUG season
    /// hook (`FERNLET_UI_TEST_TERRAIN_SEASON`) fixes the season for screenshots.
    @MainActor
    static func home(_ atlas: WorldAtlas?) -> NatureFogTerrain? {
        atlas.map { NatureFogTerrain(atlas: $0, seasonOverride: UITestSupport.terrainSeasonOverride) }
    }

    /// Two snapshots are the same terrain when they are the same generation showing the same season.
    static func == (lhs: NatureFogTerrain, rhs: NatureFogTerrain) -> Bool {
        lhs.generation == rhs.generation && lhs.date == rhs.date && lhs.calendar == rhs.calendar
            && lhs.seasonOverride == rhs.seasonOverride
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

/// The terrain answers of one snapshot (World-Exploration-Spec §1, "classify each hex once"): every hex is read
/// from the snapshot once and kept (at most ``memoLimit``, then forgotten). The urban test keeps, per 0.1° atlas
/// cell, the short list of urban boundaries whose box meets that cell (at most ``bucketLimit`` cells), instead of
/// passing over every boundary for every hex.
///
/// **Shared** (perf review 2026-10-31): a hex's land is a pure function of the snapshot and the hex — the hex grid
/// is the same at every fog scale — so the fog view hands one memo to every painter of every scale's book. A zoom
/// no longer reads every hex's land again (the urban point-in-polygon test was 73 % of the map's CPU in a pinch).
/// Both dictionaries sit behind one `Mutex`; a hex two painters miss together is classified twice
/// and kept once, which is harmless because both answers are the same.
nonisolated final class NatureTerrainMemo: Sendable {
    /// The most hexes kept before the memo starts again.
    static let memoLimit = 60_000
    /// The most atlas cells whose urban short list is kept.
    static let bucketLimit = 256

    /// The snapshot this memo answers for; nil for a test memo with a fixed answer.
    let terrain: NatureFogTerrain?
    private let classify: @Sendable (HexCell, NatureTerrainMemo) -> TerrainHex
    private let urbanAreas: [AtlasPolygon]
    private let grid: AtlasGrid?
    private let state = Mutex(Answers())

    /// What the memo has read so far.
    private struct Answers {
        var hexes: [HexCell: TerrainHex] = [:]
        var buckets: [Int: [Int]] = [:]
    }

    /// A memo over `terrain`.
    init(terrain: NatureFogTerrain) {
        self.terrain = terrain
        urbanAreas = terrain.atlas.urbanAreas
        grid = terrain.atlas.grid
        classify = { cell, memo in terrain.classify(cell, urban: memo.isUrban) }
    }

    /// A memo answering `answer` for every hex (tests: a field of one set or season).
    init(answer: @escaping @Sendable (HexCell) -> TerrainHex) {
        terrain = nil
        urbanAreas = []
        grid = nil
        classify = { cell, _ in answer(cell) }
    }

    /// How many hexes the memo holds (tests: proof two books read one memo).
    var knownHexCount: Int { state.withLock { $0.hexes.count } }

    /// The hex `cell` draws as.
    func hex(_ cell: HexCell) -> TerrainHex {
        if let known = state.withLock({ $0.hexes[cell] }) { return known }
        let found = classify(cell, self)
        state.withLock { answers in
            if answers.hexes.count >= Self.memoLimit { answers.hexes.removeAll(keepingCapacity: true) }
            answers.hexes[cell] = found
        }
        return found
    }

    /// Whether `point` lies inside an urban boundary, testing only the boundaries whose box meets its atlas cell.
    func isUrban(_ point: GeoPoint) -> Bool {
        guard let grid, point.isValid else { return false }
        let spot = grid.spot(of: point), index = grid.index(row: spot.row, col: spot.col)
        let candidates = state.withLock { $0.buckets[index] } ?? bucket(row: spot.row, col: spot.col, grid: grid, index: index)
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
        state.withLock { answers in
            if answers.buckets.count >= Self.bucketLimit { answers.buckets.removeAll(keepingCapacity: true) }
            answers.buckets[index] = found
        }
        return found
    }
}

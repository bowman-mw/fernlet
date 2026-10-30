import Foundation
import Observation
import WorldMapStore

/// The atlas's land mask at half a degree (the mockup's `LAND05`), built once when the world view opens, for
/// the far levels' faint land and sea: 720 × 360 cells, each land when the atlas puts land at its centre.
nonisolated struct WorldViewLandRaster: Sendable {
    /// Degrees on a cell's side.
    static let step = 0.5
    /// Columns, west to east from 180°W.
    static let columns = 720
    /// Rows, north to south from 90°N.
    static let rows = 360

    /// Every cell, row by row: whether it is land.
    private let land: [Bool]

    /// The raster of `atlas`. Bounded: exactly ``columns`` × ``rows`` lookups, each one constant time.
    init(atlas: WorldAtlas) {
        var land = [Bool](repeating: false, count: Self.columns * Self.rows)
        for row in 0..<Self.rows {
            let latitude = 90 - (Double(row) + 0.5) * Self.step
            for col in 0..<Self.columns {
                let longitude = -180 + (Double(col) + 0.5) * Self.step
                land[row * Self.columns + col] = atlas.isLand(at: GeoPoint(latitude, longitude))
            }
        }
        self.land = land
    }

    /// Whether the cell under `point` is land (latitude clamped, longitude wrapped).
    func isLand(at point: GeoPoint) -> Bool {
        guard point.latitude.isFinite, point.longitude.isFinite else { return false }
        let row = min(max(Int(((90 - point.latitude) / Self.step).rounded(.down)), 0), Self.rows - 1)
        let shifted = (point.longitude + 180) / Self.step
        let col = ((Int(shifted.rounded(.down)) % Self.columns) + Self.columns) % Self.columns
        return land[row * Self.columns + col]
    }
}

/// The world view's caches (World-Exploration-Spec §2; Power of 10: bounded, per level, drawn only on screen).
///
/// - the hexes each level's grid has uncovered (``WorldViewHexGrid/uncovered(by:)`` over the lifted fog),
///   computed once off the main actor;
/// - the land: the half-degree raster for World and Country, and for State and City the atlas's own mask at
///   each hex's centre, kept per hex;
/// - the place each land hex is in (its country, or from State in its plate group), looked up off the main
///   actor for the hexes on screen and kept per hex, for the lines on hex edges and the state labels;
/// - each level's city markers (``WorldViewCluster``).
@MainActor
@Observable
final class WorldViewModel {
    /// The most hexes a level's land or place cache keeps before it starts afresh.
    static let maxCachedHexes = 120_000

    /// What the view draws.
    private(set) var content = WorldViewContent.empty
    /// Whether ``load(_:)`` has run.
    private(set) var isLoaded = false
    /// The hexes each level has uncovered (empty until computed, and always in a decoy).
    private(set) var found: [AtlasZoomLevel: Set<HexCell>] = [:]
    /// The half-degree land mask, once built.
    private(set) var raster: WorldViewLandRaster?
    /// Moves each time looked-up places arrive, so the map redraws its lines.
    private(set) var placeGeneration = 0

    @ObservationIgnored private var landCache: [AtlasZoomLevel: [HexCell: Bool]] = [:]
    @ObservationIgnored private var placeCache: [AtlasZoomLevel: [HexCell: AtlasPlaceName?]] = [:]
    @ObservationIgnored private var clusterCache: [AtlasZoomLevel: [WorldViewCluster]] = [:]
    @ObservationIgnored private var placeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPlaces: (hexes: [HexCell], level: AtlasZoomLevel)?

    /// Takes `content` (once; later calls do nothing).
    func load(_ newContent: WorldViewContent) {
        guard !isLoaded else { return }
        content = newContent
        isLoaded = true
    }

    /// Computes the uncovered hexes and the land raster off the main actor (once each).
    func prepare() async {
        if found.isEmpty, !content.liftedCells.isEmpty {
            let cells = content.liftedCells
            found = await Task.detached(priority: .userInitiated) {
                var sets: [AtlasZoomLevel: Set<HexCell>] = [:]
                for level in AtlasZoomLevel.allCases { sets[level] = level.hexGrid.uncovered(by: cells) }
                return sets
            }.value
        }
        if raster == nil, let atlas = content.atlas {
            raster = await Task.detached(priority: .userInitiated) { WorldViewLandRaster(atlas: atlas) }.value
        }
    }

    /// Ends the place lookups (the page going away).
    func stop() {
        placeTask?.cancel()
        placeTask = nil
        pendingPlaces = nil
    }

    // MARK: Per hex

    /// Whether `hex` of `level` is uncovered.
    func isFound(_ hex: HexCell, at level: AtlasZoomLevel) -> Bool {
        found[level]?.contains(hex) ?? false
    }

    /// Whether `hex` (drawn at the unwrapped Mercator centre `x`, `y`) of `level` is land.
    func isLand(_ hex: HexCell, x: Double, y: Double, at level: AtlasZoomLevel) -> Bool {
        let point = WebMercator.geo(x: WorldViewCamera.wrap(x), y: y)
        if level <= .country, let raster { return raster.isLand(at: point) }
        if let known = landCache[level]?[hex] { return known }
        let land = content.atlas?.isLand(at: point) ?? false
        if landCache[level, default: [:]].count >= Self.maxCachedHexes { landCache[level] = [:] }
        landCache[level, default: [:]][hex] = land
        return land
    }

    /// The place `hex` of `level` is in: `.some(nil)` when looked up and none (the sea, unclaimed land), nil
    /// while not looked up yet.
    func place(of hex: HexCell, at level: AtlasZoomLevel) -> AtlasPlaceName?? {
        guard let cache = placeCache[level], let entry = cache[hex] else { return nil }
        return .some(entry)
    }

    /// Whether `hex`'s place at `level` has been looked up.
    func isKnown(_ hex: HexCell, at level: AtlasZoomLevel) -> Bool {
        placeCache[level]?.keys.contains(hex) ?? false
    }

    /// Looks up, off the main actor, the places of the land hexes in `hexes` of `level` not yet known (at most
    /// ``WorldViewPlaces/maxBatch``), then redraws. One lookup runs at a time; a request while one runs waits for it, the
    /// newest request kept.
    func requestPlaces(for hexes: [WorldViewVisibleHex], at level: AtlasZoomLevel) {
        guard level.showsCountryLines, content.atlas != nil else { return }
        var missing: [HexCell] = [], seen = Set<HexCell>()
        // Bounded: the hexes on screen (WorldViewCamera.maxVisibleHexes), and maxBatch kept.
        for hex in hexes where missing.count < WorldViewPlaces.maxBatch && !isKnown(hex.cell, at: level) {
            guard seen.insert(hex.cell).inserted, isLand(hex.cell, x: hex.x, y: hex.y, at: level) else { continue }
            missing.append(hex.cell)
        }
        guard !missing.isEmpty else { return }
        guard placeTask == nil else { pendingPlaces = (missing, level); return }
        runLookup(missing, at: level)
    }

    /// Runs one lookup batch and, when it lands, the newest waiting request.
    private func runLookup(_ cells: [HexCell], at level: AtlasZoomLevel) {
        guard let atlas = content.atlas else { return }
        placeTask = Task { [weak self] in
            let looked = await Task.detached(priority: .userInitiated) {
                WorldViewPlaces.lookUp(cells, in: level.hexGrid, atlas: atlas, countryOnly: !level.showsAdmin1Lines)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.merge(looked, at: level)
        }
    }

    /// Keeps `looked` and starts the waiting request, if any.
    private func merge(_ looked: [(HexCell, AtlasPlaceName?)], at level: AtlasZoomLevel) {
        if placeCache[level, default: [:]].count + looked.count > Self.maxCachedHexes { placeCache[level] = [:] }
        for (cell, place) in looked { placeCache[level, default: [:]][cell] = .some(place) }
        placeGeneration &+= 1
        placeTask = nil
        guard let pending = pendingPlaces else { return }
        pendingPlaces = nil
        let still = pending.hexes.filter { !isKnown($0, at: pending.level) }
        if !still.isEmpty { runLookup(still, at: pending.level) }
    }

    // MARK: Markers

    /// The city markers at `level`, computed once a level.
    func clusters(at level: AtlasZoomLevel) -> [WorldViewCluster] {
        if let cached = clusterCache[level] { return cached }
        let made = WorldViewCluster.clusters(of: content.pins, at: level)
        clusterCache[level] = made
        return made
    }
}

/// The place lookups the model runs off the main actor.
nonisolated enum WorldViewPlaces {
    /// The most hex places one lookup batch reads.
    static let maxBatch = 6_000

    /// The place of each of `cells` of `grid`: the country alone when `countryOnly` (the Country level),
    /// else the plate group and the country (``WorldAtlas/placeName(at:)``). Each hex is read at its centre,
    /// wrapped onto the globe. Bounded: at most ``maxBatch`` cells.
    static func lookUp(_ cells: [HexCell], in grid: WorldViewHexGrid, atlas: WorldAtlas,
                       countryOnly: Bool) -> [(HexCell, AtlasPlaceName?)] {
        cells.prefix(maxBatch).map { cell in
            let centre = grid.centre(of: cell)
            let point = WebMercator.geo(x: WorldViewCamera.wrap(centre.x), y: centre.y)
            guard countryOnly else { return (cell, atlas.placeName(at: point)) }
            return (cell, atlas.country(at: point).map { AtlasPlaceName(countryCode: $0.code) })
        }
    }
}

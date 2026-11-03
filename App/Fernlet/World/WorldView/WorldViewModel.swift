import Foundation
import Observation
import WorldMapStore

/// The land at half a degree (the mockup's `LAND05`), built once when the world view opens, for the far levels' faint
/// land and sea: 720 × 360 cells. The hexes read ``isLand(at:)``: with a shore mask a cell is land at a share of
/// ``WorldShoreMask/landShareThreshold`` or more (so the Great Lakes and Finland's lakes read as water, and no tile is
/// opened), and without one when the atlas puts land at its centre. The lines read ``atlasIsLand(at:)``, always the
/// atlas's, whose lakes are land: a country line through Lake Superior stays where it was.
nonisolated struct WorldViewLandRaster: Sendable {
    /// Degrees on a cell's side.
    static let step = 0.5
    /// Columns, west to east from 180°W.
    static let columns = 720
    /// Rows, north to south from 90°N.
    static let rows = 360

    /// Every cell, row by row: whether its hexes draw land.
    private let drawn: [Bool]
    /// Every cell, row by row: whether the atlas puts land at its centre.
    private let atlasLand: [Bool]

    /// The raster of `atlas`, drawing `shore`'s land when there is one. Bounded: exactly ``columns`` × ``rows`` lookups
    /// of each, each one constant time.
    init(atlas: WorldAtlas, shore: WorldShoreMask? = nil) {
        let fromAtlas = Self.cells { atlas.isLand(at: $0) }
        atlasLand = fromAtlas
        drawn = shore.map { mask in Self.cells { mask.landShare(at: $0) >= WorldShoreMask.landShareThreshold } } ?? fromAtlas
    }

    /// Whether `isLand` holds at each cell's centre, row by row. Bounded: ``columns`` × ``rows`` reads.
    private static func cells(_ isLand: (GeoPoint) -> Bool) -> [Bool] {
        var land = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            let latitude = 90 - (Double(row) + 0.5) * step
            for col in 0..<columns {
                let longitude = -180 + (Double(col) + 0.5) * step
                land[row * columns + col] = isLand(GeoPoint(latitude, longitude))
            }
        }
        return land
    }

    /// Whether the cell under `point` draws land (latitude clamped, longitude wrapped).
    func isLand(at point: GeoPoint) -> Bool {
        Self.index(of: point).map { drawn[$0] } ?? false
    }

    /// Whether the atlas puts land at the centre of the cell under `point` (latitude clamped, longitude wrapped).
    func atlasIsLand(at point: GeoPoint) -> Bool {
        Self.index(of: point).map { atlasLand[$0] } ?? false
    }

    /// The cell under `point`, nil when it isn't finite.
    private static func index(of point: GeoPoint) -> Int? {
        guard point.latitude.isFinite, point.longitude.isFinite else { return nil }
        let row = min(max(Int(((90 - point.latitude) / step).rounded(.down)), 0), rows - 1)
        let shifted = (point.longitude + 180) / step
        let col = ((Int(shifted.rounded(.down)) % columns) + columns) % columns
        return row * columns + col
    }
}

/// The world view's caches (World-Exploration-Spec §2; Power of 10: bounded, per hex detail, drawn only on screen).
///
/// - the hexes each detail's grid has uncovered (``WorldViewHexGrid/uncovered(by:)`` over the lifted fog),
///   computed once off the main actor;
/// - the land its hexes draw: the half-degree raster for World and Country, and for State and City the shore mask
///   (``WorldViewMapFacts/shoreLand(_:samples:x:y:)``; without a mask the atlas's own at each hex's centre), kept per hex;
/// - the place each land hex is in (its country, or from State in its plate group), looked up off the main
///   actor for the hexes on screen and kept per hex, for the lines on hex edges and the state labels;
/// - each detail's hexes on found airports' grounds, and their runways (``WorldViewAirportTiles``);
/// - each detail's city markers (``WorldViewCluster``) and where their labels stand (``WorldViewLabelPlacement``),
///   worked out once off the main actor;
/// - the major roads the lifted fog has crossed (``AtlasRoadCrossings``), worked out once off the main actor and
///   drawn whole on the uncovered hexes (World-Exploration-Spec §2: "on the world view").
@MainActor
@Observable
final class WorldViewModel {
    /// The most hexes a detail's land or place cache keeps before it starts afresh.
    nonisolated static let maxCachedHexes = 120_000

    /// What the view draws.
    private(set) var content = WorldViewContent.empty
    /// Whether ``load(_:)`` has run.
    private(set) var isLoaded = false
    /// The hexes each detail has uncovered (empty until computed, and always in a decoy).
    private(set) var found: [AtlasZoomDetail: Set<HexCell>] = [:]
    /// The half-degree land mask, once built.
    private(set) var raster: WorldViewLandRaster?
    /// Moves each time looked-up places arrive, so the map redraws its lines.
    private(set) var placeGeneration = 0
    /// The crossed roads (none until computed, and always none in a decoy, whose content has no lifted fog).
    private(set) var roads = WorldRoadDrawing.none
    /// Each detail's hexes on found airports' grounds (empty until computed, and always in a decoy).
    private(set) var airportCells: [AtlasZoomDetail: Set<HexCell>] = [:]
    /// Each detail's markers with where their labels stand (empty until worked out).
    private(set) var markerPlans: [AtlasZoomDetail: WorldViewMarkerPlan] = [:]

    @ObservationIgnored private var landCache: [AtlasZoomDetail: [HexCell: Bool]] = [:]
    @ObservationIgnored private var placeCache: [AtlasZoomDetail: [HexCell: AtlasPlaceName?]] = [:]
    @ObservationIgnored private var clusterCache: [AtlasZoomDetail: [WorldViewCluster]] = [:]
    @ObservationIgnored private var placeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPlaces: (hexes: [HexCell], detail: AtlasZoomDetail)?

    /// The found airports' runways.
    private var runways: [WorldViewRunway] { WorldViewAirportTiles.runways(of: content.flights.grounds) }

    /// Whether the hexes draw OpenStreetMap's data, so the map must credit it: true once the model holds the mask.
    var drawsOpenStreetMapData: Bool { content.shore != nil }

    /// Whether a place lookup is running (a new detail's drawing waits for it, so its lines don't blink).
    var isLookingUpPlaces: Bool { placeTask != nil }

    /// A place lookup still running ends with the model (the memory wall's ML1).
    isolated deinit {
        placeTask?.cancel()
    }

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
                var sets: [AtlasZoomDetail: Set<HexCell>] = [:]
                for detail in AtlasZoomDetail.all { sets[detail] = detail.hexGrid.uncovered(by: cells) }
                return sets
            }.value
        }
        if airportCells.isEmpty, !content.flights.grounds.isEmpty {
            let grounds = content.flights.grounds
            airportCells = await Task.detached(priority: .userInitiated) {
                var sets: [AtlasZoomDetail: Set<HexCell>] = [:]
                for detail in AtlasZoomDetail.all { sets[detail] = WorldViewAirportTiles.cells(of: grounds, in: detail.hexGrid) }
                return sets
            }.value
        }
        if markerPlans.isEmpty, !content.pins.isEmpty {
            // A label keeps off an airport's tiles as it does off the rest of the found ground.
            let pins = content.pins, sets = found.merging(airportCells) { $0.union($1) }, flights = content.flights
            markerPlans = await Task.detached(priority: .userInitiated) {
                WorldViewMarkerPlan.all(pins: pins, found: sets, flights: flights)
            }.value
        }
        if raster == nil, let atlas = content.atlas {
            let shore = content.shore
            raster = await Task.detached(priority: .userInitiated) { WorldViewLandRaster(atlas: atlas, shore: shore) }.value
        }
        if roads.generation == 0, let atlas = content.atlas, !content.liftedCells.isEmpty {
            let cells = content.liftedCells
            roads = await Task.detached(priority: .userInitiated) {
                let crossed = AtlasRoadCrossings(cells: cells, atlas: atlas)
                return WorldRoadDrawing.make(roads: crossed.roads(in: atlas), generation: 1)
            }.value
        }
    }

    /// Ends the place lookups and lets the shore tiles the drawings decoded go (the page going away).
    func stop() {
        placeTask?.cancel()
        placeTask = nil
        pendingPlaces = nil
        content.shore?.forgetTiles()
    }

    // MARK: Per hex

    /// Whether `hex` of `detail` is uncovered.
    func isFound(_ hex: HexCell, at detail: AtlasZoomDetail) -> Bool {
        found[detail]?.contains(hex) ?? false
    }

    /// Whether the hex drawn at the unwrapped Mercator centre `x`, `y` of `detail` gets a place looked up: land by the
    /// atlas, whose lakes are land, as the lines and labels have always read it. Never the shore mask: this runs on
    /// the main actor and must not decode a tile. One raster or atlas read.
    func holdsPlace(x: Double, y: Double, at detail: AtlasZoomDetail) -> Bool {
        WorldViewMapFacts.holdsPlace(raster: detail.level <= .country ? raster : nil, atlas: content.atlas, x: x, y: y)
    }

    /// What a map drawing of `detail` reads, copied so it can be built off the main actor (the copies share
    /// storage until either side changes).
    func facts(at detail: AtlasZoomDetail) -> WorldViewMapFacts {
        WorldViewMapFacts(detail: detail, raster: raster, atlas: content.atlas, found: found[detail] ?? [],
                          places: placeCache[detail] ?? [:], roads: roads, lands: landCache[detail] ?? [:],
                          airports: airportCells[detail] ?? [], runways: runways, shore: content.shore)
    }

    /// Keeps the land a map drawing looked up (its copy of the cache, grown), when it still fits the cache.
    func keepLands(_ lands: [HexCell: Bool], at detail: AtlasZoomDetail) {
        guard lands.count <= Self.maxCachedHexes, lands.count > landCache[detail]?.count ?? 0 else { return }
        landCache[detail] = lands
    }

    /// The place `hex` of `detail` is in: `.some(nil)` when looked up and none (the sea, unclaimed land), nil
    /// while not looked up yet.
    func place(of hex: HexCell, at detail: AtlasZoomDetail) -> AtlasPlaceName?? {
        guard let cache = placeCache[detail], let entry = cache[hex] else { return nil }
        return .some(entry)
    }

    /// Whether `hex`'s place at `detail` has been looked up.
    func isKnown(_ hex: HexCell, at detail: AtlasZoomDetail) -> Bool {
        placeCache[detail]?.keys.contains(hex) ?? false
    }

    /// Looks up, off the main actor, the places of the land hexes in `hexes` of `detail` not yet known (at most
    /// ``WorldViewPlaces/maxBatch``), then redraws. One lookup runs at a time; a request while one runs waits for it, the
    /// newest request kept.
    func requestPlaces(for hexes: [WorldViewVisibleHex], at detail: AtlasZoomDetail) {
        guard detail.level.showsCountryLines, content.atlas != nil else { return }
        var missing: [HexCell] = [], seen = Set<HexCell>()
        // Bounded: the hexes on screen (WorldViewCamera.maxVisibleHexes), and maxBatch kept.
        for hex in hexes where missing.count < WorldViewPlaces.maxBatch && !isKnown(hex.cell, at: detail) {
            guard seen.insert(hex.cell).inserted, holdsPlace(x: hex.x, y: hex.y, at: detail) else { continue }
            missing.append(hex.cell)
        }
        guard !missing.isEmpty else { return }
        guard placeTask == nil else { pendingPlaces = (missing, detail); return }
        runLookup(missing, at: detail)
    }

    /// Runs one lookup batch and, when it lands, the newest waiting request.
    private func runLookup(_ cells: [HexCell], at detail: AtlasZoomDetail) {
        guard let atlas = content.atlas else { return }
        placeTask = Task { [weak self] in
            let looked = await Task.detached(priority: .userInitiated) {
                WorldViewPlaces.lookUp(cells, in: detail.hexGrid, atlas: atlas, countryOnly: !detail.level.showsAdmin1Lines)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.merge(looked, at: detail)
        }
    }

    /// Keeps `looked` and starts the waiting request, if any.
    private func merge(_ looked: [(HexCell, AtlasPlaceName?)], at detail: AtlasZoomDetail) {
        if placeCache[detail, default: [:]].count + looked.count > Self.maxCachedHexes { placeCache[detail] = [:] }
        for (cell, place) in looked { placeCache[detail, default: [:]][cell] = .some(place) }
        placeTask = nil
        if let pending = pendingPlaces {
            pendingPlaces = nil
            let still = pending.hexes.filter { !isKnown($0, at: pending.detail) }
            if !still.isEmpty { runLookup(still, at: pending.detail) }
        }
        placeGeneration &+= 1
    }

    // MARK: Markers

    /// The city markers at `detail`: the plan's once worked out, else computed once a detail.
    func clusters(at detail: AtlasZoomDetail) -> [WorldViewCluster] {
        if let plan = markerPlans[detail] { return plan.clusters }
        if let cached = clusterCache[detail] { return cached }
        let made = WorldViewCluster.clusters(of: content.pins, scale: detail.pointsPerMercatorUnit)
        clusterCache[detail] = made
        return made
    }

    /// Where the labels of `detail`'s markers stand, by anchor token (empty until worked out).
    func labelSpots(at detail: AtlasZoomDetail) -> [String: WorldViewLabelSpot] {
        markerPlans[detail]?.spots ?? [:]
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

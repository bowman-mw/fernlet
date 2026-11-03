import SwiftUI
import WorldMapStore

/// What one map drawing reads about the hexes, copied off the model so it can be built off the main actor:
/// the level's uncovered hexes, the land they draw (the half-degree raster at World and Country; from State in the
/// shore mask sampled over each hex, or without a mask the atlas's at its centre, kept per hex), the land the lines read
/// (always the atlas's), the places looked up so far, and the crossed roads.
nonisolated struct WorldViewMapFacts: Sendable {
    /// The hex detail the facts are for.
    let detail: AtlasZoomDetail
    /// The half-degree land mask, once built.
    let raster: WorldViewLandRaster?
    /// The atlas, for the lines' land, and for the hexes' from State in with no shore mask.
    let atlas: WorldAtlas?
    /// The shore mask, for the hexes' land from State in; nil falls back to the atlas's.
    let shore: WorldShoreMask?
    /// Where a hex of this detail is read in the shore mask, as Mercator offsets from its centre.
    private let samples: [(x: Double, y: Double)]
    /// The level's uncovered hexes.
    let found: Set<HexCell>
    /// The level's places looked up so far (``WorldViewModel/place(of:at:)``).
    let places: [HexCell: AtlasPlaceName?]
    /// The crossed roads.
    let roads: WorldRoadDrawing
    /// The hexes on found airports' grounds.
    let airports: Set<HexCell>
    /// The found airports' runways.
    let runways: [WorldViewRunway]
    /// The land the level's hexes draw, per hex: the model's cache, plus what this drawing looked up (handed back to
    /// the model).
    private(set) var lands: [HexCell: Bool]

    /// The named level the detail belongs to.
    var level: AtlasZoomLevel { detail.level }

    /// The facts of `detail`, from the model's caches.
    init(detail: AtlasZoomDetail, raster: WorldViewLandRaster?, atlas: WorldAtlas?, found: Set<HexCell>,
         places: [HexCell: AtlasPlaceName?], roads: WorldRoadDrawing, lands: [HexCell: Bool],
         airports: Set<HexCell> = [], runways: [WorldViewRunway] = [], shore: WorldShoreMask? = nil) {
        self.detail = detail
        self.raster = raster
        self.atlas = atlas
        self.shore = shore
        samples = Self.shoreSamples(in: detail.hexGrid)
        self.found = found
        self.places = places
        self.roads = roads
        self.lands = lands
        self.airports = airports
        self.runways = runways
    }

    /// Whether `hex` is uncovered.
    func isFound(_ hex: HexCell) -> Bool { found.contains(hex) }

    /// Whether `hex` (drawn at the unwrapped Mercator centre `x`, `y`) draws land; a hex not known yet is looked
    /// up and kept (the land cache stays under ``WorldViewModel/maxCachedHexes``).
    mutating func isLand(_ hex: HexCell, x: Double, y: Double) -> Bool {
        if level <= .country, let raster { return raster.isLand(at: WebMercator.geo(x: WorldViewCamera.wrap(x), y: y)) }
        if let known = lands[hex] { return known }
        let land = shore.map { Self.shoreLand($0, samples: samples, x: x, y: y) } ?? Self.atlasLand(atlas, x: x, y: y)
        if lands.count >= WorldViewModel.maxCachedHexes { lands = [:] }
        lands[hex] = land
        return land
    }

    /// Whether the hex at the unwrapped Mercator centre `x`, `y` has a place for the lines to compare (the atlas's land).
    func holdsPlace(x: Double, y: Double) -> Bool {
        Self.holdsPlace(raster: level <= .country ? raster : nil, atlas: atlas, x: x, y: y)
    }

    /// The place `hex` is in: `.some(nil)` when looked up and none, nil while not looked up yet.
    func place(of hex: HexCell) -> AtlasPlaceName?? {
        guard let entry = places[hex] else { return nil }
        return .some(entry)
    }

    /// Whether the atlas puts land at the unwrapped Mercator point (`x`, `y`); no atlas, no land.
    static func atlasLand(_ atlas: WorldAtlas?, x: Double, y: Double) -> Bool {
        atlas?.isLand(at: WebMercator.geo(x: WorldViewCamera.wrap(x), y: y)) ?? false
    }

    /// Whether the lines and labels read land at the unwrapped Mercator point (`x`, `y`): `raster`'s atlas land where
    /// the level reads the raster, else the atlas's. Never the shore mask, so no line or label moves with it.
    static func holdsPlace(raster: WorldViewLandRaster?, atlas: WorldAtlas?, x: Double, y: Double) -> Bool {
        guard let raster else { return atlasLand(atlas, x: x, y: y) }
        return raster.atlasIsLand(at: WebMercator.geo(x: WorldViewCamera.wrap(x), y: y))
    }

    /// How far out a hex's six outer samples sit, as a share of its centre-to-corner radius.
    static let shoreSampleReach = 0.6

    /// Where a hex of `grid` is read in the shore mask: its centre, then six points toward its corners.
    static func shoreSamples(in grid: WorldViewHexGrid) -> [(x: Double, y: Double)] {
        [(0, 0)] + grid.cornerOffsets.map { ($0.x * shoreSampleReach, $0.y * shoreSampleReach) }
    }

    /// Whether the hex centred on the unwrapped Mercator point (`x`, `y`) draws land: at least half of `samples` are
    /// land. A hex from State in is 3 to 18 km across, so one reading at its centre would make islands and rivers
    /// flicker in and out at random. Bounded: at most the seven samples, stopping once the count is settled.
    static func shoreLand(_ shore: WorldShoreMask, samples: [(x: Double, y: Double)], x: Double, y: Double) -> Bool {
        let needed = samples.count / 2 + samples.count % 2
        var land = 0, water = 0
        for sample in samples {
            let point = WebMercator.geo(x: WorldViewCamera.wrap(x + sample.x), y: y + sample.y)
            if shore.isLand(at: point) { land += 1 } else { water += 1 }
            if land >= needed { return true }
            if water > samples.count - needed { return false }
        }
        return false
    }
}

/// The map's hexes, lines and roads as ready paths (round 7 performance, 2026-10-31): built once for a camera
/// that sees ``margin`` points past each edge of the screen, off the main actor, and reused by every frame
/// while the map pans and pinches (``WorldViewMapCanvas`` moves and scales it with the fingers) until the view
/// drifts ``refreshDrift`` points or ``refreshScale`` of its scale from where it was built, or the hex detail, the
/// data or the colour scheme changes. Its paths are in the build camera's screen points.
nonisolated struct WorldViewMapDrawing: Sendable {
    /// Points drawn past each edge of the screen, so a pan has room before the next drawing lands.
    static let margin = 200.0
    /// How far (points) the view may drift from the build camera before a fresh drawing is asked for.
    static let refreshDrift = 60.0
    /// How far the view's scale may differ from the build camera's before a fresh drawing is asked for (scaled
    /// this little, a drawing's lines and edges look the same).
    static let refreshScale = 0.04

    /// What a drawing was built for.
    struct Key: Equatable, Sendable {
        /// The camera it was built at, ``margin`` larger than the screen on each side.
        let camera: WorldViewCamera
        /// ``WorldAtlasMapView``'s data generation.
        let generation: Int
        /// Night colours.
        let dark: Bool
    }

    /// One fill colour's hexes, with their edge colour and whether they are uncovered.
    struct HexFill: Sendable {
        let fill: UInt32, edge: UInt32
        let found: Bool
        var path: Path
    }

    /// One road kind's path.
    struct RoadPath: Sendable {
        let kind: AtlasRoadKind
        let path: Path
    }

    /// What it was built for.
    let key: Key
    /// The hexes, one path per fill colour: the fogged ones first, so the found ones' edges lie on top.
    let hexes: [HexFill]
    /// The state and province lines.
    let region: Path
    /// The country lines.
    let country: Path
    /// The uncovered hexes, which clip the roads.
    let uncovered: Path
    /// The crossed roads, one path per kind (empty where the level draws none).
    let roads: [RoadPath]
    /// The found airports' runways (empty farther out than City, where they'd be specks).
    let runways: Path

    /// The key a drawing for `screen` would have.
    static func key(for screen: WorldViewCamera, generation: Int, dark: Bool) -> Key {
        Key(camera: screen.overscanned(by: margin), generation: generation, dark: dark)
    }

    /// Whether `wanted` (the key for the camera on screen now) needs a fresh drawing: the data, the colours, the
    /// detail or the size changed, or the view drifted ``refreshDrift`` points or ``refreshScale`` of its scale
    /// from the build camera.
    func isStale(for wanted: Key) -> Bool {
        let built = key.camera, now = wanted.camera
        guard key.generation == wanted.generation, key.dark == wanted.dark, built.detail == now.detail,
              built.size == now.size, abs(now.scale / built.scale - 1) < Self.refreshScale else { return true }
        let dx = WorldViewCamera.wrappedDelta(built.x - now.x) * now.scale, dy = (built.y - now.y) * now.scale
        return abs(dx) >= Self.refreshDrift || abs(dy) >= Self.refreshDrift
    }

    /// Where this drawing goes on a screen showing `screen`: its centre, and how much it is scaled (1 unless
    /// the view zoomed since it was built and the next drawing has not landed yet).
    func placement(on screen: WorldViewCamera) -> (centre: CGPoint, scale: Double) {
        let built = key.camera
        return (screen.screenPoint(x: built.x, y: built.y), screen.scale / built.scale)
    }

    // MARK: Building

    /// Builds the drawing for `key` from `facts` (whose land cache grows with the hexes it looked up). Bounded:
    /// the hexes the build camera sees (``WorldViewCamera/maxDrawnHexes``).
    static func build(_ key: Key, facts: inout WorldViewMapFacts) -> WorldViewMapDrawing {
        let camera = key.camera
        let visible = camera.visibleHexes(limit: WorldViewCamera.maxDrawnHexes)
        let corners = cornerOffsets(camera)
        var fills: [UInt32: HexFill] = [:]
        var uncovered = Path()
        // Bounded: the hexes the build camera sees (maxDrawnHexes).
        for hex in visible {
            let land = facts.isLand(hex.cell, x: hex.x, y: hex.y), found = facts.isFound(hex.cell)
            let airport = facts.airports.contains(hex.cell)
            let ink = airport ? WorldViewInk.airport : WorldViewInk.hex(land: land, found: found, dark: key.dark)
            let outline = hexPoints(camera.screenPoint(x: hex.x, y: hex.y), corners)
            // In place: the dictionary's path is the only reference, so adding to it never copies it.
            fills[ink.fill, default: HexFill(fill: ink.fill, edge: ink.edge, found: found || airport, path: Path())].path.addLines(outline)
            fills[ink.fill]?.path.closeSubpath()
            if found {
                uncovered.addLines(outline)
                uncovered.closeSubpath()
            }
        }
        let lines = linePaths(visible, camera: camera, facts: facts)
        let ordered = fills.values.sorted { ($0.found ? 1 : 0, $0.fill) < ($1.found ? 1 : 0, $1.fill) }
        return WorldViewMapDrawing(key: key, hexes: ordered, region: lines.region, country: lines.country,
                                   uncovered: uncovered, roads: roadPaths(camera, facts: facts, uncovered: uncovered),
                                   runways: runwayPath(camera, runways: facts.runways))
    }

    /// The runways on or near the camera's view, from City in. Bounded: ``WorldViewAirportTiles`` runways.
    private static func runwayPath(_ camera: WorldViewCamera, runways: [WorldViewRunway]) -> Path {
        guard camera.level >= .city else { return Path() }
        let view = CGRect(origin: .zero, size: camera.size)
        var path = Path()
        for runway in runways {
            let start = camera.screenPoint(x: runway.startX, y: runway.startY), end = camera.screenPoint(x: runway.endX, y: runway.endY)
            let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard box.intersects(view) else { continue }
            path.move(to: start)
            path.addLine(to: end)
        }
        return path
    }

    /// The country and state lines on shared hex edges, where the level draws them.
    private static func linePaths(_ hexes: [WorldViewVisibleHex], camera: WorldViewCamera,
                                  facts: WorldViewMapFacts) -> (region: Path, country: Path) {
        guard camera.level.showsCountryLines else { return (Path(), Path()) }
        let segments = WorldViewBorders.segments(hexes, facts: facts)
        return (edgePath(segments.region, camera: camera), edgePath(segments.country, camera: camera))
    }

    /// The crossed roads per kind, where the level draws roads and some hex they may cross is uncovered.
    private static func roadPaths(_ camera: WorldViewCamera, facts: WorldViewMapFacts, uncovered: Path) -> [RoadPath] {
        guard WorldRoadStyle.showsRoads(at: camera.level), facts.roads.roadCount > 0, !uncovered.isEmpty else { return [] }
        let view = camera.viewport, centreX = view.minX + view.width / 2
        let projection = WorldRoadPainter.Projection(originX: view.minX, originY: view.minY, scale: camera.scale) { piece in
            WorldViewCamera.wrappedDelta(piece.minX - centreX) - (piece.minX - centreX)
        }
        // Bounded: the road kinds.
        return AtlasRoadKind.allCases.compactMap { kind in
            let pieces = facts.roads.pieces.filter { $0.kind == kind }
            let path = WorldRoadPainter.path(pieces, size: camera.size, projection: projection)
            return path.isEmpty ? nil : RoadPath(kind: kind, path: path)
        }
    }

    /// A path of the edge segments, in the camera's screen points.
    private static func edgePath(_ edges: [WorldViewBorders.Edge], camera: WorldViewCamera) -> Path {
        let corners = cornerOffsets(camera)
        var path = Path()
        // Bounded: the edges of the hexes the build camera sees, three each.
        for edge in edges {
            let centre = camera.screenPoint(x: edge.x, y: edge.y)
            path.move(to: CGPoint(x: centre.x + corners[edge.corner].x, y: centre.y + corners[edge.corner].y))
            path.addLine(to: CGPoint(x: centre.x + corners[edge.next].x, y: centre.y + corners[edge.next].y))
        }
        return path
    }

    /// A hex's six corners on screen around `centre`.
    private static func hexPoints(_ centre: CGPoint, _ corners: [CGPoint]) -> [CGPoint] {
        corners.map { CGPoint(x: centre.x + $0.x, y: centre.y + $0.y) }
    }

    /// The six corners of a hex on screen, as offsets from its centre.
    private static func cornerOffsets(_ camera: WorldViewCamera) -> [CGPoint] {
        let scale = camera.scale
        return camera.detail.hexGrid.cornerOffsets.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
    }
}

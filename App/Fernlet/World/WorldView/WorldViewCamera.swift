import CoreGraphics
import Foundation
import WorldMapStore

/// Where the world view looks (World-Exploration-Spec §2, "The world view"): a place on the free zoom and a
/// centre in normalised Web Mercator, for a view of a given size. Pure maths, so the page and the tests share it.
///
/// - **East–west wraps all the way round.** The centre's `x` is kept in `0..<1`; a point is drawn at its
///   nearest copy (``screenPoint(x:y:)``), and the hexes past the antimeridian are the same hexes as on the
///   other side (``canonical(_:in:)``).
/// - **North–south is clamped.** The view never shows past Mercator's square (85°N to 85°S). At **World** it is
///   clamped harder, so the poles stay at the edges (owner, answer 9: "Make antarctica touch the bottom of the
///   screen"): the top edge never comes south of ``arcticEdgeLatitude`` and the bottom edge never north of
///   ``antarcticEdgeLatitude``. On an iPhone that leaves about 50 pt of play; a screen too short for both
///   holds the band's middle. Zooming in widens that band smoothly until the whole square is open, so nothing
///   jumps on the way in or out.
/// - **Zooming** is free (owner, 2026-11-02): ``zoom`` runs from 0 (World) through 3 (City) to
///   `AtlasZoomLevel/maxZoom` and stops wherever the fingers leave it, keeping the place under a focus point (a pinch, a tapped marker) where it was. The levels
///   of `AtlasZoomLevel` are the whole numbers on it; ``detail`` picks the hexes and ``level`` the lines, the
///   plate and the zoom control's word.
nonisolated struct WorldViewCamera: Equatable, Sendable {
    /// The latitude the World view's top edge stays north of: the Arctic is always on the top edge.
    static let arcticEdgeLatitude = 72.0
    /// The latitude the World view's bottom edge stays south of: Antarctica is always on the bottom edge.
    static let antarcticEdgeLatitude = -78.0
    /// The most hexes one frame enumerates (an iPhone screen holds about 5,000 of the 10-pt hexes).
    static let maxVisibleHexes = 16_000
    /// The most hexes one map drawing enumerates: the screen and ``WorldViewMapDrawing/margin`` past each edge
    /// (about 13,000 on an iPhone, more on an iPad).
    static let maxDrawnHexes = 40_000

    /// The place on the free zoom: 0 is World, 3 is City, `AtlasZoomLevel/maxZoom` the closest.
    private(set) var zoom: Double
    /// Screen points a Mercator unit spans at this zoom (the width of the whole world, in points).
    private(set) var scale: Double
    /// The centre's Mercator `x`, in `0..<1`.
    private(set) var x: Double
    /// The centre's Mercator `y`, clamped by the rules above.
    private(set) var y: Double
    /// The view's size in points.
    private(set) var size: CGSize

    /// A camera at `level` centred on `centre` (clamped and wrapped) in a view of `size`.
    init(level: AtlasZoomLevel, centre: GeoPoint, size: CGSize) {
        let unit = WebMercator.unit(centre.isValid ? centre : GeoPoint(0, 0))
        self.zoom = Double(level.rank)
        self.scale = level.pointsPerMercatorUnit
        self.x = Self.wrap(unit.x)
        self.y = unit.y
        self.size = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        clamp()
    }

    // MARK: Reading

    /// The hexes this zoom draws.
    var detail: AtlasZoomDetail { AtlasZoomDetail(zoom: zoom) }

    /// The named level this zoom belongs to.
    var level: AtlasZoomLevel { detail.level }

    /// Whether the view can go closer.
    var canZoomIn: Bool { zoom < AtlasZoomLevel.maxZoom }

    /// Whether the view can go farther out.
    var canZoomOut: Bool { zoom > 0 }

    /// Where + or − goes from `zoom`: the next whole step along, so a free zoom lands back on the ladder. The ladder's
    /// last whole step and the closest zoom count as one stop, so no press moves the map only a little.
    static func steppedZoom(from zoom: Double, in zoomingIn: Bool) -> Double {
        let near = 0.02, lastWhole = AtlasZoomLevel.maxZoom.rounded(.down)
        if zoomingIn {
            let next = (zoom + near).rounded(.down) + 1
            return next >= lastWhole ? AtlasZoomLevel.maxZoom : next
        }
        let next = (zoom - near).rounded(.up) - 1
        return max(next >= lastWhole ? lastWhole - 1 : next, 0)
    }

    /// The place at the view's centre.
    var centre: GeoPoint { WebMercator.geo(x: x, y: y) }

    /// The latitudes at the view's top and bottom edges.
    var edgeLatitudes: (top: Double, bottom: Double) {
        let half = Double(size.height) / 2 / scale
        return (WebMercator.geo(x: 0, y: y - half).latitude, WebMercator.geo(x: 0, y: y + half).latitude)
    }

    /// What the view shows, as a Mercator rectangle (its `minX` may be negative or its right edge past 1).
    var viewport: MapViewport {
        let width = Double(size.width) / scale, height = Double(size.height) / scale
        return MapViewport(minX: x - width / 2, minY: y - height / 2, width: width, height: height)
    }

    /// Where the Mercator point (`x`, `y`) is on screen, at its copy nearest the centre.
    func screenPoint(x px: Double, y py: Double) -> CGPoint {
        CGPoint(x: Self.wrappedDelta(px - x) * scale + Double(size.width) / 2,
                y: (py - y) * scale + Double(size.height) / 2)
    }

    /// Where `point` is on screen, at its copy nearest the centre.
    func screenPoint(of point: GeoPoint) -> CGPoint {
        let unit = WebMercator.unit(point)
        return screenPoint(x: unit.x, y: unit.y)
    }

    /// The Mercator point under screen point `point` (its `x` unwrapped, so it may leave `0..<1`).
    func mercator(at point: CGPoint) -> (x: Double, y: Double) {
        (x + (Double(point.x) - Double(size.width) / 2) / scale, y + (Double(point.y) - Double(size.height) / 2) / scale)
    }

    // MARK: Moving

    /// Pans by a finger's `translation` in points (dragging right brings the west into view).
    mutating func pan(by translation: CGSize) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        x = Self.wrap(x - Double(translation.width) / scale)
        y -= Double(translation.height) / scale
        clamp()
    }

    /// Moves to `level`, keeping the place under `focus` (a screen point; nil for the centre) where it is.
    mutating func setLevel(_ newLevel: AtlasZoomLevel, focus: CGPoint? = nil) {
        setZoom(Double(newLevel.rank), focus: focus)
    }

    /// Moves to `newZoom` (held to the ladder's ends), keeping the place under `focus` (a screen point; nil for
    /// the centre) where it is.
    mutating func setZoom(_ newZoom: Double, focus: CGPoint? = nil) {
        guard newZoom.isFinite else { return }
        let anchor = focus ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let under = mercator(at: anchor)
        zoom = min(max(newZoom, 0), AtlasZoomLevel.maxZoom)
        scale = AtlasZoomLevel.pointsPerMercatorUnit(atZoom: zoom)
        x = Self.wrap(under.x - (Double(anchor.x) - Double(size.width) / 2) / scale)
        y = under.y - (Double(anchor.y) - Double(size.height) / 2) / scale
        clamp()
    }

    /// Centres on `point` (wrapped and clamped).
    mutating func centre(on point: GeoPoint) {
        guard point.isValid else { return }
        let unit = WebMercator.unit(point)
        x = Self.wrap(unit.x)
        y = unit.y
        clamp()
    }

    /// Follows a new view size (a rotation, a Dynamic Type change does not), keeping the centre.
    mutating func resize(to newSize: CGSize) {
        guard newSize.width >= 1, newSize.height >= 1, newSize != size else { return }
        size = newSize
        clamp()
    }

    /// The same view grown by `margin` points on every side, keeping the centre (not clamped again, so it
    /// shows exactly what this camera shows, and more round it).
    func overscanned(by margin: Double) -> WorldViewCamera {
        guard margin.isFinite, margin > 0 else { return self }
        var grown = self
        grown.size = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        return grown
    }

    /// The range the centre's `y` may take at this zoom in this view: round the poles' band's middle, by how far
    /// the view is taller than the band at World, and by how far it is shorter once zoomed in (twice that, so the
    /// whole square opens soon after the view stops holding both poles).
    var yRange: ClosedRange<Double> {
        let height = Double(size.height) / scale, half = height / 2
        let north = WebMercator.unit(GeoPoint(Self.arcticEdgeLatitude, 0)).y
        let south = WebMercator.unit(GeoPoint(Self.antarcticEdgeLatitude, 0)).y
        let band = south - north, middle = (north + south) / 2
        if zoom == 0, height < band { return middle...middle }
        let spread = height >= band ? (height - band) / 2 : (band - height) * 2
        let lower = max(half, middle - spread), upper = min(1 - half, middle + spread)
        guard lower <= upper else { return 0.5...0.5 }
        return lower...upper
    }

    /// Holds `y` inside ``yRange``.
    private mutating func clamp() {
        let range = yRange
        y = y.isFinite ? min(max(y, range.lowerBound), range.upperBound) : 0.5
    }

    // MARK: Wrapping

    /// `x` wrapped into `0..<1` (a non-finite value becomes 0).
    static func wrap(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        let wrapped = x - x.rounded(.down)
        return wrapped >= 1 ? 0 : wrapped
    }

    /// A Mercator `x` difference wrapped into `-0.5..<0.5`: the short way round.
    static func wrappedDelta(_ dx: Double) -> Double {
        guard dx.isFinite else { return 0 }
        return wrap(dx + 0.5) - 0.5
    }

    /// The hex of `grid` that holds the wrapped copy of the Mercator point (`x`, `y`): the one ID a hex has
    /// however many turns east or west it is drawn.
    static func canonical(_ point: (x: Double, y: Double), in grid: WorldViewHexGrid) -> HexCell {
        grid.cell(x: wrap(point.x), y: point.y)
    }
}

nonisolated extension WorldViewCamera {
    /// A smooth move from one camera to a new zoom and, if given, a new centre (the zoom control and a marker's tap).
    /// The zoom is already on a ratio scale, so a steady change of it looks steady on screen.
    struct Glide: Sendable {
        /// How many steps a glide takes.
        static let frameCount = 20
        /// How long each step lasts.
        static let frameMilliseconds = 16

        let from: WorldViewCamera
        let toZoom: Double
        /// Where the view ends up centred, or nil to keep its centre.
        let centre: GeoPoint?

        /// The camera `progress` (0 to 1) of the way along, easing out.
        func camera(at progress: Double) -> WorldViewCamera {
            let t = min(max(progress, 0), 1), eased = 1 - (1 - t) * (1 - t)
            var moved = from
            moved.setZoom(from.zoom + (toZoom - from.zoom) * eased)
            guard let centre else { return moved }
            let unit = WebMercator.unit(centre)
            let x = from.x + WorldViewCamera.wrappedDelta(unit.x - from.x) * eased, y = from.y + (unit.y - from.y) * eased
            moved.centre(on: WebMercator.geo(x: WorldViewCamera.wrap(x), y: y))
            return moved
        }
    }
}

/// One hex the view shows: its ID (``WorldViewCamera/canonical(_:in:)``) and the centre it is drawn at.
nonisolated struct WorldViewVisibleHex: Sendable {
    /// The hex's one ID.
    let cell: HexCell
    /// Its centre in unwrapped Mercator units (as drawn this frame).
    let x: Double, y: Double
}

nonisolated extension WorldViewCamera {
    /// The detail's hexes that touch the view, with `margin` hexes more on each side, row by row. Bounded: at
    /// most `limit` (``maxVisibleHexes``; a map drawing passes ``maxDrawnHexes``).
    func visibleHexes(margin: Int = 1, limit: Int = maxVisibleHexes) -> [WorldViewVisibleHex] {
        let grid = detail.hexGrid, cap = min(max(limit, 0), Self.maxDrawnHexes)
        let radius = grid.radius, across = 3.0.squareRoot() * radius
        guard radius > 0, radius.isFinite else { return [] }
        let view = viewport, pad = Double(max(margin, 0) + 1) * across
        let firstRow = Int(((view.minY - pad) / (1.5 * radius)).rounded(.down))
        let lastRow = Int(((view.minY + view.height + pad) / (1.5 * radius)).rounded(.up))
        guard lastRow >= firstRow, lastRow - firstRow < cap else { return [] }
        var hexes: [WorldViewVisibleHex] = []
        hexes.reserveCapacity(min(cap, 16_000))
        // Bounded: the rows on screen, and `limit` in all.
        for r in firstRow...lastRow {
            let shift = Double(r) / 2
            let firstQ = Int(((view.minX - pad) / across - shift).rounded(.down))
            let lastQ = Int(((view.minX + view.width + pad) / across - shift).rounded(.up))
            guard lastQ >= firstQ else { continue }
            for q in firstQ...lastQ {
                guard hexes.count < cap else { return hexes }
                let cx = across * (Double(q) + shift), cy = 1.5 * radius * Double(r)
                hexes.append(WorldViewVisibleHex(cell: Self.canonical((cx, cy), in: grid), x: cx, y: cy))
            }
        }
        return hexes
    }
}

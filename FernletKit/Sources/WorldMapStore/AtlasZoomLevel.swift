import CoreGraphics
import Foundation

// The world view's zoom ladder and its hexes (World-Exploration-Spec, "The world view", answers 9 and 13):
// World → Country → State → City, City the closest; country lines from Country, state and province lines
// from State, no county lines ever; the plate names the place from State in; the hexes stay the same size on
// screen at every level, and a hex is uncovered when any fog under it is lifted. Rules only: the screen
// draws them.

/// One of the world view's four zoom levels (a frozen token).
///
/// Each level's scale is ``pointsPerDegreeOfLatitude``, measured at ``referenceLatitude`` (45°, where the
/// fog grid has its reference size and the mockup's City view, Portland, sits). The two ends come from the
/// mockup (`World-Exploration-mockup.js`): **World** is `worldFull`'s `k = H / 176`, 874 pt for 176° of
/// latitude (86°N to the South Pole on an iPhone), about 4.97 pt a degree; **City** is `worldZoom`'s
/// `k = 360`, 360 pt a degree, about 270 km top to bottom. The mockup gives no scale for Country or State, so
/// they sit on a geometric ladder between the two: each level ``stepRatio`` (about 4.17) times the one
/// below, so Country is about 20.7 and State about 86.3 pt a degree.
public nonisolated enum AtlasZoomLevel: String, CaseIterable, Codable, Comparable, Sendable {
    case world, country, state, city

    /// The World level's scale: the mockup's 874 pt for 176° of latitude.
    public static let worldPointsPerDegree = 874.0 / 176.0
    /// The City level's scale: 360 pt a degree of latitude (owner, answer 13: the closest the world view goes).
    public static let cityPointsPerDegree = 360.0
    /// The scale between neighbouring levels: the cube root of City over World.
    public static let stepRatio = pow(cityPointsPerDegree / worldPointsPerDegree, 1.0 / 3.0)
    /// The latitude where a level's points per degree of latitude hold exactly (the fog grid's
    /// ``MercatorHexGrid/referenceLatitude``). Mercator stretches latitude away from it, as every map does.
    public static let referenceLatitude = MercatorHexGrid.referenceLatitude

    /// The level's place on the ladder, 0 (World) to 3 (City).
    public var rank: Int {
        switch self {
        case .world: 0
        case .country: 1
        case .state: 2
        case .city: 3
        }
    }

    /// Levels compare by ``rank``: World is the farthest out.
    public static func < (lhs: AtlasZoomLevel, rhs: AtlasZoomLevel) -> Bool { lhs.rank < rhs.rank }

    /// Screen points a degree of latitude spans at ``referenceLatitude``: exactly 360 at City, each level
    /// out ``stepRatio`` times fewer.
    public var pointsPerDegreeOfLatitude: Double {
        Self.cityPointsPerDegree / pow(Self.stepRatio, Double(AtlasZoomLevel.city.rank - rank))
    }

    /// Screen points a normalised Web Mercator unit spans at this level (the same everywhere on the map, so
    /// the hexes stay regular and the same size on screen).
    public var pointsPerMercatorUnit: Double {
        let unitsPerDegree = GeoPoint.metresPerDegree * WebMercator.unitsPerMetre(at: Self.referenceLatitude)
        return pointsPerDegreeOfLatitude / unitsPerDegree
    }

    /// The next level in, or nil at City (the + control is dimmed there).
    public var zoomedIn: AtlasZoomLevel? { Self.allCases.first { $0.rank == rank + 1 } }
    /// The next level out, or nil at World (the − control is dimmed there).
    public var zoomedOut: AtlasZoomLevel? { Self.allCases.first { $0.rank == rank - 1 } }
    /// Whether + is available: everywhere but City.
    public var canZoomIn: Bool { zoomedIn != nil }
    /// Whether − is available: everywhere but World.
    public var canZoomOut: Bool { zoomedOut != nil }
    /// Whether the country lines show: from Country in.
    public var showsCountryLines: Bool { self >= .country }
    /// Whether the state and province lines show: from State in. There are no county lines at any level.
    public var showsAdmin1Lines: Bool { self >= .state }
    /// Whether the plate names the place ("Oregon · United States"): from State in.
    public var showsPlaceName: Bool { self >= .state }

    /// The world-view hex grid at this level.
    public var hexGrid: WorldViewHexGrid { WorldViewHexGrid(level: self) }

    /// The viewport this level shows in a view of `size`, centred on `centre`.
    public func viewport(centredOn centre: GeoPoint, size: CGSize) -> MapViewport {
        let mid = WebMercator.unit(centre)
        let scale = pointsPerMercatorUnit
        let width = Double(max(size.width, 1)) / scale, height = Double(max(size.height, 1)) / scale
        return MapViewport(minX: mid.x - width / 2, minY: mid.y - height / 2, width: width, height: height)
    }
}

/// The world view's hexes at one zoom level: regular pointy-top hexagons over Web Mercator, the same
/// axial layout and rounding as the fog's ``MercatorHexGrid``, sized so a hex is ``hexAcrossPoints`` across
/// (flat side to flat side) on screen at its level. At City that is about 3.1 km at 45°.
///
/// The fog's own cells are about 35 m across, so a fog cell lies under the hex holding its centre; a hex is
/// uncovered when any lifted fog cell's centre lies in it (``uncovered(by:)``). The IDs are ``HexCell``s of
/// this grid, not of the fog's, and a level's grid never changes.
public nonisolated struct WorldViewHexGrid: Hashable, Sendable {
    /// A hex's width on screen, flat side to flat side, in points (the mockup's ~10 pt).
    public static let hexAcrossPoints = 10.0
    /// The most fog cells one aggregation reads: ``FogCellStore/maxCells`` (a test pins the two equal).
    public static let maxLiftedCells = 250_000

    /// The level whose scale sizes the grid.
    public let level: AtlasZoomLevel

    /// The grid at `level`.
    public init(level: AtlasZoomLevel) {
        self.level = level
    }

    /// The centre-to-corner radius in Mercator units: ``hexAcrossPoints`` across is √3 radii.
    public var radius: Double { Self.hexAcrossPoints / (3.0.squareRoot() * level.pointsPerMercatorUnit) }

    /// A hex's width on the ground near `latitude`, flat side to flat side, in metres.
    public func groundAcrossMetres(at latitude: Double) -> Double {
        3.0.squareRoot() * radius / WebMercator.unitsPerMetre(at: latitude)
    }

    /// The hex that contains the Mercator position (`x`, `y`).
    public func cell(x: Double, y: Double) -> HexCell {
        let q = (3.0.squareRoot() / 3 * x - y / 3) / radius
        let r = (2.0 / 3 * y) / radius
        return MercatorHexGrid.round(q: q, r: r)
    }

    /// The hex that contains `point`.
    public func cell(containing point: GeoPoint) -> HexCell {
        let unit = WebMercator.unit(point)
        return cell(x: unit.x, y: unit.y)
    }

    /// The Mercator centre of `hex`.
    public func centre(of hex: HexCell) -> (x: Double, y: Double) {
        let q = Double(hex.q), r = Double(hex.r)
        return (radius * 3.0.squareRoot() * (q + r / 2), radius * 1.5 * r)
    }

    /// The six corners of a hex, as Mercator offsets from its centre (pointy-top, as the fog's).
    public var cornerOffsets: [(x: Double, y: Double)] {
        let radius = radius
        return (0..<6).map { index in
            let angle = (60 * Double(index) + 30) * .pi / 180
            return (radius * cos(angle), radius * sin(angle))
        }
    }

    /// The world-view hexes uncovered by the lifted fog `cells`: each fog cell uncovers the hex holding its
    /// centre, so one cell uncovers exactly one hex and the same store drives every level. Bounded: reads at
    /// most ``maxLiftedCells`` cells, so the result has at most that many hexes.
    public func uncovered(by cells: some Collection<HexCell>) -> Set<HexCell> {
        var hexes = Set<HexCell>()
        hexes.reserveCapacity(min(cells.count, Self.maxLiftedCells))
        // Bounded: prefix(maxLiftedCells).
        for fogCell in cells.prefix(Self.maxLiftedCells) {
            let centre = MercatorHexGrid.centre(of: fogCell)
            hexes.insert(cell(x: centre.x, y: centre.y))
        }
        return hexes
    }
}

/// The parts of the zoom control's VoiceOver words (spec: one adjustable element that reads the level and the
/// place, "City, Oregon, United States"). Tokens and data only: the screen formats them, naming the level from
/// its token and the country from its code.
public nonisolated struct AtlasZoomDescription: Hashable, Sendable {
    /// The level.
    public let level: AtlasZoomLevel
    /// The place at the view's centre, only where the level names one (from State in), else nil.
    public let place: AtlasPlaceName?

    /// A description with every field given.
    public init(level: AtlasZoomLevel, place: AtlasPlaceName?) {
        self.level = level
        self.place = place
    }
}

extension WorldAtlas {
    /// The zoom control's VoiceOver parts at `level` for a view centred on `centre`: the level, and from
    /// State in the place there (``placeName(at:)``), the same place the plate names.
    public func zoomDescription(level: AtlasZoomLevel, centre: GeoPoint) -> AtlasZoomDescription {
        AtlasZoomDescription(level: level, place: level.showsPlaceName ? placeName(at: centre) : nil)
    }
}

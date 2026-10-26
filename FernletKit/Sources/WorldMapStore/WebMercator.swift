import CoreGraphics
import Foundation

/// Normalised Web Mercator: `x` and `y` run 0...1 across the whole world, `y` growing south.
///
/// Every base map behind the map seam projects this way (Apple's map today, MapLibre in phase 2), so
/// Fernlet's layers can place themselves from nothing more than the visible rectangle a base map
/// reports, and the fog's hexagons (``MercatorHexGrid``) stay regular hexagons on screen.
public nonisolated enum WebMercator {
    /// The Earth's equatorial circumference in metres: the width of the unit square.
    public static let earthCircumference = 40_075_016.686

    /// The latitude Web Mercator stops at (its square's top and bottom edges).
    public static let maxLatitude = 85.05112878

    /// The normalised Mercator position of `point` (latitudes past ±85.05° are clamped to the edge).
    public static func unit(_ point: GeoPoint) -> (x: Double, y: Double) {
        let latitude = min(max(point.latitude, -maxLatitude), maxLatitude) * .pi / 180
        let x = (point.longitude + 180) / 360
        let y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2
        return (x, y)
    }

    /// The place at a normalised Mercator position.
    public static func geo(x: Double, y: Double) -> GeoPoint {
        let longitude = x * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
        return GeoPoint(latitude, longitude)
    }

    /// Mercator units per metre on the ground at `latitude` (the projection stretches by 1 / cos).
    public static func unitsPerMetre(at latitude: Double) -> Double {
        let clamped = min(max(latitude, -maxLatitude), maxLatitude)
        return 1 / (earthCircumference * cos(clamped * .pi / 180))
    }
}

/// The base map's visible area as a rectangle in normalised Web Mercator, as the base map reports it.
///
/// This is the whole contract between a base map and Fernlet's layers: given it and the view's size,
/// every layer turns a ``GeoPoint`` into a screen point. Maps are kept north-up and flat (no rotation,
/// no pitch), so the mapping is a plain scale and offset.
public nonisolated struct MapViewport: Equatable, Sendable {
    /// The left edge, in Mercator units.
    public var minX: Double
    /// The top edge, in Mercator units.
    public var minY: Double
    /// The visible width, in Mercator units.
    public var width: Double
    /// The visible height, in Mercator units.
    public var height: Double

    /// A viewport from its Mercator edges.
    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    /// Whether the rectangle is finite and has area. A base map's first report can be empty while
    /// its view lays out; layers skip such a viewport rather than divide by zero.
    public var isUsable: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    /// A viewport `heightMetres` tall, centred on `center`, shaped to `size`.
    public static func around(_ center: GeoPoint, heightMetres: Double, size: CGSize) -> MapViewport {
        let mid = WebMercator.unit(center)
        let height = max(heightMetres, 1) * WebMercator.unitsPerMetre(at: center.latitude)
        let width = size.height > 0 ? height * Double(size.width / size.height) : height
        return MapViewport(minX: mid.x - width / 2, minY: mid.y - height / 2, width: width, height: height)
    }

    /// Where the Mercator position (`x`, `y`) falls in a view of `size`.
    public func screenPoint(x: Double, y: Double, in size: CGSize) -> CGPoint {
        guard isUsable else { return .zero }
        return CGPoint(x: (x - minX) / width * Double(size.width), y: (y - minY) / height * Double(size.height))
    }

    /// Where `point` falls in a view of `size`.
    public func screenPoint(for point: GeoPoint, in size: CGSize) -> CGPoint {
        let unit = WebMercator.unit(point)
        return screenPoint(x: unit.x, y: unit.y, in: size)
    }

    /// The place under screen point `point` in a view of `size`.
    public func geo(at point: CGPoint, in size: CGSize) -> GeoPoint {
        WebMercator.geo(x: minX + Double(point.x / max(size.width, 1)) * width,
                        y: minY + Double(point.y / max(size.height, 1)) * height)
    }

    /// Screen points per Mercator unit across a view of `size`.
    public func pointsPerUnit(in size: CGSize) -> Double {
        guard isUsable else { return 0 }
        return Double(size.width) / width
    }

    /// Screen points per metre on the ground near `latitude`.
    public func pointsPerMetre(at latitude: Double, in size: CGSize) -> Double {
        WebMercator.unitsPerMetre(at: latitude) * pointsPerUnit(in: size)
    }

    /// The viewport's centre.
    public var center: GeoPoint { WebMercator.geo(x: minX + width / 2, y: minY + height / 2) }
}

/// Fernlet's own camera for the world map: where it looks and how far up it is.
///
/// The camera belongs to Fernlet, not to the base map: a base map follows it and reports back when the
/// person pans or zooms. `revision` goes up only when Fernlet moves the camera itself (following the
/// companion, recentring), so a base map can tell a request from an echo of its own report. A move that
/// goes nowhere (within ``stillMetres`` of the centre, the height as it was) is no request (issue desk
/// W-15: a panel closing while the map follows asks for the camera already shown).
public nonisolated struct WorldCamera: Equatable, Sendable {
    /// Where the camera looks.
    public var center: GeoPoint
    /// Camera height in metres (MapKit's camera distance; the plain map scales it to the same zoom).
    public var distance: Double
    /// Bumped by every programmatic move that goes somewhere.
    public var revision: Int
    /// Whether the camera keeps the companion in view; a pan by the person turns it off.
    public var follows: Bool
    /// The height as of the last revision, so a move after a change of height is a request even when
    /// the centre stays put.
    private var revisedDistance: Double

    /// The nearest and farthest the camera may sit, in metres (the shell's bounds: a street to a
    /// neighbourhood, so the fog's cells stay at least a few points across on screen).
    public static let distanceRange: ClosedRange<Double> = 300...7_000

    /// How far a move must carry the centre, or change the height, in metres, to be a move at all.
    public static let stillMetres = 0.5

    /// A camera over `center` at `distance` metres, following the companion.
    public init(center: GeoPoint, distance: Double, revision: Int = 0, follows: Bool = true) {
        self.center = center
        self.distance = min(max(distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        self.revision = revision
        self.follows = follows
        revisedDistance = self.distance
    }

    /// Moves the camera to `center` as Fernlet's own request (bumps ``revision``). A move to where the
    /// camera already looks, within ``stillMetres`` and at the same height, sets only `follows`.
    public mutating func move(to center: GeoPoint, follows: Bool = true) {
        guard center.isValid else { return }
        self.follows = follows
        let still = center.distance(to: self.center) < Self.stillMetres && abs(distance - revisedDistance) < Self.stillMetres
        guard !still else { return }
        self.center = center
        revisedDistance = distance
        revision &+= 1
    }
}

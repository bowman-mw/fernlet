import CoreGraphics
import Foundation

/// Normalised Web Mercator: `x` and `y` run 0...1 across the whole world, `y` growing south.
///
/// Both base maps project this way (Apple's map and, in phase 2, MapLibre), so Fernlet's layers
/// can place themselves from nothing more than the visible rectangle a base map reports.
nonisolated enum WebMercator {
    /// The Earth's equatorial circumference in metres: the width of the unit square.
    static let earthCircumference = 40_075_016.686

    /// The normalised Mercator position of `point`.
    static func unit(_ point: GeoPoint) -> (x: Double, y: Double) {
        let latitude = min(max(point.latitude, -85.05), 85.05) * .pi / 180
        let x = (point.longitude + 180) / 360
        let y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2
        return (x, y)
    }

    /// The place at a normalised Mercator position.
    static func geo(x: Double, y: Double) -> GeoPoint {
        let longitude = x * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
        return GeoPoint(latitude, longitude)
    }
}

/// The base map's visible area as a rectangle in normalised Web Mercator, as the base map reports it.
///
/// This is the whole contract between a base map and Fernlet's layers: given it and the view's
/// size, every layer can turn a ``GeoPoint`` into a screen point. Maps are kept north-up and flat
/// (no rotation, no pitch), so the mapping is a plain scale and offset.
nonisolated struct MapViewport: Equatable, Sendable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double

    /// A viewport `heightMetres` tall, centred on `center`, shaped to `size`.
    static func around(_ center: GeoPoint, heightMetres: Double, size: CGSize) -> MapViewport {
        let mid = WebMercator.unit(center)
        let unitsPerMetre = 1 / (WebMercator.earthCircumference * cos(center.latitude * .pi / 180))
        let height = heightMetres * unitsPerMetre
        let width = size.height > 0 ? height * Double(size.width / size.height) : height
        return MapViewport(minX: mid.x - width / 2, minY: mid.y - height / 2, width: width, height: height)
    }

    /// Where `point` falls in a view of `size`.
    func screenPoint(for point: GeoPoint, in size: CGSize) -> CGPoint {
        let unit = WebMercator.unit(point)
        return CGPoint(x: (unit.x - minX) / width * Double(size.width),
                       y: (unit.y - minY) / height * Double(size.height))
    }

    /// The place under screen point `point` in a view of `size`.
    func geo(at point: CGPoint, in size: CGSize) -> GeoPoint {
        WebMercator.geo(x: minX + Double(point.x / max(size.width, 1)) * width,
                        y: minY + Double(point.y / max(size.height, 1)) * height)
    }

    /// Screen points per metre on the ground near `latitude`.
    func pointsPerMetre(at latitude: Double, in size: CGSize) -> Double {
        let unitsPerMetre = 1 / (WebMercator.earthCircumference * cos(latitude * .pi / 180))
        return unitsPerMetre / width * Double(size.width)
    }

    /// The viewport's centre.
    var center: GeoPoint { WebMercator.geo(x: minX + width / 2, y: minY + height / 2) }
}

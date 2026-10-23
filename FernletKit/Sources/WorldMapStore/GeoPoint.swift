import Foundation

/// A place on Earth as plain latitude and longitude, in degrees.
///
/// Every one of Fernlet's own map layers (fog, trails, the companion, pins) stores only these, never
/// a MapKit type, so phase 2 can swap Apple's map for MapLibre without touching any stored data
/// (design page "A World for Fernlet", answer 29). The distance maths is a local flat-earth step:
/// accurate to well under a metre across the few kilometres a neighbourhood covers, which is all the
/// map ever measures (a walk, a 100 m quick-start match, a fog radius).
public nonisolated struct GeoPoint: Hashable, Codable, Sendable {
    /// Degrees north of the equator, -90...90.
    public var latitude: Double
    /// Degrees east of Greenwich, -180...180.
    public var longitude: Double

    /// Metres in one degree of latitude (and of longitude at the equator).
    public static let metresPerDegree = 111_320.0

    /// A point at `latitude`, `longitude` (degrees).
    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Whether both coordinates are finite and on the globe. Location fixes and decoded rows are
    /// checked with this before they reach a store or a layer.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    /// Metres in one degree of longitude at this latitude.
    public var metresPerDegreeLongitude: Double {
        Self.metresPerDegree * cos(latitude * .pi / 180)
    }

    /// The point `east` and `north` metres away.
    public func offset(east: Double, north: Double) -> GeoPoint {
        let perLongitude = max(metresPerDegreeLongitude, 1e-6)
        return GeoPoint(latitude + north / Self.metresPerDegree, longitude + east / perLongitude)
    }

    /// How far east and north of `origin` this point lies, in metres.
    public func metres(from origin: GeoPoint) -> (east: Double, north: Double) {
        ((longitude - origin.longitude) * origin.metresPerDegreeLongitude,
         (latitude - origin.latitude) * Self.metresPerDegree)
    }

    /// The straight-line distance to `other`, in metres.
    public func distance(to other: GeoPoint) -> Double {
        let step = other.metres(from: self)
        return (step.east * step.east + step.north * step.north).squareRoot()
    }

    /// The point a fraction `t` (0...1) of the way to `other`.
    public func lerp(to other: GeoPoint, _ t: Double) -> GeoPoint {
        GeoPoint(latitude + (other.latitude - latitude) * t, longitude + (other.longitude - longitude) * t)
    }
}

import Foundation

/// A place on Earth as plain latitude and longitude, in degrees.
///
/// Every one of Fernlet's own map layers (fog, trails, the companion, markers) stores only these,
/// never a MapKit type, so phase 2 can swap Apple's map for MapLibre without touching the data
/// (design page, answer 29). The maths here is a local flat-earth step: accurate to well under a
/// metre across the few kilometres a neighbourhood covers.
nonisolated struct GeoPoint: Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    /// Metres in one degree of latitude (and of longitude at the equator).
    static let metresPerDegree = 111_320.0

    init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Metres in one degree of longitude at this latitude.
    var metresPerDegreeLongitude: Double {
        Self.metresPerDegree * cos(latitude * .pi / 180)
    }

    /// The point `east` and `north` metres away.
    func offset(east: Double, north: Double) -> GeoPoint {
        GeoPoint(latitude + north / Self.metresPerDegree, longitude + east / metresPerDegreeLongitude)
    }

    /// How far east and north of `origin` this point lies, in metres.
    func metres(from origin: GeoPoint) -> (east: Double, north: Double) {
        ((longitude - origin.longitude) * origin.metresPerDegreeLongitude,
         (latitude - origin.latitude) * Self.metresPerDegree)
    }

    /// The straight-line distance to `other`, in metres.
    func distance(to other: GeoPoint) -> Double {
        let step = other.metres(from: self)
        return (step.east * step.east + step.north * step.north).squareRoot()
    }

    /// The point a fraction `t` (0...1) of the way to `other`.
    func lerp(to other: GeoPoint, _ t: Double) -> GeoPoint {
        GeoPoint(latitude + (other.latitude - latitude) * t, longitude + (other.longitude - longitude) * t)
    }
}

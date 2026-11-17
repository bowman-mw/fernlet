import Foundation

/// The "near a major road" lookup for the ferry and train classifier (Docs/World-Transit-Paths-Exploration-2026-11-15.md
/// §2: readings within about 150 m of a major road over water are a bridge, not a ferry; §3: long stretches far from
/// any major road point to a train). It reads the roads' one-degree segment index, as the crossing rule does.
extension WorldAtlas {
    /// The farthest ``isNearMajorRoad(_:within:)`` looks, in metres: a larger `within` is read as this.
    public static let maxNearRoadMetres = 20_000.0

    /// Whether a major road (the pack's `ROAD` section) passes within `metres` of `point`: point-to-segment distance
    /// in a flat local frame, over the one-degree cells the box of `metres` touches. False for an invalid point or a
    /// distance that isn't positive; `metres` is capped at ``maxNearRoadMetres``.
    public func isNearMajorRoad(_ point: GeoPoint, within metres: Double) -> Bool {
        guard point.isValid, metres.isFinite, metres > 0 else { return false }
        let reach = min(metres, Self.maxNearRoadMetres)
        let cosine = max(0.05, cos(point.latitude * .pi / 180))
        let dLat = reach / GeoPoint.metresPerDegree, dLon = reach / (GeoPoint.metresPerDegree * cosine)
        let north = AtlasRoadIndex.row(point.latitude + dLat), south = AtlasRoadIndex.row(point.latitude - dLat)
        let west = AtlasRoadIndex.column(point.longitude - dLon), east = AtlasRoadIndex.column(point.longitude + dLon)
        let scale = AtlasPolygon.unitsPerDegree
        let kx = GeoPoint.metresPerDegree * cosine / scale, ky = GeoPoint.metresPerDegree / scale
        let originLon = point.longitude * scale, originLat = point.latitude * scale
        // Bounded: reach <= 20 km and cos >= 0.05, so at most 3 rows and 9 columns of the index, each listing once.
        for row in north...south {
            for column in west...east {
                for segment in roadGrid.cells[row * 360 + column] ?? [] {
                    guard roads.indices.contains(Int(segment.road)) else { continue }
                    let road = roads[Int(segment.road)], index = Int(segment.point)
                    guard index + 1 < road.lons.count, index + 1 < road.lats.count else { continue }
                    let a = (x: (Double(road.lons[index]) - originLon) * kx, y: (Double(road.lats[index]) - originLat) * ky)
                    let b = (x: (Double(road.lons[index + 1]) - originLon) * kx,
                             y: (Double(road.lats[index + 1]) - originLat) * ky)
                    if WorldRail.metresToSegment(a, b) <= reach { return true }
                }
            }
        }
        return false
    }
}

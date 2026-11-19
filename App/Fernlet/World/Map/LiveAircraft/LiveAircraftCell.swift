import Foundation
import WorldMapStore

/// The one piece of place the live-planes lookup may send: a fixed 0.5° grid cell (owner 2026-11-19, call 3), about
/// 55 km north–south. Everyone looking at the same cell sends the identical request, and adsb.lol learns the cell,
/// never the map's exact centre or the person's own position.
///
/// ``LiveAircraftClient`` takes only this type, never a ``GeoPoint``: the snapping happens here, before anything
/// reaches the network seam (`LiveAircraftTests` pins that the client's source names no `GeoPoint`).
nonisolated struct LiveAircraftCell: Hashable, Sendable {
    /// The cell's size, in degrees of latitude and of longitude.
    static let sizeDegrees = 0.5
    /// The fixed radius every request asks for, in nautical miles: wide enough to cover the whole cell from its
    /// centre (the corner is about 30 NM away at the equator) and the area round it.
    static let radiusNauticalMiles = 50
    /// How far north or south a cell's centre may sit (the API takes latitudes within ±90).
    static let maxCentreLatitude = 89.75

    /// The cell's row: its southern edge in half-degrees from the equator.
    let row: Int
    /// The cell's column: its western edge in half-degrees from the prime meridian, wrapped into −360..<360.
    let column: Int

    /// The cell holding `point` (the visible map's centre), or nil for a point that isn't a real place.
    init?(containing point: GeoPoint) {
        guard point.isValid else { return nil }
        let latitude = min(max(point.latitude, -90), 90)
        var longitude = point.longitude.truncatingRemainder(dividingBy: 360)
        if longitude >= 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        row = min(Int((latitude / Self.sizeDegrees).rounded(.down)), Int(90 / Self.sizeDegrees) - 1)
        column = min(Int((longitude / Self.sizeDegrees).rounded(.down)), Int(180 / Self.sizeDegrees) - 1)
    }

    /// The cell's centre latitude, the only latitude a request carries.
    var centreLatitude: Double {
        min(max(Double(row) * Self.sizeDegrees + Self.sizeDegrees / 2, -Self.maxCentreLatitude), Self.maxCentreLatitude)
    }

    /// The cell's centre longitude, the only longitude a request carries.
    var centreLongitude: Double { Double(column) * Self.sizeDegrees + Self.sizeDegrees / 2 }

    /// The centre as a place on the map (for distances on the phone; never sent anywhere but as the two numbers).
    var centre: GeoPoint { GeoPoint(centreLatitude, centreLongitude) }
}

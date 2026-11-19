import CoreGraphics
import Foundation
import WorldMapStore

/// Finding the worn road, railway or ferry wake under a tap on Home (ferry and train build, owner's C2, 2026-11-15),
/// and the ones near the person for VoiceOver's "Paths near you". Pure: Home hands in the drawn counter
/// (`FernletStore.wornYourWorldTallies`, empty with "Show worn paths" off or in a decoy).
nonisolated enum WornWayLookup {
    /// How near a marker's anchor (in points) a tap is left to the marker: markers win over the path under them.
    static let markerReach: CGFloat = 30
    /// The companion's hit area round its feet: half its width, and how far it stands above and below the feet.
    static let companionHalfWidth: CGFloat = 40
    static let companionAbove: CGFloat = 96
    static let companionBelow: CGFloat = 12
    /// A finger's reach on the ground, in points.
    static let fingerPoints = 22.0
    /// The reach's floor and ceiling in metres: a hex's radius, and a few hundred metres zoomed far out.
    static let toleranceRange = 18.0...150.0
    /// How far "Paths near you" looks, in metres.
    static let nearbyMetres = 200.0
    /// The kinds a tap prefers when two lie at the same distance (a level crossing): the rarer first.
    static let preference: [WornWayKind] = [.rail, .ferry, .road]

    /// Whether a tap at `tap` lands on a marker (one of `markers`' anchors) or on the companion standing at
    /// `companion`: the marker's own tap wins, and the path under it doesn't open.
    static func isOnMarker(_ tap: CGPoint, markers: [CGPoint], companion: CGPoint?) -> Bool {
        if let companion,
           abs(tap.x - companion.x) <= companionHalfWidth,
           tap.y >= companion.y - companionAbove, tap.y <= companion.y + companionBelow {
            return true
        }
        return markers.contains { hypot($0.x - tap.x, $0.y - tap.y) <= markerReach }
    }

    /// A finger's reach in metres at `pointsPerMetre` (the map's zoom), within ``toleranceRange``.
    static func toleranceMetres(pointsPerMetre: Double) -> Double {
        guard pointsPerMetre.isFinite, pointsPerMetre > 0 else { return toleranceRange.lowerBound }
        return min(max(fingerPoints / pointsPerMetre, toleranceRange.lowerBound), toleranceRange.upperBound)
    }

    /// The drawn way nearest `point` within `metres` (the cell under it and those round it): a road, a railway or a
    /// ferry wake at any level, abandoned included; nil when none is.
    static func way(at point: GeoPoint, within metres: Double, tallies: [WornWayKey: WornTally], today: UInt16) -> WornWayKey? {
        guard !tallies.isEmpty else { return nil }
        var best: (key: WornWayKey, metres: Double)?
        // Bounded: MercatorHexGrid caps the cells at 12 rings; three kinds each.
        for cell in MercatorHexGrid.cells(around: point, within: metres) {
            let distance = point.distance(to: MercatorHexGrid.centreGeo(of: cell))
            for kind in preference where isDrawn(WornWayKey(cell: cell, kind: kind), tallies: tallies, today: today) {
                if best == nil || distance < (best?.metres ?? .infinity) {
                    best = (WornWayKey(cell: cell, kind: kind), distance)
                }
            }
        }
        return best?.key
    }

    /// One worn way near the person, for "Paths near you": the nearest cell of each kind, and how far it is.
    struct Nearby: Equatable, Sendable, Identifiable {
        let key: WornWayKey
        let metres: Double
        var id: WornWayKey { key }
    }

    /// The worn ways within ``nearbyMetres`` of `point`: one per kind (its nearest cell), nearest first.
    static func nearby(around point: GeoPoint, tallies: [WornWayKey: WornTally], today: UInt16) -> [Nearby] {
        guard !tallies.isEmpty else { return [] }
        var nearest: [WornWayKind: Nearby] = [:]
        // Bounded: MercatorHexGrid caps the cells at 12 rings; three kinds each.
        for cell in MercatorHexGrid.cells(around: point, within: nearbyMetres) {
            let distance = point.distance(to: MercatorHexGrid.centreGeo(of: cell))
            for kind in preference where isDrawn(WornWayKey(cell: cell, kind: kind), tallies: tallies, today: today) {
                if distance < (nearest[kind]?.metres ?? .infinity) {
                    nearest[kind] = Nearby(key: WornWayKey(cell: cell, kind: kind), metres: distance)
                }
            }
        }
        return nearest.values.sorted { $0.metres == $1.metres ? $0.key < $1.key : $0.metres < $1.metres }
    }

    /// Whether `key`'s way draws today: it reached level 1 once (abandoned still draws).
    static func isDrawn(_ key: WornWayKey, tallies: [WornWayKey: WornTally], today: UInt16) -> Bool {
        tallies[key]?.level(today: today, thresholds: .forKind(key.kind)) != nil
    }
}

/// A tap on Home that found a worn way, waiting out a double-tap's second tap (which zooms the map instead) before
/// its sheet opens; `serial` tells two taps on the same way apart.
nonisolated struct WornWayPendingTap: Equatable, Sendable {
    let key: WornWayKey
    let serial: Int

    /// How long a tap waits for a second tap.
    static let doubleTapWindow: Duration = .milliseconds(350)
}

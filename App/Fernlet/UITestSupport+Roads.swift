import Foundation
import WorldMapStore

//  The major roads' DEBUG screenshot hook (round 7, World-Exploration-Spec §2 `ex-roads`), beside `UITestSupport`'s
//  own: wrapped in `#if DEBUG`, with a release no-op, so nothing of it ships.

extension UITestSupport {
    #if DEBUG
    /// `FERNLET_UI_TEST_ROADS=1` — Home, the city card and the crossed roads read a demo walk across Portland that
    /// crosses I-5 and I-84, in memory only (nothing is read or written; never in a decoy), for the `ex-roads`
    /// screenshots. Consumed through ``WorldRoadTestScenes``.
    static var roadsDemo: Bool {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_ROADS"] == "1"
    }
    #else
    static var roadsDemo: Bool { false }
    #endif
}

/// The demo walk the roads screenshots stand in (``UITestSupport/roadsDemo``): west of I-5 south of downtown,
/// east across it, then north up 64th-ish across I-84, about 9 km; its fog lifted 50 m round a point every 25 m,
/// as a real walk's would be.
enum WorldRoadTestScenes {
    /// The walk's corners.
    static let corners = [GeoPoint(45.505, -122.690), GeoPoint(45.505, -122.640), GeoPoint(45.515, -122.620),
                          GeoPoint(45.545, -122.620)]

    /// Whether the demo shows (asked for, and not a decoy).
    static func isOn(decoy: Bool) -> Bool { UITestSupport.roadsDemo && !decoy }

    /// The walk's line, a point every 25 m (at most 200 a leg).
    static let walk: [GeoPoint] = {
        var points: [GeoPoint] = []
        for (from, to) in zip(corners, corners.dropFirst()) {
            let steps = min(max(1, Int(from.distance(to: to) / 25)), 200)
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                points.append(GeoPoint(from.latitude + (to.latitude - from.latitude) * t,
                                       from.longitude + (to.longitude - from.longitude) * t))
            }
        }
        return points + corners.suffix(1)
    }()

    /// The walk's lifted cells.
    static let cells: Set<HexCell> = Set(walk.flatMap { MercatorHexGrid.cells(around: $0, within: WorldFogKeeper.liftRadius) })
}

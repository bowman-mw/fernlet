import Foundation
import WorldMapStore

/// DEBUG screenshots of live planes (`FERNLET_UI_TEST_WORLD_HOME=livePlanes`): a made-up sky round the person, one plane
/// of most families in a few airlines' colours, at headings all round, one with the tail of a flight flown and one of a
/// type flown, so the labels show too. The planes hold still (read afresh every frame) and sit within Home's street
/// zoom, so a screenshot or a tap finds them; the glide itself is `LiveAircraftTests`' to prove.
/// Display only: nothing is fetched or written, and release builds never ask (`UITestSupport.worldHomeScenes` is empty).
enum LiveAircraftTestScenes {
    /// Whether the scene shows (asked for, and not a decoy).
    static func isOn(decoy: Bool) -> Bool { UITestSupport.worldHomeScenes.contains("livePlanes") && !decoy }

    /// What the scene says was flown: the 737 MAX 8's tail and the A320's type.
    static let flown: LiveAircraftFlown = {
        var flown = LiveAircraftFlown()
        flown.tails = ["N27260"]
        flown.types = ["A320"]
        return flown
    }()

    /// The made-up planes: callsign, registration, type, metres east and north of the person, track, altitude, speed.
    static let planes: [(String, String, String, Double, Double, Double, Int, Double)] = [
        ("UAL1704", "N27260", "B38M", -420, 520, 45, 9_500, 210),
        ("SWA2210", "N8712L", "B737", 520, 380, 300, 6_200, 180),
        ("DAL455", "N372DA", "A320", -380, -460, 135, 12_400, 250),
        ("BAW219", "G-XWBA", "A35K", 180, -620, 200, 33_000, 470),
        ("FDX1427", "N864FD", "B763", 640, -140, 270, 21_000, 420),
        ("SKW5543", "N603QX", "E75L", -640, -40, 90, 8_000, 230),
        ("N172SP", "N172SP", "C172", 120, 220, 340, 5_900, 95),
        ("N44EV", "N44EV", "B407", -120, -200, 160, 5_600, 110),
    ]

    /// How much nearer the person the planes sit than their listed offsets.
    static let nearer = 0.3

    /// The scene's sky at `now`, read afresh, round `here`.
    static func sky(around here: GeoPoint, now: Date) -> LiveAircraftSky {
        let beat = now
        let aircraft = planes.enumerated().map { index, plane in
            LiveAircraft(id: "scene\(index)", callsign: plane.0, registration: plane.1, typeCode: plane.2, category: nil,
                         position: here.offset(east: plane.3 * nearer, north: plane.4 * nearer), altitudeFeet: plane.6,
                         groundSpeedKnots: plane.7, trackDegrees: plane.5, seenAt: beat)
        }
        return LiveAircraftSky().merging(aircraft, at: beat)
    }
}

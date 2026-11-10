import Foundation
import WorldMapStore

/// The DEBUG road trip scenes (World-RoadTrip-Spec PR 1, which has no entry point; PR 2 adds Start a road trip), asked
/// for in `FERNLET_UI_TEST_WORLD_HOME` beside Home's other scenes (``UITestSupport/worldHomeScenes``, empty in release
/// builds). Home stages them once it shows (`FernletStore.stageRoadTripTestScene(now:)`):
///
/// - `roadTrip`: a trip with Rae and Sam that this iPhone started and maps, begun three hours ago and last caught up 40
///   minutes ago, with a staged 84 km line east along the Columbia, so the chip reads "Road trip · 3" and Trip info
///   "Mapping: Mike's iPhone · Last caught up … · 84 km · 6 photos" (the photo count is display only). Readings join
///   the line from then on.
/// - `roadTripPassenger`: the same trip started and mapped by Rae: this iPhone is a passenger, traces no drive, and
///   Trip info offers Map from this iPhone.
///
/// Unlike most of Home's scenes, the trip is written to the vault like a real one (so recording, the passenger gate and
/// the wipes can be tried); End the road trip, Leave the road trip or Delete map history removes it. Never in a decoy.
enum RoadTripTestScenes {
    /// The scenes asked for (none in release builds).
    static var scenes: Set<String> { UITestSupport.worldHomeScenes }

    /// Whether a trip is staged.
    static var stagesTrip: Bool { scenes.contains("roadTrip") || scenes.contains("roadTripPassenger") }

    /// Whether the staged trip is mapped by another member's iPhone.
    static var asPassenger: Bool { scenes.contains("roadTripPassenger") }

    /// The staged photo count Trip info shows (display only); nil without the scene.
    static var photoCount: Int? { stagesTrip ? 6 : nil }

    /// The staged members' ids (fixtures, never a real fingerprint).
    static let selfID = "fixture-self", raeID = "fixture-rae", samID = "fixture-sam"

    /// The staged trip at `now`: this iPhone's, or Rae's to map when `passenger`.
    static func trip(now: Date, passenger: Bool) -> RoadTrip {
        let lead = passenger ? raeID : selfID
        let members = [RoadTripMember(id: selfID, firstName: "Mike"), RoadTripMember(id: raeID, firstName: "Rae"),
                       RoadTripMember(id: samID, firstName: "Sam")]
        return RoadTrip(id: UUID(), name: nil, startedAt: now.addingTimeInterval(-3 * 60 * 60), starterID: lead, selfID: selfID,
                        members: members, mapperID: lead, mapperOverride: nil,
                        lastCatchUp: now.addingTimeInterval(-40 * 60), endedAt: nil, leftAt: nil)
    }

    /// How many staged points (one every ``spacing`` metres: 84 km).
    static let pointCount = 2_801
    /// The staged points' spacing, in metres (a second apart: 108 km/h).
    static let spacing = 30.0

    /// The staged line from `start`: east from Portland along the Columbia, a point every ``spacing`` metres and a
    /// second apart.
    static func line(startingAt start: Date) -> [RoadTripPoint] {
        let from = GeoPoint(45.5300, -122.6600)
        return (0..<pointCount).map { index in
            RoadTripPoint(point: from.offset(east: Double(index) * spacing, north: 0),
                          at: start.addingTimeInterval(TimeInterval(index)))
        }
    }
}

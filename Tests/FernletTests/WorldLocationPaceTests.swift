import CoreLocation
import Foundation
import Testing
@testable import Fernlet

/// The map's location pace (owner 2026-10-31, perf review): with the map behind a panel, sheet or tab and nothing
/// recording, readings come less often and at ten-metre accuracy, and that can never cost the map an uncovered
/// hex — the gap between readings stays inside the lift radius, and the accuracy asked for stays inside the fog's
/// and ride detection's limit. A walk, a drive or a ride always gets the full pace its lines need.
@MainActor
struct WorldLocationPaceTests {
    @Test func theMapInFrontOrAnythingRecordingGetsTheFullPace() {
        for recording in [false, true] {
            let front = WorldLocationSource.pace(mapOnScreen: true, recording: recording)
            #expect(front.accuracy == kCLLocationAccuracyBest && front.distanceFilter == 10)
        }
        let recordingOffMap = WorldLocationSource.pace(mapOnScreen: false, recording: true)
        #expect(recordingOffMap.accuracy == kCLLocationAccuracyBest && recordingOffMap.distanceFilter == 10,
                "a walk, a drive or a ride under a panel keeps its 25 m line")
        let offMap = WorldLocationSource.pace(mapOnScreen: false, recording: false)
        #expect(offMap.accuracy == kCLLocationAccuracyNearestTenMeters && offMap.distanceFilter == 25)
    }

    @Test func theOffMapPaceNeverLeavesAnUnliftedGap() {
        let pace = WorldLocationSource.offMapPace
        #expect(pace.distanceFilter < WorldFogKeeper.liftRadius,
                "two readings a filter apart lift overlapping circles, so walking under a panel leaves no hole")
        #expect(pace.accuracy > 0 && pace.accuracy < WorldFogKeeper.maxAccuracy && pace.accuracy < WorldRideWatch.goodAccuracy,
                "the accuracy asked for is inside the fog's and ride detection's 65 m — never the hundred-metre mode")
        #expect(pace.accuracy != kCLLocationAccuracyHundredMeters && pace.accuracy != kCLLocationAccuracyKilometer)
    }
}

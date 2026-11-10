import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Trips that keep tracking (owner 2026-11-09: "really long stop lights that then make it think I'm walking", and
/// trips dropping in the background so tiles don't unlock): a long light, GPS drift while stopped and a crawl
/// through a jam are no walk and no parking; a drive that ended on foot resumes after a short run; and the
/// location source's own rules for the cool-down, the leaving fence and the listen.
@MainActor
struct WorldTripTrackingTests {
    typealias Stream = WorldRidesTests.Stream

    /// A minute at 15 m/s, readings every five seconds; the stream's second and metres east after it.
    private static func drive(_ stream: inout Stream, from second: Double = 0, east: Double = 0) -> (Double, Double) {
        var second = second, east = east
        for _ in 0..<12 {
            second += 5
            east += 75
            stream.read(east, second, speed: 15)
        }
        return (second, east)
    }

    // MARK: Red lights and jams

    /// A three-minute light in a queue that creeps up a car length at a time, read as iOS's ten-metre filter hands
    /// it on (a reading at walking pace every half minute, 10 m on), by CoreLocation's speed and by the pace alone:
    /// one drive, never a walk. Before 2026-11-09 a minute of those readings ended the drive.
    @Test func creepingUpToALongLightIsOneDrive() {
        for withSpeed in [true, false] {
            var stream = Stream()
            var (second, east) = Self.drive(&stream)
            #expect(stream.watch.isDriving)
            for _ in 0..<6 {
                second += 30
                east += 10
                stream.read(east, second, speed: withSpeed ? 1.2 : nil)
            }
            (second, east) = Self.drive(&stream, from: second, east: east)
            #expect(stream.drivesStarted == 1 && stream.drivesEnded == 0, "withSpeed \(withSpeed): \(stream.events)")
        }
    }

    /// Four minutes stopped at a light with GPS drift (±6 m round one spot every eight seconds, CoreLocation saying
    /// 0.8 m/s): still the drive, since the drift goes nowhere.
    @Test func gpsDriftWhileStoppedIsNoWalk() {
        var stream = Stream()
        var (second, east) = Self.drive(&stream)
        for step in 0..<30 {
            second += 8
            let jitter = Double((step * 7) % 13) - 6
            stream.read(east + jitter, second, speed: 0.8, north: -jitter / 2)
        }
        #expect(stream.watch.isDriving && stream.drivesEnded == 0, "\(stream.events)")
        (second, east) = Self.drive(&stream, from: second, east: east)
        #expect(stream.drivesStarted == 1 && stream.drivesEnded == 0)
    }

    /// Nine minutes crawling through a jam, 30 m a minute at walking pace and never faster: the car keeps moving
    /// further than ``WorldRideWatch/parkRadius`` from where it last moved, so it isn't parked after five minutes,
    /// and the crawl is too slow for a walk. Truly parked after it, the drive ends parked.
    @Test func crawlingThroughAJamIsNeitherParkedNorAWalk() {
        var stream = Stream()
        var (second, east) = Self.drive(&stream)
        for _ in 0..<9 {
            second += 60
            east += 30
            stream.read(east, second, speed: 1.5)
            stream.tick(second)
        }
        #expect(stream.watch.isDriving && stream.drivesEnded == 0, "\(stream.events)")
        stream.tick(second + WorldRideWatch.parkTime + 5)
        #expect(!stream.watch.isDriving && stream.drivesEnded == 1)
        #expect(stream.watch.lastDriveEnd == .parked)
    }

    /// Still a walk: parked, then a minute or so at 1.4 m/s away from the car ends the drive on foot, as before.
    @Test func walkingAwayFromTheCarStillEndsTheDrive() {
        var stream = Stream()
        var (second, east) = Self.drive(&stream)
        second += 10
        east += 20
        stream.read(east, second, speed: 0.2)
        for _ in 0..<8 {
            second += 10
            east += 14
            stream.read(east, second, speed: 1.4)
        }
        #expect(!stream.watch.isDriving && stream.drivesEnded == 1, "\(stream.events)")
        #expect(stream.watch.lastDriveEnd == .onFoot)
    }

    // MARK: Resuming

    /// A drive that ended on foot resumes after ten seconds at a car's speed, within five minutes of that end; after
    /// a parked end, or later, the run must span the usual half minute.
    @Test func aDriveThatEndedOnFootResumesQuickly() {
        var stream = Stream()
        var (second, east) = Self.drive(&stream)
        for _ in 0..<8 {
            second += 10
            east += 14
            stream.read(east, second, speed: 1.4)
        }
        #expect(stream.watch.lastDriveEnd == .onFoot && !stream.watch.isDriving)
        for step in 1...3 {
            stream.read(east + Double(step) * 75, second + Double(step) * 5, speed: 15)
        }
        #expect(stream.drivesStarted == 2 && stream.watch.isDriving, "ten seconds at speed resumes it: \(stream.events)")

        var parked = Stream()
        (second, east) = Self.drive(&parked)
        parked.tick(second + WorldRideWatch.parkTime + 5)
        #expect(parked.watch.lastDriveEnd == .parked)
        second += WorldRideWatch.parkTime + 10
        for step in 1...3 {
            parked.read(east + Double(step) * 75, second + Double(step) * 5, speed: 15)
        }
        #expect(parked.drivesStarted == 1 && !parked.watch.isDriving, "after parking, ten seconds is not enough")
        for step in 4...7 {
            parked.read(east + Double(step) * 75, second + Double(step) * 5, speed: 15)
        }
        #expect(parked.drivesStarted == 2 && parked.watch.isDriving, "the usual half minute is")
    }

    /// Each way a drive ends is named: Motion's confident walking is on foot, and a flight is a flight.
    @Test func everyDriveEndIsNamed() {
        var walking = Stream(usesMotion: true)
        walking.motion(.automotive, 0, through: WorldRideWatch.motionHold)
        #expect(walking.watch.isDriving)
        walking.motion(.walking, 200)
        #expect(walking.watch.lastDriveEnd == .onFoot)

        var flying = Stream()
        let (second, _) = Self.drive(&flying)
        flying.events += flying.watch.takeOff(at: Stream.start.addingTimeInterval(second + 5))
        #expect(flying.watch.lastDriveEnd == .flight && !flying.watch.isDriving)
        #expect(WorldRideWatch().lastDriveEnd == nil)
    }

    // MARK: The location source's rules

    /// Only a drive that ended on foot cools down: a parked one goes straight to the fence, one that became a ride
    /// hands over, and a flight ends everything.
    @Test func onlyADriveThatEndedOnFootCoolsDown() {
        #expect(WorldLocationSource.coolsDown(after: .onFoot))
        for end in [WorldDriveEnd.parked, .cycling, .flight] {
            #expect(!WorldLocationSource.coolsDown(after: end), "\(end)")
        }
        #expect(!WorldLocationSource.coolsDown(after: nil))
        #expect(WorldLocationSource.traceCoolDown == 3 * 60)
    }

    /// The leaving fence is armed only with Always, background mapping on and region monitoring available.
    @Test func theFenceNeedsAlwaysAndBackgroundMapping() {
        var armed: [String] = []
        for permission in [WorldLocationPermission.notAsked, .denied, .whileUsing, .always] {
            for mapping in [false, true] {
                for available in [false, true] where WorldLocationSource.armsFence(
                    permission: permission, backgroundMapping: mapping, monitoringAvailable: available) {
                    armed.append("\(permission) \(mapping) \(available)")
                }
            }
        }
        #expect(armed == ["always true true"])
    }

    /// The fence is 150 m plus the reading's accuracy, doubling with each quiet listen up to three, never wider
    /// than a kilometre; a reading too rough, or no accuracy at all, places none.
    @Test func theFenceWidensWithQuietListensAndIsBounded() {
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 0, accuracy: 10) == 160)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 1, accuracy: 10) == 310)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 2, accuracy: 10) == 610)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 3, accuracy: 10) == 1_000)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 40, accuracy: 10) == 1_000)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: -2, accuracy: 0) == 150)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 0, accuracy: 200) == 350)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 0, accuracy: 201) == nil)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 0, accuracy: -1) == nil)
        #expect(WorldLocationSource.fenceRadius(afterQuietListens: 0, accuracy: .infinity) == nil)
        #expect(WorldLocationSource.fenceIdentifier == "WorldLeaving")
    }

    /// A low-power reading starts a listen only when its own speed is faster than walking; a visit only when iOS
    /// saw the person leave within the last ten minutes.
    @Test func lowPowerReadingsAndVisitsStartAListenOnlyWhenMoving() {
        #expect(!WorldLocationSource.listens(afterLowPowerSpeed: nil))
        #expect(!WorldLocationSource.listens(afterLowPowerSpeed: 1.4))
        #expect(!WorldLocationSource.listens(afterLowPowerSpeed: WorldRideWatch.walkingSpeed))
        #expect(WorldLocationSource.listens(afterLowPowerSpeed: 9))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(!WorldLocationSource.listensAfterVisit(departed: nil, now: now))
        #expect(WorldLocationSource.listensAfterVisit(departed: now.addingTimeInterval(-5 * 60), now: now))
        #expect(!WorldLocationSource.listensAfterVisit(departed: now.addingTimeInterval(-11 * 60), now: now))
        #expect(!WorldLocationSource.listensAfterVisit(departed: now.addingTimeInterval(60), now: now))
    }

    /// Without Always (the test host has none) a fast low-power reading starts no listen and arms nothing, and the
    /// map's own updates going to the background leave nothing running.
    @Test func nothingListensWithoutAlways() {
        let source = WorldLocationSource()
        source.deliver(WorldFix(point: Stream.here, accuracy: 8, at: Stream.start, isPrecise: true, speed: 20))
        #expect(!source.isListening && !source.isCoolingDown && source.trace == nil)
        source.stopForeground()
        source.removeLeavingFence()
        #expect(!source.isListening)
    }
}

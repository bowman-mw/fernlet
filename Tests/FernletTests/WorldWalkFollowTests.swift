import CoreLocation
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Following a walk in the background (owner 2026-11-21, pick A of the city-walk investigation: a pocketed walk
/// nobody started cleared only spots). The pure rules: when a listen has seen steady walking, when a followed walk
/// is over, the pace it runs at, and that a drive or a ride always takes it over.
@MainActor
struct WorldWalkFollowTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)

    /// A precise reading `east` metres along at `second`.
    private static func fix(_ east: Double, _ second: Double, speed: Double? = nil, accuracy: Double = 8,
                            precise: Bool = true) -> WorldFix {
        WorldFix(point: here.offset(east: east, north: 0), accuracy: accuracy, at: start.addingTimeInterval(second),
                 isPrecise: precise, speed: speed)
    }

    /// A listen's readings: one every `step` seconds for `seconds`, moving at `pace` metres a second.
    private static func listen(pace: Double, seconds: Double = 120, step: Double = 8, speed: Bool = true,
                               accuracy: Double = 8, motion: WorldMotionKind? = nil) -> WorldWalkFollow {
        var follow = WorldWalkFollow()
        for index in 0...Int(seconds / step) {
            let second = Double(index) * step
            follow.see(fix(pace * second, second, speed: speed ? pace : nil, accuracy: accuracy), motion: motion)
        }
        return follow
    }

    // MARK: Seeing a walk

    /// Two minutes at a steady 1.3 m/s is a walk, by CoreLocation's speed or by the pace between readings, where
    /// Motion is not read.
    @Test func aSteadyWalkIsSeenByPaceAlone() {
        for speed in [true, false] {
            #expect(Self.listen(pace: 1.3, speed: speed).seesWalk(motionRead: false, motion: nil), "speed \(speed)")
        }
    }

    /// It is seen within the listen, not at its end: after about a minute.
    @Test func aWalkIsSeenWellInsideTheListen() {
        #expect(Self.listen(pace: 1.3, seconds: 64).seesWalk(motionRead: false, motion: nil))
        #expect(!Self.listen(pace: 1.3, seconds: 32).seesWalk(motionRead: false, motion: nil), "under the 45 s it must span")
        #expect(WorldWalkFollow.seeTime < WorldLocationSource.listenTime)
    }

    /// Where Motion is read it must say walking or running: nothing yet, stationary, a car or a bike is no walk.
    @Test func whereMotionIsReadItMustSayWalkingOrRunning() {
        let seen = Self.listen(pace: 1.3)
        #expect(seen.seesWalk(motionRead: true, motion: .walking))
        #expect(seen.seesWalk(motionRead: true, motion: .running))
        for kind in [WorldMotionKind.stationary, .automotive, .cycling, .unknown] {
            #expect(!seen.seesWalk(motionRead: true, motion: kind), "\(kind)")
        }
        #expect(!seen.seesWalk(motionRead: true, motion: nil), "no sample yet")
    }

    /// Standing about with GPS drift goes nowhere beyond the readings' accuracy, and a shuffle slower than a walk
    /// is none.
    @Test func driftAndWaitingAboutAreNoWalk() {
        var drift = WorldWalkFollow()
        for step in 0..<15 {
            drift.see(Self.fix(Double((step * 7) % 13) - 6, Double(step) * 8, speed: 0.8))
        }
        #expect(!drift.seesWalk(motionRead: false, motion: nil))
        #expect(!Self.listen(pace: 0.2).seesWalk(motionRead: false, motion: nil))
    }

    /// A car or a bike is left to car and bike detection: readings faster than a walk never make a run, and a run
    /// only counts as one when Motion says running.
    @Test func fasterThanAWalkIsLeftToCarAndBikeDetection() {
        #expect(!Self.listen(pace: 12).seesWalk(motionRead: false, motion: nil))
        #expect(!Self.listen(pace: 4).seesWalk(motionRead: false, motion: nil), "a slow bike, Motion not read")
        #expect(Self.listen(pace: 4, motion: .running).seesWalk(motionRead: true, motion: .running))
        #expect(!Self.listen(pace: 9, motion: .running).seesWalk(motionRead: true, motion: .running), "a car's speed")
    }

    /// Getting out of a car and walking: the fast readings start the run over, so the walk is measured from the
    /// first reading on foot.
    @Test func aFastReadingStartsTheRunOver() {
        var follow = WorldWalkFollow()
        for index in 0..<6 { follow.see(Self.fix(Double(index) * 60, Double(index) * 5, speed: 12)) }
        #expect(follow.runFrom == nil)
        for index in 0..<8 { follow.see(Self.fix(300 + Double(index) * 10.4, 30 + Double(index) * 8, speed: 1.3)) }
        #expect(follow.runFrom?.at == Self.start.addingTimeInterval(30))
        #expect(follow.seesWalk(motionRead: false, motion: nil))
    }

    /// Rough and approximate readings count for nothing, and a gap longer than a minute starts the run over.
    @Test func roughReadingsAndLongGapsDoNotCount() {
        #expect(!Self.listen(pace: 1.3, accuracy: 80).seesWalk(motionRead: false, motion: nil))
        var approximate = WorldWalkFollow()
        for index in 0..<15 { approximate.see(Self.fix(Double(index) * 10, Double(index) * 8, precise: false)) }
        #expect(approximate.runFrom == nil)
        var gapped = WorldWalkFollow()
        gapped.see(Self.fix(0, 0, speed: 1.3))
        gapped.see(Self.fix(100, 90, speed: 1.3))
        #expect(gapped.runFrom?.at == Self.start.addingTimeInterval(90))
        #expect(!gapped.seesWalk(motionRead: false, motion: nil))
    }

    // MARK: A followed walk ends when the person is still

    /// A walk that keeps moving is followed; three minutes with nothing beyond the readings' accuracy ends it.
    @Test func aFollowedWalkEndsAfterThreeStillMinutes() {
        var follow = Self.listen(pace: 1.3)
        follow.start(at: Self.start.addingTimeInterval(120))
        #expect(follow.isFollowing)
        var second = 120.0, east = 156.0
        for _ in 0..<30 {
            second += 20
            east += 26
            follow.follow(Self.fix(east, second, speed: 1.3))
            #expect(!follow.isOver(at: Self.start.addingTimeInterval(second)))
        }
        // Stopped: drift inside the accuracy is no move.
        for step in 0..<8 {
            follow.follow(Self.fix(east + Double(step % 3) * 4, second + Double(step + 1) * 20, speed: 0.3))
        }
        #expect(!follow.isOver(at: Self.start.addingTimeInterval(second + 170)))
        #expect(follow.isOver(at: Self.start.addingTimeInterval(second + WorldWalkFollow.stillTime)))
    }

    /// A phone that hands on no reading at all (it does not move 25 m) is still by the clock alone, from the start.
    @Test func noReadingsAtAllIsStill() {
        var follow = Self.listen(pace: 1.3)
        follow.start(at: Self.start.addingTimeInterval(120))
        #expect(!follow.isOver(at: Self.start.addingTimeInterval(120 + 179)))
        #expect(follow.isOver(at: Self.start.addingTimeInterval(120 + 180)))
    }

    /// Where Motion is read, three minutes of stationary ends the follow though indoor drift still reads as moving;
    /// walking, or stationary for less, does not.
    @Test func motionStationaryEndsAFollowThatStillDrifts() {
        var follow = Self.listen(pace: 1.3)
        let began = Self.start.addingTimeInterval(120)
        follow.start(at: began)
        let later = began.addingTimeInterval(400)
        follow.follow(Self.fix(900, 515, speed: 1))
        #expect(!follow.isOver(at: later, motion: .walking, motionSince: began))
        #expect(!follow.isOver(at: later, motion: .stationary, motionSince: later.addingTimeInterval(-100)))
        #expect(follow.isOver(at: later, motion: .stationary, motionSince: later.addingTimeInterval(-180)))
        // Stationary from before the follow started counts only from its start.
        var early = Self.listen(pace: 1.3)
        early.start(at: began)
        early.follow(Self.fix(200, 150, speed: 1.3))
        #expect(!early.isOver(at: began.addingTimeInterval(60), motion: .stationary, motionSince: Self.start))
    }

    /// A follow is bounded: six hours, whatever the readings say.
    @Test func aFollowIsBounded() {
        var follow = Self.listen(pace: 1.3)
        follow.start(at: Self.start)
        let end = Self.start.addingTimeInterval(WorldWalkFollow.maxTime)
        follow.follow(Self.fix(20_000, WorldWalkFollow.maxTime - 5, speed: 1.3))
        #expect(follow.isOver(at: end))
        #expect(WorldLocationSource.maxWalkTicks > 0 && WorldLocationSource.maxWalkTicks <= 1_000)
        var none = WorldWalkFollow()
        none.follow(Self.fix(0, 0))
        #expect(!none.isFollowing && !none.isOver(at: end), "no follow, nothing to end")
    }

    // MARK: The location source's own rules

    /// The walk pace: every 25 m at ten-metre accuracy, close enough that the 50 m lifts overlap, and never iOS's
    /// hundred-metre mode. In the background the map counts as on no screen while a walk is followed, so the full
    /// pace comes back only with Fernlet open on the map.
    @Test func theWalkPaceLeavesNoGapAndIsNotTheFullPace() {
        let pace = WorldLocationSource.walkPace
        #expect(pace.accuracy == kCLLocationAccuracyNearestTenMeters && pace.distanceFilter == 25)
        #expect(pace.distanceFilter < WorldFogKeeper.liftRadius && pace.accuracy < WorldFogKeeper.maxAccuracy)
        #expect(!WorldLocationSource.mapInFront(onScreen: true, appOpen: false, followingWalk: true))
        #expect(WorldLocationSource.mapInFront(onScreen: true, appOpen: true, followingWalk: true))
        #expect(WorldLocationSource.mapInFront(onScreen: true, appOpen: false, followingWalk: false),
                "a listen or a drive keeps today's rule")
        #expect(!WorldLocationSource.mapInFront(onScreen: false, appOpen: true, followingWalk: true))
        let followed = WorldLocationSource.pace(mapOnScreen: false, recording: false)
        #expect(followed.accuracy == pace.accuracy && followed.distanceFilter == pace.distanceFilter)
    }

    /// A walk is followed for the fitness activity, and never once a drive or a ride is on: their trace takes over,
    /// and a road trip's passenger, whose drive is not traced, loses the follow too.
    @Test func aDriveOrARideAlwaysTakesTheWalkOver() {
        #expect(WorldLocationSource.activityType(for: .walk) == .fitness)
        #expect(WorldLocationSource.followsWalk(driving: false, cycling: false))
        #expect(!WorldLocationSource.followsWalk(driving: true, cycling: false))
        #expect(!WorldLocationSource.followsWalk(driving: false, cycling: true))
        #expect(!WorldLocationSource.startsTrace(.drive, roadTripPassenger: true), "the passenger rule is untouched")
        #expect(WorldLocationSource.startsTrace(.walk, roadTripPassenger: true))
    }

    /// Without Always (the test host), a listen never starts, so no walk is followed whatever the readings say.
    @Test func nothingIsFollowedWithoutAlways() {
        let source = WorldLocationSource(backgroundMapping: { true })
        for index in 0..<20 { source.deliver(Self.fix(Double(index) * 10.4, Double(index) * 8, speed: 1.3)) }
        #expect(!source.isFollowingWalk && source.trace == nil && !source.isListening)
        #expect(!source.walkTick(at: Self.start))
    }

    // MARK: Staying awake after a background wake (the phone log of 2026-11-20)

    /// Background mapping holds its session under exactly the fence's conditions, and only where the app declares
    /// the location background mode.
    @Test func theMappingSessionIsHeldOnlyForBackgroundMapping() {
        var held: [String] = []
        for permission in [WorldLocationPermission.notAsked, .denied, .whileUsing, .always] {
            for mapping in [false, true] {
                for declared in [false, true] where WorldLocationSource.holdsMappingSession(
                    permission: permission, backgroundMapping: mapping, declaresBackground: declared) {
                    held.append("\(permission) \(mapping) \(declared)")
                }
            }
        }
        #expect(held == ["always true true"])
    }

    /// With Fernlet not open the manager gets no distance filter (iOS may suspend an app that sets one beside
    /// significant-change monitoring), at an accuracy inside the hundred metres that rule asks for; open, the pace's own.
    @Test func noDistanceFilterWhileFernletIsNotOpen() {
        for pace in [WorldLocationSource.fullPace, WorldLocationSource.offMapPace, WorldLocationSource.walkPace] {
            #expect(WorldLocationSource.managerFilter(for: pace, appOpen: false) == kCLDistanceFilterNone)
            #expect(WorldLocationSource.managerFilter(for: pace, appOpen: true) == pace.distanceFilter)
            #expect(pace.accuracy <= kCLLocationAccuracyHundredMeters)
        }
    }

    /// The readings are thinned to the pace's spacing instead: one that has not moved is held back, but never longer
    /// than ten seconds, and with Fernlet open every reading goes on.
    @Test func unfilteredReadingsAreThinnedToThePace() {
        let last = Self.fix(0, 0)
        #expect(WorldLocationSource.handsOn(Self.fix(5, 1), after: nil, spacing: 25), "the first")
        #expect(!WorldLocationSource.handsOn(Self.fix(5, 1), after: last, spacing: 25))
        #expect(WorldLocationSource.handsOn(Self.fix(26, 2), after: last, spacing: 25), "moved the spacing")
        #expect(WorldLocationSource.handsOn(Self.fix(1, 10), after: last, spacing: 25), "a still phone, every ten seconds")
        #expect(WorldLocationSource.handsOn(Self.fix(1, -30), after: last, spacing: 25), "a clock change")
        #expect(WorldLocationSource.handsOn(Self.fix(1, 1), after: last, spacing: nil), "Fernlet open: iOS filters")
        #expect(WorldLocationSource.thins(appOpen: false, continuous: true))
        #expect(!WorldLocationSource.thins(appOpen: true, continuous: true), "iOS filters")
        #expect(!WorldLocationSource.thins(appOpen: false, continuous: false), "low-power readings and visits always go on")
        // A walk at 1.3 m/s read every second: what is handed on is never further apart than the fog's lift reaches.
        var kept = [last]
        for second in 1...120 {
            let fix = Self.fix(1.3 * Double(second), Double(second))
            if WorldLocationSource.handsOn(fix, after: kept.last, spacing: WorldLocationSource.walkPace.distanceFilter) { kept.append(fix) }
        }
        #expect(kept.count >= 12 && kept.count <= 14)
        for (before, after) in zip(kept, kept.dropFirst()) {
            #expect(before.point.distance(to: after.point) < WorldFogKeeper.liftRadius)
        }
    }

    /// A listen is over by the clock too: its sleeping task does not run while iOS has Fernlet suspended.
    @Test func aListenEndsByTheClock() {
        let until = Self.start.addingTimeInterval(WorldLocationSource.listenTime)
        #expect(!WorldLocationSource.listenIsOver(until: until, now: Self.start.addingTimeInterval(119)))
        #expect(WorldLocationSource.listenIsOver(until: until, now: until))
        #expect(WorldLocationSource.listenIsOver(until: until, now: Self.start.addingTimeInterval(900)))
        #expect(!WorldLocationSource.listenIsOver(until: nil, now: until))
    }
}

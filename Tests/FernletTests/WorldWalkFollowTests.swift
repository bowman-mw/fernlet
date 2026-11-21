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

    /// Where Motion is read, only a car or a bike refuses a walk (car and bike detection decide those). Saying
    /// walking or running, the rule is the base one. Saying nothing yet, still or "can't tell" (a phone in a hand,
    /// Motion's history running late), the readings alone must be surer: two minutes of steady walking are, one
    /// minute is not.
    @Test func motionRefusesOnlyACarOrABike() {
        let seen = Self.listen(pace: 1.3)
        let minute = Self.listen(pace: 1.3, seconds: 64)
        for kind in [WorldMotionKind.walking, .running] {
            #expect(seen.seesWalk(motionRead: true, motion: kind) && minute.seesWalk(motionRead: true, motion: kind), "\(kind)")
        }
        for kind in [WorldMotionKind.automotive, .cycling] {
            #expect(seen.blocker(motionRead: true, motion: kind) == .motionSaysRide, "\(kind)")
        }
        for kind in [WorldMotionKind.stationary, .unknown, nil] {
            #expect(seen.seesWalk(motionRead: true, motion: kind), "\(String(describing: kind))")
            #expect(minute.blocker(motionRead: true, motion: kind) == .motionUnsure, "\(String(describing: kind))")
        }
        #expect(WorldWalkFollow.sureTime < WorldLocationSource.listenTime && WorldWalkFollow.sureTime > WorldWalkFollow.seeTime)
        #expect(WorldWalkFollow.sureDistance > WorldWalkFollow.seeDistance)
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

    // MARK: Why full listens followed nothing (the phone log of 2026-11-20, section 9), replayed

    /// Blocker 1, the rough first reading. A wake's first good reading comes from Wi-Fi: 60 m accuracy and, here,
    /// 45 m further along the street than the person is. Measured from it, a steady walk counted only after about
    /// 110 s (both hand-overs in the log came 112 s into a 120 s listen), or not at all. Measured from the sharp
    /// reading six seconds later, it is seen within the minute.
    @Test func aRoughFirstReadingNoLongerHidesTheWalk() {
        var follow = WorldWalkFollow()
        follow.see(Self.fix(45, 0, accuracy: 60), motion: .walking)
        var seenAt: Double?
        for index in 1...15 {
            let second = Double(index) * 8 - 2
            follow.see(Self.fix(1.3 * second, second, speed: 1.3), motion: .walking)
            if seenAt == nil, follow.seesWalk(motionRead: true, motion: .walking) { seenAt = second }
        }
        #expect(follow.measureFrom?.accuracy == 8 && follow.runFrom?.accuracy == 60, "the clock keeps the first reading")
        #expect((seenAt ?? 999) <= 62, "seen at \(String(describing: seenAt))")
        // The old measure, from the first reading: |1.3 t - 45| - 68 m reaches 30 m only after t = 110 s.
        let old = { (second: Double) in abs(1.3 * second - 45) - 68 >= WorldWalkFollow.seeDistance }
        #expect(!old(102) && old(112))
        // A later sharp reading does not move the measure: only one within the settle time.
        var late = WorldWalkFollow()
        late.see(Self.fix(0, 0, accuracy: 60), motion: .walking)
        late.see(Self.fix(40, 30, speed: 1.3, accuracy: 60), motion: .walking)
        late.see(Self.fix(52, 40, speed: 1.3), motion: .walking)
        #expect(late.measureFrom?.accuracy == 60)
    }

    /// Blocker 2, Motion. A phone in a hand: Motion says "can't tell" or still through the whole listen while the
    /// readings walk 150 m. That was no walk before; now the readings carry it, late in the listen. Standing in a
    /// shop does not: drift, a wander round the aisles and pacing up and down all stay inside the rule, whatever
    /// Motion says.
    @Test func aPhoneInAHandIsFollowedAndAShopIsNot() {
        for kind in [WorldMotionKind.unknown, .stationary] {
            var follow = WorldWalkFollow()
            var seenAt: Double?
            for index in 0...24 {
                let second = Double(index) * 5
                follow.see(Self.fix(1.3 * second, second, speed: 1.3), motion: kind)
                if seenAt == nil, follow.seesWalk(motionRead: true, motion: kind) { seenAt = second }
            }
            #expect((seenAt ?? 0) >= WorldWalkFollow.sureTime && (seenAt ?? 999) <= 90, "\(kind): \(String(describing: seenAt))")
        }
        var shops: [String: WorldWalkFollow] = [:]
        var seen: [String] = []
        for index in 0...24 {
            let second = Double(index) * 5
            // Drift indoors at 30 m accuracy, wandering up to 40 m off.
            shops["drift", default: WorldWalkFollow()].see(Self.fix(Double((index * 17) % 81) - 40, second, speed: 0.6, accuracy: 30))
            // Pacing a 25 m aisle at a walk's pace.
            let lap = second.truncatingRemainder(dividingBy: 50)
            shops["pacing", default: WorldWalkFollow()].see(Self.fix(lap <= 25 ? lap : 50 - lap, second, speed: 1.0))
            // A slow shuffle along a queue: 20 m in two minutes.
            shops["queue", default: WorldWalkFollow()].see(Self.fix(second / 6, second, speed: 0.2))
            // Asked after every reading, as the listen asks, whatever Motion says and where it is not read.
            for (name, shop) in shops {
                let kinds: [WorldMotionKind?] = [.walking, .stationary, .unknown, nil]
                if kinds.contains(where: { shop.seesWalk(motionRead: true, motion: $0) }) || shop.seesWalk(motionRead: false, motion: nil) {
                    seen.append("\(name) at \(second)")
                }
            }
        }
        #expect(seen.isEmpty && shops.count == 3, "\(seen)")
    }

    /// Blocker 3, the pace rule. One stray reading faster than a walk (GPS speed jumps) no longer starts the run
    /// over; two in a row do, and so does one at a car's speed, so a bike or a car is still left to their detection.
    @Test func oneStrayFastReadingIsPassedBy() {
        func walk(fastAt: Set<Int>, speed: Double) -> WorldWalkFollow {
            var follow = WorldWalkFollow()
            for index in 0...8 {
                let second = Double(index) * 8
                follow.see(Self.fix(1.3 * second, second, speed: fastAt.contains(index) ? speed : 1.3))
            }
            return follow
        }
        let stray = walk(fastAt: [4], speed: 3.4)
        #expect(stray.runFrom?.at == Self.start && stray.seesWalk(motionRead: false, motion: nil))
        let twice = walk(fastAt: [4, 5], speed: 3.4)
        #expect(twice.runFrom?.at == Self.start.addingTimeInterval(48) && twice.blocker(motionRead: false, motion: nil) == .tooShort)
        let car = walk(fastAt: [4], speed: 9)
        #expect(car.runFrom?.at == Self.start.addingTimeInterval(40), "a car's speed starts it over at once")
    }

    /// What still stands in the way, by name, for the diary: readings all rougher than 65 m are no run at all (and
    /// are counted as rough), readings of 65 m accuracy cannot show 30 m beyond it in two minutes, a walk too short,
    /// too slow or too fast says so.
    @Test func theBlockerSaysWhatStoodInTheWay() {
        let rough = Self.listen(pace: 1.3, accuracy: 80)
        #expect(rough.blocker(motionRead: true, motion: .walking) == .noRun && rough.goodSeen == 0 && rough.roughSeen == 16)
        let wifi = Self.listen(pace: 1.3, accuracy: 65)
        #expect(wifi.blocker(motionRead: true, motion: .walking) == .notFar && wifi.goodSeen == 16 && wifi.roughSeen == 0)
        #expect(Self.listen(pace: 1.3, seconds: 32).blocker(motionRead: true, motion: .walking) == .tooShort)
        #expect(Self.listen(pace: 0.4).blocker(motionRead: false, motion: nil) == .tooSlow)
        #expect(Self.listen(pace: 12).blocker(motionRead: false, motion: nil) == .noRun, "never at walking pace")
        #expect(WorldWalkFollow().blocker(motionRead: false, motion: nil) == .noRun)
        #expect(Self.listen(pace: 1.3).blocker(motionRead: true, motion: .walking) == nil)
        var counted = Self.listen(pace: 1.3)
        counted.countFromHere()
        #expect(counted.goodSeen == 0 && counted.runFrom != nil, "a listen counts its own readings and keeps the run")
        #expect(WorldWalkBlocker.allCases.map(\.rawValue) == ["motionSaysRide", "noRun", "tooShort", "notFar", "tooSlow",
                                                              "tooFast", "motionUnsure"], "frozen: the diary's file holds them")
    }

    // MARK: Leaving the front while moving (the phone log of 2026-11-20, section 9)

    /// The recent readings show movement once one is 20 m beyond both accuracies from an earlier one, and stop
    /// showing it a minute after the last that did. Standing still with drift, and rough readings, never do.
    @Test func theMoveWatchTellsMovingFromStandingStill() {
        var walking = WorldMoveWatch()
        var firstMoved: Double?
        for index in 0...12 {
            let second = Double(index) * 5
            walking.observe(Self.fix(1.3 * second, second, speed: 1.3))
            if firstMoved == nil, walking.isMoving(at: Self.start.addingTimeInterval(second)) { firstMoved = second }
        }
        #expect(firstMoved == 30, "36 m at 1.3 m/s")
        #expect(walking.isMoving(at: Self.start.addingTimeInterval(60 + WorldMoveWatch.freshTime)))
        #expect(!walking.isMoving(at: Self.start.addingTimeInterval(61 + WorldMoveWatch.freshTime)), "stopped a minute ago")
        #expect(!walking.isMoving(at: Self.start.addingTimeInterval(-5)), "a clock change")
        var still = WorldMoveWatch(), rough = WorldMoveWatch()
        for index in 0...60 {
            let second = Double(index) * 5
            still.observe(Self.fix(Double((index * 7) % 13) - 6, second, accuracy: 10))
            rough.observe(Self.fix(1.3 * second, second, accuracy: 90))
            #expect(!still.isMoving(at: Self.start.addingTimeInterval(second)))
        }
        #expect(still.movedAt == nil && rough.movedAt == nil)
        #expect(still.kept.count <= WorldMoveWatch.maxKept && WorldMoveWatch.maxKept == 13)
    }

    /// Leaving the front starts a listen only when the person is moving: by the readings, or by Motion read within
    /// the last minute saying anything but still or "can't tell". Old news and standing still start nothing.
    @Test func leavingTheFrontListensOnlyWhenMoving() {
        let now = Self.start
        let fresh = now.addingTimeInterval(-20), old = now.addingTimeInterval(-90)
        #expect(WorldLocationSource.listensOnLeaving(readingsMoving: true, motion: nil, motionKnown: nil, now: now))
        #expect(WorldLocationSource.listensOnLeaving(readingsMoving: true, motion: .stationary, motionKnown: fresh, now: now))
        for kind in [WorldMotionKind.walking, .running, .cycling, .automotive] {
            #expect(WorldLocationSource.listensOnLeaving(readingsMoving: false, motion: kind, motionKnown: fresh, now: now), "\(kind)")
            #expect(!WorldLocationSource.listensOnLeaving(readingsMoving: false, motion: kind, motionKnown: old, now: now), "old \(kind)")
            #expect(!WorldLocationSource.listensOnLeaving(readingsMoving: false, motion: kind, motionKnown: nil, now: now))
        }
        for kind in [WorldMotionKind.stationary, .unknown, nil] {
            #expect(!WorldLocationSource.listensOnLeaving(readingsMoving: false, motion: kind, motionKnown: fresh, now: now),
                    "\(String(describing: kind))")
        }
    }

    /// A walk with Fernlet opened and closed: the readings taken while it was open already count, so the listen that
    /// starts as it leaves the front sees the walk with its first reading. With Fernlet open the readings are shown
    /// to the walk rules only while no walk the person started records, and no follow starts in front.
    @Test func aWalkSeenInFrontIsFollowedAsSoonAsFernletLeaves() {
        var follow = WorldWalkFollow()
        var moves = WorldMoveWatch()
        // A minute and a half with Fernlet open, a reading every 10 m (iOS's filter in front).
        for index in 0...11 {
            let fix = Self.fix(Double(index) * 10.4, Double(index) * 8, speed: 1.3)
            follow.see(fix, motion: .walking)
            moves.observe(fix)
        }
        let left = Self.start.addingTimeInterval(90)
        #expect(WorldLocationSource.listensOnLeaving(readingsMoving: moves.isMoving(at: left), motion: nil, motionKnown: nil, now: left))
        follow.countFromHere()
        follow.see(Self.fix(124.8, 96, speed: 1.3), motion: .walking)
        #expect(follow.seesWalk(motionRead: true, motion: .walking) && follow.goodSeen == 1)
        #expect(WorldLocationSource.watchesForWalk(listening: false, appOpen: true, walking: false))
        #expect(!WorldLocationSource.watchesForWalk(listening: false, appOpen: true, walking: true))
        #expect(WorldLocationSource.watchesForWalk(listening: true, appOpen: false, walking: false))
        #expect(!WorldLocationSource.watchesForWalk(listening: false, appOpen: false, walking: false), "low-power readings")
        // Standing still in front, then leaving: nothing to listen for.
        var still = WorldMoveWatch()
        for index in 0...11 { still.observe(Self.fix(Double(index % 3), Double(index) * 8, accuracy: 10)) }
        #expect(!WorldLocationSource.listensOnLeaving(readingsMoving: still.isMoving(at: left), motion: .stationary,
                                                      motionKnown: left, now: left))
    }

    /// In the test host (no Always) leaving the front starts no listen however the person moves, and coming to the
    /// front and leaving it touches no trace.
    @Test func leavingTheFrontWithoutAlwaysStartsNothing() {
        let source = WorldLocationSource(backgroundMapping: { true })
        source.startForeground()
        for index in 0..<12 { source.deliver(Self.fix(Double(index) * 10.4, Double(index) * 8, speed: 1.3)) }
        source.stopForeground()
        #expect(!source.isListening && source.trace == nil)
    }
}

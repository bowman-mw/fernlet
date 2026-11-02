import Foundation
import CoreGraphics
import QuartzCore
import Testing
import WorldMapStore
@testable import Fernlet

/// Follow smoothing (2026-11-01): Sprout, and the camera that follows it, glide between readings instead of
/// stepping from one to the next. Each test runs the glide frame by frame at 60 frames a second on a straight
/// road north, and checks what the owner would see: no step bigger than the speed allows, no going backwards,
/// Sprout close to the person in a car, and resting exactly on the last reading once the person stops.
@MainActor
struct WorldFollowGlideTests {
    private static let start = GeoPoint(45.5205, -122.6255)
    private static let frame = 1.0 / 60
    private static let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A reading `north` metres up the road at `second` seconds, moving `speed` metres a second north.
    private static func fix(north: Double, second: Double, speed: Double?, course: Double? = 0) -> WorldFix {
        WorldFix(point: start.offset(east: 0, north: north), accuracy: 5, at: epoch.addingTimeInterval(second),
                 isPrecise: true, speed: speed, course: course)
    }

    /// Sprout's distance north of the start, frame by frame from `from` to `to` seconds.
    private static func norths(_ glide: WorldFollowGlide, from: Double, to: Double) -> [Double] {
        let frames = Int(((to - from) / frame).rounded())
        return (0..<frames).compactMap { index in
            glide.advance(to: from + Double(index) * frame)?.metres(from: start).north
        }
    }

    /// The largest move between two frames, and the largest move backwards (south).
    private static func steps(_ norths: [Double]) -> (largest: Double, backwards: Double) {
        let deltas = zip(norths.dropFirst(), norths).map { $0 - $1 }
        return (deltas.map(abs).max() ?? 0, -(deltas.min() ?? 0))
    }

    /// Driving at 30 m/s with a reading a second: Sprout moves every frame by about the car's own step, never
    /// back, and stays within a few metres of the car (the lead carries it between readings).
    @Test func aSteadyDriveGlidesAtTheCarsSpeed() {
        let glide = WorldFollowGlide()
        var all: [Double] = []
        for second in 0..<12 {
            let now = Double(second)
            glide.track(Self.fix(north: 30 * now, second: now, speed: 30), smooth: true, now: now)
            all += Self.norths(glide, from: now, to: now + 1)
        }
        // The map opened mid-drive (Sprout at rest on the first reading): it catches up at no more than about
        // twice the car's speed, and from then on keeps the car's own pace.
        let catchingUp = Self.steps(Array(all.prefix(240).dropFirst(60)))
        #expect(catchingUp.largest < 30 * Self.frame * 2.2)
        let steps = Self.steps(Array(all.dropFirst(240)))
        #expect(steps.largest < 30 * Self.frame * 1.25)
        #expect(steps.backwards < 0.01)
        let late = glide.advance(to: 11.5)?.metres(from: Self.start).north ?? 0
        #expect(abs(late - 30 * 11.5) < 3)
    }

    /// Cruising at 15 m/s, then braking at 3 m/s² to a stop, a reading a second, the last one standing still:
    /// Sprout never rolls back along the road while the car moves, overshoots the stop by less than two metres
    /// (under two points at Home's zoom) and comes to rest exactly on the last reading.
    @Test func brakingSettlesOnTheStopWithoutRollingBack() {
        let glide = WorldFollowGlide()
        var moving: [Double] = []
        for second in 0...9 {
            let t = Double(second), braked = max(0, t - 5)
            let north: Double = 15 * t - 1.5 * braked * braked
            let speed: Double = 15 - 3 * braked
            glide.track(Self.fix(north: north, second: t, speed: speed), smooth: true, now: t)
            moving += Self.norths(glide, from: t, to: t + 1)
        }
        glide.track(Self.fix(north: 112.5, second: 10, speed: 0), smooth: true, now: 10)
        let stopping = Self.norths(glide, from: 10, to: 20)
        #expect(Self.steps(Array(moving.dropFirst(240))).backwards < 0.01)
        #expect(((moving + stopping).max() ?? 0) < 112.5 + 2)
        let rest = glide.advance(to: 20)?.metres(from: Self.start).north ?? 0
        #expect(abs(rest - 112.5) < 0.01)
        #expect(glide.isSettled(at: 20))
    }

    /// A reading that doesn't come (a tunnel): the lead runs on for its limit and then slows to a stop, so Sprout
    /// goes no further than its tail past where the car was due.
    @Test func aLateReadingLetsTheLeadSlowToAStop() {
        let glide = WorldFollowGlide()
        for second in 0...3 {
            let t = Double(second)
            glide.track(Self.fix(north: 20 * t, second: t, speed: 20), smooth: true, now: t)
        }
        let coast = Self.norths(glide, from: 3, to: 9)
        let furthest = coast.max() ?? 0
        let limit = 60 + 20 * (WorldGlidePath.leadLimit + WorldGlidePath.leadTail)
        #expect(furthest <= limit + 0.5)
        #expect(Self.steps(coast).backwards < 0.01)
        #expect(glide.isSettled(at: 9))
    }

    /// Walking: readings ten metres apart every seven seconds, too seldom to guess across. Sprout walks from one
    /// to the next over the gap (never a step bigger than a brisk walker's frame) and stands on each reading by the
    /// time the next comes.
    @Test func aWalkGlidesFromReadingToReading() {
        let glide = WorldFollowGlide()
        var all: [Double] = []
        for step in 0..<5 {
            let t = Double(step) * 7
            glide.track(Self.fix(north: Double(step) * 10, second: t, speed: 1.4, course: nil), smooth: true, now: t)
            if step > 0 {
                #expect(abs((glide.advance(to: t)?.metres(from: Self.start).north ?? 0) - Double(step - 1) * 10) < 0.05)
            }
            all += Self.norths(glide, from: t, to: t + 7)
        }
        let steps = Self.steps(all)
        #expect(steps.largest < 4 * Self.frame)
        #expect(steps.backwards < 0.01)
    }

    /// Running: a reading every three seconds, twelve metres apart (City Run). Sprout reaches each reading at the
    /// runner's pace and runs on through it, never stopping at a reading and starting again, and never faster than
    /// a sprint's frame.
    @Test func aRunKeepsItsPaceThroughEachReading() {
        let glide = WorldFollowGlide()
        var all: [Double] = []
        for step in 0..<6 {
            let t = Double(step) * 3
            glide.track(Self.fix(north: Double(step) * 12, second: t, speed: 4, course: 0), smooth: true, now: t)
            all += Self.norths(glide, from: t, to: t + 3)
        }
        let running = Array(all.dropFirst(360))
        let slowest = zip(running.dropFirst(), running).map { $0 - $1 }.min() ?? 0
        #expect(slowest > 4 * Self.frame * 0.4)
        #expect(Self.steps(running).largest < 9 * Self.frame)
    }

    /// A reading lands without a jump, in place or in speed, even mid catch-up and on a new course.
    @Test func aReadingLandsWithoutAJump() {
        let glide = WorldFollowGlide()
        glide.track(Self.fix(north: 0, second: 0, speed: 25), smooth: true, now: 0)
        glide.track(Self.fix(north: 25, second: 1, speed: 25), smooth: true, now: 1)
        let earlier = glide.advance(to: 1.995 - Self.frame)?.metres(from: Self.start).north ?? 0
        let before = glide.advance(to: 1.995)?.metres(from: Self.start).north ?? 0
        glide.track(Self.fix(north: 46, second: 2, speed: 18, course: 10), smooth: true, now: 1.995)
        let after = glide.advance(to: 1.995)?.metres(from: Self.start).north ?? 0
        #expect(abs(after - before) < 0.001)
        // Nor in speed: the frame after it moves as far as the frame before it did, within a few cm.
        let next = glide.advance(to: 1.995 + Self.frame)?.metres(from: Self.start).north ?? 0
        #expect(abs((next - after) - (before - earlier)) < 0.05)
    }

    /// Jumps: a reading that isn't smooth (behind a panel, Reduce Motion, off following), one far from Sprout,
    /// and one far away after a long gap all stand Sprout on the reading at once; the same reading again changes
    /// nothing but whether the next glides.
    @Test func jumpsStandSproutOnTheReadingAtOnce() {
        let glide = WorldFollowGlide()
        glide.track(Self.fix(north: 0, second: 0, speed: 0), smooth: true, now: 0)
        glide.track(Self.fix(north: 40, second: 1, speed: 30), smooth: false, now: 1)
        #expect(glide.shown == Self.start.offset(east: 0, north: 40))
        glide.track(Self.fix(north: 1_000, second: 2, speed: 30), smooth: true, now: 2)
        #expect(glide.shown == Self.start.offset(east: 0, north: 1_000))
        glide.track(Self.fix(north: 1_080, second: 60, speed: 1), smooth: true, now: 60)
        #expect(glide.shown == Self.start.offset(east: 0, north: 1_080))
        let path = glide.path
        glide.track(Self.fix(north: 1_080, second: 60, speed: 1), smooth: false, now: 61)
        #expect(glide.path == path)
        #expect(!glide.isSmooth)
    }

    /// The lead's rate is continuous where it starts slowing, and it never runs past its tail.
    @Test func theLeadSlowsWithoutAKink() {
        let edge = WorldGlidePath.leadLimit
        #expect(abs(WorldGlidePath.lead(edge + 1e-6).rate - 1) < 1e-3)
        #expect(WorldGlidePath.lead(100).distance <= edge + WorldGlidePath.leadTail)
        let early = WorldGlidePath.lead(0.5)
        #expect(early.distance == 0.5 && early.rate == 1)
    }

    /// Only a fast reading with readings about a second apart leads: a walk, a jog's long gaps, and a first
    /// reading don't; without a course, the lead points along the line from the last reading.
    @Test func onlyFrequentFastReadingsLead() {
        let previous = Self.fix(north: 0, second: 0, speed: 20)
        let lead = WorldFollowGlide.leadVelocity(of: Self.fix(north: 20, second: 1, speed: 20, course: nil), after: previous, interval: 1)
        #expect(abs(lead.north - 20) < 1e-9 && abs(lead.east) < 1e-9)
        let walk = WorldFollowGlide.leadVelocity(of: Self.fix(north: 10, second: 7, speed: 1.4), after: previous, interval: 7)
        #expect(walk.east == 0 && walk.north == 0)
        let gap = WorldFollowGlide.leadVelocity(of: Self.fix(north: 60, second: 3, speed: 20), after: previous, interval: 3)
        #expect(gap.east == 0 && gap.north == 0)
        let first = WorldFollowGlide.leadVelocity(of: Self.fix(north: 0, second: 0, speed: 20), after: nil, interval: nil)
        #expect(first.east == 0 && first.north == 0)
        let east = WorldFollowGlide.leadVelocity(of: Self.fix(north: 0, second: 1, speed: 10, course: 90), after: previous, interval: 1)
        #expect(abs(east.east - 10) < 1e-9 && abs(east.north) < 1e-9)
    }

    /// The pan lost mid-drive: the follow driver's own camera sets, landing in a pan's glide after the finger lifted,
    /// neither end the person's move nor count as one, so the pan is adopted when MapKit's glide ends.
    @Test func theDriversFramesNeverEndThePersonsMove() {
        var move = AppleMapPersonMove()
        let started = move.willChange(touched: true, ownFrame: false)
        #expect(started && move.isMoving, "the finger starts it")
        let endedByFrame = move.didChange(ownFrame: true)
        #expect(!endedByFrame, "a frame of the driver's ending ends nothing")
        let startedByFrame = move.willChange(touched: false, ownFrame: true)
        #expect(!startedByFrame && move.isMoving, "nor does one starting: the person's move is still under way")
        let ended = move.didChange(ownFrame: false)
        #expect(ended && !move.isMoving, "MapKit's glide ending is its end")
        let untouched = move.willChange(touched: false, ownFrame: false)
        #expect(untouched && !move.isMoving, "a move with no finger on the map is no move of the person's")
        let adopted = move.didChange(ownFrame: false)
        #expect(!adopted, "so there is nothing to adopt")
    }

    /// The fog treats the following camera's slide as the map sitting still (the grass keeps swaying, a zoom's
    /// scale still settles); a fast slide or a change of zoom is the map moving.
    @Test func aFollowingCamerasSlideIsDriftNotAMove() {
        let size = CGSize(width: 402, height: 874)
        let old = MapViewport(minX: 0.2, minY: 0.3, width: 0.0004, height: 0.00087)
        let unitsPerPoint = old.width / 402
        let slide = MapViewport(minX: old.minX + unitsPerPoint * 2, minY: old.minY + unitsPerPoint, width: old.width, height: old.height)
        #expect(NatureFogMapView.isDrift(from: old, to: slide, size: size))
        let pan = MapViewport(minX: old.minX + unitsPerPoint * 30, minY: old.minY, width: old.width, height: old.height)
        #expect(!NatureFogMapView.isDrift(from: old, to: pan, size: size))
        let pinch = MapViewport(minX: old.minX, minY: old.minY, width: old.width * 1.02, height: old.height * 1.02)
        #expect(!NatureFogMapView.isDrift(from: old, to: pinch, size: size))
    }
}

import Foundation
import QuartzCore
import SwiftUI
import WorldMapStore

/// One stretch of Sprout's glide on the live map, from one reading until the next (follow smoothing,
/// 2026-11-01: "Sprout jumps. The camera also jumps").
///
/// Two parts, added together, in metres east and north of the reading:
/// - **Where the person is now** (the lead). Fast enough that readings come about once a second (a drive, a
///   bike ride), the person is carried on along the reading's course at its speed for ``leadLimit`` seconds,
///   so Sprout keeps moving between readings; a reading that is late lets the lead slow to a stop over
///   ``leadTail`` instead of running on. Slower (a walk, a run), readings come only every ten metres, too far
///   apart to guess across, so the person stands at the reading.
/// - **Where Sprout was** (the correction). Sprout's own place and speed when the reading came, eased away
///   over ``settle`` seconds as a cubic Hermite: no jump in place or speed when a reading lands. At a walk the
///   settle lasts until the next reading is due and Sprout arrives at the person's own pace (``arrival``),
///   which then fades over ``leadTail``, so Sprout walks on through each reading rather than stopping at it. In a car a
///   correction that would carry Sprout backwards along the road is stretched until it only slows Sprout down,
///   so Sprout never overshoots and comes back; stopped, it settles back onto the reading.
///
/// Pure values: the time is the caller's (Core Animation's media time), so tests run it by hand.
nonisolated struct WorldGlidePath: Equatable, Sendable {
    /// Metres east and north.
    typealias Step = (east: Double, north: Double)

    /// The reading the stretch starts from.
    let fix: GeoPoint
    /// The person's speed along the course, metres a second east and north (zero without a lead).
    let velocity: Step
    /// When the reading came (media time).
    let begin: CFTimeInterval
    /// Where Sprout stood when it came, from the reading, and how much faster it moved than ``velocity``.
    let offset: Step
    let offsetVelocity: Step
    /// How long the correction takes, in seconds.
    let settle: Double
    /// At a walk or a run: the speed Sprout reaches the reading at (the person's pace along their way), fading
    /// over ``leadTail`` after it; zero in a car and when Sprout stops on the reading.
    var arrival: Step = (0, 0)

    /// How long the lead runs at full speed after a reading (a reading a second, with room for one late).
    static let leadLimit = 1.25
    /// How quickly a lead past ``leadLimit`` slows to a stop, in seconds (the most it runs on is speed × this).
    static let leadTail = 0.35
    /// The slowest a person goes, in metres a second, for the lead to run (about a jog: a walk's or a run's
    /// readings, ten metres apart, come too seldom to guess across).
    static let leadSpeed = 4.0
    /// The longest gap between readings, in seconds, that still leads (a car's come about once a second).
    static let leadInterval = 2.0
    /// The shortest and longest a correction lasts, in seconds.
    static let settleRange: ClosedRange<Double> = 0.45...8
    /// The correction in a car, before any stretch.
    static let leadSettle = 0.6
    /// Below this speed, in metres a second, the person counts as standing still.
    static let stillSpeed = 0.5
    /// How long Sprout takes to slow to a stop once past a reading, in seconds (it rolls on half this at its speed).
    static let coastSeconds = 0.6
    /// How fast, in gaps per settle, Sprout may come in to a reading it stops on (just under a Hermite's 3).
    static let monotoneLimit = 2.9

    /// Sprout still at `point` from `now` on (the first reading, a jump, Reduce Motion).
    static func still(at point: GeoPoint, now: CFTimeInterval) -> WorldGlidePath {
        WorldGlidePath(fix: point, velocity: (0, 0), begin: now, offset: (0, 0), offsetVelocity: (0, 0),
                       settle: settleRange.lowerBound)
    }

    /// The stretch for a reading at `fix` moving at `velocity` (already zero when it shouldn't lead) and
    /// `pace` metres a second (CoreLocation's speed, if any), with Sprout at `shown` moving at `shownVelocity`
    /// when it came at `now`, `interval` seconds after the last one.
    static func toward(_ fix: GeoPoint, velocity: Step, pace: Double?, course: Double?, interval: Double?,
                       shown: GeoPoint, shownVelocity: Step, now: CFTimeInterval) -> WorldGlidePath {
        let offset = shown.metres(from: fix)
        let offsetVelocity = (east: shownVelocity.east - velocity.east, north: shownVelocity.north - velocity.north)
        guard velocity.east == 0 && velocity.north == 0 else {
            return WorldGlidePath(fix: fix, velocity: velocity, begin: now, offset: offset, offsetVelocity: offsetVelocity,
                                  settle: leadSettle(offset: offset, velocity: velocity))
        }
        let passed = offset.east * shownVelocity.east + offset.north * shownVelocity.north > 0
        if let pace, pace >= stillSpeed, passed { return coast(from: shown, velocity: shownVelocity, now: now) }
        let walk = walkSettle(interval: interval, metres: shown.distance(to: fix), pace: pace)
        let start = approach(offset: offset, offsetVelocity: offsetVelocity, settle: walk)
        var path = WorldGlidePath(fix: fix, velocity: velocity, begin: now, offset: offset,
                                  offsetVelocity: start.offsetVelocity, settle: start.settle)
        path.arrival = arrival(offset: offset, startVelocity: start.offsetVelocity, settle: start.settle,
                               pace: pace, course: course)
        return path
    }

    /// The speed Sprout reaches the reading at: the person's `pace` along their `course` (or along the way to the
    /// reading without one), never back the way Sprout came, and held so that, with the speed it starts at, the
    /// approach can't carry it past the reading and back (Fritsch–Carlson: the two speeds, over the gap's own
    /// speed, within a circle of radius 3).
    static func arrival(offset: Step, startVelocity: Step, settle: Double, pace: Double?, course: Double?) -> Step {
        let gap = (offset.east * offset.east + offset.north * offset.north).squareRoot()
        guard let pace, pace >= stillSpeed, gap > 0, settle > 0 else { return (0, 0) }
        let toward = (east: -offset.east / gap, north: -offset.north / gap)
        var way = toward
        if let course, course.isFinite {
            let radians = course * .pi / 180
            way = (sin(radians), cos(radians))
        }
        let along = way.east * toward.east + way.north * toward.north
        guard along > 0 else { return (0, 0) }
        let secant = gap / settle
        let opening = max(0, startVelocity.east * toward.east + startVelocity.north * toward.north) / secant
        let room = (max(0, monotoneLimit * monotoneLimit - opening * opening)).squareRoot() * secant / along
        let speed = min(pace, room)
        return (way.east * speed, way.north * speed)
    }

    /// Sprout already past a reading while the person still moves (a car slowing for a light, past the last
    /// guess): it slows to a stop ahead over ``coastSeconds`` rather than turning back; the next reading takes it on,
    /// or, the person stopped, settles it back.
    static func coast(from shown: GeoPoint, velocity: Step, now: CFTimeInterval) -> WorldGlidePath {
        let half = coastSeconds / 2
        let stop = shown.offset(east: velocity.east * half, north: velocity.north * half)
        return WorldGlidePath(fix: stop, velocity: (0, 0), begin: now, offset: shown.metres(from: stop),
                              offsetVelocity: velocity, settle: coastSeconds)
    }

    /// In a car: ``leadSettle``, stretched for a large gap so the correction is never quicker than the car itself
    /// (a Hermite's quickest pull is 1.5 × the gap over the settle): Sprout ahead along the road only slows,
    /// never rolls back, and Sprout behind (the map opened mid-drive) catches up at about twice the speed at most.
    static func leadSettle(offset: Step, velocity: Step) -> Double {
        let speed = (velocity.east * velocity.east + velocity.north * velocity.north).squareRoot()
        guard speed > 0 else { return leadSettle }
        let gap = (offset.east * offset.east + offset.north * offset.north).squareRoot()
        return min(max(leadSettle, 2 * gap / speed), settleRange.upperBound)
    }

    /// Without a lead Sprout comes in to the reading and stops on it: a fast approach is shortened, or failing
    /// that its speed trimmed, so the Hermite never carries Sprout past the reading and back (Fritsch–Carlson:
    /// the speed toward it at most about three times the gap over the time).
    static func approach(offset: Step, offsetVelocity: Step, settle: Double) -> (settle: Double, offsetVelocity: Step) {
        let gap = (offset.east * offset.east + offset.north * offset.north).squareRoot()
        guard gap > 0 else { return (settle, offsetVelocity) }
        let toward = (east: -offset.east / gap, north: -offset.north / gap)
        let closing = offsetVelocity.east * toward.east + offsetVelocity.north * toward.north
        guard closing > 0 else { return (settle, offsetVelocity) }
        let quickest = min(settle, max(monotoneLimit * gap / closing, settleRange.lowerBound))
        let allowed = monotoneLimit * gap / quickest
        guard closing > allowed else { return (quickest, offsetVelocity) }
        let trim = closing - allowed
        return (quickest, (offsetVelocity.east - trim * toward.east, offsetVelocity.north - trim * toward.north))
    }

    /// At a walk: until the next reading is due, as long as the last gap (a second for a first reading), or
    /// sooner when the person's `pace` would cover the `metres` to the reading sooner (the first steps after
    /// standing a while, a car pulling away).
    static func walkSettle(interval: Double?, metres: Double, pace: Double?) -> Double {
        var settle = interval ?? 1
        if let pace, pace >= stillSpeed { settle = min(settle, metres / pace) }
        return min(max(settle, settleRange.lowerBound), settleRange.upperBound)
    }

    /// Where Sprout stands at `now`.
    func position(at now: CFTimeInterval) -> GeoPoint {
        let step = metres(at: now)
        return fix.offset(east: step.east, north: step.north)
    }

    /// Where Sprout stands at `now`, in metres from the reading.
    func metres(at now: CFTimeInterval) -> Step {
        let age = max(0, now - begin), lead = Self.lead(age), left = correction(age)
        return (velocity.east * lead.distance + left.offset.east, velocity.north * lead.distance + left.offset.north)
    }

    /// How fast Sprout moves at `now`, in metres a second east and north.
    func speed(at now: CFTimeInterval) -> Step {
        let age = max(0, now - begin), lead = Self.lead(age), left = correction(age)
        return (velocity.east * lead.rate + left.rate.east, velocity.north * lead.rate + left.rate.north)
    }

    /// Whether Sprout has come to rest (the correction over and any lead run out).
    func isSettled(at now: CFTimeInterval) -> Bool {
        let age = now - begin
        let leads = velocity.east != 0 || velocity.north != 0
        let arrives = arrival.east != 0 || arrival.north != 0
        guard age >= settle else { return false }
        if leads { return age >= Self.leadLimit + 8 * Self.leadTail }
        return !arrives || age >= settle + 8 * Self.leadTail
    }

    /// How far the lead has carried the person after `age` seconds (in seconds at the reading's speed), and
    /// its rate: full speed to ``leadLimit``, then slowing to a stop.
    static func lead(_ age: Double) -> (distance: Double, rate: Double) {
        guard age > leadLimit else { return (age, 1) }
        let fade = exp(-(age - leadLimit) / leadTail)
        return (leadLimit + leadTail * (1 - fade), fade)
    }

    /// What is left of Sprout's offset after `age` seconds, and how fast it shrinks; past the settle, how far
    /// the ``arrival`` speed has carried Sprout on as it fades.
    private func correction(_ age: Double) -> (offset: Step, rate: Step) {
        guard settle > 0 else { return ((0, 0), (0, 0)) }
        guard age < settle else {
            let fade = exp(-(age - settle) / Self.leadTail), reach = Self.leadTail * (1 - fade)
            return ((arrival.east * reach, arrival.north * reach), (arrival.east * fade, arrival.north * fade))
        }
        let s = age / settle
        let h00 = 2 * s * s * s - 3 * s * s + 1, h10 = s * s * s - 2 * s * s + s, h11 = s * s * s - s * s
        let d00 = (6 * s * s - 6 * s) / settle, d10 = 3 * s * s - 4 * s + 1, d11 = 3 * s * s - 2 * s
        let offset = (h00 * self.offset.east + h10 * settle * offsetVelocity.east + h11 * settle * arrival.east,
                      h00 * self.offset.north + h10 * settle * offsetVelocity.north + h11 * settle * arrival.north)
        let rate = (d00 * self.offset.east + d10 * offsetVelocity.east + d11 * arrival.east,
                    d00 * self.offset.north + d10 * offsetVelocity.north + d11 * arrival.north)
        return (offset, rate)
    }

    static func == (lhs: WorldGlidePath, rhs: WorldGlidePath) -> Bool {
        lhs.fix == rhs.fix && lhs.begin == rhs.begin && lhs.settle == rhs.settle
            && lhs.velocity == rhs.velocity && lhs.offset == rhs.offset && lhs.offsetVelocity == rhs.offsetVelocity
            && lhs.arrival == rhs.arrival
    }
}

/// Where Sprout stands on the live map between readings, and so where the following camera looks (follow
/// smoothing, 2026-11-01).
///
/// Home hands it each reading (``track(_:smooth:now:)``); the base map's frame driver asks it for Sprout's place
/// on every frame while it follows (``advance(to:)``) and points the camera at ``cameraCentre(distance:)``, and
/// Home stands Sprout on ``shown``. So the camera and Sprout move as one, a frame at a time, and the map slides
/// under a Sprout that keeps its place on screen. Not observed: writing ``shown`` on every frame redraws nothing
/// by itself; the map's own viewport report, a frame later, redraws the layers and Sprout together.
///
/// Off following, behind a panel, and with Reduce Motion on, each reading is a jump (`smooth` false): Sprout
/// stands on it at once and the camera, when it follows, jumps with it.
@MainActor
final class WorldFollowGlide {
    /// Where Sprout stands now; nil before the first reading.
    private(set) var shown: GeoPoint?
    /// Whether the last reading glides (the camera eases after it) or jumped.
    private(set) var isSmooth = false
    /// The stretch under way.
    private(set) var path: WorldGlidePath?
    /// The last reading tracked.
    private var lastFix: WorldFix?

    /// Further than this from Sprout, in metres, a reading is a jump (a teleport, a long gap): never a glide
    /// across a town.
    static let jumpMetres = 600.0
    /// A reading this many seconds after the last, and further than ``staleMetres`` from Sprout, is a jump too
    /// (the app back in front after a while): Sprout never crawls across the gap.
    static let staleSeconds = 20.0
    static let staleMetres = 50.0

    /// Takes a new reading. The same reading again (a re-follow, a zoom) only records `smooth`.
    func track(_ fix: WorldFix, smooth: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        guard fix.point.isValid else { return }
        isSmooth = smooth
        let previous = lastFix
        guard fix != previous else { return }
        lastFix = fix
        let current = path.map { $0.position(at: now) }
        guard smooth, let current, let path, current.distance(to: fix.point) <= Self.jumpMetres else {
            jump(to: fix.point, now: now)
            return
        }
        let interval = previous.map { fix.at.timeIntervalSince($0.at) }.flatMap { $0 > 0 ? $0 : nil }
        if let interval, interval > Self.staleSeconds, current.distance(to: fix.point) > Self.staleMetres {
            jump(to: fix.point, now: now)
            return
        }
        let velocity = Self.leadVelocity(of: fix, after: previous, interval: interval)
        self.path = .toward(fix.point, velocity: velocity, pace: fix.speed, course: fix.course, interval: interval,
                            shown: current, shownVelocity: path.speed(at: now), now: now)
        shown = current
    }

    /// Sprout's place at `now`, which it now stands on.
    @discardableResult
    func advance(to now: CFTimeInterval) -> GeoPoint? {
        guard let path else { return shown }
        let point = path.position(at: now)
        guard point.isValid else { return shown }
        shown = point
        return point
    }

    /// Whether Sprout has come to rest at `now` (true with nothing to glide).
    func isSettled(at now: CFTimeInterval) -> Bool {
        path?.isSettled(at: now) ?? true
    }

    /// Where the following camera looks at `distance` metres up, to keep Sprout on its spot (``WorldMapHome/lookAt(_:distance:)``).
    func cameraCentre(distance: Double) -> GeoPoint? {
        shown.map { WorldMapHome.lookAt($0, distance: distance) }
    }

    private func jump(to point: GeoPoint, now: CFTimeInterval) {
        path = .still(at: point, now: now)
        shown = point
    }

    /// The speed the lead carries the person at: the reading's own speed along its course (or, without a
    /// course, along the line from the last reading), only when it is fast and the readings come about once a
    /// second (``WorldGlidePath/leadSpeed``, ``WorldGlidePath/leadInterval``); otherwise none.
    static func leadVelocity(of fix: WorldFix, after previous: WorldFix?, interval: Double?) -> WorldGlidePath.Step {
        guard let speed = fix.speed, speed >= WorldGlidePath.leadSpeed, let interval,
              interval <= WorldGlidePath.leadInterval else { return (0, 0) }
        if let course = fix.course, course.isFinite {
            let radians = course * .pi / 180
            return (speed * sin(radians), speed * cos(radians))
        }
        guard let previous else { return (0, 0) }
        let step = fix.point.metres(from: previous.point)
        let length = (step.east * step.east + step.north * step.north).squareRoot()
        guard length > 0 else { return (0, 0) }
        return (speed * step.east / length, speed * step.north / length)
    }
}

extension EnvironmentValues {
    /// Sprout's glide on the World Home's map, which the base map's camera follows frame by frame; nil for
    /// the maps that never follow anyone.
    @Entry var worldFollowGlide: WorldFollowGlide? = nil
}

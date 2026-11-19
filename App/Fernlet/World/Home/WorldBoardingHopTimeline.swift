import CoreGraphics
import Foundation

/// Which Home the person last saw (the boarding hop, owner 2026-11-18): the map (or the location-off scene) on the
/// ground, or the plane's window in the air. Frozen tokens: the raw values are stored on this iPhone.
nonisolated enum WorldHomeSky: String, Equatable, Sendable {
    case ground
    case air
}

/// Which way Home switched: boarding (the map to the plane) or landing (the plane to the map).
nonisolated enum WorldBoardingHopDirection: String, Equatable, Sendable {
    case boarding
    case landing

    /// The switch from `from` to `to`, or nil when they're the same.
    init?(from: WorldHomeSky, to: WorldHomeSky) {
        switch (from, to) {
        case (.ground, .air): self = .boarding
        case (.air, .ground): self = .landing
        default: return nil
        }
    }
}

/// When the boarding hop plays (owner's picks, page UABPFeySzGuLEisj7bMKn3): this iPhone remembers which Home it
/// last showed; when Home is in front and the Home it should show is the other one, the scene for that direction
/// plays, and the new Home is remembered as it starts, so it never plays twice for one change. A switch there and
/// back while the app was away leaves nothing to play, so scenes never stack. The first look (nothing remembered)
/// plays nothing; a decoy plays nothing and remembers nothing. Pure.
nonisolated enum WorldBoardingHopGate {
    /// What to do now: the scene to play (nil for none) and the Home to remember (nil to leave it).
    struct Decision: Equatable, Sendable {
        let play: WorldBoardingHopDirection?
        let remember: WorldHomeSky?
    }

    /// The decision for Home showing `now`, `remembered` last, in front (`canPlay`) or not, in a decoy or not.
    static func decide(remembered: WorldHomeSky?, now: WorldHomeSky, canPlay: Bool, isDecoy: Bool) -> Decision {
        guard canPlay, !isDecoy else { return Decision(play: nil, remember: nil) }
        guard let remembered else { return Decision(play: nil, remember: now) }
        guard let direction = WorldBoardingHopDirection(from: remembered, to: now) else {
            return Decision(play: nil, remember: nil)
        }
        return Decision(play: direction, remember: now)
    }
}

/// One moment of the boarding hop, everything the scene draws (``WorldBoardingHopTimeline``). Lengths are in points;
/// the plane's spots are worked out by the scene from its size.
nonisolated struct WorldBoardingHopFrame: Equatable, Sendable {
    /// How far the plane has rolled along the runway from where it parks (right is forward).
    var roll: CGFloat = 0
    /// From 0 on the ground to 1 level above the clouds: the plane rises to its cruising spot and the ground and
    /// clouds slide down out of the scene.
    var climb: CGFloat = 0
    /// The plane's pitch in degrees; negative is nose up.
    var tilt: Double = 0
    var gearDown = true
    var doorOpen = true
    /// The steps at the door, 0 gone to 1 in place.
    var steps: Double = 1
    /// Whether Sprout's window shows Sprout (on board).
    var windowLit = false
    /// The speed marks behind the plane (0–3).
    var marks = 0
    /// The touch-down puff, 0 to 1.
    var puff: Double = 0
    /// How far the runway's dashes have run past, for the feel of speed.
    var dashes: CGFloat = 0
    /// Sprout's feet from the parked plane's top-left corner, or nil while Sprout is on board.
    var sprout: CGPoint?
    /// From 0 (the whole plane) to 1 (Sprout's window the size of the in-flight view's glass, where it stands).
    var zoom: CGFloat = 0
    /// The in-flight view drawn over the scene, 0 to 1 (the hand-over at the window).
    var flightView: Double = 0
    /// The whole scene's opacity (its fade into the new Home).
    var opacity: Double = 1
}

/// The boarding hop's five seconds (owner's storyboard v2, 2026-11-18), as pure keyframes.
///
/// **Boarding:** Sprout hops up the steps and in, the door shuts, the plane rolls and lifts off, levels above the
/// clouds with Sprout at its window, and the camera closes in on that window until it is the in-flight view's
/// glass, where the in-flight view takes over. **Landing:** the same hand-over backwards, then down through the
/// clouds, a touch-down puff, a roll to a stop, the door opens and Sprout hops down to the ground. Reduce Motion:
/// the end moment held still for a second, then a short fade.
nonisolated enum WorldBoardingHopTimeline {
    /// The scene's length, and the reduced one's hold and fade.
    static let duration = 5.0
    static let reducedHold = 1.0
    static let reducedFade = 0.3
    /// Points per sprite pixel, for the plane, the steps and Sprout.
    static let pixel: CGFloat = 2
    /// Sprout's path, its feet from the parked plane's top-left: the ground beside the steps, the steps' middle,
    /// the door's sill, and just inside.
    static let ground = CGPoint(x: 276, y: 100)
    static let step = CGPoint(x: 244, y: 88)
    static let sill = CGPoint(x: 212, y: 74)
    static let inside = CGPoint(x: 204, y: 74)
    /// How high each hop rises.
    static let hopHeight: CGFloat = 14
    /// Where Reduce Motion holds: boarding level above the clouds, landing with Sprout on the ground.
    static let boardingStill = 3.6
    static let landingStill = 4.45

    /// How long the scene runs.
    static func length(reduceMotion: Bool) -> Double {
        reduceMotion ? reducedHold + reducedFade : duration
    }

    /// The scene `direction` at `t` seconds in.
    static func frame(_ direction: WorldBoardingHopDirection, at t: Double, reduceMotion: Bool) -> WorldBoardingHopFrame {
        guard reduceMotion else { return direction == .boarding ? boarding(at: t) : landing(at: t) }
        var still = direction == .boarding ? boarding(at: boardingStill) : landing(at: landingStill)
        still.opacity = 1 - ramp(t, reducedHold, reducedHold + reducedFade)
        return still
    }

    /// Boarding at `t`.
    static func boarding(at t: Double) -> WorldBoardingHopFrame {
        var frame = WorldBoardingHopFrame()
        frame.sprout = boardingSprout(at: t)
        let aboard = t >= 1.35
        frame.doorOpen = !aboard
        frame.windowLit = aboard
        frame.steps = 1 - ramp(t, 1.35, 1.6)
        let rolling = ramp(t, 1.7, 2.9)
        frame.roll = 70 * CGFloat(rolling * rolling)
        let run = ramp(t, 1.7, 3.4)
        frame.dashes = 260 * CGFloat(run * run)
        frame.marks = (1.9..<3.0).contains(t) ? 3 : 0
        frame.climb = CGFloat(smooth(ramp(t, 2.6, 3.5)))
        frame.tilt = -10 * sin(Double.pi * ramp(t, 2.6, 3.6))
        frame.gearDown = t < 3.0
        let closing = ramp(t, 3.8, 4.6)
        frame.zoom = CGFloat(closing * closing)
        frame.flightView = ramp(t, 4.4, 4.75)
        frame.opacity = 1 - ramp(t, 4.75, duration)
        return frame
    }

    /// Landing at `t`.
    static func landing(at t: Double) -> WorldBoardingHopFrame {
        var frame = WorldBoardingHopFrame()
        frame.flightView = 1 - ramp(t, 0.15, 0.55)
        let opening = 1 - ramp(t, 0.2, 1.2)
        frame.zoom = CGFloat(opening * opening)
        frame.climb = CGFloat(1 - smooth(ramp(t, 1.25, 2.3)))
        frame.tilt = 4 * sin(Double.pi * ramp(t, 1.25, 2.0)) - 3 * sin(Double.pi * ramp(t, 2.0, 2.5))
        frame.gearDown = t >= 1.5
        let slowing = easeOut(ramp(t, 1.25, 3.0))
        frame.roll = -60 + 60 * CGFloat(slowing)
        frame.dashes = 200 * CGFloat(slowing)
        frame.puff = (2.3..<2.8).contains(t) ? 1 - ramp(t, 2.3, 2.8) : 0
        frame.marks = (2.3..<2.9).contains(t) ? 3 : (2.9..<3.0).contains(t) ? 1 : 0
        let doorOpens = t >= 3.05
        frame.doorOpen = doorOpens
        frame.windowLit = !doorOpens
        frame.steps = ramp(t, 3.05, 3.3)
        frame.sprout = landingSprout(at: t)
        frame.opacity = 1 - ramp(t, 4.5, duration)
        return frame
    }

    /// Sprout boarding: on the ground, two hops up the steps, a step in through the door, then on board.
    static func boardingSprout(at t: Double) -> CGPoint? {
        if t < 0.3 { return ground }
        if t < 0.65 { return hop(from: ground, to: step, ramp(t, 0.3, 0.65)) }
        if t < 1.0 { return hop(from: step, to: sill, ramp(t, 0.65, 1.0)) }
        if t < 1.2 { return snapped(lerp(sill, inside, ramp(t, 1.0, 1.2))) }
        return nil
    }

    /// Sprout landing: on board, out onto the sill, two hops down, and one happy bounce on the ground.
    static func landingSprout(at t: Double) -> CGPoint? {
        if t < 3.2 { return nil }
        if t < 3.3 { return snapped(lerp(inside, sill, ramp(t, 3.2, 3.3))) }
        if t < 3.7 { return hop(from: sill, to: step, ramp(t, 3.3, 3.7)) }
        if t < 4.1 { return hop(from: step, to: ground, ramp(t, 3.7, 4.1)) }
        if t < 4.45 { return hop(from: ground, to: ground, ramp(t, 4.1, 4.45)) }
        return ground
    }

    // MARK: Curves

    /// How far `t` is from `start` to `end`, held between 0 and 1.
    static func ramp(_ t: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return t >= end ? 1 : 0 }
        return min(max((t - start) / (end - start), 0), 1)
    }

    /// Smoothstep: slow at both ends.
    static func smooth(_ u: Double) -> Double {
        u * u * (3 - 2 * u)
    }

    /// Fast first, slowing to the end.
    static func easeOut(_ u: Double) -> Double {
        1 - (1 - u) * (1 - u)
    }

    /// The point `u` of the way from `a` to `b`.
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * CGFloat(u), y: a.y + (b.y - a.y) * CGFloat(u))
    }

    /// A hop `u` of the way from `a` to `b`, rising ``hopHeight`` at its middle, on the sprite-pixel grid.
    static func hop(from a: CGPoint, to b: CGPoint, _ u: Double) -> CGPoint {
        let along = lerp(a, b, u)
        return snapped(CGPoint(x: along.x, y: along.y - hopHeight * CGFloat(sin(Double.pi * u))))
    }

    /// `point` on the sprite-pixel grid, so Sprout's pixels stay crisp.
    static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x / pixel).rounded() * pixel, y: (point.y / pixel).rounded() * pixel)
    }
}

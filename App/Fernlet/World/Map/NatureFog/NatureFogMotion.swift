import CoreGraphics
import QuartzCore
import UIKit

/// The fog's motion (`nf-clear`, approved): a hex clears in 0.4 s while its blades scatter, a tree lifts whole
/// with its leaves scattering, and long grass and flowers sway 1 pt and back over 3.4 s, staggered so
/// neighbours are out of step. Trees stay still. With Reduce Motion there is no sway and no scatter: a
/// clearing hex simply fades out.
struct NatureFogMotion: Equatable {
    /// The person's Reduce Motion setting.
    let reduceMotion: Bool

    /// Whether long grass and flowers sway.
    var sways: Bool { !reduceMotion }
    /// Whether blades and leaves scatter as a hex clears.
    var scatters: Bool { !reduceMotion }

    /// A hex's fade, and the scatter's flight.
    static let clearDuration = 0.4
    /// One sway there and back.
    static let swayPeriod = 3.4
    /// How far the sway leans, in points.
    static let swayDistance = 1.0
    /// The three phase groups' head starts (the mockup's delays of 0, −1.1 and −2.3 s).
    static let staggers: [Double] = [0, 1.1, 2.3]
    /// How long the map must sit still before the sway resumes.
    static let settleDelay = 0.6
    /// The most clearing cells that scatter at once (a long jump in the fog just fades).
    static let maxScattering = 16
    /// Where the 8 blades fly, in hex radii (the mockup's `nf-clear` frame at R = 30).
    static let flights: [CGPoint] = [
        CGPoint(x: -1, y: -1), CGPoint(x: 0.87, y: -1.1), CGPoint(x: -1.1, y: 0.07), CGPoint(x: 1, y: -0.07),
        CGPoint(x: -0.27, y: -1.27), CGPoint(x: 0.33, y: 0.87), CGPoint(x: -0.67, y: -0.53), CGPoint(x: 0.6, y: -0.67),
    ]

    /// The sway for phase `group`: a render-server animation, so a swaying field never redraws a tile. Every
    /// layer counts from the same clock, so a tile drawn later sways in step with its neighbours.
    static func sway(group: Int) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = swayDistance
        animation.duration = swayPeriod / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = 1 - staggers[max(0, min(group, staggers.count - 1))]
        return animation
    }

    /// A tile's crossfade from its old picture to its new one: the cleared grass fades, a lifted tree fades
    /// whole, and the new edge hexes lighten.
    static func clearing() -> CATransition {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = clearDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return fade
    }

    /// One scattering blade or leaf: from `start` out by `offset`, fading, in 0.4 s.
    static func flight(from start: CGPoint, by offset: CGPoint) -> CAAnimationGroup {
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(cgPoint: start)
        move.toValue = NSValue(cgPoint: CGPoint(x: start.x + offset.x, y: start.y + offset.y))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = clearDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }
}

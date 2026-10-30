//
//  ExerciseAnimationPose.swift
//  Fernlet
//
//  The pose the approved motion engine samples, decoded into Swift, and the engine's vector helpers
//  (`V`, `mix`, `RAD`, and the JavaScriptCore `Math` functions they rest on) ported so every
//  floating-point step runs in the same order as the JavaScript and lands on the same bits.
//

import Foundation

/// A point or direction in the engine's model space (z up): the Swift twin of the engine's `[x, y, z]`
/// arrays, decoded from that same three-number array.
nonisolated struct ExerciseAnimationVector: Equatable, Sendable {
    /// Model-space x (the character's right).
    var x: Double
    /// Model-space y (the character's forward).
    var y: Double
    /// Model-space z (up).
    var z: Double
}

nonisolated extension ExerciseAnimationVector: Decodable {
    /// Decodes the engine's `[x, y, z]` array.
    nonisolated init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
        z = try container.decode(Double.self)
    }
}

/// The engine's `V` vector helpers and the `Math` behaviour they depend on, written so each result is
/// bit-identical to JavaScriptCore's: same operand order, `Math.min`/`Math.max` NaN and signed-zero
/// rules, and `Math.hypot` as JavaScriptCore computes it for three arguments.
nonisolated enum ExerciseAnimationMath {
    /// The engine's `RAD` (`Math.PI / 180`).
    static let rad = Double.pi / 180

    /// `V.add(a, b)`.
    @inline(__always)
    static func add(_ a: ExerciseAnimationVector, _ b: ExerciseAnimationVector) -> ExerciseAnimationVector {
        ExerciseAnimationVector(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    /// `V.sub(a, b)`.
    @inline(__always)
    static func sub(_ a: ExerciseAnimationVector, _ b: ExerciseAnimationVector) -> ExerciseAnimationVector {
        ExerciseAnimationVector(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    /// `V.mul(a, s)`.
    @inline(__always)
    static func mul(_ a: ExerciseAnimationVector, _ s: Double) -> ExerciseAnimationVector {
        ExerciseAnimationVector(x: a.x * s, y: a.y * s, z: a.z * s)
    }

    /// `V.dot(a, b)`: a `reduce` that starts from 0, so the sum is `((0 + ax·bx) + ay·by) + az·bz`.
    @inline(__always)
    static func dot(_ a: ExerciseAnimationVector, _ b: ExerciseAnimationVector) -> Double {
        ((0 + a.x * b.x) + a.y * b.y) + a.z * b.z
    }

    /// `V.cross(a, b)`.
    static func cross(_ a: ExerciseAnimationVector, _ b: ExerciseAnimationVector) -> ExerciseAnimationVector {
        ExerciseAnimationVector(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    /// `V.unit(a)`: divides by `Math.hypot(...a) || 1`, so a zero (or NaN) length divides by 1.
    static func unit(_ a: ExerciseAnimationVector) -> ExerciseAnimationVector {
        let length = hypot3(a)
        let divisor = (length == 0 || length.isNaN) ? 1 : length
        return ExerciseAnimationVector(x: a.x / divisor, y: a.y / divisor, z: a.z / divisor)
    }

    /// `V.mix(a, b, t)`: `a + (b - a) · t` per component.
    static func mix(_ a: ExerciseAnimationVector, _ b: ExerciseAnimationVector, _ t: Double) -> ExerciseAnimationVector {
        ExerciseAnimationVector(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
    }

    /// The engine's scalar `mix(a, b, t)`: `a + (b - a) · t`.
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// `Math.hypot(x, y, z)` exactly as JavaScriptCore computes it: libc++'s three-argument
    /// `std::hypot`, which scales far-out magnitudes by a power of two and sums the squares with the
    /// two fused multiply-adds its compiler contracts `x*x + y*y + z*z` into
    /// (`fma(z, z, fma(x, x, y*y))`). Matched bit for bit against JavaScriptCore on 20,000 vectors.
    static func hypot3(_ v: ExerciseAnimationVector) -> Double {
        if v.x.isInfinite || v.y.isInfinite || v.z.isInfinite { return .infinity }
        let largest = cppMax(abs(v.x), cppMax(abs(v.y), abs(v.z)))
        let threshold = 0x1p512
        let scale = largest > threshold ? 0x1p-532 : (largest < 1 / threshold ? 0x1p532 : 1)
        let x = v.x * scale, y = v.y * scale, z = v.z * scale
        let inner = (y * y).addingProduct(x, x)
        return inner.addingProduct(z, z).squareRoot() / scale
    }

    /// C++ `std::max(a, b)`: `(a < b) ? b : a`.
    @inline(__always)
    static func cppMax(_ a: Double, _ b: Double) -> Double {
        a < b ? b : a
    }

    /// `Math.min(a, b)`: NaN wins, and -0 is smaller than +0.
    @inline(__always)
    static func jsMin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a < b { return a }
        if b < a { return b }
        return a.sign == .minus ? a : b
    }

    /// `Math.max(a, b)`: NaN wins, and +0 is larger than -0.
    @inline(__always)
    static func jsMax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        if a > b { return a }
        if b > a { return b }
        return a.sign == .minus ? b : a
    }

    /// `Math.round(x)`: the nearest integer, halves toward +∞ (exact, unlike `floor(x + 0.5)` near
    /// 0.49999999999999994).
    static func jsRound(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let down = x.rounded(.down)
        return x - down >= 0.5 ? down + 1 : down
    }
}

/// An orthonormal frame a box is drawn in (`{right, forward, up}` in the engine).
nonisolated struct ExerciseAnimationBasis: Decodable, Sendable {
    /// The box's width axis.
    var right: ExerciseAnimationVector
    /// The box's depth axis.
    var forward: ExerciseAnimationVector
    /// The box's height axis.
    var up: ExerciseAnimationVector

    /// The engine's default basis: model x, y and z.
    static let world = ExerciseAnimationBasis(
        right: ExerciseAnimationVector(x: 1, y: 0, z: 0),
        forward: ExerciseAnimationVector(x: 0, y: 1, z: 0),
        up: ExerciseAnimationVector(x: 0, y: 0, z: 1))
}

/// One equipment or prop primitive in a pose's `objects` list; which fields are set depends on `type`
/// (`line`, `box`, `bar`, `dumbbell`, `kettlebell`, `pulley`, `handle`, `ball`, `wheel`, `cylinder`,
/// `roller`, `cuff`, `hand`).
nonisolated struct ExerciseAnimationObject: Decodable, Sendable {
    /// The primitive's kind (a token, never displayed).
    var type: String
    /// A palette key (`metal`, `pad`, …) or a raw colour string; nil when the engine set none.
    var color: String?
    /// A polyline's points.
    var points: [ExerciseAnimationVector]?
    /// A polyline's width in model units.
    var width: Double?
    /// The primitive's centre.
    var center: ExerciseAnimationVector?
    /// A box's width, depth and height.
    var size: ExerciseAnimationVector?
    /// A box's frame; nil means the world frame.
    var basis: ExerciseAnimationBasis?
    /// A bar's, dumbbell's, wheel's or cylinder's axis.
    var axis: ExerciseAnimationVector?
    /// A bar's half length.
    var half: Double?
    /// A ball's, wheel's, cylinder's or roller's radius.
    var radius: Double?
    /// A cylinder's or roller's length.
    var length: Double?
    /// A hand primitive's pointing direction.
    var direction: ExerciseAnimationVector?
}

/// One foot's ankle and frame (the shoe is drawn from them).
nonisolated struct ExerciseAnimationFoot: Decodable, Sendable {
    /// The ankle joint.
    var ankle: ExerciseAnimationVector
    /// The foot's sideways axis.
    var right: ExerciseAnimationVector
    /// The foot's toe-ward axis.
    var forward: ExerciseAnimationVector
    /// The foot's sole normal.
    var up: ExerciseAnimationVector
}

/// One sampled pose: what `sampleExercise(e, t)` (or a raw `MOTIONS[e.motion](e, t)` for camera
/// framing) returned, reduced to the fields the renderer reads, plus the engine's `socket` points.
nonisolated struct ExerciseAnimationPose: Decodable, Sendable {
    /// The point the camera frames around.
    var center: ExerciseAnimationVector
    /// The pose's own camera azimuth in degrees (used when the exercise has no preset).
    var view: Double
    /// The pelvis.
    var hip: ExerciseAnimationVector
    /// The torso's up axis.
    var up: ExerciseAnimationVector
    /// The torso's forward axis.
    var forward: ExerciseAnimationVector
    /// The torso's right axis.
    var right: ExerciseAnimationVector
    /// The pelvis's right axis.
    var hipRight: ExerciseAnimationVector
    /// The top of the spine.
    var shoulder: ExerciseAnimationVector
    /// The head's centre.
    var head: ExerciseAnimationVector
    /// The head's own up axis, when it differs from the torso's.
    var headUp: ExerciseAnimationVector?
    /// The head's own right axis, when it differs from the torso's.
    var headRight: ExerciseAnimationVector?
    /// The grip token (`neutral`, `supinated`, …), nil for none.
    var grip: String?
    /// `custom` when the exercise draws its own hands.
    var handStyle: String?
    /// The spine's points, hip first.
    var spine: [ExerciseAnimationVector]
    /// The named joints (`lk`, `la`, `le`, `lh`, …).
    var j: [String: ExerciseAnimationVector]
    /// The feet, in the engine's order.
    var feet: [ExerciseAnimationFoot]
    /// The equipment and props, in draw order.
    var objects: [ExerciseAnimationObject]
    /// `socket(p,-1)`, `socket(p,1)`, `socket(p,-1,false)`, `socket(p,1,false)`; nil on framing poses.
    var sockets: [ExerciseAnimationVector]?
}

/// The approved catalog fields of one exercise that sampling and camera framing read.
nonisolated struct ExerciseAnimationExerciseInfo: Decodable, Sendable {
    /// The package's stable ID, `exercise-NNN`.
    var id: String
    /// A held pose: every progress samples progress 0.
    var hold: Bool
    /// The approved camera preset name, if the exercise has one.
    var viewPreset: String?
    /// The approved camera elevation in degrees, if the exercise overrides the default 18°.
    var viewElevation: Double?
}

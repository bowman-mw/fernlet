//
//  ExerciseAnimationPainter+Body.swift
//  Fernlet
//
//  `drawExercise`'s equipment loop and the character's body parts, in the approved renderer's order.
//

import Foundation

nonisolated extension ExerciseAnimationPainter {
    // MARK: - Equipment

    /// One `p.objects` entry, drawn as its type says (each JavaScript `if` in turn).
    mutating func drawObject(_ object: ExerciseAnimationObject) {
        let center = object.center ?? .nan
        switch object.type {
        case "line": line(object.points ?? [], ink(object.color), width: object.width ?? .nan)
        case "box": box(center, object.size ?? .nan, ink(object.color), basis: object.basis)
        case "bar": drawBar(object, center: center)
        case "dumbbell": drawDumbbell(object, center: center)
        case "kettlebell":
            ring(ExerciseAnimationMath.add(center, ExerciseAnimationVector(x: 0, y: 0, z: -2)), 5,
                 axis: ExerciseAnimationVector(x: 0, y: 1, z: 0), ink("grip"), width: 2)
            sphere(ExerciseAnimationMath.add(center, ExerciseAnimationVector(x: 0, y: 0, z: -11)), 7, ink("ball"))
        case "pulley":
            cylinder(center, axis: ExerciseAnimationVector(x: 1, y: 0, z: 0), length: 2.5, radius: 3.5, ink("grip"),
                     segments: 12)
            sphere(center, 1.2, ink("metal"), outline: false)
        case "handle":
            line([ExerciseAnimationMath.add(center, ExerciseAnimationVector(x: -3, y: 0, z: 0)),
                  ExerciseAnimationMath.add(center, ExerciseAnimationVector(x: 3, y: 0, z: 0))], ink("grip"), width: 3)
        case "ball": sphere(center, object.radius ?? .nan, ink("ball"))
        case "wheel": drawWheel(object, center: center)
        case "cylinder":
            cylinder(center, axis: object.axis ?? .nan, length: object.length ?? .nan, radius: object.radius ?? .nan,
                     ink(object.color))
        case "roller":
            cylinder(center, axis: ExerciseAnimationVector(x: 1, y: 0, z: 0), length: object.length ?? .nan,
                     radius: object.radius ?? .nan, ink("mat"))
        case "cuff": box(center, ExerciseAnimationVector(x: 9, y: 5, z: 6), ink("band"))
        case "hand":
            let tip = ExerciseAnimationMath.add(center, ExerciseAnimationMath.mul(object.direction ?? .nan, 6))
            line([center, tip], ink("skin"), width: 4, outline: true)
        default: return
        }
    }

    /// A barbell: the metal bar between its ends, then a grip cylinder 7 in from each end.
    mutating func drawBar(_ object: ExerciseAnimationObject, center: ExerciseAnimationVector) {
        let axis = object.axis ?? .nan, half = object.half ?? .nan
        let end = { (x: Double) in ExerciseAnimationMath.add(center, ExerciseAnimationMath.mul(axis, x)) }
        line([end(-half), end(half)], ink("metal"), width: 2.5)
        for s in [-1.0, 1] {
            cylinder(end(s * (half - 7)), axis: axis, length: 4, radius: 9, ink("grip"))
        }
    }

    /// A dumbbell: a short metal handle and an 8-sided grip cylinder at each end.
    mutating func drawDumbbell(_ object: ExerciseAnimationObject, center: ExerciseAnimationVector) {
        let a = ExerciseAnimationMath.unit(object.axis ?? .nan)
        line([ExerciseAnimationMath.add(center, ExerciseAnimationMath.mul(a, -8)),
              ExerciseAnimationMath.add(center, ExerciseAnimationMath.mul(a, 8))], ink("metal"), width: 2.5)
        for s in [-1.0, 1] {
            cylinder(ExerciseAnimationMath.add(center, ExerciseAnimationMath.mul(a, s * 6)), axis: a, length: 3.5,
                     radius: 4.7, ink("grip"), segments: 8)
        }
    }

    /// A wheel: its rim ring, a metal hub, and two crossing spokes (the second axis is not normalised,
    /// as in the JavaScript).
    mutating func drawWheel(_ object: ExerciseAnimationObject, center: ExerciseAnimationVector) {
        let axis = object.axis ?? .nan, radius = object.radius ?? .nan
        ring(center, radius, axis: axis, ink("grip"), width: 2.5)
        sphere(center, 2.5, ink("metal"), outline: false)
        let f = ExerciseAnimationMath.unit(Self.wheelSeed(axis)), u = ExerciseAnimationMath.cross(axis, f)
        for spoke in [ExerciseAnimationMath.mul(f, radius), ExerciseAnimationMath.mul(u, radius)] {
            line([ExerciseAnimationMath.sub(center, spoke), ExerciseAnimationMath.add(center, spoke)], ink("metal"),
                 width: 1.2)
        }
    }

    // MARK: - Body

    /// The engine's `socket(p, s, arm)`, as the bridge sampled it.
    func socket(_ s: Double, arm: Bool) -> ExerciseAnimationVector {
        let sockets = pose.sockets ?? []
        let index = (arm ? 0 : 2) + (s < 0 ? 0 : 1)
        guard index < sockets.count else { return .nan }
        return sockets[index]
    }

    /// Both legs: hip socket, knee, ankle as one outlined trouser capsule chain.
    mutating func drawLegs() {
        for s in [-1.0, 1] {
            guard let knee = pose.j[s < 0 ? "lk" : "rk"], let ankle = pose.j[s < 0 ? "la" : "ra"] else { continue }
            line([socket(s, arm: false), knee, ankle], ink("pants"), width: 8.2, outline: true)
        }
    }

    /// The pelvis block, 2.5 below the hip in the hip's frame, without outlines.
    mutating func drawHips() {
        let basis = ExerciseAnimationBasis(right: pose.hipRight, forward: pose.forward, up: pose.up)
        box(ExerciseAnimationMath.add(pose.hip, ExerciseAnimationMath.mul(pose.up, -2.5)),
            ExerciseAnimationVector(x: 20, y: 11, z: 7), ink("pants"), basis: basis, stroke: false)
    }

    /// The torso: one tapered four-sided tube per spine segment (front face `shirt`, the rest
    /// `shirtSide`), a lid on the last, and its four long edges queued for outlining.
    mutating func drawSpine() {
        let spine = pose.spine
        guard spine.count >= 2 else { return }
        let last = Double(spine.count - 1)
        for index in 1..<spine.count {
            let a = spine[index - 1], b = spine[index]
            let frame = torsoFrame(from: a, to: b)
            let w0 = ExerciseAnimationMath.mix(20, 27, Double(index - 1) / last)
            let w1 = ExerciseAnimationMath.mix(20, 27, Double(index) / last)
            let lo = torsoCorners(a, width: w0, frame: frame), hi = torsoCorners(b, width: w1, frame: frame)
            for side in 0..<4 {
                let next = (side + 1) % 4
                poly([lo[side], lo[next], hi[next], hi[side]], ink(side == 2 ? "shirt" : "shirtSide"), stroke: false)
            }
            if index == spine.count - 1 { poly(hi, ink("shirt"), stroke: false) }
            for side in 0..<4 { edges.append((project(lo[side]), project(hi[side]))) }
        }
    }

    /// A spine segment's right and forward axes, made perpendicular to the segment.
    func torsoFrame(from a: ExerciseAnimationVector, to b: ExerciseAnimationVector)
        -> (right: ExerciseAnimationVector, forward: ExerciseAnimationVector) {
        let up = ExerciseAnimationMath.unit(ExerciseAnimationMath.sub(b, a))
        let f = ExerciseAnimationMath.unit(ExerciseAnimationMath.sub(
            pose.forward, ExerciseAnimationMath.mul(up, ExerciseAnimationMath.dot(pose.forward, up))))
        let r = ExerciseAnimationMath.unit(ExerciseAnimationMath.sub(
            pose.right, ExerciseAnimationMath.mul(up, ExerciseAnimationMath.dot(pose.right, up))))
        return (r, f)
    }

    /// `corners(pt, w)`: the torso section's four corners, 10 deep and `w` wide.
    func torsoCorners(_ point: ExerciseAnimationVector, width w: Double,
                      frame: (right: ExerciseAnimationVector, forward: ExerciseAnimationVector)) -> [ExerciseAnimationVector] {
        let r = frame.right, f = frame.forward
        let corner = { (across: Double, depth: Double) in
            ExerciseAnimationMath.add(point, ExerciseAnimationMath.add(ExerciseAnimationMath.mul(r, across),
                                                                       ExerciseAnimationMath.mul(f, depth)))
        }
        return [corner(-w / 2, -5), corner(w / 2, -5), corner(w / 2, 5), corner(-w / 2, 5)]
    }

    /// Both arms: skin capsule chain, a shirt sleeve over the upper 42 %, then (unless the exercise
    /// draws custom hands) a hand cube and, with a grip, a thumb cube.
    mutating func drawArms() {
        for s in [-1.0, 1] {
            let origin = socket(s, arm: true)
            guard let elbow = pose.j[s < 0 ? "le" : "re"], let hand = pose.j[s < 0 ? "lh" : "rh"] else { continue }
            line([origin, elbow, hand], ink("skin"), width: 5.8, outline: true)
            line([origin, ExerciseAnimationMath.mix(origin, elbow, 0.42)], ink("shirt"), width: 8.3, outline: true)
            guard pose.handStyle != "custom" else { continue }
            box(hand, ExerciseAnimationVector(x: 4.2, y: 4.2, z: 4.2), ink("skin"))
            guard let grip = pose.grip else { continue }
            let thumb = grip == "neutral" ? ExerciseAnimationVector(x: s * 2.6, y: 0, z: 2)
                : ExerciseAnimationVector(x: s * 1.8, y: grip == "supinated" ? -2.8 : 2.8, z: 0)
            box(ExerciseAnimationMath.add(hand, thumb), ExerciseAnimationVector(x: 2, y: 2, z: 3), ink("skin"),
                basis: nil, stroke: false)
        }
    }

    /// Each foot: a shoe block 2 ahead of and 1 below the ankle, and an ink sole beneath it.
    mutating func drawFeet() {
        for foot in pose.feet {
            let basis = ExerciseAnimationBasis(right: foot.right, forward: foot.forward, up: foot.up)
            let center = ExerciseAnimationMath.add(foot.ankle, ExerciseAnimationMath.add(
                ExerciseAnimationMath.mul(foot.forward, 2), ExerciseAnimationMath.mul(foot.up, -1)))
            box(center, ExerciseAnimationVector(x: 8, y: 14, z: 6), ink("shoe"), basis: basis)
            box(ExerciseAnimationMath.add(center, ExerciseAnimationMath.mul(foot.up, -2.7)),
                ExerciseAnimationVector(x: 8.4, y: 14.4, z: 1.2), ink("ink"), basis: basis, stroke: false)
        }
    }

    /// The neck, head, hair (with the female character's bun and side hair) and the face decals.
    mutating func drawHead() {
        let hu = pose.headUp ?? pose.up, hr = pose.headRight ?? pose.right, hc = pose.head
        let hf = ExerciseAnimationMath.unit(ExerciseAnimationMath.sub(
            pose.forward, ExerciseAnimationMath.mul(hu, ExerciseAnimationMath.dot(pose.forward, hu))))
        let hb = ExerciseAnimationBasis(right: hr, forward: hf, up: hu)
        let at = { (offset: ExerciseAnimationVector) in ExerciseAnimationMath.add(hc, offset) }
        line([pose.shoulder, ExerciseAnimationMath.sub(hc, ExerciseAnimationMath.mul(hu, 6))], ink("skin"), width: 5.5,
             outline: true)
        box(hc, ExerciseAnimationVector(x: 17, y: 14, z: 18), ink("skin"), basis: hb)
        box(at(ExerciseAnimationMath.mul(hu, 8)), ExerciseAnimationVector(x: 19, y: 16, z: 5), ink("hair"), basis: hb)
        box(at(ExerciseAnimationMath.mul(hf, -6)), ExerciseAnimationVector(x: 18, y: 3.4, z: 17), ink("hair"), basis: hb)
        if character == .female {
            box(at(ExerciseAnimationMath.add(ExerciseAnimationMath.mul(hf, -10), ExerciseAnimationMath.mul(hu, -1))),
                ExerciseAnimationVector(x: 8, y: 7, z: 16), ink("hair"), basis: hb)
            box(at(ExerciseAnimationMath.mul(hr, -8)), ExerciseAnimationVector(x: 3, y: 14, z: 18), ink("hair"), basis: hb)
        }
        for s in [-1.0, 1] {
            let eye = ExerciseAnimationMath.add(ExerciseAnimationMath.mul(hr, s * 3.5), ExerciseAnimationMath.add(
                ExerciseAnimationMath.mul(hf, 7.3), ExerciseAnimationMath.mul(hu, 2)))
            box(at(eye), ExerciseAnimationVector(x: 1.8, y: 0.45, z: 2.7), ink("ink"), basis: hb, stroke: false)
        }
        box(at(ExerciseAnimationMath.mul(hf, 7.9)), ExerciseAnimationVector(x: 2.3, y: 2.1, z: 2.4), ink("skin"),
            basis: hb, stroke: false)
    }
}

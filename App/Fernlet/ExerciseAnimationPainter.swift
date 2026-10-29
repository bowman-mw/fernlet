//
//  ExerciseAnimationPainter.swift
//  Fernlet
//
//  The approved renderer's `drawExercise`, ported: the floor, every equipment primitive, the legs,
//  hips, torso, arms (with the custom-hand path), feet, head, the female character's hair, the face,
//  and the outline edges, in the JavaScript's order so depth ties resolve the same way.
//

import Foundation

/// Draws one sampled pose into a raster with a framed camera (one `drawExercise` call).
nonisolated struct ExerciseAnimationPainter {
    /// The buffers being drawn into; hand it back to the renderer when the frame is done.
    var raster: ExerciseAnimationRaster
    /// The pose being drawn.
    let pose: ExerciseAnimationPose
    /// The exercise's framed camera.
    let camera: ExerciseAnimationCamera
    /// The character drawn.
    let character: ExerciseAnimationCharacter
    /// The character's palette (`pal`).
    let palette: [String: String]
    /// Outline edges collected by stroked polygons and the torso, drawn last (`edges`).
    var edges: [(ExerciseAnimationScreenPoint, ExerciseAnimationScreenPoint)] = []

    /// A painter for `pose`, drawing `character` into `raster`.
    init(raster: ExerciseAnimationRaster, pose: ExerciseAnimationPose, camera: ExerciseAnimationCamera,
         character: ExerciseAnimationCharacter) {
        self.raster = raster
        self.pose = pose
        self.camera = camera
        self.character = character
        palette = ExerciseAnimationPalette.palette(for: character)
    }

    // MARK: - drawExercise

    /// The whole frame, in `drawExercise`'s order.
    mutating func draw() {
        raster.clear(ink("paper").pixel)
        let floor = [ExerciseAnimationVector(x: -160, y: -150, z: -3), ExerciseAnimationVector(x: 160, y: -150, z: -3),
                     ExerciseAnimationVector(x: 160, y: 150, z: -3), ExerciseAnimationVector(x: -160, y: 150, z: -3)]
        poly(floor.map { ExerciseAnimationMath.add($0, pose.center) }, ink("floor"), stroke: false)
        for object in pose.objects { drawObject(object) }
        drawLegs()
        drawHips()
        drawSpine()
        drawArms()
        drawFeet()
        drawHead()
        let edgeInk = ink("ink").pixel, edgeWidth = 0.5 / camera.scale
        let style = ExerciseAnimationSegmentStyle(outline: false, bias: 0.045, flat: true)
        for (a, b) in edges {
            raster.segment(a, b, width: edgeWidth, color: edgeInk, scale: camera.scale, style: style)
        }
    }

    // MARK: - Primitives

    /// `color(k)`: the palette entry for a key, else the string itself, resolved to an ink.
    func ink(_ key: String?) -> ExerciseAnimationInk {
        let name = key ?? "undefined"
        return ExerciseAnimationInk(colorString: palette[name] ?? name)
    }

    /// `projectPoint(p, v)`.
    @inline(__always)
    func project(_ v: ExerciseAnimationVector) -> ExerciseAnimationScreenPoint {
        camera.project(v, center: pose.center)
    }

    /// `poly(points, fill, stroke)`: a triangle fan from the first point; a stroked polygon queues its
    /// outline edges.
    mutating func poly(_ points: [ExerciseAnimationVector], _ fill: ExerciseAnimationInk, stroke: Bool = true) {
        let projected = points.map { project($0) }
        guard projected.count >= 3 else { return }
        for index in 1..<(projected.count - 1) {
            raster.triangle(projected[0], projected[index], projected[index + 1], color: fill.pixel)
        }
        guard stroke else { return }
        for index in projected.indices {
            edges.append((projected[index], projected[(index + 1) % projected.count]))
        }
    }

    /// `line(points, fill, width, outline)`: one capsule per consecutive pair.
    mutating func line(_ points: [ExerciseAnimationVector], _ fill: ExerciseAnimationInk, width: Double,
                       outline: Bool = false) {
        guard points.count >= 2 else { return }
        let style = ExerciseAnimationSegmentStyle(outline: outline)
        for index in 1..<points.count {
            raster.segment(project(points[index - 1]), project(points[index]), width: width, color: fill.pixel,
                           scale: camera.scale, style: style)
        }
    }

    /// `sphere(center, r, fill, outline)`: a zero-length capsule of diameter `2r`.
    mutating func sphere(_ center: ExerciseAnimationVector, _ r: Double, _ fill: ExerciseAnimationInk, outline: Bool = true) {
        let a = project(center)
        raster.segment(a, a, width: r * 2, color: fill.pixel, scale: camera.scale,
                       style: ExerciseAnimationSegmentStyle(outline: outline))
    }

    /// `box(center, size, fill, basis, stroke)`: six faces, each tinted by its shade.
    mutating func box(_ center: ExerciseAnimationVector, _ size: ExerciseAnimationVector, _ fill: ExerciseAnimationInk,
                      basis: ExerciseAnimationBasis? = nil, stroke: Bool = true) {
        let b = basis ?? .world, w = size.x, d = size.y, h = size.z
        var vertices: [ExerciseAnimationVector] = []
        for z in [-1.0, 1] {
            for y in [-1.0, 1] {
                for x in [-1.0, 1] {
                    let offset = ExerciseAnimationMath.add(
                        ExerciseAnimationMath.mul(b.right, x * w / 2),
                        ExerciseAnimationMath.add(ExerciseAnimationMath.mul(b.forward, y * d / 2),
                                                  ExerciseAnimationMath.mul(b.up, z * h / 2)))
                    vertices.append(ExerciseAnimationMath.add(center, offset))
                }
            }
        }
        for (face, shade) in Self.boxFaces {
            poly(face.map { vertices[$0] }, fill.tinted(shade), stroke: stroke)
        }
    }

    /// The box's faces (vertex indices) and their shades, in the JavaScript's order.
    static let boxFaces: [([Int], Double)] = [
        ([0, 1, 3, 2], 0.86), ([4, 6, 7, 5], 1.08), ([0, 4, 5, 1], 0.8),
        ([2, 3, 7, 6], 1), ([0, 2, 6, 4], 0.88), ([1, 5, 7, 3], 0.96),
    ]

    /// `cylinder(center, axis, length, radius, fill, segments)`: two end caps (the near one tinted
    /// 0.86) and `segments` side quads shaded by angle, without outlines on the sides.
    mutating func cylinder(_ center: ExerciseAnimationVector, axis: ExerciseAnimationVector, length: Double,
                           radius: Double, _ fill: ExerciseAnimationInk, segments: Int = 16) {
        guard segments > 0 else { return }
        let rings = cylinderRings(center, axis: axis, length: length, radius: radius, segments: segments)
        poly(rings.0.reversed(), fill.tinted(0.86))
        poly(rings.1, fill)
        let count = Double(segments)
        for index in 0..<segments {
            let next = (index + 1) % segments
            let shade = 0.86 + 0.14 * cos((Double(index) + 0.5) / count * Double.pi * 2)
            poly([rings.0[index], rings.0[next], rings.1[next], rings.1[index]], fill.tinted(shade), stroke: false)
        }
    }

    /// The cylinder's two rings of `segments` points (`rings` in the JavaScript).
    func cylinderRings(_ center: ExerciseAnimationVector, axis: ExerciseAnimationVector, length: Double, radius: Double,
                       segments: Int) -> ([ExerciseAnimationVector], [ExerciseAnimationVector]) {
        let a = ExerciseAnimationMath.unit(axis)
        let seed = abs(a.z) < 0.8 ? ExerciseAnimationVector(x: 0, y: 0, z: 1) : ExerciseAnimationVector(x: 0, y: 1, z: 0)
        let f = ExerciseAnimationMath.unit(ExerciseAnimationMath.cross(seed, a))
        let u = ExerciseAnimationMath.unit(ExerciseAnimationMath.cross(a, f))
        let count = Double(segments)
        let ring = { (s: Double) -> [ExerciseAnimationVector] in
            let end = ExerciseAnimationMath.add(center, ExerciseAnimationMath.mul(a, s * length / 2))
            return (0..<segments).map { index in
                let angle = Double(index) / count * Double.pi * 2
                return ExerciseAnimationMath.add(end, ExerciseAnimationMath.add(
                    ExerciseAnimationMath.mul(f, radius * cos(angle)), ExerciseAnimationMath.mul(u, radius * sin(angle))))
            }
        }
        return (ring(-1), ring(1))
    }

    /// `ring(center, r, axis, fill, width)`: a 40-step circle as a polyline.
    mutating func ring(_ center: ExerciseAnimationVector, _ r: Double, axis: ExerciseAnimationVector,
                       _ fill: ExerciseAnimationInk, width: Double) {
        let f = ExerciseAnimationMath.unit(Self.wheelSeed(axis))
        let u = ExerciseAnimationMath.unit(ExerciseAnimationMath.cross(axis, f))
        var points: [ExerciseAnimationVector] = []
        for k in 0...40 {
            let a = Double(k) / 40 * Double.pi * 2
            points.append(ExerciseAnimationMath.add(center, ExerciseAnimationMath.add(
                ExerciseAnimationMath.mul(f, r * cos(a)), ExerciseAnimationMath.mul(u, r * sin(a)))))
        }
        line(points, fill, width: width)
    }

    /// `Math.abs(axis[2]) < .8 ? V.cross([0,0,1], axis) : [1,0,0]` (the ring's and wheel's first axis,
    /// before `ring` normalises it).
    static func wheelSeed(_ axis: ExerciseAnimationVector) -> ExerciseAnimationVector {
        abs(axis.z) < 0.8 ? ExerciseAnimationMath.cross(ExerciseAnimationVector(x: 0, y: 0, z: 1), axis)
            : ExerciseAnimationVector(x: 1, y: 0, z: 0)
    }
}

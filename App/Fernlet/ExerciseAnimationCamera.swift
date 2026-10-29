//
//  ExerciseAnimationCamera.swift
//  Fernlet
//
//  The approved renderer's orthographic camera: `CAMERA_PRESETS`, `cameraSpec`, `cameraAxes`,
//  `frameCamera` (bounds over the 49 raw poses of the loop) and `projectPoint`, ported.
//

import Foundation

/// A camera direction in degrees (`{azimuth, elevation}` in the JavaScript).
nonisolated struct ExerciseAnimationCameraSpec: Equatable, Sendable {
    /// Degrees around the vertical axis.
    var azimuth: Double
    /// Degrees above the floor plane.
    var elevation: Double
}

/// The camera's screen axes in model space.
nonisolated struct ExerciseAnimationCameraAxes: Sendable {
    /// Model direction of screen-right.
    var horizontal: ExerciseAnimationVector
    /// Model direction of screen-down.
    var vertical: ExerciseAnimationVector
    /// Model direction toward the viewer (larger depth is nearer).
    var depth: ExerciseAnimationVector
}

/// A framed camera: `{scale, x, y, axes}` from `frameCamera`.
nonisolated struct ExerciseAnimationCamera: Sendable {
    /// Layout units per model unit.
    var scale: Double
    /// Layout-unit x of the pose centre.
    var x: Double
    /// Layout-unit y of the pose centre.
    var y: Double
    /// The screen axes.
    var axes: ExerciseAnimationCameraAxes

    /// `projectPoint(p, v)`: `v` relative to the pose's centre, onto the screen axes.
    @inline(__always)
    func project(_ v: ExerciseAnimationVector, center: ExerciseAnimationVector) -> ExerciseAnimationScreenPoint {
        let d = ExerciseAnimationMath.sub(v, center)
        return ExerciseAnimationScreenPoint(
            x: x + scale * ExerciseAnimationMath.dot(axes.horizontal, d),
            y: y + scale * ExerciseAnimationMath.dot(axes.vertical, d),
            depth: ExerciseAnimationMath.dot(axes.depth, d))
    }
}

/// The running `minU/maxU/minV/maxV` bounds `frameCamera` grows with `include(v, r)`.
nonisolated struct ExerciseAnimationFrameBounds {
    /// Smallest horizontal extent so far.
    var minU = Double.infinity
    /// Largest horizontal extent so far.
    var maxU = -Double.infinity
    /// Smallest vertical extent so far.
    var minV = Double.infinity
    /// Largest vertical extent so far.
    var maxV = -Double.infinity

    /// `include(v, r)`: grows the bounds by `v`'s projection, padded by `r`.
    mutating func include(_ v: ExerciseAnimationVector, _ r: Double, center: ExerciseAnimationVector,
                          axes: ExerciseAnimationCameraAxes) {
        let d = ExerciseAnimationMath.sub(v, center)
        let u = ExerciseAnimationMath.dot(axes.horizontal, d), w = ExerciseAnimationMath.dot(axes.vertical, d)
        minU = ExerciseAnimationMath.jsMin(minU, u - r)
        maxU = ExerciseAnimationMath.jsMax(maxU, u + r)
        minV = ExerciseAnimationMath.jsMin(minV, w - r)
        maxV = ExerciseAnimationMath.jsMax(maxV, w + r)
    }
}

/// The approved camera presets and the framing arithmetic.
nonisolated enum ExerciseAnimationCameraRig {
    /// The default view: the exercise's own approved camera.
    static let exerciseView = "exercise"

    /// `CAMERA_PRESETS`.
    static let presets: [String: ExerciseAnimationCameraSpec] = [
        "front-iso": ExerciseAnimationCameraSpec(azimuth: 45, elevation: 35.264),
        "rear-iso": ExerciseAnimationCameraSpec(azimuth: 135, elevation: 35.264),
        "front": ExerciseAnimationCameraSpec(azimuth: 0, elevation: 15),
        "side": ExerciseAnimationCameraSpec(azimuth: 90, elevation: 14),
    ]

    /// `cameraSpec(e, p, override)`: the preset the view names (the exercise's own preset for
    /// `exercise`), else the pose's azimuth at the exercise's elevation (18° by default).
    static func spec(_ exercise: ExerciseAnimationExerciseInfo, poseView: Double,
                     override: String = exerciseView) -> ExerciseAnimationCameraSpec {
        let name = override == exerciseView ? exercise.viewPreset : override
        if let name, let preset = presets[name] { return preset }
        return ExerciseAnimationCameraSpec(azimuth: poseView, elevation: exercise.viewElevation ?? 18)
    }

    /// `cameraAxes(spec)`.
    static func axes(_ spec: ExerciseAnimationCameraSpec) -> ExerciseAnimationCameraAxes {
        let a = spec.azimuth * ExerciseAnimationMath.rad, b = spec.elevation * ExerciseAnimationMath.rad
        let c = cos(a), s = sin(a), cb = cos(b), sb = sin(b)
        return ExerciseAnimationCameraAxes(
            horizontal: ExerciseAnimationVector(x: c, y: s, z: 0),
            vertical: ExerciseAnimationVector(x: -s * sb, y: c * sb, z: -cb),
            depth: ExerciseAnimationVector(x: -s * cb, y: c * cb, z: sb))
    }

    /// `frameCamera(e, override)` over the loop's raw poses (`MOTIONS[e.motion](e, i/48)`, i = 0…48):
    /// the bounds of every joint, spine point, the head and the non-mat equipment, fitted into the
    /// 284 × 204 layout box centred at (160, 119), never closer than 2.35. The axes are the last pose's.
    static func frame(_ exercise: ExerciseAnimationExerciseInfo, poses: [ExerciseAnimationPose],
                      override: String = exerciseView) -> ExerciseAnimationCamera? {
        guard let last = poses.last else { return nil }
        var bounds = ExerciseAnimationFrameBounds()
        var axes = Self.axes(spec(exercise, poseView: last.view, override: override))
        for pose in poses {
            axes = Self.axes(spec(exercise, poseView: pose.view, override: override))
            include(pose, in: &bounds, axes: axes)
        }
        let scale = ExerciseAnimationMath.jsMin(2.35, ExerciseAnimationMath.jsMin(
            284 / (bounds.maxU - bounds.minU), 204 / (bounds.maxV - bounds.minV)))
        return ExerciseAnimationCamera(scale: scale, x: 160 - (bounds.minU + bounds.maxU) / 2 * scale,
                                       y: 119 - (bounds.minV + bounds.maxV) / 2 * scale, axes: axes)
    }

    /// One raw pose's contribution to the framing bounds, in the JavaScript's order.
    static func include(_ pose: ExerciseAnimationPose, in bounds: inout ExerciseAnimationFrameBounds,
                        axes: ExerciseAnimationCameraAxes) {
        let center = pose.center
        for joint in pose.j.values { bounds.include(joint, 6, center: center, axes: axes) }
        for point in pose.spine { bounds.include(point, 15, center: center, axes: axes) }
        bounds.include(pose.head, 17, center: center, axes: axes)
        for object in pose.objects where object.color != "mat" {
            include(object, in: &bounds, center: center, axes: axes)
        }
    }

    /// One equipment object's framing points: its polyline, a box's eight corners, a bar's two ends,
    /// or its centre padded by its radius (19 for a kettlebell, 10 when it has none).
    static func include(_ object: ExerciseAnimationObject, in bounds: inout ExerciseAnimationFrameBounds,
                        center: ExerciseAnimationVector, axes: ExerciseAnimationCameraAxes) {
        if let points = object.points {
            let pad = truthy(object.width) / 2 + 1
            for point in points { bounds.include(point, pad, center: center, axes: axes) }
        }
        guard let objectCenter = object.center else { return }
        switch object.type {
        case "box":
            for corner in boxCorners(object, center: objectCenter) { bounds.include(corner, 1, center: center, axes: axes) }
        case "bar":
            let axis = object.axis ?? .nan, half = object.half ?? .nan
            bounds.include(ExerciseAnimationMath.add(objectCenter, ExerciseAnimationMath.mul(axis, half)), 11,
                           center: center, axes: axes)
            bounds.include(ExerciseAnimationMath.add(objectCenter, ExerciseAnimationMath.mul(axis, -half)), 11,
                           center: center, axes: axes)
        default:
            let pad = object.type == "kettlebell" ? 19 : truthy(object.radius, or: 10)
            bounds.include(objectCenter, pad, center: center, axes: axes)
        }
    }

    /// A box object's eight corners in `frameCamera`'s order and arithmetic (`size/2*x`).
    static func boxCorners(_ object: ExerciseAnimationObject, center: ExerciseAnimationVector) -> [ExerciseAnimationVector] {
        let basis = object.basis ?? .world, size = object.size ?? .nan
        var corners: [ExerciseAnimationVector] = []
        for x in [-1.0, 1] {
            for y in [-1.0, 1] {
                for z in [-1.0, 1] {
                    let offset = ExerciseAnimationMath.add(
                        ExerciseAnimationMath.mul(basis.right, size.x / 2 * x),
                        ExerciseAnimationMath.add(ExerciseAnimationMath.mul(basis.forward, size.y / 2 * y),
                                                  ExerciseAnimationMath.mul(basis.up, size.z / 2 * z)))
                    corners.append(ExerciseAnimationMath.add(center, offset))
                }
            }
        }
        return corners
    }

    /// JavaScript `value || fallback` for an optional number: nil, 0 and NaN take the fallback.
    static func truthy(_ value: Double?, or fallback: Double = 1) -> Double {
        guard let value, value != 0, !value.isNaN else { return fallback }
        return value
    }
}

nonisolated extension ExerciseAnimationVector {
    /// A vector of NaNs: what a missing engine field turns arithmetic into.
    static let nan = ExerciseAnimationVector(x: .nan, y: .nan, z: .nan)
}

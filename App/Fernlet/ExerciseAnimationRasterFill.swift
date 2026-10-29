//
//  ExerciseAnimationRasterFill.swift
//  Fernlet
//
//  The per-pixel loops of the approved renderer's `DepthRaster`, kept apart in this one file because
//  they write through buffer pointers: an unoptimised (Debug) build pays a generic call per `Array`
//  element access, which made one frame cost 100–450 ms, while pointer subscripts compile to plain
//  loads and stores. Every pointer stays inside its `with…` closure, both buffers are checked to be
//  exactly 640 × 480 before the first write, and every index is a clamped (row, column) pair.
//

import Foundation

/// One triangle's pixel-space corners and depths, its clamped pixel box, and its colour, ready to fill.
nonisolated struct ExerciseAnimationTriangleJob {
    /// Corner A, pixels.
    let ax: Double, ay: Double
    /// Corner B, pixels.
    let bx: Double, by: Double
    /// Corner C, pixels.
    let cx: Double, cy: Double
    /// The corners' depths.
    let az: Double, bz: Double, cz: Double
    /// `1 / area`.
    let inv: Double
    /// Added to every depth written.
    let bias: Double
    /// The clamped columns and rows to visit.
    let columns: ClosedRange<Int>, rows: ClosedRange<Int>
    /// The packed fill pixel.
    let color: UInt32
}

/// One capsule segment's nearest-point arithmetic, radii, depths and inks, ready to fill.
nonisolated struct ExerciseAnimationSegmentJob {
    /// Start, direction and squared length in pixels.
    let span: ExerciseAnimationSegmentSpan
    /// Squared radius and squared inner (non-outline) radius, pixels².
    let r2: Double, inner2: Double
    /// Model units per pixel for the depth bulge.
    let worldPerPixel: Double
    /// Start depth and end-minus-start depth.
    let az: Double, dz: Double
    /// Added to every depth written.
    let bias: Double
    /// No depth bulge.
    let flat: Bool
    /// The clamped columns and rows to visit.
    let columns: ClosedRange<Int>, rows: ClosedRange<Int>
    /// The packed fill pixel, and the pixel for the outline rim (the fill when not outlined).
    let color: UInt32, rim: UInt32
}

/// The pixel loops, over the raster's two buffers.
nonisolated enum ExerciseAnimationRasterFill {
    /// The canvas size both buffers must have.
    static let pixelCount = ExerciseAnimationRaster.width * ExerciseAnimationRaster.height
    /// The JavaScript's coverage and depth tolerance.
    static let tolerance = 0.00001

    /// Whether a job's box lies on the canvas (spans are clamped, so this always holds).
    static func fits(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> Bool {
        columns.lowerBound >= 0 && columns.upperBound < ExerciseAnimationRaster.width
            && rows.lowerBound >= 0 && rows.upperBound < ExerciseAnimationRaster.height
    }

    /// Fills `job`'s triangle: pixels whose centres are inside (within the tolerance) and pass the
    /// `z >= stored - 0.00001` depth test, exactly as `DepthRaster.triangle` does.
    static func triangle(_ job: ExerciseAnimationTriangleJob, pixels: inout [UInt32], depth: inout [Float]) {
        guard fits(columns: job.columns, rows: job.rows), pixels.count == pixelCount, depth.count == pixelCount else {
            assertionFailure("raster buffers are the canvas size and spans are clamped")
            return
        }
        pixels.withUnsafeMutableBufferPointer { pixelBuffer in
            depth.withUnsafeMutableBufferPointer { depthBuffer in
                guard let pixel = pixelBuffer.baseAddress, let stored = depthBuffer.baseAddress else { return }
                triangleRows(job, pixel: pixel, stored: stored)
            }
        }
    }

    /// The triangle's row and column loops over the (checked) buffer starts.
    static func triangleRows(_ job: ExerciseAnimationTriangleJob, pixel: UnsafeMutablePointer<UInt32>,
                             stored: UnsafeMutablePointer<Float>) {
        let ax = job.ax, ay = job.ay, bx = job.bx, by = job.by, cx = job.cx, cy = job.cy
        let az = job.az, bz = job.bz, cz = job.cz, inv = job.inv, bias = job.bias, color = job.color
        let tolerance = Self.tolerance, width = ExerciseAnimationRaster.width
        let firstX = job.columns.lowerBound, lastX = job.columns.upperBound
        var y = job.rows.lowerBound - 1
        while y < job.rows.upperBound {
            y += 1
            let py = Double(y) + 0.5, rowStart = y * width
            var x = firstX - 1
            while x < lastX {
                x += 1
                let px = Double(x) + 0.5
                let u = ((bx - px) * (cy - py) - (by - py) * (cx - px)) * inv
                let v = ((cx - px) * (ay - py) - (cy - py) * (ax - px)) * inv
                let t = 1 - u - v
                if u < -tolerance || v < -tolerance || t < -tolerance { continue }
                let z = u * az + v * bz + t * cz + bias
                let index = rowStart + x
                if z >= Double(stored[index]) - tolerance {
                    stored[index] = Float(z)
                    pixel[index] = color
                }
            }
        }
    }

    /// Fills `job`'s capsule, exactly as `DepthRaster.segment` does.
    static func segment(_ job: ExerciseAnimationSegmentJob, pixels: inout [UInt32], depth: inout [Float]) {
        guard fits(columns: job.columns, rows: job.rows), pixels.count == pixelCount, depth.count == pixelCount else {
            assertionFailure("raster buffers are the canvas size and spans are clamped")
            return
        }
        pixels.withUnsafeMutableBufferPointer { pixelBuffer in
            depth.withUnsafeMutableBufferPointer { depthBuffer in
                guard let pixel = pixelBuffer.baseAddress, let stored = depthBuffer.baseAddress else { return }
                segmentRows(job, pixel: pixel, stored: stored)
            }
        }
    }

    /// The capsule's row and column loops over the (checked) buffer starts: for each pixel centre the
    /// clamped nearest point `t` on the segment, its squared distance `d2`, and the bulged depth, all in
    /// the JavaScript's operation order.
    static func segmentRows(_ job: ExerciseAnimationSegmentJob, pixel: UnsafeMutablePointer<UInt32>,
                            stored: UnsafeMutablePointer<Float>) {
        let ax = job.span.ax, ay = job.span.ay, dx = job.span.dx, dy = job.span.dy, len = job.span.len
        let hasLength = job.span.hasLength, r2 = job.r2, inner2 = job.inner2, worldPerPixel = job.worldPerPixel
        let az = job.az, dz = job.dz, bias = job.bias, flat = job.flat, color = job.color, rim = job.rim
        let tolerance = Self.tolerance, width = ExerciseAnimationRaster.width
        let firstX = job.columns.lowerBound, lastX = job.columns.upperBound
        var y = job.rows.lowerBound - 1
        while y < job.rows.upperBound {
            y += 1
            let fy = Double(y) + 0.5, rowStart = y * width
            var x = firstX - 1
            while x < lastX {
                x += 1
                let fx = Double(x) + 0.5
                var t = 0.0
                if hasLength {
                    let q = ((fx - ax) * dx + (fy - ay) * dy) / len
                    t = q > 1 ? 1 : (q > 0 ? q : (q.isNaN ? q : 0))
                }
                let ex = fx - ax - t * dx, ey = fy - ay - t * dy
                let d2 = ex * ex + ey * ey
                if d2 > r2 { continue }
                let rest = r2 - d2
                let bulge = flat ? 0 : (rest > 0 ? rest : (rest.isNaN ? rest : 0)).squareRoot() * worldPerPixel
                let z = az + t * dz + bulge + bias
                let index = rowStart + x
                if z >= Double(stored[index]) - tolerance {
                    stored[index] = Float(z)
                    pixel[index] = d2 > inner2 ? rim : color
                }
            }
        }
    }

    /// The packed pixels as bytes: each `0xAABBGGRR` value stored little-endian is R, G, B, A, the
    /// canvas's `ImageData` layout. The bytes are copied into the `Data` inside the closure.
    static func rgbaData(_ pixels: [UInt32]) -> Data {
        pixels.withUnsafeBytes { Data($0) }
    }
}

//
//  ExerciseAnimationRaster.swift
//  Fernlet
//
//  The approved renderer's `DepthRaster`, ported: a 640 × 480 colour buffer and a Float32 depth
//  buffer, filled one triangle or capsule segment at a time with the JavaScript's exact arithmetic
//  and its -0.00001 depth tolerance.
//

import Foundation
import CoreGraphics

/// A projected point: canvas x and y in the renderer's 320 × 240 layout units, and depth (larger is
/// nearer the camera).
nonisolated struct ExerciseAnimationScreenPoint: Sendable {
    /// Layout-unit x (multiplied by 2 for the 640-pixel canvas).
    var x: Double
    /// Layout-unit y (multiplied by 2 for the 480-pixel canvas).
    var y: Double
    /// Camera depth.
    var depth: Double
}

/// How a capsule segment is shaded: `outline` inks its rim, `flat` drops the rounded depth bulge, and
/// `bias` nudges its depth toward the camera (the renderer's edge lines use 0.045).
nonisolated struct ExerciseAnimationSegmentStyle: Sendable {
    /// Paint the outer 0.55-layout-unit rim with the outline ink.
    var outline = false
    /// Added to every depth the segment writes.
    var bias = 0.0
    /// No rounded bulge: depth is the straight line between the ends.
    var flat = false
}

/// The colour and depth buffers one frame is drawn into. Pixels are packed `0xAABBGGRR`, so a pixel
/// written out little-endian is the canvas's R, G, B, A bytes.
nonisolated struct ExerciseAnimationRaster {
    /// Canvas width in pixels.
    static let width = ExerciseAnimationRenderer.pixelWidth
    /// Canvas height in pixels.
    static let height = ExerciseAnimationRenderer.pixelHeight
    /// Pixels per layout unit, horizontally (`width / 320`).
    static let sx = Double(width) / 320
    /// Pixels per layout unit, vertically (`height / 240`).
    static let sy = Double(height) / 240
    /// The colour buffer, row-major.
    private(set) var pixels: [UInt32]
    /// The depth buffer (`Float32Array` in the JavaScript), row-major.
    private(set) var depth: [Float]
    /// The packed outline ink (`COLORS.ink`).
    let outlineInk: UInt32

    /// A raster with no buffers yet; `clear` allocates them (the painter clears first, as the
    /// JavaScript does).
    init(outlineInk: UInt32) {
        self.outlineInk = outlineInk
        pixels = []
        depth = []
    }

    /// `clear(hex)`: every pixel to `color`, every depth to -∞.
    mutating func clear(_ color: UInt32) {
        pixels = [UInt32](repeating: color, count: Self.width * Self.height)
        depth = [Float](repeating: -.infinity, count: Self.width * Self.height)
    }

    /// The clamped pixel span `[max(0, floor(lo)), min(limit - 1, ceil(hi))]`, or nil when it is empty
    /// or NaN (the JavaScript loop then runs zero times).
    @inline(__always)
    static func span(_ lo: Double, _ hi: Double, limit: Int) -> ClosedRange<Int>? {
        let first = ExerciseAnimationMath.jsMax(0, lo.rounded(.down))
        let last = ExerciseAnimationMath.jsMin(Double(limit - 1), hi.rounded(.up))
        guard first <= last else { return nil }
        return Int(first)...Int(last)
    }

    /// `triangle(a, b, c, hex, bias)`: fills pixels whose centres lie inside (within the tolerance)
    /// and pass the depth test, interpolating depth barycentrically.
    mutating func triangle(_ a: ExerciseAnimationScreenPoint, _ b: ExerciseAnimationScreenPoint,
                           _ c: ExerciseAnimationScreenPoint, color: UInt32, bias: Double = 0) {
        let ax = a.x * Self.sx, ay = a.y * Self.sy, bx = b.x * Self.sx, by = b.y * Self.sy
        let cx = c.x * Self.sx, cy = c.y * Self.sy
        let area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        guard !(abs(area) < 1e-9) else { return }
        let minX = ExerciseAnimationMath.jsMin(ax, ExerciseAnimationMath.jsMin(bx, cx))
        let maxX = ExerciseAnimationMath.jsMax(ax, ExerciseAnimationMath.jsMax(bx, cx))
        let minY = ExerciseAnimationMath.jsMin(ay, ExerciseAnimationMath.jsMin(by, cy))
        let maxY = ExerciseAnimationMath.jsMax(ay, ExerciseAnimationMath.jsMax(by, cy))
        guard let columns = Self.span(minX, maxX, limit: Self.width),
              let rows = Self.span(minY, maxY, limit: Self.height) else { return }
        let job = ExerciseAnimationTriangleJob(ax: ax, ay: ay, bx: bx, by: by, cx: cx, cy: cy, az: a.depth, bz: b.depth,
                                               cz: c.depth, inv: 1 / area, bias: bias, columns: columns, rows: rows,
                                               color: color)
        ExerciseAnimationRasterFill.triangle(job, pixels: &pixels, depth: &depth)
    }

    /// `segment(a, b, width, hex, scale, {outline, bias, flat})`: a capsule of radius
    /// `max(0.55, width × scale × sx / 2)` pixels, its depth bulging like a tube unless `flat`.
    mutating func segment(_ a: ExerciseAnimationScreenPoint, _ b: ExerciseAnimationScreenPoint, width: Double,
                          color: UInt32, scale: Double, style: ExerciseAnimationSegmentStyle = .init()) {
        let ax = a.x * Self.sx, ay = a.y * Self.sy, bx = b.x * Self.sx, by = b.y * Self.sy
        let dx = bx - ax, dy = by - ay, len = dx * dx + dy * dy
        let r = ExerciseAnimationMath.jsMax(0.55, width * scale * Self.sx / 2), r2 = r * r
        guard let columns = Self.span(ExerciseAnimationMath.jsMin(ax, bx) - r, ExerciseAnimationMath.jsMax(ax, bx) + r,
                                      limit: Self.width),
              let rows = Self.span(ExerciseAnimationMath.jsMin(ay, by) - r, ExerciseAnimationMath.jsMax(ay, by) + r,
                                   limit: Self.height) else { return }
        let inner = ExerciseAnimationMath.jsMax(0, r - 0.55 * Self.sx), inner2 = inner * inner
        let worldPerPixel = 1 / (scale * Self.sx)
        let span = ExerciseAnimationSegmentSpan(ax: ax, ay: ay, dx: dx, dy: dy, len: len, hasLength: len != 0 && !len.isNaN)
        let job = ExerciseAnimationSegmentJob(span: span, r2: r2, inner2: inner2, worldPerPixel: worldPerPixel, az: a.depth,
                                              dz: b.depth - a.depth, bias: style.bias, flat: style.flat, columns: columns,
                                              rows: rows, color: color, rim: style.outline ? outlineInk : color)
        ExerciseAnimationRasterFill.segment(job, pixels: &pixels, depth: &depth)
    }

    /// The canvas as 8-bit R, G, B, A rows (what `putImageData` receives).
    func rgbaData() -> Data {
        ExerciseAnimationRasterFill.rgbaData(pixels)
    }

    /// The canvas as an sRGB CGImage; nil only if Core Graphics refuses the buffer.
    func makeImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let provider = CGDataProvider(data: rgbaData() as CFData) else { return nil }
        return CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Self.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// A segment's pixel-space start, direction and squared length (`ax`, `ay`, `dx`, `dy`, `len`).
nonisolated struct ExerciseAnimationSegmentSpan {
    /// Start x in pixels.
    let ax: Double
    /// Start y in pixels.
    let ay: Double
    /// End minus start, x.
    let dx: Double
    /// End minus start, y.
    let dy: Double
    /// Squared length (`len` in the JavaScript).
    let len: Double
    /// `len` is truthy (non-zero, not NaN), so the nearest point is clamped along the segment.
    let hasLength: Bool
}

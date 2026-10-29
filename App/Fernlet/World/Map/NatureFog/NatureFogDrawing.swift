import CoreGraphics
import SwiftUI
import WorldMapStore

/// Draws a ``NatureFogLayout`` into a y-down `CGContext` whose top-left sits at `origin` (global points).
/// Coordinates are made local before Core Graphics sees them, so the map's large global positions never
/// lose precision.
enum NatureFogDrawer {
    /// The ground, back to front: every hex filled (one path a colour) with its seam, the specks, then the
    /// water (R + 0.5, covering the seams), its shores, ripples, lilies and far-off flowers.
    static func drawGround(_ layout: NatureFogLayout, scale: NatureFogScale, palette: NatureFogPalette,
                           in context: CGContext, origin: CGPoint) {
        guard !layout.hexes.isEmpty else { return }
        var fills: [NaturePaint: CGMutablePath] = [:]
        let seams = CGMutablePath()
        for hex in layout.hexes {
            let path = hexPath(local(hex.centre, origin), radius: scale.radius)
            let fill = fills[hex.paint] ?? CGMutablePath()
            fill.addPath(path)
            fills[hex.paint] = fill
            seams.addPath(path)
        }
        for paint in NaturePaint.allCases {
            guard let path = fills[paint] else { continue }
            context.addPath(path)
            context.setFillColor(palette.color(paint))
            context.fillPath()
        }
        context.addPath(seams)
        context.setStrokeColor(palette.color(.seam))
        context.setLineWidth(palette.seamWidth)
        context.strokePath()
        fill(layout.specks, palette: palette, in: context, origin: origin)
        drawWater(layout, scale: scale, palette: palette, in: context, origin: origin)
    }

    /// Water, shores, then ripples, lilies and far-off flowers.
    private static func drawWater(_ layout: NatureFogLayout, scale: NatureFogScale, palette: NatureFogPalette,
                                  in context: CGContext, origin: CGPoint) {
        let water = CGMutablePath()
        for centre in layout.ponds { water.addPath(hexPath(local(centre, origin), radius: scale.radius + 0.5)) }
        context.addPath(water)
        context.setFillColor(palette.color(.water))
        context.fillPath()
        let shore = CGMutablePath()
        for line in layout.shores {
            shore.move(to: local(line.from, origin))
            shore.addLine(to: local(line.to, origin))
        }
        context.addPath(shore)
        context.setStrokeColor(palette.color(.shore))
        context.setLineWidth(scale.unit * 0.9)
        context.setLineCap(.round)
        context.strokePath()
        fill(layout.waterMarks, palette: palette, in: context, origin: origin)
    }

    /// The growing pieces in their sorted order (reduced-detail tiles and the widget's picture bake them in).
    static func drawPieces(_ layout: NatureFogLayout, atlas: NatureFogAtlas, in context: CGContext, origin: CGPoint) {
        for piece in layout.pieces {
            guard let sprite = atlas.sprite(piece.sprite) else { continue }
            NatureFogAtlas.draw(sprite, in: context, rect: piece.frame.offsetBy(dx: -origin.x, dy: -origin.y))
        }
    }

    /// Solid blocks, crisp (no antialiasing, so they land on whole pixels).
    private static func fill(_ blocks: [NatureFogBlock], palette: NatureFogPalette, in context: CGContext, origin: CGPoint) {
        guard !blocks.isEmpty else { return }
        context.saveGState()
        context.setShouldAntialias(false)
        for block in blocks {
            context.setFillColor(palette.color(block.paint))
            context.fill(block.rect.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        context.restoreGState()
    }

    /// `point` relative to `origin`.
    private static func local(_ point: CGPoint, _ origin: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// A pointy-top hex round `centre`.
    static func hexPath(_ centre: CGPoint, radius: Double) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: (0..<6).map { NatureFogGrower.corner(centre, radius, $0) })
        path.closeSubpath()
        return path
    }
}

/// The nature fog drawn straight into a `GraphicsContext`, for the map widget's saved picture: always the
/// reduced detail (spec "Zoomed out, and the widget"), and still, since a picture never sways.
struct NatureFogPicturePainter {
    let viewport: MapViewport
    let clearing: NatureFogClearing
    let palette: NatureFogPalette

    /// The scale the picture draws at for a view of `size`: the hex's real size, reduced detail.
    func scale(in size: CGSize) -> NatureFogScale? {
        let radius = MercatorHexGrid.radius * viewport.pointsPerUnit(in: size)
        guard radius.isFinite, radius >= NatureFogScale.minimumRadius else { return nil }
        return NatureFogScale(radius: radius, reduced: true)
    }

    /// Paints the fog over the whole of `size`.
    func paint(_ context: inout GraphicsContext, size: CGSize) {
        guard let grown = grow(in: size) else { return }
        context.withCGContext { cgContext in
            NatureFogDrawer.drawGround(grown.layout, scale: grown.scale, palette: palette, in: cgContext, origin: grown.origin)
            NatureFogDrawer.drawPieces(grown.layout, atlas: grown.atlas, in: cgContext, origin: grown.origin)
        }
    }

    /// The fogged hexes over `size` as outlines alone, in the picture's own points: no fill, no seam colour,
    /// no grass, trees or ponds (the map widget's one-colour picture, phone test W-11). Nil when the hexes
    /// would be too small to draw.
    func outlines(in size: CGSize) -> Path? {
        guard let grown = grow(in: size) else { return nil }
        var path = Path()
        for hex in grown.layout.hexes {
            let centre = CGPoint(x: hex.centre.x - grown.origin.x, y: hex.centre.y - grown.origin.y)
            path.addPath(Path(NatureFogDrawer.hexPath(centre, radius: grown.scale.radius)))
        }
        return path
    }

    /// The layout the picture draws over `size`, at its scale, from its global origin, with the atlas it
    /// grew from; nil when the hexes would be too small.
    private func grow(in size: CGSize) -> (layout: NatureFogLayout, scale: NatureFogScale, origin: CGPoint, atlas: NatureFogAtlas)? {
        guard let scale = scale(in: size) else { return nil }
        let perUnit = scale.pointsPerUnit
        let origin = CGPoint(x: viewport.minX * perUnit, y: viewport.minY * perUnit)
        let atlas = NatureFogAtlas(palette: palette)
        let layout = NatureFogGrower(scale: scale, clearing: clearing, atlas: atlas).layout(in: CGRect(origin: origin, size: size))
        return (layout, scale, origin, atlas)
    }
}

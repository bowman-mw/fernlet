import CoreGraphics
import SwiftUI
import WorldMapStore

/// Draws a ``NatureFogLayout`` into a y-down `CGContext` whose top-left sits at `origin` (global points).
/// Coordinates are made local before Core Graphics sees them, so the map's large global positions never
/// lose precision.
///
/// Each land hex paints in its terrain look's palette (``NatureFogPalette/with(_:)``), the approved look first;
/// a layout of the approved look alone makes exactly the calls the nature fog made before the terrain.
nonisolated enum NatureFogDrawer {
    /// The ground, back to front: every land hex filled (one path a colour, look by look) with its seam, the
    /// sea's hexes (R + 0.4, no seam), the specks and terrain marks, then the water (R + 0.5, covering the
    /// seams), its shores, the sand line along the coast, ripples, lilies and far-off flowers.
    static func drawGround(_ layout: NatureFogLayout, scale: NatureFogScale, palette: NatureFogPalette,
                           in context: CGContext, origin: CGPoint) {
        guard !layout.hexes.isEmpty || !layout.seas.isEmpty else { return }
        var palettes = NatureFogPalettes(base: palette)
        let looks = order(layout.hexes.map(\.look))
        var seams: [(TerrainLook, CGMutablePath)] = []
        for look in looks {
            var fills: [NaturePaint: CGMutablePath] = [:]
            let seam = CGMutablePath()
            for hex in layout.hexes where hex.look == look {
                let path = hexPath(local(hex.centre, origin), radius: scale.radius)
                let fill = fills[hex.paint] ?? CGMutablePath()
                fill.addPath(path)
                fills[hex.paint] = fill
                seam.addPath(path)
            }
            let colours = palettes[look]
            for paint in NaturePaint.allCases {
                guard let path = fills[paint] else { continue }
                context.addPath(path)
                context.setFillColor(colours.color(paint))
                context.fillPath()
            }
            seams.append((look, seam))
        }
        for (look, seam) in seams {
            context.addPath(seam)
            context.setStrokeColor(palettes[look].color(.seam))
            context.setLineWidth(palette.seamWidth)
            context.strokePath()
        }
        drawSeas(layout, scale: scale, palettes: &palettes, in: context, origin: origin)
        fill(layout.specks, palettes: &palettes, in: context, origin: origin)
        mark(layout.marks, palettes: &palettes, in: context, origin: origin)
        drawWater(layout, scale: scale, palettes: &palettes, in: context, origin: origin)
    }

    /// `looks` without repeats, the approved look first, the rest in the order they first appear.
    private static func order(_ looks: [TerrainLook]) -> [TerrainLook] {
        var seen = Set<TerrainLook>(), ordered: [TerrainLook] = []
        if looks.contains(.approved) {
            seen.insert(.approved)
            ordered.append(.approved)
        }
        for look in looks where seen.insert(look).inserted { ordered.append(look) }
        return ordered
    }

    /// The sea's hexes, a little larger than a hex so no seam shows between them.
    private static func drawSeas(_ layout: NatureFogLayout, scale: NatureFogScale, palettes: inout NatureFogPalettes,
                                 in context: CGContext, origin: CGPoint) {
        guard !layout.seas.isEmpty else { return }
        let colours = palettes[TerrainLook(set: .water, season: .summer)]
        var fills: [NaturePaint: CGMutablePath] = [:]
        for hex in layout.seas {
            let fill = fills[hex.paint] ?? CGMutablePath()
            fill.addPath(hexPath(local(hex.centre, origin), radius: scale.radius + 0.4))
            fills[hex.paint] = fill
        }
        for paint in NaturePaint.allCases {
            guard let path = fills[paint] else { continue }
            context.addPath(path)
            context.setFillColor(colours.color(paint))
            context.fillPath()
        }
    }

    /// The coast's sand line, then the sea's wave marks and far-off flowers. There are no ponds: water is drawn
    /// only where the atlas has it (owner, 2026-10-30).
    private static func drawWater(_ layout: NatureFogLayout, scale: NatureFogScale, palettes: inout NatureFogPalettes,
                                  in context: CGContext, origin: CGPoint) {
        if !layout.coasts.isEmpty {
            let sand = palettes[TerrainLook(set: .water, season: .summer)].color(.shore)
            stroke(layout.coasts, colour: sand, width: scale.unit * 1.4, in: context, origin: origin)
        }
        fill(layout.waterMarks, palettes: &palettes, in: context, origin: origin)
    }

    /// Straight round-capped lines.
    private static func stroke(_ lines: [(from: CGPoint, to: CGPoint)], colour: CGColor, width: Double, in context: CGContext,
                               origin: CGPoint) {
        let path = CGMutablePath()
        for line in lines {
            path.move(to: local(line.from, origin))
            path.addLine(to: local(line.to, origin))
        }
        context.addPath(path)
        context.setStrokeColor(colour)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.strokePath()
    }

    /// The growing pieces in their sorted order (reduced-detail tiles and the widget's picture bake them in).
    static func drawPieces(_ layout: NatureFogLayout, atlas: NatureFogAtlas, in context: CGContext, origin: CGPoint) {
        for piece in layout.pieces {
            guard let sprite = atlas.sprite(piece.sprite, look: piece.look) else { continue }
            NatureFogAtlas.draw(sprite, in: context, rect: piece.frame.offsetBy(dx: -origin.x, dy: -origin.y))
        }
    }

    /// Solid blocks in their looks' colours, crisp (no antialiasing, so they land on whole pixels).
    private static func fill(_ blocks: [NatureFogBlock], palettes: inout NatureFogPalettes, in context: CGContext, origin: CGPoint) {
        guard !blocks.isEmpty else { return }
        context.saveGState()
        context.setShouldAntialias(false)
        for block in blocks {
            context.setFillColor(palettes[block.look].color(block.paint))
            context.fill(block.rect.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        context.restoreGState()
    }

    /// Terrain marks, crisp like the specks.
    private static func mark(_ marks: [NatureFogMark], palettes: inout NatureFogPalettes, in context: CGContext, origin: CGPoint) {
        guard !marks.isEmpty else { return }
        context.saveGState()
        context.setShouldAntialias(false)
        for mark in marks {
            context.setFillColor(palettes[mark.look].color(mark.ink))
            context.fill(mark.rect.offsetBy(dx: -origin.x, dy: -origin.y))
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

/// One appearance's palettes by terrain look, made on first use while one picture draws.
nonisolated struct NatureFogPalettes {
    let base: NatureFogPalette
    private var made: [TerrainLook: NatureFogPalette] = [:]

    /// Palettes in `base`'s appearance.
    init(base: NatureFogPalette) {
        self.base = base
    }

    /// The palette for `look`.
    subscript(look: TerrainLook) -> NatureFogPalette {
        mutating get {
            if look == base.look { return base }
            if let known = made[look] { return known }
            let palette = base.with(look)
            made[look] = palette
            return palette
        }
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
    /// no grass or trees (the map widget's one-colour picture, phone test W-11). Nil when the hexes
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

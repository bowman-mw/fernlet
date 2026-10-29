import SwiftUI
import UIKit
import WorldMapStore

/// The faint scene of the map widget's one-colour drawing (phone test W-11, `ref-tint-map` draft 2 and
/// `ref-tint-map-light`, approved): what each pixel of Apple's light muted map keeps, as a share of white,
/// which iOS tints on the tinted and clear Home Screens.
///
/// The classes are tuned on real snapshots of the muted map: roads are pure white, a park's paths a warm
/// light grey, parks a pale green, water a pale blue. Blocks (a cream near white), buildings (a cool grey) and
/// label text (a mid grey) keep nothing, so no name of a street or a place reaches the drawing. Apple's
/// "Maps" logo, bottom left, keeps its shape (MapKit terms), as in the colour pictures.
enum WorldWidgetMonoInk {
    /// Streets and paths (the spec's "about 25%").
    static let street = 0.25
    /// Parks and other green ground (the spec's 6–10%).
    static let park = 0.07
    /// Water (the spec's 6–10%).
    static let water = 0.10
    /// The unexplored ring's hex outlines (the spec's 15–17%).
    static let hexOutline = 0.16
    /// How far, in points, a street closes over each side of a gap (its name's letters): 1.3 points,
    /// 4 pixels at the picture's scale.
    static let labelGap: CGFloat = 1.3
    /// The most pixels one scene reads (a 2048 × 2048 picture; the widget's is 1092 × 1146).
    static let maxPixels = 2_048 * 2_048
    /// Where Apple's "Maps" logo sits in the picture, in points (`WorldMapCreditClearance`'s rectangle).
    static func credit(in size: CGSize) -> CGRect {
        CGRect(x: 2, y: size.height - 40, width: 128, height: 44)
    }

    /// The share of white a pixel of the light snapshot keeps (`red`, `green`, `blue` in 0...255).
    static func alpha(red: Int, green: Int, blue: Int) -> Double {
        if min(red, green, blue) >= 250 { return street }
        // A park's path: a warm light grey, yellower than a building, darker than a block.
        if (232...245).contains(red), abs(red - green) <= 3, (7...12).contains(red - blue) { return street }
        if blue >= red + 30, blue >= green { return water }
        if green >= red + 6, green >= blue + 10 { return park }
        return 0
    }

    /// The share of white a pixel inside the logo's rectangle keeps: the logo's dark grey whole, its
    /// antialiased edge in between, the light ground nothing.
    static func creditAlpha(red: Int, green: Int, blue: Int) -> Double {
        let luminance = 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
        return min(1, max(0, (230 - luminance) / 130))
    }

    /// Apple's light map as the faint scene, the size of `base` in pixels: white at each pixel's share,
    /// premultiplied. `credit` is the logo's rectangle in pixels. A street's name, grey letters on the white
    /// road, would read as a cut-out, so the streets are closed over gaps narrower than `labelRadius` pixels
    /// each side (``closed(_:width:height:radius:)``) and the letters take the street's share. Nil when the
    /// map has no pixels to read or more than ``maxPixels``.
    static func scene(of base: UIImage, credit: CGRect, labelRadius: Int) -> CGImage? {
        guard let source = base.cgImage, source.width > 0, source.height > 0,
              source.width * source.height <= maxPixels, let pixels = rgba(of: source) else { return nil }
        let width = source.width, height = source.height
        var shares = [UInt8](repeating: 0, count: width * height)
        var streets = [Bool](repeating: false, count: width * height)
        let streetShare = UInt8((street * 255).rounded())
        for y in 0..<height {
            let creditRow = CGFloat(y) >= credit.minY && CGFloat(y) < credit.maxY
            for x in 0..<width {
                let index = y * width + x
                let red = Int(pixels[index * 4]), green = Int(pixels[index * 4 + 1]), blue = Int(pixels[index * 4 + 2])
                let share = alpha(red: red, green: green, blue: blue)
                let inCredit = creditRow && CGFloat(x) >= credit.minX && CGFloat(x) < credit.maxX
                let logo = inCredit ? creditAlpha(red: red, green: green, blue: blue) : 0
                shares[index] = UInt8((max(share, logo) * 255).rounded())
                streets[index] = share == street
            }
        }
        let roads = closed(streets, width: width, height: height, radius: labelRadius)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let value = roads[index] ? max(shares[index], streetShare) : shares[index]
            for channel in 0..<4 { out[index * 4 + channel] = value }
        }
        return image(out, width: width, height: height)
    }

    /// `mask` (rows top first) closed by a square of `radius` cells each side: a gap narrower than the
    /// square — a street's name — fills, while a straight edge stays where it was. Unchanged for a mask of
    /// the wrong size or a radius under 1.
    static func closed(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard width > 0, height > 0, mask.count == width * height, radius >= 1 else { return mask }
        var result = mask
        // Grow along the rows, then the columns; then shrink the same way.
        for (alongRows, every) in [(true, false), (false, false), (true, true), (false, true)] {
            result = slide(result, width: width, height: height, radius: radius, alongRows: alongRows, every: every)
        }
        return result
    }

    /// One pass of a window `radius` cells each side, along the rows or the columns: a cell is set where any
    /// cell in its window is (growing), or every one is (shrinking). Past the edge counts as unset while
    /// growing and set while shrinking, so the picture's edges neither grow nor wear away.
    private static func slide(_ mask: [Bool], width: Int, height: Int, radius: Int, alongRows: Bool, every: Bool) -> [Bool] {
        let lines = alongRows ? height : width, length = alongRows ? width : height
        let span = 2 * radius + 1, outside = every ? 1 : 0
        func isSet(_ line: Int, _ at: Int) -> Int {
            guard at >= 0, at < length else { return outside }
            return mask[alongRows ? line * width + at : at * width + line] ? 1 : 0
        }
        var out = mask
        for line in 0..<lines {
            var count = 0
            for at in -radius...radius { count += isSet(line, at) }
            for at in 0..<length {
                out[alongRows ? line * width + at : at * width + line] = every ? count == span : count > 0
                count += isSet(line, at + radius + 1) - isSet(line, at - radius)
            }
        }
        return out
    }

    /// `source`'s pixels as 8-bit RGBA rows, top first, with no padding; nil when they can't be drawn.
    private static func rgba(of source: CGImage) -> [UInt8]? {
        let width = source.width, height = source.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        // R9: no pointer seam — the drawn copy's bytes come back as `Data`.
        guard let drawn = context.makeImage(), drawn.bytesPerRow == width * 4,
              let data = drawn.dataProvider?.data as Data?, data.count >= width * height * 4 else { return nil }
        return [UInt8](data)
    }

    /// Premultiplied RGBA bytes as an image.
    private static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Clear ring twin: begin

/// A clear ring round a pixel sprite: its painted cells dilated by one in all eight directions, diagonals
/// included (phone test W-11). The map widget punches Sprout's out of the one-colour map, so no line touches
/// Sprout or shows through its face; the one-colour picture clears a marker's, so no street runs through
/// its outline. The app and the widget each keep this copy, word for word (`WidgetMapTests` holds them equal).
enum MapClearRing {
    /// The most cells a sprite may have.
    static let maxCells = 4_096

    /// `painted` (rows top first, `width` × `height`) dilated by one cell, on a grid one cell larger on
    /// every side: (width + 2) × (height + 2), where input cell (x, y) is output cell (x + 1, y + 1). Empty
    /// for a grid of the wrong size.
    static func ring(painted: [Bool], width: Int, height: Int) -> [Bool] {
        guard width > 0, height > 0, width <= maxCells, height <= maxCells, width * height <= maxCells,
              painted.count == width * height else { return [] }
        let outWidth = width + 2
        var out = [Bool](repeating: false, count: outWidth * (height + 2))
        for y in 0..<height {
            for x in 0..<width where painted[y * width + x] {
                for dy in 0...2 {
                    for dx in 0...2 { out[(y + dy) * outWidth + x + dx] = true }
                }
            }
        }
        return out
    }
}

// MARK: - Clear ring twin: end

/// The map widget's one-colour drawing (phone test W-11, `ref-tint-map` draft 2 and `ref-tint-map-light`,
/// approved), from the same viewport and content as the colour pictures: the faint scene of Apple's light
/// map (``WorldWidgetMonoInk``), the unexplored ring's hexes as outlines alone, the saved trails at the
/// full tint, and the homes, the hotel and the kept places as outline icons in a cleared ring. White on
/// clear: iOS tints it. Nothing else — no names, counts or history; Sprout, the plate and the tag are the
/// widget's, which punches the map out under them.
struct WorldWidgetMonoCanvas: View {
    /// The faint scene, in pixels.
    let scene: CGImage
    let viewport: MapViewport
    let size: CGSize
    let content: WorldWidgetMapContent

    var body: some View {
        Canvas { context, canvasSize in
            context.draw(Image(decorative: scene, scale: 1), in: CGRect(origin: .zero, size: canvasSize))
            var lines = context
            // Apple's logo stays clear of the hexes and the trails, as in the colour pictures.
            var clearance = Path(CGRect(origin: .zero, size: canvasSize).insetBy(dx: -12, dy: -12))
            clearance.addRoundedRect(in: WorldWidgetMonoInk.credit(in: canvasSize), cornerSize: CGSize(width: 10, height: 10))
            lines.clip(to: clearance, style: FillStyle(eoFill: true))
            let painter = NatureFogPicturePainter(viewport: viewport,
                                                  clearing: WorldWidgetMapCanvas.clearing(viewport: viewport, size: canvasSize, content: content),
                                                  palette: NatureFogPalette(dark: false, highContrast: false))
            if let outlines = painter.outlines(in: canvasSize) {
                lines.stroke(outlines, with: .color(.white.opacity(WorldWidgetMonoInk.hexOutline)), lineWidth: 1)
            }
            for trail in content.trails {
                lines.stroke(trailPath(trail, in: canvasSize), with: .color(.white),
                             style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            for place in content.places { drawPlace(place, in: &context, size: canvasSize) }
            for home in content.homes { drawHome(home, in: &context, size: canvasSize) }
        }
        .frame(width: size.width, height: size.height)
    }

    /// A trail's line in the picture's points.
    private func trailPath(_ trail: [GeoPoint], in size: CGSize) -> Path {
        var path = Path()
        for (index, point) in trail.enumerated() {
            let screen = viewport.screenPoint(for: point, in: size)
            if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        return path
    }

    /// A kept place: the colour picture's 34-point tile as its 3-point outline and the icon's ink, over a
    /// cleared square a little larger, so no street runs through it.
    private func drawPlace(_ place: WorldMapMarker, in context: inout GraphicsContext, size: CGSize) {
        let at = viewport.screenPoint(for: place.point, in: size)
        let tile = CGRect(x: at.x - 17, y: at.y - 17, width: 34, height: 34)
        Self.clear(Path(roundedRect: tile.insetBy(dx: -2, dy: -2), cornerRadius: 10), in: &context)
        context.stroke(Path(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 6.5), with: .color(.white), lineWidth: 3)
        let sprite = place.kind == .space ? WorldPlaceSprites.dumbbell : WorldPlaceSprites.bowl
        let origin = CGPoint(x: at.x - CGFloat(sprite.width), y: at.y - CGFloat(sprite.height))
        context.fill(Self.cells(of: sprite, at: origin, scale: 2) { $0 == "k" }, with: .color(.white))
    }

    /// A home or the hotel: the colour picture's sprite, where it stands there, as its ink alone over its
    /// clear ring.
    private func drawHome(_ home: HomePlace, in context: inout GraphicsContext, size: CGSize) {
        let sprite = home.kind == .home ? WorldPlaceSprites.house : WorldPlaceSprites.hotel
        let scale: CGFloat = 4
        let at = viewport.screenPoint(for: home.point, in: size)
        let offset = WorldPlaceSprites.baseOffset(scale: scale)
        let origin = CGPoint(x: at.x + offset.width - CGFloat(sprite.width) * scale / 2,
                             y: at.y + offset.height - CGFloat(sprite.height) * scale / 2)
        Self.clear(Self.ring(of: sprite, at: origin, scale: scale), in: &context)
        context.fill(Self.cells(of: sprite, at: origin, scale: scale) { $0 == "k" }, with: .color(.white))
    }

    /// Clears `path` out of what is drawn so far.
    private static func clear(_ path: Path, in context: inout GraphicsContext) {
        var eraser = context
        eraser.blendMode = .destinationOut
        eraser.fill(path, with: .color(.white))
    }

    /// The cells of `sprite` whose key passes `keep`, as squares of `scale` points from `origin`.
    static func cells(of sprite: WorldSprite, at origin: CGPoint, scale: CGFloat, keep: (Character) -> Bool) -> Path {
        var path = Path()
        for (y, row) in sprite.rows.enumerated() {
            for (x, key) in row.enumerated() where key != "." && keep(key) {
                path.addRect(CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale, width: scale, height: scale))
            }
        }
        return path
    }

    /// `sprite`'s clear ring (``MapClearRing``), as squares of `scale` points from `origin`.
    static func ring(of sprite: WorldSprite, at origin: CGPoint, scale: CGFloat) -> Path {
        let painted = sprite.rows.flatMap { row in row.map { $0 != "." } }
        let ring = MapClearRing.ring(painted: painted, width: sprite.width, height: sprite.height)
        var path = Path()
        for (index, on) in ring.enumerated() where on {
            let x = index % (sprite.width + 2) - 1, y = index / (sprite.width + 2) - 1
            path.addRect(CGRect(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale, width: scale, height: scale))
        }
        return path
    }

    /// The one-colour drawing as PNG at `scale`, from Apple's light map `base`; nil when it can't be drawn.
    static func png(base: UIImage, viewport: MapViewport, content: WorldWidgetMapContent, size: CGSize, scale: CGFloat) -> Data? {
        guard viewport.isUsable, size.width > 0, size.height > 0, let source = base.cgImage else { return nil }
        let perPoint = CGFloat(source.width) / size.width
        let credit = WorldWidgetMonoInk.credit(in: size)
        let pixelCredit = CGRect(x: credit.minX * perPoint, y: credit.minY * perPoint,
                                 width: credit.width * perPoint, height: credit.height * perPoint)
        let labelRadius = max(1, Int((WorldWidgetMonoInk.labelGap * perPoint).rounded()))
        guard let scene = WorldWidgetMonoInk.scene(of: base, credit: pixelCredit, labelRadius: labelRadius) else { return nil }
        let renderer = ImageRenderer(content: WorldWidgetMonoCanvas(scene: scene, viewport: viewport, size: size, content: content))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
    }
}

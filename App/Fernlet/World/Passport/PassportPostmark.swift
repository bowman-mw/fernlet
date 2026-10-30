import CoreText
import FernletUI
import SwiftUI
import WorldMapStore

/// The three postmark shapes: a ring (continents), a hexagon (oceans and seas), a rounded rectangle (countries).
nonisolated enum PassportPostmarkShape: Hashable, Sendable {
    case round, hex, rect

    /// The postmark's drawing size in points at scale 1: 56 × 44 for a country, 48 × 48 for the rest.
    var size: CGSize { self == .rect ? CGSize(width: 56, height: 44) : CGSize(width: 48, height: 48) }
}

/// An earned stamp, ready to draw: its ink (light mode), its pixel art, its printed label (countries only), and the
/// key its tilt and wear are seeded from.
nonisolated struct PassportStampDrawing: Hashable, Sendable {
    /// The light-mode ink, `0xRRGGBB` (dark mode lifts it with `PassportInk.mix2`).
    let ink: UInt32
    /// The art, top row first, `true` where the ink is.
    let art: [[Bool]]
    /// The label's lines in the stamp's capitals (a country's), or empty.
    let label: [String]
    /// The stamp's frozen key (``PassportStampSeed``).
    let key: String
}

/// One passport stamp drawn as the mockup's `postmark()` draws it (World-Exploration-Spec §3): the shape's double
/// outline in one ink, the art as pixel squares with about 7 % worn away, a country's label in DM Sans Bold
/// capitals, and the stamp's tilt; or, not yet earned, the shape dashed with a "?" and no name.
///
/// Drawn in a Canvas in the postmark's own 56 × 44 or 48 × 48 points, scaled, so it stays crisp at any size. The
/// label is glyph outlines from Core Text in the stamp's ink, so its size is the stamp's, never Dynamic Type's
/// (the stamp is a picture). It says nothing to VoiceOver itself: ``PassportStampView`` names it.
struct PassportPostmark: View {
    /// The stamp, or nil for a space not earned yet.
    let stamp: PassportStampDrawing?
    let shape: PassportPostmarkShape
    /// The drawing's scale (1.25 in a continent's spread, 1.6 for its header, …).
    let scale: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let size = shape.size
        let dark = colorScheme == .dark, strong = contrast == .increased
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            if let stamp {
                PassportPostmarkPainter.drawEarned(stamp, shape: shape, dark: dark, in: &context)
            } else {
                PassportPostmarkPainter.drawSpace(shape: shape, dark: dark, strong: strong, in: &context)
            }
        }
        .frame(width: size.width * scale, height: size.height * scale)
        .rotationEffect(.degrees(Double(stamp.map { PassportStampSeed.tilt($0.key) } ?? 0)))
    }
}

/// The postmark's drawing steps, in the postmark's own points (``PassportPostmark`` scales the context first).
@MainActor
enum PassportPostmarkPainter {
    /// The most pixels across or down an art (a silhouette is at most 48).
    static let maxArtSide = 48

    /// An earned stamp: outline, art, label.
    static func drawEarned(_ stamp: PassportStampDrawing, shape: PassportPostmarkShape, dark: Bool,
                           in context: inout GraphicsContext) {
        let ink = PassportInk.color(PassportInk.resolved(stamp.ink, dark: dark))
        drawOutline(shape: shape, ink: ink, in: &context)
        drawArt(stamp.art, shape: shape, seed: PassportStampSeed.seed(stamp.key), ink: ink, in: &context)
        guard shape == .rect, let size = PassportStampLabel.pointSize(for: stamp.label) else { return }
        let baselines = PassportStampLabel.baselines(lines: stamp.label.count)
        for (line, baseline) in zip(stamp.label, baselines) {
            let path = PassportGlyphs.path(line, fontName: FernletFontName.dmSansBold, size: size,
                                           tracking: PassportStampLabel.letterSpacing,
                                           centreX: PassportStampLabel.centreX, baseline: baseline)
            context.fill(path, with: .color(ink))
        }
    }

    /// The shape's two outlines (and a ring's eight dots).
    private static func drawOutline(shape: PassportPostmarkShape, ink: Color, in context: inout GraphicsContext) {
        switch shape {
        case .rect:
            context.stroke(Path(roundedRect: CGRect(x: 2.5, y: 2.5, width: 51, height: 39), cornerRadius: 5),
                           with: .color(ink), lineWidth: 2)
            context.stroke(Path(roundedRect: CGRect(x: 6, y: 6, width: 44, height: 25), cornerRadius: 3),
                           with: .color(ink), lineWidth: 0.8)
        case .hex:
            context.stroke(hexagon(radius: 22), with: .color(ink), lineWidth: 2)
            context.stroke(hexagon(radius: 18), with: .color(ink), lineWidth: 0.8)
        case .round:
            context.stroke(circle(radius: 22), with: .color(ink), lineWidth: 2)
            context.stroke(circle(radius: 18), with: .color(ink), lineWidth: 0.8)
            for step in 0..<8 {
                let angle = Double(step) * .pi / 4 + 0.39
                let rect = CGRect(x: 24 + 20 * cos(angle) - 0.6, y: 24 + 20 * sin(angle) - 0.6, width: 1.2, height: 1.2)
                context.fill(Path(rect), with: .color(ink))
            }
        }
    }

    /// The art as pixel squares (each a hair over its pitch so neighbours join), centred in the shape, skipping
    /// the worn ones the stamp's seed picks.
    private static func drawArt(_ art: [[Bool]], shape: PassportPostmarkShape, seed: UInt32, ink: Color,
                                in context: inout GraphicsContext) {
        let height = min(art.count, maxArtSide), width = min(art.first?.count ?? 0, maxArtSide)
        guard height > 0, width > 0 else { return }
        let centre = CGPoint(x: shape.size.width / 2, y: shape == .rect ? 18.5 : shape.size.height / 2)
        let pitch = min((shape == .rect ? 21 : 31) / CGFloat(max(width, height)), 2.2)
        let originX = centre.x - CGFloat(width) * pitch / 2, originY = centre.y - CGFloat(height) * pitch / 2
        var path = Path(), wear = seed
        for row in 0..<height {
            for col in 0..<min(width, art[row].count) where art[row][col] {
                wear = PassportStampSeed.next(wear)
                guard !PassportStampSeed.isWorn(wear) else { continue }
                path.addRect(CGRect(x: originX + CGFloat(col) * pitch, y: originY + CGFloat(row) * pitch,
                                    width: pitch + 0.05, height: pitch + 0.05))
            }
        }
        context.fill(path, with: .color(ink))
    }

    /// A space not earned yet: the shape dashed and a "?", in the page's ink at low strength (stronger under
    /// Increase Contrast).
    static func drawSpace(shape: PassportPostmarkShape, dark: Bool, strong: Bool, in context: inout GraphicsContext) {
        let base = dark ? Color(red: 1, green: 241 / 255, blue: 207 / 255) : Color(red: 74 / 255, green: 46 / 255,
                                                                                    blue: 28 / 255)
        let line = base.opacity(strong ? 0.7 : (dark ? 0.4 : 0.35))
        let mark = base.opacity(strong ? 0.75 : (dark ? 0.45 : 0.4))
        let outline: Path = switch shape {
        case .rect: Path(roundedRect: CGRect(x: 3, y: 3, width: 50, height: 38), cornerRadius: 5)
        case .hex: hexagon(radius: 21)
        case .round: circle(radius: 21)
        }
        context.stroke(outline, with: .color(line), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        let centre = CGPoint(x: shape.size.width / 2, y: shape.size.height / 2)
        context.fill(PassportGlyphs.path("?", fontName: FernletFontName.dmSans, size: 12, tracking: 0,
                                         centreX: centre.x, baseline: centre.y + 4), with: .color(mark))
    }

    /// The hexagon of the mockup's `hexRing`, centred in a 48-point square, a corner pointing right.
    private static func hexagon(radius: CGFloat) -> Path {
        var path = Path()
        for corner in 0..<6 {
            let angle = Double(corner) * .pi / 3
            let point = CGPoint(x: 24 + radius * cos(angle), y: 24 + radius * sin(angle))
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A circle centred in a 48-point square.
    private static func circle(radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: 24 - radius, y: 24 - radius, width: radius * 2, height: radius * 2))
    }
}

/// The country label's layout from the stamp file's `style.name` (owner-approved DM Sans Bold), read from
/// `WorldCountryStamps` so the two never disagree.
nonisolated enum PassportStampLabel {
    /// The label's centre.
    static var centreX: CGFloat { CGFloat(WorldCountryStamps.labelCentreX) }
    /// The letter-spacing, in points.
    static var letterSpacing: CGFloat { CGFloat(WorldCountryStamps.labelLetterSpacing) }

    /// The point size for `label`, or nil for an empty one.
    static func pointSize(for label: [String]) -> CGFloat? {
        WorldCountryStamps.labelPointSize(for: label).map { CGFloat($0) }
    }

    /// The baselines for a label of `lines` lines (one: 38.6; two: 35.3 and 39.7).
    static func baselines(lines: Int) -> [CGFloat] {
        let two = WorldCountryStamps.twoLineBaselines
        return lines == 2 ? [CGFloat(two.first), CGFloat(two.second)] : [CGFloat(WorldCountryStamps.oneLineBaseline)]
    }
}

/// Text as filled glyph outlines (Core Text), so a stamp's label is drawn at the stamp's own size in its ink.
@MainActor
enum PassportGlyphs {
    /// The most characters drawn on one line.
    static let maxCharacters = 32

    /// `text` in the font named `fontName` at `size` points with `tracking` added after each glyph, centred on
    /// `centreX` with its baseline at `baseline` (y grows down). Empty when the font has no glyphs for it.
    static func path(_ text: String, fontName: String, size: CGFloat, tracking: CGFloat, centreX: CGFloat,
                     baseline: CGFloat) -> Path {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let units = Array(text.prefix(maxCharacters).utf16)
        guard !units.isEmpty else { return Path() }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) else { return Path() }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let width = advances.reduce(0) { $0 + $1.width } + tracking * CGFloat(max(glyphs.count - 1, 0))
        var path = Path(), x = centreX - width / 2
        for (glyph, advance) in zip(glyphs, advances) where glyph != 0 {
            if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                let place = CGAffineTransform(translationX: x, y: baseline).scaledBy(x: 1, y: -1)
                path.addPath(Path(outline), transform: place)
            }
            x += advance.width + tracking
        }
        return path
    }
}

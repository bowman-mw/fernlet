import FernletUI
import SwiftUI

/// An airport's ticket stamp drawn as the mockup's `apStamp` draws it (World-Airports-Spec §4.1), in the ticket's
/// own 56 × 44 points (``PassportPostmark`` scales and tilts the context): the `TICKET` outline, notched on both
/// sides, at 2 pt under a 42 × 32 inner frame at 0.8 pt; the art as pixel squares (at most 1.7 pt, fitted to 30 ×
/// 13 around the point 28, 16) with the seeded wear dropped; the code in DM Sans Bold 9.6 with 1.1 letter-spacing on
/// the 31.6 baseline and the city (or TRANSIT) in DM Sans Bold 4.2 (3.5 when long) with 0.3 on the 36.4 baseline.
/// Not found yet, the ticket is a dashed outline alone.
@MainActor
enum PassportTicketPainter {
    /// The code's and the city's baselines.
    static let codeBaseline: CGFloat = 31.6
    static let cityBaseline: CGFloat = 36.4
    /// The art's box and centre.
    static let artBox = CGSize(width: 30, height: 13)
    static let artCentre = CGPoint(x: 28, y: 16)
    /// The largest art pixel.
    static let maxPixel: CGFloat = 1.7

    /// An earned ticket: outline, inner frame, art and lettering in the stamp's ink (``PassportInk/mix2(_:)`` in
    /// dark mode).
    static func drawEarned(_ stamp: PassportStampDrawing, dark: Bool, in context: inout GraphicsContext) {
        let ink = PassportInk.color(PassportInk.resolved(stamp.ink, dark: dark))
        context.stroke(ticket(), with: .color(ink), lineWidth: 2)
        context.stroke(Path(roundedRect: CGRect(x: 7, y: 6, width: 42, height: 32), cornerRadius: 3),
                       with: .color(ink), lineWidth: 0.8)
        drawArt(PassportAirportStamp.worn(stamp.art, wearKey: stamp.wearKey ?? stamp.key), ink: ink, in: &context)
        if let code = stamp.label.first {
            context.fill(PassportGlyphs.path(code, fontName: FernletFontName.dmSansBold,
                                             size: CGFloat(PassportAirportStamp.codeSize),
                                             tracking: CGFloat(PassportAirportStamp.codeTracking), centreX: 28,
                                             baseline: codeBaseline), with: .color(ink))
        }
        if stamp.label.count > 1 {
            let city = stamp.label[1]
            context.fill(PassportGlyphs.path(city, fontName: FernletFontName.dmSansBold,
                                             size: CGFloat(PassportAirportStamp.citySize(for: city)),
                                             tracking: CGFloat(PassportAirportStamp.cityTracking), centreX: 28,
                                             baseline: cityBaseline), with: .color(ink))
        }
    }

    /// The art's ink pixels (already worn) as squares a hair over their pitch, so neighbours join.
    private static func drawArt(_ art: [[Bool]], ink: Color, in context: inout GraphicsContext) {
        let height = art.count, width = art.map(\.count).max() ?? 0
        guard height > 0, width > 0 else { return }
        let pitch = min(artBox.width / CGFloat(width), artBox.height / CGFloat(height), maxPixel)
        let originX = artCentre.x - CGFloat(width) * pitch / 2, originY = artCentre.y - CGFloat(height) * pitch / 2
        var path = Path()
        // Bounded: the art is at most PassportAirportStamp.maxArtSide square.
        for (row, line) in art.enumerated() {
            for (col, isInk) in line.enumerated() where isInk {
                path.addRect(CGRect(x: originX + CGFloat(col) * pitch, y: originY + CGFloat(row) * pitch,
                                    width: pitch + 0.05, height: pitch + 0.05))
            }
        }
        context.fill(path, with: .color(ink))
    }

    /// A ticket not found yet: the outline dashed 3 3 at 1.5 pt in the page's ink at low strength (stronger
    /// under Increase Contrast), with no name and no art.
    static func drawSpace(dark: Bool, strong: Bool, in context: inout GraphicsContext) {
        let base = dark ? Color(red: 1, green: 241 / 255, blue: 207 / 255)
            : Color(red: 74 / 255, green: 46 / 255, blue: 28 / 255)
        let line = base.opacity(strong ? 0.7 : (dark ? 0.4 : 0.35))
        context.stroke(ticket(), with: .color(line), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
    }

    /// The mockup's `TICKET` path: a 51 × 39 ticket with 5-pt corners, a 4-pt semicircle notched into each side
    /// at its middle (the arcs as two quarter-circle curves each, so the notch always bites inward).
    static func ticket() -> Path {
        let bend: CGFloat = 4 * 0.552_284_75
        var path = Path()
        path.move(to: CGPoint(x: 7.5, y: 2.5))
        path.addLine(to: CGPoint(x: 48.5, y: 2.5))
        path.addQuadCurve(to: CGPoint(x: 53.5, y: 7.5), control: CGPoint(x: 53.5, y: 2.5))
        path.addLine(to: CGPoint(x: 53.5, y: 18))
        path.addCurve(to: CGPoint(x: 49.5, y: 22), control1: CGPoint(x: 53.5 - bend, y: 18),
                      control2: CGPoint(x: 49.5, y: 22 - bend))
        path.addCurve(to: CGPoint(x: 53.5, y: 26), control1: CGPoint(x: 49.5, y: 22 + bend),
                      control2: CGPoint(x: 53.5 - bend, y: 26))
        path.addLine(to: CGPoint(x: 53.5, y: 36.5))
        path.addQuadCurve(to: CGPoint(x: 48.5, y: 41.5), control: CGPoint(x: 53.5, y: 41.5))
        path.addLine(to: CGPoint(x: 7.5, y: 41.5))
        path.addQuadCurve(to: CGPoint(x: 2.5, y: 36.5), control: CGPoint(x: 2.5, y: 41.5))
        path.addLine(to: CGPoint(x: 2.5, y: 26))
        path.addCurve(to: CGPoint(x: 6.5, y: 22), control1: CGPoint(x: 2.5 + bend, y: 26),
                      control2: CGPoint(x: 6.5, y: 22 + bend))
        path.addCurve(to: CGPoint(x: 2.5, y: 18), control1: CGPoint(x: 6.5, y: 22 - bend),
                      control2: CGPoint(x: 2.5 + bend, y: 18))
        path.addLine(to: CGPoint(x: 2.5, y: 7.5))
        path.addQuadCurve(to: CGPoint(x: 7.5, y: 2.5), control: CGPoint(x: 2.5, y: 2.5))
        path.closeSubpath()
        return path
    }
}

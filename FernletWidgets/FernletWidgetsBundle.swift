// FernletWidgetsBundle.swift
// FernletWidgets
//
// v1 companion widget: systemSmall (interactive +1 water) + lock-screen accessories.
// DESIGN: the companion renders as a per-mood GLYPH whose FACE is negative space (a filled blob
// with the eyes/mouth punched out via Canvas .destinationOut) — so it reads small and survives the
// Lock Screen's monochrome/tinted rendering, where the EXPRESSION (not colour) distinguishes moods.
// Translated from Docs/design-refs/widget.html badges 9a/9b/9c. Companion mood + water only —
// never anything sensitive.

import SwiftUI
import WidgetKit

enum FernletWidgetKind {
    static let companion = "FernletCompanion"
}

@main
struct FernletWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FernletCompanionWidget()
    }
}

struct FernletCompanionEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    /// Water progress only counts when the mirrored snapshot is for the CURRENT day; after a day
    /// rollover with the app closed, the fresh day starts at zero bottles.
    var bottleCount: Int {
        guard let snapshot else { return 0 }
        return snapshot.dateKey == WidgetDayKey.current(date) ? snapshot.bottleCount : 0
    }

    var hydrationTarget: Int { max(snapshot?.hydrationTarget ?? 4, 1) }
}

struct FernletCompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> FernletCompanionEntry {
        FernletCompanionEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FernletCompanionEntry) -> Void) {
        let snapshot = WidgetSnapshotStore().read() ?? (context.isPreview ? .placeholder : nil)
        completion(FernletCompanionEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FernletCompanionEntry>) -> Void) {
        let entry = FernletCompanionEntry(date: Date(), snapshot: WidgetSnapshotStore().read())
        // Single entry; refreshes are pushed by the app via WidgetCenter.reloadTimelines on every
        // snapshot mirror — the hourly policy just re-evaluates day rollover while the app is closed.
        let nextHour = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextHour)))
    }
}

struct FernletCompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FernletWidgetKind.companion, provider: FernletCompanionProvider()) { entry in
            FernletCompanionWidgetView(entry: entry)
        }
        .configurationDisplayName("Fernlet")
        .description("Your companion's mood and today's water, at a glance.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Palette (widget-local; the widget can't use the app's Color.* extension)

private enum FernletWidgetPalette {
    // Card + text (9b)
    static let card = Color(red: 0.984, green: 0.969, blue: 0.933)     // #FBF7EE
    static let ink = Color(red: 0.239, green: 0.180, blue: 0.118)      // #3D2E1E
    static let inkSoft = Color(red: 0.541, green: 0.478, blue: 0.384)  // #8A7A62
    static let waterAccent = Color(red: 0.369, green: 0.486, blue: 0.549) // #5E7C8C
    static let waterTrack = Color(red: 0.369, green: 0.486, blue: 0.549).opacity(0.18)
    static let buttonFill = Color(red: 0.353, green: 0.478, blue: 0.322) // #5A7A52
    static let buttonInk = Color(red: 0.961, green: 0.937, blue: 0.878)  // #F5EFE0
    static let dashed = Color(red: 0.776, green: 0.718, blue: 0.604)   // #C6B79A

    // Mood colours (9a). The Lock Screen tints/monochromes these away — the EXPRESSION carries the mood.
    static func mood(_ state: WidgetCompanionState?) -> Color {
        switch state {
        case .thriving: return Color(red: 0.420, green: 0.620, blue: 0.384) // #6B9E62 fern
        case .okay:     return Color(red: 0.788, green: 0.588, blue: 0.290) // #C9964A amber
        case .tired:    return Color(red: 0.545, green: 0.482, blue: 0.620) // #8B7B9E periwinkle
        case .resting:  return Color(red: 0.549, green: 0.651, blue: 0.714) // #8CA6B6 slate-blue
        case .sick:     return Color(red: 0.753, green: 0.404, blue: 0.290) // #C0674A terracotta
        case nil:       return Color(red: 0.420, green: 0.620, blue: 0.384)
        }
    }
}

// MARK: - Companion glyph (9a): a blob silhouette with the FACE as negative space
//
// Ported from the SVG masks in Docs/design-refs/widget.html (100×100 userSpace). The blob is a
// filled circle; the face features (eyes/mouth/z) are drawn back into the same Canvas layer with
// `.blendMode(.destinationOut)`, ERASING them to transparency so the face is literally holes in the
// shape. Because the mood is told by the punched-out expression (not the fill colour), the glyph
// survives the Lock Screen's monochrome/tinted rendering: pass `.white` for the accessory families.

private struct CompanionGlyph: View {
    let state: WidgetCompanionState?
    /// Single fill colour for the whole silhouette. Accessories pass `.white` (system tints it).
    var fill: Color

    var body: some View {
        Canvas { context, size in
            // Everything is authored in a 100×100 space, then scaled to fit.
            let s = min(size.width, size.height) / 100.0
            context.scaleBy(x: s, y: s)

            // Isolate a layer so `.destinationOut` erases the blob rather than the whole widget.
            context.drawLayer { layer in
                // 1) the blob body
                let body = Path(ellipseIn: CGRect(x: 8, y: 10, width: 84, height: 84))
                layer.fill(body, with: .color(fill))

                // 2) punch the face out of the body
                Self.eraseFace(for: state, in: layer)
            }
        }
        // Let the Lock Screen recolour the single-colour drawing.
        .widgetAccentable()
    }

    /// Draws each mood's exact eyes/mouth (+resting "z") with `.destinationOut`, matching the masks.
    private static func eraseFace(for state: WidgetCompanionState?, in ctx: GraphicsContext) {
        let clear = GraphicsContext.Shading.color(.black) // any opaque colour; blend mode erases
        var eyeCtx = ctx
        eyeCtx.blendMode = .destinationOut

        func dotEye(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }
        func stroke(_ build: (inout Path) -> Void, width: CGFloat) {
            var p = Path(); build(&p)
            eyeCtx.stroke(p, with: clear,
                          style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }

        switch state {
        case .thriving, nil:
            eyeCtx.fill(dotEye(37, 45, 5.5), with: clear)
            eyeCtx.fill(dotEye(63, 45, 5.5), with: clear)
            stroke({ p in
                p.move(to: CGPoint(x: 33, y: 55))
                p.addQuadCurve(to: CGPoint(x: 67, y: 55), control: CGPoint(x: 50, y: 75))
            }, width: 6.5)

        case .okay:
            eyeCtx.fill(dotEye(37, 48, 5.5), with: clear)
            eyeCtx.fill(dotEye(63, 48, 5.5), with: clear)
            stroke({ p in
                p.move(to: CGPoint(x: 41, y: 61))
                p.addQuadCurve(to: CGPoint(x: 59, y: 61), control: CGPoint(x: 50, y: 68))
            }, width: 5.5)

        case .tired:
            stroke({ p in                       // sleepy slanted lines
                p.move(to: CGPoint(x: 31, y: 47)); p.addLine(to: CGPoint(x: 44, y: 50))
            }, width: 5.5)
            stroke({ p in
                p.move(to: CGPoint(x: 69, y: 47)); p.addLine(to: CGPoint(x: 56, y: 50))
            }, width: 5.5)
            stroke({ p in                       // flat mouth
                p.move(to: CGPoint(x: 42, y: 63)); p.addLine(to: CGPoint(x: 58, y: 63))
            }, width: 5)

        case .resting:
            stroke({ p in                       // closed-arc eyes
                p.move(to: CGPoint(x: 31, y: 50))
                p.addQuadCurve(to: CGPoint(x: 44, y: 50), control: CGPoint(x: 37.5, y: 56))
            }, width: 5)
            stroke({ p in
                p.move(to: CGPoint(x: 56, y: 50))
                p.addQuadCurve(to: CGPoint(x: 69, y: 50), control: CGPoint(x: 62.5, y: 56))
            }, width: 5)
            stroke({ p in                       // tiny mouth
                p.move(to: CGPoint(x: 44, y: 62))
                p.addQuadCurve(to: CGPoint(x: 56, y: 62), control: CGPoint(x: 50, y: 66))
            }, width: 4.5)
            stroke({ p in                       // the "z"
                p.move(to: CGPoint(x: 70, y: 20))
                p.addLine(to: CGPoint(x: 80, y: 20))
                p.addLine(to: CGPoint(x: 70, y: 31))
                p.addLine(to: CGPoint(x: 80, y: 31))
            }, width: 3.4)

        case .sick:
            stroke({ p in                       // queasy x-ish eyes (chevrons)
                p.move(to: CGPoint(x: 32, y: 44))
                p.addLine(to: CGPoint(x: 40, y: 48))
                p.addLine(to: CGPoint(x: 32, y: 52))
            }, width: 4.5)
            stroke({ p in
                p.move(to: CGPoint(x: 68, y: 44))
                p.addLine(to: CGPoint(x: 60, y: 48))
                p.addLine(to: CGPoint(x: 68, y: 52))
            }, width: 4.5)
            stroke({ p in                       // wavy mouth
                p.move(to: CGPoint(x: 38, y: 63))
                p.addQuadCurve(to: CGPoint(x: 46, y: 63), control: CGPoint(x: 42, y: 58))
                p.addQuadCurve(to: CGPoint(x: 54, y: 63), control: CGPoint(x: 50, y: 68))
                p.addQuadCurve(to: CGPoint(x: 62, y: 63), control: CGPoint(x: 58, y: 58))
            }, width: 4)
        }
    }
}

// MARK: - Water progress ring (9b/9c): a thick track + progress arc with a water-drop glyph inside

private struct WaterRing: View {
    let filled: Int
    let target: Int
    var lineWidth: CGFloat = 6
    var track: Color = FernletWidgetPalette.waterTrack
    var accent: Color = FernletWidgetPalette.waterAccent

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(Double(filled) / Double(target), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth))
            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            WaterDropGlyph()
                .stroke(accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: lineWidth * 3, height: lineWidth * 3)
        }
    }
}

/// A single teardrop path (the widget.html water-drop icon), authored in a 24×24 box.
private struct WaterDropGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var p = Path()
        // M12 3 s6 6.4 6 11 a6 6 0 0 1-12 0 c0-4.6 6-11 6-11z
        p.move(to: pt(12, 3))
        p.addQuadCurve(to: pt(18, 14), control: pt(18, 9.4))
        p.addArc(center: pt(12, 14), radius: 6 * s,
                 startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addQuadCurve(to: pt(12, 3), control: pt(6, 9.4))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root view

struct FernletCompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FernletCompanionEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                CircularCompanionView(entry: entry)
            case .accessoryRectangular:
                RectangularCompanionView(entry: entry)
            default:
                SmallCompanionView(entry: entry)
            }
        }
        // Companion state encodes wellbeing (incl. sickness) — redact on a locked Lock Screen.
        .privacySensitive()
        .containerBackground(for: .widget) { containerBackground }
    }

    @ViewBuilder private var containerBackground: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular:
            Color.clear                 // accessories draw on the Lock Screen's own material
        default:
            FernletWidgetPalette.card   // 9b cream card
        }
    }
}

// MARK: - 9b · Home Screen (systemSmall)

private struct SmallCompanionView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                // top row: companion glyph (left) + water ring (right)
                HStack(alignment: .top) {
                    CompanionGlyph(state: snapshot.companionState,
                                   fill: FernletWidgetPalette.mood(snapshot.companionState))
                        .frame(width: 52, height: 52)
                    Spacer(minLength: 8)
                    WaterRing(filled: entry.bottleCount, target: entry.hydrationTarget, lineWidth: 6)
                        .frame(width: 52, height: 52)
                }

                Spacer(minLength: 8)

                // bottom row: "3 of 6" / "bottles today" (left) + "+1" button (right)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(entry.bottleCount)")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(FernletWidgetPalette.ink)
                            Text(" of \(entry.hydrationTarget)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(FernletWidgetPalette.inkSoft)
                        }
                        Text("bottles today")
                            .font(.system(size: 12))
                            .foregroundStyle(FernletWidgetPalette.inkSoft)
                    }
                    Spacer(minLength: 8)
                    Button(intent: WaterPlusOneIntent()) {
                        Text("+1")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(FernletWidgetPalette.buttonInk)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .background(FernletWidgetPalette.buttonFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
        } else {
            PlaceholderView()
        }
    }
}

/// 9b "Before first launch": a soft dashed blob outline + "Open Fernlet / to meet your companion".
private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 14) {
            DashedCompanionOutline()
                .frame(width: 60, height: 60)
                .opacity(0.6)
            VStack(spacing: 3) {
                Text("Open Fernlet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FernletWidgetPalette.ink)
                Text("to meet your companion")
                    .font(.system(size: 12))
                    .foregroundStyle(FernletWidgetPalette.inkSoft)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The dashed placeholder blob (a simple always-happy face, drawn as strokes not negative space).
private struct DashedCompanionOutline: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 100.0
            context.scaleBy(x: s, y: s)
            let color = GraphicsContext.Shading.color(FernletWidgetPalette.dashed)

            let ring = Path(ellipseIn: CGRect(x: 10, y: 12, width: 80, height: 80))
            context.stroke(ring, with: color,
                           style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [5, 7]))

            context.fill(Path(ellipseIn: CGRect(x: 34, y: 44, width: 8, height: 8)), with: color)
            context.fill(Path(ellipseIn: CGRect(x: 58, y: 44, width: 8, height: 8)), with: color)

            var smile = Path()
            smile.move(to: CGPoint(x: 40, y: 62))
            smile.addQuadCurve(to: CGPoint(x: 60, y: 62), control: CGPoint(x: 50, y: 69))
            context.stroke(smile, with: color,
                           style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }
}

// MARK: - 9c · Lock Screen · circular (companion glyph — monochrome-safe)

private struct CircularCompanionView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            // Companion glyph is the primary circular option; the shape+negative-space reads in
            // the single-tint Lock Screen render (white fill, system applies the vibrancy tint).
            CompanionGlyph(state: snapshot.companionState, fill: .white)
                .padding(3)
        } else {
            CompanionGlyph(state: nil, fill: .white)
                .padding(3)
        }
    }
}

// MARK: - 9c · Lock Screen · rectangular (glyph + "Thriving · 3 of 6 bottles" + 6-segment bar)

private struct RectangularCompanionView: View {
    let entry: FernletCompanionEntry

    private var moodLabel: String {
        switch entry.snapshot?.companionState {
        case .thriving: return "Thriving"
        case .okay:     return "Okay"
        case .tired:    return "Tired"
        case .resting:  return "Resting"
        case .sick:     return "Sick"
        case nil:       return "Fernlet"
        }
    }

    var body: some View {
        if let snapshot = entry.snapshot {
            HStack(spacing: 10) {
                CompanionGlyph(state: snapshot.companionState, fill: .white)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(moodLabel) · \(entry.bottleCount) of \(entry.hydrationTarget) bottles")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    SegmentFillBar(filled: entry.bottleCount, target: entry.hydrationTarget)
                        .frame(height: 6)
                }
            }
        } else {
            HStack(spacing: 10) {
                CompanionGlyph(state: nil, fill: .white)
                    .frame(width: 34, height: 34)
                Text("Open Fernlet to say hi")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
            }
        }
    }
}

/// The 6-segment fill bar under the rectangular accessory (caps at 6 segments per the mockup).
private struct SegmentFillBar: View {
    let filled: Int
    let target: Int

    private var segments: Int { max(min(target, 6), 1) }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 5
            let count = segments
            let totalSpacing = spacing * CGFloat(count - 1)
            let segWidth = max((geo.size.width - totalSpacing) / CGFloat(count), 1)
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(index < filled ? 0.95 : 0.3))
                        .frame(width: segWidth)
                }
            }
        }
    }
}

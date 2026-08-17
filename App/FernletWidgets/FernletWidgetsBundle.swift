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

/// Namespace for the extension's WidgetKit `kind` identifiers.
///
/// The app addresses widget timelines by these strings (e.g.
/// `WidgetCenter.shared.reloadTimelines(ofKind:)` after every snapshot mirror and from
/// ``WaterPlusOneIntent``), so they are persisted identity — never change a value once shipped.
enum FernletWidgetKind {
    /// The companion widget (`FernletCompanionWidget`) — currently the only timeline-based widget.
    static let companion = "FernletCompanion"
}

/// The extension's `@main` entry point: registers every widget and Live Activity this target ships.
///
/// One companion widget (Home Screen + Lock Screen accessories) plus the two Live Activities
/// (``WorkoutLiveActivity``, ``CookingLiveActivity``). Anything not listed here never appears in the
/// widget gallery or on the Lock Screen, so a new surface must be added to this body.
@main
struct FernletWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FernletCompanionWidget()
        WorkoutLiveActivity()
        CookingLiveActivity()
    }
}

/// One timeline entry for the companion widget: an entry date plus the mirrored app snapshot (nil
/// before first launch or when the app-group file is unreadable).
///
/// The load-bearing part is the day gate: every rendered value flows through accessors that compare
/// the snapshot's `dateKey` against THIS entry's `date` (via `WidgetDayGate`), so the same snapshot
/// renders as live data in a same-day entry and as a fresh, empty day in the midnight-rollover entry
/// ``FernletCompanionProvider`` appends. Views must read ``bottleCount`` /
/// ``currentDayCompanionState`` — never `snapshot` fields directly — or the rollover gate is lost.
struct FernletCompanionEntry: TimelineEntry {
    /// The moment this entry represents (now, or the next local midnight for the rollover entry).
    let date: Date
    /// The mirrored app-group snapshot this entry renders from; nil → the "Open Fernlet" placeholder.
    let snapshot: WidgetSnapshot?

    /// Whether the mirrored snapshot is for the SAME local day as THIS entry's date. Both the water
    /// count and the companion mood gate on this, so a day-rollover entry (including the midnight
    /// entry the provider appends) reads as a fresh, empty day rather than yesterday's state — with
    /// the app closed, nothing else corrects it until launch.
    private var reflectsCurrentDay: Bool {
        guard let snapshot else { return false }
        return WidgetDayGate.snapshotReflectsDay(snapshot.dateKey, at: date)
    }

    /// Water progress only counts when the mirrored snapshot is for the CURRENT day; after a day
    /// rollover with the app closed, the fresh day starts at zero bottles.
    var bottleCount: Int {
        guard let snapshot, reflectsCurrentDay else { return 0 }
        return snapshot.bottleCount
    }

    var hydrationTarget: Int { max(snapshot?.hydrationTarget ?? 4, 1) }

    /// Day-gated companion mood — the SINGLE source every family reads for the glyph and label. A
    /// stale (previous-day) snapshot yields `nil` (the neutral "Fernlet" treatment) instead of
    /// yesterday's face, keeping mood and water internally consistent across a rollover.
    var currentDayCompanionState: WidgetCompanionState? {
        guard reflectsCurrentDay else { return nil }
        return snapshot?.companionState
    }
}

/// Timeline provider for the companion widget: reads the mirrored app-group snapshot and builds a
/// two-entry timeline (now + the next local midnight) refreshed hourly.
///
/// The midnight entry reuses the SAME snapshot — each entry's own day gate (see
/// ``FernletCompanionEntry``) is what makes it render as a fresh day, so the rollover self-corrects
/// with the app closed and no fetch. The hourly `.after` policy only backstops that; real refreshes
/// are pushed by the app via `WidgetCenter` on every snapshot mirror.
struct FernletCompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> FernletCompanionEntry {
        FernletCompanionEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FernletCompanionEntry) -> Void) {
        let snapshot = WidgetSnapshotStore().read() ?? (context.isPreview ? .placeholder : nil)
        completion(FernletCompanionEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FernletCompanionEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore().read()
        let now = Date()
        var entries = [FernletCompanionEntry(date: now, snapshot: snapshot)]

        // A second entry pinned to the next local midnight, built from the SAME snapshot. Each entry
        // decides what it renders via its own date-vs-dateKey gate (see FernletCompanionEntry), so
        // once the day rolls over this entry shows the neutral mood + zero water WITHOUT WidgetKit
        // having to fetch a fresh timeline first — the mood now self-corrects at midnight exactly as
        // the water count already did. Refreshes are still pushed by the app via WidgetCenter on
        // every snapshot mirror; the hourly policy only backstops day rollover while the app is closed.
        let startOfToday = Calendar.current.startOfDay(for: now)
        if let nextMidnight = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday) {
            entries.append(FernletCompanionEntry(date: nextMidnight, snapshot: snapshot))
        }

        let nextHour = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: entries, policy: .after(nextHour)))
    }
}

/// The companion widget configuration: mood + water at a glance, in systemSmall and the two Lock
/// Screen accessory families.
///
/// A `StaticConfiguration` (no user options) keyed by ``FernletWidgetKind/companion`` and driven by
/// ``FernletCompanionProvider``; ``FernletCompanionWidgetView`` picks the per-family layout.
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

/// The widget target's local color palette (9b cream card, ink text, moss button, per-mood fills),
/// translated from Docs/design-refs/widget.html.
///
/// Widget-target-internal (not private) so the workout and cooking Live Activities can reuse the
/// same colours without re-declaring the literals — see WorkoutLiveActivity.swift. The widget can't
/// use the app's `Color.*` extension, hence the duplication.
enum FernletWidgetPalette {
    // Card + text (9b)
    static let card = Color(red: 0.984, green: 0.969, blue: 0.933)     // #FBF7EE
    static let ink = Color(red: 0.239, green: 0.180, blue: 0.118)      // #3D2E1E
    static let inkSoft = Color(red: 0.541, green: 0.478, blue: 0.384)  // #8A7A62
    static let waterAccent = Color(red: 0.369, green: 0.486, blue: 0.549) // #5E7C8C
    static let waterTrack = Color(red: 0.369, green: 0.486, blue: 0.549).opacity(0.18)
    static let buttonFill = Color(red: 0.353, green: 0.478, blue: 0.322) // #5A7A52 deep moss
    static let buttonInk = Color(red: 0.961, green: 0.937, blue: 0.878)  // #F5EFE0
    static let dashed = Color(red: 0.776, green: 0.718, blue: 0.604)   // #C6B79A
    /// Brighter fern (the "thriving" mood colour) — reads on the Dynamic Island's always-black
    /// background where the deep-brown `ink` would vanish.
    static let leaf = Color(red: 0.420, green: 0.620, blue: 0.384)     // #6B9E62

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

/// The companion's mood glyph (9a): a filled blob whose face is negative space, punched out with
/// `.destinationOut` in a Canvas layer.
///
/// Because the mood is told by the punched-out EXPRESSION rather than the fill color, the glyph
/// survives the Lock Screen's monochrome/tinted rendering — accessory families pass `.white` and let
/// the system tint it. `nil` state draws the neutral (thriving-faced) blob. Shared by every widget
/// family in this file.
private struct CompanionGlyph: View {
    /// The mood to draw; `nil` renders the neutral face (used pre-first-launch and after a day gate).
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
    ///
    /// One small function per mood (R4) over a shared ``FaceEraser``; every coordinate is unchanged,
    /// so the rendered glyphs are identical to the SVG masks they were ported from.
    private static func eraseFace(for state: WidgetCompanionState?, in ctx: GraphicsContext) {
        var eyeCtx = ctx
        eyeCtx.blendMode = .destinationOut
        let eraser = FaceEraser(ctx: eyeCtx)

        switch state {
        case .thriving, nil: eraseThrivingFace(eraser)
        case .okay:          eraseOkayFace(eraser)
        case .tired:         eraseTiredFace(eraser)
        case .resting:       eraseRestingFace(eraser)
        case .sick:          eraseSickFace(eraser)
        }
    }

    private static func eraseThrivingFace(_ e: FaceEraser) {
        e.dot(37, 45, 5.5)
        e.dot(63, 45, 5.5)
        e.stroke({ p in
            p.move(to: CGPoint(x: 33, y: 55))
            p.addQuadCurve(to: CGPoint(x: 67, y: 55), control: CGPoint(x: 50, y: 75))
        }, width: 6.5)
    }

    private static func eraseOkayFace(_ e: FaceEraser) {
        e.dot(37, 48, 5.5)
        e.dot(63, 48, 5.5)
        e.stroke({ p in
            p.move(to: CGPoint(x: 41, y: 61))
            p.addQuadCurve(to: CGPoint(x: 59, y: 61), control: CGPoint(x: 50, y: 68))
        }, width: 5.5)
    }

    private static func eraseTiredFace(_ e: FaceEraser) {
        e.stroke({ p in                       // sleepy slanted lines
            p.move(to: CGPoint(x: 31, y: 47)); p.addLine(to: CGPoint(x: 44, y: 50))
        }, width: 5.5)
        e.stroke({ p in
            p.move(to: CGPoint(x: 69, y: 47)); p.addLine(to: CGPoint(x: 56, y: 50))
        }, width: 5.5)
        e.stroke({ p in                       // flat mouth
            p.move(to: CGPoint(x: 42, y: 63)); p.addLine(to: CGPoint(x: 58, y: 63))
        }, width: 5)
    }

    private static func eraseRestingFace(_ e: FaceEraser) {
        e.stroke({ p in                       // closed-arc eyes
            p.move(to: CGPoint(x: 31, y: 50))
            p.addQuadCurve(to: CGPoint(x: 44, y: 50), control: CGPoint(x: 37.5, y: 56))
        }, width: 5)
        e.stroke({ p in
            p.move(to: CGPoint(x: 56, y: 50))
            p.addQuadCurve(to: CGPoint(x: 69, y: 50), control: CGPoint(x: 62.5, y: 56))
        }, width: 5)
        e.stroke({ p in                       // tiny mouth
            p.move(to: CGPoint(x: 44, y: 62))
            p.addQuadCurve(to: CGPoint(x: 56, y: 62), control: CGPoint(x: 50, y: 66))
        }, width: 4.5)
        e.stroke({ p in                       // the "z"
            p.move(to: CGPoint(x: 70, y: 20))
            p.addLine(to: CGPoint(x: 80, y: 20))
            p.addLine(to: CGPoint(x: 70, y: 31))
            p.addLine(to: CGPoint(x: 80, y: 31))
        }, width: 3.4)
    }

    private static func eraseSickFace(_ e: FaceEraser) {
        e.stroke({ p in                       // queasy x-ish eyes (chevrons)
            p.move(to: CGPoint(x: 32, y: 44))
            p.addLine(to: CGPoint(x: 40, y: 48))
            p.addLine(to: CGPoint(x: 32, y: 52))
        }, width: 4.5)
        e.stroke({ p in
            p.move(to: CGPoint(x: 68, y: 44))
            p.addLine(to: CGPoint(x: 60, y: 48))
            p.addLine(to: CGPoint(x: 68, y: 52))
        }, width: 4.5)
        e.stroke({ p in                       // wavy mouth
            p.move(to: CGPoint(x: 38, y: 63))
            p.addQuadCurve(to: CGPoint(x: 46, y: 63), control: CGPoint(x: 42, y: 58))
            p.addQuadCurve(to: CGPoint(x: 54, y: 63), control: CGPoint(x: 50, y: 68))
            p.addQuadCurve(to: CGPoint(x: 62, y: 63), control: CGPoint(x: 58, y: 58))
        }, width: 4)
    }
}

/// The two drawing primitives every mood's face is made of, over a `.destinationOut` context.
///
/// Holds the already-blend-mode-set context plus the opaque shading whose only job is to erase, so
/// each `erase<Mood>Face` function is nothing but coordinates.
private struct FaceEraser {
    /// The erasing context — the caller sets `blendMode = .destinationOut` before handing it over.
    let ctx: GraphicsContext
    /// Any opaque colour; the blend mode is what turns a draw into an erase.
    private let shade = GraphicsContext.Shading.color(.black)

    /// Punches a filled circle of radius `r` centred at (`cx`, `cy`) — the dot eyes.
    func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)), with: shade)
    }

    /// Punches a round-capped stroke of the path `build` describes — mouths, lids, and the "z".
    func stroke(_ build: (inout Path) -> Void, width: CGFloat) {
        guard width > 0 else { return }        // a non-positive line width erases nothing
        var p = Path()
        build(&p)
        ctx.stroke(p, with: shade,
                   style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Water progress ring (9b/9c): a thick track + progress arc with a water-drop glyph inside

/// The water progress ring (9b/9c): a thick track, a progress arc clamped at 100%, and a small
/// water-drop glyph in the center.
///
/// Rendered on the systemSmall card next to the companion glyph; a `target` of zero degrades to an
/// empty ring rather than dividing by zero.
private struct WaterRing: View {
    /// Bottles logged today (day-gated by the entry before it reaches here).
    let filled: Int
    /// Today's hydration target in bottles.
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
///
/// A resolution-independent `Shape` so ``WaterRing`` can stroke it at any size; it scales uniformly
/// to the smaller of the target rect's dimensions.
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

/// The companion widget's root view: switches on the widget family and applies the two cross-family
/// modifiers (privacy redaction and the container background).
///
/// `.privacySensitive()` is deliberate policy, not decoration — the companion state encodes
/// wellbeing (including sickness), so the whole widget redacts on a locked Lock Screen. Accessory
/// families draw on the Lock Screen's own material (clear background); systemSmall gets the 9b cream
/// card.
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

/// The systemSmall Home Screen layout (9b): companion glyph + water ring on top, "N of M bottles
/// today" + the interactive "+1" button below.
///
/// The "+1" button fires ``WaterPlusOneIntent`` directly from the Home Screen. With no snapshot yet
/// (app never launched / file unreadable) it falls back to ``PlaceholderView``.
private struct SmallCompanionView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        if entry.snapshot != nil {
            VStack(alignment: .leading, spacing: 0) {
                // top row: companion glyph (left) + water ring (right)
                HStack(alignment: .top) {
                    CompanionGlyph(state: entry.currentDayCompanionState,
                                   fill: FernletWidgetPalette.mood(entry.currentDayCompanionState))
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
///
/// Shown by ``SmallCompanionView`` whenever the entry carries no snapshot — the gentle invitation
/// state rather than an error state.
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
///
/// Only used inside ``PlaceholderView``; unlike ``CompanionGlyph`` it never varies by mood, so the
/// cheaper stroke drawing is fine here.
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

/// The Lock Screen circular accessory (9c): just the companion glyph, white-filled so the system's
/// vibrancy tint recolors it.
///
/// No snapshot AND a stale (previous-day) snapshot both resolve to the neutral glyph via the entry's
/// day gate — the shape + negative-space design is what keeps it legible in single-tint rendering.
private struct CircularCompanionView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        // Companion glyph is the primary circular option; the shape+negative-space reads in the
        // single-tint Lock Screen render (white fill, system applies the vibrancy tint). No snapshot
        // AND a stale (previous-day) snapshot both resolve to the neutral glyph via the day gate.
        CompanionGlyph(state: entry.currentDayCompanionState, fill: .white)
            .padding(3)
    }
}

// MARK: - 9c · Lock Screen · rectangular (glyph + "Thriving · 3 of 6 bottles" + 6-segment bar)

/// The Lock Screen rectangular accessory (9c): glyph + "Thriving · 3 of 6 bottles" + the 6-segment
/// water bar.
///
/// The mood label falls back to "Fernlet" when the day gate yields no current-day state; with no
/// snapshot at all it renders the neutral glyph + "Open Fernlet to say hi".
private struct RectangularCompanionView: View {
    let entry: FernletCompanionEntry

    private var moodLabel: String {
        switch entry.currentDayCompanionState {
        case .thriving: return "Thriving"
        case .okay:     return "Okay"
        case .tired:    return "Tired"
        case .resting:  return "Resting"
        case .sick:     return "Sick"
        case nil:       return "Fernlet"
        }
    }

    var body: some View {
        if entry.snapshot != nil {
            HStack(spacing: 10) {
                CompanionGlyph(state: entry.currentDayCompanionState, fill: .white)
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
///
/// Segments filled beyond the cap simply stay filled — the numeric label above it carries the true
/// count, so the bar can safely stay compact.
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

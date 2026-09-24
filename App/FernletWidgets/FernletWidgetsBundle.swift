// FernletWidgetsBundle.swift
// FernletWidgets
//
// v1 companion widget: systemSmall (interactive +1 water) + systemMedium + lock-screen accessories.
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

    /// The companion's emotion at THIS entry's date (owner decision 2026-09-24) — the only place a
    /// family reads it.
    ///
    /// Day-scoped per moment rather than per snapshot (``WidgetEmotionTimeline``): a moment applies
    /// only on its own local day, so a stale snapshot can never draw yesterday's feeling — while the
    /// moments the app computed for the NEW date (the sleepy night carried past midnight, which only
    /// the clock decides) still apply after the rollover, when the state itself has gone neutral.
    var currentCompanionEmotion: WidgetCompanionEmotion? {
        guard let moments = snapshot?.companionEmotionTimeline else { return nil }
        return WidgetEmotionTimeline.emotion(in: moments, at: date)
    }
}

/// Timeline provider for the companion widget: reads the mirrored app-group snapshot and builds a
/// timeline of now, every upcoming emotion transition, and the next local midnight, refreshed hourly.
///
/// Every entry reuses the SAME snapshot — each entry's own day gate and emotion lookup (see
/// ``FernletCompanionEntry``) decide what it renders, so the rollover self-corrects with the app
/// closed and no fetch, and a sleepy companion appears at bedtime or a hungry one at the hunger onset
/// the same way. The hourly `.after` policy only backstops that; real refreshes are pushed by the app
/// via `WidgetCenter` on every snapshot mirror.
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

        // One entry at each upcoming emotion transition (bedtime, the hunger onset, the wake time…),
        // so the face changes on time with the app closed. Bounded, and never at `now` itself.
        let transitions = WidgetEmotionTimeline.transitionDates(in: snapshot?.companionEmotionTimeline ?? [], after: now)
        entries += transitions.map { FernletCompanionEntry(date: $0, snapshot: snapshot) }

        // A second entry pinned to the next local midnight, built from the SAME snapshot. Each entry
        // decides what it renders via its own date-vs-dateKey gate (see FernletCompanionEntry), so
        // once the day rolls over this entry shows the neutral mood + zero water WITHOUT WidgetKit
        // having to fetch a fresh timeline first — the mood now self-corrects at midnight exactly as
        // the water count already did. Refreshes are still pushed by the app via WidgetCenter on
        // every snapshot mirror; the hourly policy only backstops day rollover while the app is closed.
        let startOfToday = Calendar.current.startOfDay(for: now)
        if let nextMidnight = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday),
           !transitions.contains(nextMidnight) {
            entries.append(FernletCompanionEntry(date: nextMidnight, snapshot: snapshot))
        }
        entries.sort { $0.date < $1.date }

        let nextHour = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: entries, policy: .after(nextHour)))
    }
}

/// The companion widget configuration: mood + water at a glance, in systemSmall, systemMedium and
/// the two Lock Screen accessory families.
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
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
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

/// The mood a ``CompanionGlyph`` is speaking, for the families where the glyph is the ONLY place the
/// mood appears (systemSmall and the circular accessory both draw it without a written label).
///
/// The words come from ``WidgetCompanionState/displayName`` and ``WidgetCompanionEmotion`` 's display
/// forks, never from a `rawValue` — those raw strings are the cross-process wire tokens, so speaking
/// one would read the persistence format aloud and would stay English after translation. With an
/// emotion the value reads "Okay, feeling sleepy". A day-gated `nil` state has no mood to report:
/// the glyph is the neutral face (or, after midnight, the clock's sleepy face), so it says so rather
/// than implying yesterday's state still holds.
private func companionMoodValue(_ state: WidgetCompanionState?, _ emotion: WidgetCompanionEmotion? = nil) -> Text {
    guard let state else {
        guard let emotion else { return Text("No mood yet today") }
        return Text(emotion.displayName)
    }
    guard let emotion else { return Text(state.displayName) }
    return Text(String(localized: "companionEmotion.stateAndFeeling",
                       defaultValue: "\(state.displayName), \(emotion.feelingPhrase)",
                       comment: "The companion's spoken status: its state, then its feeling. Example: 'Okay, feeling sleepy'"))
}

/// Which widget families may draw the companion's emotion.
///
/// PRIVACY-FORWARD, OWNER-CONFIRMED (2026-09-24: "State face only"): the Lock Screen accessories
/// draw the STATE face only, and the Home Screen families draw the emotion. A sad or hungry face on the Lock
/// Screen tells anyone who glances at the phone how the day went; the Home Screen is only seen
/// unlocked. The whole widget is `.privacySensitive()` besides, so a locked Lock Screen redacts it.
enum FernletWidgetEmotionPolicy {
    /// Whether the Lock Screen accessory families draw the emotion. `false` = the state face only.
    static let lockScreenShowsEmotion = false
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
/// family in this file. An `emotion` replaces the state's face with the emotion's own (the fill
/// colour still follows the state), exactly as the app's companion draws an emotion over its state.
private struct CompanionGlyph: View {
    /// The mood to draw; `nil` renders the neutral face (used pre-first-launch and after a day gate).
    let state: WidgetCompanionState?
    /// The feeling to draw instead of the state's face; nil draws the state's face.
    var emotion: WidgetCompanionEmotion? = nil
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

                // 2) punch the face out of the body — the emotion's, when there is one
                if let emotion {
                    Self.eraseEmotionFace(for: emotion, in: layer)
                } else {
                    Self.eraseFace(for: state, in: layer)
                }
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

    // MARK: Emotion faces (2026-09-24) — same 100×100 space, same erase-only drawing

    /// Draws one emotion's face with `.destinationOut`: the six widget-publishable feelings.
    ///
    /// *Tired* reuses the tired state's face, so "Tired, feeling tired" is one face, not two. The
    /// small motifs (the moon, the apple, the drop) are punched out inside the blob like the resting
    /// face's "z", so they survive the Lock Screen's single-tint rendering too.
    private static func eraseEmotionFace(for emotion: WidgetCompanionEmotion, in ctx: GraphicsContext) {
        var eyeCtx = ctx
        eyeCtx.blendMode = .destinationOut
        let eraser = FaceEraser(ctx: eyeCtx)

        switch emotion {
        case .happy:   eraseHappyFace(eraser)
        case .sad:     eraseSadFace(eraser)
        case .tired:   eraseTiredFace(eraser)
        case .sleepy:  eraseSleepyFace(eraser)
        case .hungry:  eraseHungryFace(eraser)
        case .thirsty: eraseThirstyFace(eraser)
        }
    }

    private static func eraseHappyFace(_ e: FaceEraser) {
        e.stroke({ p in                       // crescent eyes, bowed up
            p.move(to: CGPoint(x: 30, y: 49))
            p.addQuadCurve(to: CGPoint(x: 44, y: 49), control: CGPoint(x: 37, y: 39))
        }, width: 5)
        e.stroke({ p in
            p.move(to: CGPoint(x: 56, y: 49))
            p.addQuadCurve(to: CGPoint(x: 70, y: 49), control: CGPoint(x: 63, y: 39))
        }, width: 5)
        e.stroke({ p in                       // wide smile
            p.move(to: CGPoint(x: 33, y: 58))
            p.addQuadCurve(to: CGPoint(x: 67, y: 58), control: CGPoint(x: 50, y: 77))
        }, width: 6.5)
    }

    private static func eraseSadFace(_ e: FaceEraser) {
        e.dot(37, 51, 5.2)
        e.dot(63, 51, 5.2)
        e.stroke({ p in                       // brows lifted at the INNER ends: sympathy
            p.move(to: CGPoint(x: 29, y: 41)); p.addLine(to: CGPoint(x: 42, y: 36))
        }, width: 4)
        e.stroke({ p in
            p.move(to: CGPoint(x: 71, y: 41)); p.addLine(to: CGPoint(x: 58, y: 36))
        }, width: 4)
        e.stroke({ p in                       // a small, soft frown
            p.move(to: CGPoint(x: 41, y: 69))
            p.addQuadCurve(to: CGPoint(x: 59, y: 69), control: CGPoint(x: 50, y: 61))
        }, width: 4.5)
    }

    private static func eraseSleepyFace(_ e: FaceEraser) {
        e.stroke({ p in                       // closed lids
            p.move(to: CGPoint(x: 30, y: 50))
            p.addQuadCurve(to: CGPoint(x: 44, y: 50), control: CGPoint(x: 37, y: 56))
        }, width: 5)
        e.stroke({ p in
            p.move(to: CGPoint(x: 56, y: 50))
            p.addQuadCurve(to: CGPoint(x: 70, y: 50), control: CGPoint(x: 63, y: 56))
        }, width: 5)
        e.oval(50, 66, width: 9, height: 11)  // a yawn
        e.stroke({ p in                       // a crescent moon, opening to the upper right
            p.addArc(center: CGPoint(x: 72, y: 28), radius: 8.5,
                     startAngle: .degrees(60), endAngle: .degrees(290), clockwise: false)
        }, width: 4)
    }

    private static func eraseHungryFace(_ e: FaceEraser) {
        e.dot(37, 46, 5.2)                    // eyes raised toward the apple
        e.dot(63, 46, 5.2)
        e.oval(50, 66, width: 12, height: 10) // an open "o"
        e.dot(71, 31, 7)                      // the apple…
        e.stroke({ p in                       // …and its leaf (kept inside the blob's edge)
            p.move(to: CGPoint(x: 72.5, y: 23)); p.addLine(to: CGPoint(x: 76, y: 20))
        }, width: 3)
    }

    private static func eraseThirstyFace(_ e: FaceEraser) {
        e.dot(37, 47, 5.2)
        e.dot(63, 47, 5.2)
        e.oval(50, 65, width: 9, height: 8)   // a small "o"
        e.fill { p in                         // a drop of water, point up
            p.move(to: CGPoint(x: 71, y: 18))
            p.addQuadCurve(to: CGPoint(x: 78, y: 31), control: CGPoint(x: 78, y: 24.5))
            p.addArc(center: CGPoint(x: 71, y: 31), radius: 7,
                     startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            p.addQuadCurve(to: CGPoint(x: 71, y: 18), control: CGPoint(x: 64, y: 24.5))
        }
    }
}

/// The drawing primitives every mood's face is made of, over a `.destinationOut` context.
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

    /// Punches a filled ellipse centred at (`cx`, `cy`) — the open and yawning mouths.
    func oval(_ cx: CGFloat, _ cy: CGFloat, width: CGFloat, height: CGFloat) {
        guard width > 0, height > 0 else { return }
        ctx.fill(Path(ellipseIn: CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)), with: shade)
    }

    /// Punches the filled shape the path `build` describes — the water drop.
    func fill(_ build: (inout Path) -> Void) {
        var p = Path()
        build(&p)
        p.closeSubpath()
        ctx.fill(p, with: shade)
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
        // Three strokes and a teardrop carry the whole hydration reading visually and nothing at all
        // otherwise. Flattened to one element so the arc, track and drop stop being three silent
        // shapes, with the count as the VALUE — a value re-announces when it changes, a label does not.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Water"))
        .accessibilityValue(Text("\(filled) of \(target) bottles"))
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
            case .systemMedium:
                MediumCompanionView(entry: entry)
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
                                   emotion: entry.currentCompanionEmotion,
                                   fill: FernletWidgetPalette.mood(entry.currentDayCompanionState))
                        .frame(width: 52, height: 52)
                        // systemSmall never writes the mood down — the face IS the reading, so this
                        // element is the only place it can be heard.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Fernlet companion"))
                        .accessibilityValue(companionMoodValue(entry.currentDayCompanionState, entry.currentCompanionEmotion))
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
                    // "+1" alone announces as "plus one, button". The intent's own title already says
                    // what the tap does, in every language the catalog carries — borrowing it labels
                    // the control without minting a second string that could drift from it.
                    .accessibilityLabel(Text(WaterPlusOneIntent.title))
                    .background(FernletWidgetPalette.buttonFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
        } else {
            PlaceholderView()
        }
    }
}

/// The systemMedium Home Screen layout (2026-09-24): a larger companion glyph with its state and
/// feeling written beside it, the water count, and the water ring over the interactive "+1".
///
/// The one family with room to WRITE the feeling, so the glyph itself is hidden from VoiceOver and
/// the two words beside it carry the reading. With no snapshot it falls back to ``PlaceholderView``.
private struct MediumCompanionView: View {
    let entry: FernletCompanionEntry

    /// The state's written name, or the companion's own name when the day has no state yet.
    private var stateLabel: String {
        entry.currentDayCompanionState?.displayName ?? String(localized: "Fernlet")
    }

    var body: some View {
        if entry.snapshot != nil {
            HStack(alignment: .center, spacing: 14) {
                CompanionGlyph(state: entry.currentDayCompanionState,
                               emotion: entry.currentCompanionEmotion,
                               fill: FernletWidgetPalette.mood(entry.currentDayCompanionState))
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)      // the words beside it say the same thing
                VStack(alignment: .leading, spacing: 3) {
                    Text(stateLabel)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(FernletWidgetPalette.ink)
                    if let emotion = entry.currentCompanionEmotion {
                        Text(emotion.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(FernletWidgetPalette.inkSoft)
                    }
                    Spacer(minLength: 6)
                    Text("\(entry.bottleCount) of \(entry.hydrationTarget) bottles today")
                        .font(.system(size: 13))
                        .foregroundStyle(FernletWidgetPalette.inkSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                VStack(spacing: 10) {
                    WaterRing(filled: entry.bottleCount, target: entry.hydrationTarget, lineWidth: 6)
                        .frame(width: 52, height: 52)
                    Button(intent: WaterPlusOneIntent()) {
                        Text("+1")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(FernletWidgetPalette.buttonInk)
                            .frame(width: 44, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(WaterPlusOneIntent.title))
                    .background(FernletWidgetPalette.buttonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                // There is no companion yet, so the dashed blob illustrates the invitation below
                // rather than reporting anything — an empty element in front of the real message.
                .accessibilityHidden(true)
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
        CompanionGlyph(state: entry.currentDayCompanionState, emotion: lockScreenEmotion, fill: .white)
            .padding(3)
            // The whole accessory is one Canvas, which is an accessibility element with no content —
            // it reads as an unlabelled blank on the Lock Screen. The face is the only reading this
            // family offers, so it has to be spoken here or not at all.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Fernlet companion"))
            .accessibilityValue(companionMoodValue(entry.currentDayCompanionState, lockScreenEmotion))
    }

    /// The emotion this Lock Screen family may draw — none under the privacy-forward default
    /// (``FernletWidgetEmotionPolicy``).
    private var lockScreenEmotion: WidgetCompanionEmotion? {
        FernletWidgetEmotionPolicy.lockScreenShowsEmotion ? entry.currentCompanionEmotion : nil
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

    /// The written mood word, from the localized display fork.
    ///
    /// This used to switch over the state and return English literals, which no catalog could ever
    /// see. It must not switch over `rawValue` either — that string is the cross-process wire token
    /// (see ``WidgetCompanionState/displayName``). With no current-day state there is no mood to
    /// name, so the companion's own name stands in, exactly as the glyph falls back to a neutral face.
    private var moodLabel: String {
        entry.currentDayCompanionState?.displayName ?? String(localized: "Fernlet")
    }

    /// The emotion this Lock Screen family may draw — none under the privacy-forward default
    /// (``FernletWidgetEmotionPolicy``). The written label stays the state either way: the Lock
    /// Screen never spells a feeling out.
    private var lockScreenEmotion: WidgetCompanionEmotion? {
        FernletWidgetEmotionPolicy.lockScreenShowsEmotion ? entry.currentCompanionEmotion : nil
    }

    var body: some View {
        if entry.snapshot != nil {
            HStack(spacing: 10) {
                CompanionGlyph(state: entry.currentDayCompanionState, emotion: lockScreenEmotion, fill: .white)
                    .frame(width: 34, height: 34)
                    // Unlike the other two families this one WRITES the mood beside the face, so
                    // labelling the Canvas would say it twice; hiding it drops the empty element.
                    .accessibilityHidden(true)
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
                    .accessibilityHidden(true)     // decorative: the invitation beside it is the message
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

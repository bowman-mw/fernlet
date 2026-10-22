// WidgetCompanionFigure.swift
// FernletWidgets
//
// The simplified companion every widget family draws (owner decision 2026-10-21): the person's own
// body shape, body colour and topper, still (no breathing), with the face punched out of the body
// so it reads in the Home Screen's tinted and clear modes and on the Lock Screen. Clothing, the
// side item and user-designed items are left out on purpose: at widget size they are a few pixels
// and would crowd the cut-out face.

import SwiftUI
import WidgetKit

/// The four body silhouettes, mirrored from the app's `CompanionBlobShape` with the breath held
/// still. Points are in a unit square; ``path(in:)`` scales them to the body's rect.
enum WidgetCompanionBody: String {
    case circle
    case softBlob
    case pear
    case puddle

    /// The body for a frozen token; an unknown one draws the round body.
    init(token: String) {
        self = WidgetCompanionBody(rawValue: token) ?? .circle
    }

    /// The silhouette in `rect`. `slump` lowers the top a little on a low-energy band, as the app
    /// does; the circle has no top to lower.
    func path(in rect: CGRect, slump: CGFloat) -> Path {
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        var path = Path()
        switch self {
        case .circle:
            path.addEllipse(in: rect)
        case .softBlob:
            path.move(to: p(0.50, 0.04 + slump))
            path.addCurve(to: p(0.94, 0.35), control1: p(0.76, 0.02), control2: p(0.96, 0.15))
            path.addCurve(to: p(0.77, 0.91), control1: p(0.94, 0.62), control2: p(0.96, 0.83))
            path.addCurve(to: p(0.22, 0.88), control1: p(0.58, 1.00), control2: p(0.34, 0.98))
            path.addCurve(to: p(0.07, 0.34), control1: p(0.03, 0.73), control2: p(0.01, 0.48))
            path.addCurve(to: p(0.50, 0.04 + slump), control1: p(0.14, 0.14), control2: p(0.26, 0.04))
        case .pear:
            path.move(to: p(0.50, 0.02 + slump))
            path.addCurve(to: p(0.78, 0.34), control1: p(0.68, 0.02 + slump), control2: p(0.80, 0.16 + slump))
            path.addCurve(to: p(0.88, 0.72), control1: p(0.80, 0.48), control2: p(0.91, 0.55))
            path.addCurve(to: p(0.69, 0.93), control1: p(0.85, 0.86), control2: p(0.79, 0.92))
            path.addCurve(to: p(0.31, 0.93), control1: p(0.57, 0.97), control2: p(0.43, 0.97))
            path.addCurve(to: p(0.12, 0.72), control1: p(0.21, 0.92), control2: p(0.15, 0.86))
            path.addCurve(to: p(0.22, 0.34), control1: p(0.09, 0.55), control2: p(0.20, 0.48))
            path.addCurve(to: p(0.50, 0.02 + slump), control1: p(0.20, 0.16 + slump), control2: p(0.32, 0.02 + slump))
        case .puddle:
            path.move(to: p(0.48, 0.13 + slump))
            path.addCurve(to: p(0.93, 0.43), control1: p(0.74, 0.08), control2: p(0.94, 0.20))
            path.addCurve(to: p(0.84, 0.78), control1: p(0.94, 0.58), control2: p(0.98, 0.71))
            path.addCurve(to: p(0.24, 0.87), control1: p(0.64, 0.95), control2: p(0.38, 0.93))
            path.addCurve(to: p(0.06, 0.48), control1: p(0.06, 0.80), control2: p(0.00, 0.63))
            path.addCurve(to: p(0.48, 0.13 + slump), control1: p(0.09, 0.28), control2: p(0.24, 0.13))
        }
        path.closeSubpath()
        return path
    }
}

/// The topper drawn above (or, for glasses, on) the body: the app's `CompanionAccessory` tokens.
enum WidgetCompanionTopper: String {
    case none
    case sprout
    case flower
    case glasses

    /// The topper for a frozen token; an unknown one draws none.
    init(token: String) {
        self = WidgetCompanionTopper(rawValue: token) ?? .none
    }

    /// Whether the companion is wearing this topper right now. Glasses come off when it is tired,
    /// sick, sleepy or asleep, and stay on when it is resting (owner decision 2026-10-21) — the twin
    /// of the app's `CompanionAccessory.isWorn(state:emotion:)`.
    func isWorn(state: WidgetCompanionState?, emotion: WidgetCompanionEmotion?) -> Bool {
        guard self == .glasses else { return self != .none }
        if emotion == .sleepy || emotion == .asleep { return false }
        if state == .tired || state == .sick { return false }
        return !(emotion == .tired && state != .resting)
    }
}

/// The simplified companion every widget family draws: the person's body shape in its colour, the
/// topper, and the face cut out of the body.
///
/// One `Canvas` in a 100-point design space: the body fills ``bodyRect``, which leaves the band
/// above it for a sprout or flower and the top-right corner for the asleep "z". `monochrome` draws
/// everything white and cuts the glasses and the flower's centre out too — for the Lock Screen and
/// the Home Screen's tinted and clear modes, where the system recolours one tint and only the holes
/// can carry the expression. The whole drawing is one accessibility-silent element; each family
/// labels or hides it.
struct CompanionFigure: View {
    /// The person's look; ``WidgetCompanionLook/standard`` until the app publishes one.
    let look: WidgetCompanionLook
    /// The day-gated state; nil draws the neutral face.
    let state: WidgetCompanionState?
    /// The feeling to draw over the state; nil draws the state's face.
    let emotion: WidgetCompanionEmotion?
    /// One white tint with every feature cut out, for the system to recolour.
    var monochrome: Bool = false

    /// Where the body sits in the 100-point design space.
    static let bodyRect = CGRect(x: 12, y: 24, width: 76, height: 76)

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 100 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.drawLayer { layer in
                drawFigure(in: layer)
            }
        }
        // Let the Lock Screen and the tinted Home Screen recolour the drawing as one.
        .widgetAccentable()
    }

    /// Topper behind, body, cut-out face, then whatever sits on top (glasses, the flower's centre)
    /// and the feeling's small motif beside the body.
    private func drawFigure(in layer: GraphicsContext) {
        let topper = WidgetCompanionTopper(token: look.accessoryRaw)
        let worn = topper.isWorn(state: state, emotion: emotion)
        let bodyUnits = Self.bodyUnitContext(layer)
        if worn { WidgetTopperArt.drawBehind(topper, in: bodyUnits, color: topperColor) }
        let shape = WidgetCompanionBody(token: look.bodyStyleRaw)
        layer.fill(shape.path(in: Self.bodyRect, slump: slump), with: .color(bodyColor))
        WidgetCompanionFaces.erase(state: state, emotion: emotion, in: Self.faceContext(layer))
        if worn {
            WidgetTopperArt.drawInFront(topper, in: bodyUnits, monochrome: monochrome)
        }
        if let emotion {
            WidgetMotifArt.draw(emotion, in: layer, color: bodyColor, onLeft: worn && topper == .flower)
        }
    }

    /// A context whose units are percent of the body: (0, 0) is the body's top-left, 100 its width.
    private static func bodyUnitContext(_ layer: GraphicsContext) -> GraphicsContext {
        var ctx = layer
        ctx.translateBy(x: bodyRect.minX, y: bodyRect.minY)
        ctx.scaleBy(x: bodyRect.width / 100, y: bodyRect.height / 100)
        return ctx
    }

    /// A context in the faces' authoring space — the 100×100 masks whose body was the circle in
    /// (8, 10, 84, 84) — mapped onto ``bodyRect``, so every face coordinate stays as it was ported.
    private static func faceContext(_ layer: GraphicsContext) -> GraphicsContext {
        var ctx = layer
        ctx.translateBy(x: bodyRect.minX, y: bodyRect.minY)
        ctx.scaleBy(x: bodyRect.width / 84, y: bodyRect.height / 84)
        ctx.translateBy(x: -8, y: -10)
        return ctx
    }

    /// The low-energy bands sit a little lower at the top, as in the app — unless the feeling hides
    /// the day, when the posture must say nothing about it.
    private var slump: CGFloat {
        guard emotion?.hidesTheDay != true else { return 0 }
        return state == .tired || state == .resting || state == .sick ? 0.04 : 0
    }

    /// The body: white when monochrome, the person's fixed colour, else the state's (the night
    /// colour while the feeling hides the day).
    private var bodyColor: Color {
        if monochrome { return .white }
        if let hex = look.bodyColorHex, let color = Color(widgetHex: hex) { return color }
        return FernletWidgetPalette.body(state, emotion)
    }

    /// The topper, resolved the same way as the body.
    private var topperColor: Color {
        if monochrome { return .white }
        if let hex = look.accessoryColorHex, let color = Color(widgetHex: hex) { return color }
        return FernletWidgetPalette.body(state, emotion)
    }
}

/// The topper drawn around the body, in body units (percent of the body).
///
/// Simplified from the app's `CompanionAccessoryView`: the sprout and the flower sit a little higher
/// than in the app so they stay clear of the body in a single tint, and the glasses are cut out of
/// the body when monochrome rather than drawn over it.
enum WidgetTopperArt {
    /// The parts behind the body: the sprout's stem and leaves, or the flower's petals.
    static func drawBehind(_ topper: WidgetCompanionTopper, in ctx: GraphicsContext, color: Color) {
        let shading = GraphicsContext.Shading.color(color)
        switch topper {
        case .sprout:
            ctx.fill(Path(roundedRect: CGRect(x: 48.25, y: -22, width: 3.5, height: 24), cornerRadius: 1.75), with: shading)
            ctx.fill(leaf(center: CGPoint(x: 41.75, y: -8), degrees: -26), with: shading)
            ctx.fill(leaf(center: CGPoint(x: 58.25, y: -8), degrees: 26), with: shading)
        case .flower:
            for index in 0..<5 {
                ctx.fill(petal(index), with: shading)
            }
        case .glasses, .none:
            return
        }
    }

    /// The parts in front of the body: the glasses (drawn, or cut out when monochrome) and the
    /// flower's centre.
    static func drawInFront(_ topper: WidgetCompanionTopper, in ctx: GraphicsContext, monochrome: Bool) {
        switch topper {
        case .glasses:
            var cut = ctx
            if monochrome { cut.blendMode = .destinationOut }
            let ink = GraphicsContext.Shading.color(monochrome ? .black : FernletWidgetPalette.ink.opacity(0.8))
            cut.stroke(glasses, with: ink, style: StrokeStyle(lineWidth: monochrome ? 3.4 : 2.8, lineCap: .round))
        case .flower:
            var center = ctx
            if monochrome { center.blendMode = .destinationOut }
            center.fill(Path(ellipseIn: CGRect(x: 68, y: -8, width: 8, height: 8)),
                        with: .color(monochrome ? .black : FernletWidgetPalette.card))
        case .sprout, .none:
            return
        }
    }

    /// One sprout leaf: an ellipse turned by `degrees` about its centre.
    private static func leaf(center: CGPoint, degrees: Double) -> Path {
        let oval = Path(ellipseIn: CGRect(x: -9, y: -4.5, width: 18, height: 9))
        let turn = CGAffineTransform(rotationAngle: CGFloat(degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return oval.applying(turn)
    }

    /// One of the flower's five petals around its centre at (72, -4).
    private static func petal(_ index: Int) -> Path {
        let angle = CGFloat(index) * 72 * .pi / 180
        let oval = Path(ellipseIn: CGRect(x: -4, y: -8, width: 8, height: 16))
        let place = CGAffineTransform(rotationAngle: angle)
            .concatenating(CGAffineTransform(translationX: 72 + 8 * sin(angle), y: -4 - 8 * cos(angle)))
        return oval.applying(place)
    }

    /// The two lenses and the bridge, over the eyes.
    private static var glasses: Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 24.5, y: 33, width: 20, height: 20))
        path.addEllipse(in: CGRect(x: 55.5, y: 33, width: 20, height: 20))
        path.move(to: CGPoint(x: 44.5, y: 43))
        path.addLine(to: CGPoint(x: 55.5, y: 43))
        return path
    }
}

/// The small motif a feeling adds beside the body: the sleepy moon, the asleep "z", the hungry
/// apple, the thirsty drop.
///
/// Drawn, not cut, in the design space's top corner — above the body's rect, so it never overlaps
/// any body shape (cut into a pear's or a blob's shoulder it read as a bite out of the body). In the
/// body's own colour, so a single tint keeps it. The corner is the top-right, or the top-left when a
/// flower is worn there.
enum WidgetMotifArt {
    /// Draws the motif for `emotion`, if it has one.
    static func draw(_ emotion: WidgetCompanionEmotion, in layer: GraphicsContext, color: Color, onLeft: Bool) {
        var ctx = layer
        if onLeft {
            // Slide the top-right corner to the top-left — slid, not mirrored, so a "z" still reads.
            ctx.translateBy(x: -72, y: 0)
        }
        let shading = GraphicsContext.Shading.color(color)
        switch emotion {
        case .asleep: ctx.stroke(z, with: shading, style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
        case .sleepy: ctx.fill(moon, with: shading)
        case .hungry:
            ctx.fill(Path(ellipseIn: CGRect(x: 80, y: 8, width: 12, height: 12)), with: shading)
            ctx.stroke(leafStem, with: shading, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        case .thirsty: ctx.fill(drop, with: shading)
        case .happy, .sad, .tired: return
        }
    }

    /// A "z" in the corner.
    private static var z: Path {
        var path = Path()
        path.move(to: CGPoint(x: 80, y: 6))
        path.addLine(to: CGPoint(x: 91, y: 6))
        path.addLine(to: CGPoint(x: 80, y: 17))
        path.addLine(to: CGPoint(x: 91, y: 17))
        return path
    }

    /// A crescent: a disc with an offset disc taken out of its upper right, as in the app's moon.
    private static var moon: Path {
        let disc = Path(ellipseIn: CGRect(x: 79, y: 5, width: 14, height: 14))
        let bite = Path(ellipseIn: CGRect(x: 83.5, y: 1.5, width: 13, height: 13))
        return disc.subtracting(bite)
    }

    /// The apple's stem and leaf.
    private static var leafStem: Path {
        var path = Path()
        path.move(to: CGPoint(x: 86, y: 8))
        path.addLine(to: CGPoint(x: 89, y: 4))
        return path
    }

    /// A drop of water, point up.
    private static var drop: Path {
        var path = Path()
        path.move(to: CGPoint(x: 86, y: 4))
        path.addQuadCurve(to: CGPoint(x: 92, y: 15), control: CGPoint(x: 92, y: 9.5))
        path.addArc(center: CGPoint(x: 86, y: 15), radius: 6, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addQuadCurve(to: CGPoint(x: 86, y: 4), control: CGPoint(x: 80, y: 9.5))
        path.closeSubpath()
        return path
    }
}

extension Color {
    /// A colour from a `#RRGGBB` string, or nil for anything else — the look's fixed colours.
    init?(widgetHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// Every face the widget companion can wear, punched out of the body with `.destinationOut`.
///
/// Authored in the 100×100 space of the original SVG masks (body = the circle in (8, 10, 84, 84));
/// ``CompanionFigure`` maps that space onto whichever body shape the person chose. An emotion's face
/// replaces the state's, exactly as the app's companion draws a feeling over its state. One small
/// function per face (R4) over a shared ``FaceEraser``, so each is nothing but coordinates.
enum WidgetCompanionFaces {
    /// Punches the emotion's face when there is one, else the state's.
    static func erase(state: WidgetCompanionState?, emotion: WidgetCompanionEmotion?, in ctx: GraphicsContext) {
        if let emotion {
            eraseEmotionFace(for: emotion, in: ctx)
        } else {
            eraseFace(for: state, in: ctx)
        }
    }

    /// The state's own face; a day with no state yet wears the thriving face.
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

    /// Resting: relaxed half-lids and a small mouth. It used to have closed eyes and a "z", which is
    /// now the asleep face's (2026-10-21) — a resting day is taking it easy, not asleep.
    private static func eraseRestingFace(_ e: FaceEraser) {
        e.fill { p in                         // lower half of each eye, under a flat lid
            p.move(to: CGPoint(x: 31, y: 48))
            p.addLine(to: CGPoint(x: 44, y: 48))
            p.addArc(center: CGPoint(x: 37.5, y: 48), radius: 6.5,
                     startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        }
        e.fill { p in
            p.move(to: CGPoint(x: 56, y: 48))
            p.addLine(to: CGPoint(x: 69, y: 48))
            p.addArc(center: CGPoint(x: 62.5, y: 48), radius: 6.5,
                     startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        }
        e.stroke({ p in                       // a small, even mouth
            p.move(to: CGPoint(x: 45, y: 63)); p.addLine(to: CGPoint(x: 55, y: 63))
        }, width: 4)
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
        case .asleep:  eraseAsleepFace(eraser)
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
        e.oval(50, 66, width: 9, height: 11)  // a yawn (the moon floats beside the body: WidgetMotifArt)
    }

    private static func eraseAsleepFace(_ e: FaceEraser) {
        e.stroke({ p in                       // closed lids, curving down
            p.move(to: CGPoint(x: 30, y: 51))
            p.addQuadCurve(to: CGPoint(x: 44, y: 51), control: CGPoint(x: 37, y: 57))
        }, width: 5)
        e.stroke({ p in
            p.move(to: CGPoint(x: 56, y: 51))
            p.addQuadCurve(to: CGPoint(x: 70, y: 51), control: CGPoint(x: 63, y: 57))
        }, width: 5)
        e.stroke({ p in                       // a small, soft sleeping mouth
            p.move(to: CGPoint(x: 45, y: 64))
            p.addQuadCurve(to: CGPoint(x: 55, y: 64), control: CGPoint(x: 50, y: 67))
        }, width: 4)
    }

    private static func eraseHungryFace(_ e: FaceEraser) {
        e.dot(37, 46, 5.2)                    // eyes raised toward the apple beside the body
        e.dot(63, 46, 5.2)
        e.oval(50, 66, width: 12, height: 10) // an open "o"
    }

    private static func eraseThirstyFace(_ e: FaceEraser) {
        e.dot(37, 47, 5.2)
        e.dot(63, 47, 5.2)
        e.oval(50, 65, width: 9, height: 8)   // a small "o" (the drop floats beside the body)
    }
}

/// The drawing primitives every mood's face is made of, over a `.destinationOut` context.
///
/// Holds the already-blend-mode-set context plus the opaque shading whose only job is to erase, so
/// each `erase<Mood>Face` function is nothing but coordinates.
struct FaceEraser {
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

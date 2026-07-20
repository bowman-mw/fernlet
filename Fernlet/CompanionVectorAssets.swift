import SwiftUI
import FernletDomainModel
import FernletUI

struct CompanionView: View {
    var state: CompanionState
    var appearance: CompanionAppearance = .standard
    var size: CGFloat
    var interactionLevel: Int = 0
    /// User-designed items currently equipped (one per occupied slot). Drawn as the topmost layer so
    /// they always read clearly over the base avatar.
    var equippedItems: [CustomizationItem] = []
    /// Presentation-only "a little frazzled" accent (opt-in body signals, state >= tense):
    /// a sliding sweat bead, faint rising steam, a soft brow furrow, and a slightly quicker
    /// breath. DELIBERATELY not a `CompanionState` case — new raw values in the persisted
    /// `DailyHealthScore.companionState` would fail decode on older builds, so frazzled stays
    /// a render flag that is never persisted. It stays warm-neutral (no red, shake, or flash),
    /// and is ignored for the low-energy states (sick/resting/tired keep their own posture).
    var stressTint: Bool = false
    /// Presentation-only "calm / settled" accent (opt-in body signals read `.calm`): eyes soften
    /// to happy arcs, a warm blush, a slower breath, and two drifting motes. A gentle positive
    /// counterpart to `stressTint` — also a pure render flag, never persisted, and suppressed
    /// for the low-energy states. `stressTint` wins if both are somehow set.
    var calmTint: Bool = false
    /// Presentation-only "settled" pet-cooldown pose: a droopy-happy slump (wider than tall),
    /// happy-arc eyes, a wide soft smile, a warm blush, and a drifting "z". Driven from the
    /// pet-interaction cooldown window — not a mood, never persisted.
    var settled: Bool = false

    private var showsStressAccent: Bool {
        stressTint && !state.isLowEnergy && !settled
    }

    private var showsCalmAccent: Bool {
        calmTint && !stressTint && !state.isLowEnergy && !settled
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            // Breath tempo: the tense accent quickens the swell (~3s), the calm accent and the
            // settled pose slow it into a longer, softer cycle (~6.6s). The sine period is 2·tempo.
            let tempo: Double = if showsStressAccent {
                state.animationTempo * 0.8
            } else if settled || showsCalmAccent {
                max(state.animationTempo, 3.3)
            } else {
                state.animationTempo
            }
            let breath = (sin(elapsed * .pi / tempo) + 1) / 2
            let petBounce = interactionLevel.isMultiple(of: 2) ? 0.0 : -size * 0.060
            let bodyColor = appearance.resolvedBodyColor(for: state)

            ZStack {
                if appearance.sideItem != .none {
                    CompanionSideItemView(
                        item: appearance.sideItem,
                        color: appearance.resolvedSideItemColor(for: state),
                        size: size
                    )
                    .offset(x: size * 0.58, y: size * 0.28)
                }

                CompanionBlobShape(style: appearance.bodyStyle, state: state, breath: breath)
                    .fill(bodyColor)
                    .frame(width: size, height: size)
                    // Settled reads as a low relaxed slump — a touch wider than tall.
                    .scaleEffect(
                        x: (settled ? 1.06 : 1) + breath * state.horizontalBreath,
                        y: (settled ? 0.94 : 1) + breath * state.verticalBreath
                    )
                    .offset(y: settled ? size * 0.05 : (state == .resting ? size * 0.04 : petBounce))
                    .shadow(color: bodyColor.opacity(0.20), radius: size * 0.08, x: 0, y: size * 0.04)

                Ellipse()
                    .fill(.white.opacity(0.16))
                    .frame(width: size * 0.34, height: size * 0.22)
                    .offset(x: -size * 0.12, y: -size * 0.20 + petBounce)

                CompanionAccessoryView(
                    accessory: appearance.accessory,
                    color: appearance.resolvedAccessoryColor(for: state),
                    size: size
                )
                .offset(y: petBounce)

                CompanionClothingView(
                    clothing: appearance.clothing,
                    color: appearance.resolvedClothingColor(for: state),
                    size: size
                )
                .offset(y: petBounce)

                let showsHappyArcEyes = settled || showsCalmAccent
                let facePetBounce = settled ? size * 0.05 : petBounce

                if settled || showsCalmAccent {
                    // Warm blush cheeks that ride with the settled/calm face. Settled sits deeper in
                    // the content beat, so its blush is a touch wider and warmer than the calm accent's.
                    let blushOpacity = settled ? 0.42 : 0.38
                    let blushWidth = settled ? size * 0.15 : size * 0.135
                    HStack(spacing: size * 0.17) {
                        Ellipse()
                            .fill(Color.dustyRose.opacity(blushOpacity))
                            .frame(width: blushWidth, height: size * 0.072)
                        Ellipse()
                            .fill(Color.dustyRose.opacity(blushOpacity))
                            .frame(width: blushWidth, height: size * 0.072)
                    }
                    .offset(y: size * 0.02 + facePetBounce)
                }

                HStack(spacing: size * 0.18) {
                    EyeView(tired: state.isLowEnergy, happyArc: showsHappyArcEyes, size: size)
                    EyeView(tired: state.isLowEnergy, happyArc: showsHappyArcEyes, size: size)
                }
                .offset(y: -size * 0.08 + facePetBounce)

                if settled {
                    // A wide soft smile completes the droopy-happy "completely content" read.
                    CompanionSettledMouth()
                        .fill(.white.opacity(0.78))
                        .frame(width: size * 0.30, height: size * 0.15)
                        .offset(y: size * 0.14 + facePetBounce)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(0.72))
                        .frame(width: size * 0.18, height: state.mouthHeight(for: size))
                        .offset(y: size * 0.14 + facePetBounce)
                }

                ForEach(equippedItems) { item in
                    CompanionCustomItemLayer(item: item, size: size)
                        .offset(y: petBounce)
                        .zIndex(Self.itemPaintOrder(item.slot))
                }

                if showsStressAccent {
                    // Frazzled / tense: a soft brow furrow, faint rising steam, and one cool
                    // sweat bead that slides down and fades. Warm-neutral, never alarming.
                    CompanionBrowFurrow(size: size)
                        .offset(y: -size * 0.20 + petBounce)
                        .zIndex(5)
                        .transition(.opacity)

                    CompanionSteam(size: size, elapsed: elapsed)
                        .offset(x: -size * 0.02, y: -size * 0.52 + petBounce)
                        .zIndex(5)
                        .transition(.opacity)

                    CompanionSweatBead(size: size, elapsed: elapsed)
                        .offset(x: size * 0.30, y: -size * 0.24 + petBounce)
                        .zIndex(6)
                        .transition(.opacity)
                }

                if showsCalmAccent {
                    // Calm / settled: two soft motes drifting up beside the companion.
                    CompanionMotes(size: size, elapsed: elapsed)
                        .offset(x: size * 0.36, y: -size * 0.30 + petBounce)
                        .zIndex(5)
                        .transition(.opacity)
                }

                if settled {
                    // A single drifting "z" — a content, sleepy-happy beat.
                    CompanionDriftingZ(size: size, elapsed: elapsed)
                        .offset(x: size * 0.34, y: -size * 0.30)
                        .zIndex(6)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.44), value: interactionLevel)
            .animation(.easeInOut(duration: 0.5), value: settled)
        }
        .accessibilityLabel("Fernlet companion, \(state.rawValue)")
    }

    /// Back-to-front paint order for equipped custom items so layers stack naturally (the outfit sits
    /// behind a held item, the face piece, and the hat — never on top of them). All values are >= 1 so
    /// every custom item draws above the base avatar (eyes/mouth at the default zIndex 0).
    static func itemPaintOrder(_ slot: ItemSlot) -> Double {
        switch slot {
        case .body: 1
        case .heldItem: 2
        case .face: 3
        case .hat: 4
        }
    }
}

struct CompanionBlobShape: Shape {
    var style: CompanionBodyStyle
    var state: CompanionState
    var breath: Double

    var animatableData: Double {
        get { breath }
        set { breath = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let wobble = CGFloat(breath) * 0.035
        let slump = state == .tired || state == .resting || state == .sick ? CGFloat(0.04) : 0
        var path = Path()

        switch style {
        case .circle:
            path.addEllipse(in: rect)
        case .softBlob:
            path.move(to: point(0.50, 0.04 + slump, rect))
            path.addCurve(to: point(0.94, 0.35, rect), control1: point(0.76 + wobble, 0.02, rect), control2: point(0.96, 0.15, rect))
            path.addCurve(to: point(0.77, 0.91, rect), control1: point(0.94, 0.62, rect), control2: point(0.96, 0.83, rect))
            path.addCurve(to: point(0.22, 0.88, rect), control1: point(0.58, 1.00, rect), control2: point(0.34, 0.98, rect))
            path.addCurve(to: point(0.07, 0.34, rect), control1: point(0.03, 0.73, rect), control2: point(0.01, 0.48, rect))
            path.addCurve(to: point(0.50, 0.04 + slump, rect), control1: point(0.14, 0.14, rect), control2: point(0.26 - wobble, 0.04, rect))
        case .pear:
            path.move(to: point(0.50, 0.02 + slump, rect))
            path.addCurve(
                to: point(0.78 + wobble, 0.34, rect),
                control1: point(0.68, 0.02 + slump, rect),
                control2: point(0.80, 0.16 + slump, rect)
            )
            path.addCurve(
                to: point(0.88, 0.72, rect),
                control1: point(0.80, 0.48, rect),
                control2: point(0.91, 0.55, rect)
            )
            path.addCurve(
                to: point(0.69, 0.93, rect),
                control1: point(0.85, 0.86, rect),
                control2: point(0.79, 0.92, rect)
            )
            path.addCurve(
                to: point(0.31, 0.93, rect),
                control1: point(0.57, 0.97, rect),
                control2: point(0.43, 0.97, rect)
            )
            path.addCurve(
                to: point(0.12, 0.72, rect),
                control1: point(0.21, 0.92, rect),
                control2: point(0.15, 0.86, rect)
            )
            path.addCurve(
                to: point(0.22 - wobble, 0.34, rect),
                control1: point(0.09, 0.55, rect),
                control2: point(0.20, 0.48, rect)
            )
            path.addCurve(
                to: point(0.50, 0.02 + slump, rect),
                control1: point(0.20, 0.16 + slump, rect),
                control2: point(0.32, 0.02 + slump, rect)
            )
        case .puddle:
            path.move(to: point(0.48, 0.13 + slump, rect))
            path.addCurve(to: point(0.93, 0.43, rect), control1: point(0.74, 0.08, rect), control2: point(0.94, 0.20, rect))
            path.addCurve(to: point(0.84, 0.78, rect), control1: point(0.94, 0.58, rect), control2: point(0.98, 0.71, rect))
            path.addCurve(to: point(0.24, 0.87, rect), control1: point(0.64, 0.95, rect), control2: point(0.38, 0.93, rect))
            path.addCurve(to: point(0.06, 0.48, rect), control1: point(0.06, 0.80, rect), control2: point(0.00, 0.63, rect))
            path.addCurve(to: point(0.48, 0.13 + slump, rect), control1: point(0.09, 0.28, rect), control2: point(0.24 - wobble, 0.13, rect))
        }

        path.closeSubpath()
        return path
    }

    private func point(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}

struct EyeView: View {
    var tired: Bool
    /// Presentation-only "happy arc" eye (calm/settled accents): an upward crescent instead of
    /// the round pupil, reading as a soft, content squint. Wins over `tired`.
    var happyArc: Bool = false
    var size: CGFloat

    var body: some View {
        if happyArc {
            CompanionHappyArcEye()
                .stroke(
                    Color(red: 0.239, green: 0.180, blue: 0.118),
                    style: StrokeStyle(lineWidth: max(2, size * 0.024), lineCap: .round)
                )
                .frame(width: size * 0.15, height: size * 0.085)
        } else {
            ZStack {
                Ellipse()
                    .fill(.white.opacity(0.92))
                    .frame(width: size * 0.13, height: tired ? size * 0.07 : size * 0.13)
                Circle()
                    .fill(Color(red: 0.239, green: 0.180, blue: 0.118))
                    .frame(width: size * 0.06, height: size * 0.06)
            }
        }
    }
}

/// An upward-opening crescent — the calm/settled "happy arc" eye. Drawn as a quadratic arc so it
/// reads as a gentle smile-shaped squint rather than a full closed lid.
struct CompanionHappyArcEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.4)
        )
        return path
    }
}

/// The settled pose's wide soft smile — a downward-opening lens (flat top, rounded bottom).
struct CompanionSettledMouth: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.6)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Frazzled / tense accent parts (presentation-only)

/// The soft brow furrow: two short bars tipped up at their inner ends. Warm-neutral, never harsh.
struct CompanionBrowFurrow: View {
    var size: CGFloat

    var body: some View {
        // Two short bars tipped up at their inner ends. Matches the mockup furrow ratio
        // (~15×3 on a 116 body) and its softly-set ink (bark @ ~0.55) — a set brow, not a scowl.
        HStack(spacing: size * 0.17) {
            Capsule()
                .fill(Color.bark.opacity(0.55))
                .frame(width: size * 0.13, height: max(2, size * 0.024))
                .rotationEffect(.degrees(11))
            Capsule()
                .fill(Color.bark.opacity(0.55))
                .frame(width: size * 0.13, height: max(2, size * 0.024))
                .rotationEffect(.degrees(-11))
        }
    }
}

/// Faint rising steam: two low-opacity squiggles that drift up and fade on a slow loop.
struct CompanionSteam: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        // A ~2.6s loop: rise a little and fade in/out. Three wisps of soft, warm-neutral steam —
        // the middle one taller — kept low-opacity (the mockup tops out around 0.55) so it reads
        // as a faint warmth off the body, never a plume.
        let t = (elapsed.truncatingRemainder(dividingBy: 2.6)) / 2.6
        let rise = -size * 0.10 * CGFloat(t)
        let fade = sin(t * .pi) * 0.55
        let line = StrokeStyle(lineWidth: max(1.4, size * 0.015), lineCap: .round)
        HStack(alignment: .bottom, spacing: size * 0.045) {
            CompanionSquiggle()
                .stroke(Color.softTaupe.opacity(0.7), style: line)
                .frame(width: size * 0.06, height: size * 0.13)
            CompanionSquiggle()
                .stroke(Color.softTaupe.opacity(0.7), style: line)
                .frame(width: size * 0.07, height: size * 0.16)
            CompanionSquiggle()
                .stroke(Color.softTaupe.opacity(0.7), style: line)
                .frame(width: size * 0.055, height: size * 0.11)
        }
        .opacity(fade)
        .offset(y: rise)
    }
}

/// One vertical S-squiggle used for the steam wisps.
struct CompanionSquiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.midY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.18),
            control2: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.10)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.10),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.18)
        )
        return path
    }
}

/// One cool sweat bead that slides down and fades on a slow loop.
struct CompanionSweatBead: View {
    var size: CGFloat
    var elapsed: TimeInterval

    // A soft blue-grey teardrop, cool against the warm body — never red.
    private let beadColor = Color(red: 0.80, green: 0.87, blue: 0.88)

    var body: some View {
        let t = (elapsed.truncatingRemainder(dividingBy: 2.8)) / 2.8
        // Fade in quickly, hold, fade out as it reaches the bottom of the slide.
        let fade: Double = t < 0.18 ? t / 0.18 : (t > 0.72 ? max(0, (1 - t) / 0.28) : 1)
        let slide = size * 0.12 * CGFloat(t)
        // A cool droplet with a soft top-left glint so it reads as water catching the light —
        // gentle and dewy, never an alarm.
        CompanionTeardrop()
            .fill(beadColor)
            .frame(width: size * 0.08, height: size * 0.10)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: size * 0.02, height: size * 0.02)
                    .offset(x: size * 0.015, y: size * 0.02)
            }
            .opacity(fade * 0.95)
            .offset(y: slide)
    }
}

/// A teardrop: a rounded droplet with a pointed top (rotated so it hangs point-up like sweat).
struct CompanionTeardrop: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.68),
            control: CGPoint(x: rect.maxX, y: rect.minY + h * 0.32)
        )
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY + h * 0.68),
            radius: w * 0.5,
            startAngle: .degrees(0),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY + h * 0.32)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Calm / settled accent parts (presentation-only)

/// Two soft motes drifting up and fading — the quiet, positive counterpart to the frazzle steam.
struct CompanionMotes: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        ZStack {
            mote(period: 3.0, phase: 0.0, dx: 0, tint: Color.moss, diameter: size * 0.05)
            mote(period: 3.0, phase: 1.1, dx: size * 0.06, tint: Color.goldenrod, diameter: size * 0.035)
        }
    }

    private func mote(period: TimeInterval, phase: TimeInterval, dx: CGFloat, tint: Color, diameter: CGFloat) -> some View {
        let t = ((elapsed + phase).truncatingRemainder(dividingBy: period)) / period
        let rise = -size * 0.16 * CGFloat(t)
        // Twinkle both the opacity and the scale (per the mockup: 0.6→1) so each mote gently
        // swells into view and settles back — a soft sparkle, not a blinking dot.
        let pulse = sin(t * .pi)
        let twinkle = 0.15 + 0.7 * pulse
        let scale = 0.6 + 0.4 * pulse
        return Circle()
            .fill(tint)
            .frame(width: diameter, height: diameter)
            .scaleEffect(scale)
            .opacity(max(0, twinkle))
            .offset(x: dx, y: rise)
    }
}

/// A single drifting "z" for the settled pose — rises, drifts, and fades on a slow loop.
struct CompanionDriftingZ: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let t = (elapsed.truncatingRemainder(dividingBy: 3.4)) / 3.4
        let rise = -size * 0.22 * CGFloat(t)
        let fade = sin(t * .pi)
        Text("z")
            .font(.system(size: size * 0.16, weight: .semibold, design: .serif))
            .foregroundStyle(Color.moss.opacity(0.6))
            .rotationEffect(.degrees(-5 + 12 * t))
            .opacity(fade)
            .offset(y: rise)
    }
}

struct CompanionAccessoryView: View {
    var accessory: CompanionAccessory
    var color: Color
    var size: CGFloat

    var body: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .sprout:
            VStack(spacing: -size * 0.03) {
                Capsule()
                    .fill(color)
                    .frame(width: size * 0.035, height: size * 0.18)
                HStack(spacing: -size * 0.015) {
                    Ellipse()
                        .fill(color)
                        .frame(width: size * 0.18, height: size * 0.09)
                        .rotationEffect(.degrees(-26))
                    Ellipse()
                        .fill(color)
                        .frame(width: size * 0.18, height: size * 0.09)
                        .rotationEffect(.degrees(26))
                }
            }
            .offset(y: -size * 0.55)
        case .flower:
            ZStack {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: size * 0.08, height: size * 0.16)
                        .offset(y: -size * 0.08)
                        .rotationEffect(.degrees(Double(index) * 72))
                }
                Circle()
                    .fill(Color.cream)
                    .frame(width: size * 0.08, height: size * 0.08)
            }
            .offset(x: size * 0.20, y: -size * 0.44)
        case .glasses:
            HStack(spacing: size * 0.08) {
                Circle()
                    .stroke(color.opacity(0.80), lineWidth: max(2, size * 0.018))
                    .frame(width: size * 0.22, height: size * 0.16)
                Circle()
                    .stroke(color.opacity(0.80), lineWidth: max(2, size * 0.018))
                    .frame(width: size * 0.22, height: size * 0.16)
            }
            .overlay(Rectangle().fill(color.opacity(0.80)).frame(width: size * 0.10, height: max(1, size * 0.012)))
            .offset(y: -size * 0.08)
        }
    }
}

struct CompanionClothingView: View {
    var clothing: CompanionClothing
    var color: Color
    var size: CGFloat

    var body: some View {
        switch clothing {
        case .none:
            EmptyView()
        case .scarf:
            Capsule()
                .fill(color)
                .frame(width: size * 0.54, height: size * 0.12)
                .offset(y: size * 0.24)
        case .sleepCap:
            Capsule()
                .fill(color.opacity(0.78))
                .frame(width: size * 0.46, height: size * 0.20)
                .rotationEffect(.degrees(-10))
                .offset(x: -size * 0.08, y: -size * 0.43)
        }
    }
}

/// Draws one equipped user-designed item onto the companion. The pixel grid is rendered once to a
/// `CGImage` (cached in `@State`, regenerated only when the texture changes — never inside the
/// per-frame breath loop) and placed in a slot-specific region, preserving the grid's aspect ratio.
struct CompanionCustomItemLayer: View {
    var item: CustomizationItem
    var size: CGFloat
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                let placement = Self.placement(for: item.slot, size: size, texture: item.texture)
                // `.medium` rather than `.none`: nearest-neighbour was what made worn items read as hard
                // blocks — a body item is ~48 cells across ~79pt, so every cell was a visible square.
                // Safe on alpha because the renderer writes premultipliedLast with transparent cells left
                // at (0,0,0,0), the correct premultiplied encoding, so filtering cannot bleed black halos
                // in from outside the art.
                Image(decorative: image, scale: 1)
                    .interpolation(.medium)
                    .resizable()
                    .frame(width: placement.width, height: placement.height)
                    .offset(x: placement.x, y: placement.y)
            }
        }
        .onChange(of: item.texture, initial: true) { _, texture in
            image = ItemTextureRenderer.image(for: texture)
        }
    }

    /// Slot placement on the `size`-square companion frame. `width` is a fraction of `size`; height
    /// preserves the texture aspect ratio; `(x, y)` is the offset of the region center from the frame
    /// center. Cosmetic — tune freely.
    static func placement(for slot: ItemSlot, size: CGFloat, texture: ItemGridTexture) -> (width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat) {
        let widthFraction: CGFloat
        let center: CGPoint
        switch slot {
        case .hat:
            widthFraction = 0.52
            center = CGPoint(x: 0, y: -0.40)
        case .face:
            widthFraction = 0.56
            center = CGPoint(x: 0, y: -0.06)
        case .body:
            widthFraction = 0.60
            center = CGPoint(x: 0, y: 0.22)
        case .heldItem:
            widthFraction = 0.30
            center = CGPoint(x: 0.54, y: 0.30)
        }
        let width = size * widthFraction
        let aspect = texture.rows > 0 ? CGFloat(texture.cols) / CGFloat(texture.rows) : 1
        let height = aspect > 0 ? width / aspect : width
        return (width, height, size * center.x, size * center.y)
    }
}

struct CompanionSideItemView: View {
    var item: CompanionSideItem
    var color: Color
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.cream)
            Circle()
                .stroke(Color.bark.opacity(0.08), lineWidth: 1)
            sideItemAsset
                .foregroundStyle(color.opacity(0.86))
        }
        .frame(width: size * 0.34, height: size * 0.34)
    }

    @ViewBuilder
    private var sideItemAsset: some View {
        let assetSize = size * 0.34
        switch item {
        case .none:
            Circle()
                .stroke(color.opacity(0.72), lineWidth: max(2, size * 0.014))
                .frame(width: assetSize * 0.42, height: assetSize * 0.42)
                .overlay(
                    Rectangle()
                        .fill(color.opacity(0.72))
                        .frame(width: assetSize * 0.52, height: max(2, size * 0.012))
                        .rotationEffect(.degrees(-45))
                )
        case .mug:
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: assetSize * 0.12, style: .continuous)
                    .fill(color.opacity(0.86))
                    .frame(width: assetSize * 0.42, height: assetSize * 0.44)
                    .offset(x: -assetSize * 0.05)
                Circle()
                    .stroke(color.opacity(0.86), lineWidth: max(2, size * 0.018))
                    .frame(width: assetSize * 0.22, height: assetSize * 0.24)
                    .offset(x: assetSize * 0.08)
            }
        case .book:
            ZStack {
                RoundedRectangle(cornerRadius: assetSize * 0.08, style: .continuous)
                    .fill(color.opacity(0.86))
                    .frame(width: assetSize * 0.54, height: assetSize * 0.42)
                    .rotationEffect(.degrees(-6))
                Rectangle()
                    .fill(Color.cream.opacity(0.65))
                    .frame(width: max(1, size * 0.010), height: assetSize * 0.32)
                    .offset(x: -assetSize * 0.08)
                    .rotationEffect(.degrees(-6))
            }
        case .dumbbell:
            HStack(spacing: assetSize * 0.05) {
                RoundedRectangle(cornerRadius: assetSize * 0.04, style: .continuous)
                    .fill(color.opacity(0.86))
                    .frame(width: assetSize * 0.16, height: assetSize * 0.36)
                Capsule()
                    .fill(color.opacity(0.86))
                    .frame(width: assetSize * 0.36, height: max(3, size * 0.030))
                RoundedRectangle(cornerRadius: assetSize * 0.04, style: .continuous)
                    .fill(color.opacity(0.86))
                    .frame(width: assetSize * 0.16, height: assetSize * 0.36)
            }
            .rotationEffect(.degrees(-12))
        case .waterBottle:
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: assetSize * 0.04, style: .continuous)
                    .fill(color.opacity(0.86))
                    .frame(width: assetSize * 0.20, height: assetSize * 0.10)
                RoundedRectangle(cornerRadius: assetSize * 0.11, style: .continuous)
                    .fill(color.opacity(0.86))
                    .frame(width: assetSize * 0.30, height: assetSize * 0.50)
                    .overlay(
                        Capsule()
                            .fill(Color.cream.opacity(0.45))
                            .frame(width: assetSize * 0.16, height: assetSize * 0.24)
                    )
            }
        }
    }
}

private extension CompanionAppearance {
    func resolvedBodyColor(for state: CompanionState) -> Color {
        color(hex: bodyCustomColorHex, fallback: bodyColor, state: state)
    }

    func resolvedAccessoryColor(for state: CompanionState) -> Color {
        color(hex: accessoryCustomColorHex, fallback: accessoryColor, state: state)
    }

    func resolvedClothingColor(for state: CompanionState) -> Color {
        color(hex: clothingCustomColorHex, fallback: clothingColor, state: state)
    }

    func resolvedSideItemColor(for state: CompanionState) -> Color {
        color(hex: sideItemCustomColorHex, fallback: sideItemColor, state: state)
    }

    private func color(hex: String?, fallback: CompanionAssetColor, state: CompanionState) -> Color {
        if let hex, let color = Color(fernletHex: hex) {
            return color
        }
        return fallback.color(for: state)
    }
}

private extension Color {
    init?(fernletHex: String) {
        let cleaned = fernletHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private extension CompanionState {
    var isLowEnergy: Bool {
        self == .tired || self == .resting || self == .sick
    }

    var animationTempo: Double {
        switch self {
        case .thriving: 1.25
        case .okay: 1.65
        case .tired: 2.35
        case .resting: 3.20
        case .sick: 2.80
        }
    }

    var horizontalBreath: CGFloat {
        switch self {
        case .thriving: 0.018
        case .okay: 0.012
        case .tired, .sick: 0.006
        case .resting: 0.003
        }
    }

    var verticalBreath: CGFloat {
        switch self {
        case .thriving: 0.026
        case .okay: 0.018
        case .tired, .sick: 0.010
        case .resting: 0.004
        }
    }

    func mouthHeight(for size: CGFloat) -> CGFloat {
        switch self {
        case .thriving: size * 0.07
        case .okay: size * 0.05
        case .tired, .sick: size * 0.025
        case .resting: size * 0.018
        }
    }
}

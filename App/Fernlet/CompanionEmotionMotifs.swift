import SwiftUI
import FernletDomainModel
import FernletUI

/// The one small motif each emotion adds beside the companion: a twinkle, a moon, a thought bubble,
/// a heart, a tear.
///
/// Presentation only, drawn by ``CompanionView``'s accent layer above the equipped items. Every
/// motif is vector (shapes plus, for the sleepy "z", the same serif glyph the settled pose already
/// draws) and runs off the view's shared `elapsed` clock, so it pauses with Reduce Motion and when
/// Home is offscreen, exactly like the frazzle steam and the calm motes. ``CompanionEmotion/calm``
/// and ``CompanionEmotion/frazzled`` keep their original accents, which ``CompanionView`` draws
/// itself, so they have no motif here.
struct CompanionEmotionMotif: View {
    let emotion: CompanionEmotion
    let size: CGFloat
    let elapsed: TimeInterval

    var body: some View {
        switch emotion {
        case .happy:
            CompanionTwinkle(size: size, elapsed: elapsed)
                .offset(x: size * 0.40, y: -size * 0.36)
        case .playful:
            CompanionPlayfulSparkles(size: size, elapsed: elapsed)
                .offset(y: -size * 0.30)
        case .loved:
            CompanionRisingHeart(size: size, elapsed: elapsed)
                .offset(x: size * 0.40, y: -size * 0.34)
        case .comforted:
            CompanionHeldHeart(size: size, elapsed: elapsed)
                .offset(x: -size * 0.28, y: size * 0.24)
        case .sad:
            CompanionTear(size: size, elapsed: elapsed)
                .offset(x: -size * 0.15, y: -size * 0.01)
        case .tired:
            CompanionSighPuff(size: size, elapsed: elapsed)
                .offset(x: size * 0.22, y: size * 0.12)
        case .sleepy:
            CompanionMoonAndZ(size: size, elapsed: elapsed)
                .offset(x: size * 0.40, y: -size * 0.40)
        case .hungry, .thirsty:
            CompanionThoughtBubble(content: emotion == .hungry ? .apple : .droplet, size: size, elapsed: elapsed)
                .offset(x: size * 0.46, y: -size * 0.44)
        case .calm, .frazzled:
            EmptyView()
        }
    }
}

// MARK: - Shapes

/// A soft four-point sparkle: four tips joined by curves that pinch in toward the centre.
struct CompanionSparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let pinchX = rect.width * 0.09
        let pinchY = rect.height * 0.09
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: center.x + pinchX, y: center.y - pinchY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: center.x + pinchX, y: center.y + pinchY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: center.x - pinchX, y: center.y + pinchY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: center.x - pinchX, y: center.y - pinchY))
        path.closeSubpath()
        return path
    }
}

/// A rounded heart: two lobes over a soft point.
struct CompanionHeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let lobe = width * 0.25
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + height * 0.30),
                      control1: CGPoint(x: rect.midX - width * 0.12, y: rect.maxY - height * 0.16),
                      control2: CGPoint(x: rect.minX, y: rect.minY + height * 0.60))
        path.addArc(center: CGPoint(x: rect.minX + lobe, y: rect.minY + height * 0.30), radius: lobe,
                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.addArc(center: CGPoint(x: rect.maxX - lobe, y: rect.minY + height * 0.30), radius: lobe,
                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.minY + height * 0.60),
                      control2: CGPoint(x: rect.midX + width * 0.12, y: rect.maxY - height * 0.16))
        path.closeSubpath()
        return path
    }
}

/// A crescent moon: a disc with an offset disc taken out of its upper right.
struct CompanionCrescentShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let disc = Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius,
                                          width: radius * 2, height: radius * 2))
        let bite = Path(ellipseIn: CGRect(x: rect.midX - radius * 0.35, y: rect.midY - radius * 1.25,
                                          width: radius * 1.9, height: radius * 1.9))
        return disc.subtracting(bite)
    }
}

/// A small cloud puff: three overlapping discs on a flat-ish base.
struct CompanionPuffShape: Shape {
    func path(in rect: CGRect) -> Path {
        let height = rect.height
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY + height * 0.30, width: rect.width * 0.50, height: height * 0.70))
        path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.25, y: rect.minY, width: rect.width * 0.50, height: height * 0.80))
        path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.50, y: rect.minY + height * 0.28, width: rect.width * 0.50, height: height * 0.72))
        return path
    }
}

// MARK: - Motifs

/// Happy: one golden sparkle that swells and settles.
struct CompanionTwinkle: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let pulse = (sin(elapsed * .pi / 1.2) + 1) / 2
        CompanionSparkleShape()
            .fill(Color.goldenrod)
            .frame(width: size * 0.11, height: size * 0.11)
            .scaleEffect(0.7 + 0.3 * pulse)
            .opacity(0.55 + 0.4 * pulse)
    }
}

/// Playful: two small sparkles popping on either side, out of phase.
struct CompanionPlayfulSparkles: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let first = (sin(elapsed * .pi / 0.9) + 1) / 2
        let second = (sin(elapsed * .pi / 0.9 + .pi) + 1) / 2
        HStack(spacing: size * 0.78) {
            CompanionSparkleShape()
                .fill(Color.goldenrod)
                .frame(width: size * 0.09, height: size * 0.09)
                .scaleEffect(0.5 + 0.5 * first)
                .opacity(0.35 + 0.6 * first)
            CompanionSparkleShape()
                .fill(Color.sun)
                .frame(width: size * 0.08, height: size * 0.08)
                .scaleEffect(0.5 + 0.5 * second)
                .opacity(0.35 + 0.6 * second)
        }
    }
}

/// Loved: a heart that rises beside the head and fades, on a slow loop.
struct CompanionRisingHeart: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let t = elapsed.truncatingRemainder(dividingBy: 3.2) / 3.2
        CompanionHeartShape()
            .fill(Color.dustyRose)
            .frame(width: size * 0.12, height: size * 0.11)
            .scaleEffect(0.85 + 0.15 * sin(t * .pi))
            .opacity(sin(t * .pi) * 0.9)
            .offset(y: -size * 0.14 * CGFloat(t))
    }
}

/// Comforted: a small heart held close in front, breathing with the body — held, not celebrated.
struct CompanionHeldHeart: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let pulse = (sin(elapsed * .pi / 1.8) + 1) / 2
        CompanionHeartShape()
            .fill(Color.dustyRose.opacity(0.88))
            .frame(width: size * 0.13, height: size * 0.12)
            .scaleEffect(0.94 + 0.08 * pulse)
    }
}

/// Sad: one soft, cool tear that slides slowly down the cheek and fades — never a stream.
struct CompanionTear: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let t = elapsed.truncatingRemainder(dividingBy: 4.0) / 4.0
        let fade: Double = t < 0.2 ? t / 0.2 : max(0, (1 - t) / 0.8)
        CompanionTeardrop()
            .fill(Color(red: 0.62, green: 0.75, blue: 0.84))
            .frame(width: size * 0.05, height: size * 0.07)
            .opacity(fade * 0.85)
            .offset(y: size * 0.10 * CGFloat(t))
    }
}

/// Tired: a small sigh puff drifting away from the mouth and thinning out.
struct CompanionSighPuff: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let t = elapsed.truncatingRemainder(dividingBy: 3.6) / 3.6
        // Soft white rather than taupe: the puff has to read on every band's body colour, and the
        // tired band's is the dusty rose that swallowed a taupe puff whole.
        CompanionPuffShape()
            .fill(Color.white.opacity(0.6))
            .frame(width: size * 0.15, height: size * 0.085)
            .scaleEffect(0.7 + 0.4 * CGFloat(t))
            .opacity(sin(t * .pi) * 0.8)
            .offset(x: size * 0.10 * CGFloat(t), y: -size * 0.04 * CGFloat(t))
    }
}

/// Sleepy: a small crescent moon bobbing above the head, with a "z" drifting up beside it.
struct CompanionMoonAndZ: View {
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let bob = sin(elapsed * .pi / 2.4) * size * 0.012
        ZStack {
            CompanionCrescentShape()
                .fill(Color.goldenrod.opacity(0.9))
                .frame(width: size * 0.16, height: size * 0.16)
                .rotationEffect(.degrees(-18))
                .offset(y: bob)
            CompanionDriftingZ(size: size * 0.8, elapsed: elapsed)
                .offset(x: -size * 0.12, y: size * 0.02)
        }
    }
}

/// Hungry and thirsty: a thought bubble trailing up from the head, holding an apple or a drop of
/// water — a wish, drawn gently, never a warning.
struct CompanionThoughtBubble: View {
    /// What the companion is thinking about.
    enum Content {
        case apple
        case droplet
    }

    let content: Content
    var size: CGFloat
    var elapsed: TimeInterval

    var body: some View {
        let bob = sin(elapsed * .pi / 2.2) * size * 0.012
        ZStack(alignment: .bottomLeading) {
            bubble
            Circle().fill(Color.cream).frame(width: size * 0.035, height: size * 0.035)
                .overlay(Circle().stroke(Color.bark.opacity(0.14), lineWidth: 1))
                .offset(x: -size * 0.07, y: size * 0.08)
            Circle().fill(Color.cream).frame(width: size * 0.05, height: size * 0.05)
                .overlay(Circle().stroke(Color.bark.opacity(0.14), lineWidth: 1))
                .offset(x: -size * 0.03, y: size * 0.03)
        }
        .offset(y: bob)
    }

    private var bubble: some View {
        ZStack {
            Circle().fill(Color.cream)
            Circle().stroke(Color.bark.opacity(0.14), lineWidth: 1)
            switch content {
            case .apple: CompanionApple(size: size)
            case .droplet:
                CompanionTeardrop()
                    .fill(Color(red: 0.42, green: 0.60, blue: 0.72))
                    .frame(width: size * 0.07, height: size * 0.095)
            }
        }
        .frame(width: size * 0.20, height: size * 0.20)
    }
}

/// A tiny apple: a round fruit, a stem, and one leaf.
struct CompanionApple: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.terracotta.opacity(0.9))
                .frame(width: size * 0.085, height: size * 0.08)
                .offset(y: size * 0.008)
            Capsule()
                .fill(Color.bark.opacity(0.7))
                .frame(width: max(1, size * 0.01), height: size * 0.03)
                .offset(y: -size * 0.04)
            Ellipse()
                .fill(Color.moss)
                .frame(width: size * 0.035, height: size * 0.018)
                .rotationEffect(.degrees(-28))
                .offset(x: size * 0.018, y: -size * 0.045)
        }
    }
}

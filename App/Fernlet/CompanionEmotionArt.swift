import SwiftUI
import FernletDomainModel
import FernletUI

// MARK: - Face grammar

/// How one companion eye is drawn.
///
/// The open styles share one white eye and a bark pupil (the original companion eye); the others
/// are single strokes. `drooped` is the low-energy half-lid the tired/resting/sick states have always
/// used, and `happyArc` is the calm/settled crescent.
enum CompanionEyeStyle: Equatable {
    /// The plain round eye.
    case round
    /// The low-energy half-lid.
    case drooped
    /// An upward crescent: a soft, content squint.
    case happyArc
    /// A soft closed lid, curving down: asleep, or soothed.
    case closed
    /// The round eye with a bright glint: happy, playful.
    case sparkle
    /// The round eye, gaze lowered, with two glints: sad with you.
    case glossy
    /// The round eye, gaze raised toward a thought bubble: hungry, thirsty.
    case lookingUp
}

/// How the companion's mouth is drawn.
enum CompanionMouthStyle: Equatable {
    /// The state's own rounded bar, its height set by the band.
    case state
    /// The settled pose's wide soft lens.
    case settledLens
    /// A stroked upward arc.
    case smile
    /// A small stroked upward arc.
    case softSmile
    /// A small open smile.
    case grin
    /// A small stroked downward arc — gentle, never a scowl.
    case frown
    /// A small round "o".
    case open
    /// A taller "o": a yawn.
    case yawn
    /// A short flat line.
    case flat
}

/// The companion's face for one frame: which eyes, which mouth, how much blush, and whether the
/// brows lift in sympathy.
///
/// Resolved from the state, the emotion, the settled pose and the day's gentleness by
/// ``resolve(state:emotion:settled:gentleDay:)`` — the single place they meet, so the reconciliation
/// rules live in one table:
/// - any emotion replaces the plain state face (so an emotion always outranks the old `calmTint`
///   happy eyes: calm is now just one more emotion, and it only shows when nothing above it fires);
/// - the settled pet-cooldown pose keeps its droopy-happy face, EXCEPT on a gentle or unwell day
///   (the day itself is gentle or sick, or the emotion is sad, tired, sleepy or comforted), where it
///   softens to closed, soothed eyes — petting a companion on a hard day comforts it; it never makes
///   it look cheerful. The day is passed in rather than read off the emotion because the settled
///   window (ten minutes) outlasts the pet's comforted beat, and a relaunch restores the pose with
///   no pet at all.
struct CompanionExpression: Equatable {
    var leftEye: CompanionEyeStyle
    var rightEye: CompanionEyeStyle
    var mouth: CompanionMouthStyle
    /// Blush opacity; 0 draws none.
    var blush: Double
    /// Brows lifted at their inner ends — the sympathetic "I'm with you" look.
    var sympatheticBrows: Bool = false

    /// The face for a state, an emotion (nil = none), the settled pose, and whether the day is gentle
    /// (`CompanionEmotionInputs.isGentleDay`).
    static func resolve(state: CompanionState, emotion: CompanionEmotion?, settled: Bool,
                        gentleDay: Bool) -> CompanionExpression {
        if settled { return settledFace(state: state, emotion: emotion, gentleDay: gentleDay) }
        guard let emotion else { return stateFace(state) }
        return face(for: emotion, state: state)
    }

    /// The plain state face: round eyes (half-lids on a low-energy band) and the state's mouth.
    static func stateFace(_ state: CompanionState) -> CompanionExpression {
        let eye: CompanionEyeStyle = state.isLowEnergy ? .drooped : .round
        return CompanionExpression(leftEye: eye, rightEye: eye, mouth: .state, blush: 0)
    }

    /// The settled pose's face: content and droopy-happy, or soothed on a gentle or unwell day.
    static func settledFace(state: CompanionState, emotion: CompanionEmotion?, gentleDay: Bool) -> CompanionExpression {
        let gentle: Set<CompanionEmotion> = [.comforted, .sad, .tired, .sleepy]
        if gentleDay || state == .sick || emotion.map(gentle.contains) == true {
            return CompanionExpression(leftEye: .closed, rightEye: .closed, mouth: .softSmile, blush: 0.34)
        }
        return CompanionExpression(leftEye: .happyArc, rightEye: .happyArc, mouth: .settledLens, blush: 0.42)
    }

    /// Each emotion's face.
    static func face(for emotion: CompanionEmotion, state: CompanionState) -> CompanionExpression {
        switch emotion {
        case .happy: CompanionExpression(leftEye: .sparkle, rightEye: .sparkle, mouth: .smile, blush: 0.22)
        case .playful: CompanionExpression(leftEye: .happyArc, rightEye: .sparkle, mouth: .grin, blush: 0.30)
        case .loved: CompanionExpression(leftEye: .happyArc, rightEye: .happyArc, mouth: .softSmile, blush: 0.42)
        case .calm: CompanionExpression(leftEye: .happyArc, rightEye: .happyArc, mouth: .state, blush: 0.38)
        case .comforted: CompanionExpression(leftEye: .closed, rightEye: .closed, mouth: .softSmile, blush: 0.34)
        case .sad: CompanionExpression(leftEye: .glossy, rightEye: .glossy, mouth: .frown, blush: 0, sympatheticBrows: true)
        case .tired: CompanionExpression(leftEye: .drooped, rightEye: .drooped, mouth: .flat, blush: 0)
        case .sleepy: CompanionExpression(leftEye: .closed, rightEye: .closed, mouth: .yawn, blush: 0)
        case .hungry, .thirsty: CompanionExpression(leftEye: .lookingUp, rightEye: .lookingUp, mouth: .open, blush: 0)
        case .frazzled: stateFace(state)
        }
    }

    /// Whether this face reads as cheerful: a crescent or glinting eye, or a smile.
    ///
    /// `CompanionEmotionPresentationTests` holds every gentle-day and unwell face to `false`.
    var isHappyLooking: Bool {
        let cheerfulEyes: Set<CompanionEyeStyle> = [.happyArc, .sparkle]
        let cheerfulMouths: Set<CompanionMouthStyle> = [.smile, .grin, .settledLens]
        return cheerfulEyes.contains(leftEye) || cheerfulEyes.contains(rightEye) || cheerfulMouths.contains(mouth)
    }
}

extension CompanionEmotion {
    /// The breath period for this emotion, from the state's own: slower when sleepy, tired, sad or
    /// soothed, quicker when playful, happy or frazzled.
    func breathTempo(from base: Double) -> Double {
        switch self {
        case .sleepy: max(base, 3.6)
        case .tired: base * 1.25
        case .sad: base * 1.2
        case .calm, .loved, .comforted: max(base, 3.3)
        case .playful: base * 0.75
        case .happy: base * 0.9
        case .frazzled: base * 0.8
        case .hungry, .thirsty: base
        }
    }
}

// MARK: - Eyes, mouth, brows

/// One companion eye in any ``CompanionEyeStyle``.
///
/// Replaces the old two-flag eye (`tired`, `happyArc`): the round, drooped and crescent styles
/// draw exactly as they did, and the new styles only add glints, a shifted gaze, or a closed lid.
struct CompanionEyeView: View {
    let style: CompanionEyeStyle
    let size: CGFloat

    /// The pupil and stroke ink — the companion's bark brown.
    static let ink = Color(red: 0.239, green: 0.180, blue: 0.118)

    var body: some View {
        switch style {
        case .happyArc:
            CompanionHappyArcEye()
                .stroke(Self.ink, style: StrokeStyle(lineWidth: max(2, size * 0.024), lineCap: .round))
                .frame(width: size * 0.15, height: size * 0.085)
        case .closed:
            CompanionClosedEye()
                .stroke(Self.ink, style: StrokeStyle(lineWidth: max(2, size * 0.024), lineCap: .round))
                .frame(width: size * 0.15, height: size * 0.06)
        case .round, .drooped, .sparkle, .glossy, .lookingUp:
            openEye
        }
    }

    /// The white eye, the pupil (its gaze shifted for glossy and looking-up), and the glints.
    private var openEye: some View {
        let pupilShift: CGFloat = switch style {
        case .glossy: size * 0.02
        case .lookingUp: -size * 0.024
        default: 0
        }
        return ZStack {
            Ellipse()
                .fill(.white.opacity(0.92))
                .frame(width: size * 0.13, height: style == .drooped ? size * 0.07 : size * 0.13)
            Circle()
                .fill(Self.ink)
                .frame(width: size * 0.06, height: size * 0.06)
                .offset(y: pupilShift)
            if style == .sparkle || style == .glossy {
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: max(1.5, size * 0.022), height: max(1.5, size * 0.022))
                    .offset(x: size * 0.013, y: pupilShift - size * 0.013)
            }
            if style == .glossy {
                Circle()
                    .fill(.white.opacity(0.8))
                    .frame(width: max(1, size * 0.012), height: max(1, size * 0.012))
                    .offset(x: -size * 0.012, y: pupilShift + size * 0.012)
            }
        }
    }
}

/// A closed lid curving down — asleep, or soothed.
///
/// The mirror of ``CompanionHappyArcEye``: where the crescent bows UP into a content squint, this
/// bows DOWN into a resting lid, so a closed-eyed companion never reads as grinning.
struct CompanionClosedEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.4)
        )
        return path
    }
}

/// A shallow arc: bowed down it is a smile, bowed up (``CompanionFrownArc``) a gentle frown.
struct CompanionSmileArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.6))
        return path
    }
}

/// A shallow upward bow — the sad face's small, soft frown.
struct CompanionFrownArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return path
    }
}

/// The companion's mouth in any ``CompanionMouthStyle``, in the face's soft white.
struct CompanionMouthView: View {
    let style: CompanionMouthStyle
    let state: CompanionState
    let size: CGFloat

    var body: some View {
        let line = StrokeStyle(lineWidth: max(2, size * 0.026), lineCap: .round)
        switch style {
        case .state:
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(0.72))
                .frame(width: size * 0.18, height: state.mouthHeight(for: size))
        case .settledLens:
            CompanionSettledMouth().fill(.white.opacity(0.78)).frame(width: size * 0.30, height: size * 0.15)
        case .grin:
            CompanionSettledMouth().fill(.white.opacity(0.82)).frame(width: size * 0.22, height: size * 0.11)
        case .smile:
            CompanionSmileArc().stroke(.white.opacity(0.85), style: line).frame(width: size * 0.24, height: size * 0.07)
        case .softSmile:
            CompanionSmileArc().stroke(.white.opacity(0.82), style: line).frame(width: size * 0.15, height: size * 0.04)
        case .frown:
            CompanionFrownArc().stroke(.white.opacity(0.78), style: line).frame(width: size * 0.14, height: size * 0.035)
        case .open:
            Ellipse().fill(.white.opacity(0.78)).frame(width: size * 0.085, height: size * 0.075)
        case .yawn:
            Ellipse().fill(.white.opacity(0.78)).frame(width: size * 0.09, height: size * 0.12)
        case .flat:
            Capsule().fill(.white.opacity(0.72)).frame(width: size * 0.12, height: max(2, size * 0.022))
        }
    }
}

/// Two short brows lifted at their inner ends — sad WITH the person, the opposite of a scowl.
///
/// The frazzle furrow (``CompanionBrowFurrow``) tips the inner ends DOWN into a set brow; this tips
/// them UP, which is what reads as sympathy rather than disappointment.
struct CompanionSympatheticBrows: View {
    var size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.17) {
            Capsule()
                .fill(Color.bark.opacity(0.5))
                .frame(width: size * 0.12, height: max(2, size * 0.022))
                .rotationEffect(.degrees(-14))
            Capsule()
                .fill(Color.bark.opacity(0.5))
                .frame(width: size * 0.12, height: max(2, size * 0.022))
                .rotationEffect(.degrees(14))
        }
    }
}

import SwiftUI
import FernletDomainModel

struct CompanionView: View {
    var state: CompanionState
    var appearance: CompanionAppearance = .standard
    var size: CGFloat
    var interactionLevel: Int = 0
    /// User-designed items currently equipped (one per occupied slot). Drawn as the topmost layer so
    /// they always read clearly over the base avatar.
    var equippedItems: [CustomizationItem] = []
    /// Presentation-only "a little frazzled" accent (opt-in body signals, state >= tense):
    /// slightly quicker breathing plus a small squiggle. DELIBERATELY not a `CompanionState`
    /// case — new raw values in the persisted `DailyHealthScore.companionState` would fail
    /// decode on older builds, so frazzled stays a render flag that is never persisted.
    /// Ignored for the low-energy states (sick/resting/tired keep their own posture).
    var stressTint: Bool = false

    private var showsStressAccent: Bool {
        stressTint && !state.isLowEnergy
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let tempo = showsStressAccent ? state.animationTempo * 0.8 : state.animationTempo
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
                    .scaleEffect(x: 1 + breath * state.horizontalBreath, y: 1 + breath * state.verticalBreath)
                    .offset(y: state == .resting ? size * 0.04 : petBounce)
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

                HStack(spacing: size * 0.18) {
                    EyeView(tired: state.isLowEnergy, size: size)
                    EyeView(tired: state.isLowEnergy, size: size)
                }
                .offset(y: -size * 0.08 + petBounce)

                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.72))
                    .frame(width: size * 0.18, height: state.mouthHeight(for: size))
                    .offset(y: size * 0.14 + petBounce)

                ForEach(equippedItems) { item in
                    CompanionCustomItemLayer(item: item, size: size)
                        .offset(y: petBounce)
                        .zIndex(Self.itemPaintOrder(item.slot))
                }

                if showsStressAccent {
                    // Tiny frazzle squiggle — a gentle "little frazzled" cue, never alarming.
                    Image(systemName: "scribble")
                        .font(.system(size: size * 0.13, weight: .semibold))
                        .foregroundStyle(Color.slate.opacity(0.55))
                        .rotationEffect(.degrees(-16))
                        .offset(x: size * 0.40, y: -size * 0.36 + petBounce)
                        .zIndex(5)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.44), value: interactionLevel)
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
    var size: CGFloat

    var body: some View {
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
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
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

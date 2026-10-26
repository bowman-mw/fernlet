import SwiftUI
import FernletDomainModel
import FernletUI

/// Where an onboarding step sits in the flow, for the framed progress segments under its caption
/// (designs `b2-onb-1` … `b2-onb-8`). The coordinator sets it; a step's own page reads it through
/// ``OnboardingScreenContainer``.
struct OnboardingStepPosition: Equatable, Sendable {
    /// Zero-based.
    let index: Int
    let count: Int
}

extension EnvironmentValues {
    /// The onboarding step on screen, or nil outside onboarding.
    @Entry var onboardingStepPosition: OnboardingStepPosition? = nil
}

/// The framed progress segments: one per step, moss up to and including this one, paper after it.
/// Decorative: the “2 of 8” caption beside Back says the same.
struct OnboardingStepProgress: View {
    let position: OnboardingStepPosition

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<max(position.count, 1), id: \.self) { step in
                RoundedRectangle(cornerRadius: 4)
                    .fill(step <= position.index ? WorldPalette.moss : WorldPalette.paperLight)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(WorldPalette.ink, lineWidth: 2))
                    .frame(height: 12)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The onboarding Back (design `b2-onb-2`): the pixel arrow and “Back”, at least 44 pt.
struct OnboardingBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                WorldSpriteView(sprite: WorldSprites.chevL, scale: 2)
                Text("Back")
                    .font(FernletFramedFont.back)
                    .foregroundStyle(WorldPalette.bark)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.back")
    }
}

/// An onboarding card (designs `b2-onb-1`, `-2`, `-3`, `-8`): a framed card with a framed pixel tile,
/// a Fraunces title and a line under it. Static, or the label of a choice's button.
struct OnboardingCard: View {
    let sprite: WorldSprite
    let title: Text
    let detail: Text
    /// Marks the chosen card in a choice (a moss ring).
    var isSelected = false
    /// The tile's fill, where the art needs one to show (the white iCloud cloud on sky).
    var tileFill: Color? = nil
    /// A control at the card's end (Notifications' Turn on).
    var accessory: AnyView? = nil
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            HStack(alignment: .top, spacing: 14) {
                FernletIconTile(size: 46, fill: tileFill) { WorldSpriteView(sprite: sprite, scale: 3) }
                VStack(alignment: .leading, spacing: 3) {
                    title
                        .font(FernletFramedFont.cardTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                    detail
                        .font(FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
                .fernletWrappingText()
                Spacer(minLength: 0)
                if let accessory { accessory }
            }
        }
        .overlay { OnboardingSelectionRing(isSelected: isSelected) }
        .contentShape(Rectangle())
    }
}

/// The moss ring around a chosen onboarding card (designs `b2-onb-4`, `b2-onb-6b`).
struct OnboardingSelectionRing: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius + 3)
                .strokeBorder(WorldPalette.moss, lineWidth: 3)
                .padding(-3)
                .accessibilityHidden(true)
        }
    }
}

/// A choice in a radio group (designs `b2-onb-6b`, `b2-onb-7`): a framed card with a Fraunces title,
/// a line under it, and a framed square at the end, moss with a white tick when chosen; the chosen
/// card wears the moss ring.
struct OnboardingRadioCard: View {
    let title: Text
    var detail: Text? = nil
    let isSelected: Bool
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    title
                        .font(FernletFramedFont.cardTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                    if let detail {
                        detail
                            .font(FernletFramedFont.body)
                            .foregroundStyle(look?.dim ?? Color.slate)
                    }
                }
                .fernletWrappingText()
                Spacer(minLength: 8)
                checkbox
            }
        }
        .overlay { OnboardingSelectionRing(isSelected: isSelected) }
        .contentShape(Rectangle())
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? WorldPalette.accent : WorldPalette.paperLight)
            .frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .overlay { if isSelected { WorldSpriteView(sprite: WorldSprites.check, scale: 2, tint: WorldPalette.onAccent) } }
            .accessibilityHidden(true)
    }
}

/// Onboarding's own pixel art.
enum OnboardingArt {
    /// A bell, for the daily check-in reminder (`b2-onb-8`).
    static let bell = WorldSprite(rows: ["...k...", "..kyk..", ".kyyyk.", ".kyyyk.", ".kyyyk.", "kyyyyyk", "kkkkkkk", "...k..."],
                                  palette: ["k": 0x4A2E1C, "y": 0xF2C14E])
}

/// The pixel companion close up and, beside it, as it stands on the map (designs `b2-onb-1`,
/// `b2-onb-5`). Decorative.
struct OnboardingPixelCompanion: View {
    var appearance: CompanionAppearance = .standard
    var state: CompanionState = .thriving
    /// Points per pixel close up.
    var scale: CGFloat = 7
    /// Whether the small map version sits beside it.
    var showsMap = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let look = WorldCompanionLook(appearance: appearance, state: state, asleep: false)
        let grid = WorldCompanionPainter.paint(state: state, look: look,
                                               pose: WorldCompanionPose(breathIn: false, settled: false, asleep: false),
                                               increasedContrast: contrast == .increased)
        HStack(alignment: .bottom, spacing: 30) {
            canvas(grid, scale: scale)
            if showsMap {
                canvas(grid, scale: 3)
                    .frame(width: 80, height: 80)
                    .background(WorldPalette.adaptive(light: 0xE7E2D4, dark: 0x2A2017), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 3))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func canvas(_ grid: WorldCompanionGrid, scale: CGFloat) -> some View {
        WorldCompanionCanvas(grid: grid, scale: scale)
            .frame(width: CGFloat(WorldCompanionGrid.width) * scale, height: CGFloat(WorldCompanionGrid.height) * scale)
    }
}

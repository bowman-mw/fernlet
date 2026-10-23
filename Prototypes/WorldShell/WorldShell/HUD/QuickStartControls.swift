import SwiftUI

/// The blue button: quick-starts what you usually do where you're standing. Its icon changes with
/// the place; it never badges, buzzes or notifies (design page, "It never nags").
struct QuickStartButton: View {
    let spot: FixtureSpot?
    let expanded: Bool
    let action: () -> Void
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        let radius = metrics.pt(8), edge = metrics.pt(2)
        Button(action: action) {
            PixelSpriteView(sprite: QuickStart.buttonIcon(at: spot))
                .frame(width: metrics.pt(42), height: metrics.pt(42))
                .background {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(expanded ? FernColors.rgb(0x4FA6B8) : FernColors.teal)
                        .overlay(alignment: .bottom) { FernColors.tealShade.frame(height: metrics.pt(3)).padding(.horizontal, edge + 1).padding(.bottom, edge) }
                        .overlay(alignment: .top) { FernColors.tealLight.frame(height: edge).padding(.horizontal, edge * 2).padding(.top, edge) }
                        .background {
                            RoundedRectangle(cornerRadius: radius)
                                .fill(Color(.sRGB, red: 0.08, green: 0.16, blue: 0.2, opacity: 0.4)).offset(y: edge)
                        }
                }
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(FernColors.tealDark, lineWidth: edge))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spot.map { "Quick start at \($0.label)" } ?? "Walk together")
        .accessibilityAddTraits(expanded ? .isSelected : [])
    }
}

/// The plate beside the blue button naming the known place you're standing at.
struct HerePlate: View {
    let spot: FixtureSpot
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        Text("At \(spot.label)")
            .font(.system(size: metrics.pt(11.5), weight: .bold, design: .rounded))
            .foregroundStyle(FernColors.ink)
            .padding(EdgeInsets(top: metrics.pt(2), leading: metrics.pt(7), bottom: metrics.pt(2), trailing: metrics.pt(7)))
            .background(FernColors.gameCream.opacity(0.95), in: RoundedRectangle(cornerRadius: metrics.pt(6)))
            .overlay(RoundedRectangle(cornerRadius: metrics.pt(6)).strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
            .accessibilityHidden(true)
    }
}

/// The small "back to Fernlet" button, shown once you've panned the map away.
struct RecentreButton: View {
    let action: () -> Void
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        Button(action: action) {
            PixelSpriteView(sprite: PixelSprites.crosshair)
                .frame(width: metrics.pt(34), height: metrics.pt(34))
                .background(FernColors.slate, in: RoundedRectangle(cornerRadius: metrics.pt(7)))
                .overlay(RoundedRectangle(cornerRadius: metrics.pt(7)).strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Fernlet")
    }
}

/// The quick-start card above the blue button: the place, how often you've been, and what it can
/// start. On a resting or sick day it says rest counts first.
struct QuickStartCard: View {
    let spot: FixtureSpot?
    let level: TimeWithFernlet
    let gentle: Bool
    let onPick: (QuickStartOption) -> Void
    let onClose: () -> Void
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.pt(6)) {
            HStack {
                Text(spot?.label ?? "Go for a walk")
                    .font(.system(size: metrics.pt(14), weight: .bold, design: .rounded))
                    .foregroundStyle(FernColors.ink)
                Spacer()
                GameCloseButton(action: onClose)
            }
            if gentle {
                note("Resting counts today. These are here if you want them.")
            }
            note(QuickStart.seenLine(for: spot, level: level))
            ForEach(Array(QuickStart.options(at: spot, level: level).enumerated()), id: \.element.id) { index, option in
                Button { onPick(option) } label: { row(option, primary: index == 0) }
                    .buttonStyle(.plain)
            }
        }
        .padding(metrics.pt(8))
        .frame(width: metrics.pt(232))
        .gamePlate(cornerRadius: metrics.pt(10), border: metrics.pt(3))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: metrics.pt(11.5)))
            .foregroundStyle(FernColors.rgb(0x7A5A3A))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One option: the pixel icon in a teal tile, the title and a line under it.
    private func row(_ option: QuickStartOption, primary: Bool) -> some View {
        HStack(spacing: metrics.pt(8)) {
            PixelSpriteView(sprite: option.icon)
                .frame(width: metrics.pt(30), height: metrics.pt(30))
                .background(primary ? FernColors.tealDark.opacity(0.35) : FernColors.teal, in: RoundedRectangle(cornerRadius: metrics.pt(6)))
            VStack(alignment: .leading, spacing: 1) {
                Text(option.title).font(.system(size: metrics.pt(12.5), weight: .semibold))
                Text(option.subtitle).font(.system(size: metrics.pt(11))).opacity(0.85).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(primary ? Color.white : FernColors.speechInk)
        .padding(EdgeInsets(top: metrics.pt(6), leading: metrics.pt(8), bottom: metrics.pt(6), trailing: metrics.pt(8)))
        .background(primary ? FernColors.teal : FernColors.paper, in: RoundedRectangle(cornerRadius: metrics.pt(8)))
        .overlay(RoundedRectangle(cornerRadius: metrics.pt(8)).strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
        .contentShape(Rectangle())
    }
}

/// The game look's ✕ button for cards and panels.
struct GameCloseButton: View {
    let action: () -> Void
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        Button(action: action) {
            Text("✕")
                .font(.system(size: metrics.pt(12), weight: .heavy))
                .foregroundStyle(FernColors.ink)
                .frame(width: metrics.pt(26), height: metrics.pt(24))
                .background(FernColors.paper, in: RoundedRectangle(cornerRadius: metrics.pt(6)))
                .overlay(RoundedRectangle(cornerRadius: metrics.pt(6)).strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

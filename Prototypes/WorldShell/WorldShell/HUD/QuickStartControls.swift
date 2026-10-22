import SwiftUI

/// The blue button: quick-starts what you usually do where you're standing. Its icon changes with
/// the place; it never badges, buzzes or notifies (design page, "It never nags").
struct QuickStartButton: View {
    let spot: FixtureSpot?
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PixelSpriteView(sprite: QuickStart.buttonIcon(at: spot))
                .frame(width: 42, height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(expanded ? FernColors.rgb(0x4FA6B8) : FernColors.teal)
                        .overlay(alignment: .bottom) { FernColors.tealShade.frame(height: 3).padding(.horizontal, 3).padding(.bottom, 2) }
                        .overlay(alignment: .top) { FernColors.tealLight.frame(height: 2).padding(.horizontal, 4).padding(.top, 2) }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FernColors.tealDark, lineWidth: 2))
                .shadow(color: Color(.sRGB, red: 0.08, green: 0.16, blue: 0.2, opacity: 0.4), radius: 0, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spot.map { "Quick start at \($0.label)" } ?? "Walk together")
        .accessibilityAddTraits(expanded ? .isSelected : [])
    }
}

/// The small "back to Fernlet" button, shown once you've panned the map away.
struct RecentreButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PixelSpriteView(sprite: PixelSprites.crosshair)
                .frame(width: 34, height: 34)
                .background(FernColors.slate, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(FernColors.ink, lineWidth: 2))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(spot?.label ?? "Go for a walk")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(FernColors.ink)
                Spacer()
                GameCloseButton(action: onClose)
            }
            if gentle {
                Text("Resting counts today. These are here if you want them.").font(.caption).foregroundStyle(FernColors.rgb(0x7A5A3A))
            }
            Text(QuickStart.seenLine(for: spot, level: level)).font(.caption).foregroundStyle(FernColors.rgb(0x7A5A3A))
            ForEach(Array(QuickStart.options(at: spot, level: level).enumerated()), id: \.element.id) { index, option in
                Button { onPick(option) } label: { row(option, primary: index == 0) }
                    .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 252)
        .gamePlate(cornerRadius: 10)
    }

    /// One option: the pixel icon in a teal tile, the title and a line under it.
    private func row(_ option: QuickStartOption, primary: Bool) -> some View {
        HStack(spacing: 8) {
            PixelSpriteView(sprite: option.icon)
                .frame(width: 30, height: 30)
                .background(primary ? FernColors.tealDark.opacity(0.35) : FernColors.teal, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(option.title).font(.footnote.weight(.semibold))
                Text(option.subtitle).font(.caption2).opacity(0.85).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(primary ? Color.white : FernColors.speechInk)
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .background(primary ? FernColors.teal : FernColors.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(FernColors.ink, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// The game look's ✕ button for cards and panels.
struct GameCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("✕")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(FernColors.ink)
                .frame(width: 30, height: 26)
                .background(FernColors.paper, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FernColors.ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

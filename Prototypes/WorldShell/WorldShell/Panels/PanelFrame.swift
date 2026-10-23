import SwiftUI

/// A framed panel over the map: a wooden title plate with a pixel icon and ✕, then today's screen
/// inside on parchment, in crisp type. Every item-bar button, the hearts, the photo strip and the
/// companion's long-press open one of these.
struct PanelFrame<Content: View>: View {
    let kind: PanelKind
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        let border = metrics.pt(3), radius = metrics.pt(12)
        VStack(spacing: 0) {
            HStack(spacing: metrics.pt(6)) {
                PixelSpriteView(sprite: kind.icon)
                Text(kind.title)
                    .font(.system(size: metrics.pt(16), weight: .bold, design: .rounded))
                    .foregroundStyle(FernColors.woodLabel)
                    .shadow(color: FernColors.ink, radius: 0, x: 0, y: 1)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                GameCloseButton(action: onClose)
            }
            .padding(EdgeInsets(top: metrics.pt(6), leading: metrics.pt(12), bottom: metrics.pt(6), trailing: metrics.pt(6)))
            .background(FernColors.wood)
            .overlay(alignment: .bottom) { FernColors.ink.frame(height: border) }
            // Short panels hug their content; long ones scroll.
            ViewThatFits(in: .vertical) {
                inner
                ScrollView { inner }.scrollIndicators(.hidden)
            }
        }
        .background(FernColors.parchment)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(FernColors.ink, lineWidth: border))
        .background {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(.sRGB, red: 0.157, green: 0.078, blue: 0.031, opacity: 0.3)).offset(y: metrics.pt(4))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The panel's cards, padded.
    private var inner: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .padding(10)
    }
}

/// Today's card look inside panels: cream, a hairline rule, rounded 15.
struct ShellCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FernColors.cream, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(FernColors.rule, lineWidth: 1))
    }
}

/// A card's small caps label ("MACROS", "CARE TASKS").
struct CardLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(FernColors.dim)
    }
}

/// A row that would open a screen in the app; in the shell it says so in a toast.
struct LinkRow: View {
    let title: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(FernColors.bark)
                Spacer()
                if let detail { Text(detail).font(.caption).foregroundStyle(FernColors.dim) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(FernColors.dim)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The moss pill button on cards.
struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(FernColors.parchment)
                .padding(EdgeInsets(top: 6, leading: 13, bottom: 6, trailing: 13))
                .background(FernColors.mossInk, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// HealthBar from Home, as it is today: twelve segments in the state colour.
struct HealthBarView: View {
    let state: ShellCompanionState
    let value: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<12, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < Int((value * 12).rounded()) ? state.color : FernColors.bark.opacity(0.10))
                    .frame(height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Care score \(Int((value * 100).rounded())) percent")
    }
}

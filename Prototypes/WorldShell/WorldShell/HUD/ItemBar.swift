import SwiftUI

/// The item bar: today's tabs as a wooden game bar. Food, Move, Log (raised, in the centre),
/// Friends, Private and Settings, each with its name small under the icon (answer 9), so Voice
/// Control can say any of them.
///
/// The bar's wood, edges and outline are all drawn in its background, so the raised Log disc sits
/// on top of the bar's border, as a child paints over its parent's border in the mockup. Names are
/// solid bark on wood (5.2:1), with no shadow.
struct ItemBar: View {
    let open: PanelKind?
    let action: (PanelKind) -> Void

    /// One slot on the bar.
    struct Slot: Identifiable {
        let kind: PanelKind
        let name: String
        let icon: PixelSprite
        var id: PanelKind { kind }
    }

    private let items: [Slot] = [
        Slot(kind: .food, name: "Food", icon: PixelSprites.onigiri), Slot(kind: .move, name: "Move", icon: PixelSprites.shoe),
        Slot(kind: .log, name: "Log", icon: PixelSprites.basket), Slot(kind: .friends, name: "Friends", icon: PixelSprites.face),
        Slot(kind: .privacy, name: "Private", icon: PixelSprites.diary), Slot(kind: .settings, name: "Settings", icon: PixelSprites.gear),
    ]

    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        let border = metrics.pt(3), radius = metrics.pt(12)
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button { action(item.kind) } label: { label(for: item) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(open == item.kind ? .isSelected : [])
            }
        }
        .padding(.horizontal, metrics.pt(3))
        .frame(height: metrics.barHeight)
        .background {
            RoundedRectangle(cornerRadius: radius)
                .fill(FernColors.wood)
                .overlay(alignment: .top) { FernColors.woodLight.frame(height: border).padding(.horizontal, radius * 0.7).padding(.top, border) }
                .overlay(alignment: .bottom) { FernColors.woodDark.frame(height: border).padding(.horizontal, radius * 0.7).padding(.bottom, border) }
                .background {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color(.sRGB, red: 0.157, green: 0.078, blue: 0.031, opacity: 0.35)).offset(y: border)
                }
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(FernColors.ink, lineWidth: border))
        }
    }

    /// One slot: the pixel icon (Log's on a raised cream disc) over its small name.
    @ViewBuilder
    private func label(for item: Slot) -> some View {
        let disc = metrics.pt(50), lift = metrics.pt(10)
        VStack(spacing: metrics.pt(3)) {
            if item.kind == .log {
                PixelSpriteView(sprite: item.icon)
                    .frame(width: disc, height: disc)
                    .background {
                        Circle().fill(FernColors.gameCream)
                            .background { Circle().fill(FernColors.ink.opacity(0.35)).offset(y: metrics.pt(3)) }
                    }
                    .overlay(Circle().strokeBorder(FernColors.ink, lineWidth: metrics.pt(3)))
                    .offset(y: -lift)
                    .padding(.bottom, -lift)
            } else {
                PixelSpriteView(sprite: item.icon)
            }
            Text(item.name)
                .font(.system(size: metrics.pt(9), weight: .heavy))
                .foregroundStyle(FernColors.woodLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: metrics.pt(52))
        .background {
            if open == item.kind && item.kind != .log {
                RoundedRectangle(cornerRadius: metrics.pt(8)).fill(FernColors.woodSelected)
            }
        }
        .contentShape(Rectangle())
    }
}

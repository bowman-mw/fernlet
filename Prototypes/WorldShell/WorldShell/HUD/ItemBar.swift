import SwiftUI

/// The item bar: today's tabs as a wooden game bar. Food, Move, Log (raised, in the centre),
/// Friends, Private and Settings, each with its name small under the icon (answer 9), so Voice
/// Control can say any of them.
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button { action(item.kind) } label: { label(for: item) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(open == item.kind ? .isSelected : [])
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 64)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(FernColors.wood)
                .overlay(alignment: .top) { FernColors.woodLight.frame(height: 3).padding(.horizontal, 8).padding(.top, 3) }
                .overlay(alignment: .bottom) { FernColors.woodDark.frame(height: 3).padding(.horizontal, 8).padding(.bottom, 3) }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(FernColors.ink, lineWidth: 3))
        .shadow(color: Color(.sRGB, red: 0.157, green: 0.078, blue: 0.031, opacity: 0.35), radius: 0, x: 0, y: 3)
    }

    /// One slot: the pixel icon (Log's on a raised cream disc) over its small name.
    @ViewBuilder
    private func label(for item: Slot) -> some View {
        VStack(spacing: 3) {
            if item.kind == .log {
                PixelSpriteView(sprite: item.icon)
                    .frame(width: 50, height: 50)
                    .background(FernColors.gameCream, in: Circle())
                    .overlay(Circle().strokeBorder(FernColors.ink, lineWidth: 3))
                    .shadow(color: FernColors.ink.opacity(0.35), radius: 0, x: 0, y: 3)
                    .offset(y: -10)
                    .padding(.bottom, -10)
            } else {
                PixelSpriteView(sprite: item.icon)
            }
            Text(item.name)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(FernColors.woodLabel)
                .shadow(color: FernColors.ink, radius: 0, x: 0, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background {
            if open == item.kind && item.kind != .log {
                RoundedRectangle(cornerRadius: 8).fill(FernColors.woodDark)
            }
        }
        .contentShape(Rectangle())
    }
}

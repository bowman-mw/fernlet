import SwiftUI

/// The item bar over the map: today's tabs as a wooden bar, Food, Move, Log (raised, in the middle),
/// Friends, Private and Settings, each with its name small under its pixel icon (design page answer 9;
/// approved Batch 1 draft 3). It shows only on the map: every panel covers it.
///
/// Sizes are the approved design's (84 pt tall, 9 pt in from the sides, 26 pt off the bottom, a 3-pt ink
/// frame, the Log disc 70 pt and raised 34 pt). At accessibility text sizes the names hide, as today's
/// tab bar does, and holding a slot shows its name in the Large Content Viewer; the sprites step up
/// from 3 to 4 points per pixel.
struct WorldItemBar: View {
    /// The panel to open.
    let onOpen: (WorldPanel) -> Void
    @Environment(\.worldTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The bar's height, for the views that sit above it.
    static let height: CGFloat = 84
    /// How far the bar sits off the bottom of the screen.
    static let bottomGap: CGFloat = 26
    /// The bar's name for VoiceOver (a container: nothing taps the bar itself).
    static let barLabel = LocalizedStringResource("itemBar.a11y", defaultValue: "Item bar",
                                                  comment: "World Home: the item bar's name for VoiceOver")

    var body: some View {
        GeometryReader { proxy in
            // The design's columns: 1, 1, 1.15 (Log), 1, 1, 1.
            let unit = max(0, proxy.size.width - 8) / 6.15
            HStack(spacing: 0) {
                ForEach(WorldPanel.itemBar) { panel in
                    slot(panel).frame(width: unit * (panel == .log ? 1.15 : 1))
                }
            }
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .background { barWood }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.barLabel))
        .accessibilityIdentifier("world.itemBar")
    }

    /// One slot: its pixel icon (Log's on a raised paper disc) over its name.
    private func slot(_ panel: WorldPanel) -> some View {
        let accessibility = dynamicTypeSize.isAccessibilitySize
        let scale = theme.scale(accessibilitySize: accessibility)
        return Button { onOpen(panel) } label: {
            VStack(spacing: 4) {
                if panel == .log {
                    WorldSpriteView(sprite: theme.icon(for: panel), scale: scale)
                        .frame(width: 70, height: 70)
                        .background(WorldPalette.paper, in: Circle())
                        .overlay(alignment: .bottom) { logDiscShade }
                        .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 4))
                        .background { Circle().fill(Color(.sRGB, red: 40 / 255, green: 20 / 255, blue: 8 / 255, opacity: 0.35)).offset(y: 4) }
                        .padding(.top, -34)
                } else {
                    WorldSpriteView(sprite: theme.icon(for: panel), scale: scale)
                        .frame(height: accessibility ? 48 : 36, alignment: .bottom)
                }
                if !accessibility {
                    Text(verbatim: panel.barName)
                        .font(WorldType.barLabel)
                        .foregroundStyle(WorldPalette.bark)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: panel.barName))
        .accessibilityIdentifier(panel.itemIdentifier)
        .accessibilityShowsLargeContentViewer {
            WorldSpriteView(sprite: theme.icon(for: panel), scale: 4)
            Text(verbatim: panel.barName)
        }
    }

    /// The paper disc's shaded lower edge.
    private var logDiscShade: some View {
        Circle()
            .trim(from: 0.1, to: 0.4)
            .stroke(WorldPalette.paperShade, lineWidth: 4)
            .padding(6)
    }

    /// The wood: its high and low edges, a 3-pt ink frame and a solid drop shadow (all in the
    /// background, so the raised Log disc paints over the frame).
    private var barWood: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(WorldPalette.wood)
            .overlay(alignment: .top) { WorldPalette.woodHigh.frame(height: 4).padding(.horizontal, 10).padding(.top, 3) }
            .overlay(alignment: .bottom) { WorldPalette.woodLow.frame(height: 4).padding(.horizontal, 10).padding(.bottom, 3) }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.sRGB, red: 40 / 255, green: 20 / 255, blue: 8 / 255, opacity: 0.35)).offset(y: 4)
            }
    }
}

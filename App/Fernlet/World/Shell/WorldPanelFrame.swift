import FernletUI
import SwiftUI

/// The frame every World panel opens in (designs `b1-frame-root`, `-push` and `-keyboard`, draft 3,
/// approved 2026-10-23): it covers the whole screen, status bar and item bar included, with a wooden
/// title plate under the iOS status bar (the panel's pixel icon, its Fraunces title and a 44-pt ✕) and
/// the page below on parchment with a faint dot grid. Closing returns to the map; there's no switching
/// panels from inside one.
///
/// **The seam.** Every panel goes through this one view, so a revision of the frame lands here and
/// nowhere else. During the disposable camera the Friends panel hides its plate, because the camera
/// stays full screen (design batch 2). A page that edits something (Arrange Today) names itself and
/// closes with Done instead of ✕ (design `b1-today-editor`).
///
/// VoiceOver lands on the title when a panel opens, so it hears the screen's name first (the approved
/// frame's accessibility note).
struct WorldPanelFrame<Content: View>: View {
    let panel: WorldPanel
    /// The title on the plate, when it is not the panel's own (Arrange Today).
    var title: String? = nil
    /// Whether the plate closes with ✕ (back to the map) or Done (an editor).
    var closesWithDone = false
    /// Whether the wooden plate shows (false while the disposable camera fills the screen).
    var showsPlate = true
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.worldTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsPlate { plate }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.fernletTabBarClearance, 0)
                // The plate names the panel, so its root page draws only its subtitle (ScreenHeader).
                .environment(\.fernletTitleOnPlate, showsPlate)
        }
        .background { WorldPageBackground().ignoresSafeArea() }
        .onAppear { isTitleFocused = showsPlate }
    }

    /// The wooden title plate: icon, title, ✕ (or Done).
    private var plate: some View {
        HStack(spacing: 10) {
            WorldSpriteView(sprite: theme.icon(for: panel), scale: theme.scale(accessibilitySize: dynamicTypeSize.isAccessibilitySize))
            Text(verbatim: title ?? panel.title)
                .font(WorldType.plateTitle)
                .foregroundStyle(WorldPalette.bark)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            Spacer(minLength: 8)
            if closesWithDone {
                WorldDoneButton(action: onClose)
            } else {
                WorldCloseButton(action: onClose)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 12))
        .background {
            WorldPalette.wood
                .overlay(alignment: .bottom) { WorldPalette.woodLow.frame(height: 4).padding(.bottom, 3) }
                .overlay(alignment: .bottom) { WorldPalette.ink.frame(height: 3) }
                .ignoresSafeArea(edges: .top)
        }
        .background(alignment: .bottom) {
            Color(.sRGB, red: 40 / 255, green: 20 / 255, blue: 8 / 255, opacity: 0.18).frame(height: 3).offset(y: 3)
        }
        .zIndex(1)
    }
}

/// The 44-pt paper ✕ on a title plate.
struct WorldCloseButton: View {
    let action: () -> Void

    /// Its spoken name, and the one word Voice Control can say.
    static let label = LocalizedStringResource("worldPanel.close", defaultValue: "Close",
                                               comment: "World Home: the ✕ on a panel's title plate, which returns to the map")

    var body: some View {
        Button(action: action) {
            WorldSpriteView(sprite: WorldSprites.xx, scale: 3, tint: WorldPalette.bark)
                .frame(width: 44, height: 44)
                .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottom) {
                    WorldPalette.paperShade.frame(height: 3).padding(.horizontal, 3).padding(.bottom, 3)
                }
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldPalette.ink, lineWidth: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.label))
        .accessibilityInputLabels([Text(Self.label)])
        .accessibilityIdentifier("world.panel.close")
    }
}

/// The plate's Done for an editor (Arrange Today): the word on paper in the plate's ink frame, at
/// least 44 pt tall.
struct WorldDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(WorldType.plateLabel)
                .foregroundStyle(WorldPalette.bark)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldPalette.ink, lineWidth: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("world.panel.done")
    }
}

/// A World page: parchment with a faint dot grid every 14 pt (design language, "Pages").
struct WorldPageBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(WorldPalette.page))
            let step: CGFloat = 14
            var dots = Path()
            let columns = min(Int(size.width / step) + 1, 200), rows = min(Int(size.height / step) + 1, 200)
            for row in 0..<rows {
                for column in 0..<columns {
                    dots.addEllipse(in: CGRect(x: CGFloat(column) * step + 6, y: CGFloat(row) * step + 6, width: 2.4, height: 2.4))
                }
            }
            context.fill(dots, with: .color(WorldPalette.pageDot))
        }
        .accessibilityHidden(true)
    }
}

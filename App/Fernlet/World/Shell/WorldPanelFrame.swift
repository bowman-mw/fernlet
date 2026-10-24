import FernletUI
import SwiftUI

/// The frame every World panel opens in (designs `b1-frame-root`, draft 3, `b1-frame-push` and
/// `b1-frame-keyboard`, draft 2, approved 2026-10-23): it covers the whole screen, status bar and item
/// bar included, with a wooden title plate under the iOS status bar (the panel's pixel icon, its
/// Fraunces title and a 44-pt ✕) and the page below on parchment with a faint dot grid. Closing returns
/// to the map; there's no switching panels from inside one.
///
/// **Going deeper.** A page pushed inside the panel's stack with `fernletPushedPage(_:)` keeps this
/// plate: its Back (arrow and the name of the page it returns to, Batch 2's 7-pt gap and 13-pt end) takes
/// the icon's place, its title takes the panel's, and the ✕ stays. The plate learns of pushes through
/// ``FernletPlateNavigation``, which it owns and hands down. Swipe from the left edge still goes back.
///
/// **The keyboard.** The plate stays put and the page ends at the keyboard's top, so a pinned save bar
/// rides above the keyboard and nothing hides behind it.
///
/// **The seam.** Every panel goes through this one view, so a revision of the frame lands here and
/// nowhere else. A frame opened over a page of its own panel can put a Back in the icon's place
/// (`backTitle`, `b4-mem-solo-open`'s "‹ Album"). A page that edits something (Arrange Today) names itself and
/// closes with Done instead of ✕ (design `b1-today-editor`).
///
/// VoiceOver lands on the title when a panel opens and again when a page is pushed or popped, so it
/// hears the screen's name first (the approved frame's accessibility note).
struct WorldPanelFrame<Content: View>: View {
    let panel: WorldPanel
    /// The title on the plate, when it is not the panel's own (Arrange Today).
    var title: String? = nil
    /// Whether the plate closes with ✕ (back to the map) or Done (an editor).
    var closesWithDone = false
    /// Whether the wooden plate shows (false while the disposable camera fills the screen).
    var showsPlate = true
    /// A Back in the icon's place at the root, for a frame opened over a page of its own panel (a "Just
    /// you" set over the Album, `b4-mem-solo-open`): the name of the page it returns to.
    var backTitle: String? = nil
    /// What that Back does (close this frame); the Back shows only when both are set.
    var onBack: (() -> Void)? = nil
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.worldTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The wood App colors chose: the plate stays on screen while App colors is open, so it reads the
    /// choice from the environment to be redrawn by a pick.
    @Environment(\.worldAppColors) private var appColors
    @AccessibilityFocusState private var isTitleFocused: Bool
    /// The pages pushed under this plate (their titles and Backs).
    @State private var navigation = FernletPlateNavigation()

    var body: some View {
        VStack(spacing: 0) {
            if showsPlate { plate }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.fernletTabBarClearance, 0)
                // The plate names the panel, so its root page draws only its subtitle (ScreenHeader).
                .environment(\.fernletTitleOnPlate, showsPlate)
                .environment(\.fernletPlateNavigation, showsPlate ? navigation : nil)
        }
        .background { WorldPageBackground().ignoresSafeArea() }
        .onAppear {
            navigation.rootTitle = plateTitle
            isTitleFocused = showsPlate
        }
        .onChange(of: navigation.top?.id) { _, _ in isTitleFocused = showsPlate }
    }

    /// The panel's own title on the plate.
    private var plateTitle: String { title ?? panel.title }

    /// The wooden title plate (`.pt`): icon and title, or Back and the pushed page's title; then ✕ (or
    /// Done). 4 pt under the status bar, 10 pt above its 4-pt dark band and 3-pt ink edge.
    private var plate: some View {
        HStack(spacing: 10) {
            if let page = navigation.top {
                FernletBackButton(verbatim: navigation.topBackTitle, compact: FernletBackButton.isCompact(title: page.title)) {
                    navigation.popTop()
                }
                    .disabled(navigation.isHeld)
                    .padding(.trailing, 6)
                plateText(page.title)
            } else if let backTitle, let onBack {
                FernletBackButton(verbatim: backTitle, compact: FernletBackButton.isCompact(title: plateTitle), action: onBack)
                    .padding(.trailing, 6)
                plateText(plateTitle)
            } else {
                WorldSpriteView(sprite: theme.icon(for: panel), scale: theme.scale(accessibilitySize: dynamicTypeSize.isAccessibilitySize))
                plateText(plateTitle)
            }
            Spacer(minLength: 8)
            if closesWithDone {
                WorldDoneButton(action: onClose)
            } else {
                // A pushed page holding unsaved work (the Creation Studio's paint) asks first.
                // Off while a page holds the panel (Delete everything's wipe is running).
                WorldCloseButton { if navigation.allowsClose() { onClose() } }
                    .disabled(navigation.isHeld)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 13, trailing: 12))
        .background {
            appColors.wood.tones.wood
                .overlay(alignment: .bottom) { appColors.wood.tones.low.frame(height: 4).padding(.bottom, 3) }
                .overlay(alignment: .bottom) { WorldPalette.ink.frame(height: 3) }
                .ignoresSafeArea(edges: .top)
        }
        .background(alignment: .bottom) {
            Color(.sRGB, red: 40 / 255, green: 20 / 255, blue: 8 / 255, opacity: 0.18).frame(height: 3).offset(y: 3)
        }
        .zIndex(1)
    }

    /// The plate's title (Fraunces 25): one line, or up to three at accessibility sizes, where it wraps rather
    /// than shrinks (`b1-frame-push`'s accessibility note).
    private func plateText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(WorldType.plateTitle)
            .foregroundStyle(appColors.wood.tones.label)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.7)
            // The approved largest-text plate draws its title at 31 pt, not the full accessibility size,
            // so a one-word title ("Appearance") never breaks inside the word.
            .dynamicTypeSize(...WorldType.plateTitleCap)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($isTitleFocused)
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

/// A World page: parchment with a faint dot grid every 14 pt (design language, "Pages"), in the World
/// palette whatever the environment says. FernletUI's ``FernletDottedPage`` draws it.
struct WorldPageBackground: View {
    var body: some View {
        FernletDottedPage()
            .environment(\.fernletFramedLook, WorldTheme.framedLook)
    }
}

import FernletUI
import SwiftUI
import WorldMapStore

/// The full-screen world view (World-Exploration-Spec §2, `ex-world` draft 3 and `ex-world-zoom` draft 2),
/// opened from page 2 of Sprout's passport (World-Passport-Spec §5): the world map edge to edge under the
/// status bar, with **‹ Passport** (top left, `onBack`: back to the passport's world page), the title
/// **Your world** and **✕** (top right, `onClose`) floating on it as framed chips, and the plate under them.
///
/// At the largest Dynamic Type the chips wrap onto two rows (the title under ‹ Passport and ✕) and never clip.
struct WorldYourWorldPage: View {
    /// Where the map's data comes from.
    let source: WorldAtlasMapView.Source
    /// The level it opens at.
    var initialLevel: AtlasZoomLevel = .world
    /// Where it opens; nil opens on home.
    var initialCentre: GeoPoint?
    /// ‹ Passport: back to the passport's world page.
    let onBack: () -> Void
    /// ✕: closes the passport.
    let onClose: () -> Void
    /// A city marker tapped at City (its frozen token): the city view, wired by the lane.
    var onOpenCity: (String) -> Void = { _ in }

    /// The chips' measured height, so the plate sits under them however they wrap (the mockup: the 44-pt bar
    /// 4 pt under the status bar, the plate 14 pt under the bar).
    @State private var barHeight: CGFloat = 44

    var body: some View {
        GeometryReader { outer in
            ZStack(alignment: .top) {
                WorldAtlasMapView(source: source, initialLevel: initialLevel, initialCentre: initialCentre,
                                  chromeInsets: EdgeInsets(top: outer.safeAreaInsets.top + barHeight + 18, leading: 14,
                                                           bottom: outer.safeAreaInsets.bottom + 186, trailing: 14),
                                  onOpenCity: onOpenCity)
                    .ignoresSafeArea()
                WorldYourWorldBar(onBack: onBack, onClose: onClose)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
        }
        .uxScreenAnchor("screen.worldView")
    }
}

/// The page's floating chips: ‹ Passport, the title and ✕ on one row, or ‹ Passport and ✕ above the title when
/// the words don't fit.
struct WorldYourWorldBar: View {
    let onBack: () -> Void
    let onClose: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                backChip
                Spacer(minLength: 0)
                titleChip.fixedSize()
                Spacer(minLength: 0)
                closeChip
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    backChip
                    Spacer(minLength: 8)
                    closeChip
                }
                titleChip
            }
        }
    }

    /// ‹ Passport.
    private var backChip: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                WorldSpriteView(sprite: WorldSprites.chevL, scale: 2, tint: WorldViewInk.text)
                Text(WorldViewCopy.back)
                    .font(.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
                    .fixedSize()
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(minWidth: 44, minHeight: 44)
            .worldAtlasChip(cornerRadius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(WorldViewCopy.backSpoken))
        .accessibilityInputLabels([Text(WorldViewCopy.back), Text(WorldViewCopy.backSpoken)])
        .accessibilityIdentifier("worldView.back")
    }

    /// The title, "Your world".
    private var titleChip: some View {
        Text(WorldViewCopy.title)
            .font(.custom(FernletFontName.dmSansBold, size: 16, relativeTo: .headline))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .worldAtlasChip(cornerRadius: 10)
            .accessibilityAddTraits(.isHeader)
    }

    /// ✕.
    private var closeChip: some View {
        Button(action: onClose) {
            WorldSpriteView(sprite: WorldSprites.xx, scale: 3, tint: WorldViewInk.text)
                .frame(width: 44, height: 44)
                .worldAtlasChip(cornerRadius: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(WorldCloseButton.label))
        .accessibilityInputLabels([Text(WorldCloseButton.label)])
        .accessibilityIdentifier("worldView.close")
    }
}

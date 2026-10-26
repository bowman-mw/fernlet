import FernletDomainModel
import FernletUI
import SwiftUI

/// Home with location off (design `b1-home-denied`, draft 4, approved 2026-10-24): no map and no "map is
/// off" card. The date, the companion's name and the four photos sit on top, as on today's Home; the
/// companion stands in an open sky-and-grass scene that runs to the screen's edges, with no frame; the
/// status plate sits below it, a little larger, and opens Today. There's no blue button (nothing on Home
/// asks for location; Settings → Home map still says it is off).
///
/// The scene is decoration: VoiceOver reads the date and name, the photos, the companion, the status
/// plate and the item bar.
struct WorldOffMapHome<Companion: View>: View {
    var store: FernletStore
    let date: Date
    let status: WorldStatus
    let onOpen: (WorldPanel) -> Void
    /// A print on the photo wall: its photo in the Album (`ref-wall-photo`), or the Album (nil).
    let onOpenPrint: (FriendsRoute?) -> Void
    @ViewBuilder let companion: () -> Companion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
            WorldPhotoPrints(store: store, arrangement: .row(compact: large), onOpen: onOpenPrint)
                .padding(.leading, 14)
                .padding(.top, 8)
            scene(large: large)
            WorldStatusPlate(status: status) { onOpen(.today) }
                .scaleEffect(large ? 1 : 1.22, anchor: .top)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .background { WorldPalette.page.ignoresSafeArea() }
    }

    /// The date (a section label with its moss square) and the companion's name in Fraunces.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(verbatim: date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            Text(verbatim: companionName)
                .font(Font.custom(FernletFontName.frauncesSemiBold, size: 40, relativeTo: .largeTitle))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
        }
        // The date and name grow to the first accessibility size, so the scene keeps its room.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// The open scene: sky fading in from the page, the companion and its bubble, grass to the edges.
    private func scene(large: Bool) -> some View {
        ZStack(alignment: .bottom) {
            LinearGradient(stops: [.init(color: WorldOffScenePalette.sky.opacity(0), location: 0),
                                   .init(color: WorldOffScenePalette.sky.opacity(0.75), location: 0.3),
                                   .init(color: WorldOffScenePalette.skyLow, location: 0.72)],
                           startPoint: .top, endPoint: .bottom)
            WorldGrassBand()
                .frame(height: 92)
            companion()
                .padding(.bottom, 66)
        }
        .frame(height: large ? 250 : 330)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
    }

    /// The companion's own name, or Fernlet.
    private var companionName: String {
        let chosen = store.settings.companionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? "Fernlet" : chosen
    }
}

/// The open scene's colours (the approved draft 4's sky and grass), deeper in dark mode.
nonisolated enum WorldOffScenePalette {
    static let sky = WorldPalette.adaptive(light: 0xBFE0EC, dark: 0x2B4250)
    static let skyLow = WorldPalette.adaptive(light: 0xDCEDE6, dark: 0x23352F)
    static let grass = WorldPalette.adaptive(light: 0x9BC27F, dark: 0x4F6E43)
    static let grassLight = WorldPalette.adaptive(light: 0xB5D69A, dark: 0x6B8C5A)
    static let tuft = WorldPalette.adaptive(light: 0x6E9A55, dark: 0x3F5C35)
}

/// The grass along the scene's foot: a light lip, pixel tufts, fading out at the bottom.
struct WorldGrassBand: View {
    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 18
            context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: size.height - top)),
                         with: .linearGradient(Gradient(stops: [.init(color: WorldOffScenePalette.grass, location: 0),
                                                                 .init(color: WorldOffScenePalette.grass, location: 0.7),
                                                                 .init(color: WorldOffScenePalette.grass.opacity(0), location: 1)]),
                                               startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: size.height)))
            context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: 5)), with: .color(WorldOffScenePalette.grassLight))
            let tufts = min(Int(size.width / 21) + 1, 40)
            for index in 0..<tufts {
                let x = CGFloat(index * 21 + (index % 3) * 4)
                let height = CGFloat(5 + (index % 2) * 3)
                context.fill(Path(CGRect(x: x, y: top - CGFloat(index % 2) * 3 - height + 10, width: 6, height: height)),
                             with: .color(WorldOffScenePalette.tuft))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

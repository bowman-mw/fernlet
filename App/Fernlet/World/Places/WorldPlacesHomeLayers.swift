import FernletUI
import SwiftUI
import WorldMapStore

/// Round 6 on Home's map, behind the companion (approved 2026-10-25): Sprout's house at each home
/// (`ref-home-arrive`, its windows glowing at night, `ref-home-night`) and the hotel of the stay
/// (`ref-hotel`). None in a decoy.
struct WorldHomesLayer: View {
    var store: FernletStore
    let viewport: MapViewport
    let size: CGSize
    let isNight: Bool

    var body: some View {
        let offset = WorldPlaceSprites.baseOffset(scale: 4)
        ZStack(alignment: .topLeading) {
            ForEach(store.worldHomes.bases) { place in
                let at = viewport.screenPoint(for: place.point, in: size)
                WorldHomeMarkerView(place: place, isNight: isNight, companion: store.worldCompanionName)
                    .fixedSize()
                    .position(x: at.x + offset.width, y: at.y + offset.height)
            }
        }
    }
}

/// Beside the companion (its feet on `point`): Sprout's suitcase while a hotel stay goes on (`ref-hotel`),
/// and the z's when it sleeps by its house at bedtime at home (`ref-home-night`). None in a decoy.
struct WorldCompanionExtras: View {
    var store: FernletStore
    let point: CGPoint
    let date: Date

    var body: some View {
        let book = store.worldHomes
        ZStack(alignment: .topLeading) {
            if book.hotel != nil {
                WorldSuitcaseView(companion: store.worldCompanionName)
                    .fixedSize()
                    .position(x: point.x + 34, y: point.y - 10)
            }
            if isAsleepAtHome(book) {
                WorldSleepZees(companion: store.worldCompanionName)
                    .position(x: point.x + 40, y: point.y - 62)
            }
        }
    }

    /// Whether the person is at one of their homes past the companion's bedtime.
    private func isAsleepAtHome(_ book: HomeBook) -> Bool {
        guard let at = book.presence.atID, book.homes.contains(where: { $0.id == at }) else { return false }
        if WorldPlacesTestScenes.scenes.contains("asleep") { return true }
        return WorldMapCompanion.isPastBedtime(store: store, at: date)
    }
}

/// "Remember this place" (`ref-tag-home` draft 2, round 7): the quiet framed chip beside the blue button,
/// a pixel pin and the words, with a small ✕ ("Not here") on its right, while the person has stayed more
/// than 2 minutes somewhere that isn't a home, a hotel or a place they keep. No banner, sound, haptic or
/// announcement when it appears. VoiceOver: "Remember this place, button" and "Not here, button". At the
/// largest text the words grow to about 18 pt and the ✕ is 44 pt wide; it is a 44-pt target always.
struct WorldTagPlaceButton: View {
    let onRemember: () -> Void
    let onNotHere: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onRemember) { rememberLabel }
                .buttonStyle(.plain)
                .accessibilityIdentifier("world.rememberPlace")
            Rectangle().fill(WorldPalette.ink).frame(width: 2).accessibilityHidden(true)
            Button(action: onNotHere) {
                WorldSpriteView(sprite: WorldSprites.xx, scale: 2)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 44 : 34)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(WorldHomeCopy.notHere))
            .accessibilityIdentifier("world.rememberPlace.notHere")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 44)
        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    /// The pin and "Remember this place".
    private var rememberLabel: some View {
        HStack(spacing: 6) {
            WorldSpriteView(sprite: WorldSprites.pin, scale: 2)
                .accessibilityHidden(true)
            Text(WorldHomeCopy.rememberButton)
                .font(Font.custom(FernletFontName.dmSansBold, size: 14, relativeTo: .subheadline))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(WorldPalette.bark)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A menu search to open from the blue button (`b1-qs-food`'s "Find …'s menu"): the meal sheet's seed.
struct WorldMenuSearch: Identifiable {
    let id = UUID()
    let seed: MealSheetSeed
}

/// Presents round 6's sheets over Home: the Remember this place sheet (`ref-tag-name`, `ref-home-set`) and
/// the meal sheet a menu search opens, whose logged meal reaches the toast.
struct WorldPlacesPresenter: ViewModifier {
    var store: FernletStore
    @Binding var placeSheet: WorldPlaceSheetMode?
    @Binding var menuSearch: WorldMenuSearch?
    let onMealsLogged: MealLogReporter

    func body(content: Content) -> some View {
        content
            .sheet(item: $placeSheet) { mode in
                WorldRememberPlaceSheet(store: store, mode: mode) { placeSheet = nil }
            }
            .sheet(item: $menuSearch) { search in
                // The meal sheet's own reporter: a meal it logs lands on the toast once it closes.
                MealSheet(store: store, onLogged: onMealsLogged, seed: search.seed)
                    .fernletSheetChrome(anchor: "sheet.meal", detents: [.large])
            }
    }
}

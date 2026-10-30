import FernletUI
import SwiftUI
import WorldMapStore

/// A found city's card (`ex-city-card`).
struct WorldCityCardModel: Identifiable, Equatable {
    let city: AtlasCity
    /// The passport's first visit there.
    let discoveredAt: Date
    var id: String { city.token }
}

/// Zoomed out a step (`ex-zoomed`): each of the passport's cities near the view as its skyline in a cream frame,
/// the name on a plate under it, standing on the city's point. Each is a button that opens the city card
/// ("Portland, City, button").
struct WorldCityMarkersLayer: View {
    let explore: WorldExploreState
    let cities: [AtlasCity]
    let viewport: MapViewport
    let size: CGSize
    let book: PassportBook
    let list: WorldLandmarks

    var body: some View {
        ForEach(cities, id: \.token) { city in
            let point = viewport.screenPoint(for: city.point, in: size)
            if WorldExploreSelection.isOnScreen(point, size: size) {
                WorldCityMarker(city: city) { open(city) }
                    .fixedSize()
                    .frame(width: 0, height: 0, alignment: .bottom)
                    .position(point)
            }
        }
    }

    /// Opens `city`'s card (its first visit from the passport).
    private func open(_ city: AtlasCity) {
        guard let date = book.firstVisit(.city, token: city.token) else { return }
        explore.openCity = WorldCityCardModel(city: city, discoveredAt: date)
    }
}

/// One city's marker (the mockup's `cityMarker`, `.excity`): the class's skyline at one point per pixel in a
/// cream frame with a 2-pt ink edge and a small drop shadow, and the name on a plate.
struct WorldCityMarker: View {
    let city: AtlasCity
    let onOpen: () -> Void

    var body: some View {
        let sizeClass = WorldCitySizeClass(city: city)
        let name = WorldExploreCopy.name(of: city)
        Button(action: onOpen) {
            VStack(spacing: 2) {
                WorldCitySkyline(sizeClass: sizeClass, scale: 1)
                    .padding(EdgeInsets(top: 3, leading: 4, bottom: 2, trailing: 4))
                    .background {
                        // The frame's own drop shadow, never the skyline's pixels.
                        RoundedRectangle(cornerRadius: 6).fill(WorldPalette.rgb(0xFFF6E2))
                            .shadow(color: WorldPalette.rgb(0x281408).opacity(0.25), radius: 0, x: 0, y: 2)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorldPalette.rgb(0x4A2E1C), lineWidth: 2))
                WorldMapPlate(text: name)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: WorldExploreCopy.cityMarkerSpoken(name: name, sizeName: String(localized: sizeClass.title))))
        .accessibilityInputLabels([Text(verbatim: name)])
        .accessibilityIdentifier("world.city.marker")
    }
}

/// A name on a cream plate in a 2-pt ink frame (the mockup's `.excity b`): DM Sans bold 12, as on the map in both
/// modes.
struct WorldMapPlate: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(FernletFramedFont.tag)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(WorldPalette.rgb(0x3A2414))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(WorldPalette.rgb(0xFFF6E2), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(WorldPalette.rgb(0x4A2E1C), lineWidth: 2))
    }
}

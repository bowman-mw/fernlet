import FernletUI
import SwiftUI
import WorldMapStore

/// A found city's card (`ex-city-card`, World-Exploration-Spec §2): a full-height sheet with Done top right; the
/// name, its size class and country; its skyline (decoration); when it was discovered; its landmarks found of its
/// list, found ones as small icons with their names and the rest as question marks, never named; and how much of
/// the major roads crossed inside it (derived from the lifted fog, ``WorldCityUncovered/roadsCrossed(in:lifted:atlas:)``);
/// how much of the city the person has uncovered. Kept on this iPhone only (the passport and the fog are device-only
/// data).
///
/// Not drawn: the discovered row's "On a walk," (the passport keeps the date, not how).
struct WorldCityCard: View {
    let store: FernletStore
    let model: WorldCityCardModel
    let explore: WorldExploreState
    @State private var share: Double?
    @State private var roadsCrossed: Int?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WorldCitySkylineBox(sizeClass: sizeClass)
                FernletFramedSection(header: nil) { rows }
                if !landmarks.isEmpty { landmarkList }
                Text("Kept on this iPhone only, like Where you've been.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 34)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text(verbatim: WorldExploreCopy.name(of: model.city)),
                        subtitle: Text(verbatim: subtitle), onDone: { dismiss() })
        }
        .fernletSheet()
        .task { await readShare() }
        .task { await readRoads() }
        .accessibilityIdentifier("world.city.card")
    }

    /// The rows: discovered, landmarks found (when the city has a list), major roads crossed, uncovered.
    @ViewBuilder private var rows: some View {
        FernletKeyValueRow("Discovered", value: Text(verbatim: WorldExploreCopy.discovered(model.discoveredAt)), showsRule: false)
        if !landmarks.isEmpty {
            FernletKeyValueRow("Landmarks", value: Text(verbatim: WorldExploreCopy.landmarksFound(found.count, of: landmarks.count)), showsRule: false)
        }
        FernletKeyValueRow("Major roads crossed", value: Text(verbatim: roadsCrossed.map { WorldExploreCopy.roadsCrossed($0) } ?? "…"),
                           showsRule: false)
        FernletKeyValueRow("Uncovered", value: Text(verbatim: share.map { WorldExploreCopy.uncovered($0) } ?? "…"), showsRule: false)
    }

    /// The found landmarks as small icons with their names, then a question mark for each one not found yet.
    private var landmarkList: some View {
        FlowLayout(spacing: 10) {
            ForEach(found, id: \.token) { landmark in
                WorldLandmarkBadge(landmark: landmark, images: explore.images, dark: colorScheme == .dark)
            }
            ForEach(0..<max(landmarks.count - found.count, 0), id: \.self) { _ in
                WorldLandmarkQuestionMark()
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .overlay(alignment: .bottomLeading) {
            if landmarks.count > found.count {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: WorldExploreCopy.moreNotFound(landmarks.count - found.count)))
            }
        }
    }

    private var sizeClass: WorldCitySizeClass { WorldCitySizeClass(city: model.city) }

    /// "City · United States".
    private var subtitle: String {
        WorldExploreCopy.cityKind(sizeName: String(localized: sizeClass.title),
                                  country: WorldExploreCopy.country(code: model.city.countryCode))
    }

    /// The city's landmark list.
    private var landmarks: [AtlasLandmark] { store.worldFog.atlas.landmarks.landmarks(inCity: model.city.token) }

    /// The ones the passport holds.
    private var found: [AtlasLandmark] {
        WorldExploreState.book(store).foundLandmarks(inCity: model.city.token, of: store.worldFog.atlas.landmarks)
    }

    /// Works the uncovered share out (off the main actor, kept per city).
    private func readShare() async {
        guard let atlas = store.worldFog.atlas.openedAtlas else {
            share = 0
            return
        }
        share = await explore.uncovered.share(of: model.city, in: atlas, lifted: store.worldRoadCells)
    }

    /// Counts the major roads crossed inside the city (off the main actor, kept per city).
    private func readRoads() async {
        guard let atlas = store.worldFog.atlas.openedAtlas else {
            roadsCrossed = 0
            return
        }
        roadsCrossed = await explore.uncovered.roadsCrossed(in: model.city, atlas: atlas, lifted: store.worldRoadCells)
    }
}

/// The card's skyline (the mockup's `.exsh-sky`): the class's skyline at 4 points per pixel on a sky in a 2-pt ink
/// frame. Decoration.
struct WorldCitySkylineBox: View {
    let sizeClass: WorldCitySizeClass
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WorldCitySkyline(sizeClass: sizeClass, scale: 4)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .background(sky, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    private var sky: LinearGradient {
        let colours = colorScheme == .dark ? [0x2E3A4A, 0x3A3328] : [0xCFE3EE, 0xF3EAD6]
        return LinearGradient(colors: colours.map { WorldPalette.rgb(UInt32($0)) }, startPoint: .top, endPoint: .bottom)
    }
}

/// A found landmark in the city card's list (the mockup's `landmark()`, `.exland`): its art small on a gold-edged
/// cream tile, its name on a plate under it. One element: its name.
struct WorldLandmarkBadge: View {
    let landmark: AtlasLandmark
    let images: WorldLandmarkImages
    let dark: Bool

    var body: some View {
        let name = WorldExploreCopy.name(of: landmark)
        VStack(spacing: 2) {
            Group {
                if let image = images.image(for: landmark, look: WorldLandmarkLook(found: true, dark: dark, halo: false)) {
                    WorldLandmarkArtView(image: image, scale: Self.scale(image))
                }
            }
            .frame(minWidth: 30, minHeight: 30)
            .padding(3)
            .background(WorldPalette.rgb(0xFFF1C9), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.rgb(0x8A5F14), lineWidth: 2))
            .padding(2)
            .background(WorldPalette.rgb(0xF2D58A), in: RoundedRectangle(cornerRadius: 10))
            WorldMapPlate(text: name)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
    }

    /// Points per art pixel in the badge: 2 for art up to 16 pixels on its longer side, else 1.
    static func scale(_ image: CGImage) -> CGFloat {
        max(image.width, image.height) <= 16 ? 2 : 1
    }
}

/// A landmark not found yet in the city card's list (the mockup's `.exq`): a dashed square with a question mark.
struct WorldLandmarkQuestionMark: View {
    var body: some View {
        Text(verbatim: "?")
            .font(FernletFramedFont.bodyBold)
            .foregroundStyle(WorldPalette.dim)
            .frame(width: 30, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(WorldPalette.dim.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
            .padding(.top, 5)
            .accessibilityHidden(true)
    }
}

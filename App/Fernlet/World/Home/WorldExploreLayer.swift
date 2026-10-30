import FernletUI
import SwiftUI
import WorldMapStore

/// Home's cities and landmarks (World-Exploration-Spec §2, `ex-zoomed`, `ex-landmark`, `ex-city-view`): what the
/// layer and its sheets share, held by Home for the session. The opened card is observed; the memo, the art's
/// images and the uncovered shares are not (writing them redraws nothing).
@MainActor
@Observable
final class WorldExploreState {
    /// The found landmark whose card is open over the map, if any.
    var openLandmark: WorldLandmarkCardModel?
    /// The found city whose card sheet is open, if any.
    var openCity: WorldCityCardModel?
    /// The viewport's answers, from memory while the map stays near.
    @ObservationIgnored let memo = WorldExploreMemo()
    /// The landmark art and its images, opened on first use.
    @ObservationIgnored let images = WorldLandmarkImages()
    /// Each city's uncovered share, worked out off the main actor and kept (``WorldCityUncovered``).
    @ObservationIgnored let uncovered = WorldCityUncoveredCache()
    /// Called once for each landmark the passport finds while Home is up, with the landmark. **Unattached on
    /// purpose:** Sprout's landmark line (World-Exploration-Spec §4, lines 46–48) comes from the passport's discovery
    /// stream through ``WorldDiscoveryRouter``, the one source, so a landmark's line plays once; nothing listens here.
    @ObservationIgnored var onLandmarkFound: (AtlasLandmark) -> Void = { _ in }
    /// The landmark tokens found when Home last looked, so a new find is told apart (nil before the first look).
    @ObservationIgnored var knownFound: Set<String>?

    /// The passport Home draws from: the person's (an empty one in a decoy), or the DEBUG demo passport a
    /// screenshot asks for (never in a decoy; in memory only, nothing is written).
    static func book(_ store: FernletStore) -> PassportBook {
        let real = store.worldFog.atlas.book
        guard !store.duressSessionActive, let demo = UITestSupport.exploreDemoBook(atlas: store.worldFog.atlas) else { return real }
        return demo
    }

    /// The card for `landmark`, found on `date`.
    func card(for landmark: AtlasLandmark, foundAt date: Date, atlas: WorldAtlas?) -> WorldLandmarkCardModel {
        let city = atlas?.city(token: landmark.cityToken).map { WorldExploreCopy.name(of: $0) }
        return WorldLandmarkCardModel(landmark: landmark, cityName: city, foundAt: date)
    }

    /// Tells the seam about each landmark found since Home last looked (only finds dated within ``freshFind``
    /// of `now`, so a restored or demo passport's old finds never speak). The first look only remembers.
    func noteFinds(in book: PassportBook, list: WorldLandmarks, isDecoy: Bool, now: Date = Date()) {
        let found = Set(book.visits(of: .landmark).keys)
        defer { knownFound = found }
        guard !isDecoy, let knownFound else { return }
        // Bounded: the new tokens, at most the passport's landmark cap.
        for token in found.subtracting(knownFound).sorted().prefix(PassportBook.cap(for: .landmark)) {
            guard let date = book.firstVisit(.landmark, token: token), now.timeIntervalSince(date) <= Self.freshFind,
                  let landmark = list.landmark(token: token) else { continue }
            onLandmarkFound(landmark)
        }
    }

    /// How recent a find must be to count as found just now, in seconds.
    static let freshFind: TimeInterval = 120
}

/// A found landmark's card (`ex-landmark`, "the landmark card as approved").
struct WorldLandmarkCardModel: Identifiable, Equatable {
    let landmark: AtlasLandmark
    /// Its city's name, when the atlas has the city.
    let cityName: String?
    /// When the passport found it.
    let foundAt: Date
    var id: String { landmark.token }
}

/// What Home lays over the fog for cities and landmarks: the landmarks near the view, big, grey and unnamed until
/// found; zoomed out a step, the passport's cities as framed skylines with their names; zoomed in on a found
/// city, the city view's plate. Placed from the viewport each frame, read from ``WorldExploreMemo``.
struct WorldExploreLayer: View {
    let store: FernletStore
    let explore: WorldExploreState
    let viewport: MapViewport
    let size: CGSize
    /// Whether the city view's plate may show (nothing else at the bottom centre: no walk bar or note).
    var showsCityPlate = true
    /// Where Sprout's feet stand on the screen: a found landmark's name plate that Sprout would cover moves below
    /// Sprout's feet (``WorldLandmarkPlateRule``), clear of the bubble above. Nil leaves every plate under its art.
    var companion: CGPoint? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let book = WorldExploreState.book(store)
        let atlas = store.worldFog.atlas.openedAtlas
        let zoomedOut = WorldExploreSelection.isZoomedOut(viewport)
        ZStack(alignment: .topLeading) {
            ForEach(placedLandmarks(book: book)) { placed in
                let aside = placed.look.found
                    && companion.map { WorldLandmarkPlateRule.sproutCovers(plate: placed.name, at: placed.point, feet: $0) } == true
                WorldBigLandmarkView(placed: placed, image: explore.images.image(for: placed.landmark, look: placed.look),
                                     scale: explore.images.mapScale(for: placed.landmark), showsPlate: !aside) {
                    open(placed.landmark, book: book, atlas: atlas)
                }
                .fixedSize()
                .frame(width: 0, height: 0, alignment: .bottom)
                .position(placed.point)
                if aside, let feet = companion {
                    // The name, readable below Sprout's feet (the button above still names it to VoiceOver).
                    WorldGoldPlate(text: placed.name)
                        .fixedSize()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .position(WorldLandmarkPlateRule.belowFeet(feet, landmark: placed.point, size: size))
                }
            }
            if zoomedOut, let atlas {
                WorldCityMarkersLayer(explore: explore, cities: explore.memo.cities(in: book, atlas: atlas, near: viewport, size: size),
                                      viewport: viewport, size: size, book: book, list: store.worldFog.atlas.landmarks)
            } else if showsCityPlate, let atlas, let city = explore.memo.foundCity(at: viewport.center, atlas: atlas, book: book) {
                WorldCityViewPlate(text: plate(for: city, book: book))
                    .frame(maxWidth: size.width - 32)
                    .position(x: size.width / 2, y: size.height - WorldCityViewPlate.bottomOffset)
            }
        }
    }

    /// The landmarks near the view that fall on the screen, north first, so a southern one overlaps a northern.
    private func placedLandmarks(book: PassportBook) -> [WorldPlacedLandmark] {
        let list = store.worldFog.atlas.landmarks
        let dark = colorScheme == .dark
        return explore.memo.landmarks(in: list, near: viewport, size: size).compactMap { landmark in
            let point = viewport.screenPoint(for: landmark.point, in: size)
            guard WorldExploreSelection.isOnScreen(point, size: size) else { return nil }
            let found = book.isFound(landmark)
            return WorldPlacedLandmark(landmark: landmark, point: point, look: WorldLandmarkLook(found: found, dark: dark),
                                       name: WorldExploreCopy.name(of: landmark))
        }
        .sorted { ($0.point.y, $0.landmark.token) < ($1.point.y, $1.landmark.token) }
    }

    /// Opens a found landmark's card (an unfound one is not a button).
    private func open(_ landmark: AtlasLandmark, book: PassportBook, atlas: WorldAtlas?) {
        guard let date = book.firstVisit(.landmark, token: landmark.token) else { return }
        explore.openLandmark = explore.card(for: landmark, foundAt: date, atlas: atlas)
    }

    /// "Portland · 2 of 6 landmarks".
    private func plate(for city: AtlasCity, book: PassportBook) -> String {
        let list = store.worldFog.atlas.landmarks
        return WorldExploreCopy.cityPlate(city: WorldExploreCopy.name(of: city),
                                          found: book.foundLandmarkCount(inCity: city.token, of: list),
                                          total: list.landmarks(inCity: city.token).count)
    }
}

/// One landmark placed on the screen.
struct WorldPlacedLandmark: Identifiable {
    let landmark: AtlasLandmark
    /// Its point on the screen (the art's foot).
    let point: CGPoint
    let look: WorldLandmarkLook
    /// Its name in the app's language (shown only once found).
    let name: String
    var id: String { landmark.token }
}

/// A landmark drawn big on the map (`ex-zoomed`, the mockup's `bigLand`): the art at the map scale with its
/// one-pixel halo and a small drop shadow; found, its name on a cream plate with a gold rim under it. Found, it
/// is a button that opens its card ("Eiffel Tower, landmark, found"); not found, one element, "Landmark, not
/// found yet", that lets the map's pans through.
struct WorldBigLandmarkView: View {
    let placed: WorldPlacedLandmark
    let image: CGImage?
    let scale: CGFloat
    /// Whether the found name plate sits under the art (false: the layer draws it below Sprout's feet instead).
    var showsPlate = true
    let onOpen: () -> Void

    var body: some View {
        if placed.look.found {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: WorldExploreCopy.spoken(placed.landmark, found: true)))
                .accessibilityInputLabels([Text(verbatim: placed.name)])
                .accessibilityIdentifier("world.landmark.found")
        } else {
            content
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(WorldExploreCopy.notFound))
                .accessibilityIdentifier("world.landmark.notFound")
        }
    }

    private var content: some View {
        VStack(spacing: 3) {
            if let image {
                WorldLandmarkArtView(image: image, scale: scale)
                    .shadow(color: WorldPalette.rgb(0x281408).opacity(0.3), radius: 0, x: 0, y: 2)
            }
            if placed.look.found { WorldGoldPlate(text: placed.name).opacity(showsPlate ? 1 : 0) }
        }
    }
}

/// Where a found landmark's name plate goes when Sprout stands on the landmark (shots: Laurelhurst Park's plate hid
/// behind Sprout). The plate normally sits under the art, its bottom on the landmark's point; Sprout's sprite stands
/// with its feet on the person's point and its bubble above. When the two overlap, the plate moves below Sprout's
/// feet (under its shadow), where neither the sprite nor the bubble reaches. Estimates in points, from the map's
/// sprite (about 44 pt square at the map's scale) and the plate's DM Sans bold 12.
nonisolated enum WorldLandmarkPlateRule {
    /// Half Sprout's width round its feet, with a little room.
    static let sproutHalfWidth: CGFloat = 28
    /// How far Sprout's sprite reaches above its feet.
    static let sproutHeight: CGFloat = 52
    /// How far its shadow reaches below its feet.
    static let shadowDrop: CGFloat = 8
    /// The plate's height (12 pt type, its padding, the gold rim).
    static let plateHeight: CGFloat = 24
    /// The gap between Sprout's shadow and the moved plate's top.
    static let gapBelow: CGFloat = 4

    /// The plate's estimated width for `name`: about 7 pt a character plus its padding and rims.
    static func plateWidth(_ name: String) -> CGFloat {
        CGFloat(min(name.count, 60)) * 7 + 18
    }

    /// The plate's rectangle under its art: centred on the landmark's x, its bottom on the landmark's point.
    static func plateRect(name: String, at point: CGPoint) -> CGRect {
        let width = plateWidth(name)
        return CGRect(x: point.x - width / 2, y: point.y - plateHeight, width: width, height: plateHeight)
    }

    /// Sprout's rectangle: the sprite above its feet and the shadow under them.
    static func sproutRect(feet: CGPoint) -> CGRect {
        CGRect(x: feet.x - sproutHalfWidth, y: feet.y - sproutHeight, width: sproutHalfWidth * 2, height: sproutHeight + shadowDrop)
    }

    /// Whether Sprout, standing at `feet`, covers the plate `name` of the landmark at `point`.
    static func sproutCovers(plate name: String, at point: CGPoint, feet: CGPoint) -> Bool {
        plateRect(name: name, at: point).intersects(sproutRect(feet: feet))
    }

    /// The moved plate's centre: the landmark's x (kept on the screen), just under Sprout's shadow.
    static func belowFeet(_ feet: CGPoint, landmark: CGPoint, size: CGSize) -> CGPoint {
        let y = feet.y + shadowDrop + gapBelow + plateHeight / 2
        return CGPoint(x: min(max(landmark.x, 60), max(size.width - 60, 60)), y: y)
    }
}

/// A name on a cream plate in an ink frame with a gold rim (the mockup's `.exbig b`): DM Sans bold 12, the same in
/// light and dark, as the mockup draws it on the map.
struct WorldGoldPlate: View {
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
            .padding(2)
            .background(WorldPalette.rgb(0xF2D58A), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// The city view's plate (`ex-city-view`, the mockup's `.exzoom`): "Portland · 2 of 6 landmarks", bottom centre
/// above the blue button's row, DM Sans bold 13 on cream in a 2-pt ink frame. Static text to VoiceOver.
struct WorldCityViewPlate: View {
    let text: String
    /// Its centre's height above the screen's bottom edge (the mockup: its bottom 168 pt up on an 874-pt phone).
    static let bottomOffset: CGFloat = 182

    var body: some View {
        Text(verbatim: text)
            .font(Font.custom(FernletFontName.dmSansBold, size: 13, relativeTo: .footnote))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .foregroundStyle(WorldPalette.rgb(0x3A2414))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(WorldPalette.rgb(0xFFF6E2), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.rgb(0x4A2E1C), lineWidth: 2))
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
            .accessibilityIdentifier("world.cityView.plate")
    }
}

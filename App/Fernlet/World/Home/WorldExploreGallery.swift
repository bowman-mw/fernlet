#if DEBUG
import FernletUI
import SwiftUI
import WorldMapStore

/// DEBUG-only: the cities-and-landmarks art on boards, for the `ex-skylines`, `ex-landmark`, `ex-colosseum` and
/// `ex-fam-1`…`ex-fam-4` screenshots (`FERNLET_UI_TEST_EXPLORE=gallery:<board>`). `skylines`: the five skylines
/// with their classes and a marker of each; `famous0`: the first four famous landmarks and the six generic icons;
/// `famous1`…`famous4`: the 24 more, six to a board. Each landmark is drawn at its map scale with its halo, found
/// beside not found, on fog-coloured ground. Its words are verbatim DEBUG copy, never harvested into a catalog;
/// absent from Release builds (a stub stands in).
struct WorldExploreGallery: View {
    let scene: String
    let images: WorldLandmarkImages
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if scene == "skylines" { skylines } else { landmarks }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text(verbatim: title), onDone: { dismiss() })
        }
        .fernletSheet()
    }

    private var title: String {
        scene == "skylines" ? "A skyline per size class" : "Landmarks · \(scene)"
    }

    /// The five classes: the skyline at 2 points per pixel, the class, the mockup's range and example, and the
    /// class's map marker.
    private var skylines: some View {
        ForEach(WorldCitySizeClass.allCases, id: \.self) { sizeClass in
            HStack(spacing: 12) {
                WorldCitySkyline(sizeClass: sizeClass, scale: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(sizeClass.title).font(FernletFramedFont.rowTitleBold).foregroundStyle(WorldPalette.bark)
                    Text(verbatim: Self.ranges[sizeClass.rank]).font(FernletFramedFont.note).foregroundStyle(WorldPalette.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorldPalette.ink, lineWidth: 2))
        }
    }

    /// The mockup's `CLASS` ranges and examples.
    static let ranges = ["Under 20,000 people · Hood River", "20,000 to 100,000 · Astoria", "100,000 to 1 million · Portland",
                         "1 to 10 million · Seattle", "Over 10 million · Tokyo"]

    private var landmarks: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Self.board(scene), id: \.self) { key in
                VStack(spacing: 6) {
                    HStack(alignment: .bottom, spacing: 6) {
                        art(key, found: false)
                        art(key, found: true)
                    }
                    Text(verbatim: key).font(FernletFramedFont.noteBold).foregroundStyle(WorldPalette.bark)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding(6)
                .background(colorScheme == .dark ? WorldPalette.nightFog : WorldPalette.fog, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
            }
        }
    }

    /// One sprite at its map scale (3, or 3.5 for a generic icon), shrunk to fit the half-width tile.
    private func art(_ key: String, found: Bool) -> some View {
        let tier: AtlasLandmarkTier = AtlasLandmarkKind(rawValue: key).map { .generic($0) } ?? .famous(artID: key)
        let scale: CGFloat = AtlasLandmarkKind(rawValue: key) == nil ? 3 : 3.5
        return Group {
            if let image = images.image(of: tier, look: WorldLandmarkLook(found: found, dark: colorScheme == .dark)) {
                WorldLandmarkArtView(image: image, scale: scale)
                    .scaleEffect(min(1, 72 / (CGFloat(image.width) * scale)), anchor: .bottom)
                    .frame(width: 72, height: min(CGFloat(image.height) * scale, 110), alignment: .bottom)
            }
        }
    }

    /// The art keys a board shows.
    static func board(_ scene: String) -> [String] {
        switch scene {
        case "famous1": ["bigben", "goldengate", "liberty", "tajmahal", "greatwall", "redeemer"]
        case "famous2": ["pyramids", "pisa", "sagrada", "burjkhalifa", "spaceneedle", "acropolis"]
        case "famous3": ["towerbridge", "harbourbridge", "cntower", "skytree", "stbasils", "brandenburg"]
        case "famous4": ["petronas", "machupicchu", "chichenitza", "petra", "angkorwat", "hollywood"]
        default: ["eiffel", "empire", "opera", "colosseum"] + AtlasLandmarkKind.allCases.map(\.rawValue)
        }
    }
}
#else
import SwiftUI

/// The gallery is DEBUG-only; Release builds carry this empty stand-in.
struct WorldExploreGallery: View {
    let scene: String
    let images: WorldLandmarkImages

    var body: some View { EmptyView() }
}
#endif

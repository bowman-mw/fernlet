import SwiftUI
import WorldMapStore

// The world view's DEBUG hook (round 7, lane explore-ui): `FERNLET_UI_TEST_WORLD_VIEW=world` or `=city` opens
// the full-screen world view, `=preview` the passport's small world map on a page, for screenshots. It is the
// only way in until the passport's page 2 wires the preview. Under the demo seed
// (`FERNLET_UI_TEST_SEED_DEMO=1`) it shows an in-memory demo passport and fog (home Portland, four cities,
// three countries), never written anywhere; without it, the person's own. Absent in Release.

extension UITestSupport {
    #if DEBUG
    /// The world view screen to open at launch (`FERNLET_UI_TEST_WORLD_VIEW`: `world`, `city` or `preview`), or nil.
    static var worldViewScreen: String? { ProcessInfo.processInfo.environment["FERNLET_UI_TEST_WORLD_VIEW"] }
    #else
    static var worldViewScreen: String? { nil }
    #endif
}

#if DEBUG
extension View {
    /// Opens the world map the DEBUG hook asks for, once the root appears.
    func worldAtlasMapHook(store: FernletStore) -> some View {
        modifier(WorldAtlasMapHook(store: store))
    }
}

/// The screens the hook opens (test tokens).
enum WorldAtlasMapDebugScreen: String, Identifiable {
    /// World, on home (Portland in the demo): `ex-world`.
    case world
    /// City over Oregon ("Oregon · United States"): `ex-world-zoom`.
    case city
    /// The passport's small world map (`ps-world`), which opens the world view.
    case preview

    var id: String { rawValue }

    /// The level it opens at.
    var level: AtlasZoomLevel { self == .city ? .city : .world }
    /// Where it opens: the mockup's closest-zoom view south of the Columbia, or home.
    var centre: GeoPoint? { self == .city ? GeoPoint(45.42, -122.63) : nil }
}

/// Presents the requested world map over the root, after the launch settles.
private struct WorldAtlasMapHook: ViewModifier {
    let store: FernletStore
    @State private var screen: WorldAtlasMapDebugScreen?

    func body(content: Content) -> some View {
        content
            .task {
                guard screen == nil, let raw = UITestSupport.worldViewScreen,
                      let wanted = WorldAtlasMapDebugScreen(rawValue: raw) else { return }
                do {
                    try await Task.sleep(for: .seconds(1.5))
                } catch {
                    return
                }
                screen = wanted
            }
            .fullScreenCover(item: $screen) { wanted in
                let source: WorldAtlasMapView.Source = UITestSupport.shouldSeedDemoContent
                    ? .content(WorldAtlasMapDemo.content(atlas: store.worldFog.atlas.openedAtlas)) : .store(store)
                WorldAtlasMapDebugHost(source: source, screen: wanted) { screen = nil }
            }
    }
}

/// The hook's host: the world view itself, or the passport's small world map on a page, whose tap opens it.
struct WorldAtlasMapDebugHost: View {
    let source: WorldAtlasMapView.Source
    let screen: WorldAtlasMapDebugScreen
    let onClose: () -> Void
    @State private var opened = false

    var body: some View {
        if screen == .preview && !opened {
            WorldAtlasPreview(source: source) { opened = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WorldPageBackground().ignoresSafeArea())
        } else {
            WorldYourWorldPage(source: source, initialLevel: screen.level, initialCentre: screen.centre,
                               onBack: { if screen == .preview { opened = false } else { onClose() } }, onClose: onClose)
        }
    }
}

/// The demo passport and fog for the world map's screenshots, in memory only: Portland (home), Seattle,
/// Vancouver and Tokyo found, with walks and patches around Portland and small patches in the others.
enum WorldAtlasMapDemo {
    /// The four demo cities' points.
    static let cityPoints = [GeoPoint(45.5152, -122.6784), GeoPoint(47.6062, -122.3321), GeoPoint(49.2827, -123.1207),
                             GeoPoint(35.6762, 139.6503)]
    /// Patches: centre and radius in metres (two in Portland, as the closest-zoom drawing's).
    static let patches: [(GeoPoint, Double)] = [
        (GeoPoint(45.515, -122.625), 9_000), (GeoPoint(45.525, -122.68), 5_500), (GeoPoint(47.61, -122.33), 4_000),
        (GeoPoint(49.28, -123.12), 4_000), (GeoPoint(35.68, 139.65), 5_000)
    ]
    /// Walks out of Portland (the drawing's trails).
    static let trails: [[GeoPoint]] = [
        [GeoPoint(45.535, -122.71), GeoPoint(45.56, -122.75), GeoPoint(45.59, -122.79), GeoPoint(45.62, -122.82)],
        [GeoPoint(45.545, -122.55), GeoPoint(45.54, -122.4), GeoPoint(45.545, -122.25), GeoPoint(45.576, -122.116)],
        [GeoPoint(45.51, -122.715), GeoPoint(45.525, -122.68), GeoPoint(45.515, -122.625)]
    ]

    /// The demo content over `atlas` (nil: the sea alone).
    static func content(atlas: WorldAtlas?) -> WorldViewContent {
        let cities = cityPoints.compactMap { atlas?.city(at: $0) }
        let pins = cities.map { WorldViewCityPin(city: $0, name: WorldViewNames.city($0)) }
        return WorldViewContent(atlas: atlas, pins: pins, cityCount: pins.count,
                                countryCount: Set(cities.map(\.countryCode)).count, liftedCells: fogCells(),
                                start: cityPoints.first)
    }

    /// One fog cell every 1.2 km over each patch and every 800 m along each walk. Bounded: fixed lists.
    static func fogCells() -> [HexCell] {
        var cells = Set<HexCell>()
        for (centre, radius) in patches {
            let steps = Int(radius / 1_200)
            for north in -steps...steps {
                for east in -steps...steps where Double(north * north + east * east) * 1_440_000 <= radius * radius {
                    cells.insert(MercatorHexGrid.cell(containing: centre.offset(east: Double(east) * 1_200,
                                                                                north: Double(north) * 1_200)))
                }
            }
        }
        for trail in trails {
            for (from, to) in zip(trail, trail.dropFirst()) {
                let pieces = max(Int(from.distance(to: to) / 800), 1)
                for piece in 0...pieces {
                    let t = Double(piece) / Double(pieces)
                    cells.insert(MercatorHexGrid.cell(containing: GeoPoint(from.latitude + (to.latitude - from.latitude) * t,
                                                                           from.longitude + (to.longitude - from.longitude) * t)))
                }
            }
        }
        return Array(cells)
    }
}
#else
extension View {
    /// The world map's DEBUG hook: nothing in Release.
    func worldAtlasMapHook(store: FernletStore) -> some View { self }
}
#endif

#if DEBUG
import SwiftUI
import WorldMapStore

/// DEBUG-only: the map seam on its own, with fixture fog and a fixture trail, for step 1a's
/// screenshots (World app plan). Opened by `FERNLET_UI_TEST_WORLD_MAP_HARNESS=1` in place of the whole
/// app; nothing is loaded, read or stored, and there is no location.
///
/// The fixture sits in Laurelhurst Park, Portland (a public park, the World Shell's neutral example):
/// fog lifted around the park's centre and along its loop path. `FERNLET_UI_TEST_WORLD_MAP_PLAIN=1`
/// swaps Apple's map for the plain map; `FERNLET_UI_TEST_WORLD_MAP_PHASE=dawn|day|dusk|night` fixes
/// the time of day. Absent from Release builds entirely (`TestHookBoundaryTests`).
struct WorldMapHarnessView: View {
    /// Opens at World Shell's height, about 435 m across an iPhone 17.
    @State private var camera = WorldCamera(center: Self.parkCentre, distance: 1_700)

    /// The park's middle.
    static let parkCentre = GeoPoint(45.5205, -122.6255)

    /// The park's loop path: the World Shell's recorded route (Apple walking directions, a public path).
    static let parkLoop: [GeoPoint] = [
        GeoPoint(45.520273, -122.623031), GeoPoint(45.520349, -122.623190), GeoPoint(45.520425, -122.623296),
        GeoPoint(45.520601, -122.623421), GeoPoint(45.520771, -122.623563), GeoPoint(45.520968, -122.623428),
        GeoPoint(45.521227, -122.623355), GeoPoint(45.521426, -122.623333), GeoPoint(45.521903, -122.623379),
        GeoPoint(45.522193, -122.623378), GeoPoint(45.522388, -122.623513), GeoPoint(45.522434, -122.623554),
        GeoPoint(45.522476, -122.623626), GeoPoint(45.522516, -122.623753), GeoPoint(45.522405, -122.624409),
        GeoPoint(45.522324, -122.625039), GeoPoint(45.522251, -122.625433), GeoPoint(45.522192, -122.625612),
        GeoPoint(45.522192, -122.625720), GeoPoint(45.522183, -122.625971), GeoPoint(45.522141, -122.626252),
        GeoPoint(45.522120, -122.626335), GeoPoint(45.522085, -122.626396), GeoPoint(45.522077, -122.626772),
        GeoPoint(45.522040, -122.627193), GeoPoint(45.521982, -122.627624), GeoPoint(45.521908, -122.627970),
        GeoPoint(45.521811, -122.628334), GeoPoint(45.521594, -122.628956), GeoPoint(45.521459, -122.629252),
        GeoPoint(45.521594, -122.628956), GeoPoint(45.521811, -122.628334), GeoPoint(45.521908, -122.627970),
        GeoPoint(45.521826, -122.627919), GeoPoint(45.521624, -122.627780), GeoPoint(45.521458, -122.627647),
        GeoPoint(45.521371, -122.627778), GeoPoint(45.521261, -122.627899), GeoPoint(45.521025, -122.628072),
        GeoPoint(45.520875, -122.628144), GeoPoint(45.520543, -122.628242), GeoPoint(45.520384, -122.628258),
        GeoPoint(45.520334, -122.628298), GeoPoint(45.520283, -122.628338), GeoPoint(45.519700, -122.628344),
        GeoPoint(45.519297, -122.628349), GeoPoint(45.519296, -122.627718), GeoPoint(45.519294, -122.625696),
        GeoPoint(45.519445, -122.625698), GeoPoint(45.519645, -122.625337), GeoPoint(45.519690, -122.625095),
        GeoPoint(45.519674, -122.624784), GeoPoint(45.519640, -122.624655), GeoPoint(45.519573, -122.624517),
        GeoPoint(45.519546, -122.624396), GeoPoint(45.519597, -122.624428), GeoPoint(45.519695, -122.624435),
        GeoPoint(45.519846, -122.624378), GeoPoint(45.519970, -122.624251), GeoPoint(45.520113, -122.624066),
        GeoPoint(45.520450, -122.624058), GeoPoint(45.520488, -122.623921), GeoPoint(45.520456, -122.623609),
        GeoPoint(45.520425, -122.623296), GeoPoint(45.520349, -122.623190), GeoPoint(45.520273, -122.623084),
        GeoPoint(45.520273, -122.623031),
    ]

    var body: some View {
        WorldMapStack(kind: UITestSupport.worldMapHarnessPlain ? .plain : .appleMuted, camera: $camera,
                      ground: Self.ground, phase: UITestSupport.worldMapHarnessPhase ?? .current(),
                      creditInset: 40) { _, _ in EmptyView() }
    }

    /// Fog lifted 120 m around the park's middle and 40 m either side of its loop.
    static var ground: WorldGround {
        var lifted = Set(MercatorHexGrid.cells(around: parkCentre, within: 120))
        for point in Polyline(parkLoop).samples(every: 10) {
            lifted.formUnion(MercatorHexGrid.cells(around: point, within: 40))
        }
        return WorldGround(lifted: lifted, trails: [parkLoop], traces: [])
    }
}
#endif

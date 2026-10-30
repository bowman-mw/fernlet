import CoreGraphics
import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The world map (World-Exploration-Spec §2, `ex-world` and `ex-world-zoom`): wrap-around panning, the poles
/// at World's edges, level steps, the 30-pt clusters and their "+N", the plate per level, a decoy's empty
/// map, and the shared skylines.
@MainActor
struct WorldAtlasMapTests {
    private static let phone = CGSize(width: 402, height: 874)
    private static let portland = GeoPoint(45.5152, -122.6784)

    private static func pin(_ token: String, _ point: GeoPoint, _ size: WorldCitySizeClass, _ people: Int) -> WorldViewCityPin {
        let unit = WebMercator.unit(point)
        return WorldViewCityPin(token: token, name: token, sizeClass: size, population: people,
                                x: WorldViewCamera.wrap(unit.x), y: unit.y)
    }

    // MARK: Panning

    /// Panning a whole world's width east comes back to the same place; the centre's x stays in 0..<1, and a
    /// city just across the antimeridian is drawn beside the centre, not a world away.
    @Test func panningWrapsAllTheWayRound() {
        var camera = WorldViewCamera(level: .world, centre: GeoPoint(0, 179), size: Self.phone)
        let start = camera.x
        camera.pan(by: CGSize(width: -camera.scale, height: 0))
        #expect(abs(camera.x - start) < 1e-9)
        camera.pan(by: CGSize(width: -camera.scale * 0.3, height: 0))
        #expect(camera.x >= 0 && camera.x < 1)
        let near = WorldViewCamera(level: .country, centre: GeoPoint(-17, 179.5), size: Self.phone)
        let across = near.screenPoint(of: GeoPoint(-17, -179.5))
        #expect(abs(across.x - (Self.phone.width / 2 + 1 * near.scale / 360)) < 1, "one degree east, on screen")
        let grid = AtlasZoomLevel.state.hexGrid
        #expect(WorldViewCamera.canonical((0.25, 0.4), in: grid) == WorldViewCamera.canonical((1.25, 0.4), in: grid))
        #expect(WorldViewCamera.wrappedDelta(0.9) < 0 && abs(WorldViewCamera.wrappedDelta(0.9) + 0.1) < 1e-12)
    }

    /// At World the Arctic stays on the top edge and Antarctica on the bottom edge however far one pans; at
    /// City the view never leaves Mercator's square; a screen too short for both holds the band's middle.
    @Test func worldKeepsThePolesAtTheEdges() {
        for drag in [-100_000.0, 100_000.0, 0] {
            var camera = WorldViewCamera(level: .world, centre: Self.portland, size: Self.phone)
            camera.pan(by: CGSize(width: 0, height: drag))
            let edges = camera.edgeLatitudes
            #expect(edges.top >= WorldViewCamera.arcticEdgeLatitude - 1e-6, "drag \(drag)")
            #expect(edges.bottom <= WorldViewCamera.antarcticEdgeLatitude + 1e-6, "drag \(drag)")
        }
        var city = WorldViewCamera(level: .city, centre: GeoPoint(84, 0), size: Self.phone)
        city.pan(by: CGSize(width: 0, height: 1_000_000))
        #expect(city.edgeLatitudes.top <= WebMercator.maxLatitude + 1e-6)
        let short = WorldViewCamera(level: .world, centre: GeoPoint(60, 0), size: CGSize(width: 320, height: 400))
        #expect(short.yRange.lowerBound == short.yRange.upperBound)
        let opened = WorldViewCamera(level: .world, centre: Self.portland, size: Self.phone)
        let home = opened.screenPoint(of: Self.portland)
        #expect(home.y > 0 && home.y < Self.phone.height && abs(home.x - Self.phone.width / 2) < 1, "home in view")
    }

    /// A level step keeps the place under the focus where it was, + and − follow the ladder, and the ends dim.
    @Test func levelStepsKeepTheFocusStill() {
        var camera = WorldViewCamera(level: .state, centre: Self.portland, size: Self.phone)
        let focus = CGPoint(x: 120, y: 500)
        let before = camera.mercator(at: focus)
        camera.setLevel(.city, focus: focus)
        let after = camera.mercator(at: focus)
        #expect(abs(WorldViewCamera.wrappedDelta(after.x - before.x)) < 1e-9 && abs(after.y - before.y) < 1e-9)
        var level = AtlasZoomLevel.world, steps = 0
        while let next = level.zoomedIn, steps < 8 { level = next; steps += 1 }
        #expect(level == .city && steps == 3 && !level.canZoomIn)
        #expect(!AtlasZoomLevel.world.canZoomOut)
        let hexes = camera.visibleHexes()
        #expect(!hexes.isEmpty && hexes.count <= WorldViewCamera.maxVisibleHexes)
    }

    // MARK: Markers

    /// Cities closer than 30 pt share one marker named for the biggest ("Seattle +2") until you zoom in; one
    /// across the antimeridian still joins its neighbour.
    @Test func nearbyCitiesShareOneMarker() {
        let pins = [Self.pin("portland", Self.portland, .city, 650_000),
                    Self.pin("seattle", GeoPoint(47.6062, -122.3321), .bigCity, 3_500_000),
                    Self.pin("tacoma", GeoPoint(47.25, -122.44), .city, 220_000),
                    Self.pin("tokyo", GeoPoint(35.68, 139.65), .megacity, 37_000_000)]
        let world = WorldViewCluster.clusters(of: pins, at: .world)
        #expect(world.count == 2)
        let seattle = world.first { $0.anchor.token == "seattle" }
        #expect(seattle?.others == 2)
        #expect(WorldViewCopy.clusterPlate(name: "Seattle", others: 2) == "Seattle +2")
        #expect(WorldViewCopy.clusterSpoken(name: "Seattle", others: 2) == "Seattle and 2 more cities")
        #expect(WorldViewCluster.clusters(of: pins, at: .city).count == 4, "apart at City")
        let fiji = [Self.pin("a", GeoPoint(-17, 179.9), .town, 50_000), Self.pin("b", GeoPoint(-17, -179.9), .city, 150_000)]
        let joined = WorldViewCluster.clusters(of: fiji, at: .world)
        #expect(joined.count == 1 && joined.first?.anchor.token == "b")
    }

    // MARK: The plate

    /// The plate counts at World and Country and at sea, and names the state and country from State in.
    @Test func thePlateFollowsTheLevel() {
        let oregon = AtlasPlaceName(countryCode: "US", regionToken: "US-OR", regionNames: AtlasCityNames(english: "Oregon"))
        #expect(WorldAtlasPlate.text(level: .world, place: oregon, cities: 4, countries: 3) == "4 cities, 3 countries found")
        #expect(WorldAtlasPlate.text(level: .country, place: oregon, cities: 1, countries: 1) == "1 city, 1 country found")
        let english = WorldViewNames.language == .english
        if english {
            #expect(WorldAtlasPlate.text(level: .city, place: oregon, cities: 4, countries: 3) == "Oregon · United States")
            #expect(WorldAtlasPlate.text(level: .state, place: AtlasPlaceName(countryCode: "FR"), cities: 0, countries: 0) == "France")
            let spoken = WorldViewCopy.zoomValue(AtlasZoomDescription(level: .city, place: oregon))
            #expect(spoken == "City, Oregon, United States")
            #expect(WorldViewCopy.zoomValue(AtlasZoomDescription(level: .world, place: nil)) == "World")
        }
        #expect(WorldAtlasPlate.text(level: .city, place: nil, cities: 0, countries: 0) == "0 cities, 0 countries found")
    }

    // MARK: Duress

    /// A decoy's passport is empty and its fog none, so its map has no cities, no counts and no uncovered hex.
    @Test func aDecoyShowsNothing() async {
        let content = WorldViewContent.make(atlas: nil, book: PassportBook(), cells: [], start: nil)
        #expect(content.pins.isEmpty && content.cityCount == 0 && content.countryCount == 0 && content.liftedCells.isEmpty)
        let model = WorldViewModel()
        model.load(content)
        await model.prepare()
        #expect(model.found.isEmpty)
        let hex = AtlasZoomLevel.world.hexGrid.cell(containing: Self.portland)
        #expect(!model.isFound(hex, at: .world))
        #expect(model.clusters(at: .world).isEmpty)
    }

    /// The demo's uncovered hexes are found at every level, and only the demo's: a far hex stays fogged.
    @Test func liftedFogUncoversItsHexes() async {
        let cells = [MercatorHexGrid.cell(containing: Self.portland)]
        let model = WorldViewModel()
        model.load(WorldViewContent(atlas: nil, pins: [], cityCount: 0, countryCount: 0, liftedCells: cells, start: nil))
        await model.prepare()
        for level in AtlasZoomLevel.allCases {
            #expect(model.isFound(level.hexGrid.cell(containing: Self.portland), at: level), "\(level)")
            #expect(!model.isFound(level.hexGrid.cell(containing: GeoPoint(-33.87, 151.21)), at: level))
        }
    }

    // MARK: Size classes and skylines

    /// Five classes from the pack's four sizes (a town under 20,000 is a village), each with a skyline inside
    /// its 48 × 40 picture, windows warmer in dark mode.
    @Test func fiveSkylinesFromFourSizes() {
        #expect(WorldCitySizeClass(size: .town, population: 19_999) == .village)
        #expect(WorldCitySizeClass(size: .town, population: 20_000) == .town)
        #expect(WorldCitySizeClass(size: .city, population: 500_000) == .city)
        #expect(WorldCitySizeClass(size: .large, population: 3_000_000) == .bigCity)
        #expect(WorldCitySizeClass(size: .mega, population: 30_000_000) == .megacity)
        #expect(WorldCitySizeClass.allCases.map(\.rawValue) == ["village", "town", "city", "bigCity", "megacity"], "tokens")
        for sizeClass in WorldCitySizeClass.allCases {
            let light = WorldCitySkylineArt.pixels(for: sizeClass, dark: false)
            #expect(!light.isEmpty)
            #expect(light.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 48 && $0.y + $0.height <= 40 }, "\(sizeClass)")
            let dark = WorldCitySkylineArt.pixels(for: sizeClass, dark: true)
            #expect(dark.count == light.count)
            #expect(dark.contains { $0.color.hex == 0xF2D58A } && light.contains { $0.color.hex == 0xFFF3C4 })
        }
    }

    // MARK: The passport's world preview

    /// The preview is the whole world in 274 × 112 pt from 168°W and 84°N; a lifted cell lights its hex, a
    /// found city its neighbours and one marker; two cities a few points apart share one marker.
    @Test func thePreviewLightsWhatWasFound() {
        let portland = WorldPreviewField.position(of: Self.portland)
        #expect(abs(portland.x - (-122.6784 + 168) * 274 / 360) < 0.01)
        #expect(abs(portland.y - (84 - 45.5152) * 274 / 360) < 0.01)
        #expect(abs(WorldPreviewField.position(of: GeoPoint(0, -169)).x - 273.24) < 0.01, "wraps round")
        let pins = [Self.pin("portland", Self.portland, .city, 650_000),
                    Self.pin("seattle", GeoPoint(47.6, -122.3), .bigCity, 3_500_000)]
        let sydneyPoint = GeoPoint(-33.87, 151.21)
        let lit = WorldPreviewField(atlas: nil, cells: [MercatorHexGrid.cell(containing: sydneyPoint)], pins: pins)
        #expect(lit.dots.count == 1, "Portland and Seattle are under 7 pt apart")
        #expect(lit.hexes.contains { $0.found && abs($0.x - portland.x) < 5 && abs($0.y - portland.y) < 5 })
        let sydney = WorldPreviewField.position(of: sydneyPoint)
        #expect(lit.hexes.contains { $0.found && abs($0.x - sydney.x) < 3 && abs($0.y - sydney.y) < 3 })
        #expect(lit.hexes.allSatisfy { !$0.land }, "no atlas: all sea")
        let empty = WorldPreviewField(atlas: nil, cells: [], pins: [])
        #expect(empty.dots.isEmpty && empty.hexes.allSatisfy { !$0.found } && empty.hexes.count > 2_000)
    }
}

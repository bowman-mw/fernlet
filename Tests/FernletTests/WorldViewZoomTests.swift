import CoreGraphics
import Foundation
import Testing
import WorldMapStore

/// The world view's zoom ladder and its hexes (World-Exploration-Spec, "The world view", answers 9 and 13):
/// World → Country → State → City, City 360 pt a degree, lines and the plate by level, + and − rules, and the
/// fog's lifted cells aggregated into the level's 10-pt hexes.
@MainActor
struct WorldViewZoomTests {
    /// The ladder runs World, Country, State, City, each closer than the last, City at exactly 360 pt a degree
    /// of latitude and World at the mockup's 874 pt for 176°.
    @Test func theLadderIsMonotonicWithCityAt360() {
        let levels = AtlasZoomLevel.allCases
        #expect(levels == [.world, .country, .state, .city])
        #expect(levels.map(\.rawValue) == ["world", "country", "state", "city"], "frozen tokens")
        #expect(AtlasZoomLevel.city.pointsPerDegreeOfLatitude == 360)
        #expect(abs(AtlasZoomLevel.world.pointsPerDegreeOfLatitude - 874.0 / 176.0) < 1e-9)
        for (outer, inner) in zip(levels, levels.dropFirst()) {
            #expect(outer < inner)
            #expect(inner.pointsPerDegreeOfLatitude > outer.pointsPerDegreeOfLatitude)
            #expect(inner.pointsPerMercatorUnit > outer.pointsPerMercatorUnit)
            let ratio = inner.pointsPerDegreeOfLatitude / outer.pointsPerDegreeOfLatitude
            #expect(abs(ratio - AtlasZoomLevel.stepRatio) < 1e-9, "a geometric ladder")
        }
        #expect(abs(AtlasZoomLevel.country.pointsPerDegreeOfLatitude - 20.706) < 0.01)
        #expect(abs(AtlasZoomLevel.state.pointsPerDegreeOfLatitude - 86.338) < 0.01)
    }

    /// At City an iPhone shows about 270 km top to bottom (874 pt at 45°); at World about 176° of latitude's
    /// worth of points.
    @Test func cityShowsAbout270Kilometres() {
        let size = CGSize(width: 402, height: 874)
        let portland = GeoPoint(45.0, -122.6)
        let city = AtlasZoomLevel.city.viewport(centredOn: portland, size: size)
        let metres = city.height / WebMercator.unitsPerMetre(at: 45)
        #expect(metres > 260_000 && metres < 280_000)
        #expect(abs(city.center.latitude - 45) < 1e-6 && abs(city.center.longitude + 122.6) < 1e-6)
        let world = AtlasZoomLevel.world.viewport(centredOn: portland, size: size)
        #expect(abs(world.height / city.height - 360 / AtlasZoomLevel.world.pointsPerDegreeOfLatitude) < 1e-6)
    }

    /// + is dimmed at City, − at World; each step moves one level.
    @Test func plusAndMinusFollowTheLadder() {
        #expect(!AtlasZoomLevel.city.canZoomIn && AtlasZoomLevel.city.zoomedIn == nil)
        #expect(!AtlasZoomLevel.world.canZoomOut && AtlasZoomLevel.world.zoomedOut == nil)
        #expect(AtlasZoomLevel.world.zoomedIn == .country && AtlasZoomLevel.country.zoomedIn == .state)
        #expect(AtlasZoomLevel.state.zoomedIn == .city && AtlasZoomLevel.city.zoomedOut == .state)
        #expect(AtlasZoomLevel.state.zoomedOut == .country && AtlasZoomLevel.country.zoomedOut == .world)
        for level in [AtlasZoomLevel.country, .state] {
            #expect(level.canZoomIn && level.canZoomOut)
        }
    }

    /// Country lines from Country, state and province lines and the plate's place from State.
    @Test func linesAndThePlateComeInSteps() {
        let lines = AtlasZoomLevel.allCases.map { ($0.showsCountryLines, $0.showsAdmin1Lines, $0.showsPlaceName) }
        #expect(lines.map(\.0) == [false, true, true, true])
        #expect(lines.map(\.1) == [false, false, true, true])
        #expect(lines.map(\.2) == [false, false, true, true])
    }

    /// VoiceOver names the country from Country in ("Country, United States") and the plate group from State
    /// in ("City, Oregon, United States"); World reads the level alone.
    @Test func voiceOverNamesTheCountryFromCountry() {
        #expect(AtlasZoomLevel.allCases.map(\.readsCountry) == [false, true, true, true])
        #expect(AtlasZoomLevel.allCases.map(\.readsRegion) == [false, false, true, true])
        #expect(AtlasZoomLevel.allCases.allSatisfy { $0.readsRegion == $0.showsPlaceName }, "the plate and the words agree")
    }

    /// A hex is 10 pt across on screen at every level, about 3 km on the ground at City.
    @Test func hexesStayTenPointsAcross() {
        for level in AtlasZoomLevel.allCases {
            let grid = level.hexGrid
            let across = 3.0.squareRoot() * grid.radius * level.pointsPerMercatorUnit
            #expect(abs(across - WorldViewHexGrid.hexAcrossPoints) < 1e-9, "\(level)")
            #expect(grid.cornerOffsets.count == 6)
        }
        let city = AtlasZoomLevel.city.hexGrid.groundAcrossMetres(at: 45)
        #expect(city > 2_900 && city < 3_300)
        // A hex's own centre lies in it, and the hex under a point holds that point's neighbourhood.
        let grid = AtlasZoomLevel.state.hexGrid
        let hex = grid.cell(containing: GeoPoint(45.52, -122.68))
        let centre = grid.centre(of: hex)
        #expect(grid.cell(x: centre.x, y: centre.y) == hex)
    }

    /// One lifted fog cell uncovers exactly one hex at every level; two far apart uncover two.
    @Test func oneFogCellUncoversOneHex() {
        let portland = MercatorHexGrid.cell(containing: GeoPoint(45.52, -122.68))
        let paris = MercatorHexGrid.cell(containing: GeoPoint(48.8566, 2.3522))
        for level in AtlasZoomLevel.allCases {
            let grid = level.hexGrid
            let one = grid.uncovered(by: [portland])
            #expect(one == [grid.cell(containing: MercatorHexGrid.centreGeo(of: portland))], "\(level)")
            #expect(grid.uncovered(by: [portland, paris]).count == 2, "\(level)")
            #expect(grid.uncovered(by: [HexCell]()).isEmpty)
        }
    }

    /// Neighbouring fog cells near a hex's centre uncover that one hex; the same store drives every level, so
    /// a 12 km walk uncovers several 3-km hexes at City and only one to three of the bigger hexes farther out.
    @Test func aWalkUncoversFewerHexesFartherOut() {
        let grid = AtlasZoomLevel.city.hexGrid
        let middle = grid.centre(of: grid.cell(containing: GeoPoint(45.52, -122.68)))
        let fog = MercatorHexGrid.cell(x: middle.x, y: middle.y)
        #expect(grid.uncovered(by: [fog] + MercatorHexGrid.neighbours(of: fog)).count == 1)
        let start = GeoPoint(45.52, -122.68)
        let walk = (0..<400).map { MercatorHexGrid.cell(containing: start.offset(east: Double($0) * 30, north: 0)) }
        let counts = AtlasZoomLevel.allCases.map { $0.hexGrid.uncovered(by: walk).count }
        #expect((counts.last ?? 0) >= 4, "12 km east at City crosses several 3-km hexes")
        #expect(counts.dropLast().allSatisfy { (1...3).contains($0) })
    }

    /// The aggregation reads at most maxLiftedCells cells (the fog store's own cap), so a cell past it is not
    /// read.
    @Test func theAggregationIsBounded() {
        #expect(WorldViewHexGrid.maxLiftedCells == FogCellStore.maxCells)
        let near = MercatorHexGrid.cell(containing: GeoPoint(45.52, -122.68))
        let far = MercatorHexGrid.cell(containing: GeoPoint(-33.87, 151.21))
        let cells = Array(repeating: near, count: WorldViewHexGrid.maxLiftedCells) + [far]
        let grid = AtlasZoomLevel.world.hexGrid
        #expect(grid.uncovered(by: cells) == grid.uncovered(by: [near]))
    }
}

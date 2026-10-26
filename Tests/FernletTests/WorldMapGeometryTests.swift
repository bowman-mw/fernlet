import CoreGraphics
import Foundation
import Testing
import WorldMapStore

/// The World map's geometry (World app plan step 1a): Web Mercator, the viewport contract every layer
/// places itself from, the global fog grid, lines and the camera.
struct WorldMapGeometryTests {

    static let places = [
        GeoPoint(45.5205, -122.6255), GeoPoint(0, 0), GeoPoint(-33.8688, 151.2093),
        GeoPoint(64.1466, -21.9426), GeoPoint(51.4779, -0.0015), GeoPoint(1.3521, 103.8198),
    ]

    // MARK: Web Mercator and the viewport

    @Test func mercatorRoundTripsEveryPlace() {
        for place in Self.places {
            let unit = WebMercator.unit(place)
            let back = WebMercator.geo(x: unit.x, y: unit.y)
            #expect(place.distance(to: back) < 0.01, "\(place) came back as \(back)")
        }
    }

    @Test func aViewportPlacesItsCentreInTheMiddleOfTheView() {
        let size = CGSize(width: 402, height: 874)
        for place in Self.places {
            let viewport = MapViewport.around(place, heightMetres: 760, size: size)
            let middle = viewport.screenPoint(for: place, in: size)
            #expect(abs(middle.x - size.width / 2) < 0.5 && abs(middle.y - size.height / 2) < 0.5)
            #expect(viewport.geo(at: middle, in: size).distance(to: place) < 0.5)
            #expect(abs(viewport.pointsPerMetre(at: place.latitude, in: size) * 760 - Double(size.height)) < 1)
        }
    }

    @Test func anEmptyViewportPlacesNothing() {
        let empty = MapViewport(minX: 0, minY: 0, width: 0, height: 0)
        #expect(!empty.isUsable)
        #expect(empty.pointsPerUnit(in: CGSize(width: 100, height: 100)) == 0)
        #expect(MercatorHexGrid.cells(in: empty).isEmpty)
    }

    // MARK: The fog grid

    @Test func cellIDsRoundTripAndRejectNonsense() {
        for cell in [HexCell(q: 0, r: 0), HexCell(q: -539_000, r: 1_079_000), HexCell(q: 934_000, r: 3)] {
            #expect(HexCell(id: cell.id) == cell)
        }
        #expect(HexCell(id: -1) == nil)
    }

    @Test func aCellHasItsReferenceSizeAt45Degrees() {
        #expect(abs(MercatorHexGrid.groundRadius(at: 45) - 17.5) < 0.001)
        #expect(MercatorHexGrid.groundRadius(at: 0) > MercatorHexGrid.groundRadius(at: 60))
    }

    @Test func everyPlaceFallsInTheCellWhoseCentreIsNearest() {
        for place in Self.places {
            let cell = MercatorHexGrid.cell(containing: place)
            let centre = MercatorHexGrid.centreGeo(of: cell)
            #expect(place.distance(to: centre) <= MercatorHexGrid.groundRadius(at: place.latitude) + 0.01)
            for neighbour in MercatorHexGrid.neighbours(of: cell) {
                #expect(place.distance(to: centre) <= place.distance(to: MercatorHexGrid.centreGeo(of: neighbour)) + 0.01)
            }
        }
    }

    @Test func neighboursAreSixDistinctAdjacentCells() {
        let cell = MercatorHexGrid.cell(containing: Self.places[0])
        let neighbours = MercatorHexGrid.neighbours(of: cell)
        #expect(Set(neighbours).count == 6)
        let centre = MercatorHexGrid.centre(of: cell)
        for neighbour in neighbours {
            let other = MercatorHexGrid.centre(of: neighbour)
            let gap = ((other.x - centre.x) * (other.x - centre.x) + (other.y - centre.y) * (other.y - centre.y)).squareRoot()
            #expect(abs(gap - MercatorHexGrid.radius * 3.0.squareRoot()) < MercatorHexGrid.radius * 1e-6)
        }
    }

    @Test func liftingAroundAPointStaysInsideItsRadiusAndIsCapped() {
        let place = Self.places[0]
        let near = MercatorHexGrid.cells(around: place, within: 50)
        #expect(near.contains(MercatorHexGrid.cell(containing: place)))
        #expect(near.count > 5)
        for cell in near {
            #expect(MercatorHexGrid.centreGeo(of: cell).distance(to: place) <= 50.5)
        }
        let huge = MercatorHexGrid.cells(around: place, within: 50_000)
        #expect(huge.count <= 25 * 25, "one fix lifted \(huge.count) cells")
        #expect(MercatorHexGrid.cells(around: place, within: .nan) == [MercatorHexGrid.cell(containing: place)])
    }

    @Test func theCellsInAViewportCoverItsCornersAndAreBounded() {
        let size = CGSize(width: 402, height: 874)
        let viewport = MapViewport.around(Self.places[0], heightMetres: 760, size: size)
        let cells = Set(MercatorHexGrid.cells(in: viewport))
        for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
            #expect(cells.contains(MercatorHexGrid.cell(containing: viewport.geo(at: corner, in: size))))
        }
        let wide = MapViewport.around(Self.places[0], heightMetres: 40_000, size: size)
        #expect(MercatorHexGrid.cells(in: wide).count <= MercatorHexGrid.maxCellsPerQuery + 600)
    }

    // MARK: Lines and the camera

    @Test func aPolylineMeasuresSamplesAndSkipsBadPoints() {
        let start = Self.places[0]
        let end = start.offset(east: 300, north: 400)
        let line = Polyline([start, GeoPoint(.nan, 0), end])
        #expect(line.points.count == 2)
        #expect(abs(line.length - 500) < 0.5)
        let samples = line.samples(every: 10)
        #expect(samples.count == 51)
        #expect(samples.first == start && samples.last == end)
        #expect(line.point(at: -5) == start && line.point(at: 9_999) == end)
        #expect(Polyline([]).point(at: 1) == nil)
        #expect(Polyline([start, end]).samples(every: 0.0001).count <= Polyline.maxSamples)
    }

    @Test func theCameraClampsItsHeightAndCountsItsOwnMoves() {
        var camera = WorldCamera(center: Self.places[0], distance: 50)
        #expect(camera.distance == WorldCamera.distanceRange.lowerBound)
        camera.move(to: Self.places[1])
        #expect(camera.revision == 1 && camera.center == Self.places[1] && camera.follows)
        camera.move(to: GeoPoint(200, 0))
        #expect(camera.revision == 1, "an invalid point must not move the camera")
    }
}

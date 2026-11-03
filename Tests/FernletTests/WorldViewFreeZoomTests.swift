import CoreGraphics
import Foundation
import SwiftUI
import Testing
import WorldMapStore
@testable import Fernlet

/// The passport map's free zoom, its marks standing exactly on their places, and its labels keeping off the found
/// ground (owner, 2026-11-02).
@MainActor
struct WorldViewFreeZoomTests {
    private static let phone = CGSize(width: 402, height: 874)
    private static let atlanta = GeoPoint(33.749, -84.388)

    /// At a whole number the free zoom is exactly the level: same scale, same hexes, same word.
    @Test func aLevelIsAWholeNumberOnTheZoom() {
        for level in AtlasZoomLevel.allCases {
            let camera = WorldViewCamera(level: level, centre: Self.atlanta, size: Self.phone)
            #expect(camera.zoom == Double(level.rank))
            #expect(camera.scale == level.pointsPerMercatorUnit)
            #expect(camera.level == level)
            #expect(camera.detail.hexGrid.radius == level.hexGrid.radius)
        }
    }

    /// The word changes halfway between two levels, and the hexes never go below 10 pt or far past 20.
    @Test func detailsStepInHalfLevels() {
        #expect(AtlasZoomDetail(zoom: 0.49).level == .world)
        #expect(AtlasZoomDetail(zoom: 0.5).level == .country)
        #expect(AtlasZoomDetail(zoom: 1.49).level == .country)
        #expect(AtlasZoomDetail(zoom: 1.5).level == .state)
        #expect(AtlasZoomDetail(zoom: 2.5).level == .city)
        #expect(AtlasZoomDetail(zoom: 3).level == .city)
        #expect(AtlasZoomDetail(zoom: .nan).halfSteps == 0)
        #expect(AtlasZoomDetail(zoom: 9).halfSteps == AtlasZoomDetail.maxHalfSteps)
        var camera = WorldViewCamera(level: .world, centre: Self.atlanta, size: Self.phone)
        for step in 0...Int(AtlasZoomLevel.maxZoom * 100) {
            camera.setZoom(Double(step) / 100)
            let across = 3.0.squareRoot() * camera.detail.hexGrid.radius * camera.scale
            #expect(across >= WorldViewHexGrid.hexAcrossPoints - 1e-6 && across < 20.5, "zoom \(camera.zoom): \(across) pt")
        }
    }

    /// A zoom holds the place under the fingers still, however small the step, and stops at the ladder's ends.
    @Test func zoomingKeepsThePlaceUnderTheFocus() {
        var camera = WorldViewCamera(level: .country, centre: Self.atlanta, size: Self.phone)
        let focus = CGPoint(x: 120, y: 300)
        let under = camera.mercator(at: focus)
        camera.setZoom(1.37, focus: focus)
        let there = camera.screenPoint(x: under.x, y: under.y)
        #expect(abs(there.x - focus.x) < 1e-6 && abs(there.y - focus.y) < 1e-6)
        camera.setZoom(99)
        #expect(camera.zoom == AtlasZoomLevel.maxZoom && !camera.canZoomIn && camera.canZoomOut)
        camera.setZoom(-99)
        #expect(camera.zoom == 0 && camera.canZoomIn && !camera.canZoomOut)
    }

    /// Moving the map never changes the zoom.
    @Test func panningNeverChangesTheZoom() {
        var camera = WorldViewCamera(level: .world, centre: Self.atlanta, size: Self.phone)
        camera.setZoom(1.73)
        for step in 0..<200 {
            camera.pan(by: CGSize(width: 37, height: step.isMultiple(of: 2) ? 1_000 : -1_500))
            #expect(camera.zoom == 1.73)
        }
    }

    /// Zooming all the way out from near a pole brings the view to World's band with no jump on the way.
    @Test func zoomingOutNearAPoleHasNoJump() {
        var camera = WorldViewCamera(level: .state, centre: GeoPoint(80, 0), size: Self.phone)
        var last = camera.y
        for step in (0...200).reversed() {
            camera.setZoom(Double(step) / 100)
            #expect(abs(camera.y - last) < 0.03, "zoom \(camera.zoom): \(last) to \(camera.y)")
            last = camera.y
        }
        #expect(camera.edgeLatitudes.top >= WorldViewCamera.arcticEdgeLatitude - 1e-6)
        #expect(camera.edgeLatitudes.bottom <= WorldViewCamera.antarcticEdgeLatitude + 1e-6)
    }

    /// + and − land on the next level along, from a level or from between two.
    @Test func theControlStepsBackOntoTheLadder() {
        #expect(WorldViewCamera.steppedZoom(from: 1, in: true) == 2)
        #expect(WorldViewCamera.steppedZoom(from: 1.4, in: true) == 2)
        #expect(WorldViewCamera.steppedZoom(from: 1.99, in: true) == 3)
        #expect(WorldViewCamera.steppedZoom(from: 1.4, in: false) == 1)
        #expect(WorldViewCamera.steppedZoom(from: 1, in: false) == 0)
        #expect(WorldViewCamera.steppedZoom(from: 2.9, in: true) == 3)
        #expect(WorldViewCamera.steppedZoom(from: 0.1, in: false) == 0)
        #expect(WorldViewCamera.steppedZoom(from: 3, in: true) == AtlasZoomLevel.maxZoom)
        let last = AtlasZoomLevel.maxZoom
        #expect(WorldViewCamera.steppedZoom(from: last.rounded(.down) - 1, in: true) == last, "no small last press in")
        #expect(WorldViewCamera.steppedZoom(from: last, in: false) == last.rounded(.down) - 1, "nor out")
    }

    /// The closest zoom shows about 25 km top to bottom, and stops short of the next, finer hex detail.
    @Test func theClosestZoomIsAbout25Kilometres() {
        let kilometres = { (height: Double, latitude: Double) -> Double in
            var camera = WorldViewCamera(level: .world, centre: GeoPoint(latitude, 0), size: CGSize(width: 402, height: height))
            camera.setZoom(99)
            camera.centre(on: GeoPoint(latitude, 0))
            let edges = camera.edgeLatitudes
            return (edges.top - edges.bottom) * GeoPoint.metresPerDegree / 1_000
        }
        #expect(abs(kilometres(874, 45) - 21) < 1.5, "iPhone 17 at 45°")
        #expect(abs(kilometres(956, 31) - 27) < 1.5, "Pro Max at 31°")
        #expect(AtlasZoomLevel.maxZoom == 4.8 && AtlasZoomDetail.maxHalfSteps == 9)
    }

    /// Past City the word stays City; every detail has its own hexes, finer than the last.
    @Test func pastCityTheDetailsGoOn() {
        var camera = WorldViewCamera(level: .city, centre: Self.atlanta, size: Self.phone)
        camera.setZoom(4.2)
        #expect(camera.level == .city && !camera.level.canZoomIn && camera.canZoomIn)
        let radii = AtlasZoomDetail.all.map { $0.hexGrid.radius }
        #expect(zip(radii, radii.dropFirst()).allSatisfy { $0 > $1 })
        #expect(AtlasZoomDetail.all.count == AtlasZoomDetail.maxHalfSteps + 1 && AtlasZoomDetail.maxHalfSteps > 6)
    }

    /// A glide starts where the camera is, ends exactly on its target, and goes the short way round the world.
    @Test func aGlideEndsOnItsTarget() {
        let start = WorldViewCamera(level: .country, centre: GeoPoint(10, 179), size: Self.phone)
        let glide = WorldViewCamera.Glide(from: start, toZoom: 2, centre: GeoPoint(10, -179))
        #expect(glide.camera(at: 0) == start)
        let end = glide.camera(at: 1)
        #expect(end.zoom == 2)
        #expect(abs(WorldViewCamera.wrappedDelta(end.x - WebMercator.unit(GeoPoint(10, -179)).x)) < 1e-9)
        let middle = glide.camera(at: 0.5)
        #expect(abs(WorldViewCamera.wrappedDelta(middle.x - start.x)) < 2.0 / 360, "the short way")
    }

    /// A small zoom scales the drawing on screen; past the threshold, or at a new detail, a fresh one is asked for.
    @Test func zoomingScalesTheDrawingUntilItDrifts() {
        let camera = WorldViewCamera(level: .country, centre: Self.atlanta, size: Self.phone)
        let key = WorldViewMapDrawing.key(for: camera, generation: 0, dark: false)
        var facts = WorldViewMapFacts(detail: camera.detail, raster: nil, atlas: nil, found: [], places: [:], roads: .none, lands: [:])
        let drawing = WorldViewMapDrawing.build(key, facts: &facts)
        var near = camera
        near.setZoom(camera.zoom + 0.01)
        #expect(!drawing.isStale(for: WorldViewMapDrawing.key(for: near, generation: 0, dark: false)))
        #expect(abs(drawing.placement(on: near).scale - near.scale / camera.scale) < 1e-9)
        var farther = camera
        farther.setZoom(camera.zoom + 0.2)
        #expect(drawing.isStale(for: WorldViewMapDrawing.key(for: farther, generation: 0, dark: false)))
    }

    // MARK: Marks

    /// A ring stands centred on its airport and a tower's foot on its airport, wherever the other marks are: the
    /// flight lines end at those same points (the 2026-11-02 bug drew every mark 11 pt right and 18 pt down of it).
    @Test func marksStandExactlyOnTheirAirports() throws {
        let size = CGSize(width: 400, height: 400)
        let camera = WorldViewCamera(level: .world, centre: GeoPoint(0, 0), size: size)
        let ringSpot = CGPoint(x: 100, y: 200), towerSpot = CGPoint(x: 280, y: 200)
        let flights = WorldFlightMap(arcs: [], rings: [Self.mark("TUL", at: ringSpot, camera)],
                                     found: [Self.mark("ATL", at: towerSpot, camera)], airportCount: 1, flightCount: 0)
        let inked = try Self.inkBounds(WorldFlightMarks(camera: camera, flights: flights, namedRing: nil), size: size)
        let ring = try #require(inked(CGRect(x: 0, y: 0, width: 200, height: 400)))
        #expect(abs(ring.midX - ringSpot.x) <= 1, "ring x \(ring.midX)")
        #expect(abs(ring.midY - ringSpot.y) <= 1, "ring y \(ring.midY)")
        let tower = try #require(inked(CGRect(x: 200, y: 0, width: 200, height: 400)))
        // The sprite is 22 pt wide with 2 pt clear down its left side, and 20 tall with its foot 2 pt above its bottom.
        #expect(abs(tower.minX - (towerSpot.x - 9)) <= 1, "tower left \(tower.minX)")
        #expect(abs(tower.minY - (towerSpot.y - 18)) <= 1, "tower top \(tower.minY)")
    }

    /// A state's label and a marker's label lie centred or hung on their own point, not the layer's widest guide.
    @Test func aPinnedViewStandsOnItsGuide() throws {
        let size = CGSize(width: 300, height: 300)
        let view = ZStack(alignment: .topLeading) {
            Color.black.frame(width: 40, height: 20).worldMapPinned(at: CGPoint(x: 150, y: 150), .center)
            Color.black.frame(width: 90, height: 60).worldMapPinned(at: CGPoint(x: 280, y: 280), .bottomTrailing)
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
        let inked = try Self.inkBounds(view, size: size)
        let centred = try #require(inked(CGRect(x: 100, y: 100, width: 90, height: 70)))
        #expect(abs(centred.midX - 150) <= 1 && abs(centred.midY - 150) <= 1)
        let corner = try #require(inked(CGRect(x: 185, y: 215, width: 115, height: 85)))
        #expect(abs(corner.maxX - 280) <= 1 && abs(corner.maxY - 280) <= 1)
    }

    // MARK: Labels

    /// With nothing in the way a label takes its nearest, likeliest spot: beside the city, over it from State in.
    @Test func anOpenMapKeepsTheUsualSpot() {
        let pin = Self.pin("atlanta", at: Self.atlanta)
        let clusters = [WorldViewCluster(anchor: pin, members: [pin])]
        let far = WorldViewLabelPlacement.spots(for: clusters, detail: AtlasZoomLevel.country.detail, found: [], flights: .none)
        #expect(far["atlanta"] == .fallback(skyline: false))
        let near = WorldViewLabelPlacement.spots(for: clusters, detail: AtlasZoomLevel.city.detail, found: [], flights: .none)
        #expect(near["atlanta"] == .fallback(skyline: true))
    }

    /// A label moves off the found hexes when there is ground to spare, at every detail.
    @Test func aLabelKeepsOffTheFoundGround() throws {
        let pin = Self.pin("atlanta", at: Self.atlanta)
        let clusters = [WorldViewCluster(anchor: pin, members: [pin])]
        for detail in AtlasZoomDetail.all {
            let grid = detail.hexGrid, scale = detail.pointsPerMercatorUnit, skyline = detail.level >= .state
            let city = CGPoint(x: pin.x * scale, y: pin.y * scale)
            var found = Set<HexCell>()
            // A disc of found ground 60 pt round the city.
            for dy in stride(from: -60.0, through: 60, by: 5) {
                for dx in stride(from: -60.0, through: 60, by: 5) where dx * dx + dy * dy <= 3_600 {
                    found.insert(grid.cell(x: (city.x + dx) / scale, y: (city.y + dy) / scale))
                }
            }
            let spots = WorldViewLabelPlacement.spots(for: clusters, detail: detail, found: found, flights: .none)
            let spot = try #require(spots["atlanta"])
            let area = WorldViewLabelPlacement.rect(side: spot.side, touching: CGPoint(x: city.x + spot.dx, y: city.y + spot.dy),
                                                    size: WorldViewLabelPlacement.labelSize(clusters[0], skyline: skyline))
            #expect(!Self.covers(area, found: found, grid: grid, scale: scale), "\(detail.halfSteps): \(spot)")
        }
    }

    /// Two labels that want one spot take two, and a label keeps off an airport's mark.
    @Test func labelsKeepOffEachOtherAndTheAirports() throws {
        let detail = AtlasZoomLevel.country.detail, scale = detail.pointsPerMercatorUnit
        let first = Self.pin("atlanta", at: Self.atlanta)
        let second = WorldViewCityPin(token: "second", name: "Second", sizeClass: first.sizeClass, population: 1,
                                      x: first.x, y: first.y + 34 / scale)
        let clusters = [first, second].map { WorldViewCluster(anchor: $0, members: [$0]) }
        let unit = WebMercator.unit(Self.atlanta)
        let airport = WorldFlightAirportMark(code: "ATL", name: "Atlanta", mercator: CGPoint(x: unit.x + 25 / scale, y: unit.y))
        let flights = WorldFlightMap(arcs: [], rings: [], found: [airport], airportCount: 1, flightCount: 0)
        let spots = WorldViewLabelPlacement.spots(for: clusters, detail: detail, found: [], flights: flights)
        let rects = try clusters.map { cluster -> CGRect in
            let spot = try #require(spots[cluster.anchor.token])
            let city = CGPoint(x: cluster.anchor.x * scale + spot.dx, y: cluster.anchor.y * scale + spot.dy)
            return WorldViewLabelPlacement.rect(side: spot.side, touching: city,
                                                size: WorldViewLabelPlacement.labelSize(cluster, skyline: false))
        }
        #expect(!rects[0].intersects(rects[1]))
        let tower = CGRect(x: airport.mercator.x * scale - 11, y: airport.mercator.y * scale - 20, width: 60, height: 22)
        #expect(!rects[0].intersects(tower) && !rects[1].intersects(tower))
    }

    /// The plans are the same however often they are worked out, so a label stands still between visits.
    @Test func thePlanIsDeterministic() {
        let pins = [Self.pin("a", at: Self.atlanta), Self.pin("b", at: GeoPoint(33.8, -84.3))]
        let one = WorldViewMarkerPlan.all(pins: pins, found: [:], flights: .none)
        let two = WorldViewMarkerPlan.all(pins: pins.reversed(), found: [:], flights: .none)
        #expect(one.count == AtlasZoomDetail.all.count)
        for detail in AtlasZoomDetail.all { #expect(one[detail]?.spots == two[detail]?.spots) }
    }

    // MARK: Airports

    private static func airport(grounds: WorldAirportGrounds, runways: [WorldRunway] = []) -> WorldAirport {
        WorldAirport(token: "ATL", iata: "ATL", ident: "KATL", point: GeoPoint(33.6407, -84.4277), countryCode: "US", size: .large,
                     timeZoneIdentifier: "America/New_York", englishName: "Atlanta", spanishName: nil, englishCity: "Atlanta",
                     spanishCity: nil, grounds: grounds, runways: runways)
    }

    /// An airport fills the hexes on its grounds, more of them closer in, and never fewer than the one under its point.
    @Test func anAirportFillsItsGrounds() {
        let ring = [GeoPoint(33.62, -84.47), GeoPoint(33.66, -84.47), GeoPoint(33.66, -84.39), GeoPoint(33.62, -84.39)]
        let airport = Self.airport(grounds: .outline(ring))
        let world = AtlasZoomLevel.world.detail.hexGrid
        #expect(WorldViewAirportTiles.cells(of: [airport], in: world) == [world.cell(containing: airport.point)], "one hex far out")
        let closest = AtlasZoomDetail(halfSteps: AtlasZoomDetail.maxHalfSteps).hexGrid
        let cells = WorldViewAirportTiles.cells(of: [airport], in: closest)
        #expect(cells.count > 20)
        #expect(cells.contains(closest.cell(containing: airport.point)))
        #expect(cells.contains(closest.cell(containing: GeoPoint(33.64, -84.40))), "inside, east")
        #expect(!cells.contains(closest.cell(containing: GeoPoint(33.72, -84.43))), "outside, north")
        let circle = Self.airport(grounds: .circle(radiusMetres: 1_500))
        #expect(!WorldViewAirportTiles.cells(of: circle, in: closest).isEmpty)
    }

    /// A ring crossing 180° keeps the hex under its point rather than scanning half the world.
    @Test func aRingAcrossTheAntimeridianIsBounded() {
        let ring = [GeoPoint(-17, 179.99), GeoPoint(-17, -179.99), GeoPoint(-16.9, -179.99), GeoPoint(-16.9, 179.99)]
        let closest = AtlasZoomDetail(halfSteps: AtlasZoomDetail.maxHalfSteps).hexGrid
        #expect(WorldViewAirportTiles.cells(of: Self.airport(grounds: .outline(ring)), in: closest).count == 1)
    }

    /// The drawing gives an airport's hexes their own colour, keeps them out of the roads' clip, and draws its
    /// runways only from City in.
    @Test func theDrawingShowsAirports() {
        let runway = WorldRunway(start: GeoPoint(33.64, -84.45), end: GeoPoint(33.64, -84.41), widthMetres: 45)
        let airport = Self.airport(grounds: .circle(radiusMetres: 4_000), runways: [runway])
        let build = { (level: AtlasZoomLevel) -> WorldViewMapDrawing in
            let camera = WorldViewCamera(level: level, centre: airport.point, size: Self.phone)
            let key = WorldViewMapDrawing.key(for: camera, generation: 0, dark: false)
            var facts = WorldViewMapFacts(detail: camera.detail, raster: nil, atlas: nil, found: [], places: [:], roads: .none, lands: [:],
                                          airports: WorldViewAirportTiles.cells(of: [airport], in: camera.detail.hexGrid),
                                          runways: WorldViewAirportTiles.runways(of: [airport]))
            return WorldViewMapDrawing.build(key, facts: &facts)
        }
        let city = build(.city)
        #expect(city.hexes.contains { $0.fill == WorldViewInk.airport.fill })
        #expect(city.uncovered.isEmpty)
        #expect(!city.runways.isEmpty)
        #expect(build(.state).runways.isEmpty)
    }

    // MARK: Helpers

    private static func mark(_ code: String, at point: CGPoint, _ camera: WorldViewCamera) -> WorldFlightAirportMark {
        let spot = camera.mercator(at: point)
        return WorldFlightAirportMark(code: code, name: code, mercator: CGPoint(x: spot.x, y: spot.y))
    }

    private static func pin(_ token: String, at point: GeoPoint) -> WorldViewCityPin {
        let unit = WebMercator.unit(point)
        return WorldViewCityPin(token: token, name: "Atlanta", sizeClass: .city, population: 1_000, x: unit.x, y: unit.y)
    }

    /// Whether any ground in `area` is found, looking finer than the placer does.
    private static func covers(_ area: CGRect, found: Set<HexCell>, grid: WorldViewHexGrid, scale: Double) -> Bool {
        for y in stride(from: Double(area.minY) + 5, to: Double(area.maxY), by: 10) {
            for x in stride(from: Double(area.minX) + 5, to: Double(area.maxX), by: 10)
            where found.contains(grid.cell(x: WorldViewCamera.wrap(x / scale), y: y / scale)) {
                return true
            }
        }
        return false
    }

    /// Renders `view` at one pixel a point and returns a lookup of the bounds of its opaque pixels inside a region.
    private static func inkBounds(_ view: some View, size: CGSize) throws -> (CGRect) -> CGRect? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let snapshot = pixels
        return { region in
            var bounds: CGRect?
            for y in Int(region.minY)..<min(Int(region.maxY), height) {
                for x in Int(region.minX)..<min(Int(region.maxX), width) where snapshot[(y * width + x) * 4 + 3] > 128 {
                    let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                    bounds = bounds?.union(pixel) ?? pixel
                }
            }
            return bounds
        }
    }
}

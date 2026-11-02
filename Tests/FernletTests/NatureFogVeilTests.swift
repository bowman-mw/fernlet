import CoreGraphics
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// A found airport's translucent fog (``NatureFogVeils``, owner 2026-11-02): the grounds draw half-strength fog with
/// nothing growing on them, the cells walked stay fully clear, and the veil never joins the lifted history.
@MainActor
struct NatureFogVeilTests {
    static let scale = NatureFogScale(radius: 19, reduced: false)
    static let palette = NatureFogPalette(dark: false, highContrast: false)
    /// A cell in the Portland area, at the middle of the made-up airport.
    static let middle = NatureFogRules.cell(col: 523_420, row: 761_220)

    /// An airport whose grounds are `grounds`, or a square about a kilometre across round ``middle``.
    private func airport(_ token: String = "TST", grounds: WorldAirportGrounds? = nil) -> WorldAirport {
        let at = MercatorHexGrid.centreGeo(of: Self.middle)
        let square = [GeoPoint(at.latitude + 0.005, at.longitude - 0.007), GeoPoint(at.latitude + 0.005, at.longitude + 0.007),
                      GeoPoint(at.latitude - 0.005, at.longitude + 0.007), GeoPoint(at.latitude - 0.005, at.longitude - 0.007)]
        return WorldAirport(token: token, iata: token, ident: token, point: at, countryCode: "US", size: .large,
                            timeZoneIdentifier: "America/Los_Angeles", englishName: token, spanishName: nil, englishCity: token,
                            spanishCity: nil, grounds: grounds ?? .outline(square))
    }

    private func grower(_ clearing: NatureFogClearing) -> NatureFogGrower {
        NatureFogGrower(scale: Self.scale, clearing: clearing, atlas: NatureFogAtlas(palette: Self.palette))
    }

    /// The 256-pt tile holding ``middle``.
    private var key: NatureTileKey {
        let centre = Self.scale.centre(of: Self.middle)
        return NatureTileKey(x: Int((centre.x / NatureFogTileBook.tileSize).rounded(.down)),
                             y: Int((centre.y / NatureFogTileBook.tileSize).rounded(.down)))
    }

    @Test func theGroundsDrawVeilsWithNothingGrowingAndWalkedCellsStayClear() {
        let walked = Self.middle
        let clearing = NatureFogClearing(lifted: [walked], veils: NatureFogVeils(airports: [airport()]))
        #expect(clearing.isClear(walked) && !clearing.isVeiled(walked), "where the person walked is fully clear")
        let neighbour = MercatorHexGrid.neighbours(of: walked)[0]
        #expect(clearing.isClear(neighbour) && clearing.isVeiled(neighbour))
        let far = NatureFogRules.cell(col: 523_420, row: 761_000)
        #expect(!clearing.isClear(far) && !clearing.isVeiled(far), "outside the grounds is ordinary fog")

        let layout = grower(clearing).layout(in: NatureFogTileBook.area(of: key))
        let centre = Self.scale.centre(of: walked)
        #expect(!layout.veils.isEmpty)
        #expect(layout.hexes.isEmpty && layout.pieces.isEmpty && layout.trees.isEmpty, "nothing grows inside the grounds")
        #expect(!layout.veils.contains { $0.centre == centre })
        // The walked hex may sit at the tile's edge: only the neighbours inside the tile draw here.
        let area = NatureFogTileBook.area(of: key)
        let inTile = MercatorHexGrid.neighbours(of: walked).map { Self.scale.centre(of: $0) }.filter(area.contains)
        #expect(!inTile.isEmpty)
        #expect(inTile.allSatisfy { point in layout.veils.contains { $0.centre == point } })
    }

    @Test func aRunwayStaysClearThroughTheVeilWithNoGaps() {
        let at = MercatorHexGrid.centreGeo(of: Self.middle)
        let start = GeoPoint(at.latitude, at.longitude - 0.003), end = GeoPoint(at.latitude + 0.001, at.longitude + 0.003)
        let square = [GeoPoint(at.latitude + 0.005, at.longitude - 0.007), GeoPoint(at.latitude + 0.005, at.longitude + 0.007),
                      GeoPoint(at.latitude - 0.005, at.longitude + 0.007), GeoPoint(at.latitude - 0.005, at.longitude - 0.007)]
        let runway = WorldRunway(start: start, end: end, widthMetres: 45)
        let field = WorldAirport(token: "RWY", iata: "RWY", ident: "RWY", point: at, countryCode: "US", size: .large,
                                 timeZoneIdentifier: "America/Los_Angeles", englishName: "RWY", spanishName: nil, englishCity: "RWY",
                                 spanishCity: nil, grounds: .outline(square), runways: [runway])
        let clearing = NatureFogClearing(veils: NatureFogVeils(airports: [field]))
        // Every hex along the middle line: a strip with no veil left across it.
        for step in 0...40 {
            let share = Double(step) / 40
            let point = GeoPoint(start.latitude + (end.latitude - start.latitude) * share,
                                 start.longitude + (end.longitude - start.longitude) * share)
            let cell = MercatorHexGrid.cell(containing: point)
            #expect(clearing.isClear(cell) && !clearing.isVeiled(cell), "step \(step)")
        }
        let beside = MercatorHexGrid.cell(containing: GeoPoint(at.latitude - 0.003, at.longitude))
        #expect(clearing.isClear(beside) && clearing.isVeiled(beside), "the rest of the grounds keep the veil")
        // Past the grounds the runway clears nothing.
        let outside = NatureFogRules.cell(col: 523_420, row: 761_000)
        #expect(!clearing.isClear(outside))
    }

    @Test func noFoundAirportDrawsNoVeil() {
        let layout = grower(NatureFogClearing()).layout(in: NatureFogTileBook.area(of: key))
        #expect(layout.veils.isEmpty)
        #expect(!layout.hexes.isEmpty)
        #expect(NatureFogVeils.none.isEmpty && !NatureFogVeils.none.covers(Self.middle))
    }

    @Test func theTileShowsTheMapThroughTheVeilAndFullyWhereWalked() throws {
        let clearing = NatureFogClearing(lifted: [Self.middle], veils: NatureFogVeils(airports: [airport()]))
        let order = NatureFogTileOrder(key: key, scale: Self.scale, palette: Self.palette, clearing: clearing, generation: 0, pixelScale: 1)
        let tile = NatureFogTileContent.draw(order, grower: grower(clearing))
        let picture = try #require(tile.ground)
        let area = NatureFogTileBook.area(of: key), centre = Self.scale.centre(of: Self.middle)
        let walked = CGPoint(x: centre.x - area.minX, y: centre.y - area.minY)
        // Half a tile from the walked hex, inside the grounds.
        let veiled = CGPoint(x: (walked.x + 128).truncatingRemainder(dividingBy: 256), y: walked.y)
        #expect(try alpha(of: picture, at: walked) == 0)
        let through = try alpha(of: picture, at: veiled)
        #expect(abs(Double(through) / 255 - Double(NatureFogDrawer.veilOpacity)) < 0.02, "got \(through)")
    }

    /// The opacity (0–255) of one pixel of `image`.
    private func alpha(of image: CGImage, at point: CGPoint) throws -> UInt8 {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: -point.x.rounded(.down), y: point.y.rounded(.down) + 1 - height,
                                       width: CGFloat(image.width), height: height))
        return pixel[3]
    }

    @Test func findingAnAirportRedrawsAndForgettingOneCoversItsGroundAgain() {
        let book = NatureFogTileBook(scale: Self.scale, palette: Self.palette, clearing: NatureFogClearing(), pixelScale: 1)
        let veils = NatureFogVeils(airports: [airport()])
        let found = book.change(to: NatureFogClearing(veils: veils))
        #expect(found.reset && !found.covers)
        #expect(book.clearing.veils == veils)
        let forgotten = book.change(to: NatureFogClearing())
        #expect(forgotten.reset && forgotten.covers, "no history lingers once the airport leaves the passport")
    }

    @Test func aWalkInsideTheGroundsRedrawsOnlyWhatItReaches() {
        let veils = NatureFogVeils(airports: [airport()])
        let book = NatureFogTileBook(scale: Self.scale, palette: Self.palette, clearing: NatureFogClearing(veils: veils), pixelScale: 1)
        let change = book.change(to: NatureFogClearing(lifted: [Self.middle], veils: veils))
        #expect(!change.reset && !change.covers)
    }

    @Test func veilsMatchByTheirAirportsInAnyOrder() {
        let one = NatureFogVeils(airports: [airport("AAA"), airport("BBB")])
        let other = NatureFogVeils(airports: [airport("BBB"), airport("AAA")])
        #expect(one == other)
        #expect(one != NatureFogVeils(airports: [airport("AAA")]))
        #expect(one.holds(everyAirportIn: NatureFogVeils(airports: [airport("AAA")])))
        #expect(!NatureFogVeils(airports: [airport("AAA")]).holds(everyAirportIn: one))
    }

    @Test func aCircleAirportIsVeiledAndARingAcrossTheDateLineIsLeftOut() {
        let circle = NatureFogVeils(airports: [airport(grounds: .circle(radiusMetres: 300))])
        #expect(circle.covers(Self.middle))
        #expect(!circle.covers(NatureFogRules.cell(col: 523_420, row: 761_000)))
        let wide = [GeoPoint(1, 179.9), GeoPoint(1, -179.9), GeoPoint(-1, -179.9), GeoPoint(-1, 179.9)]
        #expect(NatureFogVeils(airports: [airport(grounds: .outline(wide))]).isEmpty)
    }
}

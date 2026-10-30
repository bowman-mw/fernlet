import CoreGraphics
import Foundation
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// The land under the fog (World-Exploration-Spec §1, `ex-biomes`, `ex-flora`, `ex-seasons`): each hex draws the
/// terrain set the atlas's classifier gives it, the seasons follow the hemisphere, grassland and temperate forest
/// stay exactly the approved nature fog, the sea has no seams and a sand line at the coast, every set grows its
/// own pieces, and with no atlas the fog is today's.
@MainActor
struct WorldTerrainTests {
    static let full = NatureFogScale(radius: 19, reduced: false)
    static let light = NatureFogPalette(dark: false, highContrast: false)

    /// The bundled atlas.
    private static func shippedAtlas() throws -> WorldAtlas {
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        return try WorldAtlas(data: Data(contentsOf: url))
    }

    /// Noon UTC on `month`/15/2026, read in a UTC Gregorian calendar.
    private static func day(month: Int) -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: 15, hour: 12)) ?? Date()
        return (date, calendar)
    }

    private static func terrain(_ atlas: WorldAtlas, month: Int, override: AtlasSeason? = nil) -> NatureFogTerrain {
        let (date, calendar) = day(month: month)
        return NatureFogTerrain(atlas: atlas, date: date, calendar: calendar, seasonOverride: override)
    }

    /// A grower over a field whose every hex is `answer`'s.
    private func grower(_ answer: @escaping (HexCell) -> TerrainHex, clearing: NatureFogClearing = NatureFogClearing()) -> NatureFogGrower {
        NatureFogGrower(scale: Self.full, clearing: clearing, atlas: NatureFogAtlas(palette: Self.light),
                        terrain: NatureTerrainMemo(answer: answer))
    }

    /// A 4 × 4-tile area round a Portland-area cell (the nature fog tests' patch).
    private static let field: CGRect = {
        let origin = full.centre(of: NatureFogRules.cell(col: 523_400, row: 761_200))
        return CGRect(x: origin.x, y: origin.y, width: 900, height: 900)
    }()

    private static func everywhere(_ set: TerrainSet, season: AtlasSeason = .summer, flora: TerrainFlora = .everything) -> TerrainHex {
        TerrainHex(set: set, season: season, flora: flora, floraPicks: !set.isApproved)
    }

    // MARK: ex-biomes: the set comes from the classifier

    @Test func eachHexDrawsTheSetTheClassifierGivesRealPlaces() throws {
        let atlas = try Self.shippedAtlas()
        let memo = NatureTerrainMemo(terrain: Self.terrain(atlas, month: 7))
        let classifier = AtlasTerrainClassifier(atlas: atlas)
        let places: [(String, GeoPoint, TerrainSet)] = [
            ("the Oregon Coast Range", GeoPoint(45.60, -123.40), .forest), ("the Sahara", GeoPoint(23.4, 12.0), .desert),
            ("the mid-Pacific", GeoPoint(0, -150), .water), ("Antarctica", GeoPoint(-80, 0), .ice),
            ("the Amazon near Manaus", GeoPoint(-4, -63), .tropical), ("Svalbard", GeoPoint(78.5, 16.5), .tundra),
            ("the Bernese Alps", GeoPoint(46.55, 7.98), .mountain), ("Nunavut's taiga", GeoPoint(65, -100), .boreal),
            ("Times Square", GeoPoint(40.758, -73.9855), .urban), ("the Mato Grosso savanna", GeoPoint(-12.5, -55.5), .meadow),
        ]
        for (name, point, set) in places {
            let cell = MercatorHexGrid.cell(containing: point), centre = MercatorHexGrid.centreGeo(of: cell)
            let expected = TerrainSet(classifier.terrain(of: cell), urban: atlas.isUrban(centre))
            let drawn = memo.hex(cell)
            #expect(drawn.set == expected, "\(name): the drawn set is the classifier's")
            #expect(drawn.set == set, "\(name) draws \(set)")
            #expect(memo.isUrban(centre) == atlas.isUrban(centre), "\(name): the short list answers as the atlas")
            let field = NatureFogGrower(scale: Self.full, clearing: NatureFogClearing(), atlas: NatureFogAtlas(palette: Self.light), terrain: memo)
            let at = Self.full.centre(of: cell)
            let layout = field.layout(in: CGRect(origin: at, size: .zero).insetBy(dx: -60, dy: -60))
            if set == .water {
                #expect(layout.seas.contains { $0.centre == at } && !layout.hexes.contains { $0.centre == at }, "\(name): the sea is water")
            } else {
                #expect(layout.hexes.first { $0.centre == at }?.look == drawn.look, "\(name): land is drawn in its own look")
            }
        }
    }

    @Test func savannaAndShrublandDrawTheMeadowWithTheirOwnFlora() throws {
        let atlas = try Self.shippedAtlas()
        let memo = NatureTerrainMemo(terrain: Self.terrain(atlas, month: 7))
        let savanna = memo.hex(MercatorHexGrid.cell(containing: GeoPoint(-12.5, -55.5)))
        #expect(savanna.set == .meadow && savanna.floraPicks && !savanna.followsApproved)
        #expect(savanna.flora.contains(.palms) && !savanna.flora.contains(.conifers), "Aw: palms, no pines")
        let sahara = memo.hex(MercatorHexGrid.cell(containing: GeoPoint(23.4, 12.0)))
        #expect(!sahara.flora.contains(.cacti), "no cacti outside the Americas")
        let forest = memo.hex(MercatorHexGrid.cell(containing: GeoPoint(45.60, -123.40)))
        #expect(forest.followsApproved && forest.look == .approved, "temperate forest in summer is the approved fog")
    }

    @Test func eachHexIsClassifiedOnceAndKept() {
        var asked = 0
        let memo = NatureTerrainMemo { _ in
            asked += 1
            return .approved
        }
        let cell = NatureFogRules.cell(col: 523_410, row: 761_210)
        _ = memo.hex(cell)
        _ = memo.hex(cell)
        #expect(asked == 1)
        let field = NatureFogGrower(scale: Self.full, clearing: NatureFogClearing(), atlas: NatureFogAtlas(palette: Self.light), terrain: memo)
        _ = field.layout(in: Self.field)
        let first = asked
        _ = field.layout(in: Self.field)
        #expect(asked == first, "a second layout of the same area asks the atlas nothing")
    }

    // MARK: Grassland and temperate forest stay the approved nature fog

    @Test func theMeadowAndForestPalettesAreTheApprovedOnes() {
        for dark in [false, true] {
            for contrast in [false, true] {
                let approved = NatureFogPalette(dark: dark, highContrast: contrast)
                for set in [TerrainSet.meadow, .forest] {
                    let look = Self.everywhere(set).look
                    #expect(look == .approved)
                    let palette = NatureFogPalette(dark: dark, highContrast: contrast, look: look)
                    #expect(NaturePaint.allCases.map(palette.rgb) == NaturePaint.allCases.map(approved.rgb))
                }
            }
        }
        let desert = NatureFogPalette(dark: true, highContrast: false, look: TerrainLook(set: .desert, season: .summer))
        #expect(desert.rgb(.grassA) == NatureFogPalette.mix(0xE3C98F, toward: 0x141C12, by: 0.42), "Dark Mode mixes as palFor")
        #expect(desert.rgb(.seam) == NatureFogPalette.mix(0xCBAE70, toward: 0x141C12, by: 0.5))
        let iceContrast = NatureFogPalette(dark: false, highContrast: true, look: TerrainLook(set: .ice, season: .summer))
        #expect(iceContrast.rgb(.seam) == 0x2F4A24 && iceContrast.seamWidth == 1.8, "Increase Contrast as today")
        #expect(desert.rgb(.fixed(0xC9AA6A)) == NatureFogPalette.mix(0xC9AA6A, toward: 0x141C12, by: 0.3))
        #expect(desert.rgb(.pair(light: 0xB6DAEE, dark: 0x6E93AE)) == 0x6E93AE)
    }

    @Test func approvedLandGrowsExactlyTodaysNatureFog() {
        let today = NatureFogGrower(scale: Self.full, clearing: NatureFogClearing(), atlas: NatureFogAtlas(palette: Self.light))
        for set in [TerrainSet.meadow, .forest] {
            let land = grower { _ in TerrainHex(set: set, season: .summer, flora: .everything, floraPicks: false) }
            let a = today.layout(in: Self.field), b = land.layout(in: Self.field)
            #expect(a.hexes.map { "\($0.centre)\($0.paint)" } == b.hexes.map { "\($0.centre)\($0.paint)" })
            #expect(a.specks.map(\.rect) == b.specks.map(\.rect) && a.waterMarks.map(\.rect) == b.waterMarks.map(\.rect))
            #expect(a.pieces.map { "\($0.sprite)\($0.frame)" } == b.pieces.map { "\($0.sprite)\($0.frame)" })
            #expect(b.pieces.allSatisfy { $0.look == .approved } && b.seas.isEmpty && b.marks.isEmpty && b.coasts.isEmpty)
            #expect(a.trees.map(\.anchor) == b.trees.map(\.anchor))
        }
    }

    @Test func aTileOfRealTemperateForestIsTheApprovedTile() async throws {
        let atlas = try Self.shippedAtlas()
        let terrain = Self.terrain(atlas, month: 7)
        let cell = MercatorHexGrid.cell(containing: GeoPoint(45.60, -123.40))
        let key = NatureFogTileBook.key(at: Self.full.centre(of: cell))
        let real = NatureFogTileBook(scale: Self.full, palette: Self.light, clearing: NatureFogClearing(), pixelScale: 1, terrain: terrain)
        let plain = NatureFogTileBook(scale: Self.full, palette: Self.light, clearing: NatureFogClearing(), pixelScale: 1)
        // Through map-perf P1's painters, off the main thread: the content seam draws the same picture.
        let a = await real.tile(key)
        let b = await plain.tile(key)
        let bytes = { (image: CGImage?) in image?.dataProvider?.data.map { $0 as Data } }
        #expect(bytes(a.ground) != nil && bytes(a.ground) == bytes(b.ground), "the ground picture is pixel for pixel today's")
        #expect(a.pieces.map { "\($0.sprite)\($0.frame)\($0.look)" } == b.pieces.map { "\($0.sprite)\($0.frame)\($0.look)" })
    }

    @Test func withNoAtlasTheFogIsTodaysNatureFog() {
        #expect(NatureFogTerrain.home(nil) == nil)
        let plain = NatureFogGrower(scale: Self.full, clearing: NatureFogClearing(), atlas: NatureFogAtlas(palette: Self.light))
        #expect(plain.terrain == nil && plain.land(MercatorHexGrid.cell(containing: GeoPoint(0, -150))) == .approved)
        let book = NatureFogTileBook(scale: Self.full, palette: Self.light, clearing: NatureFogClearing(), pixelScale: 1)
        #expect(book.terrain == nil)
        let viewport = MapViewport.around(GeoPoint(45.5205, -122.6255), heightMetres: 900, size: CGSize(width: 402, height: 874))
        let scene = NatureFogScene(viewport: viewport, clearing: NatureFogClearing(), palette: Self.light, motion: NatureFogMotion(reduceMotion: true))
        #expect(scene.terrain == nil)
    }

    // MARK: ex-seasons: by hemisphere

    @Test func theSeasonFollowsTheHemisphere() throws {
        let atlas = try Self.shippedAtlas()
        let portland = MercatorHexGrid.cell(containing: GeoPoint(45.60, -123.40))
        let victoria = MercatorHexGrid.cell(containing: GeoPoint(-37.55, 145.95))
        let amazon = MercatorHexGrid.cell(containing: GeoPoint(-4, -63))
        let april = NatureTerrainMemo(terrain: Self.terrain(atlas, month: 4))
        #expect(april.hex(portland).season == .spring, "Portland's April is spring")
        #expect(april.hex(victoria).set == .forest && april.hex(victoria).season == .autumn, "Melbourne's is autumn")
        #expect(april.hex(amazon).season == .summer, "the tropics look the same all year")
        let july = NatureTerrainMemo(terrain: Self.terrain(atlas, month: 7))
        #expect(july.hex(portland).season == .summer && july.hex(victoria).season == .winter)
        let forced = NatureTerrainMemo(terrain: Self.terrain(atlas, month: 7, override: .winter))
        #expect(forced.hex(portland).season == .winter, "the DEBUG override paints winter")
        #expect(forced.hex(amazon).season == .summer, "only grassland, forest and cropland change")
    }

    @Test func winterIsSnowBareTreesAndSnowyPines() {
        let winter = grower { _ in Self.everywhere(.forest, season: .winter) }.layout(in: Self.field)
        let summer = grower { _ in Self.everywhere(.forest) }.layout(in: Self.field)
        #expect(winter.hexes.allSatisfy { $0.look == TerrainLook(set: .meadow, season: .winter) })
        #expect(!winter.pieces.contains { if case .tree = $0.sprite { true } else { false } }, "no leafy trees in winter")
        #expect(winter.pieces.contains { if case .bare = $0.sprite { true } else { false } })
        #expect(winter.pieces.contains { if case .snowyPine = $0.sprite { true } else { false } })
        #expect(!winter.pieces.contains { if case .flowers = $0.sprite { true } else { false } }, "no flowers in winter")
        #expect(winter.trees.allSatisfy { tree in
            let at = NatureFogRules.offset(of: tree.anchor)
            return NatureFogRules.tree(at.col, at.row) != nil
        }, "a winter tree stands only where the approved field has one (bare trees are smaller, so a few more fit)")
        #expect(!summer.trees.isEmpty && abs(winter.trees.count - summer.trees.count) < summer.trees.count / 10)
        let snow = NatureFogPalette(dark: false, highContrast: false, look: TerrainLook(set: .meadow, season: .winter))
        #expect(snow.rgb(.grassA) == 0xEEF2F2, "snow on the ground")
    }

    @Test func springBlossomsAndAutumnTurnsGold() {
        let spring = grower { _ in Self.everywhere(.meadow, season: .spring) }.layout(in: Self.field)
        let summer = grower { _ in Self.everywhere(.meadow) }.layout(in: Self.field)
        func count(_ layout: NatureFogLayout, _ match: (NatureSprite) -> Bool) -> Int { layout.pieces.filter { match($0.sprite) }.count }
        let isFlowers: (NatureSprite) -> Bool = { if case .flowers = $0 { true } else { false } }
        #expect(count(spring, { if case .blossom = $0 { true } else { false } }) > 0, "blossom on some trees")
        #expect(count(spring, isFlowers) > count(summer, isFlowers), "more wildflowers")
        let autumn = NatureFogPalette(dark: false, highContrast: false, look: TerrainLook(set: .meadow, season: .autumn))
        #expect(autumn.rgb(.leafMid) == 0xC0612A && autumn.rgb(.leafHighlight) == 0xF2C14E && autumn.rgb(.speck) == 0xC68A3E,
                "gold and red trees, fallen leaves")
        let desert = NatureFogPalette(dark: false, highContrast: false, look: TerrainLook(set: .desert, season: .summer))
        #expect(TerrainHex.classify(terrain: .desert, urban: false, plants: [.cacti], latitude: 32, season: .winter).look
                    == TerrainLook(set: .desert, season: .summer), "the desert looks the same all year")
        #expect(desert.rgb(.grassA) == 0xE3C98F)
    }

    // MARK: Water over water, land over land

    @Test func theSeaHasNoSeamsWavesAndASandLineAtTheCoast() {
        let shoreline = 523_415
        let coast = grower { cell in
            NatureFogRules.offset(of: cell).col < shoreline ? Self.everywhere(.water) : Self.everywhere(.meadow)
        }
        let layout = coast.layout(in: Self.field)
        #expect(!layout.seas.isEmpty && !layout.coasts.isEmpty)
        let seaCentres = Set(layout.seas.map { "\($0.centre)" })
        #expect(!layout.hexes.contains { seaCentres.contains("\($0.centre)") }, "a sea hex is never a seamed land hex")
        #expect(layout.marks.contains { $0.ink == .pair(light: 0xB6DAEE, dark: 0x6E93AE) }, "a few wave marks")
        #expect(layout.trees.allSatisfy { NatureFogRules.offset(of: $0.anchor).col >= shoreline }, "nothing stands on the sea")
        for line in layout.coasts {
            let middle = CGPoint(x: (line.from.x + line.to.x) / 2, y: (line.from.y + line.to.y) / 2)
            let nearest = layout.seas.min { hypot($0.centre.x - middle.x, $0.centre.y - middle.y) < hypot($1.centre.x - middle.x, $1.centre.y - middle.y) }
            #expect(nearest.map { hypot($0.centre.x - middle.x, $0.centre.y - middle.y) < Self.full.radius } == true, "the sand runs along a sea hex's edge")
        }
    }

    @Test func walksClearTheFogExactlyAsTodayOverAnyLand() {
        let walked = Set((523_405..<523_412).map { NatureFogRules.cell(col: $0, row: 761_220) })
        let clearing = NatureFogClearing(lifted: walked)
        for set in TerrainSet.allCases {
            let field = grower({ _ in Self.everywhere(set) }, clearing: clearing)
            for cell in walked { #expect(field.state(cell) == .clear, "\(set): a walked hex shows the map") }
            let next = NatureFogRules.cell(col: 523_412, row: 761_220)
            #expect(field.state(next) == .wild(.edge), "\(set): its neighbour is the plain edge")
        }
    }

    // MARK: ex-flora and every set's pieces

    @Test func everySetGrowsItsOwnPieces() {
        func pieces(_ hex: TerrainHex) -> NatureFogLayout { grower { _ in hex }.layout(in: Self.field) }
        func has(_ layout: NatureFogLayout, _ match: (NatureSprite) -> Bool) -> Bool { layout.pieces.contains { match($0.sprite) } }
        let tropical = pieces(Self.everywhere(.tropical, flora: [.palms, .broad]))
        #expect(has(tropical) { if case .palm = $0 { true } else { false } }, "palms in the tropics")
        #expect(has(pieces(Self.everywhere(.boreal, flora: [.conifers, .broad]))) { if case .pine = $0 { true } else { false } })
        let desert = pieces(Self.everywhere(.desert, flora: [.cacti]))
        #expect(has(desert) { if case .cactus = $0 { true } else { false } }, "cacti in the Americas' deserts")
        #expect(desert.marks.contains { $0.ink == .fixed(0xC9AA6A) }, "sand ripples")
        #expect(!has(pieces(Self.everywhere(.desert, flora: []))) { if case .cactus = $0 { true } else { false } }, "no cacti in the Sahara")
        #expect(has(pieces(Self.everywhere(.mountain, flora: [.conifers]))) { if case .peak = $0 { true } else { false } }, "peaks")
        #expect(has(pieces(Self.everywhere(.urban, flora: [.broad]))) { if case .house = $0 { true } else { false } }, "roofs")
        #expect(has(pieces(Self.everywhere(.crops))) { if case .crops = $0 { true } else { false } }, "crop rows")
        let tundra = pieces(Self.everywhere(.tundra)), ice = pieces(Self.everywhere(.ice))
        #expect(tundra.trees.isEmpty && ice.trees.isEmpty, "nothing stands on tundra or ice")
        #expect(tundra.marks.contains { $0.ink == .fixed(0xC0743A) } && ice.marks.contains { $0.ink == .fixed(0x9DB9C6) })
        let mountainInTheTropics = pieces(Self.everywhere(.mountain, flora: [.broad]))
        #expect(!has(mountainInTheTropics) { if case .pine = $0 { true } else { false } }, "conifers thin out in the tropics")
        let north = pieces(Self.everywhere(.boreal, flora: [.conifers]))
        #expect(!has(north) { if case .palm = $0 { true } else { false } }, "palms never grow in the north")
    }

    @Test func theNewPiecesAreDrawnAndStandOverSeveralHexes() {
        let atlas = NatureFogAtlas(palette: Self.light)
        let keys: [NatureSprite] = [.palm(height: 18, variant: 1), .cactus(height: 13, variant: 3), .peak(width: 26, height: 21, variant: 1),
                                    .house(variant: 0), .house(variant: 2), .bare(radius: 10, variant: 0), .crops(wheat: true),
                                    .snowyPine(height: 19, odd: false), .blossom(radius: 12, variant: 0)]
        let look = TerrainLook(set: .desert, season: .summer)
        for key in keys {
            #expect(atlas.sprite(key) != nil && atlas.sprite(key, look: look) != nil, "\(key) is drawn")
        }
        let peak = NatureFogAtlas.art(.peak(width: 26, height: 21, variant: 1)).bounds
        #expect((peak?.width ?? 0) >= 3 * 8, "a big peak spans 3–4 hexes")
        #expect(NatureFogAtlas.art(.snowyPine(height: 19, odd: false)).pixels.count == NatureFogAtlas.art(.pine(height: 19, odd: false)).pixels.count)
        #expect(NatureFogAtlas.art(.snowyPine(height: 19, odd: false)).pixels.values.contains(.fixed(0xF5F8F8)), "snow on the tiers")
        #expect(NatureFogAtlas.art(.blossom(radius: 12, variant: 0)).pixels.count == NatureFogAtlas.art(.tree(radius: 12, variant: 0)).pixels.count)
    }

    // MARK: Decoration, and the layer guards

    @Test func terrainIsDecorationAndKeepsTheLayerGuards() async throws {
        let atlas = try Self.shippedAtlas()
        let size = CGSize(width: 402, height: 874)
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: size))
        let coast = GeoPoint(34.0100, -118.4900)
        let viewport = MapViewport.around(coast, heightMetres: 1_700 * 0.57, size: size)
        view.show(NatureFogScene(viewport: viewport, clearing: NatureFogClearing(), palette: Self.light,
                                 motion: NatureFogMotion(reduceMotion: true), terrain: Self.terrain(atlas, month: 7)))
        #expect(view.shownTileCount > 0)
        #expect(!view.isAccessibilityElement && view.accessibilityElementsHidden && !view.isUserInteractionEnabled)
        let book = NatureFogTileBook(scale: Self.full, palette: Self.light, clearing: NatureFogClearing(), pixelScale: 1,
                                     terrain: Self.terrain(atlas, month: 7))
        let key = NatureFogTileBook.key(at: Self.full.centre(of: MercatorHexGrid.cell(containing: coast)))
        let tile = await book.tile(key)
        #expect(NatureFogTileBook.visible(tile.pieces, in: key).rejected == 0, "every terrain sprite passes the W-20 guard")
    }
}

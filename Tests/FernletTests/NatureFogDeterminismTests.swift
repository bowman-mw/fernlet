import CoreGraphics
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The nature fog is deterministic from each hex's (col, row) and matches the approved mockup
/// (`Docs/Handoff/World-Nature-Fog-mockup.js`) number for number: every expected value here was printed by
/// the mockup's own `hash`, `noise`, `rng`, `kindAt`, `treeAt`, `pal`, `treeArt` and `pineArt`, run in
/// JavaScriptCore on 2026-10-26.
@MainActor
struct NatureFogDeterminismTests {
    @Test func hashMatchesTheMockup() {
        let expected: [(Int, Int, UInt32)] = [
            (0, 0, 0), (1, 2, 3_792_824_159), (-5, 7, 1_344_262_776), (1_000, 1_000, 1_538_036_497),
            (3_001, 2_999, 316_231_966), (523_417, 761_233, 3_448_587_836), (-17, -23, 1_052_166_623),
            (987_654, 1_234_567, 521_395_269),
        ]
        for (x, y, value) in expected { #expect(NatureFogNoise.hash(x, y) == value, "hash(\(x), \(y))") }
    }

    @Test func noiseMatchesTheMockup() {
        let expected: [(Int, Int, Double, Double, Double)] = [
            (0, 0, 0.81073564966209233, 0.43473816802725196, 0.82690307288430631),
            (3, 4, 0.57659999061272382, 0.51965618376089640, 0.62571186718343796),
            (17, 29, 0.68106646903896562, 0.32279534000603877, 0.40188823723607781),
            (523_417, 761_233, 0.26225177457524146, 0.69493090694889459, 0.91698230936727698),
            (100, -40, 0.64515667742588378, 0.041296970099210739, 0.34271603858749955),
            (61, 7, 0.38025151818047864, 0.30227511614763730, 0.20511737761886029),
        ]
        for (col, row, woods, pond, pine) in expected {
            #expect(abs(NatureFogNoise.noise(col, row, size: 6, salt: 1) - woods) < 1e-15, "woods(\(col), \(row))")
            #expect(abs(NatureFogNoise.noise(col, row, size: 5, salt: 2) - pond) < 1e-15, "pond(\(col), \(row))")
            #expect(abs(NatureFogNoise.noise(col, row, size: 7, salt: 3) - pine) < 1e-15, "conifer(\(col), \(row))")
        }
    }

    @Test func mulberry32MatchesTheMockup() {
        let expected: [(UInt32, [Double])] = [
            (1, [0.62707394058816135, 0.0027357211802154779, 0.52744703995995224, 0.98105096747167408]),
            (2_654_423_424, [0.59758371091447771, 0.63142878259532154, 0.62282115616835654, 0.46211453364230692]),
            (4_294_967_295, [0.89642261411063373, 0.18947825673967600, 0.71565267816185951, 0.94405990932136774]),
        ]
        #expect(UInt32(0x9E37_79B9) ^ 12_345 == 2_654_423_424)
        for (seed, values) in expected {
            var random = NatureRandom(seed: seed)
            for value in values { #expect(random.next() == value, "rng(\(seed))") }
        }
    }

    @Test func kindsOverAWildFieldMatchTheMockupsCounts() {
        var counts: [NatureHexKind: Int] = [:]
        var trees: [String] = []
        for row in 2..<78 {
            for col in 2..<58 {
                let kind = NatureFogRules.isPond(col, row) ? NatureHexKind.pond : NatureFogRules.ground(col, row)
                counts[kind, default: 0] += 1
                if let tree = NatureFogRules.tree(col, row) {
                    trees.append("\(col),\(row),\(tree.pine ? 1 : 0),\(tree.big ? 1 : 0),\(tree.variant)")
                }
            }
        }
        #expect(counts == [.short: 1_985, .long: 1_257, .flowers: 669, .boulder: 133, .pond: 212])
        #expect(trees.count == 351)
        #expect(Array(trees.prefix(12)) == ["3,2,1,1,3", "15,2,1,0,2", "20,2,0,1,3", "25,2,1,1,3", "28,2,1,0,0", "30,2,0,1,0",
                                            "33,2,0,0,3", "35,2,0,1,0", "40,2,1,0,1", "49,2,0,1,1", "18,3,0,0,3", "31,3,0,0,3"])
    }

    @Test func realMapCellsGrowWhatTheMockupGrows() {
        var trees: [String] = []
        for row in 761_200..<761_240 {
            for col in 523_400..<523_440 {
                guard let tree = NatureFogRules.tree(col, row) else { continue }
                trees.append("\(col),\(row),\(tree.pine ? 1 : 0),\(tree.big ? 1 : 0),\(tree.variant)")
            }
        }
        #expect(trees.count == 138)
        #expect(Array(trees.prefix(10)) == ["523401,761200,0,1,2", "523403,761200,0,1,1", "523431,761200,0,0,1", "523409,761201,1,0,1",
                                            "523411,761201,1,1,2", "523420,761201,0,0,0", "523424,761201,0,1,1", "523426,761201,0,0,1",
                                            "523432,761201,0,0,2", "523408,761202,0,1,3"])
        let kinds = (523_400..<523_412).map { NatureFogRules.ground($0, 761_203) }
        #expect(kinds == [.short, .short, .short, .long, .flowers, .long, .short, .long, .short, .long, .long, .flowers])
    }

    @Test func offsetCoordinatesRoundTripAxialCells() {
        for cell in [HexCell(q: 0, r: 0), HexCell(q: 5, r: -3), HexCell(q: -7, r: 11), HexCell(q: 140_000, r: 761_233)] {
            let at = NatureFogRules.offset(of: cell)
            #expect(NatureFogRules.cell(col: at.col, row: at.row) == cell)
            #expect(Set(NatureFogRules.sides(of: cell)) == Set(MercatorHexGrid.neighbours(of: cell)))
        }
    }

    @Test func paletteMixesDarkModeAndIncreaseContrastAsTheMockup() {
        #expect(NatureFogPalette.light.count == NaturePaint.allCases.count)
        let dark = NatureFogPalette(dark: true, highContrast: false)
        #expect(NaturePaint.grasses.map(dark.rgb) == [0x637C4E, 0x5E7849, 0x688054])
        #expect(dark.rgb(.seam) == 0x4A623A && dark.rgb(.edge) == 0x677957)
        #expect(NaturePaint.petals.map(dark.rgb) == [0xB77685, 0xBC9D42, 0xCBC6B3, 0x927EB3])
        #expect(dark.rgb(.centre) == 0xC19234 && dark.rgb(.outline) == 0x254026 && dark.rgb(.water) == 0x50788F)
        let darkContrast = NatureFogPalette(dark: true, highContrast: true)
        #expect(darkContrast.rgb(.seam) == 0xD7E8C4 && darkContrast.rgb(.outline) == 0x060B06 && darkContrast.rgb(.pineOutline) == 0x060B06)
        let lightContrast = NatureFogPalette(dark: false, highContrast: true)
        #expect(lightContrast.rgb(.seam) == 0x2F4A24 && lightContrast.rgb(.outline) == 0x14281A && lightContrast.seamWidth == 1.8)
        #expect(NatureFogPalette(dark: false, highContrast: false).seamWidth == 1)
    }

    @Test func treeArtMatchesTheMockupsPixels() {
        let expected: [(NatureSprite, Int, Int, Int, Int, Int)] = [
            (.tree(radius: 12, variant: 0), 399, 21, 28, -10, -26), (.tree(radius: 12, variant: 1), 401, 22, 27, -11, -25),
            (.tree(radius: 12, variant: 2), 404, 22, 28, -11, -26), (.tree(radius: 12, variant: 3), 391, 21, 27, -11, -25),
            (.tree(radius: 8, variant: 0), 192, 14, 19, -7, -17), (.tree(radius: 8, variant: 1), 178, 14, 19, -7, -17),
            (.tree(radius: 8, variant: 2), 181, 14, 19, -7, -17), (.tree(radius: 8, variant: 3), 182, 14, 19, -7, -17),
            (.pine(height: 19, odd: false), 143, 13, 21, -6, -19), (.pine(height: 19, odd: true), 155, 15, 21, -7, -19),
            (.pine(height: 14, odd: false), 80, 9, 16, -4, -14), (.pine(height: 14, odd: true), 88, 11, 16, -5, -14),
        ]
        for (key, pixels, width, height, minI, minJ) in expected {
            let art = NatureFogAtlas.art(key)
            #expect(art.pixels.count == pixels, "\(key) pixels")
            let box = art.bounds
            #expect(box?.width == width && box?.height == height && box?.minI == minI && box?.minJ == minJ, "\(key) bounds")
        }
    }
}

import CoreGraphics

/// A piece in the fog's atlas.
nonisolated enum NatureSprite: Hashable {
    /// A long-grass variant.
    case grass(Int)
    /// A wildflower variant.
    case flowers(Int)
    /// A pond's reeds variant.
    case reeds(Int)
    /// The boulder.
    case boulder
    /// A round tree of canopy radius `radius` units in one of 4 shapes.
    case tree(radius: Int, variant: Int)
    /// A pine `height` units tall; an odd variant has the wider bottom tier.
    case pine(height: Int, odd: Bool)
    /// A winter pine: the pine with snow on its tiers.
    case snowyPine(height: Int, odd: Bool)
    /// A spring round tree in blossom.
    case blossom(radius: Int, variant: Int)
    /// A bare winter tree of crown radius `radius` units.
    case bare(radius: Int, variant: Int)
    /// A palm `height` units tall.
    case palm(height: Int, variant: Int)
    /// A cactus `height` units tall.
    case cactus(height: Int, variant: Int)
    /// A mountain peak `width` × `height` units.
    case peak(width: Int, height: Int, variant: Int)
    /// An urban hex's house or tall block (seven variants).
    case house(variant: Int)
    /// A cropland hex's rows: wheat, or greens.
    case crops(wheat: Bool)
}

/// A sprite drawn at one pixel per unit, with where its top-left unit sits from its anchor.
nonisolated struct NatureSpriteImage {
    /// The pixels, one per unit, opaque where painted.
    let image: CGImage
    /// The top-left unit, from the anchor.
    let minI: Int
    let minJ: Int
    /// The size in units.
    let width: Int
    let height: Int

    /// The image's memory: 4 bytes a pixel.
    var bytes: Int { width * height * 4 }

    /// The sprite's frame in points for an anchor at `anchor` and `unit` points a unit.
    func frame(anchor: CGPoint, unit: Double) -> CGRect {
        CGRect(x: anchor.x + Double(minI) * unit, y: anchor.y + Double(minJ) * unit,
               width: Double(width) * unit, height: Double(height) * unit)
    }
}

/// The fog's pre-rendered pieces (spec "Performance"): 6 long-grass and 6 flower variants, 8 round trees (2 sizes
/// × 4 shapes), 4 pines, 3 reed variants and the boulder, drawn once per palette at one pixel per unit — about
/// 34 KB, under the 40 KB budget — and scaled up nearest-neighbour, so every piece stays crisp at any zoom.
/// Hexes pick their variant by hash. Zoomed out, trees sized from the smaller R are drawn on first use and
/// kept beside the set.
///
/// One atlas belongs to one map view (or one widget picture); nothing is shared globally. The terrain's other
/// looks (``TerrainLook``) each get an atlas of their own inside this one, made on first use and drawn only as
/// their pieces are asked for (at most ``lookLimit``).
nonisolated final class NatureFogAtlas {
    /// How many long-grass, flower and reed variants there are.
    static let grassVariants = 6
    static let flowerVariants = 6
    static let reedVariants = 3
    /// The full-detail trees: canopy radius round(1.45·8) and round(1.05·8) units, pines round(2.4·8) and
    /// round(1.8·8) units tall.
    static let treeRadii = [12, 8]
    static let pineHeights = [19, 14]

    /// The most terrain looks one atlas holds (11 sets × 4 seasons fit).
    static let lookLimit = 48

    /// The palette every sprite is painted in.
    let palette: NatureFogPalette
    private var sprites: [NatureSprite: NatureSpriteImage] = [:]
    private var looks: [TerrainLook: NatureFogAtlas] = [:]

    /// The full-detail set, painted in `palette` (`preparing` false draws nothing until asked).
    init(palette: NatureFogPalette, preparing: Bool = true) {
        self.palette = palette
        guard preparing else { return }
        for key in Self.fullDetailSet { prepare(key) }
    }

    /// The sprite for `key` painted in `look`'s colours: this atlas's own for its look, else the look's atlas.
    func sprite(_ key: NatureSprite, look: TerrainLook) -> NatureSpriteImage? {
        guard look != palette.look else { return sprite(key) }
        if let atlas = looks[look] { return atlas.sprite(key) }
        guard looks.count < Self.lookLimit else { return nil }
        let atlas = NatureFogAtlas(palette: palette.with(look), preparing: false)
        looks[look] = atlas
        return atlas.sprite(key)
    }

    /// The pieces drawn at full detail.
    static var fullDetailSet: [NatureSprite] {
        var keys: [NatureSprite] = (0..<grassVariants).map { .grass($0) } + (0..<flowerVariants).map { .flowers($0) }
        keys += (0..<reedVariants).map { .reeds($0) } + [.boulder]
        for radius in treeRadii { keys += (0..<4).map { .tree(radius: radius, variant: $0) } }
        for height in pineHeights { keys += [.pine(height: height, odd: false), .pine(height: height, odd: true)] }
        return keys
    }

    /// The memory the full-detail set takes.
    var fullDetailBytes: Int {
        Self.fullDetailSet.compactMap { sprites[$0]?.bytes }.reduce(0, +)
    }

    /// The sprite for `key`, drawn on first use; nil if it has no pixels.
    func sprite(_ key: NatureSprite) -> NatureSpriteImage? {
        if let made = sprites[key] { return made }
        prepare(key)
        return sprites[key]
    }

    /// Draws `key` into the atlas (a bounded set: trees and pines are at most 40 and 60 units).
    private func prepare(_ key: NatureSprite) {
        guard sprites[key] == nil, sprites.count < 256, let image = Self.render(Self.art(key), palette: palette) else { return }
        sprites[key] = image
    }

    /// The pixel art behind `key`. Variants come from fixed mulberry32 seeds, so they never change.
    static func art(_ key: NatureSprite) -> NaturePixelArt {
        switch key {
        case .grass(let variant):
            var random = NatureRandom(seed: NatureFogNoise.hash(variant + 7_100, 7_100))
            return NatureFogArt.grass(flowers: false, random: &random)
        case .flowers(let variant):
            var random = NatureRandom(seed: NatureFogNoise.hash(variant + 7_200, 7_200))
            return NatureFogArt.grass(flowers: true, random: &random)
        case .reeds(let variant):
            var random = NatureRandom(seed: NatureFogNoise.hash(variant + 7_300, 7_300))
            return NatureFogArt.reeds(random: &random)
        case .boulder:
            return NatureFogArt.rock()
        case .tree(let radius, let variant):
            return NatureFogTreeArt.round(radius: radius, variant: variant)
        case .pine(let height, let odd):
            return NatureFogTreeArt.pine(height: height, variant: odd ? 1 : 0)
        default:
            return terrainArt(key)
        }
    }

    /// The pixel art behind the terrain's pieces.
    private static func terrainArt(_ key: NatureSprite) -> NaturePixelArt {
        switch key {
        case .snowyPine(let height, let odd): TerrainArt.snowyPine(height: height, odd: odd)
        case .blossom(let radius, let variant): TerrainArt.blossom(radius: radius, variant: variant)
        case .bare(let radius, let variant): TerrainArt.bare(radius: radius, variant: variant)
        case .palm(let height, let variant): TerrainArt.palm(height: height, variant: variant)
        case .cactus(let height, let variant): TerrainArt.cactus(height: height, variant: variant)
        case .peak(let width, let height, let variant): TerrainArt.peak(width: width, height: height, variant: variant)
        case .house(let variant): TerrainArt.house(variant: variant)
        case .crops(let wheat): TerrainArt.crops(wheat: wheat)
        case .grass, .flowers, .reeds, .boulder, .tree, .pine: NaturePixelArt()
        }
    }

    /// Paints `art` one pixel per unit; nil for empty or oversized art.
    static func render(_ art: NaturePixelArt, palette: NatureFogPalette) -> NatureSpriteImage? {
        guard let box = art.bounds, box.width <= 160, box.height <= 160,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: box.width, height: box.height, bitsPerComponent: 8,
                                      bytesPerRow: box.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (unit, ink) in art.pixels {
            context.setFillColor(palette.color(ink))
            context.fill(CGRect(x: unit.i - box.minI, y: box.height - 1 - (unit.j - box.minJ), width: 1, height: 1))
        }
        guard let image = context.makeImage() else { return nil }
        return NatureSpriteImage(image: image, minI: box.minI, minJ: box.minJ, width: box.width, height: box.height)
    }

    /// Draws `sprite` into `context` (y down) filling `rect`, nearest-neighbour.
    static func draw(_ sprite: NatureSpriteImage, in context: CGContext, rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(sprite.image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

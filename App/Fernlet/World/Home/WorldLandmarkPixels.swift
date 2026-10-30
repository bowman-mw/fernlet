import CoreGraphics
import Foundation
import SwiftUI
import WorldMapStore

/// How one landmark's art is coloured (World-Exploration-Spec §2, "Colours"; the mockup's `lmArt`).
nonisolated struct WorldLandmarkLook: Hashable, Sendable {
    /// Whether the passport holds it: full colour, else grey and unnamed.
    var found: Bool
    /// Dark Mode's halo and greys.
    var dark: Bool
    /// Whether the one-pixel halo rings the art (on the map, always; the card's small icons go without).
    var halo = true
}

/// A landmark sprite as colours: `width` × `height` pixels, row by row, nil where nothing is drawn.
nonisolated struct WorldLandmarkPixelGrid: Equatable, Sendable {
    /// Width in pixels (the sprite's, plus two with a halo).
    let width: Int
    /// Height in pixels.
    let height: Int
    /// `width × height` colours as `0xRRGGBB`, top row first; nil is clear.
    let pixels: [UInt32?]

    /// The colour at column `x`, row `y`, or nil (clear, or off the grid).
    func colour(x: Int, y: Int) -> UInt32? {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        return pixels[y * width + x]
    }
}

/// Turns the approved landmark art (`WorldLandmarkArt.json`) into pixels, exactly as the mockup's `lmArt` and
/// `haloed` do:
///
/// - **found**: each palette letter its own colour (`LMPAL`), the halo ``WorldLandmarkArt/foundHalo``;
/// - **not found**: the outline letter (`k`) ``WorldLandmarkArt/notFoundOutline``, every other drawn pixel
///   ``WorldLandmarkArt/notFoundFill``, the halo ``WorldLandmarkArt/notFoundHalo``;
/// - **the halo**: the sprite padded by one clear pixel all round, and every clear pixel with a drawn pixel
///   among its eight neighbours takes the halo colour.
///
/// Pure and bounded: at most (``WorldLandmarkArt/maxSide`` + 2)² pixels, each reading at most eight neighbours.
nonisolated enum WorldLandmarkPixels {
    /// The pixels of `sprite` from `art` in `look`.
    static func grid(_ sprite: LandmarkSprite, art: WorldLandmarkArt, look: WorldLandmarkLook) -> WorldLandmarkPixelGrid {
        guard sprite.width > 0, sprite.height > 0 else { return WorldLandmarkPixelGrid(width: 0, height: 0, pixels: []) }
        let pad = look.halo ? 1 : 0
        let width = min(sprite.width, WorldLandmarkArt.maxSide) + 2 * pad
        let height = min(sprite.height, WorldLandmarkArt.maxSide) + 2 * pad
        let halo = pick(look.found ? art.foundHalo : art.notFoundHalo, dark: look.dark)
        var pixels = [UInt32?](repeating: nil, count: width * height)
        // Bounded: at most (maxSide + 2)² pixels.
        for y in 0..<height {
            for x in 0..<width {
                if let index = letter(sprite, x: x - pad, y: y - pad) {
                    pixels[y * width + x] = colour(of: index, art: art, look: look)
                } else if look.halo, touchesArt(sprite, x: x - pad, y: y - pad) {
                    pixels[y * width + x] = halo
                }
            }
        }
        return WorldLandmarkPixelGrid(width: width, height: height, pixels: pixels)
    }

    /// The colour a drawn palette `index` takes in `look`.
    static func colour(of index: UInt8, art: WorldLandmarkArt, look: WorldLandmarkLook) -> UInt32 {
        guard look.found else {
            return pick(index == art.outlineIndex ? art.notFoundOutline : art.notFoundFill, dark: look.dark)
        }
        guard art.colours.indices.contains(Int(index)) else { return pick(art.notFoundFill, dark: look.dark) }
        return hex(art.colours[Int(index)])
    }

    /// The palette index at sprite pixel (`x`, `y`), or nil when it is clear or off the sprite.
    private static func letter(_ sprite: LandmarkSprite, x: Int, y: Int) -> UInt8? {
        guard sprite.pixels.indices.contains(y), sprite.pixels[y].indices.contains(x) else { return nil }
        let index = sprite.pixels[y][x]
        return index == LandmarkSprite.clear ? nil : index
    }

    /// Whether any of the eight neighbours of sprite pixel (`x`, `y`) is drawn.
    private static func touchesArt(_ sprite: LandmarkSprite, x: Int, y: Int) -> Bool {
        guard x >= -1, y >= -1, x <= sprite.width, y <= sprite.height else { return false }
        // Bounded: the eight neighbours.
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                if letter(sprite, x: x + dx, y: y + dy) != nil { return true }
            }
        }
        return false
    }

    /// The light or dark colour of `pair`.
    static func pick(_ pair: LandmarkArtPair, dark: Bool) -> UInt32 {
        hex(dark ? pair.dark : pair.light)
    }

    /// `colour` as `0xRRGGBB`.
    static func hex(_ colour: LandmarkArtColour) -> UInt32 {
        UInt32(colour.red) << 16 | UInt32(colour.green) << 8 | UInt32(colour.blue)
    }

    /// `grid` as an image, one image pixel per art pixel (drawn nearest-neighbour by the caller). Nil for an
    /// empty grid.
    static func image(_ grid: WorldLandmarkPixelGrid) -> CGImage? {
        guard grid.width > 0, grid.height > 0, grid.pixels.count == grid.width * grid.height else { return nil }
        var bytes = [UInt8](repeating: 0, count: grid.pixels.count * 4)
        // Bounded: one pass over the grid's pixels.
        for (index, pixel) in grid.pixels.enumerated() {
            guard let pixel else { continue }
            bytes[index * 4] = UInt8((pixel >> 16) & 0xFF)
            bytes[index * 4 + 1] = UInt8((pixel >> 8) & 0xFF)
            bytes[index * 4 + 2] = UInt8(pixel & 0xFF)
            bytes[index * 4 + 3] = 0xFF
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: grid.width, height: grid.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: grid.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The landmark art and its drawn images, opened on first use and kept for the session (``WorldLandmarkArtLoader``
/// reads the bundled file once). Each image is made once per sprite and look and kept, at most ``maxImages``.
@MainActor
final class WorldLandmarkImages {
    /// The most images kept (28 famous and 6 generic sprites in four looks each is 136).
    static let maxImages = 256

    private let load: @MainActor () -> WorldLandmarkArt?
    private var opened: WorldLandmarkArt??
    private var images: [String: CGImage] = [:]

    /// Images of the art `load` opens (the app: the bundled file).
    init(load: @escaping @MainActor () -> WorldLandmarkArt? = { WorldLandmarkArtLoader.bundled() }) {
        self.load = load
    }

    /// The art, opened on first use; nil when the file is missing or refused (logged by the loader).
    var art: WorldLandmarkArt? {
        if let opened { return opened }
        let art = load()
        opened = .some(art)
        return art
    }

    /// The image of `landmark`'s art in `look`, with its size in art pixels; nil without art for it.
    func image(for landmark: AtlasLandmark, look: WorldLandmarkLook) -> CGImage? {
        image(of: landmark.tier.drawable, look: look)
    }

    /// The image of the sprite `tier` draws, in `look`; nil when the art has no such sprite.
    func image(of tier: AtlasLandmarkTier, look: WorldLandmarkLook) -> CGImage? {
        guard let art else { return nil }
        let sprite: LandmarkSprite?
        switch tier {
        case .famous(let artID): sprite = art.famous[artID]
        case .generic(let kind): sprite = art.generic[kind]
        }
        guard let sprite else { return nil }
        let key = "\(Self.artKey(tier))|\(look.found)|\(look.dark)|\(look.halo)"
        if let image = images[key] { return image }
        guard let image = WorldLandmarkPixels.image(WorldLandmarkPixels.grid(sprite, art: art, look: look)) else { return nil }
        if images.count >= Self.maxImages { images.removeAll(keepingCapacity: true) }
        images[key] = image
        return image
    }

    /// Points per art pixel on the map: famous art 3, generic icons 3.5 (the art file's own scales).
    func mapScale(for landmark: AtlasLandmark) -> CGFloat {
        guard let art else { return 3 }
        switch landmark.tier.drawable {
        case .famous: return CGFloat(art.famousScale)
        case .generic: return CGFloat(art.genericScale)
        }
    }

    /// A key naming the sprite a tier draws.
    nonisolated static func artKey(_ tier: AtlasLandmarkTier) -> String {
        switch tier {
        case .famous(let artID): "famous.\(artID)"
        case .generic(let kind): "generic.\(kind.rawValue)"
        }
    }
}

/// A landmark's art drawn crisply: its cached image at `scale` points per art pixel, nearest-neighbour.
/// Decoration to VoiceOver (the element round it names the landmark).
struct WorldLandmarkArtView: View {
    let image: CGImage
    let scale: CGFloat

    var body: some View {
        Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            .accessibilityHidden(true)
    }
}

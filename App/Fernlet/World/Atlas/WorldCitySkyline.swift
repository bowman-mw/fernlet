import SwiftUI

/// One pixel skyline per city size class (World-Exploration-Spec §2, `ex-skylines`, approved), drawn crisply
/// from the mockup's `SKY` and `skyline()` (`World-Exploration-mockup.js`): a 48 × 40-pixel picture of
/// buildings on an ink ground line. A village is houses round a church spire, a town has a clock tower, a city
/// one tower, a big city towers, and a megacity a spire among towers. Lit windows are pale yellow, and dark
/// mode warms them.
///
/// Shared by the world view's city markers and Home's (round 7). Decoration to VoiceOver: the marker or the
/// card that carries it says the city's name.
struct WorldCitySkyline: View {
    /// The size class whose skyline this is.
    let sizeClass: WorldCitySizeClass
    /// Points per skyline pixel (whole numbers keep it crisp; the markers use 1).
    var scale: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let pixels = WorldCitySkylineArt.pixels(for: sizeClass, dark: colorScheme == .dark)
        Canvas { context, _ in
            // Bounded: one skyline's fixed list of rectangles (at most a few hundred).
            for pixel in pixels {
                let rect = CGRect(x: CGFloat(pixel.x) * scale, y: CGFloat(pixel.y) * scale,
                                  width: CGFloat(pixel.width) * scale, height: CGFloat(pixel.height) * scale)
                context.fill(Path(rect), with: .color(pixel.color.color))
            }
        }
        .frame(width: CGFloat(WorldCitySkylineArt.width) * scale, height: CGFloat(WorldCitySkylineArt.height) * scale)
        .accessibilityHidden(true)
    }
}

/// The skylines' pixels, as data: the mockup's buildings per class and the rules that draw each kind.
nonisolated enum WorldCitySkylineArt {
    /// The picture's width in pixels.
    static let width = 48
    /// The picture's height in pixels.
    static let height = 40
    /// The ground line's top row (the mockup's `top = H - 2`).
    static let ground = height - 2

    /// What a building is: its outline rule.
    enum Kind: Sendable {
        case house, block, tower, church, clock, spire, tree
    }

    /// One building: its left column, width and height in pixels, and its kind (the mockup's `[x, w, h, kind]`).
    struct Building: Sendable {
        let x: Int, width: Int, height: Int, kind: Kind
    }

    /// One filled rectangle of the picture, in pixels.
    struct Pixel: Equatable, Sendable {
        let x: Int, y: Int, width: Int, height: Int
        let color: Ink
    }

    /// A colour the skylines use: an sRGB hex and an opacity.
    struct Ink: Equatable, Sendable {
        let hex: UInt32
        var opacity = 1.0

        /// The SwiftUI colour.
        var color: Color { WorldPalette.rgb(hex).opacity(opacity) }
    }

    /// The ink of the ground line and the clock's hands (the mockup's `INK`).
    static let ink = Ink(hex: 0x4A2E1C)
    /// The building bodies, taken in turn (the mockup's `BODY`).
    static let bodies: [UInt32] = [0xC9B79A, 0x9EAAB3, 0xB98B6E, 0xD6C9AE, 0x8FA0A8]
    /// A lit window: pale yellow, warmer in dark mode.
    static func window(dark: Bool) -> Ink { Ink(hex: dark ? 0xF2D58A : 0xFFF3C4) }

    /// The buildings of each class, smallest class first (the mockup's `SKY`).
    static let skylines: [[Building]] = [
        [.init(x: 2, width: 7, height: 6, kind: .house), .init(x: 10, width: 6, height: 5, kind: .house),
         .init(x: 17, width: 5, height: 16, kind: .church), .init(x: 24, width: 7, height: 6, kind: .house),
         .init(x: 33, width: 6, height: 5, kind: .house), .init(x: 41, width: 5, height: 7, kind: .tree)],
        [.init(x: 1, width: 7, height: 8, kind: .block), .init(x: 9, width: 6, height: 11, kind: .block),
         .init(x: 16, width: 5, height: 17, kind: .clock), .init(x: 22, width: 8, height: 9, kind: .block),
         .init(x: 31, width: 6, height: 12, kind: .block), .init(x: 38, width: 8, height: 7, kind: .house)],
        [.init(x: 1, width: 6, height: 12, kind: .block), .init(x: 8, width: 7, height: 17, kind: .block),
         .init(x: 16, width: 6, height: 25, kind: .tower), .init(x: 23, width: 8, height: 14, kind: .block),
         .init(x: 32, width: 6, height: 19, kind: .block), .init(x: 39, width: 7, height: 10, kind: .block)],
        [.init(x: 0, width: 6, height: 18, kind: .block), .init(x: 7, width: 5, height: 26, kind: .tower),
         .init(x: 13, width: 7, height: 21, kind: .block), .init(x: 21, width: 5, height: 31, kind: .tower),
         .init(x: 27, width: 7, height: 23, kind: .block), .init(x: 35, width: 5, height: 28, kind: .tower),
         .init(x: 41, width: 6, height: 16, kind: .block)],
        [.init(x: 0, width: 5, height: 22, kind: .tower), .init(x: 6, width: 6, height: 30, kind: .tower),
         .init(x: 13, width: 5, height: 26, kind: .block), .init(x: 19, width: 6, height: 37, kind: .spire),
         .init(x: 26, width: 5, height: 29, kind: .tower), .init(x: 32, width: 6, height: 33, kind: .tower),
         .init(x: 39, width: 5, height: 24, kind: .block), .init(x: 44, width: 4, height: 19, kind: .block)]
    ]

    /// Every rectangle of `sizeClass`'s skyline, in drawing order, with the windows lit for `dark` mode.
    static func pixels(for sizeClass: WorldCitySizeClass, dark: Bool) -> [Pixel] {
        let rank = sizeClass.rank
        guard skylines.indices.contains(rank) else { return [] }
        var pixels: [Pixel] = []
        // Bounded: at most eight buildings a skyline.
        for (index, building) in skylines[rank].enumerated() {
            let body = Ink(hex: bodies[(index + rank) % bodies.count])
            pixels += self.building(building, index: index, body: body, window: window(dark: dark))
        }
        pixels.append(Pixel(x: 0, y: ground, width: width, height: 2, color: ink))
        return pixels.compactMap(clipped)
    }

    /// `pixel` cut to the picture, as the mockup's 48 × 40 view box cuts it (the megacity's spire reaches past
    /// the top), or nil when nothing of it is inside.
    static func clipped(_ pixel: Pixel) -> Pixel? {
        let left = max(pixel.x, 0), top = max(pixel.y, 0)
        let right = min(pixel.x + pixel.width, width), bottom = min(pixel.y + pixel.height, height)
        guard right > left, bottom > top else { return nil }
        return Pixel(x: left, y: top, width: right - left, height: bottom - top, color: pixel.color)
    }

    /// One building's rectangles, by its kind (the mockup's rules).
    private static func building(_ b: Building, index: Int, body: Ink, window: Ink) -> [Pixel] {
        switch b.kind {
        case .tree:
            return [Pixel(x: b.x + 2, y: ground - 2, width: 1, height: 2, color: Ink(hex: 0x74482A)),
                    Pixel(x: b.x, y: ground - 6, width: 5, height: 4, color: Ink(hex: 0x5E9A48))]
        case .house:
            let top = ground - b.height
            var rects = [Pixel(x: b.x, y: top + 3, width: b.width, height: b.height - 3, color: body)]
            // Bounded: three roof rows.
            for row in 0..<3 {
                rects.append(Pixel(x: b.x + row, y: top + 2 - row, width: b.width - 2 * row, height: 1,
                                   color: Ink(hex: 0xB5523B)))
            }
            rects.append(Pixel(x: b.x + 2, y: ground - 2, width: 1, height: 2, color: Ink(hex: 0x7A4B2A)))
            return rects
        case .block, .tower, .church, .clock, .spire:
            return tall(b, index: index, body: body, window: window)
        }
    }

    /// A tall building: its body, its shaded right edge, its lit windows, then its crown.
    private static func tall(_ b: Building, index: Int, body: Ink, window: Ink) -> [Pixel] {
        let top = ground - b.height
        var rects = [Pixel(x: b.x, y: top, width: b.width, height: b.height, color: body),
                     Pixel(x: b.x + b.width - 1, y: top, width: 1, height: b.height,
                           color: Ink(hex: 0x281608, opacity: 0.22))]
        // Bounded: a building is at most 40 pixels tall and 8 wide.
        for wy in stride(from: top + 2, to: ground - 1, by: 3) {
            for wx in stride(from: b.x + 1, to: b.x + b.width - 1, by: 2) where (wx * 7 + wy * 3 + index) % 5 != 0 {
                rects.append(Pixel(x: wx, y: wy, width: 1, height: 1, color: window))
            }
        }
        switch b.kind {
        case .church:
            rects.append(Pixel(x: b.x + 2, y: top - 4, width: 1, height: 4, color: body))
            rects.append(Pixel(x: b.x + 1, y: top - 3, width: 3, height: 1, color: body))
        case .clock:
            rects.append(Pixel(x: b.x + 1, y: top + 2, width: 3, height: 3, color: Ink(hex: 0xFFF6E2)))
            rects.append(Pixel(x: b.x + 2, y: top + 3, width: 1, height: 1, color: ink))
        case .spire, .tower:
            let mast = b.kind == .spire ? 6 : 2
            rects.append(Pixel(x: b.x + b.width / 2, y: top - mast, width: 1, height: mast, color: Ink(hex: 0x6E6A66)))
        case .block, .house, .tree:
            break
        }
        return rects
    }
}

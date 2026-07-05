import SwiftUI
import UIKit
import CoreGraphics
import FernletDomainModel

/// Converts a palette-indexed `ItemGridTexture` into a crisp `CGImage` (one pixel per cell, nearest-
/// neighbor on display). Generation is cheap (a few hundred cells), and callers cache the result in
/// view `@State` keyed by the texture so it is never regenerated inside the companion's per-frame
/// animation loop.
enum ItemTextureRenderer {
    static func image(for texture: ItemGridTexture) -> CGImage? {
        let width = texture.cols
        let height = texture.rows
        guard width > 0, height > 0, texture.pixels.count == width * height else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let idx = texture.pixels[i]
            guard idx >= 0, idx < texture.palette.count, let rgb = rgb(texture.palette[idx]) else { continue }
            let p = i * 4
            bytes[p] = rgb.0
            bytes[p + 1] = rgb.1
            bytes[p + 2] = rgb.2
            bytes[p + 3] = 255
        }

        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return context?.makeImage()
        }
    }

    /// Palette hex → RGB bytes for the pixel path. Delegates to the single shared hex parser on
    /// `UIColor` so the item renderer and `UIColor(hex:)` can never drift apart.
    static func rgb(_ hex: String) -> (UInt8, UInt8, UInt8)? {
        UIColor.rgbBytes(fromHex: hex)
    }
}

extension Color {
    /// A color from a 6-hex `RRGGBB` palette string, used by the item designer. Internal to the app target.
    init?(itemHex: String) {
        guard let rgb = ItemTextureRenderer.rgb(itemHex) else { return nil }
        self.init(.sRGB, red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }
}

/// A small fixed-size preview of a designed item, used in the Wardrobe and (later) the shop. Renders
/// the texture pixel-perfect on a soft parchment tile, preserving the grid's aspect ratio.
struct CustomItemThumbnail: View {
    var texture: ItemGridTexture
    var size: CGFloat = 56
    @State private var image: CGImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.parchment)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.bark.opacity(0.10), lineWidth: 1)
            }
            .frame(width: size, height: size)
            .onChange(of: texture, initial: true) { _, newValue in
                image = ItemTextureRenderer.image(for: newValue)
            }
    }

    private var aspect: CGFloat {
        guard texture.rows > 0 else { return 1 }
        return CGFloat(texture.cols) / CGFloat(texture.rows)
    }
}

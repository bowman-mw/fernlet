import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Fernlet

/// The Messages card's pixel artwork (World Review Batch 4, `b4-msg-bubbles`, owner, 2026-10-24),
/// read pixel by pixel: cream paper, the pixel bowl or dumbbell in the middle, an ink line over a
/// grass strip along the bottom, and the framed tag top left.
///
/// The builder is compiled into the app as well as the iMessage app ("Send in Messages"), so this
/// bundle draws the very artwork both send.
@MainActor
struct MessagesCardArtworkTests {
    /// The recipe card's picture is the 1200×630 scene at scale 1, in the design's colours where each
    /// part should be.
    @Test func theRecipeArtworkIsThePixelScene() throws {
        let image = FernletMessagesCard.recipePlaceholderImage()
        #expect(image.size == FernletMessagesCard.artworkSize && image.scale == 1)
        try Self.expect(image, at: CGPoint(x: 1_150, y: 40), is: 0xFFF6E2, "the paper, top right")
        try Self.expect(image, at: CGPoint(x: 600, y: 620), is: 0x8DBB78, "the grass strip")
        try Self.expect(image, at: CGPoint(x: 600, y: FernletMessagesCard.groundTop + 4), is: 0x4A2E1C, "the ground's ink line")
        // The bowl: 9 × 6 keys at 27 points, centred; key (4, 3) is the cream fill, key (0, 2) the rim.
        let origin = CGPoint(x: ((1_200 - 9 * 27) / 2).rounded(.down), y: ((630 - 6 * 27) / 2).rounded(.down))
        try Self.expect(image, at: CGPoint(x: origin.x + 4 * 27 + 13, y: origin.y + 3 * 27 + 13), is: 0xF3E2B3, "the bowl's fill")
        try Self.expect(image, at: CGPoint(x: origin.x + 13, y: origin.y + 2 * 27 + 13), is: 0x4A2E1C, "the bowl's rim")
        try Self.expect(image, at: CGPoint(x: 48, y: 90), is: 0x4A2E1C, "the tag's ink frame")
    }

    /// The workout card's picture is the same scene with the dumbbell in ink.
    @Test func theWorkoutArtworkCarriesTheDumbbell() throws {
        let image = FernletMessagesCard.placeholderImage(sprite: .dumbbell, tag: "Fernlet workout")
        #expect(image.size == FernletMessagesCard.artworkSize)
        let origin = CGPoint(x: ((1_200 - 11 * 27) / 2).rounded(.down), y: ((630 - 5 * 27) / 2).rounded(.down))
        try Self.expect(image, at: CGPoint(x: origin.x + 5 * 27 + 13, y: origin.y + 2 * 27 + 13), is: 0x4A2E1C, "the bar")
        try Self.expect(image, at: CGPoint(x: origin.x + 5 * 27 + 13, y: origin.y + 13), is: 0xFFF6E2, "paper above the bar")
    }

    /// A tag far too long for the canvas is cut off inside it rather than drawn past the edge.
    @Test func aLongTagStaysOnTheCanvas() throws {
        let image = FernletMessagesCard.placeholderImage(sprite: .bowl, tag: String(repeating: "Fernlet recipe ", count: 20))
        #expect(image.size == FernletMessagesCard.artworkSize)
        try Self.expect(image, at: CGPoint(x: 1_196, y: 90), is: 0xFFF6E2, "the canvas edge beyond the tag's frame")
    }

    /// Every card sprite is a rectangle of keys its palette knows; the pixel rows hold no letter, so the
    /// target's literal wall (`LocalizationBoundaryTests` H2) never mistakes them for copy.
    @Test func theCardSpritesAreWellFormed() {
        for sprite in [FernletMessagesSprite.fern, .bowl, .dumbbell] {
            #expect(sprite.width > 0 && sprite.rows.allSatisfy { $0.count == sprite.width })
            let keys = Set(sprite.rows.joined()).subtracting(["."])
            #expect(keys.isSubset(of: Set(sprite.palette.keys)))
            #expect(!sprite.rows.joined().contains { $0.isLetter })
        }
        #expect(FernletMessagesSprite.bowl.image(pixel: 2).size == CGSize(width: 18, height: 12))
        #expect(FernletMessagesSprite.fern.image(pixel: 0).size == .zero)
    }

    /// The colour at `point`, within a step of rounding per channel.
    static func expect(_ image: UIImage, at point: CGPoint, is hex: UInt32, _ what: String) throws {
        let found = try rgb(at: point, in: image)
        let channels = [16, 8, 0].map { (Int((found >> UInt32($0)) & 0xFF), Int((hex >> UInt32($0)) & 0xFF)) }
        #expect(channels.allSatisfy { abs($0.0 - $0.1) <= 3 },
                "\(what) at \(point): found #\(String(found, radix: 16)), expected #\(String(hex, radix: 16))")
    }

    /// One pixel of `image`, as `0xRRGGBB`.
    static func rgb(at point: CGPoint, in image: UIImage) throws -> UInt32 {
        let cgImage = try #require(image.cgImage)
        let pixel = try #require(cgImage.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        #expect(drawn)
        return UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
    }
}

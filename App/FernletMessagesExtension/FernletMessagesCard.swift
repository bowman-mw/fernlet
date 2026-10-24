//
//  FernletMessagesCard.swift
//  FernletMessagesExtension (also compiled into the Fernlet app target)
//
//  The ONE builder of a Fernlet Messages card (2026-09-30). Until then it was private to
//  `FernletMessagesViewController`; the app's recipe Share screen now sends the same card through
//  `MFMessageComposeViewController` ("Send in Messages"), and a second builder would be a second
//  card format waiting to drift. Both targets compile this file (the app through a membership
//  exception on the extension's synchronized folder), so an inserted card and a composed one come
//  out of the same code: same envelope, same URL, same layout, same artwork.
//
//  It imports only what the extension may (`MessagesExtensionBoundaryTests.permittedModules`), and
//  it never forks the wire: the URL is `ExchangeMessageEnvelope.messageURL()`, exactly.
//

import FernletExchange
import Foundation
import Messages
import UIKit

/// The fixed colours of a Fernlet Messages card's artwork, spelled out in `UIColor` rather than read
/// from the app's design tokens: an app extension is a separate process with no access to the host's
/// asset catalog, and the artwork is a picture Messages shows in light and dark conversations alike,
/// so it keeps one palette (the World pixel scene's: cream paper, an ink line, a grass strip).
///
/// The iMessage app's panel draws in `FernletMessagesLook` instead, which follows Dark Mode.
nonisolated enum FernletMessagesPalette {
    /// The scene's paper (`#FFF6E2`).
    static let paper = rgb(0xFFF6E2)
    /// The pixel art's ink, the ground line and the tag's frame (`#4A2E1C`).
    static let ink = rgb(0x4A2E1C)
    /// The grass strip along the bottom (`#8DBB78`).
    static let grass = rgb(0x8DBB78)
    /// The tag's words (`#3A2414`, the design's bark).
    static let bark = rgb(0x3A2414)

    /// An opaque colour from a `0xRRGGBB` literal.
    static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The PostScript names of the typefaces the World design language draws in: Fraunces for titles,
/// DM Sans for everything else. The same faces, by the same names, as FernletUI's `FernletFontName`,
/// which this target may not import. The iMessage app registers its own copies through its
/// `UIAppFonts`; the app (which compiles this file for "Send in Messages") through the app's. A name
/// that does not resolve falls back to the system face, so a missing font never blanks a card.
nonisolated enum FernletMessagesFontName {
    /// Fraunces SemiBold: titles.
    static let fraunces = "Fraunces-72ptSemiBoldNonWonky"
    /// DM Sans Regular: body text.
    static let dmSans = "DMSans-14pt"
    /// DM Sans Medium: the bold weight the design draws labels, tags and buttons in.
    static let dmSansMedium = "DMSans-14ptMedium"
}

/// One piece of the World's pixel art, drawn by UIKit: rows of palette keys (`.` is clear), each key
/// one square. The approved sprites, copied key for key from the design page (World Review Batch 4),
/// with digits for keys so no row carries a letter (the target's literal wall reads letters as copy).
///
/// The card's three sprites live here because the card artwork is drawn in both processes; the
/// panel's own icons extend this type in the iMessage app (`FernletMessagesPanelSprites.swift`).
struct FernletMessagesSprite: Sendable {
    /// The rows, top to bottom; every row has the same width.
    let rows: [String]
    /// The colour of each key, as `0xRRGGBB`.
    let palette: [Character: UInt32]

    /// Width in sprite pixels.
    var width: Int { rows.first?.count ?? 0 }
    /// Height in sprite pixels.
    var height: Int { rows.count }

    /// Fills each key's square, `pixel` points wide, from `origin` in the current graphics context:
    /// in its own colour, or every key in `tint`.
    func draw(at origin: CGPoint, pixel: CGFloat, tint: UIColor? = nil) {
        guard pixel > 0 else { return }
        for (y, row) in rows.enumerated() {
            for (x, key) in row.enumerated() where key != "." {
                guard let hex = palette[key] else { continue }
                (tint ?? FernletMessagesPalette.rgb(hex)).setFill()
                UIRectFill(CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel,
                                  width: pixel, height: pixel))
            }
        }
    }

    /// The sprite as an image at the screen's scale, `pixel` points per key. A one-colour icon is
    /// drawn as a template, so an image view's dynamic `tintColor` inks it in light and dark mode.
    func image(pixel: CGFloat, template: Bool = false) -> UIImage {
        let size = CGSize(width: CGFloat(width) * pixel, height: CGFloat(height) * pixel)
        guard size.width > 0, size.height > 0 else { return UIImage() }
        let image = UIGraphicsImageRenderer(size: size).image { _ in draw(at: .zero, pixel: pixel) }
        return template ? image.withRenderingMode(.alwaysTemplate) : image
    }

    /// The pixel fern of the Fernlet mark: moss fronds on an ink stem.
    static let fern = FernletMessagesSprite(
        rows: ["....1....", "...111...", "..1.1.1..", ".11.1.11.", "..1.1.1..", ".11.1.11.", "..1.1.1..",
               "....1....", "....2...."],
        palette: ["1": 0x5E844D, "2": 0x4A2E1C])
    /// The recipe bowl, ink-outlined with a cream fill (the app's `bowlInk`).
    static let bowl = FernletMessagesSprite(
        rows: ["......11.", ".....1...", "111111111", "122222221", ".1222221.", "..11111.."],
        palette: ["1": 0x4A2E1C, "2": 0xF3E2B3])
    /// The workout dumbbell, one colour (inked by its caller in the panel).
    static let dumbbell = FernletMessagesSprite(
        rows: [".11.....11.", "111.....111", "11111111111", "111.....111", ".11.....11."],
        palette: ["1": 0x4A2E1C])
}

/// Builds the `MSMessage` a Fernlet recipe or workout card travels as: the envelope's serverless
/// `data:` URL, a template layout, and the summary Messages reads aloud.
///
/// The recipe card is whole here (``recipeMessage(for:)``); the workout card's layout stays in the
/// iMessage app, which is the only place that sends one, and reaches this type for the shared
/// ``message(for:layout:)`` and ``placeholderImage(sprite:tag:)``. Main-actor isolated in both
/// targets (their default isolation), like the UIKit drawing it does.
enum FernletMessagesCard {

    /// The recipe card for `packet`, ready to insert into a conversation or hand to a composer.
    ///
    /// - Throws: `ExchangePacketError.tooLarge` or `.invalidMessageURL` when the recipe will not fit
    ///   a card (`ExchangeLimits`), `.invalidCardMetadata` when its title is over the card's limit,
    ///   or the packet's own validation error.
    static func recipeMessage(for packet: RecipeExchangePacket) throws -> MSMessage {
        let envelope = try ExchangeMessageEnvelope(recipe: packet)
        return try message(for: envelope, layout: recipeLayout(for: envelope.card, includesNotes: packet.includesNotes))
    }

    /// Wraps `envelope` in a message with `layout`. The URL is the envelope's own
    /// `messageURL()`, which enforces Apple's 5,000-character limit before Messages can refuse it.
    static func message(for envelope: ExchangeMessageEnvelope, layout: MSMessageTemplateLayout) throws -> MSMessage {
        let message = MSMessage()
        message.url = try envelope.messageURL()
        message.layout = layout
        message.summaryText = FernletMessagesCardCopy.messageSummary(title: envelope.card.title)
        return message
    }

    /// The recipe card's face: the drawn artwork, the recipe's name, its counts, whether a note rides
    /// along, and the "Opens in Fernlet on iPhone" line for a recipient who cannot open it.
    ///
    /// Read off the envelope's validated `card` — the recipe's name and counts, which
    /// `ExchangeCardMetadata.recipe(from:)` takes from the packet — rather than the packet's payload,
    /// so this file needs no import beyond the four the extension may have: the payload's members
    /// live in `FernletDomainModel`, which the app target (built with member-import visibility)
    /// would otherwise require here.
    static func recipeLayout(for card: ExchangeCardMetadata, includesNotes: Bool) -> MSMessageTemplateLayout {
        let layout = MSMessageTemplateLayout()
        layout.image = recipePlaceholderImage()
        layout.caption = card.title
        layout.subcaption = recipeSummary(servings: card.servings ?? 0, ingredients: card.ingredientCount ?? 0,
                                          steps: card.stepCount ?? 0)
        layout.trailingCaption = includesNotes
            ? FernletMessagesCardCopy.cardNotesIncluded
            : FernletMessagesCardCopy.cardRecipe
        layout.trailingSubcaption = FernletMessagesCardCopy.cardOpensInFernlet
        return layout
    }

    /// "4 servings · 9 ingredients · 6 steps": three separately plural-ruled counts joined by
    /// punctuation. One key holding all three would give a translator a single form for three
    /// independent plurals.
    static func recipeSummary(servings: Int, ingredients: Int, steps: Int) -> String {
        [
            FernletMessagesCardCopy.servingCount(servings),
            FernletMessagesCardCopy.ingredientCount(ingredients),
            FernletMessagesCardCopy.stepCount(steps)
        ].joined(separator: " · ")
    }

    /// Local, high-resolution recipe artwork; Messages never fetches or exposes private food photos.
    static func recipePlaceholderImage() -> UIImage {
        placeholderImage(sprite: .bowl, tag: FernletMessagesCardCopy.recipeTag)
    }

    /// The artwork's canvas: 1200×630, the 1.91:1 a Messages card shows.
    static let artworkSize = CGSize(width: 1_200, height: 630)
    /// Canvas points per point of the approved 270-point-wide card drawing (World Review Batch 4).
    private static let artworkScale: CGFloat = 1_200 / 270
    /// Where the grass strip's ink line starts, from the top: the drawing's 36-point strip.
    static let groundTop: CGFloat = 630 - 160

    /// A 1200×630 card image, the World pixel scene (`b4-msg-bubbles`): cream paper, `sprite` in the
    /// middle at 27 canvas points a pixel, a grass strip under an ink line along the bottom, and a
    /// framed tag top left with the pixel fern and `tag` ("Fernlet recipe"). Drawn at scale 1 so the
    /// bytes do not depend on the device's screen; always light, whatever the conversation's mode.
    static func placeholderImage(sprite: FernletMessagesSprite, tag: String) -> UIImage {
        let size = artworkSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            FernletMessagesPalette.paper.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            drawGround(in: size)
            let pixel: CGFloat = 27
            let origin = CGPoint(x: ((size.width - CGFloat(sprite.width) * pixel) / 2).rounded(.down),
                                 y: ((size.height - CGFloat(sprite.height) * pixel) / 2).rounded(.down))
            sprite.draw(at: origin, pixel: pixel)
            drawTag(tag, in: size)
        }
    }

    /// The ground: a 3-point ink line over a grass strip, scaled to the canvas.
    private static func drawGround(in size: CGSize) {
        let line = (3 * artworkScale).rounded()
        FernletMessagesPalette.ink.setFill()
        UIRectFill(CGRect(x: 0, y: groundTop, width: size.width, height: line))
        FernletMessagesPalette.grass.setFill()
        UIRectFill(CGRect(x: 0, y: groundTop + line, width: size.width, height: size.height - groundTop - line))
    }

    /// The framed tag: paper in a 2-point ink frame, the pixel fern, then `tag` in DM Sans bold,
    /// all at the drawing's 12-point size scaled to the canvas. A long translation truncates.
    private static func drawTag(_ tag: String, in size: CGSize) {
        let inset = (10 * artworkScale).rounded()
        let pad = CGSize(width: (7 * artworkScale).rounded(), height: (4 * artworkScale).rounded())
        let fernPixel = (2 * artworkScale).rounded()
        let gap = (5 * artworkScale).rounded()
        let font = UIFont(name: FernletMessagesFontName.dmSansMedium, size: 12 * artworkScale)
            ?? .systemFont(ofSize: 12 * artworkScale, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: FernletMessagesPalette.bark]
        let fernSide = CGFloat(FernletMessagesSprite.fern.width) * fernPixel
        let textSize = (tag as NSString).size(withAttributes: attributes)
        let maxText = size.width - 2 * inset - 2 * pad.width - fernSide - gap
        let textWidth = min(textSize.width.rounded(.up), maxText)
        let height = max(fernSide, textSize.height) + 2 * pad.height
        let frame = CGRect(x: inset, y: inset, width: 2 * pad.width + fernSide + gap + textWidth, height: height)
        let stroke = (2 * artworkScale).rounded()
        let plate = UIBezierPath(roundedRect: frame.insetBy(dx: stroke / 2, dy: stroke / 2),
                                 cornerRadius: (6 * artworkScale).rounded() - stroke / 2)
        FernletMessagesPalette.paper.setFill()
        plate.fill()
        FernletMessagesPalette.ink.setStroke()
        plate.lineWidth = stroke
        plate.stroke()
        FernletMessagesSprite.fern.draw(at: CGPoint(x: frame.minX + pad.width, y: (frame.midY - fernSide / 2).rounded()),
                                        pixel: fernPixel)
        let textRect = CGRect(x: frame.minX + pad.width + fernSide + gap, y: frame.midY - textSize.height / 2,
                              width: textWidth, height: textSize.height)
        (tag as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                               attributes: attributes, context: nil)
    }
}

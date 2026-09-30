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

/// The colours a Fernlet Messages card and the iMessage app's panel are drawn in, spelled out in
/// `UIColor` rather than read from the app's design tokens: an app extension is a separate process
/// with no access to the host's asset catalog, and a missing token here would render as
/// black-on-black rather than fail loudly. The card artwork uses `paper`, `sage` and `moss`.
enum FernletMessagesPalette {
    static let ink = UIColor(red: 0.24, green: 0.18, blue: 0.12, alpha: 1)
    static let moss = UIColor(red: 0.27, green: 0.41, blue: 0.23, alpha: 1)
    static let paper = UIColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1)
    static let card = UIColor(red: 0.99, green: 0.97, blue: 0.92, alpha: 1)
    static let sage = UIColor(red: 0.79, green: 0.85, blue: 0.73, alpha: 1)
    static let muted = UIColor(red: 0.36, green: 0.42, blue: 0.47, alpha: 1)
    static let line = UIColor(red: 0.24, green: 0.18, blue: 0.12, alpha: 0.16)
}

/// Builds the `MSMessage` a Fernlet recipe or workout card travels as: the envelope's serverless
/// `data:` URL, a template layout, and the summary Messages reads aloud.
///
/// The recipe card is whole here (``recipeMessage(for:)``); the workout card's layout stays in the
/// iMessage app, which is the only place that sends one, and reaches this type for the shared
/// ``message(for:layout:)`` and ``placeholderImage(symbol:label:)``. Main-actor isolated in both
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
        placeholderImage(symbol: "fork.knife", label: FernletMessagesCardCopy.recipeWordmark)
    }

    /// A 1200×630 card image: an SF Symbol on a sage halo over the paper colour, with `label` as the
    /// wordmark beneath it. Drawn at scale 1 so the bytes do not depend on the device's screen.
    static func placeholderImage(symbol: String, label: String) -> UIImage {
        let size = CGSize(width: 1_200, height: 630)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            FernletMessagesPalette.paper.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            drawPlaceholderSymbol(named: symbol)
            drawPlaceholderWordmark(label, in: size)
        }
    }

    private static func drawPlaceholderSymbol(named symbol: String) {
        let halo = UIBezierPath(ovalIn: CGRect(x: 350, y: 60, width: 500, height: 470))
        FernletMessagesPalette.sage.withAlphaComponent(0.5).setFill()
        halo.fill()
        let configuration = UIImage.SymbolConfiguration(pointSize: 250, weight: .medium)
        let image = UIImage(systemName: symbol, withConfiguration: configuration)
        let tinted = image?.withTintColor(FernletMessagesPalette.moss, renderingMode: .alwaysOriginal)
        tinted?.draw(in: CGRect(x: 475, y: 145, width: 250, height: 250))
    }

    private static func drawPlaceholderWordmark(_ label: String, in size: CGSize) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: FernletMessagesPalette.moss,
            .paragraphStyle: paragraphStyle
        ]
        let rect = CGRect(x: 0, y: size.height - 88, width: size.width, height: 40)
        label.draw(in: rect, withAttributes: attributes)
    }
}

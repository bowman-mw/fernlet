import Foundation
import Messages
import Testing
import UIKit
import FernletDomainModel
import FernletExchange
@testable import Fernlet

/// The recipe card the app's "Send in Messages" composes is the card the iMessage app inserts.
///
/// There is ONE builder, `FernletMessagesCard`, compiled into both targets (the app through a
/// membership exception on the extension's synchronized folder — `MessagesExtensionBoundaryTests`
/// pins the exception and that no second builder exists). This test bundle links the app, so it
/// exercises that builder directly: the URL is exactly the envelope's own `messageURL()` (the wire is
/// never forked), it decodes back to the same packet through the path a recipient's extension runs,
/// and the face is the recipe's name, its counts, its notes flag and the "Opens in Fernlet on iPhone"
/// line. The strings resolve here exactly as they do in the app process — against the iMessage app's
/// catalog, which the app reads out of the extension bundle it embeds
/// (``theAppReadsTheCardCopyFromTheEmbeddedIMessageApp()``) — and
/// ``aOneOfEachCardReadsAsTheIMessageAppsCard()`` holds them to that catalog's reading.
@MainActor
struct MessagesRecipeCardParityTests {
    @Test func theCardsURLIsTheEnvelopesOwnAndOpensAsTheSamePacket() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let packet = try RecipeExchangePacket(recipe: salad.recipe, foodItems: salad.foodItems, includesNotes: true)

        let message = try FernletMessagesCard.recipeMessage(for: packet)
        let url = try #require(message.url)
        #expect(url == (try ExchangeMessageEnvelope(recipe: packet).messageURL()))
        #expect(url.absoluteString.utf8.count <= ExchangeLimits.maxMessageURLCharacters)

        let opened = try ExchangeMessageEnvelope.decode(messageURL: url)
        guard case .recipe(let received) = try opened.validatedPayload() else {
            Issue.record("The card did not open as a recipe.")
            return
        }
        #expect(received == packet)
        #expect(received.recipe.componentSlices?.map(\.name)
                == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])
        #expect(FernletMessagesReceivedItem.resolve(messageURL: url) != .invalid,
                "the recipient's extension resolves it as the sender's own card")
    }

    @Test func theCardsFaceIsTheRecipesNameCountsAndLines() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let packet = try RecipeExchangePacket(recipe: salad.recipe, foodItems: salad.foodItems, includesNotes: true)
        let message = try FernletMessagesCard.recipeMessage(for: packet)
        let layout = try #require(message.layout as? MSMessageTemplateLayout)

        #expect(layout.caption == RecipeMultipartFixtures.recipeName)
        #expect(layout.subcaption == "4 servings · 9 ingredients · 5 steps")
        #expect(layout.subcaption == FernletMessagesCard.recipeSummary(servings: 4, ingredients: 9, steps: 5))
        #expect(layout.trailingCaption == FernletMessagesCardCopy.cardNotesIncluded)
        #expect(layout.trailingSubcaption == FernletMessagesCardCopy.cardOpensInFernlet)
        #expect(layout.trailingSubcaption == "Opens in Fernlet on iPhone")
        #expect(message.summaryText == FernletMessagesCardCopy.messageSummary(title: RecipeMultipartFixtures.recipeName))
        let image = try #require(layout.image)
        #expect(image.size == CGSize(width: 1_200, height: 630) && image.scale == 1)
    }

    @Test func aCardWithoutNotesSaysItIsAPlainRecipe() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let packet = try RecipeExchangePacket(recipe: salad.recipe, foodItems: salad.foodItems, includesNotes: false)
        let layout = try #require(try FernletMessagesCard.recipeMessage(for: packet).layout as? MSMessageTemplateLayout)
        #expect(layout.trailingCaption == FernletMessagesCardCopy.cardRecipe)
        #expect(layout.trailingCaption == "Fernlet recipe")
    }

    /// A one-serving, one-ingredient, one-step card reads exactly as the iMessage app's card does
    /// (review C-F1/L-F1, 2026-09-30), and so does every other string on the face.
    ///
    /// The counts are where a card resolved in the app could part from the iMessage app's: the
    /// extension catalog carries hand-authored `one`/`other` plural blocks that `xcstringstool sync`
    /// never writes, and round 1, which let the app read `App/Fernlet/Localizable.xcstrings`, sent
    /// "1 servings · 1 ingredients · 1 steps" while the iMessage app sent "1 serving · 1 ingredient ·
    /// 1 step". Four servings (the fixture above) cannot see that. This resolves each string against
    /// the extension bundle the app embeds and requires the app's own resolution to match, in
    /// whatever language the run is in, at one and at four — whatever `FernletMessagesCardCopy`
    /// resolves against, this is the reading it must produce.
    @Test func aOneOfEachCardReadsAsTheIMessageAppsCard() throws {
        let appex = try #require(Self.messagesExtensionBundle(),
                                 "the app embeds PlugIns/FernletMessagesExtension.appex; the parity check needs it")
        for count in [1, 4] {
            let extensionSummary = [
                String(localized: "messages.recipe.servingCount", defaultValue: "\(count) servings", bundle: appex),
                String(localized: "messages.recipe.ingredientCount", defaultValue: "\(count) ingredients", bundle: appex),
                String(localized: "messages.recipe.stepCount", defaultValue: "\(count) steps", bundle: appex)
            ].joined(separator: " · ")
            #expect(FernletMessagesCard.recipeSummary(servings: count, ingredients: count, steps: count) == extensionSummary,
                    "the app's card and the iMessage app's card read differently at a count of \(count)")
        }
        if Locale.current.language.languageCode == .english {
            #expect(FernletMessagesCard.recipeSummary(servings: 1, ingredients: 1, steps: 1)
                    == "1 serving · 1 ingredient · 1 step")
        }
        let title = RecipeMultipartFixtures.recipeName
        #expect(FernletMessagesCardCopy.messageSummary(title: title)
                == String(localized: "messages.card.summaryText", defaultValue: "Fernlet: \(title)", bundle: appex))
        #expect(FernletMessagesCardCopy.cardNotesIncluded
                == String(localized: "messages.card.notesIncluded", defaultValue: "Notes included", bundle: appex))
        #expect(FernletMessagesCardCopy.cardRecipe
                == String(localized: "messages.card.recipe", defaultValue: "Fernlet recipe", bundle: appex))
        #expect(FernletMessagesCardCopy.cardOpensInFernlet
                == String(localized: "messages.card.opensInFernlet", defaultValue: "Opens in Fernlet on iPhone", bundle: appex))
        #expect(FernletMessagesCardCopy.recipeWordmark
                == String(localized: "messages.card.wordmark.recipe", defaultValue: "FERNLET RECIPE", bundle: appex))
    }

    /// In the app, the card's copy is read from the iMessage app's bundle — the one the app embeds —
    /// and never from the app's own (review C-F1/L-F1, fix round 2, 2026-09-30).
    ///
    /// This test bundle is hosted by the app, so `Bundle.main` here is the app's, exactly as in the
    /// process that composes "Send in Messages". One catalog means one set of plural blocks and one
    /// place a translator works: the card cannot read differently from the iMessage app's in any
    /// language, and the app catalog needs none of its keys
    /// (`MessagesExtensionBoundaryTests.theSharedCardCopyIsReadOnlyFromTheExtensionsCatalog()`).
    @Test func theAppReadsTheCardCopyFromTheEmbeddedIMessageApp() throws {
        let appex = try #require(Self.messagesExtensionBundle(),
                                 "the app embeds PlugIns/FernletMessagesExtension.appex; the card's copy is read from it")
        let catalog = FernletMessagesCardCopy.catalog
        #expect(catalog.bundleURL.standardizedFileURL == appex.bundleURL.standardizedFileURL,
                "the app resolves the card's copy against \(catalog.bundleURL.lastPathComponent), not the embedded iMessage app")
        #expect(catalog.bundleURL.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL)
        #expect(catalog.bundleURL.pathExtension == "appex")
        #expect(catalog.localizations.contains("en"), "the embedded iMessage app carries no English catalog")
    }

    /// The iMessage app's bundle as the app embeds it — the catalog the extension process reads.
    static func messagesExtensionBundle() -> Bundle? {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return nil }
        return Bundle(url: plugIns.appendingPathComponent("FernletMessagesExtension.appex"))
    }

    /// Forty-five steps of a thousand incompressible characters will not fit a card, and the builder
    /// says so with the error the iMessage app turns into "too large" — never a card Messages refuses.
    @Test func aRecipeTooBigForACardIsRefusedBeforeMessagesSeesIt() throws {
        let packet = try RecipeExchangePacket(recipe: RecipeMessagesCardOfferTests.oversizeRecipe(),
                                              foodItems: [], includesNotes: true)
        #expect(throws: ExchangePacketError.self) { try FernletMessagesCard.recipeMessage(for: packet) }
        do {
            _ = try FernletMessagesCard.recipeMessage(for: packet)
        } catch let error as ExchangePacketError {
            #expect(error == .tooLarge || error == .invalidMessageURL)
        }
    }
}

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
/// line. The strings resolve against the app's catalog here, as they do in the app process.
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

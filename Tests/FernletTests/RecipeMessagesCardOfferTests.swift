import Foundation
import Testing
import FernletDomainModel
import FernletExchange
import ProximityKit
@testable import Fernlet

/// What the recipe Share screen's "Send in Messages" row offers (`FernletStore.recipeMessagesCardOffer`),
/// and the one draft every entry point builds (`FernletStore.recipeShareDraft(for:)`).
///
/// The row is offered only for a card `MSConversation` would accept, so the store builds the card's
/// URL up front: a recipe past the card's limits, or with a name over its 120-character title, gets
/// the "too long" note instead. A recipe saved from a web page is left out on purpose — its card
/// would carry no ingredients (the pinned defect in `FernletExchangeTests`), and this entry point
/// must not widen that. "Include notes" off withholds the notes AND the steps of a recipe the person
/// made, as the nearby share does. The device half (`canSendText`) is not here: it is false on every
/// simulator, and the view reads it live.
@MainActor
struct RecipeMessagesCardOfferTests {
    @Test func aRecipeThePersonMadeIsReadyWithItsNotesAndSteps() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let offer = FernletStore.messagesCardOffer(for: salad.recipe, foodItems: salad.foodItems, includesNotes: true)
        guard case .ready(let packet) = offer else {
            Issue.record("Expected a card, got \(offer).")
            return
        }
        #expect(packet == (try RecipeExchangePacket(recipe: salad.recipe, foodItems: salad.foodItems, includesNotes: true)),
                "the same packet the iMessage app's catalog publishes for this recipe")
        #expect(packet.includesNotes && packet.recipe.steps?.count == 5)
    }

    @Test func notesOffWithholdsTheNotesAndTheSteps() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let offer = FernletStore.messagesCardOffer(for: salad.recipe, foodItems: salad.foodItems, includesNotes: false)
        guard case .ready(let packet) = offer else {
            Issue.record("Expected a card, got \(offer).")
            return
        }
        #expect(!packet.includesNotes && packet.recipe.notes.isEmpty)
        #expect(packet.recipe.steps == nil, "step text is the sender's own prose, withheld like the notes")
        #expect(packet.recipe.ingredients.count == 9, "the ingredients still go")
    }

    @Test func aWebRecipeIsNotOfferedACard() {
        let offer = FernletStore.messagesCardOffer(for: RecipeShareTextTests.webRecipe(), foodItems: [], includesNotes: true)
        #expect(offer == .webImported)
    }

    @Test func aRecipeTooBigForACardGetsTheTooLongNote() {
        #expect(FernletStore.messagesCardOffer(for: Self.oversizeRecipe(), foodItems: [], includesNotes: true) == .tooLarge)
    }

    @Test func aNameOverTheCardsTitleLimitGetsTheTooLongNote() {
        var recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        let foods = RecipeMultipartFixtures.saladWithHomemadeDressing().foodItems
        recipe.name = String(repeating: "a", count: ExchangeLimits.maxCardTitleCharacters + 1)
        #expect(FernletStore.messagesCardOffer(for: recipe, foodItems: foods, includesNotes: true) == .tooLarge)
        recipe.name = String(repeating: "a", count: ExchangeLimits.maxCardTitleCharacters)
        guard case .ready = FernletStore.messagesCardOffer(for: recipe, foodItems: foods, includesNotes: true) else {
            Issue.record("A name at the limit must still get a card.")
            return
        }
    }

    /// Every Share-screen entry point builds its draft here, from either half of the recipe book.
    @Test func theDraftCarriesTheRecipeAndItsNearbyPayload() throws {
        let store = makeTestStore()
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let local = store.recipeShareDraft(for: salad.recipe)
        #expect(local.title == salad.recipe.name && local.recipe == salad.recipe)
        #expect(local.payload.recipe.kind == .local)

        let web = RecipeShareTextTests.webRecipe()
        let saved = store.recipeShareDraft(for: web)
        #expect(saved.title == web.name && saved.recipe == web)
        #expect(saved.payload.recipe.kind == .saved)
        #expect(saved.payload.recipe.saved?.sourceURLString == web.webImport?.sourceURLString)
    }

    /// Forty-five steps of a thousand incompressible characters: inside every recipe limit, far past
    /// what a Messages card carries.
    static func oversizeRecipe() -> RecipeDefinition {
        let steps = (0..<45).map { index in
            RecipeStep(text: (0..<28).map { _ in UUID().uuidString }.joined(separator: " ") + " \(index)")
        }
        return RecipeDefinition(name: "Forty-five long steps", servings: 2, ingredients: [], source: "manual",
                                createdAt: Date(timeIntervalSince1970: 1_779_664_800),
                                updatedAt: Date(timeIntervalSince1970: 1_779_664_800), steps: steps)
    }
}

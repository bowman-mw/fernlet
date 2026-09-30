import FernletFoundation
import FernletDomainModel
import FernletExchange
import FoodCatalog
import Foundation

/// What the recipe Share screen's "Send in Messages" row can offer for one recipe, decided before the
/// row is drawn so it never offers a card Messages would refuse.
///
/// - `ready` carries the packet the card is built from (`FernletMessagesCard.recipeMessage(for:)`).
/// - `webImported`: a recipe saved from a web page. Its card would carry no ingredients — the pinned
///   defect `FernletExchangeTests.webImportedRecipesShareWithNoIngredientsAPinnedDefect`, which is
///   the owner's call — so this new entry point does not widen it; the row points to text instead.
/// - `tooLarge`: past what a card can carry (`ExchangeLimits`: the 5,000-character URL, the
///   compressed frame, the packet), or a name over the card's 120-character title limit.
/// - `unavailable`: any other refusal from the packet's validation. Logged, never silent.
enum RecipeMessagesCardOffer: Equatable {
    case ready(RecipeExchangePacket)
    case webImported
    case tooLarge
    case unavailable
}

extension FernletStore {
    /// The Share screen's draft for `recipe`, from either half of the recipe book: its title, the
    /// recipe itself (the sheet builds the text and the Messages card from it, for the current
    /// "Include notes" choice) and the nearby payload.
    func recipeShareDraft(for recipe: RecipeDefinition) -> ProximityRecipeShareDraft {
        ProximityRecipeShareDraft(
            title: recipe.name,
            recipe: recipe,
            payload: proximityRecipeSharePayload(for: recipe)
        )
    }

    /// The readable text "Share as text" hands the system share sheet — see ``RecipeShareText``. It
    /// carries no Fernlet data; calories appear only when the person shows calories.
    func recipeShareText(for recipe: RecipeDefinition, includesNotes: Bool) -> String {
        RecipeShareText.text(
            for: recipe,
            foodItems: foodCatalog.items(forRecipe: recipe),
            showCalories: settings.showCalories,
            includesNotes: includesNotes
        )
    }

    /// What "Send in Messages" can offer for `recipe` — see ``RecipeMessagesCardOffer``.
    func recipeMessagesCardOffer(for recipe: RecipeDefinition, includesNotes: Bool) -> RecipeMessagesCardOffer {
        Self.messagesCardOffer(for: recipe, foodItems: foodCatalog.items(forRecipe: recipe), includesNotes: includesNotes)
    }

    /// The pure half of ``recipeMessagesCardOffer(for:includesNotes:)``.
    ///
    /// "Include notes" off withholds what the nearby share withholds for a recipe the person made:
    /// the notes AND the steps (`ProximityRecipeSharePayload.omittingShareNotes()` — step text is
    /// free-form and can carry the same personal remarks). The fit is checked by building the card's
    /// URL here, so the row is only offered for a card `MSConversation` would accept.
    static func messagesCardOffer(
        for recipe: RecipeDefinition, foodItems: [FoodItem], includesNotes: Bool
    ) -> RecipeMessagesCardOffer {
        guard recipe.webImport == nil else { return .webImported }
        var shared = recipe
        if !includesNotes {
            shared.notes = ""
            shared.steps = nil
        }
        do {
            let packet = try RecipeExchangePacket(recipe: shared, foodItems: foodItems, includesNotes: includesNotes)
            _ = try ExchangeMessageEnvelope(recipe: packet).messageURL()
            return .ready(packet)
        } catch ExchangePacketError.tooLarge, ExchangePacketError.invalidMessageURL,
                ExchangePacketError.invalidCardMetadata {
            return .tooLarge
        } catch {
            FernletAuditLog.log("recipeShare.messagesCard.unavailable", context: ["error": String(describing: error)])
            return .unavailable
        }
    }
}

import Foundation
import SwiftUI
import Testing
import FernletDomainModel
import FernletExchange
@testable import Fernlet

/// Shortcuts' two confirmations (World Review Batch 4, `b4-sc-recipe`, `b4-sc-plan`): their lines, and
/// that each draws as Fernlet's framed card.
///
/// The copy fix the owner approved with the batch is the plural: Import recipe read "1 servings", and
/// the plan's collisions and warnings read "1 collisions", "1 … warnings". The recipe's counts are the
/// Messages card's own, read from the iMessage app's catalog whose `one`/`other` blocks already exist;
/// the plan's two keys wait in `LocalizationBoundaryTests.pluralRuledKeysAwaitingTheirCatalog`.
@MainActor
struct ExchangeSnippetTests {
    private var english: Bool { Locale.current.language.languageCode == .english }

    /// The recipe's two lines are the Messages card's plural-ruled counts, so one serving reads as one.
    @Test func theRecipeLinesCountLikeTheMessagesCard() {
        #expect(ExchangeSnippetCopy.servingsAndIngredients(servings: 1, ingredients: 9)
                == [FernletMessagesCardCopy.servingCount(1), FernletMessagesCardCopy.ingredientCount(9)].joined(separator: " · "))
        #expect(ExchangeSnippetCopy.stepsAndNotes(steps: 6, includesNotes: true)
                .hasPrefix(FernletMessagesCardCopy.stepCount(6) + " · "))
        guard english else { return }
        #expect(ExchangeSnippetCopy.servingsAndIngredients(servings: 1, ingredients: 9) == "1 serving · 9 ingredients")
        #expect(ExchangeSnippetCopy.servingsAndIngredients(servings: 2, ingredients: 1) == "2 servings · 1 ingredient")
        #expect(ExchangeSnippetCopy.stepsAndNotes(steps: 6, includesNotes: true) == "6 steps · Notes included")
        #expect(ExchangeSnippetCopy.stepsAndNotes(steps: 1, includesNotes: false) == "1 step · No notes")
    }

    /// The plan's lines: the sender or its fallback, collisions with the policy's name, the changes and
    /// the warnings.
    @Test func thePlanLinesSayWhatTheImportDoes() {
        #expect(ExchangeSnippetCopy.sender("Sam") == "Sam")
        #expect(!ExchangeSnippetCopy.sender("").isEmpty)
        #expect(ExchangeSnippetCopy.collisions(2, policy: .addAlongside)
                .hasSuffix(" · " + WorkoutPlanCollisionPolicy.addAlongside.displayName))
        guard english else { return }
        #expect(ExchangeSnippetCopy.sender("") == "Sender not specified")
        #expect(ExchangeSnippetCopy.collisions(3, policy: .keepExistingWorkouts) == "3 collisions · Keep existing workouts")
        #expect(ExchangeSnippetCopy.changes(added: 3, changed: 0, removed: 0) == "3 added · 0 changed · 0 removed")
        #expect(ExchangeSnippetCopy.safetyWarnings(2) == "2 avoided or unavailable exercise warnings")
        #expect(WorkoutPlanCollisionPolicy.replaceFutureConflicts.displayName == "Replace future conflicts")
    }

    /// The recipe confirmation draws (the framed card with its pixel bowl) at a phone's snippet width,
    /// in light and dark, a recipe made in parts included.
    @Test func theRecipeConfirmationDraws() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let packet = try RecipeExchangePacket(recipe: salad.recipe, foodItems: salad.foodItems, includesNotes: true)
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: RecipeExchangeConfirmation(packet: packet)
                .frame(width: 350)
                .environment(\.colorScheme, scheme))
            let image = try #require(renderer.uiImage)
            #expect(image.size.width == 350 && image.size.height > 100)
        }
    }
}

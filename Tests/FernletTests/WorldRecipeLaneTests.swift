import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The World build's recipe lane (`b2-recipe-book` … `b3-sharing-settings`): the ingredient icons the
/// compact rows choose, the recipe page's in-place notes edit, and the two recipe-sharing choices that
/// moved from the share sheet to Settings › Sharing.
@MainActor
struct WorldRecipeLaneTests {

    // MARK: - Ingredient icons (b2-recipe-detail draft 3)

    @Test func ingredientsWithArtShowIt() {
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Rolled oats") == WorldSprites.oats)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Greek yogurt, plain") == WorldSprites.yogurt)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Blueberries") == WorldSprites.berries)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Chicken thighs") == WorldSprites.drumstick)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Olive oil") == WorldSprites.fatDrop)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Basmati rice") == WorldSprites.wheat)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Cebolla morada") == WorldSprites.onion,
                "a Spanish catalog name finds its art too")
    }

    /// Matching reads word starts, so a word that merely contains a key never borrows its art.
    @Test func nearMissesDoNotBorrowArt() {
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Goat cheese") != WorldSprites.oats)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Eggplant") != WorldSprites.egg)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Butternut squash") != WorldSprites.fatDrop)
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: "Fresh ginger") != WorldSprites.drumstick)
        #expect(!RecipeIngredientArt.hasArt(forIngredientNamed: "Garam masala"))
    }

    /// An ingredient with no art gets a dot whose colour is the same on every launch and every row.
    @Test func dotsAreStableAndDrawnFromThePalette() {
        let first = RecipeIngredientArt.sprite(forIngredientNamed: "Garam masala")
        let again = RecipeIngredientArt.sprite(forIngredientNamed: "Garam masala")
        #expect(first == again)
        #expect(RecipeIngredientArt.dotColours.contains(RecipeIngredientArt.dotColour(for: "garam masala")))
        #expect(RecipeIngredientArt.sprite(forIngredientNamed: nil).rows.count == 5, "an unresolved food draws a dot")
        #expect(RecipeIngredientArt.highlight(0x000000) == 0x8C8C8C)
        #expect(RecipeIngredientArt.highlight(0xFFFFFF) == 0xFFFFFF)
    }

    /// The new one-colour icons are pure ink, so they take the ink token in dark mode.
    @Test func theRecipeIconsAreInkIcons() {
        for sprite in [WorldSprites.share, WorldSprites.swap, WorldSprites.globe, WorldSprites.clock,
                       WorldSprites.doc, WorldSprites.plane, WorldSprites.waves, WorldSprites.bubble,
                       WorldSprites.trash, WorldSprites.barcode, WorldSprites.chevU] {
            #expect(sprite.isMonoInk)
            #expect(Set(sprite.rows.map(\.count)).count == 1, "every row the same width")
        }
    }

    // MARK: - Notes on the recipe page (b3-recipe-notes draft 2)

    @Test func theNotesCardChangesOnlyTheNotes() throws {
        let store = makeTestStore()
        let recipe = store.addRecipe(name: "Overnight oats", servings: 2, notes: "Mix.",
                                     ingredients: [ManualRecipeIngredientInput(name: "Oats", quantity: 1, unit: "cup",
                                                                               protein: 5, carbs: 27, fat: 3)],
                                     steps: [RecipeStep(text: "Stir")])
        store.updateRecipeNotes("  Swap the berries for what's in season.  ", forRecipeID: recipe.id)
        let updated = try #require(store.recipes.first { $0.id == recipe.id })
        #expect(updated.notes == "Swap the berries for what's in season.")
        #expect(updated.name == recipe.name && updated.servings == recipe.servings)
        #expect(updated.ingredients == recipe.ingredients)
        #expect(updated.steps?.map(\.text) == ["Stir"])
        // A recipe deleted meanwhile is left alone.
        store.updateRecipeNotes("Gone", forRecipeID: UUID())
        #expect(store.recipes.count == 1)
    }

    // MARK: - Recipe sharing choices (b3-sharing-settings)

    @Test func recipeSharingChoicesDefaultOnAndRoundTrip() throws {
        let defaults = FernletSettings()
        #expect(defaults.recipeShareIncludesNotes && defaults.recipeShareIncludesPicture,
                "both on by default, as the share sheet's switches were")
        // A settings blob from before the move carries neither key and decodes them on.
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any])
        legacy.removeValue(forKey: "recipeShareIncludesNotes")
        legacy.removeValue(forKey: "recipeShareIncludesPicture")
        let decoded = try JSONDecoder().decode(FernletSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.recipeShareIncludesNotes && decoded.recipeShareIncludesPicture)
        var off = defaults
        off.recipeShareIncludesNotes = false
        off.recipeShareIncludesPicture = false
        let roundTripped = try JSONDecoder().decode(FernletSettings.self, from: JSONEncoder().encode(off))
        #expect(!roundTripped.recipeShareIncludesNotes && !roundTripped.recipeShareIncludesPicture)
    }
}

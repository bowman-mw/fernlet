import DiaryStore
import FernletDomainModel
import Foundation

extension FernletStore {
    /// Writes only a recipe's notes, in whichever half of the book holds it: the recipe page's Notes
    /// card (World `b3-recipe-notes`, draft 2: notes live on the recipe page, not in a sheet). A saved
    /// or web recipe merges the one field into its live row (``updateSavedRecipeNotes(_:forRecipeID:)``);
    /// a manual recipe changes its notes and nothing else. A recipe deleted meanwhile is left alone.
    func updateRecipeNotes(_ notes: String, forRecipeID recipeID: UUID) {
        if savedRecipes.contains(where: { $0.id == recipeID }) {
            updateSavedRecipeNotes(notes, forRecipeID: recipeID)
        } else {
            diary.updateRecipeNotes(notes, forRecipeID: recipeID)
        }
    }
}

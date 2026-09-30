import SwiftUI
import FernletUI

/// The line under a web-imported recipe's macros saying how many of its ingredients the USDA
/// estimate left out (ingredient-search round, F11).
///
/// The web importer used to void a page's whole estimate when one ingredient line could not be
/// converted, rather than publish a partial one silently. It now skips that line and counts it
/// (`RecipeWebImport.uncountedIngredientLines`), and this note is what keeps the partial estimate
/// from reading as a whole one. Renders nothing for a label-sourced import, a complete estimate, or
/// a recipe imported before the count existed.
struct WebImportEstimateNote: View {
    /// Lines the estimate left out; nil or 0 shows nothing.
    var uncountedLines: Int?

    var body: some View {
        if let uncountedLines, uncountedLines > 0 {
            Text("^[\(uncountedLines) ingredient](inflect: true) not counted in this estimate")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("recipe.webImport.uncountedIngredients")
        }
    }
}

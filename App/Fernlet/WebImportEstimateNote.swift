import SwiftUI
import FernletUI

/// The line under a web-imported recipe's macros saying how many of its ingredients the USDA
/// estimate left out (ingredient-search round, F11).
///
/// The web importer used to void a page's whole estimate when one ingredient line could not be
/// converted, rather than publish a partial one silently. It now skips that line and counts it
/// (`RecipeWebImport.uncountedIngredientLines`), and this note is what keeps the partial estimate
/// from reading as a whole one. It sits wherever the estimate is read or logged from: the recipe
/// detail's macros card (the page an import lands on, and the one "Log" commits from), the book
/// row's macros line, and the notes sheet — there even when the estimate rounds to all zeros and its
/// macros card is hidden (fix round 1, u3-C-U3-1). Renders nothing for a label-sourced import, a
/// complete estimate, or a recipe imported before the count existed.
///
/// It also says how many lines the estimate weighed by a USDA typical size (ingredient-search round
/// F4b, fix round 1, finding s2-L-F4b-DT-3: `RecipeWebImport.estimatedIngredientLines`) — lines that
/// used to be left out and noted, and are now counted by a curated size rather than by the food's own
/// data, so the estimate says it leans on them.
struct WebImportEstimateNote: View {
    /// Lines the estimate left out; nil or 0 shows nothing.
    var uncountedLines: Int?
    /// Lines the estimate weighed by a USDA typical size; nil or 0 shows nothing.
    var estimatedLines: Int?

    var body: some View {
        if let uncountedLines, uncountedLines > 0 {
            Text("^[\(uncountedLines) ingredient](inflect: true) not counted in this estimate")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("recipe.webImport.uncountedIngredients")
        }
        if let estimatedLines, estimatedLines > 0 {
            Text("^[\(estimatedLines) ingredient](inflect: true) weighed by a USDA typical size (estimate)")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("recipe.webImport.typicalSizeIngredients")
        }
    }
}

import SwiftUI
import FernletUI

/// The "Create custom ingredient" escape shown BENEATH a recipe ingredient's catalog matches
/// (ingredient-search round, F9).
///
/// It used to appear only when a search returned nothing, so a list of six wrong rows — 24 chip
/// cookies for "chocolate chips" — left no visible way out but to scroll to the manual macro rows and
/// guess that typing there makes a custom ingredient. This row names that way. Once taken it becomes
/// the same instruction the empty-results state shows; the list stays, so a tap on a row still binds
/// it. Kept out of `RecipeIngredientEditor`'s body on purpose: one line there, the view here.
struct CustomIngredientEscapeRow: View {
    /// Whether the person already chose to create one; the row then says what to do next.
    var isCreating: Bool
    /// Starts creating a custom ingredient.
    var onCreate: () -> Void

    var body: some View {
        if isCreating {
            Text("Add its macros below, then save the custom ingredient.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        } else {
            Button(action: onCreate) {
                Label("Create custom ingredient", systemImage: "plus.circle")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recipeIngredient.createCustom")
        }
    }
}

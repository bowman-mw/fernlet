//
//  RecipeIngredientRecipes.swift
//  Fernlet
//
//  Recipes as building blocks, step 3 (Docs/Recipes-As-Building-Blocks-Design-2026-11-15.md §2, §6,
//  §11): the recipe editor's ways to use a saved recipe as an ingredient — the "Your recipes" group
//  above food results, the "From your recipes" list, the amount a recipe line is typed in, the
//  recipe's own optional "Makes" amount, and the "Used in" note on a recipe others use.
//

import SwiftUI
import FernletDomainModel
import FernletUI

/// What the recipe editor's ingredient rows need to offer saved recipes: the recipes this recipe may
/// use, every recipe by id (a bound row's servings and "Makes" amount), and the way to prepare a
/// picked recipe's recipe food. ``none`` offers nothing (the multipart parts editor, which is retired
/// in favour of separate recipes).
struct RecipeIngredientRecipeSource {
    let choices: [RecipeDefinition]
    let recipesByID: [UUID: RecipeDefinition]
    let prepare: (RecipeDefinition) -> FoodItem?

    static let none = RecipeIngredientRecipeSource(choices: [], recipesByID: [:], prepare: { _ in nil })

    /// The store's recipes for a recipe being edited (`editing` nil while it is new).
    @MainActor
    static func from(_ store: FernletStore, editing: UUID?) -> RecipeIngredientRecipeSource {
        let all = store.allRecipesForNesting
        return RecipeIngredientRecipeSource(
            choices: store.recipeIngredientChoices(editing: editing),
            recipesByID: Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            prepare: { store.prepareRecipeFood(for: $0) }
        )
    }
}

/// The short "Your recipes" group above food results (owner pick P10a): at most three saved recipes
/// whose names hold the typed words.
struct RecipeSuggestionGroup: View {
    let recipes: [RecipeDefinition]
    let onPick: (RecipeDefinition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your recipes")
                .font(FernletFramedFont.rowDetailBold)
                .foregroundStyle(WorldPalette.dim)
                .accessibilityAddTraits(.isHeader)
            ForEach(recipes) { recipe in
                RecipeChoiceRow(recipe: recipe) { onPick(recipe) }
            }
        }
        .accessibilityIdentifier("recipeIngredient.recipeResults")
    }
}

/// One saved recipe offered as an ingredient: its name and what it makes.
struct RecipeChoiceRow: View {
    let recipe: RecipeDefinition
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                WorldSpriteView(sprite: WorldSprites.pen, scale: 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: recipe.name)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    Text(RecipeMakesText.summary(for: recipe))
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.moss)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityInputLabels([Text(verbatim: recipe.name)])
    }
}

/// The plain words for what a recipe makes, shown under its name wherever it is offered as an
/// ingredient and on a line that uses it.
enum RecipeMakesText {
    /// "4 servings" or "4 servings · makes 2 cups".
    static func summary(for recipe: RecipeDefinition) -> String {
        let servings = String(localized: "\(recipe.servings) servings",
                              comment: "How many servings a saved recipe makes, under its name when it is offered as an ingredient of another recipe")
        guard let makes = recipe.makes?.validated else { return servings }
        let amount = amountText(makes.quantity, unit: makes.recipeUnit)
        return String(localized: "\(servings) · makes \(amount)",
                      comment: "Under a saved recipe offered as an ingredient: its servings, then how much the whole recipe makes, e.g. '4 servings · makes 2 cups'")
    }

    /// "2 cup", "1.5 batch" style amount text: the number in the person's locale and the unit's label.
    static func amountText(_ quantity: Double, unit: RecipeUnit?) -> String {
        let number = RecipeQuantityDisplay.display(quantity)
        guard let unit else { return number }
        return "\(number) \(unit.label)"
    }
}

/// The amount a line using a saved recipe is typed in: servings, batches, or the recipe's "Makes"
/// unit (owner pick P02a). The line is always saved in servings (`RecipeFood`); the field shows and
/// takes the amount in the chosen unit and says what it is in servings.
struct RecipeAmountRow: View {
    @Binding var ingredient: ManualRecipeIngredientInput
    let recipe: RecipeDefinition
    @Binding var unit: RecipeAmountUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("Qty", value: amount, format: .number, prompt: .fieldPrompt("Qty"))
                    .keyboardType(.decimalPad)
                    .textContentType(.none)
                    .sheetTextInput()
                    .frame(maxWidth: 92)
                    .accessibilityIdentifier("recipeIngredient.recipeAmount")
                FernletDropdown("Unit", selection: $unit, options: RecipeAmountUnit.choices(for: recipe),
                                showsLabel: false, fullWidth: true) { choice in
                    Text(label(for: choice))
                }
            }
            if unit != .servings {
                Text("That's \(RecipeQuantityDisplay.display(ingredient.quantity)) servings of \(recipe.name).")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// The typed amount in `unit`, written back as servings.
    private var amount: Binding<Double> {
        Binding(
            get: { unit.amount(forServings: ingredient.quantity, of: recipe) },
            set: { typed in
                let servings = typed * unit.servingsPerUnit(of: recipe)
                guard servings.isFinite, servings > 0 else { return }
                ingredient.quantity = min(servings, SharedRecipeLimits.maxQuantity)
                ingredient.unit = RecipeUnit.serving.rawValue
            }
        )
    }

    private func label(for choice: RecipeAmountUnit) -> String {
        switch choice {
        case .servings:
            String(localized: "servings", comment: "Unit choice for a line that uses another saved recipe: servings of that recipe")
        case .batches:
            String(localized: "batches", comment: "Unit choice for a line that uses another saved recipe: whole batches of that recipe, e.g. '½ batches'")
        case .makes(let yield):
            yield.recipeUnit?.label ?? yield.unit
        }
    }
}

/// The recipe's own optional "Makes" amount, under Servings (owner pick P02a): how much the whole
/// recipe makes, so another recipe can use "1 cup" of it.
struct RecipeMakesField: View {
    @Binding var quantity: Double?
    @Binding var unit: String

    /// Mass and volume units only: a count is what Servings already says.
    private static let units = RecipeUnit.allCases.filter { $0.dimension == .mass || $0.dimension == .volume }.map(\.rawValue)

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Makes (optional)")
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.bark)
                Text("How much the whole recipe makes, so other recipes can use it by the cup or gram.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                HStack(spacing: 10) {
                    TextField("Amount", value: $quantity, format: .number, prompt: .fieldPrompt(verbatim: "2"))
                        .keyboardType(.decimalPad)
                        .textContentType(.none)
                        .sheetTextInput()
                        .frame(maxWidth: 92)
                        .accessibilityIdentifier("recipeEditor.makesAmount")
                    FernletDropdown("Makes unit", selection: $unit, options: Self.units,
                                    showsLabel: false, fullWidth: true) { token in
                        Text(verbatim: RecipeUnit(rawValue: token)?.label ?? token)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Used in Pasta and 2 more. They'll use the new version." on a recipe other recipes use (owner
/// pick P05a), shown while it is edited so the person sees it before saving.
struct RecipeUsedInNote: View {
    let users: [RecipeDefinition]

    var body: some View {
        if let first = users.first {
            FernletNotice(text: text(first: first.name)) {
                WorldSpriteView(sprite: WorldSprites.pen, scale: 2)
            }
            .accessibilityIdentifier("recipeEditor.usedIn")
        }
    }

    private func text(first: String) -> Text {
        let others = users.count - 1
        if others == 0 {
            return Text("Used in \(first). It will use the new version.")
        }
        return Text("Used in \(first) and \(others) more. They'll use the new version.")
    }
}

/// "From your recipes": every saved recipe this recipe may use, with a search field (owner pick P10a).
struct RecipeChoicesSheet: View {
    let choices: [RecipeDefinition]
    let onPick: (RecipeDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [RecipeDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return choices }
        let words = FoodItemSearch.normalized(trimmed).split(separator: " ").map(String.init)
        return choices.filter { recipe in
            let name = FoodItemSearch.normalized(recipe.name).split(separator: " ").map(String.init)
            return words.allSatisfy { word in name.contains { $0.hasPrefix(word) } }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        FernletIcon(.search, scale: 2)
                        TextField("Search your recipes", text: $query, prompt: .fieldPrompt("Search your recipes"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .accessibilityIdentifier("recipeChoices.search")
                    }
                    .sheetTextInput()
                    if choices.isEmpty {
                        Text("No saved recipe can go in this one yet. A recipe can't use itself, a recipe that uses it, or a chain more than three recipes deep.")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    ForEach(shown) { recipe in
                        RecipeChoiceRow(recipe: recipe) {
                            onPick(recipe)
                            dismiss()
                        }
                    }
                }
                .padding(18)
            }
            .background(WorldPalette.paper.ignoresSafeArea())
            .fernletDraftGuard(isDirty: false, title: "From your recipes") { dismiss() }
        }
    }
}

/// The delete confirmation's body for a recipe other recipes use (owner pick P06a): who uses it, and
/// what they keep.
enum RecipeDeleteUsersText {
    static func message(users: [RecipeDefinition]) -> LocalizedStringKey {
        let first = users.first?.name ?? ""
        let others = users.count - 1
        if others <= 0 {
            return "\(first) uses this recipe. It keeps it as a fixed ingredient with today's nutrition, and this recipe's steps are copied into it. Meals you already logged stay in your diary. Fernlet can't undo this."
        }
        return "\(first) and \(others) more use this recipe. They keep it as a fixed ingredient with today's nutrition, and this recipe's steps are copied into them. Meals you already logged stay in your diary. Fernlet can't undo this."
    }
}

/// The recipe book's one-time note after this build turned recipe parts into recipes of their own
/// (owner pick P07a), with its Dismiss.
struct RecipePartsMigratedNote: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FernletNotice("Your recipe parts are now their own recipes. A dressing you made as a part is a recipe of its own, and the recipe that used it lists it as an ingredient, with its steps first.") {
                WorldSpriteView(sprite: WorldSprites.pen, scale: 2)
            }
            Button("Got it", action: onDismiss)
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("recipeBook.partsMigratedDismiss")
        }
        .accessibilityIdentifier("recipeBook.partsMigratedNote")
    }
}

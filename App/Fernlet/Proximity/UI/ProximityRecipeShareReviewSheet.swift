import ProximityKit
import SwiftUI
import FernletDomainModel
import FernletUI

/// The receiving side of a proximity recipe share: review what arrived, then import or decline.
///
/// Presented by ContentView when `ProximityRecipeShareManager` holds a
/// `PendingProximityRecipeShare`. Shows the recipe's kind (local Fernlet recipe vs. saved web
/// recipe), servings/ingredient counts, macros, notes, and the ingredient list, plus a duplicate
/// warning when a same-named (or same-source) recipe already exists — import then becomes
/// "Import anyway". The source-URL duplicate check uses `RecipeSourceURLMatcher`, the SAME
/// normalized match the import path decides with, so the warning fires for exactly the shares the
/// store will treat as already saved (and importing such a share KEEPS the user's existing copy —
/// see `FernletStore.ProximityRecipeImportOutcome.alreadySaved`). Import goes through
/// `FernletStore.importProximityRecipeShare` (which sanitizes and records provenance by sender
/// fingerprint); both outcomes consume the pending share via `dismissRecipeShare`, and an import
/// failure keeps the sheet up with an inline notice.
struct ProximityRecipeShareReviewSheet: View {
    var share: PendingProximityRecipeShare
    var store: FernletStore
    var manager: ProximityRecipeShareManager

    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ScreenHeader(
                            title: share.payload.recipe.title,
                            subtitle: "Shared by \(share.senderDisplayName)",
                            subtitleFirst: false,
                            // A peer-supplied recipe name, so the same three-line allowance the
                            // sending sheet gives its own: truncating what arrived hides the very
                            // thing the user is deciding whether to import.
                            titleLineLimit: 3
                        )

                        summaryCard

                        if let duplicateWarning {
                            Text(duplicateWarning)
                                .font(.fernlet(.bubble))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }

                        sourceHostField

                        notesField

                        ingredientsField

                        stepsField

                        if let notice {
                            Text(notice)
                                .font(.fernlet(.bubble))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 10)
                }

                SheetSaveBar(label: duplicateWarning == nil ? "Import" : "Import anyway") {
                    importShare()
                }
            }
            .background(Color.parchment)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline") {
                        manager.dismissRecipeShare(share)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Kind, servings, ingredient count and macros — the at-a-glance card above the details.
    private var summaryCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(recipeKindLabel, systemImage: recipeKindIcon)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                HStack(spacing: 12) {
                    NutritionPill(title: "Servings", value: "\(share.payload.recipe.servings)")
                    NutritionPill(title: "Ingredients", value: "\(share.payload.recipe.ingredientCount)")
                }
                if let macrosText {
                    Text(macrosText)
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                }
            }
        }
    }

    /// The sender's notes, when the payload carries any.
    @ViewBuilder
    private var notesField: some View {
        if let notesText, !notesText.isEmpty {
            SheetField("Notes") {
                Text(notesText)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
            }
        }
    }

    /// The source page's HOST for a saved (web) recipe, so the user can judge where the share came
    /// from before importing it. Plain text, deliberately NOT tappable: this is a stranger's URL and
    /// the recipe is not imported yet — naming the host informs the decision, opening it doesn't.
    @ViewBuilder
    private var sourceHostField: some View {
        if let sourceHost {
            SheetField("Source") {
                Text(sourceHost)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
            }
        }
    }

    /// The cooking steps exactly as shared (F5) — the sheet previously imported them unseen.
    @ViewBuilder
    private var stepsField: some View {
        if !sharedSteps.isEmpty {
            SheetField("Steps") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(sharedSteps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step.text)")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                }
            }
        }
    }

    /// The ingredient list exactly as shared.
    private var ingredientsField: some View {
        SheetField("Ingredients") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ingredientLines.enumerated()), id: \.offset) { _, line in
                    Text("- \(line)")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                }
            }
        }
    }

    private var recipeKindLabel: String {
        switch share.payload.recipe.kind {
        case .local: "Fernlet recipe"
        case .saved: "Saved web recipe"
        }
    }

    private var recipeKindIcon: String {
        switch share.payload.recipe.kind {
        case .local: "fork.knife"
        case .saved: "doc.text.magnifyingglass"
        }
    }

    private var ingredientLines: [String] {
        switch share.payload.recipe.kind {
        case .local:
            share.payload.recipe.local?.ingredients.map { ingredient in
                "\(String(format: "%g", ingredient.quantity)) \(ingredient.unit) \(ingredient.name)"
            } ?? []
        case .saved:
            share.payload.recipe.saved?.ingredients ?? []
        }
    }

    private var sourceHost: String? {
        guard case .saved = share.payload.recipe.kind,
              let saved = share.payload.recipe.saved,
              let host = URL(string: saved.sourceURLString)?.host() else { return nil }
        return host
    }

    private var sharedSteps: [RecipeStep] {
        switch share.payload.recipe.kind {
        case .local:
            share.payload.recipe.local?.steps ?? []
        case .saved:
            share.payload.recipe.saved?.steps ?? []
        }
    }

    private var notesText: String? {
        switch share.payload.recipe.kind {
        case .local:
            share.payload.recipe.local?.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        case .saved:
            share.payload.recipe.saved?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var macrosText: String? {
        switch share.payload.recipe.kind {
        case .local:
            guard let ingredients = share.payload.recipe.local?.ingredients else { return nil }
            let protein = Self.boundedMacroSum(ingredients, \.protein)
            let carbs = Self.boundedMacroSum(ingredients, \.carbs)
            let fat = Self.boundedMacroSum(ingredients, \.fat)
            guard protein > 0 || carbs > 0 || fat > 0 else { return nil }
            return "Macros: P \(protein)g · C \(carbs)g · F \(fat)g"
        case .saved:
            guard let saved = share.payload.recipe.saved else { return nil }
            let protein = Self.boundedMacro(saved.protein)
            let carbs = Self.boundedMacro(saved.carbs)
            let fat = Self.boundedMacro(saved.fat)
            guard protein > 0 || carbs > 0 || fat > 0 else { return nil }
            return "Macros: P \(protein)g · C \(carbs)g · F \(fat)g"
        }
    }

    /// Sums a peer's per-ingredient macros without trusting them: every term is clamped into
    /// `[0, SharedRecipeLimits.maxMacroGrams]` and the list to `maxIngredients`, so the worst case
    /// (100 * 10_000) cannot overflow the trapping `+` while this sheet is rendering.
    ///
    /// The sheet deliberately does NOT lean on the wire decoder's bounds: a payload can also be
    /// built in-process (tests, the send-side preview), and this view renders before import.
    static func boundedMacroSum(_ ingredients: [SharedRecipeIngredient],
                                _ macro: (SharedRecipeIngredient) -> Int) -> Int {
        ingredients.prefix(SharedRecipeLimits.maxIngredients)
            .reduce(0) { $0 + boundedMacro(macro($1)) }
    }

    /// One displayed macro, clamped the same way ``boundedMacroSum(_:_:)`` clamps its terms.
    static func boundedMacro(_ value: Int) -> Int {
        min(max(value, 0), SharedRecipeLimits.maxMacroGrams)
    }

    private var duplicateWarning: String? {
        let title = share.payload.recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch share.payload.recipe.kind {
        case .local:
            guard store.recipes.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title }) else { return nil }
            return "You already have a recipe with this name."
        case .saved:
            guard let saved = share.payload.recipe.saved else { return nil }
            // NORMALIZED source match — must agree with the store's duplicate decision, or a URL
            // differing only in host case or a #fragment would dodge this warning while the import
            // still treats it as already saved.
            if store.savedRecipes.contains(where: {
                RecipeSourceURLMatcher.urlsMatch($0.webImport?.sourceURLString ?? "", saved.sourceURLString)
            }) {
                return "You already saved this recipe from the same page — importing keeps your saved copy, photo, and notes."
            }
            if store.savedRecipes.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title }) {
                return "You already have a saved recipe with this name."
            }
            return nil
        }
    }

    private func importShare() {
        do {
            let outcome = try store.importProximityRecipeShare(share.payload, fromFingerprint: share.senderFingerprint)
            manager.dismissRecipeShare(share)
            switch outcome {
            case .imported(let name):
                notice = "\(name) imported."
            case .alreadySaved(let name):
                notice = "\(name) is already in your recipe book — your saved copy was kept."
            }
            dismiss()
        } catch let error as RecipeImportError {
            notice = error.message
        } catch {
            notice = RecipeImportError.invalidPayload.message
        }
    }
}

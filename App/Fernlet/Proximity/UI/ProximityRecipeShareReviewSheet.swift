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
                            subtitleFirst: false
                        )

                        summaryCard

                        if let duplicateWarning {
                            Text(duplicateWarning)
                                .font(.fernlet(.bubble))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }

                        notesField

                        ingredientsField

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
            let protein = ingredients.reduce(0) { $0 + $1.protein }
            let carbs = ingredients.reduce(0) { $0 + $1.carbs }
            let fat = ingredients.reduce(0) { $0 + $1.fat }
            guard protein > 0 || carbs > 0 || fat > 0 else { return nil }
            return "Macros: P \(protein)g · C \(carbs)g · F \(fat)g"
        case .saved:
            guard let saved = share.payload.recipe.saved,
                  saved.protein > 0 || saved.carbs > 0 || saved.fat > 0 else { return nil }
            return "Macros: P \(saved.protein)g · C \(saved.carbs)g · F \(saved.fat)g"
        }
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

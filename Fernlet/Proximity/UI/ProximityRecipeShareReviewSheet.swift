import ProximityKit
import SwiftUI
import FernletDomainModel

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

                        FernletCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(recipeKindLabel, systemImage: recipeKindIcon)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.moss)
                                HStack(spacing: 12) {
                                    NutritionPill(title: "Servings", value: "\(share.payload.recipe.servings)")
                                    NutritionPill(title: "Ingredients", value: "\(share.payload.recipe.ingredientCount)")
                                }
                                if let macrosText {
                                    Text(macrosText)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.slate)
                                }
                            }
                        }

                        if let duplicateWarning {
                            Text(duplicateWarning)
                                .font(.caption.italic())
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }

                        if let notesText, !notesText.isEmpty {
                            SheetField("Notes") {
                                Text(notesText)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.bark)
                                    .fernletWrappingText()
                            }
                        }

                        SheetField("Ingredients") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(ingredientLines.enumerated()), id: \.offset) { _, line in
                                    Text("- \(line)")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.bark)
                                        .fernletWrappingText()
                                }
                            }
                        }

                        if let notice {
                            Text(notice)
                                .font(.caption.italic())
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
            if store.savedRecipes.contains(where: { $0.webImport?.sourceURLString == saved.sourceURLString }) {
                return "You already saved this source recipe."
            }
            if store.savedRecipes.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title }) {
                return "You already have a saved recipe with this name."
            }
            return nil
        }
    }

    private func importShare() {
        do {
            let importedName = try store.importProximityRecipeShare(share.payload)
            manager.dismissRecipeShare(share)
            notice = "\(importedName) imported."
            dismiss()
        } catch let error as RecipeImportError {
            notice = error.message
        } catch {
            notice = RecipeImportError.invalidPayload.message
        }
    }
}

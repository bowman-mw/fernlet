#if canImport(UIKit)
import SwiftUI
import FernletDomainModel
import FernletUI
import AIContext
import FoodCatalog

/// F4 ingredient substitution (decision §11.4). Lets the cook replace ONE structured ingredient in a
/// recipe. The model (on-device, standard tier, user-invoked, through `FernletAIGate`) proposes
/// replacements BY CANDIDATE NUMBER from a local catalog pool; code binds them and computes the new
/// quantity by gram-equivalence — the model never emits a quantity or a macro. Applying a swap FORKS a
/// new recipe (`parentRecipeID = source.id`) only on the explicit "Save as new recipe" tap from the
/// preview; cancelling forks nothing and the source recipe is never mutated.
///
/// The manual catalog-search list is ALWAYS present (seeded with the ingredient's name) — it is the
/// deterministic fallback when AI is off/resting/incapable, and a manual override when AI is on. The AI
/// "Suggestions" section appears above it only when the model actually ran and returned bindings.
struct IngredientSubstitutionSheet: View {
    let store: FernletStore
    let recipe: RecipeDefinition
    /// The stored base ingredient being replaced.
    let original: RecipeIngredient
    /// The food `original` resolves to, if the catalog could resolve it — needed to gram-match the
    /// replacement amount. `nil` degrades gracefully to the substitute's natural default quantity.
    let originalFoodItem: FoodItem?
    let onSaveFork: (RecipeDefinition) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var didSeed = false
    @State private var aiSuggestions: [IngredientSubstitutionSuggestion] = []
    @State private var isLoadingAI = true
    @State private var searchResults: [FoodSelectionCandidate] = []
    /// Non-nil once the cook has chosen a substitute — switches the sheet from picker to preview.
    @State private var pending: PendingFork?
    /// Guards the save button against a double-tap firing `onSaveFork` twice before the sheet tears down.
    @State private var didSave = false

    private var originalName: String { originalFoodItem?.name ?? "this ingredient" }

    var body: some View {
        NavigationStack {
            Group {
                if let pending {
                    previewBody(pending)
                } else {
                    pickerBody
                }
            }
            .background(Color.parchment)
            .navigationTitle(pending == nil ? "Swap ingredient" : "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("substitution.cancel")
                }
            }
        }
        .task {
            // Seed the search list from the ingredient's own name, once, then ask AI for world-knowledge
            // swaps. When the original ingredient can't be resolved to a catalog food, there is nothing to
            // gram-match or to name to the model: seed the list empty (the cook types a real food) and skip
            // the AI call entirely so no phantom "this ingredient" query runs and no quota is charged.
            guard !didSeed else { return }
            didSeed = true
            guard let originalFoodItem else {
                searchText = ""
                searchResults = []
                isLoadingAI = false
                return
            }
            searchText = originalFoodItem.name
            searchResults = store.substitutionCandidates(forIngredientNamed: originalFoodItem.name)
            let ai = await store.aiSubstitutionSuggestions(
                recipeName: recipe.name,
                ingredientName: originalFoodItem.name
            )
            aiSuggestions = ai ?? []
            isLoadingAI = false
        }
        .task(id: searchText) {
            // Live manual search — the deterministic path, always available. Skip the initial empty tick
            // before seeding runs. Debounced + run off the main actor: `FoodCatalog` FTS is a synchronous
            // SQLite query (base + branded ODR sources) and the catalog is thread-safe, so keep keystroke
            // bursts and the query off the render thread (mirrors the debounced food typeahead).
            guard didSeed else { return }
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { searchResults = []; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let catalog = store.foodCatalog
            let results = await Task.detached(priority: .userInitiated) {
                catalog.candidates(for: trimmed, limit: 12)
            }.value
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    // MARK: - Picker

    private var pickerBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Replace \(originalName) in \(recipe.name).")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                if isLoadingAI {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Thinking of swaps…")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                    }
                } else if !aiSuggestions.isEmpty {
                    FernletCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Suggestions")
                            ForEach(Array(aiSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                                if index > 0 { FernletRowDivider() }
                                substituteRow(suggestion.foodItem, reason: suggestion.reason)
                            }
                        }
                    }
                }

                FernletCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Search foods")
                        TextField("Search for a replacement", text: $searchText)
                            .sheetTextInput()
                            .accessibilityIdentifier("substitution.search")
                        if searchResults.isEmpty {
                            Text("Type to find a replacement food.")
                                .font(.fernlet(.bodySmall))
                                .foregroundStyle(Color.slate)
                        } else {
                            ForEach(Array(searchResults.enumerated()), id: \.element.foodItem.id) { index, candidate in
                                if index > 0 { FernletRowDivider() }
                                substituteRow(candidate.foodItem, reason: nil)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func substituteRow(_ foodItem: FoodItem, reason: String?) -> some View {
        Button {
            selectSubstitute(foodItem)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(foodItem.name)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("substitution.candidate")
    }

    // MARK: - Preview

    private func previewBody(_ pending: PendingFork) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FernletCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Swap")
                        changeLine(label: "Was", text: original.lineDescription(name: originalName))
                        changeLine(label: "Now", text: pending.newIngredient.lineDescription(name: pending.substitute.name))
                    }
                }
                FernletCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Whole recipe")
                        macroCompareRow(before: pending.beforeTotals, after: pending.afterTotals)
                    }
                }
                Text("Saving creates a NEW recipe — \(RecipeSubstitution.forkedName(from: recipe.name)) — and leaves \(recipe.name) exactly as it is.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                Button {
                    guard !didSave else { return }
                    didSave = true
                    onSaveFork(pending.fork)
                    dismiss()
                } label: {
                    Label("Save as new recipe", systemImage: "plus.circle")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.cream)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("substitution.save")

                Button("Choose a different swap") { self.pending = nil }
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("substitution.back")
            }
            .padding(20)
        }
    }

    private func changeLine(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .frame(width: 40, alignment: .leading)
            Text(text)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
    }

    private func macroCompareRow(before: MacroTotals, after: MacroTotals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("P \(before.protein)g → \(after.protein)g · C \(before.carbs)g → \(after.carbs)g · F \(before.fat)g → \(after.fat)g")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if store.settings.showCalories {
                Text("\(before.calories) → \(after.calories) cal")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
            }
        }
    }

    // MARK: - Selection

    private func selectSubstitute(_ substitute: FoodItem) {
        // Quantity is gram-matched in code (never from the model); the fork is a pure value transform.
        let newIngredient = RecipeSubstitution.substitutedIngredient(
            replacing: original,
            originalFoodItem: originalFoodItem,
            with: substitute
        )
        guard let fork = RecipeSubstitution.fork(
            source: recipe,
            replacing: original.id,
            with: newIngredient,
            now: Date()
        ) else { return }
        // Macros recomputed in code on both sides via MealBuilder (store.macroTotals), from the bound
        // foodItemIds — the substitute is a resolved catalog food, so the fork resolves cleanly.
        pending = PendingFork(
            substitute: substitute,
            newIngredient: newIngredient,
            fork: fork,
            beforeTotals: store.macroTotals(for: recipe),
            afterTotals: store.macroTotals(for: fork)
        )
    }

    struct PendingFork {
        let substitute: FoodItem
        let newIngredient: RecipeIngredient
        let fork: RecipeDefinition
        let beforeTotals: MacroTotals
        let afterTotals: MacroTotals
    }
}

private extension RecipeIngredient {
    func lineDescription(name: String) -> String {
        let qty = quantity.formatted(.number.precision(.fractionLength(0...1)))
        return "\(qty) \(unit) · \(name)"
    }
}
#endif

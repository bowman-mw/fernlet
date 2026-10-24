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
    /// The words `searchResults` answer — the seed, or the search text once its results settled. A pick
    /// teaches search against these (F9b), never against a newer keystroke the list does not show yet.
    @State private var searchedText = ""
    /// Non-nil once the cook has chosen a substitute — switches the sheet from picker to preview.
    @State private var pending: PendingFork?
    /// Guards the save button against a double-tap firing `onSaveFork` twice before the sheet tears down.
    @State private var didSave = false

    /// The swapped-out food's name for the preview's "Was" line, or a localized stand-in while it is
    /// unresolved. The picker's sentence does not splice this in: it has a whole sentence per case.
    private var originalName: String {
        originalFoodItem?.name ?? String(localized: "recipe.substitution.unresolvedOriginal", defaultValue: "this ingredient",
                                         comment: "Stands in for the name of a recipe ingredient being swapped when its food can't be found, on the swap preview's 'Was' line.")
    }

    /// The picker's opening sentence, naming the ingredient when its food is known.
    private var replaceSentence: Text {
        guard let name = originalFoodItem?.name else { return Text("Replace this ingredient in \(recipe.name).") }
        return Text("Replace \(name) in \(recipe.name).")
    }

    /// World build (`b3-ingredient-swap`, approved 2026-10-24): the sheet frame with Cancel top left and
    /// the title inside the sheet, "Replace … in …", the Suggestions card, then Search foods; rows carry
    /// a framed source tag and a framed +. The preview keeps Was / Now, the whole recipe before → after
    /// and Save as new recipe.
    var body: some View {
        NavigationStack {
            Group {
                if let pending {
                    previewBody(pending)
                } else {
                    pickerBody
                }
            }
            .background(WorldPalette.paper)
            .fernletSheetToolbar(title: pending == nil ? Text("Swap ingredient") : Text("Preview"),
                                 onCancel: { dismiss() })
            // The search field's keyboard "Done", on the stack's root page: one declared on the
            // stack itself would reach no page in it.
            .keyboardDoneToolbar()
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
                searchedText = ""
                isLoadingAI = false
                return
            }
            searchText = originalFoodItem.name
            searchResults = store.substitutionCandidates(forIngredientNamed: originalFoodItem.name)
            searchedText = originalFoodItem.name
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
            guard !trimmed.isEmpty else {
                searchResults = []
                searchedText = ""
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // Superseded by a newer keystroke (or the sheet went away): the replacement task
                // owns the query from here, so this one must not write stale results.
                return
            }
            let catalog = store.foodCatalog
            // A replacement for a recipe ingredient: the ingredient itself first (F5).
            let results = await Task.detached(priority: .userInitiated) {
                catalog.candidates(for: trimmed, limit: 12, ranking: .ingredientIdentity)
            }.value
            guard !Task.isCancelled else { return }
            searchResults = results
            searchedText = trimmed
        }
    }

    // MARK: - Picker

    private var pickerBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                replaceSentence
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()

                if isLoadingAI {
                    HStack(spacing: 8) {
                        // The sentence beside it is the label; the clock is decoration.
                        WorldSpriteView(sprite: WorldSprites.clock, scale: 2)
                        Text("Thinking of swaps…")
                            .font(FernletFramedFont.note)
                            .foregroundStyle(WorldPalette.dim)
                    }
                } else if !aiSuggestions.isEmpty {
                    FernletCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Suggestions")
                            ForEach(aiSuggestions) { suggestion in
                                FernletDottedRule()
                                substituteRow(suggestion.foodItem, reason: suggestion.reason, searchList: nil)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                searchCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
    }

    /// Search foods: the field with its pixel magnifier, then the matches, each on a dotted rule.
    private var searchCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Search foods")
                HStack(spacing: 9) {
                    FernletIcon(.search, scale: 2)
                    TextField("Search for a replacement", text: $searchText, prompt: .fieldPrompt("Search for a replacement"))
                        .accessibilityIdentifier("substitution.search")
                }
                .sheetTextInput()
                if visibleSearchResults.isEmpty {
                    Text("Type to find a replacement food.")
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                } else {
                    let shown = visibleSearchResults
                    ForEach(shown) { foodItem in
                        FernletDottedRule()
                        substituteRow(foodItem, reason: nil, searchList: shown)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The search list with same-name/same-source repeats collapsed.
    ///
    /// The catalog holds "Rolled oats", "Rolled Oats" and "Rolled Oats" from the same source; as bare
    /// name-only rows they were three identical, unchoosable lines.
    private var visibleSearchResults: [FoodItem] {
        var seen = Set<String>()
        return searchResults.compactMap { candidate -> FoodItem? in
            let item = candidate.foodItem
            let key = "\(item.name.lowercased())|\(item.dataSourceLabel)"
            return seen.insert(key).inserted ? item : nil
        }
    }

    /// One replacement candidate, rendered the way the recipe editor's typeahead renders the SAME
    /// catalog: name, provenance badge, and the reference serving with its macros. A name alone left
    /// the cook no way to tell two similar hits apart — or to spot an unrelated one.
    ///
    /// `searchList` is the manual search list the row sits in (its rows, in order), or nil for an AI
    /// suggestion — which answers no words the person typed, so its pick teaches nothing (F9b).
    private func substituteRow(_ foodItem: FoodItem, reason: String?, searchList: [FoodItem]?) -> some View {
        Button {
            selectSubstitute(foodItem, searchList: searchList)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(foodItem.name)
                        .font(FernletFramedFont.rowTitle.weight(.semibold))
                        .foregroundStyle(WorldPalette.bark)
                        .fernletWrappingText()
                    HStack(spacing: 6) {
                        FernletTag(text: Text(verbatim: foodItem.dataSourceLabel))
                        Text("\(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit) · P\(foodItem.macros.protein)g C\(foodItem.macros.carbs)g F\(foodItem.macros.fat)g")
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(WorldPalette.dim)
                            .fernletWrappingText()
                    }
                    if let reason, !reason.isEmpty {
                        Text(reason)
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(WorldPalette.dim)
                            .fernletWrappingText()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RecipeSpriteTile(sprite: WorldSprites.plus, size: 32)
            }
            .padding(.vertical, 6)
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
                    // F9b: a replacement picked lower in the search list for words the person typed is
                    // remembered for the recipe searches — at this save, so a cancelled swap teaches nothing.
                    store.rememberFoodSearchCorrections(pending.searchPick.map { [$0] } ?? [])
                    dismiss()
                } label: {
                    Text("Save as new recipe").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("substitution.save")

                Button("Choose a different swap") { self.pending = nil }
                    .buttonStyle(.plain)
                    .font(FernletFramedFont.sheetControl)
                    .foregroundStyle(WorldPalette.mossInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("substitution.back")
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
    }

    /// One "Was" / "Now" line: the localized caption, then the ingredient line as data.
    private func changeLine(label: LocalizedStringKey, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(FernletFramedFont.rowDetail.weight(.bold))
                .foregroundStyle(WorldPalette.dim)
                .frame(minWidth: 40, alignment: .leading)
            Text(text)
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
        }
    }

    private func macroCompareRow(before: MacroTotals, after: MacroTotals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("P \(before.protein)g → \(after.protein)g · C \(before.carbs)g → \(after.carbs)g · F \(before.fat)g → \(after.fat)g")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
            if store.settings.showCalories {
                Text("\(before.calories) → \(after.calories) cal")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
            }
        }
    }

    // MARK: - Selection

    private func selectSubstitute(_ substitute: FoodItem, searchList: [FoodItem]?) {
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
            afterTotals: store.macroTotals(for: fork),
            searchPick: searchPick(of: substitute, in: searchList)
        )
    }

    /// What choosing `substitute` from the manual search list would teach the recipe searches (F9b,
    /// ``RecipeSearchPick``): nil for an AI suggestion, the list's first row, the seeded search or a
    /// search for the ingredient being replaced, a row that does not say the words searched for while
    /// another row does (a stand-in from the list's "coconut" or "oil" block for "coconut oil"), or a
    /// word still being typed.
    private func searchPick(of substitute: FoodItem, in searchList: [FoodItem]?) -> FoodSearchCorrection? {
        guard let searchList,
              let query = RecipeSearchPick.query(
                  typed: searchedText, picked: substitute, shown: searchList, seededWith: originalFoodItem?.name
              ) else { return nil }
        return FoodSearchCorrection(searchText: query, foodItemID: substitute.id, origin: .recipePick)
    }

    /// Everything the preview screen needs for one chosen swap: the substitute food, the
    /// gram-matched replacement ingredient, the fully built fork, and before/after whole-recipe
    /// totals.
    ///
    /// Built by `selectSubstitute` as a pure value transform — nothing is persisted until the
    /// explicit "Save as new recipe" tap hands `fork` to `onSaveFork`.
    private struct PendingFork {
        let substitute: FoodItem
        let newIngredient: RecipeIngredient
        let fork: RecipeDefinition
        let beforeTotals: MacroTotals
        let afterTotals: MacroTotals
        /// The recipe pick this swap teaches when saved (F9b), or nil.
        let searchPick: FoodSearchCorrection?
    }
}

private extension RecipeIngredient {
    /// "50 g · Margarine", or "0.65 medium (118 g) · Apples, raw" for a household choice saved as
    /// grams (F4a, fix round 1).
    func lineDescription(name: String) -> String {
        "\(amountText) · \(name)"
    }
}
#endif

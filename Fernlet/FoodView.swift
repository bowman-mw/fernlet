import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct FoodView: View {
    @ObservedObject var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @State private var retryNotice: String?
    @State private var editingRecipe: RecipeDefinition?
    @State private var editingSavedRecipe: SavedRecipe?
    @State private var showingRecipeBook = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Food", subtitle: "Eating enough, eating well.")
                        Spacer()
                        HeaderActionButton(title: "meal", systemImage: "plus") { activeSheet = .meal }
                    }
                    .padding(.top, 4)

                    MacroCard(totals: store.macroTotals, targets: store.nutritionTargets, showCalories: store.settings.showCalories)

                    if store.pendingRetryCount > 0 {
                        FernletScrollSection {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("\(store.pendingRetryCount) pending", systemImage: "clock.arrow.circlepath")
                                        .font(.headline)
                                        .foregroundStyle(Color.bark)
                                    Spacer()
                                }
                                Text(FernletVoice.message(for: .retryAvailable))
                                    .font(.callout.italic())
                                    .foregroundStyle(Color.slate)
                                Button("Retry oldest") {
                                    if let oldest = store.retryQueue.first {
                                        store.clearRetryItem(oldest.id)
                                        retryNotice = FernletVoice.message(for: .mealAnalysisFailed)
                                    }
                                }
                                .buttonStyle(.bordered)
                                if let retryNotice {
                                    Text(retryNotice)
                                        .font(.caption.italic())
                                        .foregroundStyle(Color.slate)
                                }
                            }
                        }
                    }

                    FernletScrollSection("Today") {
                        if store.day.meals.isEmpty {
                            EmptyState(text: "Nothing yet. Describe a meal when you are ready.")
                        } else {
                            ForEach(Array(store.day.meals.enumerated()), id: \.element.id) { index, meal in
                                MealRow(meal: meal, showCalories: store.settings.showCalories) { store.deleteMeal(meal) }
                                if index < store.day.meals.count - 1 {
                                    FernletRowDivider()
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel("Recipes")
                            Spacer()
                            Button("Recipe book") { showingRecipeBook = true }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.fern)
                        }
                        if recentRecipePreviews.isEmpty {
                            FernletCard {
                                EmptyState(text: "No recipes yet. Open the recipe book to create one.")
                            }
                        } else {
                            FernletCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(recentRecipePreviews.enumerated()), id: \.element.id) { index, preview in
                                        if index > 0 { FernletRowDivider() }
                                        switch preview {
                                        case .local(let recipe):
                                            HStack(spacing: 12) {
                                                Button { editingRecipe = recipe } label: {
                                                    RecipeRow(recipe: recipe, totals: store.macroTotals(for: recipe), showCalories: store.settings.showCalories)
                                                }
                                                .buttonStyle(.plain)
                                                RecipeMealTypeMenu { mealType in
                                                    store.logRecipe(recipe, mealType: mealType)
                                                }
                                                ShareLink(item: store.recipeShareText(for: recipe)) {
                                                    Image(systemName: "square.and.arrow.up")
                                                        .font(.body.weight(.semibold))
                                                        .foregroundStyle(Color.moss)
                                                        .frame(width: 36, height: 36)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        case .saved(let recipe):
                                            HStack(spacing: 12) {
                                                Button { editingSavedRecipe = recipe } label: {
                                                    SavedRecipeRow(recipe: recipe)
                                                }
                                                .buttonStyle(.plain)
                                                RecipeMealTypeMenu { mealType in
                                                    store.logSavedRecipe(recipe, mealType: mealType)
                                                }
                                                ShareLink(item: store.savedRecipeShareText(for: recipe)) {
                                                    Image(systemName: "square.and.arrow.up")
                                                        .font(.body.weight(.semibold))
                                                        .foregroundStyle(Color.moss)
                                                        .frame(width: 36, height: 36)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(Color.parchment)
            .navigationTitle("")
        }
        .sheet(item: $editingRecipe) { recipe in
            RecipeSheet(store: store, recipe: recipe)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .sheet(item: $editingSavedRecipe) { recipe in
            SavedRecipeNotesSheet(store: store, recipe: recipe)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .sheet(isPresented: $showingRecipeBook) {
            RecipeBookSheet(store: store, editingRecipe: $editingRecipe, editingSavedRecipe: $editingSavedRecipe)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .onAppear {
            store.markLaunchScreenDismissed()
            store.ensureBundledFoodItemsSeeded()
        }
    }

    private var recentRecipePreviews: [RecentRecipePreview] {
        let localPreviews = store.recipes.map(RecentRecipePreview.local)
        let savedPreviews = store.savedRecipes.map(RecentRecipePreview.saved)
        return Array((localPreviews + savedPreviews).sorted { $0.addedAt > $1.addedAt }.prefix(5))
    }
}

private enum RecentRecipePreview: Identifiable {
    case local(RecipeDefinition)
    case saved(SavedRecipe)

    var id: String {
        switch self {
        case .local(let recipe):
            "local-\(recipe.id.uuidString)"
        case .saved(let recipe):
            "saved-\(recipe.id.uuidString)"
        }
    }

    var addedAt: Date {
        switch self {
        case .local(let recipe):
            recipe.createdAt
        case .saved(let recipe):
            recipe.savedAt
        }
    }
}

struct NutritionPill: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.slate)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.bark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MicronutrientSummaryView: View {
    var micronutrients: Micronutrients

    private var rows: [(String, String)] {
        [
            nutrientRow("Fiber", micronutrients.fiber, "g"),
            nutrientRow("Vitamin C", micronutrients.vitaminC, "mg"),
            nutrientRow("Calcium", micronutrients.calcium, "mg"),
            nutrientRow("Iron", micronutrients.iron, "mg"),
            nutrientRow("Magnesium", micronutrients.magnesium, "mg"),
            nutrientRow("Potassium", micronutrients.potassium, "mg"),
            nutrientRow("Sodium", micronutrients.sodium, "mg"),
            nutrientRow("Zinc", micronutrients.zinc, "mg")
        ].compactMap { $0 }
    }

    var body: some View {
        if rows.isEmpty {
            EmptyState(text: "No micronutrient details yet.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                ForEach(rows, id: \.0) { name, value in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                        Text(value)
                            .font(.headline)
                            .foregroundStyle(Color.bark)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func nutrientRow(_ name: String, _ value: Double?, _ unit: String) -> (String, String)? {
        guard let value else { return nil }
        let formatted = value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return (name, "\(formatted) \(unit)")
    }
}

struct RecipeImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FernletStore
    @State private var importText = ""
    @State private var notice: String?
    @State private var isImportingURL = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Import recipe")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    Button {
                        importFromPasteboardURL()
                    } label: {
                        Label(isImportingURL ? "Importing URL" : "Paste URL", systemImage: isImportingURL ? "hourglass" : "link.badge.plus")
                            .font(.headline)
                            .foregroundStyle(Color.cream)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(isImportingURL)

                    SheetField("Shared recipe text") {
                        SheetTextEditor(
                            text: $importText,
                            placeholder: "Paste a Fernlet recipe share here",
                            minHeight: 180
                        )
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

            SheetSaveBar(label: "Import", disabled: importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                do {
                    try store.importRecipe(from: importText)
                    dismiss()
                } catch let error as RecipeImportError {
                    notice = error.message
                } catch {
                    notice = RecipeImportError.invalidPayload.message
                }
            }
        }
        .background(Color.parchment)
    }

    private func importFromPasteboardURL() {
        #if canImport(UIKit)
        let pastedString = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: pastedString), url.scheme == "http" || url.scheme == "https" else {
            notice = RecipeWebImportError.invalidURL.localizedDescription
            return
        }

        isImportingURL = true
        notice = "Fetching recipe..."

        Task {
            do {
                let importedRecipe = try await RecipeWebImporter.importRecipe(from: url, foodItems: store.foodItems)
                store.addSavedRecipe(SavedRecipe(
                    sourceURL: importedRecipe.sourceURL,
                    name: importedRecipe.name,
                    ingredients: importedRecipe.ingredients,
                    summary: importedRecipe.summary,
                    servings: importedRecipe.servings,
                    protein: importedRecipe.protein,
                    carbs: importedRecipe.carbs,
                    fat: importedRecipe.fat,
                    micronutrients: importedRecipe.micronutrients
                ))
                notice = "\(importedRecipe.name) added to your recipes."
                isImportingURL = false
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "Could not import that recipe."
                isImportingURL = false
            }
        }
        #else
        notice = "Pasteboard recipe import is available on iOS."
        #endif
    }
}

struct SavedRecipeRow: View {
    var recipe: SavedRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.name)
                        .font(.headline)
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    Text(recipe.sourceURL.host() ?? recipe.sourceURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(Color.slate)
                        .lineLimit(1)
                }
            }
            Text(recipe.summary)
                .font(.callout)
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Text(recipe.ingredients.prefix(4).joined(separator: " | "))
                .font(.caption)
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if recipe.protein > 0 || recipe.carbs > 0 || recipe.fat > 0 {
                HStack(spacing: 14) {
                    Text("P \(recipe.protein)g").foregroundStyle(Color.moss)
                    Text("C \(recipe.carbs)g")
                    Text("F \(recipe.fat)g")
                    if recipe.servings > 1 {
                        Text("· \(recipe.servings) servings")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.slate)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saved recipe \(recipe.name)")
    }
}

struct SavedRecipeNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FernletStore
    @State private var recipe: SavedRecipe
    @State private var showingSafari = false

    init(store: FernletStore, recipe: SavedRecipe) {
        self.store = store
        _recipe = State(initialValue: recipe)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recipe.name)
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        Button {
                            showingSafari = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                    .font(.caption)
                                Text(recipe.sourceURL.host() ?? recipe.sourceURL.absoluteString)
                                    .font(.caption)
                                    .underline()
                            }
                            .foregroundStyle(Color.fern)
                        }
                        .buttonStyle(.plain)
                    }

                    if recipe.protein > 0 || recipe.carbs > 0 || recipe.fat > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(recipe.servings > 1 ? "PER SERVING" : "MACROS")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.slate)
                                .tracking(0.8)
                            HStack(spacing: 14) {
                                Text("P \(recipe.protein)g").foregroundStyle(Color.moss)
                                Text("C \(recipe.carbs)g")
                                Text("F \(recipe.fat)g")
                                Spacer()
                                if recipe.servings > 1 {
                                    Text("\(recipe.servings) servings")
                                        .font(.caption)
                                        .foregroundStyle(Color.slate)
                                }
                            }
                            .font(.headline)
                            .foregroundStyle(Color.bark)
                        }
                        .padding(14)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    }

                    SheetField("Notes") {
                        SheetTextEditor(text: $recipe.summary, placeholder: "cooking notes, substitutions, tips", minHeight: 120)
                    }

                    if !recipe.ingredients.isEmpty {
                        SheetField("Ingredients") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(recipe.ingredients, id: \.self) { ingredient in
                                    Text("• \(ingredient)")
                                        .font(.callout)
                                        .foregroundStyle(Color.bark)
                                }
                            }
                            .padding(14)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                        }
                    }

                    Button(role: .destructive) {
                        store.deleteSavedRecipe(recipe)
                        dismiss()
                    } label: {
                        Label("Delete recipe", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(14)
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }
            SheetSaveBar(label: "Done") {
                store.updateSavedRecipe(recipe)
                dismiss()
            }
        }
        .background(Color.parchment)
        .sheet(isPresented: $showingSafari) {
            SafariView(url: recipe.sourceURL)
                .ignoresSafeArea()
        }
    }
}

enum MealFlowDestination: Hashable {
    case scanLabel
    case reviewScan(NutritionLabelResult)
    case recipeSearch
}

struct RecipeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FernletStore
    private var editingRecipe: RecipeDefinition?
    private var isEmbeddedInNavigationStack: Bool
    private var startsWithScanner: Bool
    @State private var name = ""
    @State private var servings = 1
    @State private var notes = ""
    @State private var ingredients: [ManualRecipeIngredientInput] = []
    @State private var expandedId: UUID?
    @State private var foodSearchIndex = FoodItemSearch.Index.empty
    @State private var scannerPath = false
    @State private var didStartScanner = false

    init(store: FernletStore, recipe: RecipeDefinition? = nil, isEmbeddedInNavigationStack: Bool = false, startsWithScanner: Bool = false) {
        self.store = store
        self.editingRecipe = recipe
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
        self.startsWithScanner = startsWithScanner
        if let recipe {
            let loadedIngredients = Self.inputs(for: recipe, foodItems: store.foodItems)
            _name = State(initialValue: recipe.name)
            _servings = State(initialValue: recipe.servings)
            _notes = State(initialValue: recipe.notes)
            _ingredients = State(initialValue: loadedIngredients)
            _expandedId = State(initialValue: loadedIngredients.first?.id)
        } else {
            let first = ManualRecipeIngredientInput()
            _ingredients = State(initialValue: [first])
            _expandedId = State(initialValue: first.id)
        }
    }

    @ViewBuilder
    var body: some View {
        if isEmbeddedInNavigationStack {
            recipeContent
        } else {
            NavigationStack {
                recipeContent
            }
        }
    }

    private var recipeContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(editingRecipe == nil ? "New recipe" : "Edit recipe")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    SheetField("Recipe name") {
                        TextField("black bean bowls", text: $name)
                            .sheetTextInput()
                    }

                    SheetField("Notes") {
                        SheetTextEditor(text: $notes, placeholder: "prep notes, substitutions, storage", minHeight: 82)
                    }

                    SheetField("Ingredients") {
                        VStack(spacing: 8) {
                            ForEach(ingredients.indices, id: \.self) { index in
                                let ingredient = ingredients[index]
                                if expandedId == ingredient.id || ingredient.trimmedName.isEmpty {
                                    RecipeIngredientEditor(
                                        ingredient: $ingredients[index],
                                        foodItems: store.foodItems,
                                        foodSearchIndex: foodSearchIndex,
                                        onSaveCustomIngredient: { store.saveCustomIngredient($0) },
                                        onCollapse: ingredient.trimmedName.isEmpty ? nil : { expandedId = nil },
                                        onRemove: { removeIngredient(ingredient.id) }
                                    )
                                    .padding(14)
                                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                                } else {
                                    CollapsedIngredientRow(
                                        ingredient: ingredient,
                                        foodItems: store.foodItems,
                                        onExpand: { expandedId = ingredient.id },
                                        onRemove: { removeIngredient(ingredient.id) }
                                    )
                                }
                            }
                            Button {
                                let new = ManualRecipeIngredientInput()
                                ingredients.append(new)
                                expandedId = new.id
                            } label: {
                                Label("Add ingredient", systemImage: "plus")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.moss)
                                    .frame(maxWidth: .infinity)
                                    .padding(12)
                                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("PER SERVING")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .tracking(0.8)
                        HStack {
                            Text("P \(perServingTotals.protein)g · C \(perServingTotals.carbs)g · F \(perServingTotals.fat)g")
                                .font(.headline)
                                .foregroundStyle(Color.bark)
                            Spacer()
                            Text("\(perServingTotals.calories) cal")
                                .font(.caption)
                                .foregroundStyle(Color.slate)
                        }
                        .padding(14)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    }

                    SheetField("Servings") {
                        Stepper("\(servings)", value: $servings, in: 1...24)
                            .padding(14)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    }

                    if let editingRecipe {
                        Button(role: .destructive) {
                            store.deleteRecipe(editingRecipe)
                            dismiss()
                        } label: {
                            Label("Delete recipe", systemImage: "trash")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(14)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(disabled: !canSave) {
                if let editingRecipe {
                    store.updateRecipe(editingRecipe, name: name, servings: servings, notes: notes, ingredients: ingredients)
                } else {
                    store.addRecipe(name: name, servings: servings, notes: notes, ingredients: ingredients)
                }
                dismiss()
            }
        }
        .background(Color.parchment)
        .onAppear {
            foodSearchIndex = FoodItemSearch.Index(foodItems: store.foodItems)
        }
        .onChange(of: store.foodItems) { _, newValue in
            foodSearchIndex = FoodItemSearch.Index(foodItems: newValue)
        }
        .navigationDestination(isPresented: $scannerPath) {
            NutritionLabelCameraSheet { result in
                applyLabelScan(result)
            }
        }
        .onAppear {
            guard startsWithScanner, didStartScanner == false else { return }
            didStartScanner = true
            scannerPath = true
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ingredients.contains { !$0.trimmedName.isEmpty }
    }

    private var perServingTotals: MacroTotals {
        let totals = ingredients.reduce(into: MacroTotals()) { partial, ingredient in
            guard !ingredient.trimmedName.isEmpty else { return }
            let macros = ingredient.resolvedMacros(foodItems: store.foodItems)
            partial.protein += macros.protein
            partial.carbs += macros.carbs
            partial.fat += macros.fat
        }
        let divisor = max(servings, 1)
        return MacroTotals(
            protein: Int((Double(totals.protein) / Double(divisor)).rounded()),
            carbs: Int((Double(totals.carbs) / Double(divisor)).rounded()),
            fat: Int((Double(totals.fat) / Double(divisor)).rounded())
        )
    }

    private func removeIngredient(_ id: UUID) {
        guard ingredients.count > 1 else {
            let fresh = ManualRecipeIngredientInput()
            ingredients = [fresh]
            expandedId = fresh.id
            return
        }
        ingredients.removeAll { $0.id == id }
        if expandedId == id { expandedId = nil }
    }

    private func applyLabelScan(_ result: NutritionLabelResult) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = scannedRecipeName(from: result)
        }

        if ingredients.isEmpty {
            ingredients.append(ManualRecipeIngredientInput())
        }

        var ingredient = ingredients[0]
        if ingredient.trimmedName.isEmpty {
            ingredient.name = result.servingSize ?? "Scanned serving"
        }
        ingredient.quantity = 1
        ingredient.unit = RecipeUnit.serving.rawValue
        ingredient.selectedFoodItemId = nil
        ingredient.protein = result.protein ?? ingredient.protein
        ingredient.carbs = result.carbs ?? ingredient.carbs
        ingredient.fat = result.fat ?? ingredient.fat
        ingredient.scannedMicronutrients = result.micronutrients().hasAnyValue ? result.micronutrients() : ingredient.scannedMicronutrients
        ingredients[0] = ingredient
        expandedId = ingredient.id
    }

    private func scannedRecipeName(from result: NutritionLabelResult) -> String {
        if let servingSize = result.servingSize, servingSize.isEmpty == false {
            return "Scanned item (\(servingSize))"
        }
        return "Scanned item"
    }

    private static func inputs(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> [ManualRecipeIngredientInput] {
        let inputs = recipe.ingredients.compactMap { recipeIngredient -> ManualRecipeIngredientInput? in
            guard let foodItem = foodItems.first(where: { $0.id == recipeIngredient.foodItemId }) else { return nil }
            let selectedFoodItemId = foodItem.source == .manual ? nil : foodItem.id
            return ManualRecipeIngredientInput(
                name: foodItem.name,
                selectedFoodItemId: selectedFoodItemId,
                quantity: recipeIngredient.quantity,
                unit: recipeIngredient.unit,
                protein: foodItem.macros.protein,
                carbs: foodItem.macros.carbs,
                fat: foodItem.macros.fat,
                scannedMicronutrients: foodItem.source == .manual && foodItem.micronutrients.hasAnyValue ? foodItem.micronutrients : nil
            )
        }
        return inputs.isEmpty ? [ManualRecipeIngredientInput()] : inputs
    }
}

private struct NutritionLabelScanReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let result: NutritionLabelResult
    let onUse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review the values before applying them to the first ingredient.")
                        .font(.callout)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    if let servingSize = result.servingSize {
                        scanReviewRow("Serving size", servingSize)
                    }
                    if let calories = result.calories {
                        scanReviewRow("Calories", "\(calories)")
                    }
                    if let protein = result.protein {
                        scanReviewRow("Protein", "\(protein)g")
                    }
                    if let carbs = result.carbs {
                        scanReviewRow("Carbs", "\(carbs)g")
                    }
                    if let fat = result.fat {
                        scanReviewRow("Fat", "\(fat)g")
                    }
                }
                .padding(20)
            }

            SheetSaveBar(label: "Use values") {
                onUse()
                dismiss()
            }
        }
        .background(Color.parchment)
        .navigationTitle("Review scan")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scanReviewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.bark)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.moss)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CollapsedIngredientRow: View {
    var ingredient: ManualRecipeIngredientInput
    var foodItems: [FoodItem]
    var onExpand: () -> Void
    var onRemove: () -> Void

    private var macros: Macros {
        ingredient.resolvedMacros(foodItems: foodItems)
    }

    private var calories: Int {
        macros.protein * 4 + macros.carbs * 4 + macros.fat * 9
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onExpand) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ingredient.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(String(format: "%g", ingredient.quantity)) \(ingredient.unit) · P\(macros.protein)g C\(macros.carbs)g F\(macros.fat)g · \(calories) cal")
                        .font(.caption)
                        .foregroundStyle(Color.slate)
                }
            }
            .buttonStyle(.plain)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

struct RecipeIngredientEditor: View {
    @Binding var ingredient: ManualRecipeIngredientInput
    var foodItems: [FoodItem]
    var foodSearchIndex: FoodItemSearch.Index
    var onSaveCustomIngredient: (ManualRecipeIngredientInput) -> FoodItem?
    var onCollapse: (() -> Void)?
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.slate)
                    TextField("Search ingredient", text: $ingredient.name)
                        .font(.body.weight(.medium))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textContentType(.none)
                }
                if let onCollapse, !ingredient.trimmedName.isEmpty {
                    Button("Done", action: onCollapse)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.moss)
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .foregroundStyle(Color.slate)
                }
                .buttonStyle(.plain)
            }
            if !matchingFoodItems.isEmpty && selectedFoodItem == nil {
                VStack(spacing: 4) {
                    ForEach(matchingFoodItems) { foodItem in
                        Button {
                            select(foodItem)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(foodItem.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Color.bark)
                                    Text("\(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit) · P\(foodItem.macros.protein)g C\(foodItem.macros.carbs)g F\(foodItem.macros.fat)g")
                                        .font(.caption)
                                        .foregroundStyle(Color.slate)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.moss)
                            }
                            .padding(10)
                            .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if canSaveCustomIngredient {
                Button {
                    if let foodItem = onSaveCustomIngredient(ingredient) {
                        select(foodItem)
                    }
                } label: {
                    Label("Save custom ingredient", systemImage: "plus.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.moss)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                TextField("Qty", value: $ingredient.quantity, format: .number)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.none)
                    .frame(maxWidth: 80)
                Picker("Unit", selection: $ingredient.unit) {
                    ForEach(RecipeUnit.allCases) { unit in
                        Text(unit.label).tag(unit.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let selectedFoodItem {
                LockedMacroSummary(foodItem: selectedFoodItem, macros: ingredient.resolvedMacros(foodItems: foodItems)) {
                    ingredient.selectedFoodItemId = nil
                    ingredient.protein = selectedFoodItem.macros.protein
                    ingredient.carbs = selectedFoodItem.macros.carbs
                    ingredient.fat = selectedFoodItem.macros.fat
                }
            } else {
                MacroInputRow(label: "Protein", unit: "g", value: $ingredient.protein, range: 0...250)
                MacroInputRow(label: "Carbs", unit: "g", value: $ingredient.carbs, range: 0...300)
                MacroInputRow(label: "Fat", unit: "g", value: $ingredient.fat, range: 0...200)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: ingredient.name) { _, newValue in
            syncSelection(for: newValue)
        }
    }

    private var selectedFoodItem: FoodItem? {
        ingredient.selectedFoodItem(in: foodItems)
    }

    private var matchingFoodItems: [FoodItem] {
        FoodItemSearch.results(for: ingredient.trimmedName, in: foodSearchIndex)
    }

    private var canSaveCustomIngredient: Bool {
        guard selectedFoodItem == nil, !ingredient.trimmedName.isEmpty else { return false }
        return ingredient.protein > 0 || ingredient.carbs > 0 || ingredient.fat > 0
    }

    private func select(_ foodItem: FoodItem) {
        let unit = foodItem.preferredRecipeUnit
        ingredient.name = foodItem.name
        ingredient.selectedFoodItemId = foodItem.id
        ingredient.quantity = foodItem.defaultRecipeQuantity(for: unit)
        ingredient.unit = unit.rawValue
        ingredient.protein = foodItem.macros.protein
        ingredient.carbs = foodItem.macros.carbs
        ingredient.fat = foodItem.macros.fat
    }

    private func syncSelection(for name: String) {
        if let selectedFoodItem, selectedFoodItem.name != name {
            ingredient.selectedFoodItemId = nil
        }
        guard ingredient.selectedFoodItemId == nil else { return }
        let normalizedName = FoodItemSearch.normalized(ingredient.trimmedName)
        if let exact = foodSearchIndex.exactNameMatch(for: normalizedName) {
            select(exact)
        }
    }
}

struct LockedMacroSummary: View {
    var foodItem: FoodItem
    var macros: Macros
    var onUseManual: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(foodItem.source == .manual ? "Saved macros" : "USDA macros", systemImage: foodItem.source == .manual ? "checkmark.circle.fill" : "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                Spacer()
                Button("Manual", action: onUseManual)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
            }
            Text("P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.bark)
            Text("\(foodItem.category) · \(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit) reference")
                .font(.caption)
                .foregroundStyle(Color.slate)
        }
        .padding(12)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FernletStore
    var onLogged: ([Meal]) -> Void = { _ in }
    @State private var description = ""
    @State private var mealType: MealType?
    @State private var notice: String?
    @State private var path: [MealFlowDestination] = []
    @State private var isResolvingMeal = false

    var body: some View {
        NavigationStack(path: $path) {
            mealContent
                .navigationDestination(for: MealFlowDestination.self) { destination in
                    switch destination {
                    case .recipeSearch:
                        RecipeSheet(store: store, isEmbeddedInNavigationStack: true)
                    case .scanLabel:
                        NutritionLabelCameraSheet { _ in }
                    case .reviewScan:
                        EmptyView()
                    }
                }
        }
        .background(Color.parchment)
        .onAppear {
            store.markLaunchScreenDismissed()
            store.ensureBundledFoodItemsSeeded()
        }
    }

    private var mealContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Log meal")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    if !store.recentMeals.isEmpty {
                        Menu {
                            ForEach(store.recentMeals.prefix(8)) { meal in
                                Button(meal.name) {
                                    let copiedMeal = store.copyMeal(meal)
                                    onLogged([copiedMeal])
                                    dismiss()
                                }
                            }
                        } label: {
                            Label("Copy recent meal", systemImage: "clock.arrow.circlepath")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.moss)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                        }
                    }

                    SheetField("What did you eat?") {
                        SheetTextEditor(text: $description, placeholder: "scrambled eggs and toast", minHeight: 100)
                    }

                    SheetField("Meal type") {
                        FlowLayout(spacing: 8) {
                            Button("Auto") { mealType = nil }
                                .buttonStyle(ChipButtonStyle(selected: mealType == nil))
                            ForEach(MealType.allCases) { type in
                                Button(type.rawValue) { mealType = type }
                                    .buttonStyle(ChipButtonStyle(selected: mealType == type))
                            }
                        }
                    }

                    Text(foodSelectionStatusText)
                        .font(.caption.italic())
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

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

            SheetSaveBar(label: isResolvingMeal ? "Matching" : "Save", disabled: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolvingMeal) {
                let mealDescription = description
                let selectedMealType = mealType
                isResolvingMeal = true
                Task {
                    let meals = await store.addResolvedMeals(from: mealDescription, type: selectedMealType)
                    isResolvingMeal = false
                    if meals.contains(where: \.isAIFallback) {
                        notice = FernletVoice.message(for: .mealAnalysisFailed)
                    }
                    onLogged(meals)
                    dismiss()
                }
            }
        }
        .background(Color.parchment)
    }

    private var foodSelectionStatusText: String {
        if FoodSelectionAvailability.isFoundationModelAvailable {
            "Fernlet can match your words to local food selections before saving."
        } else {
            FernletVoice.message(for: .aiUnavailable)
        }
    }
}

struct MealRow: View {
    var meal: Meal
    var showCalories: Bool
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(meal.name).font(.headline)
                        Text(meal.mealType.rawValue)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(meal.mealType.color.opacity(0.25), in: Capsule())
                    }
                    Text(meal.note)
                        .font(.caption.italic())
                        .foregroundStyle(Color.slate)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    if showCalories {
                        Text("\(meal.calories) cal").font(.subheadline.weight(.semibold))
                    }
                    Button(role: .destructive, action: onDelete) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
            }
            HStack(spacing: 14) {
                Text("P \(meal.macros.protein)g").foregroundStyle(Color.moss)
                Text("C \(meal.macros.carbs)g")
                Text("F \(meal.macros.fat)g")
                Text(meal.confidence).foregroundStyle(Color.goldenrod)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.slate)
        }
        .padding(.vertical, 4)
    }
}

struct RecipeRow: View {
    var recipe: RecipeDefinition
    var totals: MacroTotals
    var showCalories: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(recipe.name)
                    .font(.headline)
                Spacer()
                Text("\(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
            }
            Text("\(recipe.ingredients.count) ingredient\(recipe.ingredients.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(Color.slate)
            if !recipe.notes.isEmpty {
                Text(recipe.notes)
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
                    .lineLimit(2)
            }
            HStack(spacing: 14) {
                Text("P \(perServing.protein)g").foregroundStyle(Color.moss)
                Text("C \(perServing.carbs)g")
                Text("F \(perServing.fat)g")
                if showCalories {
                    Text("\(perServing.calories) cal").foregroundStyle(Color.goldenrod)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.slate)
        }
        .padding(.vertical, 4)
    }

    private var perServing: MacroTotals {
        let divisor = max(recipe.servings, 1)
        return MacroTotals(
            protein: Int((Double(totals.protein) / Double(divisor)).rounded()),
            carbs: Int((Double(totals.carbs) / Double(divisor)).rounded()),
            fat: Int((Double(totals.fat) / Double(divisor)).rounded())
        )
    }
}

struct MacroInputRow: View {
    let label: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var isEditing = false
    @State private var textValue = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(Color.bark)
            Spacer()
            if isEditing {
                TextField("", text: $textValue)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.none)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .focused($isFocused)
                    .onAppear {
                        isFocused = true
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Button {
                    textValue = String(value)
                    isEditing = true
                } label: {
                    Text("\(value)\(unit)")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.moss)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            Stepper("", value: $value, in: range)
                .labelsHidden()
                .onChange(of: value) { _, _ in
                    if isEditing {
                        isFocused = false
                        isEditing = false
                    }
                }
        }
    }

    private func commit() {
        if let n = Int(textValue), range.contains(n) { value = n }
        isEditing = false
    }
}

struct RecipeCreationOptionsView: View {
    @ObservedObject var store: FernletStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Create recipe", subtitle: "Choose how to start.", subtitleFirst: false)

                VStack(spacing: 10) {
                    NavigationLink {
                        RecipeSheet(store: store, isEmbeddedInNavigationStack: true, startsWithScanner: true)
                    } label: {
                        RecipeCreationOptionRow(
                            title: "Scan label",
                            subtitle: "Use a nutrition facts label, then fill in the name and servings.",
                            systemImage: "camera.viewfinder"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        RecipeImportSheet(store: store)
                    } label: {
                        RecipeCreationOptionRow(
                            title: "Import recipe",
                            subtitle: "Paste a recipe URL or Fernlet recipe text.",
                            systemImage: "tray.and.arrow.down"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        RecipeSheet(store: store, isEmbeddedInNavigationStack: true)
                    } label: {
                        RecipeCreationOptionRow(
                            title: "Manual entry",
                            subtitle: "Enter ingredients, macros, servings, and notes yourself.",
                            systemImage: "square.and.pencil"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .background(Color.parchment)
        .navigationTitle("Create recipe")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RecipeCreationOptionRow: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 34, height: 34)
                .background(Color.moss.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.slate.opacity(0.6))
                .padding(.top, 8)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

private struct RecipeMealTypeMenu: View {
    var onSelect: (MealType) -> Void

    var body: some View {
        Menu {
            ForEach(MealType.allCases) { mealType in
                Button(mealType.rawValue) {
                    onSelect(mealType)
                }
            }
        } label: {
            Image(systemName: "fork.knife")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Log recipe as meal")
    }
}

struct RecipeBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FernletStore
    @Binding var editingRecipe: RecipeDefinition?
    @Binding var editingSavedRecipe: SavedRecipe?
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(title: "Recipe book", subtitle: "All recipes, A\u{2013}Z.", subtitleFirst: false)
                    NavigationLink {
                        RecipeCreationOptionsView(store: store)
                    } label: {
                        Label("Create recipe", systemImage: "plus")
                            .font(.headline)
                            .foregroundStyle(Color.cream)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    TextField("Search recipes", text: $searchText)
                        .sheetTextInput()
                    let allManual = filteredManualRecipes
                    if !allManual.isEmpty {
                        FernletCard {
                            VStack(spacing: 0) {
                                ForEach(Array(allManual.enumerated()), id: \.element.id) { index, recipe in
                                    if index > 0 { FernletRowDivider() }
                                    HStack(spacing: 12) {
                                        Button { editingRecipe = recipe; dismiss() } label: {
                                            RecipeRow(recipe: recipe, totals: store.macroTotals(for: recipe), showCalories: store.settings.showCalories)
                                        }
                                        .buttonStyle(.plain)
                                        RecipeMealTypeMenu { mealType in
                                            store.logRecipe(recipe, mealType: mealType)
                                            dismiss()
                                        }
                                        ShareLink(item: store.recipeShareText(for: recipe)) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(Color.moss)
                                                .frame(width: 36, height: 36)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    let allSaved = filteredSavedRecipes
                    if !allSaved.isEmpty {
                        FernletCard {
                            VStack(spacing: 0) {
                                ForEach(Array(allSaved.enumerated()), id: \.element.id) { index, recipe in
                                    if index > 0 { FernletRowDivider() }
                                    HStack(spacing: 12) {
                                        Button { editingSavedRecipe = recipe; dismiss() } label: {
                                            SavedRecipeRow(recipe: recipe)
                                        }
                                        .buttonStyle(.plain)
                                        RecipeMealTypeMenu { mealType in
                                            store.logSavedRecipe(recipe, mealType: mealType)
                                            dismiss()
                                        }
                                        ShareLink(item: store.savedRecipeShareText(for: recipe)) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(Color.moss)
                                                .frame(width: 36, height: 36)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    if allManual.isEmpty && allSaved.isEmpty && !searchText.isEmpty {
                        EmptyState(text: "No recipes match \u{201C}\(searchText)\u{201D}.")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(Color.parchment)
            .navigationTitle("")
        }
        .background(Color.parchment)
    }

    private var filteredManualRecipes: [RecipeDefinition] {
        let sorted = store.recipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredSavedRecipes: [SavedRecipe] {
        let sorted = store.savedRecipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

#if canImport(SafariServices)
import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#endif

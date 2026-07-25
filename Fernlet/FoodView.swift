import ProximityKit
import SwiftUI
import AIContext
import AIProviders
import FernletScoring
import FoodCatalog
import AppServices

#if canImport(UIKit)
import UIKit
import PhotosUI
import FernletUI
import ImageIO
#endif

struct FoodView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @State private var editingRecipe: RecipeDefinition?
    @State private var editingSavedRecipe: RecipeDefinition?
    @State private var correctingMeal: Meal?
    @State private var showingRecipeBook = false
    @State private var recipeShareDraft: ProximityRecipeShareDraft?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: "Food", subtitle: "Eating enough, eating well.", identifier: "screen.food")
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
                                        .font(.fernlet(.header))
                                        .foregroundStyle(Color.bark)
                                    Spacer()
                                }
                                Text(FernletVoice.message(for: .retryAvailable))
                                    .font(.fernlet(.bubble))
                                    .foregroundStyle(Color.slate)
                                Button("Retry oldest") {
                                    Task { await store.retryOldestMeal() }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    if store.day.meals.isEmpty {
                        FernletScrollSection("Today") {
                            EmptyState(text: "Nothing yet. Describe a meal when you are ready.")
                        }
                    } else {
                        // Each meal type is its OWN section card, titled by a distinct small-caps
                        // SectionLabel (not the meal-name font) — separate boxes rather than one long list.
                        ForEach(mealsByType) { group in
                            FernletScrollSection(group.type.rawValue) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(group.meals.enumerated()), id: \.element.id) { rowIndex, meal in
                                        MealRow(
                                            meal: meal,
                                            showCalories: store.settings.showCalories,
                                            onDelete: { store.deleteMeal(meal) },
                                            onCorrect: { correctingMeal = meal },
                                            loadPhotoData: meal.photoID.map { id in { store.mealPhotoData(for: id) } },
                                            hasPhotoSealedFile: meal.photoID.map { id in { store.mealPhotoHasSealedFile(for: id) } },
                                            showsMealTypeBadge: false
                                        )
                                        if rowIndex < group.meals.count - 1 {
                                            FernletRowDivider()
                                        }
                                    }
                                    mealTypeSubtotal(group.meals)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel("Recipes")
                            Spacer()
                            Button("Recipe book") { showingRecipeBook = true }
                                .font(.fernlet(.label))
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
                                            // Controls sit on their own trailing line rather than beside the
                                            // row. In one HStack they claimed ~88pt of the card, so the row's
                                            // own trailing edge — and the servings label right-aligned to it —
                                            // stopped ~65% across and read as centered. Costs row height; the
                                            // smaller title above pays some of it back.
                                            VStack(alignment: .leading, spacing: 6) {
                                                #if canImport(UIKit)
                                                // Tapping a recipe pushes the read-only detail (photo,
                                                // per-serving macros, ingredients, notes); the editor is
                                                // reachable only via the detail's Edit button.
                                                NavigationLink {
                                                    RecipeDetailView(
                                                        store: store,
                                                        recipe: recipe,
                                                        onEdit: { editingRecipe = recipe },
                                                        onLog: { mealType in store.logRecipe(recipe, mealType: mealType) },
                                                        onShare: {
                                                            recipeShareDraft = ProximityRecipeShareDraft(
                                                                title: recipe.name,
                                                                shareText: store.recipeShareText(for: recipe),
                                                                payload: store.proximityRecipeSharePayload(for: recipe)
                                                            )
                                                        }
                                                    )
                                                } label: {
                                                    RecipeRow(recipe: recipe, totals: store.macroTotals(for: recipe), showCalories: store.settings.showCalories)
                                                }
                                                .buttonStyle(.plain)
                                                #else
                                                Button { editingRecipe = recipe } label: {
                                                    RecipeRow(recipe: recipe, totals: store.macroTotals(for: recipe), showCalories: store.settings.showCalories)
                                                }
                                                .buttonStyle(.plain)
                                                #endif
                                                HStack(spacing: 12) {
                                                    Spacer()
                                                    RecipeMealTypeMenu { mealType in
                                                        store.logRecipe(recipe, mealType: mealType)
                                                    }
                                                    RecipeShareButton {
                                                        recipeShareDraft = ProximityRecipeShareDraft(
                                                            title: recipe.name,
                                                            shareText: store.recipeShareText(for: recipe),
                                                            payload: store.proximityRecipeSharePayload(for: recipe)
                                                        )
                                                    }
                                                }
                                            }
                                        case .saved(let recipe):
                                            // Same trailing-controls layout as `.local` above — the two row
                                            // types interleave in one list and must not disagree.
                                            VStack(alignment: .leading, spacing: 6) {
                                                #if canImport(UIKit)
                                                // Same read-only detail as manual recipes; for a saved/web
                                                // recipe Edit opens its notes/delete sheet (web imports have
                                                // no structured ingredients to edit).
                                                NavigationLink {
                                                    RecipeDetailView(
                                                        store: store,
                                                        recipe: recipe,
                                                        onEdit: { editingSavedRecipe = recipe },
                                                        onLog: { mealType in store.logSavedRecipe(recipe, mealType: mealType) },
                                                        onShare: {
                                                            recipeShareDraft = ProximityRecipeShareDraft(
                                                                title: recipe.name,
                                                                shareText: store.savedRecipeShareText(for: recipe),
                                                                payload: store.proximityRecipeSharePayload(for: recipe)
                                                            )
                                                        }
                                                    )
                                                } label: {
                                                    SavedRecipeRow(recipe: recipe)
                                                }
                                                .buttonStyle(.plain)
                                                #else
                                                Button { editingSavedRecipe = recipe } label: {
                                                    SavedRecipeRow(recipe: recipe)
                                                }
                                                .buttonStyle(.plain)
                                                #endif
                                                HStack(spacing: 12) {
                                                    Spacer()
                                                    RecipeMealTypeMenu { mealType in
                                                        store.logSavedRecipe(recipe, mealType: mealType)
                                                    }
                                                    RecipeShareButton {
                                                        recipeShareDraft = ProximityRecipeShareDraft(
                                                            title: recipe.name,
                                                            shareText: store.savedRecipeShareText(for: recipe),
                                                            payload: store.proximityRecipeSharePayload(for: recipe)
                                                        )
                                                    }
                                                }
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
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
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
        .sheet(item: $correctingMeal) { meal in
            MealCorrectionSheet(store: store, meal: meal)
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
        .sheet(item: $recipeShareDraft) { draft in
            ProximityRecipeShareSheet(draft: draft, manager: store.recipeShareManager, store: store)
                .presentationDetents([.medium, .large])
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

    /// Today's meals grouped into meal-type sub-sections in a fixed display order, dropping any type
    /// with no meals so the "Today" card never shows an empty "Lunch" header. Meal order within each
    /// type mirrors the underlying `store.day.meals` order (filter preserves it — no reordering).
    private var mealsByType: [MealTypeGroup] {
        let order: [MealType] = [.breakfast, .lunch, .dinner, .snack, .preWorkout, .postWorkout]
        return order.compactMap { type in
            let meals = store.day.meals.filter { $0.mealType == type }
            return meals.isEmpty ? nil : MealTypeGroup(type: type, meals: meals)
        }
    }

    /// A quiet per-section macro footer inside each meal-type card (the type name is the card's title,
    /// so this only carries the protein and, behind the calorie opt-in, calorie subtotal).
    private func mealTypeSubtotal(_ meals: [Meal]) -> some View {
        let protein = meals.reduce(0) { $0 + $1.macros.protein }
        let calories = meals.reduce(0) { $0 + $1.calories }
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("P \(protein)g")
                .foregroundStyle(Color.moss)
            if store.settings.showCalories {
                Text("\(calories) cal")
                    .foregroundStyle(Color.slate)
            }
        }
        .font(.fernlet(.stat))
        .padding(.top, 10)
    }
}

/// One meal-type group in the "Today" card. Identifiable by its `MealType` so `ForEach` can key on
/// it without an index (each type appears at most once in `mealsByType`).
private struct MealTypeGroup: Identifiable {
    let type: MealType
    let meals: [Meal]
    var id: MealType { type }
}

private enum RecentRecipePreview: Identifiable {
    case local(RecipeDefinition)
    case saved(RecipeDefinition)

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
            recipe.createdAt
        }
    }
}

struct NutritionPill: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            Text(value)
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct RecipeImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @State private var importText = ""
    @State private var notice: String?
    @State private var isImportingURL = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Import recipe")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    Button {
                        importFromPasteboardURL()
                    } label: {
                        Label(isImportingURL ? "Importing URL" : "Paste URL", systemImage: isImportingURL ? "hourglass" : "link.badge.plus")
                            .font(.fernlet(.label))
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
                            .font(.fernlet(.bodySmall))
                            .italic()
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
                let importedRecipe = try await RecipeWebImporter.importRecipe(from: url, catalog: store.foodCatalog, aiEnabled: store.settings.aiStatus != .off)
                store.addSavedRecipe(RecipeDefinition(importedRecipe: importedRecipe))
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
    var recipe: RecipeDefinition

    private var webImport: RecipeWebImport? { recipe.webImport }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    // Matches `RecipeRow`'s title size — the two row types interleave in the same list
                    // on the main food page, so they must not disagree about how loud a recipe is.
                    Text(recipe.name)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    if let sourceURL = webImport?.sourceURL {
                        Text(sourceURL.host() ?? sourceURL.absoluteString)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                            .lineLimit(1)
                    }
                }
            }
            if !recipe.notes.isEmpty {
                Text(recipe.notes)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
            }
            Text((webImport?.ingredientLines ?? []).prefix(4).joined(separator: " | "))
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if let macros = webImport?.macros, macros.protein > 0 || macros.carbs > 0 || macros.fat > 0 {
                HStack(spacing: 14) {
                    Text("P \(macros.protein)g").foregroundStyle(Color.moss)
                    Text("C \(macros.carbs)g")
                    Text("F \(macros.fat)g")
                    if recipe.servings > 1 {
                        Text("· \(recipe.servings) servings")
                    }
                }
                .font(.fernlet(.stat))
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
    var store: FernletStore
    @State private var recipe: RecipeDefinition
    @State private var showingSafari = false

    init(store: FernletStore, recipe: RecipeDefinition) {
        self.store = store
        _recipe = State(initialValue: recipe)
    }

    private var webImport: RecipeWebImport? { recipe.webImport }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recipe.name)
                            .font(.fernlet(.displayMedium))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        if let sourceURL = webImport?.sourceURL {
                            if sourceURL.isSafariPresentable {
                                Button {
                                    showingSafari = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "safari")
                                            .font(.caption)
                                        Text(sourceURL.host() ?? sourceURL.absoluteString)
                                            .font(.fernlet(.labelSmall))
                                            .underline()
                                    }
                                    .foregroundStyle(Color.fern)
                                }
                                .buttonStyle(.plain)
                            } else {
                                // A non-web source link (e.g. a file URL) can't open in an in-app Safari
                                // sheet, so it's shown as calm, non-tappable text rather than a dead button.
                                Text(sourceURL.host() ?? sourceURL.absoluteString)
                                    .font(.fernlet(.labelSmall))
                                    .foregroundStyle(Color.slate)
                                    .lineLimit(1)
                            }
                        }
                    }

                    if let macros = webImport?.macros, macros.protein > 0 || macros.carbs > 0 || macros.fat > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(recipe.servings > 1 ? "PER SERVING" : "MACROS")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                                .tracking(0.8)
                            HStack(spacing: 14) {
                                Text("P \(macros.protein)g").foregroundStyle(Color.moss)
                                Text("C \(macros.carbs)g")
                                Text("F \(macros.fat)g")
                                Spacer()
                                if recipe.servings > 1 {
                                    Text("\(recipe.servings) servings")
                                        .font(.fernlet(.stat))
                                        .foregroundStyle(Color.slate)
                                }
                            }
                            .font(.fernlet(.stat))
                            .foregroundStyle(Color.bark)
                        }
                        .padding(14)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    }

                    SheetField("Notes") {
                        SheetTextEditor(text: $recipe.notes, placeholder: "cooking notes, substitutions, tips", minHeight: 120)
                    }

                    if let ingredientLines = webImport?.ingredientLines, !ingredientLines.isEmpty {
                        SheetField("Ingredients") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(ingredientLines, id: \.self) { ingredient in
                                    Text("• \(ingredient)")
                                        .font(.fernlet(.body))
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
                            .font(.fernlet(.label))
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
            if let sourceURL = webImport?.sourceURL, sourceURL.isSafariPresentable {
                SafariView(url: sourceURL)
                    .ignoresSafeArea()
            }
        }
    }
}

enum MealFlowDestination: Hashable {
    case scanBarcode
    case reviewScan(NutritionLabelResult)
    case recipeSearch
    case productPageImport
    case productSearch(String)
    /// Auto-router landings for a captured photo (Food Capture mockup §2b–2c): a barcode the router
    /// already read, and a nutrition label it already parsed. Both hand off to existing create/log
    /// flows via `BarcodePayloadResolveView` / `BarcodeNotFoundView(prefilledScan:)`.
    case captureBarcode(String)
    case captureLabel(NutritionLabelResult)
}

struct RecipeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    private var editingRecipe: RecipeDefinition?
    private var isEmbeddedInNavigationStack: Bool
    private var startsWithScanner: Bool
    @State private var name = ""
    @State private var servings = 1
    @State private var notes = ""
    @State private var ingredients: [ManualRecipeIngredientInput] = []
    @State private var expandedId: UUID?
    @State private var scannerPath = false
    @State private var didStartScanner = false
    @State private var showingBarcodeScanner = false

    init(store: FernletStore, recipe: RecipeDefinition? = nil, isEmbeddedInNavigationStack: Bool = false, startsWithScanner: Bool = false) {
        self.store = store
        self.editingRecipe = recipe
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
        self.startsWithScanner = startsWithScanner
        if let recipe {
            let loadedIngredients = Self.inputs(for: recipe, foodItems: store.foodCatalog.items(forRecipe: recipe))
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
                        .font(.fernlet(.displayMedium))
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
                            ForEach($ingredients) { $ingredient in
                                if expandedId == ingredient.id || ingredient.trimmedName.isEmpty {
                                    RecipeIngredientEditor(
                                        ingredient: $ingredient,
                                        catalog: store.foodCatalog,
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
                                        catalog: store.foodCatalog,
                                        showCalories: store.settings.showCalories,
                                        onExpand: { expandedId = ingredient.id },
                                        onRemove: { removeIngredient(ingredient.id) }
                                    )
                                }
                            }
                            HStack(spacing: 8) {
                                Button {
                                    let new = ManualRecipeIngredientInput()
                                    ingredients.append(new)
                                    expandedId = new.id
                                } label: {
                                    Label("Add ingredient", systemImage: "plus")
                                        .font(.fernlet(.label))
                                        .foregroundStyle(Color.moss)
                                        .frame(maxWidth: .infinity)
                                        .padding(12)
                                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                                }
                                .buttonStyle(.plain)

                                #if canImport(UIKit)
                                Button {
                                    showingBarcodeScanner = true
                                } label: {
                                    Label("Scan barcode", systemImage: "barcode.viewfinder")
                                        .font(.fernlet(.label))
                                        .foregroundStyle(Color.moss)
                                        .frame(maxWidth: .infinity)
                                        .padding(12)
                                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                #endif
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("PER SERVING")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                            .tracking(0.8)
                        HStack {
                            Text("P \(perServingTotals.protein)g · C \(perServingTotals.carbs)g · F \(perServingTotals.fat)g")
                                .font(.fernlet(.stat))
                                .foregroundStyle(Color.bark)
                            Spacer()
                            // Macros-first: calories render only behind the explicit opt-in.
                            if store.settings.showCalories {
                                Text("\(perServingTotals.calories) cal")
                                    .font(.fernlet(.stat))
                                    .foregroundStyle(Color.slate)
                            }
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
                                .font(.fernlet(.label))
                                .frame(maxWidth: .infinity)
                                .padding(14)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            if editingRecipe == nil {
                HStack(spacing: 12) {
                    Button("Save recipe") {
                        store.addRecipe(name: name, servings: servings, notes: notes, ingredients: ingredients)
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.moss.opacity(0.3), lineWidth: 1))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.4)

                    Button("Log & save") {
                        let recipe = store.addRecipe(name: name, servings: servings, notes: notes, ingredients: ingredients)
                        store.logRecipe(recipe)
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canSave ? Color.moss : Color.moss.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                    .disabled(!canSave)
                }
                .padding(20)
                .background(Color.parchment)
            } else {
                SheetSaveBar(disabled: !canSave) {
                    store.updateRecipe(editingRecipe!, name: name, servings: servings, notes: notes, ingredients: ingredients)
                    dismiss()
                }
            }
        }
        .background(Color.parchment)
        .navigationDestination(isPresented: $scannerPath) {
            NutritionLabelCameraSheet(showCalories: store.settings.showCalories) { result in
                applyLabelScan(result)
            }
        }
        #if canImport(UIKit)
        .navigationDestination(isPresented: $showingBarcodeScanner) {
            BarcodeResolveFlowView(store: store) { foodItem in
                showingBarcodeScanner = false
                appendIngredient(for: foodItem)
            }
        }
        #endif
        .onAppear {
            guard startsWithScanner, didStartScanner == false else { return }
            didStartScanner = true
            scannerPath = true
        }
    }

    /// Lands a barcode-resolved food (catalog hit or just-remembered user item) in the ingredient
    /// list, bound to the item exactly as `RecipeIngredientEditor.select` would bind a search pick.
    private func appendIngredient(for foodItem: FoodItem) {
        let unit = foodItem.preferredRecipeUnit
        let input = ManualRecipeIngredientInput(
            name: foodItem.name,
            selectedFoodItemId: foodItem.id,
            quantity: foodItem.defaultRecipeQuantity(for: unit),
            unit: unit.rawValue,
            protein: foodItem.macros.protein,
            carbs: foodItem.macros.carbs,
            fat: foodItem.macros.fat
        )
        if ingredients.count == 1, ingredients[0].trimmedName.isEmpty {
            ingredients[0] = input
        } else {
            ingredients.append(input)
        }
        expandedId = input.id
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ingredients.contains { !$0.trimmedName.isEmpty }
    }

    private var perServingTotals: MacroTotals {
        let resolved = store.foodCatalog.items(ids: ingredients.compactMap(\.selectedFoodItemId))
        let totals = ingredients.reduce(into: MacroTotals()) { partial, ingredient in
            guard !ingredient.trimmedName.isEmpty else { return }
            let macros = ingredient.resolvedMacros(foodItems: resolved)
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

struct CollapsedIngredientRow: View {
    var ingredient: ManualRecipeIngredientInput
    var catalog: FoodCatalog
    /// Macros-first: the trailing calorie figure renders only behind the explicit opt-in.
    var showCalories: Bool
    var onExpand: () -> Void
    var onRemove: () -> Void

    private var macros: Macros {
        ingredient.resolvedMacros(foodItems: catalog.resolved(for: ingredient))
    }

    private var calories: Int {
        macros.protein * 4 + macros.carbs * 4 + macros.fat * 9
    }

    private var summaryLine: String {
        var line = "\(String(format: "%g", ingredient.quantity)) \(ingredient.unit) · P\(macros.protein)g C\(macros.carbs)g F\(macros.fat)g"
        if showCalories {
            line += " · \(calories) cal"
        }
        return line
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onExpand) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ingredient.name)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(summaryLine)
                        .font(.fernlet(.stat))
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
    var catalog: FoodCatalog
    var onSaveCustomIngredient: (ManualRecipeIngredientInput) -> FoodItem?
    var onCollapse: (() -> Void)?
    var onRemove: () -> Void

    /// Typeahead matches, computed off the main thread and debounced (see `.task` below).
    /// The `catalog.results(for:)` call does real work (SQLite + hydrate + index + score) and the
    /// catalog is growing toward ~482k rows, so it must never run synchronously in `body`.
    @State private var matchingFoodItems: [FoodItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.slate)
                    TextField("Search ingredient", text: $ingredient.name)
                        .font(.fernlet(.body))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textContentType(.none)
                }
                if let onCollapse, !ingredient.trimmedName.isEmpty {
                    Button("Done", action: onCollapse)
                        .buttonStyle(.plain)
                        .font(.fernlet(.label))
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
                                    HStack(spacing: 6) {
                                        Text(foodItem.name)
                                            .font(.fernlet(.body))
                                            .foregroundStyle(Color.bark)
                                        Text(foodItem.dataSourceLabel)
                                            .font(.fernlet(.labelSmall))
                                            .foregroundStyle(Color.slate)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Color.parchment, in: Capsule())
                                    }
                                    Text("\(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit) · P\(foodItem.macros.protein)g C\(foodItem.macros.carbs)g F\(foodItem.macros.fat)g")
                                        .font(.fernlet(.stat))
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
                        .font(.fernlet(.label))
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
                LockedMacroSummary(foodItem: selectedFoodItem, macros: ingredient.resolvedMacros(foodItems: catalog.resolved(for: ingredient))) {
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
        // Recompute the typeahead once per settled keystroke, off the main actor.
        // Keying on the raw bound text means every edit re-runs this and cancels the prior
        // in-flight task; the cancellation on a new keystroke is what prevents stale/duplicate
        // writes, so the body only ever reads the already-settled `matchingFoodItems` state.
        .task(id: ingredient.name) {
            let text = ingredient.trimmedName
            // Mirror the render gating: nothing to show when a food is chosen or the field is empty.
            guard selectedFoodItem == nil, !text.isEmpty else {
                matchingFoodItems = []
                return
            }
            // Debounce; a newer keystroke cancels this sleep and we bail before doing any work.
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            // Heavy SQLite/index/score work runs off the main actor. `catalog` is Sendable.
            let hits = await Task.detached { [catalog] in
                catalog.results(for: text)
            }.value
            // Drop the result if this task was superseded while the query was running.
            guard !Task.isCancelled else { return }
            matchingFoodItems = hits
        }
    }

    private var selectedFoodItem: FoodItem? {
        ingredient.selectedFoodItem(in: catalog.resolved(for: ingredient))
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
        // Only UNBIND when the user edits the name away from a previously-selected food. We deliberately
        // do NOT auto-bind on an exact normalized-name match while typing: with the large branded catalog
        // (tens of thousands of products), common words like "chicken"/"milk"/"eggs" collide with branded
        // product names, so auto-binding would silently hijack the field — locking macros to a random
        // product and hiding the suggestion list. Binding happens only when the user taps a suggestion.
        if let selectedFoodItem, selectedFoodItem.name != name {
            ingredient.selectedFoodItemId = nil
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
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
                Spacer()
                Button("Manual", action: onUseManual)
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.slate)
            }
            Text("P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
            Text("\(foodItem.category) · \(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit) reference")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
        .padding(12)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MealSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    var onLogged: ([Meal]) -> Void = { _ in }
    #if canImport(UIKit)
    /// One router owns the capture detectors, so the chooser branches reuse its injectable
    /// `barcodeDetector` seam (fakes reach every path) rather than newing up their own detector.
    var captureRouter = FoodCaptureRouter()
    #endif
    @State private var description = ""
    @State private var mealType: MealType?
    @State private var notice: String?
    @State private var path: [MealFlowDestination] = []
    @State private var isResolvingMeal = false
    /// True once a meal has been committed but the sheet stayed open (photo-save failure notice). The
    /// save bar then becomes a Done/dismiss — a second "Save" tap must never log the same meal twice.
    @State private var didLogMeal = false
    @State private var reviewContext: MealReviewContext?
    #if canImport(UIKit)
    @State private var mealPhoto: UIImage?
    /// Sealed-ready JPEG bytes from a LIBRARY pick (the byte path, §2.5). Held so the photo is saved via
    /// `store.saveMealPhoto(data:)` — a single bounded normalize — instead of decoding a 48 MP pick into
    /// a ~190 MB full-res `UIImage` and re-encoding it. `mealPhoto` still holds a small downsampled
    /// preview for the sheet + the "Identify from photo" classifier. `nil` on the camera path, whose
    /// capture already hands back an in-memory `UIImage`.
    @State private var mealPhotoData: Data?
    // Camera / library-fallback plumbing now lives in the shared `PhotoCaptureControl` (#11 piece 4),
    // which both the primary Capture button and the "try again" retry use.
    @State private var isIdentifyingPhoto = false
    // Unified Capture auto-routing (Food Capture mockup §2b–2e).
    /// Calm "analyzing…" state shown while the router runs barcode → label → meal detection.
    @State private var isAnalyzingCapture = false
    /// Presented when detection is ambiguous/low-confidence — a gentle Barcode · Label · Meal chooser.
    @State private var captureChooser: CaptureChooserContext?
    /// Set when the router (or a chooser branch) couldn't read the photo — a calm retry prompt, never
    /// a hard error.
    @State private var captureError: String?
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            mealContent
                .navigationDestination(for: MealFlowDestination.self) { destination in
                    switch destination {
                    case .recipeSearch:
                        RecipeSheet(store: store, isEmbeddedInNavigationStack: true)
                    case .scanBarcode:
                        #if canImport(UIKit)
                        // Barcode hit (or a just-remembered product) logs directly — scanning a
                        // product is itself the explicit "log this" gesture, like a cached web product.
                        BarcodeResolveFlowView(store: store) { foodItem in
                            let meal = store.logBarcodeScannedFoodItem(foodItem, mealType: mealType)
                            onLogged([meal])
                            dismiss()
                        }
                        #else
                        EmptyView()
                        #endif
                    case .reviewScan:
                        EmptyView()
                    #if canImport(UIKit)
                    case .captureBarcode(let payload):
                        // The auto-router already read this barcode from the captured photo — resolve
                        // it through the same catalog-hit / name-&-remember path as a live scan.
                        BarcodePayloadResolveView(store: store, payload: payload) { foodItem in
                            let meal = store.logBarcodeScannedFoodItem(foodItem, mealType: mealType)
                            onLogged([meal])
                            dismiss()
                        }
                    case .captureLabel(let result):
                        // The auto-router parsed a nutrition label — hand off to the existing
                        // name-it-&-remember screen with the macros pre-filled (no barcode, no rescan).
                        // Log via the label-scan path so provenance is truthful: this meal came from a
                        // scanned nutrition label, not a barcode.
                        BarcodeNotFoundView(store: store, barcode: "", prefilledScan: result) { foodItem in
                            let meal = store.logLabelScannedFoodItem(foodItem, mealType: mealType)
                            onLogged([meal])
                            dismiss()
                        }
                    #else
                    case .captureBarcode, .captureLabel:
                        EmptyView()
                    #endif
                    case .productPageImport:
                        FoodProductPageImportView(store: store) { product in
                            description = product.name
                            notice = "\(product.name) was saved. Review the meal description, then save your meal."
                            path.removeLast()
                        }
                    case .productSearch(let query):
                        FoodProductPageImportView(
                            store: store,
                            initialLookup: query,
                            onLogAsTyped: {
                                // Web lookup dead-end escape: pop back to the composer and log what the
                                // user originally typed through the normal resolve cascade.
                                if path.isEmpty == false { path.removeLast() }
                                resolveTypedMeal(query, type: mealType)
                            }
                        ) { product in
                            description = product.name
                            notice = "\(product.name) was saved. Review the meal description, then save your meal."
                            path.removeLast()
                        }
                    }
                }
        }
        .background(Color.parchment)
        // While a resolve is in flight, keep the sheet from being swiped away: the unstructured resolve
        // Task isn't cancelled on dismiss, so an interactive dismiss mid-"Matching" could commit a meal
        // the user meant to cancel or set reviewContext on a torn-down sheet. Once resolve finishes,
        // the commit / reviewContext handoff runs synchronously (no suspension point), so re-enabling
        // dismissal here can't reopen the window.
        .interactiveDismissDisabled(isResolvingMeal)
        #if canImport(UIKit)
        .overlay {
            if isAnalyzingCapture {
                CaptureAnalyzingOverlay()
                    .transition(.opacity)
            }
        }
        .animation(FernletMotion.ui, value: isAnalyzingCapture)
        #endif
        .onAppear {
            store.markLaunchScreenDismissed()
            store.ensureBundledFoodItemsSeeded()
        }
        .sheet(item: $reviewContext) { context in
            MealReviewSheet(
                resolution: context.resolution,
                store: store,
                onConfirm: { reviewedMeals, confirmedRecipe in
                    // User reviewed it: commit their version, never re-queue an AI retry over it. Any
                    // legacy auto-mint recipes ride along as before; the decomposition tier's reviewed
                    // recipe (confirmedRecipe) is minted here — and ONLY here — through the same
                    // diary.recipes path, so it never reaches the book without an explicit confirm.
                    let recipesToMint = context.resolution.createdRecipes + (confirmedRecipe.map { [$0] } ?? [])
                    let committed = store.commitResolution(
                        MealResolution(
                            meals: reviewedMeals,
                            createdRecipes: recipesToMint,
                            confidence: context.resolution.confidence,
                            isFallback: false
                        )
                    )
                    #if canImport(UIKit)
                    let photoAttached = attachPhoto(context.photo, data: context.photoData, to: committed)
                    #else
                    let photoAttached = true
                    #endif
                    reviewContext = nil
                    onLogged(committed)
                    if photoAttached {
                        dismiss()
                    } else {
                        // Same disarm as the direct resolve path: the meal is in, only the photo failed.
                        didLogMeal = true
                        notice = "Your meal is logged, but its photo couldn't be saved to your private store."
                    }
                },
                onDiscard: {
                    // Leave the log sheet open with the original text so the user can adjust and retry.
                    reviewContext = nil
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
        }
        #if canImport(UIKit)
        .sheet(item: $captureChooser) { context in
            CaptureChooserSheet(
                aiEnabled: store.settings.aiStatus != .off,
                onBarcode: {
                    captureChooser = nil
                    mealPhoto = context.image
                    lookUpBarcode(in: context.image, alreadyDetected: context.detectedBarcode)
                },
                onLabel: {
                    captureChooser = nil
                    routeCapturedLabel(context.parsedLabel, from: context.image)
                },
                onMeal: {
                    captureChooser = nil
                    mealPhoto = context.image
                    mealPhotoData = nil
                },
                onTypeInstead: {
                    captureChooser = nil
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
        }
        #endif
    }

    private var mealContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Log meal")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    #if canImport(UIKit)
                    if let photo = mealPhoto {
                        mealPhotoPreview(photo)
                        // On-device photo recognition, gated like every other inference path.
                        if store.settings.aiStatus != .off {
                            mealSecondaryButton(
                                isIdentifyingPhoto ? "Identifying..." : "Identify from photo",
                                icon: "sparkle.magnifyingglass"
                            ) {
                                identifyMealPhoto(photo)
                            }
                            .disabled(isIdentifyingPhoto)
                        }
                    }
                    #endif

                    SheetField("What did you eat?") {
                        SheetTextEditor(text: $description, placeholder: "scrambled eggs and toast", minHeight: 100)
                    }

                    // One primary, quiet helpers. "Capture" opens the camera as the delightful
                    // default; barcode Scan, Recent history, and Import stay reachable but demoted.
                    VStack(spacing: 10) {
                        #if canImport(UIKit)
                        // A camera shot goes through the auto-detect front door; a library pick is just
                        // attached as the meal photo (no barcode/label rescan on an arbitrary library image).
                        PhotoCaptureControl(
                            onCameraCapture: { handleCapturedPhoto($0) },
                            onLibraryPickData: { data, _ in setLibraryPickedMealPhoto(data) }
                        ) {
                            mealCapturePrimaryLabel
                        }
                        .accessibilityLabel("Capture food")

                        HStack(spacing: 8) {
                            mealSecondaryButton("Scan", icon: "barcode.viewfinder") {
                                path.append(.scanBarcode)
                            }
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
                                    mealSecondaryLabel("Recent", icon: "clock.arrow.circlepath")
                                }
                            }
                            mealSecondaryButton("Import", icon: "link.badge.plus") {
                                path.append(.productPageImport)
                            }
                        }
                        #else
                        mealSecondaryButton("Import", icon: "link.badge.plus") {
                            path.append(.productPageImport)
                        }
                        #endif
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

                    if let notice {
                        Text(notice)
                            .font(.fernlet(.bodySmall))
                            .italic()
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }

                    #if canImport(UIKit)
                    if let captureError {
                        captureCouldntReadBanner(captureError)
                    }
                    #endif
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(
                label: didLogMeal ? "Done" : (isResolvingMeal ? "Matching" : "Save"),
                disabled: !didLogMeal && (description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolvingMeal)
            ) {
                if didLogMeal {
                    // The meal already logged (only its photo failed) — never log it a second time.
                    dismiss()
                    return
                }
                let mealDescription = description
                let selectedMealType = mealType
                if FoodProductWebSearch.shouldSearch(for: mealDescription, foodItems: store.foodItems) {
                    if let cachedProduct = store.cachedWebImportedFoodProduct(for: mealDescription) {
                        let meal = store.logWebImportedFoodProduct(cachedProduct, mealType: selectedMealType)
                        onLogged([meal])
                        dismiss()
                        return
                    }
                    if store.allowsWebNutritionLookup {
                        auditWebNutritionLookup(mealDescription)
                        path.append(.productSearch(mealDescription))
                        return
                    }
                }
                resolveTypedMeal(mealDescription, type: selectedMealType)
            }
        }
        .background(Color.parchment)
    }

    /// Runs the normal free-text resolve cascade for a typed description: a low-confidence result
    /// pauses at the pre-log review sheet, otherwise it commits and dismisses. Shared by the Save
    /// button and the web-import "log what you typed instead" escape hatch, so the web path is never a
    /// one-way street.
    private func resolveTypedMeal(_ mealDescription: String, type: MealType?) {
        #if canImport(UIKit)
        let capturedPhoto = mealPhoto
        let capturedPhotoData = mealPhotoData
        #endif
        isResolvingMeal = true
        Task {
            let resolution = await store.resolveMeals(from: mealDescription, type: type)
            isResolvingMeal = false
            if resolution.needsReview {
                // Pause for a pre-log review instead of silently committing a low-confidence guess.
                #if canImport(UIKit)
                reviewContext = MealReviewContext(resolution: resolution, photo: capturedPhoto, photoData: capturedPhotoData)
                #else
                reviewContext = MealReviewContext(resolution: resolution)
                #endif
                return
            }
            let meals = store.commitResolution(resolution)
            #if canImport(UIKit)
            let photoAttached = attachPhoto(capturedPhoto, data: capturedPhotoData, to: meals)
            #else
            let photoAttached = true
            #endif
            onLogged(meals)
            if photoAttached {
                dismiss()
            } else {
                // The meal logged; only its photo couldn't be sealed. Keep the sheet open so the
                // notice is seen rather than the photo silently vanishing — but disarm Save so the
                // notice can't be answered with a second tap that logs the meal again.
                didLogMeal = true
                notice = "Your meal is logged, but its photo couldn't be saved to your private store."
            }
        }
    }

    struct MealReviewContext: Identifiable {
        let id = UUID()
        let resolution: MealResolution
        #if canImport(UIKit)
        var photo: UIImage?
        /// Sealed-ready bytes from a library pick, carried so the review-confirm attach uses the byte
        /// path too. `nil` on the camera path (which has only `photo`).
        var photoData: Data?
        #endif
    }

    #if canImport(UIKit)
    /// Attaches the captured photo to the just-logged meals. Returns false ONLY when a photo was present
    /// but couldn't be sealed (fail-closed `saveMealPhoto` returned nil) — the meal still logged, but its
    /// photo was dropped, so the caller surfaces a gentle notice instead of dismissing on a silent loss.
    @discardableResult
    private func attachPhoto(_ photo: UIImage?, data: Data?, to meals: [Meal]) -> Bool {
        // Prefer the byte path (single bounded normalize, no double encode) when a library pick handed
        // back raw bytes; fall back to the UIImage overload for the camera path, which has no bytes.
        let photoID: UUID?
        if let data {
            photoID = store.saveMealPhoto(data: data)
        } else if let photo {
            photoID = store.saveMealPhoto(photo)
        } else {
            return true
        }
        guard let photoID else { return false }
        for meal in meals {
            store.attachMealPhoto(mealID: meal.id, photoID: photoID)
        }
        return true
    }

    /// Library-pick sink for the meal photo (byte path). Holds the sealed-ready bytes for saving and a
    /// bounded downsample for the preview/identify UI — the full-resolution bitmap is never materialised.
    private func setLibraryPickedMealPhoto(_ data: Data) {
        mealPhotoData = data
        mealPhoto = Self.boundedPreviewImage(from: data) ?? UIImage(data: data)
    }

    /// Downsamples picked bytes to a bounded preview `UIImage` via ImageIO's thumbnail path (longest
    /// side ≤ 1600 px), so a 48 MP library pick never decodes into a ~190 MB bitmap just to be shown in
    /// the sheet. Mirrors `MealPhotoStore.normalizedJPEG`'s bound without reaching into the sealed store.
    private static func boundedPreviewImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// "Identify from photo": Vision classification composes a description that runs the normal
    /// resolveMeals cascade — and a photo guess ALWAYS pauses at the review sheet, never
    /// silently committing. Nothing food-like → a gentle "want to type it?" fallback.
    private func identifyMealPhoto(_ photo: UIImage) {
        guard !isIdentifyingPhoto else { return }
        // Capture the (photo, bytes) pair up front, before the recognition await, so a mid-identify photo
        // swap can't pair this tap's image with someone else's live `mealPhotoData` (mirrors resolveTypedMeal).
        let capturedPhotoData = mealPhotoData
        isIdentifyingPhoto = true
        notice = nil
        Task {
            let outcome = await MealPhotoRecognizer().identify(photo: photo, type: mealType, host: store)
            isIdentifyingPhoto = false
            switch outcome {
            case .aiOff:
                break
            case .nothingRecognized:
                notice = "Fernlet couldn't quite tell what's in this photo — want to type what you ate instead?"
            case .resolved(let described, let resolution):
                description = described
                reviewContext = MealReviewContext(resolution: resolution, photo: photo, photoData: capturedPhotoData)
            }
        }
    }

    // MARK: - Unified Capture auto-routing (Food Capture mockup §2b–2e)

    struct CaptureChooserContext: Identifiable {
        let id = UUID()
        let image: UIImage
        /// The best-effort label parse (may be nil) so "Read the label" can prefill instead of rescan.
        let parsedLabel: NutritionLabelResult?
        /// The barcode the router already read from this image (nil when its scan found none). Carried
        /// so "Look up the barcode" reuses that result instead of re-scanning the same photo.
        let detectedBarcode: String?
    }

    /// The prominent Capture button's handler: run the auto-router over the still photo (barcode →
    /// label → meal), showing a calm "analyzing…" state, then route to the matching EXISTING flow. On
    /// an ambiguous/weak reading, offer the gentle chooser; the meal branch is the graceful default.
    private func handleCapturedPhoto(_ image: UIImage) {
        captureError = nil
        isAnalyzingCapture = true
        Task {
            let route = await captureRouter.route(for: image)
            isAnalyzingCapture = false
            switch route {
            case .barcode(let payload):
                mealPhoto = image
                mealPhotoData = nil
                path.append(.captureBarcode(payload))
            case .label(let result):
                path.append(.captureLabel(result))
            case .meal:
                // Graceful default — land the photo in the meal composer (existing meal-photo path).
                mealPhoto = image
                mealPhotoData = nil
            case .ambiguous(let label):
                // The router reaches `.ambiguous` only after its barcode scan came up empty, so the
                // chooser's "Look up the barcode" branch already knows there's nothing to find.
                captureChooser = CaptureChooserContext(image: image, parsedLabel: label, detectedBarcode: nil)
            }
        }
    }

    /// Chooser "Look up the barcode" branch — reuses the barcode the router already read from this
    /// photo when it has one; otherwise runs detection once through the router's injectable seam (the
    /// same detector the auto-route used, so fakes reach here). A calm "couldn't read that" prompt on a
    /// miss — never a hard error.
    private func lookUpBarcode(in image: UIImage, alreadyDetected: String?) {
        if let alreadyDetected, alreadyDetected.isEmpty == false {
            path.append(.captureBarcode(alreadyDetected))
            return
        }
        captureError = nil
        isAnalyzingCapture = true
        Task {
            let payload = try? await captureRouter.barcodeDetector.payload(in: image)
            isAnalyzingCapture = false
            if let payload, payload.isEmpty == false {
                path.append(.captureBarcode(payload))
            } else {
                captureError = "Fernlet couldn't spot a barcode in that photo. Steady hands and a little more light usually does it — or type it instead."
            }
        }
    }

    /// Chooser "Read the label" branch — use the parse the router already made if it read anything,
    /// otherwise re-run the OCR scanner on the held photo before handing off to the label flow.
    private func routeCapturedLabel(_ prefetched: NutritionLabelResult?, from image: UIImage) {
        if let prefetched, prefetched.recognizedFieldCount > 0 {
            path.append(.captureLabel(prefetched))
            return
        }
        captureError = nil
        isAnalyzingCapture = true
        Task {
            let parsed = try? await NutritionLabelScanner.scanAll(image: image).primary
            isAnalyzingCapture = false
            if let parsed {
                path.append(.captureLabel(parsed))
            } else {
                captureError = "Fernlet couldn't read that label. Steady hands and a little more light usually does it — or type it instead."
            }
        }
    }

    /// Calm "couldn't read that one" banner (mockup §2e) — never a red hard error; every dead-end
    /// offers a way forward (retake, or just type it in the field above).
    private func captureCouldntReadBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.goldenrod)
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                PhotoCaptureControl(
                    onCameraCapture: { captureError = nil; handleCapturedPhoto($0) },
                    // Byte path (matches the primary control): downsample the pick and stash the sealed-
                    // ready bytes so `attachPhoto` seals THIS image, not stale bytes from an earlier pick.
                    onLibraryPickData: { data, _ in captureError = nil; setLibraryPickedMealPhoto(data) }
                ) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.goldenrod.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("captureCouldntReadBanner")
    }
    #endif

    private var webNutritionLookupDisabledMessage: String {
        store.settings.aiStatus == .off
            ? "Turn off Manual off mode before using web nutrition lookup."
            : "Turn on Web nutrition lookup in Settings to search the web for chain or packaged-food nutrition."
    }

    private func auditWebNutritionLookup(_ mealDescription: String) {
        let payload = WebNutritionLookupPayload(mealDescription: mealDescription)
        Task {
            await AIAuditLog.shared.record(
                payloadKind: payload.payloadKind,
                destination: .webNutritionLookup,
                includedFields: payload.includedFieldNames
            )
        }
    }

    #if canImport(UIKit)
    /// The single prominent capture affordance — "one button points at food." It opens the camera
    /// (the delightful default). Barcode/scan/import remain as quiet helpers beneath it.
    /// The styled label for the prominent capture affordance — "one button points at food." The tap
    /// behavior (camera, or library fallback) lives in the shared `PhotoCaptureControl` that wraps this.
    private var mealCapturePrimaryLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.fill")
                .font(.system(size: 18, weight: .semibold))
            Text("Capture")
                .font(.fernlet(.label))
        }
        .foregroundStyle(Color.cream)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))
        .fernletSmallShadow()
    }
    #endif

    private func mealSecondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            mealSecondaryLabel(title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func mealSecondaryLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.fernlet(.label))
            .foregroundStyle(Color.moss)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    #if canImport(UIKit)
    private func mealPhotoPreview(_ image: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
            // Clear BOTH the preview image and the sealed-ready bytes: `attachPhoto` prefers the byte
            // path, so leaving `mealPhotoData` set would re-attach a photo the user explicitly removed.
            Button { mealPhoto = nil; mealPhotoData = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.bark)
                    .background(Color.cream, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }
    #endif
}

struct FoodProductPageImportView: View {
    var store: FernletStore
    var onSaved: (ImportedFoodProduct) -> Void
    /// Optional escape hatch offered when the web lookup fails or is disabled: log what the user typed
    /// through the normal meal resolve path instead of stranding them on the import screen. Nil when
    /// there's no typed-meal flow to fall back to (e.g. the explicit "Import" entry point).
    private var onLogAsTyped: (() -> Void)?
    private var initialLookup: String
    @State private var lookupText: String
    @State private var preview: ProductPagePreview?
    @State private var importedProduct: ImportedFoodProduct?
    @State private var notice: String?
    @State private var isLoading = false
    @State private var showingProductReview = false
    @State private var didStartInitialLookup = false

    init(store: FernletStore, initialLookup: String = "", onLogAsTyped: (() -> Void)? = nil, onSaved: @escaping (ImportedFoodProduct) -> Void) {
        self.store = store
        self.onSaved = onSaved
        self.onLogAsTyped = onLogAsTyped
        self.initialLookup = initialLookup
        _lookupText = State(initialValue: initialLookup)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Import product")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    urlEntry

                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(Color.moss)
                            Text(importedProduct == nil && preview != nil ? "Reading nutrition label..." : "Finding product page...")
                                .font(.fernlet(.body))
                                .italic()
                                .foregroundStyle(Color.slate)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    }

                    if let notice {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(notice)
                                .font(.fernlet(.bodySmall))
                                .italic()
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                            // When the web lookup can't help, don't strand the user here — let them log
                            // what they typed through the normal meal flow instead.
                            if let onLogAsTyped {
                                Button {
                                    onLogAsTyped()
                                } label: {
                                    Label("Log what you typed instead", systemImage: "square.and.pencil")
                                        .font(.fernlet(.label))
                                        .foregroundStyle(Color.moss)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

        }
        .background(Color.parchment)
        .sheet(isPresented: $showingProductReview) {
            if let preview {
                FoodProductReviewSheet(
                    preview: preview,
                    product: importedProduct,
                    showCalories: store.settings.showCalories,
                    onSearchAgain: searchAgain,
                    onConfirm: saveConfirmedProduct
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
            }
        }
        .onAppear {
            guard !initialLookup.isEmpty, !didStartInitialLookup else { return }
            didStartInitialLookup = true
            loadPreview()
        }
    }

    private var urlEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetField("Product search or page URL") {
                TextField("Costco chicken melts or https://example.com/product", text: $lookupText)
                    .textInputAutocapitalization(.never)
                    .sheetTextInput()
            }
            Text("Search for a specific packaged food or paste its product page. Fernlet will read the nutrition label and show the source and extracted values together before saving.")
                .font(.fernlet(.bodySmall))
                .italic()
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            actionButton(label: isLoading ? "Finding page" : "Find product page", systemImage: "magnifyingglass") {
                loadPreview()
            }
            .disabled(isLoading || lookupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var webNutritionLookupDisabledMessage: String {
        store.settings.aiStatus == .off
            ? "Turn off Manual off mode before using web nutrition lookup."
            : "Turn on Web nutrition lookup in Settings before searching the web for nutrition."
    }

    private func auditWebNutritionLookup(_ mealDescription: String) {
        let payload = WebNutritionLookupPayload(mealDescription: mealDescription)
        Task {
            await AIAuditLog.shared.record(
                payloadKind: payload.payloadKind,
                destination: .webNutritionLookup,
                includedFields: payload.includedFieldNames
            )
        }
    }

    private func actionButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.fernlet(.label))
                .foregroundStyle(Color.cream)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func loadPreview() {
        guard store.allowsWebNutritionLookup else {
            notice = webNutritionLookupDisabledMessage
            return
        }
        if let cachedProduct = store.cachedWebImportedFoodProduct(for: lookupText) {
            onSaved(ImportedFoodProduct(foodItem: cachedProduct, lookupQuery: lookupText))
            return
        }
        isLoading = true
        notice = nil
        auditWebNutritionLookup(lookupText)
        Task {
            do {
                if let url = normalizedURL {
                    preview = try await FoodProductWebImporter.preview(from: url)
                } else {
                    preview = try await FoodProductWebSearch.preview(for: lookupText)
                }
                if let preview {
                    var product = try await FoodProductWebImporter.importProduct(from: preview)
                    product.lookupQuery = lookupText
                    importedProduct = product
                    showingProductReview = true
                }
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "Could not import that product page."
            }
            isLoading = false
        }
    }

    private func saveConfirmedProduct() {
        guard let importedProduct else { return }
        showingProductReview = false
        store.saveWebImportedFoodProduct(importedProduct)
        onSaved(importedProduct)
    }

    private func searchAgain() {
        showingProductReview = false
        preview = nil
        importedProduct = nil
        notice = nil
    }

    private var normalizedURL: URL? {
        let trimmed = lookupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(".") && !trimmed.contains(" ") else { return nil }
        return FoodProductWebImporter.normalizedWebURL(from: trimmed)
    }
}

struct FoodProductReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    var preview: ProductPagePreview
    var product: ImportedFoodProduct?
    /// Macros-first: the Calories pill renders only behind the explicit opt-in.
    var showCalories: Bool
    var onSearchAgain: () -> Void
    var onConfirm: () -> Void
    @State private var showingSafari = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Confirm product")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    VStack(alignment: .leading, spacing: 12) {
                        detail(label: "Product", value: preview.title)
                        detail(label: "Website", value: preview.sourceName)
                        detail(label: "Source URL", value: preview.sourceURL.absoluteString)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))

                    if let product {
                        nutritionSummary(product)
                    }

                    if preview.sourceURL.isSafariPresentable {
                        Button {
                            showingSafari = true
                        } label: {
                            Label("Open page", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        dismiss()
                        onSearchAgain()
                    } label: {
                        Label("Search again", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Confirm & save product", disabled: product == nil) {
                dismiss()
                onConfirm()
            }
        }
        .background(Color.parchment)
        #if canImport(SafariServices)
        .sheet(isPresented: $showingSafari) {
            if preview.sourceURL.isSafariPresentable {
                SafariView(url: preview.sourceURL)
                    .ignoresSafeArea()
            }
        }
        #endif
    }

    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .tracking(0.8)
            Text(value)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
    }

    private func nutritionSummary(_ product: ImportedFoodProduct) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SERVING SIZE")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .tracking(0.8)
                Text(product.servingSize)
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))

            HStack(spacing: 8) {
                NutritionPill(title: "Protein", value: "\(product.macros.protein)g")
                NutritionPill(title: "Carbs", value: "\(product.macros.carbs)g")
            }
            HStack(spacing: 8) {
                NutritionPill(title: "Fat", value: "\(product.macros.fat)g")
                if showCalories {
                    NutritionPill(title: "Calories", value: "\(calories(for: product))")
                }
            }

            Text("Check the serving size and nutrition values before saving. Fernlet will add this product to your local food catalog only after confirmation.")
                .font(.fernlet(.bodySmall))
                .italic()
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    private func calories(for product: ImportedFoodProduct) -> Int {
        product.calories ?? (product.macros.protein * 4 + product.macros.carbs * 4 + product.macros.fat * 9)
    }
}

struct MealRow: View {
    var meal: Meal
    var showCalories: Bool
    var onDelete: () -> Void
    var onCorrect: () -> Void
    var loadPhotoData: (() -> Data?)? = nil
    /// Existence-only probe paired with `loadPhotoData`: lets the thumb tell a photo that never synced
    /// here from one that's here but couldn't be opened. Non-nil exactly when `loadPhotoData` is.
    var hasPhotoSealedFile: (() -> Bool)? = nil
    /// The row's own meal-type capsule. Suppressed when the row already sits under a meal-type section
    /// header (the "Today" card) so the type isn't labelled twice; defaults to shown for any other use.
    var showsMealTypeBadge: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            #if canImport(UIKit)
            if let loadData = loadPhotoData {
                MealPhotoThumb(loadData: loadData, hasSealedData: hasPhotoSealedFile ?? { false })
            }
            #endif
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(meal.name).font(.fernlet(.header))
                            if showsMealTypeBadge {
                                Text(meal.mealType.rawValue)
                                    .font(.fernlet(.labelSmall))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(meal.mealType.color.opacity(0.25), in: Capsule())
                            }
                        }
                        Text(displayNote)
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        if showCalories {
                            Text("\(meal.calories) cal").font(.fernlet(.stat))
                        }
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete meal")
                    }
                }
                if let breakdownText {
                    Text(breakdownText)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cream.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.bark.opacity(0.08), lineWidth: 1))
                }
                HStack(spacing: 14) {
                    Text("P \(meal.macros.protein)g").foregroundStyle(Color.moss)
                    Text("C \(meal.macros.carbs)g")
                    Text("F \(meal.macros.fat)g")
                    Text(meal.confidence).foregroundStyle(Color.goldenrod)
                    Spacer(minLength: 0)
                    Button("Looks off?", action: onCorrect)
                        .buttonStyle(.plain)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.fern)
                }
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayNote: String {
        breakdownText == nil ? meal.note : "Matched from local foods."
    }

    private var breakdownText: String? {
        if meal.componentSnapshots.isEmpty == false {
            let text = meal.componentSnapshots
                .map { "\($0.quantity.formatted(.number.precision(.fractionLength(0...1)))) \($0.unit) \($0.name)" }
                .joined(separator: ", ")
            return text.isEmpty ? nil : text
        }
        let prefix = "Matched locally from food selection: "
        guard meal.note.hasPrefix(prefix) else { return nil }
        let trimmed = meal.note
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct MealComponentCorrectionInput: Identifiable {
    let id: UUID
    let foodItemId: UUID?
    let name: String
    var quantity: Double
    let unit: String
    let baseQuantity: Double
    let baseMacros: Macros
    let baseMicronutrients: Micronutrients

    init(snapshot: MealComponentSnapshot) {
        id = snapshot.id
        foodItemId = snapshot.foodItemId
        name = snapshot.name
        quantity = snapshot.quantity
        unit = snapshot.unit
        baseQuantity = max(snapshot.quantity, 0.01)
        baseMacros = snapshot.macros
        baseMicronutrients = snapshot.micronutrients
    }

    var snapshot: MealComponentSnapshot {
        let scale = max(quantity, 0) / baseQuantity
        return MealComponentSnapshot(
            id: id,
            foodItemId: foodItemId,
            name: name,
            quantity: quantity,
            unit: unit,
            macros: baseMacros.scaled(by: scale),
            micronutrients: baseMicronutrients.scaled(by: scale)
        )
    }
}

struct MealCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    var meal: Meal
    @State private var name: String
    @State private var mealType: MealType
    @State private var protein: Int
    @State private var carbs: Int
    @State private var fat: Int
    @State private var components: [MealComponentCorrectionInput]

    init(store: FernletStore, meal: Meal) {
        self.store = store
        self.meal = meal
        _name = State(initialValue: meal.name)
        _mealType = State(initialValue: meal.mealType)
        _protein = State(initialValue: meal.macros.protein)
        _carbs = State(initialValue: meal.macros.carbs)
        _fat = State(initialValue: meal.macros.fat)
        _components = State(initialValue: meal.componentSnapshots.map(MealComponentCorrectionInput.init(snapshot:)))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Adjust meal")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    SheetField("Meal name") {
                        TextField("Meal", text: $name)
                            .sheetTextInput()
                    }

                    SheetField("Meal type") {
                        FlowLayout(spacing: 8) {
                            ForEach(MealType.allCases) { type in
                                Button(type.rawValue) { mealType = type }
                                    .buttonStyle(ChipButtonStyle(selected: mealType == type))
                            }
                        }
                    }

                    if components.isEmpty {
                        SheetField("Macros") {
                            MealMacroEditorRows(protein: $protein, carbs: $carbs, fat: $fat)
                        }
                    } else {
                        SheetField("Matched items") {
                            MealComponentEditorRows(components: $components)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Save correction", disabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                store.updateMealCorrection(
                    mealID: meal.id,
                    name: name,
                    mealType: mealType,
                    macros: components.isEmpty ? Macros(protein: protein, carbs: carbs, fat: fat) : componentMacros,
                    componentSnapshots: components.isEmpty ? nil : components.map(\.snapshot)
                )
                dismiss()
            }
        }
        .background(Color.parchment)
    }

    private var componentMacros: Macros {
        let totals = MealBuilder.totals(for: components.map(\.snapshot))
        return Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat)
    }
}

// MARK: - Shared meal editor rows (used by correction + pre-log review)

struct MealMacroEditorRows: View {
    @Binding var protein: Int
    @Binding var carbs: Int
    @Binding var fat: Int

    var body: some View {
        VStack(spacing: 10) {
            MacroInputRow(label: "Protein", unit: "g", value: $protein, range: 0...300)
            MacroInputRow(label: "Carbs", unit: "g", value: $carbs, range: 0...500)
            MacroInputRow(label: "Fat", unit: "g", value: $fat, range: 0...300)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MealComponentEditorRows: View {
    @Binding var components: [MealComponentCorrectionInput]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($components) { $component in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(component.name)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                        Spacer()
                        // Typeable quantity box so a wrong amount can be corrected directly, not only nudged.
                        TextField("Qty", value: $component.quantity, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.none)
                            .frame(maxWidth: 64)
                            .font(.fernlet(.stat))
                            .foregroundStyle(Color.bark)
                        Text(component.unit)
                            .font(.fernlet(.stat))
                            .foregroundStyle(Color.moss)
                    }
                    Stepper("", value: $component.quantity, in: 0...2000, step: component.unit == RecipeUnit.gram.rawValue ? 5 : 0.25)
                        .labelsHidden()
                    let macros = component.snapshot.macros
                    Text("P \(macros.protein)g  C \(macros.carbs)g  F \(macros.fat)g")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                }
                .padding(12)
                .background(Color.parchment.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 14) {
                Text("P \(componentMacros.protein)g").foregroundStyle(Color.moss)
                Text("C \(componentMacros.carbs)g")
                Text("F \(componentMacros.fat)g")
                Spacer(minLength: 0)
            }
            .font(.fernlet(.stat))
            .foregroundStyle(Color.slate)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
    }

    private var componentMacros: Macros {
        let totals = MealBuilder.totals(for: components.map(\.snapshot))
        return Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat)
    }
}

// MARK: - Pre-log review (low-confidence / fabricated resolutions)

private nonisolated struct EditableReviewMeal: Identifiable {
    let id: UUID
    var name: String
    var mealType: MealType
    var components: [MealComponentCorrectionInput]
    var protein: Int
    var carbs: Int
    var fat: Int
    let base: Meal

    init(base: Meal) {
        id = base.id
        name = base.name
        mealType = base.mealType
        components = base.componentSnapshots.map(MealComponentCorrectionInput.init(snapshot:))
        protein = base.macros.protein
        carbs = base.macros.carbs
        fat = base.macros.fat
        self.base = base
    }

    /// The meal the user is choosing to log, with their edits applied and marked as reviewed.
    var applied: Meal {
        var meal = base
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meal.name = trimmed.isEmpty ? base.name : trimmed
        meal.mealType = mealType
        if components.isEmpty {
            let macros = Macros(protein: protein, carbs: carbs, fat: fat)
            meal.macros = macros
            meal.macroSnapshot = macros
            meal.calorieSnapshot = macros.calories
            meal.micronutrientSnapshot = Micronutrients()
        } else {
            let snapshots = components.map(\.snapshot)
            var totalProtein = 0, totalCarbs = 0, totalFat = 0
            var micronutrients = Micronutrients()
            for snapshot in snapshots {
                totalProtein += snapshot.macros.protein
                totalCarbs += snapshot.macros.carbs
                totalFat += snapshot.macros.fat
                micronutrients.add(snapshot.micronutrients)
            }
            let macros = Macros(protein: totalProtein, carbs: totalCarbs, fat: totalFat)
            meal.componentSnapshots = snapshots
            meal.macros = macros
            meal.macroSnapshot = macros
            meal.calorieSnapshot = macros.calories
            meal.micronutrientSnapshot = micronutrients
        }
        meal.isAIFallback = false
        meal.confidence = "Reviewed"
        meal.quality = meal.macros.protein >= Macros.goodProteinThreshold ? .good : .ok
        return meal
    }
}

struct MealReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    private let confidence: MealResolutionConfidence
    /// The decomposition tier's built recipe, offered here for review. `nil` when the resolution
    /// carried no recipe (every non-decomposition tier, single-ingredient decompositions).
    private let suggestedRecipe: RecipeDefinition?
    /// Confirmed recipe (may be nil when the user opts out) is passed back alongside the reviewed meals
    /// so the caller can persist it through the SAME `commitResolution`/`diary.recipes` path — minting
    /// happens only on this confirm, never at resolve time.
    var onConfirm: ([Meal], RecipeDefinition?) -> Void
    var onDiscard: () -> Void
    @State private var meals: [EditableReviewMeal]
    /// One-shot guard so a fast double-tap on "Log meal" can't fire onConfirm twice — which would
    /// append the same meal id twice and double its macros.
    @State private var isLogging = false
    /// Editable recipe offer state (used only when `suggestedRecipe != nil`).
    @State private var saveAsRecipe: Bool
    @State private var recipeName: String
    @State private var recipeServings: Int

    init(
        resolution: MealResolution,
        store: FernletStore,
        onConfirm: @escaping ([Meal], RecipeDefinition?) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.store = store
        self.confidence = resolution.confidence
        self.suggestedRecipe = resolution.suggestedRecipe
        self.onConfirm = onConfirm
        self.onDiscard = onDiscard
        _meals = State(initialValue: resolution.meals.map(EditableReviewMeal.init(base:)))
        _saveAsRecipe = State(initialValue: resolution.suggestedRecipe != nil)
        _recipeName = State(initialValue: resolution.suggestedRecipe?.name ?? "")
        _recipeServings = State(initialValue: max(resolution.suggestedRecipe?.servings ?? 4, 1))
    }

    /// The recipe to mint, with the user's name + yield edits applied — or nil when there is no
    /// suggested recipe or the user turned the offer off.
    ///
    /// The ingredient quantities are rebuilt from the user's REVIEWED per-serving component grams (each
    /// × the chosen yield gives the full batch), not from the model's original decomposition. Components
    /// can only be re-quantified in review, never added or removed, so their `foodItemId` set maps 1:1
    /// onto the recipe's ingredients — keeping the promised invariant (per-serving == the plate) true
    /// even when the user corrected a component's grams, instead of silently minting the pre-edit amounts.
    private var confirmedRecipe: RecipeDefinition? {
        guard saveAsRecipe, let base = suggestedRecipe else { return nil }
        var recipe = base
        let oldYield = max(base.servings, 1)
        let newYield = max(recipeServings, 1)
        // The reviewed per-serving grams, keyed by the catalog item they bound to.
        var editedPerServing: [UUID: MealComponentCorrectionInput] = [:]
        for component in meals.flatMap(\.components) {
            if let foodItemId = component.foodItemId { editedPerServing[foodItemId] = component }
        }
        recipe.ingredients = base.ingredients.map { ingredient in
            if let edited = editedPerServing[ingredient.foodItemId] {
                return RecipeIngredient(
                    id: ingredient.id,
                    foodItemId: ingredient.foodItemId,
                    quantity: edited.quantity * Double(newYield),
                    unit: edited.unit
                )
            }
            // No matching reviewed component (not expected for a decomposition recipe) — fall back to
            // yield-scaling the model's original batch quantity so nothing is dropped.
            let factor = Double(newYield) / Double(oldYield)
            return RecipeIngredient(id: ingredient.id, foodItemId: ingredient.foodItemId, quantity: ingredient.quantity * factor, unit: ingredient.unit)
        }
        recipe.servings = newYield
        let trimmed = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.name = trimmed.isEmpty ? base.name : trimmed
        recipe.updatedAt = Date()
        return recipe
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Check this meal")
                            .font(.fernlet(.displayMedium))
                            .foregroundStyle(Color.bark)
                        Spacer()
                        Button("Discard", action: onDiscard)
                            .buttonStyle(.plain)
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.slate)
                    }

                    Text(reviewMessage)
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    ForEach($meals) { $meal in
                        VStack(alignment: .leading, spacing: 14) {
                            SheetField("Meal name") {
                                TextField("Meal", text: $meal.name)
                                    .sheetTextInput()
                            }

                            SheetField("Meal type") {
                                FlowLayout(spacing: 8) {
                                    ForEach(MealType.allCases) { type in
                                        Button(type.rawValue) { $meal.mealType.wrappedValue = type }
                                            .buttonStyle(ChipButtonStyle(selected: meal.mealType == type))
                                    }
                                }
                            }

                            if meal.components.isEmpty {
                                SheetField("Macros") {
                                    MealMacroEditorRows(protein: $meal.protein, carbs: $meal.carbs, fat: $meal.fat)
                                }
                            } else {
                                SheetField("Matched items") {
                                    MealComponentEditorRows(components: $meal.components)
                                }
                            }
                        }
                    }

                    if suggestedRecipe != nil {
                        recipeOfferSection
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Log meal", disabled: isLogging) {
                guard !isLogging else { return }
                isLogging = true
                onConfirm(meals.map(\.applied), confirmedRecipe)
            }
        }
        .background(Color.parchment)
    }

    /// Offers the decomposition-built recipe for saving to the recipe book: an opt-out toggle plus an
    /// editable name and yield. Nothing here is persisted until the user taps "Log meal" (the offer is
    /// carried back through `confirmedRecipe`), so declining or editing costs nothing.
    @ViewBuilder private var recipeOfferSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $saveAsRecipe) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save as a recipe")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text("Keep this in your recipe book to log again later.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .tint(Color.moss)
            .accessibilityIdentifier("mealReview.saveAsRecipe")

            if saveAsRecipe {
                SheetField("Recipe name") {
                    TextField("Recipe", text: $recipeName)
                        .sheetTextInput()
                        .accessibilityIdentifier("mealReview.recipeName")
                }
                SheetField("Makes") {
                    Stepper(
                        "\(recipeServings) serving\(recipeServings == 1 ? "" : "s")",
                        value: $recipeServings,
                        in: 1...24
                    )
                    .accessibilityIdentifier("mealReview.recipeServings")
                }
            }
        }
        .padding(16)
        .background(Color.cream.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var reviewMessage: String {
        switch confidence {
        case .low:
            return "Fernlet wasn't sure this matched what you ate, so it's a rough estimate. Adjust anything that looks off, then log it."
        default:
            return "Double-check the items below before logging."
        }
    }
}

#if canImport(UIKit)
private struct MealPhotoThumb: View {
    var loadData: () -> Data?
    /// Existence-only probe (no decrypt): tells a photo that never synced here (no file) from one that's
    /// here but wouldn't open (corrupt). See `MealPhotoPolaroid.hasSealedData`.
    var hasSealedData: () -> Bool
    @State private var image: UIImage?
    /// nil until the sealed read runs; false once it comes back empty (no openable bytes on this device).
    @State private var bytesAvailable: Bool?
    /// Consulted only when `bytesAvailable == false` — splits "on another device" (no file) from
    /// "couldn't open" (file present but broken).
    @State private var sealedFileExists: Bool = false

    /// The thumbnail is only rendered for a meal that HAS a photo, so the read outcome alone decides
    /// whether the picture is here, on another device, or here-but-unreadable (see MealPhotoPresence).
    private var presence: MealPhotoPresence {
        MealPhotoPresence.classify(
            hasPhoto: true, sealedFileExists: sealedFileExists, bytesAvailable: bytesAvailable ?? true)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if presence == .onOtherDevice {
                // Photo taken on another device; day data synced here, the bytes didn't. A quiet,
                // deliberate glyph rather than the same "no photo yet" fork-and-knife.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cream)
                    .frame(width: 54, height: 54)
                    .overlay(Image(systemName: "iphone.and.arrow.forward").font(.caption).foregroundStyle(Color.slate.opacity(0.7)))
                    .accessibilityLabel("Photo on your other device")
            } else if presence == .unavailable {
                // The sealed file is here but wouldn't open (corrupt / undecryptable) — a distinct,
                // honest glyph rather than claiming it lives on another device.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cream)
                    .frame(width: 54, height: 54)
                    .overlay(Image(systemName: "photo.badge.exclamationmark").font(.caption).foregroundStyle(Color.slate.opacity(0.7)))
                    .accessibilityLabel("Photo couldn't be opened")
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cream)
                    .frame(width: 54, height: 54)
                    .overlay(Image(systemName: "fork.knife").font(.caption).foregroundStyle(Color.slate))
            }
        }
        .task {
            guard image == nil else { return }
            guard let data = loadData() else {
                sealedFileExists = hasSealedData()
                bytesAvailable = false
                return
            }
            bytesAvailable = true
            if let img = UIImage(data: data) { image = img }
        }
    }
}
#endif

struct RecipeRow: View {
    var recipe: RecipeDefinition
    var totals: MacroTotals
    var showCalories: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // `.headerMedium` (20pt), a step down from the 24pt `.header` that `MealRow` uses above
                // this section. Deliberate hierarchy rather than an inconsistency: meals are the log,
                // recipes are a shortcut list beneath it.
                Text(recipe.name)
                    .font(.fernlet(.headerMedium))
                Spacer()
                Text("\(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
            }
            Text("\(recipe.ingredients.count) ingredient\(recipe.ingredients.count == 1 ? "" : "s")")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
            if !recipe.notes.isEmpty {
                Text(recipe.notes)
                    .font(.fernlet(.bubble))
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
            .font(.fernlet(.stat))
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

#if canImport(UIKit)
/// Read-only detail view for a saved recipe (#1): the user's OWN photo, per-serving + total macros, the
/// ingredient list, and notes — plus log / edit / share. Reached by tapping a recipe in the book (which
/// used to jump straight into the editor). Recipe photos are the user's own pick — never an external
/// fetch — sealed and keyed by the recipe id.
struct RecipeDetailView: View {
    var store: FernletStore
    let recipe: RecipeDefinition
    var onEdit: () -> Void
    var onLog: (MealType) -> Void
    var onShare: () -> Void

    @State private var photo: UIImage?
    @State private var didLoadPhoto = false
    /// Calm inline notice when a photo couldn't be sealed to disk (fail-closed save returned false), so
    /// the UI never shows a false success that then vanishes on next open.
    @State private var photoNotice: String?
    /// Drives the shared destructive-confirmation for the photo trash chip, so deleting the recipe photo
    /// warns + audits like every other irreversible action instead of firing off a single tap.
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    /// Presents the web-import source page in an in-app Safari sheet (`SafariView`) rather than kicking
    /// the user out to external Safari — matching the recipe *edit* sheet's own source link.
    @State private var showingSafari = false

    /// Manual recipes resolve their structured ingredients through the catalog; web imports carry
    /// free-text ingredient lines and no structured `ingredients`, so their FoodCatalog resolution
    /// would be empty. Cached in a `.task(id:)` keyed on the ingredient ids (see below) so a pushed
    /// detail doesn't re-query on every store-driven body re-eval, yet re-resolves after an edit.
    @State private var resolvedItems: [UUID: FoodItem] = [:]

    /// Whole-recipe macros. Manual recipes resolve their ingredients through the catalog; web imports
    /// store per-serving macros under `webImport`, scaled back up here by the serving count.
    private var totals: MacroTotals {
        if let webImport = recipe.webImport {
            let servings = max(recipe.servings, 1)
            return MacroTotals(
                protein: webImport.macros.protein * servings,
                carbs: webImport.macros.carbs * servings,
                fat: webImport.macros.fat * servings
            )
        }
        return store.macroTotals(for: recipe)
    }

    /// Per-serving macros. Web imports already store per-serving values; manual recipes divide the
    /// resolved whole-recipe totals by servings.
    private var perServing: MacroTotals {
        if let webImport = recipe.webImport {
            return MacroTotals(
                protein: webImport.macros.protein,
                carbs: webImport.macros.carbs,
                fat: webImport.macros.fat
            )
        }
        let divisor = max(recipe.servings, 1)
        return MacroTotals(
            protein: Int((Double(totals.protein) / Double(divisor)).rounded()),
            carbs: Int((Double(totals.carbs) / Double(divisor)).rounded()),
            fat: Int((Double(totals.fat) / Double(divisor)).rounded())
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                photoSection
                if let photoNotice {
                    Text(photoNotice)
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(recipe.name)
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)
                    Text("\(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.slate)
                }
                macrosCard
                ingredientsCard
                if !recipe.notes.isEmpty { notesCard }
                actionsRow
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .background(Color.parchment)
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        // Resolve the manual recipe's structured ingredients (a FoodCatalog SQLite read) into a cached
        // dictionary, keyed on the ingredient ids so an edit-and-save under this detail (the editor
        // presents over a pushed detail) re-resolves — a once-guard here left added/swapped ingredients
        // rendering as a generic "Ingredient" until pop-and-repush. Unchanged ids don't re-query, so a
        // detail left on screen still doesn't hit SQLite on every store mutation. Web imports have no
        // structured ingredients — they render free-text lines instead.
        .task(id: recipe.ingredients.map(\.foodItemId)) {
            let ingredientIDs = recipe.ingredients.map(\.foodItemId)
            if !ingredientIDs.isEmpty {
                resolvedItems = Dictionary(
                    store.foodCatalog.items(ids: ingredientIDs).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }
        .task {
            // The photo load keeps its own once-guard — it's a separate cache from the ingredient
            // resolution and shouldn't re-decode when ingredients change.
            guard !didLoadPhoto else { return }
            didLoadPhoto = true
            if let data = store.recipePhotoData(for: recipe.id) {
                photo = await UIImage(data: data)?.byPreparingForDisplay()
            }
        }
        .destructiveConfirmation($pendingDestructiveAction)
        .sheet(isPresented: $showingSafari) {
            if let sourceURL = recipe.webImport?.sourceURL, sourceURL.isSafariPresentable {
                SafariView(url: sourceURL)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var photoSection: some View {
        if let photo {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                HStack(spacing: 8) {
                    PhotoCaptureControl(
                        onCameraCapture: { save($0) },
                        onLibraryPickData: { data, _ in saveLibraryData(data) },
                        onLibraryPickFailed: { photoNotice = "Couldn't save this photo to your private store. Please try again." },
                        allowsLibraryChoice: true
                    ) {
                        photoIconChip("camera.fill")
                    }
                    Button { confirmRemovePhoto() } label: { photoIconChip("trash") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("recipeDetail.deletePhoto")
                }
                .padding(8)
            }
        } else {
            PhotoCaptureControl(
                onCameraCapture: { save($0) },
                onLibraryPickData: { data, _ in saveLibraryData(data) },
                onLibraryPickFailed: { photoNotice = "Couldn't save this photo to your private store. Please try again." },
                allowsLibraryChoice: true
            ) {
                HStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.system(size: 16, weight: .semibold))
                    Text("Add a photo of this recipe").font(.fernlet(.label))
                }
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.moss.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                )
            }
            .accessibilityIdentifier("recipeDetail.addPhoto")
        }
    }

    private func photoIconChip(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.bark)
            .frame(width: 34, height: 34)
            .background(Color.cream.opacity(0.92), in: Circle())
            // The chip stays 34pt; the frame + contentShape expand only the tap target to Apple's
            // 44pt minimum — same pattern as the gym-location glyphs.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var macrosCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Per serving")
                HStack(spacing: 10) {
                    NutritionPill(title: "Protein", value: "\(perServing.protein)g")
                    NutritionPill(title: "Carbs", value: "\(perServing.carbs)g")
                    NutritionPill(title: "Fat", value: "\(perServing.fat)g")
                    if store.settings.showCalories {
                        NutritionPill(title: "Calories", value: "\(perServing.calories)")
                    }
                }
                Text("Whole recipe: P \(totals.protein)g · C \(totals.carbs)g · F \(totals.fat)g\(store.settings.showCalories ? " · \(totals.calories) cal" : "")")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
            }
        }
    }

    @ViewBuilder private var ingredientsCard: some View {
        if let webImport = recipe.webImport {
            // Web imports keep free-text ingredient lines (no structured food-item resolution) plus the
            // source URL as a provenance line where a manual recipe's resolved list would be.
            FernletCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Ingredients")
                    if webImport.ingredientLines.isEmpty {
                        Text("No ingredients listed.")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                    } else {
                        ForEach(webImport.ingredientLines, id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(Color.moss.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 7)
                                Text(line)
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                    .fernletWrappingText()
                            }
                        }
                    }
                    if let sourceURL = webImport.sourceURL {
                        if sourceURL.isSafariPresentable {
                            Button {
                                showingSafari = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "safari").font(.caption)
                                    Text(sourceURL.host() ?? sourceURL.absoluteString)
                                        .font(.fernlet(.labelSmall))
                                        .underline()
                                }
                                .foregroundStyle(Color.fern)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        } else {
                            // Non-web source (e.g. a file URL) can't open in Safari — show it as plain text.
                            Text(sourceURL.host() ?? sourceURL.absoluteString)
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                                .lineLimit(1)
                                .padding(.top, 2)
                        }
                    }
                }
            }
        } else {
            FernletCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Ingredients")
                    if recipe.ingredients.isEmpty {
                        Text("No ingredients listed.")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                    } else {
                        ForEach(recipe.ingredients) { ingredient in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(Color.moss.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 7)
                                Text(ingredientLine(ingredient))
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                    .fernletWrappingText()
                            }
                        }
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Notes")
                Text(recipe.notes)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
            }
        }
    }

    private var actionsRow: some View {
        VStack(spacing: 10) {
            Menu {
                ForEach(MealType.allCases) { mealType in
                    Button(mealType.rawValue) { onLog(mealType) }
                }
            } label: {
                Label("Log this recipe", systemImage: "fork.knife")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.cream)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityIdentifier("recipeDetail.log")
            HStack(spacing: 10) {
                Button { onEdit() } label: {
                    secondaryActionLabel("Edit", icon: "pencil")
                }
                .buttonStyle(.plain)
                Button { onShare() } label: {
                    secondaryActionLabel("Share", icon: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func secondaryActionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.fernlet(.label))
            .foregroundStyle(Color.moss)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    private func ingredientLine(_ ingredient: RecipeIngredient) -> String {
        let quantity = ingredient.quantity.formatted(.number.precision(.fractionLength(0...1)))
        let name = resolvedItems[ingredient.foodItemId]?.name ?? "Ingredient"
        return "\(quantity) \(ingredient.unit) · \(name)"
    }

    private func save(_ image: UIImage) {
        // saveRecipePhoto is fail-closed (false on jpeg/keychain/disk failure). Only reflect the photo
        // when it actually sealed to disk — otherwise a false success would show it, then it would vanish
        // on next open when the store read finds nothing.
        guard store.saveRecipePhoto(image, for: recipe.id) else {
            photoNotice = "Couldn't save this photo to your private store. Please try again."
            return
        }
        photo = image
        photoNotice = nil
    }

    /// Library pick: seal the picked `Data` through the bounded ImageIO downscale (no full-res bitmap),
    /// then show the just-sealed (≤1600px) bytes rather than re-decoding the full-resolution original.
    private func saveLibraryData(_ data: Data) {
        guard store.saveRecipePhoto(data: data, for: recipe.id) else {
            photoNotice = "Couldn't save this photo to your private store. Please try again."
            return
        }
        photoNotice = nil
        Task {
            if let stored = store.recipePhotoData(for: recipe.id) {
                photo = await UIImage(data: stored)?.byPreparingForDisplay()
            }
        }
    }

    private func confirmRemovePhoto() {
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Delete this photo?",
            message: "This removes your photo of this recipe from your device. Fernlet can't undo this.",
            confirmLabel: "Delete",
            auditEvent: "recipe.photo.deleteConfirmed",
            perform: { remove() }
        )
    }

    private func remove() {
        store.deleteRecipePhoto(for: recipe.id)
        photo = nil
        photoNotice = nil
    }
}
#endif

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
                .font(.fernlet(.label))
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
                        .font(.fernlet(.stat))
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
    var store: FernletStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Create recipe", subtitle: "Choose how to start.", subtitleFirst: false)

                VStack(spacing: 10) {
                    // Recipe creation is Import or Manual only. Nutrition-label scanning belongs to the
                    // barcode-not-found handoff (BarcodeNotFoundView, reached from the camera when a scanned
                    // barcode has no catalog match) — not as a standalone recipe-creation entry point.
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
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                Text(subtitle)
                    .font(.fernlet(.bodySmall))
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

private struct RecipeShareButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share recipe")
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Log recipe as meal")
    }
}

private struct WebImportedFoodRow: View {
    var foodItem: FoodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(foodItem.name)
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    Text(foodItem.brandSource ?? foodItem.sourceURL?.host() ?? "Saved web product")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                        .lineLimit(1)
                }
            }
            if let servingDescription = foodItem.servingDescription, !servingDescription.isEmpty {
                Text("Serving: \(servingDescription)")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
            }
            HStack(spacing: 14) {
                Text("P \(foodItem.macros.protein)g").foregroundStyle(Color.moss)
                Text("C \(foodItem.macros.carbs)g")
                Text("F \(foodItem.macros.fat)g")
            }
            .font(.fernlet(.stat))
            .foregroundStyle(Color.slate)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saved product \(foodItem.name)")
    }
}

struct RecipeBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @Binding var editingRecipe: RecipeDefinition?
    @Binding var editingSavedRecipe: RecipeDefinition?
    @State private var searchText = ""
    @State private var recipeShareDraft: ProximityRecipeShareDraft?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(title: "Recipe book", subtitle: "Recipes and saved products, A\u{2013}Z.", subtitleFirst: false)
                    NavigationLink {
                        RecipeCreationOptionsView(store: store)
                    } label: {
                        Label("Create recipe", systemImage: "plus")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.cream)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    TextField("Search recipes and products", text: $searchText)
                        .sheetTextInput()
                    let allManual = filteredManualRecipes
                    if !allManual.isEmpty {
                        FernletCard {
                            VStack(spacing: 0) {
                                ForEach(Array(allManual.enumerated()), id: \.element.id) { index, recipe in
                                    if index > 0 { FernletRowDivider() }
                                    HStack(spacing: 12) {
                                        #if canImport(UIKit)
                                        // Tapping a recipe now opens a read-only detail view (photo,
                                        // per-serving macros, ingredients, notes) rather than jumping
                                        // straight into the editor — the detail view offers edit/log/share.
                                        NavigationLink {
                                            RecipeDetailView(
                                                store: store,
                                                recipe: recipe,
                                                onEdit: { editingRecipe = recipe; dismiss() },
                                                onLog: { mealType in store.logRecipe(recipe, mealType: mealType); dismiss() },
                                                onShare: {
                                                    recipeShareDraft = ProximityRecipeShareDraft(
                                                        title: recipe.name,
                                                        shareText: store.recipeShareText(for: recipe),
                                                        payload: store.proximityRecipeSharePayload(for: recipe)
                                                    )
                                                }
                                            )
                                        } label: {
                                            RecipeRow(recipe: recipe, totals: store.macroTotals(for: recipe), showCalories: store.settings.showCalories)
                                        }
                                        .buttonStyle(.plain)
                                        #else
                                        Button { editingRecipe = recipe; dismiss() } label: {
                                            RecipeRow(recipe: recipe, totals: store.macroTotals(for: recipe), showCalories: store.settings.showCalories)
                                        }
                                        .buttonStyle(.plain)
                                        #endif
                                        RecipeMealTypeMenu { mealType in
                                            store.logRecipe(recipe, mealType: mealType)
                                            dismiss()
                                        }
                                        RecipeShareButton {
                                            recipeShareDraft = ProximityRecipeShareDraft(
                                                title: recipe.name,
                                                shareText: store.recipeShareText(for: recipe),
                                                payload: store.proximityRecipeSharePayload(for: recipe)
                                            )
                                        }
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
                                        #if canImport(UIKit)
                                        // Saved/web recipes push the same read-only detail as manual rows;
                                        // Edit opens their notes/delete sheet (no structured ingredients).
                                        NavigationLink {
                                            RecipeDetailView(
                                                store: store,
                                                recipe: recipe,
                                                onEdit: { editingSavedRecipe = recipe; dismiss() },
                                                onLog: { mealType in store.logSavedRecipe(recipe, mealType: mealType); dismiss() },
                                                onShare: {
                                                    recipeShareDraft = ProximityRecipeShareDraft(
                                                        title: recipe.name,
                                                        shareText: store.savedRecipeShareText(for: recipe),
                                                        payload: store.proximityRecipeSharePayload(for: recipe)
                                                    )
                                                }
                                            )
                                        } label: {
                                            SavedRecipeRow(recipe: recipe)
                                        }
                                        .buttonStyle(.plain)
                                        #else
                                        Button { editingSavedRecipe = recipe; dismiss() } label: {
                                            SavedRecipeRow(recipe: recipe)
                                        }
                                        .buttonStyle(.plain)
                                        #endif
                                        RecipeMealTypeMenu { mealType in
                                            store.logSavedRecipe(recipe, mealType: mealType)
                                            dismiss()
                                        }
                                        RecipeShareButton {
                                            recipeShareDraft = ProximityRecipeShareDraft(
                                                title: recipe.name,
                                                shareText: store.savedRecipeShareText(for: recipe),
                                                payload: store.proximityRecipeSharePayload(for: recipe)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    let allProducts = filteredWebImportedProducts
                    if !allProducts.isEmpty {
                        Text("Imported products")
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)
                        FernletCard {
                            VStack(spacing: 0) {
                                ForEach(Array(allProducts.enumerated()), id: \.element.id) { index, product in
                                    if index > 0 { FernletRowDivider() }
                                    HStack(spacing: 12) {
                                        WebImportedFoodRow(foodItem: product)
                                        RecipeMealTypeMenu { mealType in
                                            store.logWebImportedFoodProduct(product, mealType: mealType)
                                            dismiss()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if allManual.isEmpty && allSaved.isEmpty && allProducts.isEmpty && !searchText.isEmpty {
                        EmptyState(text: "No recipes or products match \u{201C}\(searchText)\u{201D}.")
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
        .sheet(item: $recipeShareDraft) { draft in
            ProximityRecipeShareSheet(draft: draft, manager: store.recipeShareManager, store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }

    private var filteredManualRecipes: [RecipeDefinition] {
        let sorted = store.recipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredSavedRecipes: [RecipeDefinition] {
        let sorted = store.savedRecipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredWebImportedProducts: [FoodItem] {
        let sorted = store.webImportedFoodItems.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.brandSource?.localizedCaseInsensitiveContains(searchText) == true
        }
    }
}

#if canImport(SafariServices)
import SafariServices
import FernletDomainModel

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIViewController {
        // Belt-and-braces: SFSafariViewController raises NSInvalidArgumentException for any non-http(s)
        // URL, so a malformed source link that slipped past the call-site guard falls back to an empty
        // controller instead of crashing the app. Presentation sites should still gate on
        // `URL.isSafariPresentable` so this branch is never actually reached.
        guard url.isSafariPresentable else { return UIViewController() }
        return SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#endif

extension URL {
    /// `SFSafariViewController` only accepts http/https URLs — any other scheme (`file:`, `javascript:`,
    /// `tel:`, or a schemeless string) raises `NSInvalidArgumentException` on presentation. Every source
    /// link must gate on this before it's made tappable or handed to `SafariView`.
    var isSafariPresentable: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

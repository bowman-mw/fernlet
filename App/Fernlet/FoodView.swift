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

/// The Food tab's root screen: today's meals grouped by meal type, macro totals against targets, a
/// cooking-resume card, pending AI retries, and the five most recent recipes.
///
/// Hosted by the app's tab switcher and backed entirely by ``FernletStore`` state. It routes every
/// food flow: the meal-log sheet (via the shared `FernletSheet` binding), the recipe editor sheets,
/// the recipe book, proximity recipe sharing, meal correction, and resuming an in-progress cooking
/// run that survives in the app group. On appear and on re-activation it reconciles the cooking run
/// from the app group so a step advance made from the Live Activity or Siri is picked up.
struct FoodView: View {
    var store: FernletStore
    /// Reports meals logged from THIS tab's own surfaces (the Planned-today card, recipe rows,
    /// the recipe detail and book) so the host can raise the post-log toast (FLOW-15). The host
    /// (ContentView) passes its `showMealLogNotification` here; the MealSheet keeps its separate
    /// `onLogged` wiring. Defaults to a no-op so construction sites compile before wiring.
    var onMealsLogged: ([Meal]) -> Void = { _ in }
    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @State private var editingRecipe: RecipeDefinition?
    @State private var editingSavedRecipe: RecipeDefinition?
    @State private var correctingMeal: Meal?
    @State private var recipeShareDraft: ProximityRecipeShareDraft?
    /// Presents the macro-target editor from the Food tab, so nudging a target doesn't mean leaving
    /// for Settings and hunting for "Goal & nutrition".
    @State private var showingNutritionTargets = false
    /// Drives the shared destructive confirmation for the two irreversible actions on this screen —
    /// removing a logged meal (and its sealed photo) and discarding an in-progress cooking run.
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    /// The recipe to re-open cooking mode on when the user taps the Food-root resume card (set only for
    /// an in-progress cooking run whose recipe still exists). Carries whether it's a saved/web recipe so
    /// the completion log routes to the right store method.
    @State private var cookingResume: CookingResumeTarget?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        foodLifecycle(foodSheets(foodRoot))
    }

    /// The Food root's scrolling content: header, macro card, the cooking-resume and pending-retry
    /// cards, today's meals grouped by type, and the recent-recipes preview.
    private var foodRoot: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerRow

                    macrosSection

                    plannedTodaySection
                    cookingResumeSection
                    pendingRetrySection
                    todayMealsSection
                    recentRecipesSection
                }
                .padding(20)
                .padding(.bottom, 24)
                .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .navigationTitle("")
        }
        // One keyboard "Done" for everything pushed inside the Food tab (the recipe book, its create
        // flow, the planner). A tab is not a sheet, so it gets none of `fernletSheetChrome`'s
        // accessories, and the numeric pads in there had no way to dismiss themselves. Declared once,
        // at the stack, so a pushed page never stacks a second Done on top of it.
        .keyboardDoneToolbar()
    }

    private var headerRow: some View {
        HStack(alignment: .top) {
            ScreenHeader(title: "Food", subtitle: "Eating enough, eating well.", identifier: "screen.food")
            Spacer()
            HeaderActionButton(title: "meal", systemImage: "plus") { activeSheet = .meal }
        }
        .padding(.top, 4)
    }

    /// Today's macro totals plus the way in to the targets they're measured against — the card used
    /// to name targets ("of 93g") with no path to change them short of hunting through Settings.
    ///
    /// `fiberIntake` is the same value Home passes: without it this card fell back to "Fiber target
    /// 37g" while Home read "Fiber 12g of 37g" for the very same day.
    private var macrosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacroCard(
                totals: store.macroTotals,
                targets: store.nutritionTargets,
                showCalories: store.settings.showCalories,
                fiberIntake: store.micronutrientTotals.fiber
            )
            HStack {
                Spacer()
                Button("Adjust targets") { showingNutritionTargets = true }
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .accessibilityIdentifier("food.adjustTargets")
            }
        }
    }

    /// The "Planned today" card (2026-08-21, FOOD-35): one Log pill per recipe planned on today,
    /// each logging against the meal slot it was planned for — a plan made on Sunday costs one tap
    /// on Wednesday. Renders ONLY on days with a plan: no empty state, no nagging.
    @ViewBuilder private var plannedTodaySection: some View {
        let items = plannedTodayItems
        if !items.isEmpty {
            FernletScrollSection("Planned today") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { FernletRowDivider() }
                        plannedTodayRow(item)
                    }
                }
            }
        }
    }

    /// One planned recipe: name over "slot · P n g", with the Log pill at the trailing edge.
    private func plannedTodayRow(_ item: PlannedTodayItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.recipe.name)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                plannedTodayDetailLine(item)
            }
            Spacer(minLength: 0)
            Button("Log") {
                logRecipe(item.recipe, mealType: item.entry.mealType, isSaved: item.isSaved)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityLabel("Log \(item.recipe.name)")
            .accessibilityIdentifier("food.plannedToday.log")
        }
        .padding(.vertical, 6)
    }

    /// The planned slot (omitted for a legacy slotless entry) beside the per-serving protein.
    private func plannedTodayDetailLine(_ item: PlannedTodayItem) -> some View {
        HStack(spacing: 6) {
            if let mealType = item.entry.mealType {
                Text(verbatim: mealType.displayName)
                Text(verbatim: "\u{00B7}")
            }
            Text("P \(plannedPerServingProtein(item))g")
        }
        .font(.fernlet(.labelSmall))
        .foregroundStyle(Color.slate)
    }

    /// Per-serving protein for a planned recipe: the import's own per-serving figure for a
    /// saved/web recipe, the resolved totals divided by yield for a manual one.
    private func plannedPerServingProtein(_ item: PlannedTodayItem) -> Int {
        if let webImport = item.recipe.webImport { return webImport.macros.protein }
        let divisor = max(item.recipe.servings, 1)
        return Int((Double(store.macroTotals(for: item.recipe).protein) / Double(divisor)).rounded())
    }

    /// Today's plan resolved against both recipe stores (merged typed+legacy read); a dangling id
    /// resolves to nothing and is dropped silently, exactly as the planner does.
    private var plannedTodayItems: [PlannedTodayItem] {
        store.day.plannedMealEntries.compactMap { entry in
            if let recipe = store.recipes.first(where: { $0.id == entry.recipeID }) {
                return PlannedTodayItem(entry: entry, recipe: recipe, isSaved: false)
            }
            if let saved = store.savedRecipes.first(where: { $0.id == entry.recipeID }) {
                return PlannedTodayItem(entry: entry, recipe: saved, isSaved: true)
            }
            return nil
        }
    }

    /// A cooking session in progress takes precedence — it stays resumable even after an app kill
    /// (the run survives in the app group though this view's state doesn't), so this is driven by
    /// `cookingRunState` alone. Mirrors the Move-root Resume card.
    @ViewBuilder private var cookingResumeSection: some View {
        if let run = store.cookingRunState, !run.isFinished {
            CookingResumeCard(
                recipeName: run.recipeName,
                stepNumber: run.stepNumber,
                stepCount: run.stepCount,
                onResume: { resumeCookingRun() },
                onDiscard: { confirmDiscardCookingRun(named: run.recipeName) }
            )
        }
    }

    /// Discarding a cook throws away where the user had got to (and clears the Live Activity), so it
    /// asks first — the Move tab's workout runner already does.
    private func confirmDiscardCookingRun(named recipeName: String) {
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Stop cooking \(recipeName)?",
            message: "Your place in the steps is forgotten and the Live Activity is cleared. The recipe itself is untouched.",
            confirmLabel: "Stop cooking",
            auditEvent: "cooking.run.discardConfirmed",
            perform: { store.endCookingRun() }
        )
    }

    /// Removing a logged meal takes its sealed photo with it and can't be undone, so it routes
    /// through the same confirmation as the recipe-photo delete rather than firing on one tap.
    private func confirmDeleteMeal(_ meal: Meal) {
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Remove this meal?",
            message: "\u{201C}\(meal.name)\u{201D} and any photo attached to it are removed from this device. Fernlet can't undo this.",
            confirmLabel: "Remove",
            auditEvent: "meal.deleteConfirmed",
            perform: { store.deleteMeal(meal) }
        )
    }

    /// Re-opens the in-progress run's recipe in cooking mode, or retires the run when the recipe it
    /// walks no longer exists.
    private func resumeCookingRun() {
        guard let recipe = store.recipeForActiveCookingRun(),
              let isSaved = store.activeCookingRunIsSavedRecipe() else {
            // The recipe was deleted while the run outlived it — nothing to resume, so clear the run
            // + any orphan Live Activity.
            store.endCookingRun()
            return
        }
        cookingResume = CookingResumeTarget(recipe: recipe, isSaved: isSaved)
    }

    @ViewBuilder private var pendingRetrySection: some View {
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
    }

    @ViewBuilder private var todayMealsSection: some View {
        if store.day.meals.isEmpty {
            FernletScrollSection("Today") {
                EmptyState(text: "Nothing yet. Describe a meal when you are ready.")
            }
        } else {
            // Each meal type is its OWN section card, titled by a distinct small-caps
            // SectionLabel (not the meal-name font) — separate boxes rather than one long list.
            ForEach(mealsByType) { group in
                // `displayName`, not `rawValue`: the rawValue is the persisted/prompt token and
                // was being rendered as a user-visible heading. `verbatim:` because the domain
                // property has already resolved its own localized string.
                FernletScrollSection(verbatim: group.type.displayName) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(group.meals.enumerated()), id: \.element.id) { rowIndex, meal in
                            MealRow(
                                meal: meal,
                                showCalories: store.settings.showCalories,
                                onDelete: { confirmDeleteMeal(meal) },
                                onCorrect: { correctingMeal = meal },
                                loadPhotoData: meal.photoID.map { id in { store.mealPhotoData(for: id) } },
                                hasPhotoSealedFile: meal.photoID.map { id in { store.mealPhotoHasSealedFile(for: id) } },
                                showsMealTypeBadge: false
                            )
                            if rowIndex < group.meals.count - 1 {
                                FernletRowDivider()
                            }
                        }
                        mealTypeSubtotal(group.meals, type: group.type)
                    }
                }
            }
        }
    }

    private var recentRecipesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Recipes")
                Spacer()
                // Pushed, not presented: book → detail → editor then lives in ONE stack, so saving an
                // edit started from the book returns to that recipe instead of dropping to Food root.
                NavigationLink {
                    RecipeBookSheet(
                        store: store,
                        editingRecipe: $editingRecipe,
                        editingSavedRecipe: $editingSavedRecipe,
                        isEmbeddedInNavigationStack: true,
                        onMealsLogged: onMealsLogged
                    )
                } label: {
                    Text("Recipe book")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                }
                .buttonStyle(.plain)
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
                            recentRecipeRow(preview)
                        }
                    }
                }
            }
        }
    }

    /// One recent-recipe row, dispatching a manual recipe and a saved/web recipe to the same layout
    /// with the store half (`isSaved`) that owns it.
    @ViewBuilder private func recentRecipeRow(_ preview: RecentRecipePreview) -> some View {
        switch preview {
        case .local(let recipe):
            recentRecipeCard(recipe: recipe, isSaved: false) {
                RecipeRow(recipe: recipe, totals: store.macroTotals(for: recipe), showCalories: store.settings.showCalories)
            }
        case .saved(let recipe):
            // Same trailing-controls layout as `.local` — the two row types interleave in one list
            // and must not disagree.
            recentRecipeCard(recipe: recipe, isSaved: true) {
                SavedRecipeRow(recipe: recipe)
            }
        }
    }

    /// The shared recent-recipe row: the tappable summary (pushing the read-only detail) above its
    /// own trailing control line.
    ///
    /// Controls sit on their own trailing line rather than beside the row. In one HStack they claimed
    /// ~88pt of the card, so the row's own trailing edge — and the servings label right-aligned to it —
    /// stopped ~65% across and read as centered. Costs row height; the smaller title above pays some
    /// of it back.
    private func recentRecipeCard<Label: View>(
        recipe: RecipeDefinition,
        isSaved: Bool,
        @ViewBuilder label: () -> Label
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            #if canImport(UIKit)
            // Tapping a recipe pushes the read-only detail (photo, per-serving macros, ingredients,
            // notes); the editor is reachable only via the detail's Edit button — and for a saved/web
            // recipe that Edit opens its notes/delete sheet (no structured ingredients to edit).
            NavigationLink {
                recipeDetail(for: recipe, isSaved: isSaved)
            } label: {
                label()
            }
            .buttonStyle(.plain)
            #else
            Button { beginEditing(recipe, isSaved: isSaved) } label: {
                label()
            }
            .buttonStyle(.plain)
            #endif
            RecipeRowLogControl(onLog: { mealType in
                logRecipe(recipe, mealType: mealType, isSaved: isSaved)
            }) {
                RecipeShareButton {
                    recipeShareDraft = shareDraft(for: recipe, isSaved: isSaved)
                }
            }
        }
    }

    #if canImport(UIKit)
    /// The read-only detail for a recent-recipe row, wired to the store half the row came from.
    private func recipeDetail(for recipe: RecipeDefinition, isSaved: Bool) -> some View {
        RecipeDetailView(
            store: store,
            recipe: recipe,
            onEdit: { beginEditing(recipe, isSaved: isSaved) },
            onSaveFork: { fork in
                if isSaved { store.addForkedSavedRecipe(fork) } else { store.addForkedRecipe(fork) }
            },
            onLog: { current, mealType in logRecipe(current, mealType: mealType, isSaved: isSaved) },
            onShare: { current in recipeShareDraft = shareDraft(for: current, isSaved: isSaved) },
            onCookLog: { current, mealType, day in
                if isSaved {
                    store.logSavedRecipe(current, mealType: mealType, date: day)
                } else {
                    store.logRecipe(current, mealType: mealType, date: day)
                }
            }
        )
    }
    #endif

    /// Routes an edit request to the sheet that owns that recipe's store half.
    private func beginEditing(_ recipe: RecipeDefinition, isSaved: Bool) {
        if isSaved { editingSavedRecipe = recipe } else { editingRecipe = recipe }
    }

    /// Logs a recipe through the store method that matches its half (manual vs saved/web) and
    /// reports the committed meal to the host's toast path (`onMealsLogged`, FLOW-15). A nil
    /// `mealType` (a slotless legacy plan entry) falls back to the store's by-time "Auto" rule.
    private func logRecipe(_ recipe: RecipeDefinition, mealType: MealType?, isSaved: Bool) {
        let meal: Meal
        if isSaved {
            meal = store.logSavedRecipe(recipe, mealType: mealType)
        } else {
            meal = store.logRecipe(recipe, mealType: mealType)
        }
        onMealsLogged([meal])
    }

    /// The proximity share draft for a recipe, using its half's share-text builder.
    private func shareDraft(for recipe: RecipeDefinition, isSaved: Bool) -> ProximityRecipeShareDraft {
        ProximityRecipeShareDraft(
            title: recipe.name,
            shareText: isSaved ? store.savedRecipeShareText(for: recipe) : store.recipeShareText(for: recipe),
            payload: store.proximityRecipeSharePayload(for: recipe)
        )
    }

    /// The Food root's five editor/share sheets, in their original application order.
    ///
    /// The four entry sheets go through `fernletSheetChrome` for the same reason the routed sheets do:
    /// a sheet is its own presentation, so it inherits neither the tab tree's moss tint nor a keyboard
    /// "Done" accessory unless it asks for them.
    private func foodSheets<V: View>(_ content: V) -> some View {
        content
            .sheet(item: $editingRecipe) { recipe in
                RecipeSheet(store: store, recipe: recipe)
                    .fernletSheetChrome(anchor: "sheet.recipeEditor", detents: [.large])
            }
            .sheet(item: $editingSavedRecipe) { recipe in
                SavedRecipeNotesSheet(store: store, recipe: recipe)
                    .fernletSheetChrome(anchor: "sheet.savedRecipeNotes", detents: [.medium, .large])
            }
            .sheet(item: $correctingMeal) { meal in
                // Full height only: at .medium the "Matched items" editor — the thing the user opened
                // this sheet to fix — sat clipped behind the Save pill until they dragged it up.
                MealCorrectionSheet(store: store, meal: meal)
                    .fernletSheetChrome(anchor: "sheet.mealCorrection", detents: [.large])
            }
            .sheet(isPresented: $showingNutritionTargets) {
                NutritionTargetsSheet(store: store)
                    .fernletSheetChrome(anchor: "sheet.nutritionTargets", detents: [.medium, .large])
            }
            .sheet(item: $recipeShareDraft) { draft in
                ProximityRecipeShareSheet(draft: draft, manager: store.recipeShareManager, store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
            }
    }

    /// Appear/foreground reconciliation plus the cooking-mode cover, applied after the sheets so the
    /// modifier order matches what shipped.
    private func foodLifecycle<V: View>(_ content: V) -> some View {
        content
            .destructiveConfirmation($pendingDestructiveAction)
            .onAppear {
                store.markLaunchScreenDismissed()
                store.ensureBundledFoodItemsSeeded()
                // Surface a resume card / retire an orphan cooking activity after a cold launch, and
                // pick up any step advance made entirely from the Live Activity / Siri.
                store.reconcileCookingRunFromAppGroup()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                store.reconcileCookingRunFromAppGroup()
            }
            #if canImport(UIKit)
            .fullScreenCover(item: $cookingResume) { target in
                CookingModeView(
                    store: store,
                    recipe: target.recipe,
                    resuming: true,
                    onLogToDay: { mealType, day in
                        if target.isSaved {
                            store.logSavedRecipe(target.recipe, mealType: mealType, date: day)
                        } else {
                            store.logRecipe(target.recipe, mealType: mealType, date: day)
                        }
                    }
                )
            }
            #endif
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

    /// A quiet per-section macro footer inside each meal-type card, shown only when the section has
    /// more than one meal — under a single row the unlabelled "P 28g" simply repeated that row's own
    /// protein directly beneath it. When it does show it says whose total it is.
    @ViewBuilder private func mealTypeSubtotal(_ meals: [Meal], type: MealType) -> some View {
        if meals.count > 1 {
            let protein = meals.reduce(0) { $0 + $1.macros.protein }
            let calories = meals.reduce(0) { $0 + $1.calories }
            HStack(spacing: 10) {
                Text(verbatim: "\(type.displayName) total")
                    .foregroundStyle(Color.slate)
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
}

/// One row of the Food root's "Planned today" card: a plan entry resolved to its live recipe,
/// with the store half (`isSaved`) that owns it so the Log pill routes to the right log method.
///
/// Identifiable by the plan entry's recipe id (the plan holds at most one entry per recipe).
private struct PlannedTodayItem: Identifiable {
    let entry: PlannedMealEntry
    let recipe: RecipeDefinition
    let isSaved: Bool
    var id: UUID { entry.recipeID }
}

/// One meal-type group in the "Today" card.
///
/// Identifiable by its `MealType` so `ForEach` can key on it without an index (each type appears at
/// most once in `mealsByType`).
private struct MealTypeGroup: Identifiable {
    let type: MealType
    let meals: [Meal]
    var id: MealType { type }
}

/// A row in the Food root's "Recipes" preview — either a manual/local recipe or a saved/web recipe,
/// so the two stores can interleave in one recency-sorted list.
///
/// The `id` prefixes the recipe id with its store so a recipe present in both stores can't collide;
/// `addedAt` drives the newest-first sort feeding the five-row cap.
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

/// The target for the Food-root cooking resume cover: the recipe to re-open plus whether it's a
/// saved/web recipe (routes the completion log to `logSavedRecipe` vs `logRecipe`).
///
/// Identifiable by the recipe id so `fullScreenCover(item:)` keys on it.
private struct CookingResumeTarget: Identifiable {
    let recipe: RecipeDefinition
    let isSaved: Bool
    var id: UUID { recipe.id }
}

/// The Food-root "Cooking in progress" card — the cooking analogue of `ResumeWorkoutCard`.
///
/// Appears whenever a cooking run survives in the app group (including after an app kill), offering
/// Resume (re-open the walker at the saved step) and Discard (drop the run + any orphan Live
/// Activity). The a11y ids live on the buttons, not a wrapping container, so they aren't overridden.
private struct CookingResumeCard: View {
    let recipeName: String
    let stepNumber: Int
    let stepCount: Int
    var onResume: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.moss)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cooking in progress")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        Text("\(recipeName) — step \(stepNumber) of \(stepCount). Pick up where you left off.")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    Button(action: onDiscard) {
                        Text("Discard")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.slate)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.bark.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cooking.discard")

                    Button(action: onResume) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.body.weight(.semibold))
                            Text("Resume")
                                .font(.fernlet(.label))
                        }
                        .foregroundStyle(Color.onMoss)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cooking.resume")
                }
            }
        }
    }
}

/// The Food tab's way in to ``NutritionTargetsEditor`` — the same card Settings shows, wrapped in a
/// sheet under the pinned ``SheetHeader``. The editor commits live, so Done sits top-right and is
/// the whole exit (2026-08-21 template) — no bottom bar.
///
/// The macro card names targets the user can't reach from here otherwise; this keeps "nudge a target"
/// a tap away from the numbers it changes, without duplicating the editor.
private struct NutritionTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Nutrition targets", onDone: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    NutritionTargetsEditor(store: store)
                }
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background(Color.parchment)
    }
}

/// A small labeled stat tile (title over value) for macro and calorie figures.
///
/// Shared by the recipe detail's per-serving card and the web-product review sheet so nutrition
/// numbers render identically wherever they appear.
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

/// The "Import recipe" sheet: paste a Fernlet recipe share (text payload) or pull a recipe URL from
/// the pasteboard.
///
/// Text imports decode through `FernletStore.importRecipe(from:)` (the ``RecipeShareCodec`` payload);
/// the Paste-URL button runs `RecipeWebImporter` and lands the result in the saved-recipe store.
/// Reached from ``RecipeCreationOptionsView``.
private struct RecipeImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    /// Called instead of `dismiss()` once a recipe has actually been imported, so the host can pop
    /// past the create-recipe chooser to the book rather than leaving the user on it. `nil` keeps the
    /// plain one-level dismiss.
    var onSaved: ((String) -> Void)?
    @State private var importText = ""
    @State private var notice: String?
    @State private var isImportingURL = false
    /// The already-saved recipe a pasted URL matched (normalized source-URL match) — the
    /// zero-network duplicate skip (owner decision 2026-08-09). Non-nil drives the
    /// "Already in your book — Open" card instead of any fetch.
    @State private var existingRecipe: RecipeDefinition?
    /// Pushes the matched recipe's read-only detail (this sheet lives inside the recipe book's
    /// `NavigationStack`, so "Open" is an ordinary push).
    @State private var showingExistingRecipe = false
    /// Backs the pushed detail's Edit button — presents the saved-recipe notes sheet locally,
    /// since this sheet has no access to `FoodView`'s editing bindings.
    @State private var editingSavedRecipe: RecipeDefinition?
    /// Backs the pushed detail's Share button — the proximity recipe-share sheet, wired the same
    /// way ``RecipeBookSheet`` does it.
    @State private var recipeShareDraft: ProximityRecipeShareDraft?

    var body: some View {
        importPresentations(importContent)
    }

    private var importContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Import recipe")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    pasteURLButton

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

                    #if canImport(UIKit)
                    if let existingRecipe {
                        alreadySavedCard(for: existingRecipe)
                    }
                    #endif
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Import", disabled: importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                importSharedText()
            }
        }
        .background(Color.parchment)
    }

    /// The pasteboard-URL import affordance; disabled (and relabelled) while a fetch is in flight so
    /// only one import task can ever be in flight.
    private var pasteURLButton: some View {
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
    }

    /// Leaves the import screen after a successful import: all the way back to the book when the host
    /// asked for that, otherwise the plain dismiss.
    private func finishImport(named recipeName: String) {
        if let onSaved {
            onSaved(recipeName)
        } else {
            dismiss()
        }
    }

    /// Decodes the pasted share text through the store, dismissing on success and surfacing the
    /// import error's own message otherwise.
    private func importSharedText() {
        do {
            let imported = try store.importRecipe(from: importText)
            finishImport(named: imported.name)
        } catch let error as RecipeImportError {
            notice = error.message
        } catch {
            notice = RecipeImportError.invalidPayload.message
        }
    }

    /// The pushed detail for a matched already-saved recipe plus this sheet's own local editor/share
    /// sheets, in their original application order.
    private func importPresentations<V: View>(_ content: V) -> some View {
        content
        #if canImport(UIKit)
            .navigationDestination(isPresented: $showingExistingRecipe) {
                if let existingRecipe {
                    existingRecipeDetail(existingRecipe)
                }
            }
            .sheet(item: $editingSavedRecipe) { recipe in
                SavedRecipeNotesSheet(store: store, recipe: recipe)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $recipeShareDraft) { draft in
                ProximityRecipeShareSheet(draft: draft, manager: store.recipeShareManager, store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
            }
        #endif
    }

    #if canImport(UIKit)
    /// The zero-network duplicate state: names the matched recipe and offers to open its detail —
    /// no fetch happened and none will (refreshing is the detail's own "Re-import from source").
    private func alreadySavedCard(for recipe: RecipeDefinition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Already in your recipe book", systemImage: "checkmark.circle")
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
            Text(recipe.name)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Button {
                showingExistingRecipe = true
            } label: {
                Label("Open saved recipe", systemImage: "book")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.cream)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recipeImport.openExisting")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.moss.opacity(0.35), lineWidth: 1.5))
    }

    /// The matched recipe's read-only detail, wired with local closures (edit → local notes sheet,
    /// share → local proximity draft) because this sheet has no access to `FoodView`'s bindings.
    private func existingRecipeDetail(_ recipe: RecipeDefinition) -> some View {
        RecipeDetailView(
            store: store,
            recipe: recipe,
            onEdit: { editingSavedRecipe = recipe },
            onSaveFork: { store.addForkedSavedRecipe($0) },
            onLog: { current, mealType in store.logSavedRecipe(current, mealType: mealType) },
            onShare: { current in
                recipeShareDraft = ProximityRecipeShareDraft(
                    title: current.name,
                    shareText: store.savedRecipeShareText(for: current),
                    payload: store.proximityRecipeSharePayload(for: current)
                )
            },
            onCookLog: { current, mealType, day in store.logSavedRecipe(current, mealType: mealType, date: day) }
        )
    }
    #endif

    private func importFromPasteboardURL() {
        #if canImport(UIKit)
        let pastedString = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: pastedString), url.scheme == "http" || url.scheme == "https" else {
            notice = RecipeWebImportError.invalidURL.localizedDescription
            return
        }

        // Zero-network duplicate skip (owner decision 2026-08-09): a URL already in the book does
        // no fetching at all — surface the saved recipe instead. Refreshing it is the detail
        // page's explicit "Re-import from source" affordance.
        if let existing = store.savedRecipe(matchingSourceURL: url) {
            existingRecipe = existing
            notice = "\u{201C}\(existing.name)\u{201D} was already imported from this page."
            return
        }
        existingRecipe = nil

        isImportingURL = true
        notice = "Fetching recipe..."

        Task {
            do {
                let importedRecipe = try await RecipeWebImporter.importRecipe(from: url, catalog: store.foodCatalog, aiEnabled: store.settings.aiStatus != .off, userInvoked: true, gate: store.aiGate)
                let recipe = RecipeDefinition(importedRecipe: importedRecipe)
                store.addSavedRecipe(recipe)
                // Foreground import path (owner decision 2026-08-09): the user is present, so fetch
                // the page's main picture now as the recipe's default photo. Runs as its own task so
                // a slow image host never delays the import feedback — and an image failure never
                // fails the import (the store marks the one attempt either way).
                Task { await store.fetchRecipeWebImageIfNeeded(for: recipe) }
                notice = "\(importedRecipe.name) added to your recipes."
                isImportingURL = false
                do {
                    // A beat so the "added to your recipes" line can be read before the sheet goes.
                    try await Task.sleep(for: .seconds(1.2))
                } catch {
                    // Cancelled: the presenting sheet is already being torn down, so there is
                    // nothing left to dismiss.
                    return
                }
                finishImport(named: importedRecipe.name)
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

/// A list row for a saved/web-imported recipe: name, source host, notes, a preview of its free-text
/// ingredient lines, and per-serving macros when the import carried them.
///
/// Interleaves with ``RecipeRow`` in the Food root's recipe preview and in the recipe book, so its
/// title typography deliberately matches that row's.
private struct SavedRecipeRow: View {
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

/// The edit sheet for a saved/web-imported recipe — notes editing plus delete.
///
/// Web imports carry free-text ingredient lines and no structured ingredients, so unlike
/// ``RecipeSheet`` there is nothing structural to edit: ingredients and macros render read-only, the
/// source link opens in an in-app Safari sheet, and the pinned ``SheetHeader``'s Done (top-right,
/// the whole exit — 2026-08-21 template, no bottom bar) commits the notes via
/// `FernletStore.updateSavedRecipeNotes`. The header title is the recipe's name — runtime text, so
/// it renders through the `Text(verbatim:)` initializer.
struct SavedRecipeNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @State private var recipe: RecipeDefinition
    @State private var showingSafari = false
    /// Drives the confirmation in front of "Delete recipe" — it used to delete and dismiss on a
    /// single tap, with no way back.
    @State private var pendingDestructiveAction: DestructiveConfirmation?

    init(store: FernletStore, recipe: RecipeDefinition) {
        self.store = store
        // Re-resolve the LIVE row by id: the caller's copy can be stale (captured before a
        // re-import replaced the definition, or before a web-image suppression was stamped).
        // Done then merges ONLY the edited notes back into the then-current row (see
        // `FernletStore.updateSavedRecipeNotes`), so neither pre-open nor while-open store
        // updates are ever clobbered by editing notes.
        _recipe = State(initialValue: store.savedRecipes.first(where: { $0.id == recipe.id }) ?? recipe)
    }

    private var webImport: RecipeWebImport? { recipe.webImport }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: Text(verbatim: recipe.name), onDone: {
                // Merge only the field this sheet edits into the LIVE row — writing the whole
                // at-open snapshot back would revert store updates that landed while the sheet
                // was up (e.g. the image fetch stamping a suppression, or a cloud refresh).
                store.updateSavedRecipeNotes(recipe.notes, forRecipeID: recipe.id)
                dismiss()
            })
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sourceLinkSection

                    macrosCard

                    SheetField("Notes") {
                        SheetTextEditor(text: $recipe.notes, placeholder: "cooking notes, substitutions, tips", minHeight: 120)
                    }

                    ingredientLinesCard

                    deleteButton
                }
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background(Color.parchment)
        .destructiveConfirmation($pendingDestructiveAction)
        // Warm the DNS/TLS connection to the source host while the sheet is up, so tapping the
        // link opens near-instantly (owner decision 2026-08-09; documented in
        // Docs/No-Tracking-Wall.md §4b).
        .prewarmsSourceLinkConnection(for: webImport)
        .sheet(isPresented: $showingSafari) {
            if let sourceURL = webImport?.sourceURL, sourceURL.isSafariPresentable {
                SafariView(url: sourceURL)
                    .ignoresSafeArea()
            }
        }
    }

    /// The web import's source-link row, when there is one. The recipe's name itself lives in the
    /// pinned ``SheetHeader`` (2026-08-21 template), not in the scroll content.
    @ViewBuilder private var sourceLinkSection: some View {
        if let sourceURL = webImport?.sourceURL {
            SourceLinkRow(url: sourceURL) { showingSafari = true }
        }
    }

    @ViewBuilder private var macrosCard: some View {
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
    }

    @ViewBuilder private var ingredientLinesCard: some View {
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
    }

    /// Full-width destructive action in the canonical ``DestructiveCardButtonStyle`` token
    /// (2026-08-21 template, artboard 2b) — the tap still only raises the confirmation.
    private var deleteButton: some View {
        Button(role: .destructive) {
            pendingDestructiveAction = DestructiveConfirmation(
                title: "Delete \u{201C}\(recipe.name)\u{201D}?",
                message: "The saved recipe, its notes and any photo of it are removed from this device. Meals you already logged from it stay in your diary. Fernlet can't undo this.",
                confirmLabel: "Delete",
                auditEvent: "savedRecipe.deleteConfirmed",
                perform: {
                    store.deleteSavedRecipe(recipe)
                    dismiss()
                }
            )
        } label: {
            Label("Delete recipe", systemImage: "trash")
        }
        .buttonStyle(DestructiveCardButtonStyle())
    }
}

/// A web-imported recipe's source-link line: a Safari button when the URL can open in the in-app
/// browser, calm non-tappable host text when it can't.
///
/// One definition shared by ``SavedRecipeNotesSheet`` and ``RecipeDetailView``'s ingredients card —
/// the two used to carry byte-identical copies of the branch. Call sites gate on a non-nil source
/// URL themselves, so a recipe without one contributes no row (and no stack spacing).
private struct SourceLinkRow: View {
    /// The recipe's source URL.
    let url: URL
    /// Invoked when a Safari-presentable link is tapped (the owner presents its own Safari sheet).
    let onOpen: () -> Void

    var body: some View {
        if url.isSafariPresentable {
            Button(action: onOpen) {
                HStack(spacing: 4) {
                    Image(systemName: "safari")
                        .font(.caption)
                    Text(url.host() ?? url.absoluteString)
                        .font(.fernlet(.labelSmall))
                        .underline()
                }
                // Moss rather than fern: at 11pt on cream, fern measured under 3:1.
                .foregroundStyle(Color.moss)
            }
            .buttonStyle(.plain)
        } else {
            // A non-web source link (e.g. a file URL) can't open in an in-app Safari sheet, so
            // it's shown as calm, non-tappable text rather than a dead button.
            Text(url.host() ?? url.absoluteString)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .lineLimit(1)
        }
    }
}

/// Navigation destinations inside ``MealSheet``'s log-meal `NavigationStack`.
///
/// Covers the barcode scanner, the embedded recipe editor, web product import/search, and the
/// auto-router landings for a captured photo. `Hashable` so the cases can drive
/// `navigationDestination(for:)` path values.
private enum MealFlowDestination: Hashable {
    case scanBarcode
    case recipeSearch
    case productPageImport
    case productSearch(String)
    /// Auto-router landings for a captured photo (Food Capture mockup §2b–2c): a barcode the router
    /// already read, and a nutrition label it already parsed. Both hand off to existing create/log
    /// flows via `BarcodePayloadResolveView` / `BarcodeNotFoundView(prefilledScan:)`.
    case captureBarcode(String)
    case captureLabel(NutritionLabelResult)
}

/// The manual recipe editor: name, notes, catalog-bound ingredients, per-serving totals, servings,
/// and the F5 ordered cooking-step list.
///
/// Creates a new recipe (Save / Log & save) or edits an existing one, persisting through
/// `FernletStore.addRecipe`/`updateRecipe`. It can embed in a parent `NavigationStack`
/// (`isEmbeddedInNavigationStack`) or wrap its own, and can open straight into the nutrition-label
/// scanner (`startsWithScanner`). A barcode scan appends a resolved catalog item as an ingredient
/// through the same binding path as a search pick.
struct RecipeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    private var editingRecipe: RecipeDefinition?
    private var isEmbeddedInNavigationStack: Bool
    private var startsWithScanner: Bool
    /// Called instead of `dismiss()` after a successful save when this editor is PUSHED inside a host
    /// stack that wants to pop further than one level (the recipe book's create flow lands the user
    /// back on the book, not on the "Import / Manual entry" chooser they passed through). `nil` keeps
    /// the plain dismiss the sheet and the meal-flow push both want.
    private var onSaved: ((String) -> Void)?
    @State private var name = ""
    @State private var servings = 1
    @State private var notes = ""
    @State private var ingredients: [ManualRecipeIngredientInput] = []
    /// F5 manual step entry. Held as `[RecipeStep]` directly (Identifiable + mutable `text`), sanitized
    /// on save by `RecipeStepSanitizer` (drops blanks). Empty means "no cooking steps".
    @State private var steps: [RecipeStep] = []
    @State private var expandedId: UUID?
    @State private var scannerPath = false
    @State private var didStartScanner = false
    @State private var showingBarcodeScanner = false
    /// Drives the confirmation in front of "Delete recipe" — deleting and dismissing on one tap was
    /// the only unguarded way to lose a whole recipe.
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    /// The at-open draft, so the sheet can tell "nothing typed yet" from "unsaved edits" and only
    /// warn about the second (see ``isDirty``).
    private let originalDraft: RecipeDraftSnapshot

    init(
        store: FernletStore,
        recipe: RecipeDefinition? = nil,
        isEmbeddedInNavigationStack: Bool = false,
        startsWithScanner: Bool = false,
        onSaved: ((String) -> Void)? = nil
    ) {
        self.store = store
        self.editingRecipe = recipe
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
        self.startsWithScanner = startsWithScanner
        self.onSaved = onSaved
        if let recipe {
            let loadedIngredients = Self.inputs(for: recipe, foodItems: store.foodCatalog.items(forRecipe: recipe))
            _name = State(initialValue: recipe.name)
            _servings = State(initialValue: recipe.servings)
            _notes = State(initialValue: recipe.notes)
            _ingredients = State(initialValue: loadedIngredients)
            _steps = State(initialValue: recipe.steps ?? [])
            // Editing opens on the WHOLE recipe: expanding the first ingredient's search editor pushed
            // the list, servings and steps below the fold, so the user had to tap Done before they
            // could see what they came to change. Blank rows still auto-expand (see `ingredientsSection`).
            _expandedId = State(initialValue: nil)
            originalDraft = RecipeDraftSnapshot(
                name: recipe.name,
                servings: recipe.servings,
                notes: recipe.notes,
                ingredients: loadedIngredients,
                steps: recipe.steps ?? []
            )
        } else {
            let first = ManualRecipeIngredientInput()
            _ingredients = State(initialValue: [first])
            _expandedId = State(initialValue: first.id)
            originalDraft = RecipeDraftSnapshot(
                name: "",
                servings: 1,
                notes: "",
                ingredients: [first],
                steps: []
            )
        }
    }

    /// Whether the editor holds edits a swipe-away would silently throw out.
    private var isDirty: Bool {
        originalDraft != RecipeDraftSnapshot(
            name: name, servings: servings, notes: notes, ingredients: ingredients, steps: steps
        )
    }

    @ViewBuilder
    var body: some View {
        if isEmbeddedInNavigationStack {
            recipeContent
        } else {
            NavigationStack {
                recipeContent
            }
            // Presented as a sheet: a swipe-down used to discard a typed recipe with no warning.
            // The guard also renders the pinned ``SheetHeader`` (Cancel + title) — the sheet's
            // title lives there, not in the scroll content (2026-08-21 template).
            .fernletDraftGuard(isDirty: isDirty, title: editorTitle) { dismiss() }
        }
    }

    private var recipeContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Pushed pages title themselves in the nav bar (see `.navigationTitle` below);
                    // the sheet presentation titles itself in the draft guard's pinned header.
                    SheetField("Recipe name") {
                        TextField("black bean bowls", text: $name)
                            .submitLabel(.done)
                            .sheetTextInput()
                    }

                    SheetField("Notes") {
                        SheetTextEditor(text: $notes, placeholder: "prep notes, substitutions, storage", minHeight: 82)
                    }

                    ingredientsSection

                    perServingCard

                    servingsField

                    stepsSection

                    deleteRecipeButton
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            saveBar
        }
        .background(Color.parchment)
        // Belt and braces for the unit menu and the steppers: this editor is reached from a routed
        // sheet, its own sheet, and two pushed stacks, and an untinted system control renders Apple
        // blue in any presentation that isn't already tinted. (The keyboard "Done" is NOT declared
        // here — its host does that once, so a pushed editor can't stack a second one.)
        .tint(Color.moss)
        .navigationTitle(isEmbeddedInNavigationStack ? editorTitle : "")
        .navigationBarTitleDisplayMode(.inline)
        .destructiveConfirmation($pendingDestructiveAction)
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

    private var ingredientsSection: some View {
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
                // Stacks at accessibility sizes: side by side, "Add ingredient" / "Scan barcode"
                // squeezed to the edge and broke mid-word.
                AdaptiveStack(spacing: 8) {
                    Button {
                        addIngredient()
                    } label: {
                        ingredientActionLabel("Add ingredient", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    // R3: the list is bounded where it grows — the same ceiling the paste decoder uses.
                    .disabled(ingredients.count >= RecipeLimits.maxIngredients)

                    #if canImport(UIKit)
                    Button {
                        showingBarcodeScanner = true
                    } label: {
                        ingredientActionLabel("Scan barcode", systemImage: "barcode.viewfinder")
                    }
                    .buttonStyle(.plain)
                    #endif
                }
            }
        }
    }

    /// The shared cream-card label used by both ingredient action buttons (their styling is identical).
    private func ingredientActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.fernlet(.label))
            .foregroundStyle(Color.moss)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    /// Appends one blank ingredient row, refusing past ``RecipeLimits/maxIngredients`` (R3: the cap
    /// is enforced where the input enters, not only on the button's disabled state).
    private func addIngredient() {
        guard ingredients.count < RecipeLimits.maxIngredients else { return }
        let new = ManualRecipeIngredientInput()
        ingredients.append(new)
        expandedId = new.id
    }

    private var perServingCard: some View {
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
    }

    private var servingsField: some View {
        SheetField("Servings") {
            Stepper("\(servings)", value: $servings, in: 1...RecipeLimits.maxServings)
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }

    /// Full-width destructive action in the canonical ``DestructiveCardButtonStyle`` token
    /// (2026-08-21 template, artboard 2b); edit mode only, and the tap still only raises the
    /// confirmation.
    @ViewBuilder private var deleteRecipeButton: some View {
        if let editingRecipe {
            Button(role: .destructive) {
                pendingDestructiveAction = DestructiveConfirmation(
                    title: "Delete \u{201C}\(editingRecipe.name)\u{201D}?",
                    message: "The recipe, its steps and any photo of it are removed from this device. Meals you already logged from it stay in your diary. Fernlet can't undo this.",
                    confirmLabel: "Delete",
                    auditEvent: "recipe.deleteConfirmed",
                    perform: {
                        store.deleteRecipe(editingRecipe)
                        // Deleting is not saving: close this editor and leave the host where it is,
                        // rather than announcing a recipe that no longer exists.
                        dismiss()
                    }
                )
            } label: {
                Label("Delete recipe", systemImage: "trash")
            }
            .buttonStyle(DestructiveCardButtonStyle())
        }
    }

    /// The editor's own title, used in the nav bar when pushed and in the draft-guard's pinned
    /// ``SheetHeader`` when presented as a sheet. `LocalizedStringKey` so both call sites localize.
    private var editorTitle: LocalizedStringKey { editingRecipe == nil ? "New recipe" : "Edit recipe" }

    /// Leaves the editor after a save/delete: pops all the way back to the host's landing screen when
    /// one asked for that (`onSaved`), otherwise the plain dismiss (sheet close, or one pop).
    private func finishAfterSave(named recipeName: String) {
        if let onSaved {
            onSaved(recipeName)
        } else {
            dismiss()
        }
    }

    /// Create mode offers Save / Log & save; edit mode a single Done bar. Binding `editingRecipe`
    /// here is what lets the update call take the recipe by value instead of force-unwrapping it.
    @ViewBuilder private var saveBar: some View {
        if let editingRecipe {
            SheetSaveBar(disabled: !canSave) {
                store.updateRecipe(editingRecipe, name: name, servings: servings, notes: notes, ingredients: ingredients, steps: steps)
                finishAfterSave(named: name)
            }
        } else {
            createButtons
        }
    }

    /// Stacks at accessibility sizes — side by side, "Save recipe" / "Log & save" squeezed to the
    /// screen edge and broke mid-word.
    private var createButtons: some View {
        AdaptiveStack(spacing: 12) {
            Button("Save recipe") {
                store.addRecipe(name: name, servings: servings, notes: notes, ingredients: ingredients, steps: steps)
                finishAfterSave(named: name)
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
                let recipe = store.addRecipe(name: name, servings: servings, notes: notes, ingredients: ingredients, steps: steps)
                store.logRecipe(recipe)
                finishAfterSave(named: name)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.onMoss)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canSave ? Color.mossFill : Color.mossFill.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
            .disabled(!canSave)
        }
        .padding(20)
        .background(Color.parchment)
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

    /// F5 manual cooking-step editor: an ordered add / reorder (move up-down) / delete list plus an
    /// optional per-step timer, matching the shipped ingredient-editor idiom (a plain VStack of cream
    /// cards inside a ScrollView — reorder is chevron buttons rather than a `List.onMove`, since this
    /// sheet has no `List`). Blank steps are dropped by `RecipeStepSanitizer` on save.
    @ViewBuilder private var stepsSection: some View {
        SheetField("Steps (optional)") {
            VStack(spacing: 8) {
                // Identity is the step id (stable under reorder/delete); the display index is recomputed
                // per render so "Step N" and the up/down enable-state always reflect current position.
                // Each editor gets the ELEMENT binding (`$step`) rather than a by-id computed Binding:
                // the computed one rewrote the whole array on every keystroke, which reset the caret
                // mid-word and dropped characters as the user typed.
                ForEach($steps) { $step in
                    stepEditorCard($step, index: steps.firstIndex(where: { $0.id == step.id }) ?? 0)
                }
                addStepButton
            }
        }
    }

    /// One step's editor card: position label + move/remove controls, the text editor, and the
    /// optional per-step timer.
    private func stepEditorCard(_ step: Binding<RecipeStep>, index: Int) -> some View {
        let id = step.wrappedValue.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(index + 1)")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Spacer()
                stepControlButton(systemImage: "chevron.up", enabled: index > 0, label: "Move step \(index + 1) up") {
                    moveStep(id, by: -1)
                }
                stepControlButton(systemImage: "chevron.down", enabled: index < steps.count - 1, label: "Move step \(index + 1) down") {
                    moveStep(id, by: 1)
                }
                stepControlButton(systemImage: "xmark", enabled: true, tint: Color.slate, label: "Remove step \(index + 1)") {
                    removeStep(id)
                }
            }
            SheetTextEditor(text: step.text, placeholder: "what to do in this step", minHeight: 60)
            StepTimerControl(durationSeconds: step.durationSeconds)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recipeEditor.step.\(index)")
    }

    /// One 34pt glyph control on a step card — the up/down/remove buttons share this styling exactly.
    private func stepControlButton(
        systemImage: String,
        enabled: Bool,
        tint: Color = Color.moss,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(enabled ? tint : Color.slate.opacity(0.3))
                .frame(minWidth: 34, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var addStepButton: some View {
        Button {
            addStep()
        } label: {
            Label("Add step", systemImage: "plus")
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        // R3: bounded by the same step ceiling the paste decoder enforces.
        .disabled(steps.count >= RecipeLimits.maxSteps)
        .accessibilityIdentifier("recipeEditor.addStep")
    }

    /// Appends one blank step, refusing past ``RecipeLimits/maxSteps`` (R3: the cap is enforced where
    /// the input enters, not only on the button's disabled state).
    private func addStep() {
        guard steps.count < RecipeLimits.maxSteps else { return }
        steps.append(RecipeStep(text: ""))
    }

    private func moveStep(_ id: UUID, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
    }

    private func removeStep(_ id: UUID) {
        steps.removeAll { $0.id == id }
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

/// Everything ``RecipeSheet`` lets the user edit, captured as one comparable value.
///
/// The editor snapshots it at open and compares the live fields against it, so the discard warning
/// fires on real edits only — an opened-and-closed recipe (or an untouched blank draft) dismisses
/// without a dialog.
private struct RecipeDraftSnapshot: Equatable {
    let name: String
    let servings: Int
    let notes: String
    let ingredients: [ManualRecipeIngredientInput]
    let steps: [RecipeStep]
}

/// The collapsed one-line summary of a recipe ingredient (name plus a quantity/macros line), shown
/// while a different ingredient's editor is expanded.
///
/// Tapping the row re-expands it into ``RecipeIngredientEditor``; the trailing x removes it. The
/// calorie figure in the summary renders only behind the explicit calorie opt-in.
private struct CollapsedIngredientRow: View {
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
        macros.calories
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
            .fernletIconButton("Remove \(ingredient.name.isEmpty ? "ingredient" : ingredient.name)")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

/// The shared debounce + detached-query mechanics behind every catalog typeahead in the food
/// surfaces — the recipe editor's ingredient search and Adjust meal's Replace/"Add an item"
/// fields (FOOD-05), extracted so the two can't drift.
///
/// `matches` settles the keystroke (220 ms; a newer `.task(id:)` keystroke cancels the sleep and
/// aborts before any work), runs `FoodCatalog.results(for:)` — real SQLite + hydrate + score work
/// over a catalog growing toward ~482k rows — on a detached task off the main actor, then returns
/// nil when superseded so the caller keeps its current list instead of applying a stale result.
/// An empty query returns `[]` immediately. Callers must invoke it from `.task(id:)` keyed on the
/// live text, never synchronously in `body`.
enum CatalogTypeahead {
    /// One settled-keystroke query. nil = this call was superseded; apply nothing.
    static func matches(for text: String, catalog: FoodCatalog) async -> [FoodItem]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Debounce; a newer keystroke cancels this sleep and we bail before doing any work.
        do {
            try await Task.sleep(for: .milliseconds(220))
        } catch {
            return nil
        }
        // Heavy SQLite/index/score work runs off the main actor. `catalog` is Sendable.
        let hits = await Task.detached { [catalog] in
            catalog.results(for: trimmed)
        }.value
        // Drop the result if this task was superseded while the query was running.
        guard !Task.isCancelled else { return nil }
        return hits
    }
}

/// One catalog typeahead suggestion: name + provenance badge over the reference serving/macros.
///
/// Shared by the recipe editor's ingredient search and Adjust meal's Replace/"Add an item" fields
/// so a suggestion reads identically wherever it appears (FOOD-05).
private struct CatalogSuggestionRow: View {
    var foodItem: FoodItem
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
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

/// The expanded editor for one recipe ingredient: a debounced catalog typeahead, quantity/unit
/// controls, and either locked catalog macros or manual macro entry.
///
/// Typeahead results come from `FoodCatalog.results(for:)` — real SQLite + index + score work over a
/// catalog growing toward ~482k rows — so the query runs debounced and off the main actor (the
/// shared ``CatalogTypeahead`` mechanics). Selecting a
/// suggestion binds the ingredient to the catalog item (locking its macros); editing the name away
/// unbinds it, and the editor deliberately never auto-binds on an exact name match so branded products
/// can't hijack common words like "chicken". "Save custom ingredient" persists manual macros as a user
/// `FoodItem` via the injected closure.
private struct RecipeIngredientEditor: View {
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
            searchHeaderRow
            suggestionList
            saveCustomIngredientButton
            quantityUnitRow
            macroSection
            removeIngredientButton
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
            await refreshTypeahead()
        }
    }

    /// Only "Done" lives beside the search field. The remove control used to sit next to it as a bare
    /// x, which reads as "clear/close the search" — one mis-tap while looking for a way out of the
    /// results list deleted the whole ingredient. Removal is now the labelled button at the bottom of
    /// the card (see ``removeIngredientButton``).
    private var searchHeaderRow: some View {
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
                    .fernletTapTarget(minWidth: 44, minHeight: 44)
            }
        }
    }

    /// The labelled way out of an ingredient: a word, at the foot of the card, well away from the
    /// search field's Done.
    private var removeIngredientButton: some View {
        Button("Remove ingredient", action: onRemove)
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.terracottaInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Remove \(ingredient.trimmedName.isEmpty ? "ingredient" : ingredient.name)")
    }

    @ViewBuilder private var suggestionList: some View {
        if !matchingFoodItems.isEmpty && selectedFoodItem == nil {
            VStack(spacing: 4) {
                ForEach(matchingFoodItems) { foodItem in
                    CatalogSuggestionRow(foodItem: foodItem) { select(foodItem) }
                }
            }
        }
    }

    @ViewBuilder private var saveCustomIngredientButton: some View {
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
    }

    private var quantityUnitRow: some View {
        HStack(spacing: 12) {
            TextField("Qty", value: $ingredient.quantity, format: .number)
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.none)
                // Design-system digits: the bare field rendered its value in system SF next to the
                // serif placeholders in the same card.
                .font(.fernlet(.label))
                .frame(maxWidth: 80)
            Picker("Unit", selection: $ingredient.unit) {
                ForEach(RecipeUnit.allCases) { unit in
                    Text(unit.label).tag(unit.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Locked catalog macros (with the "Manual" escape hatch) when the ingredient is bound to a food
    /// item; the three editable macro rows when it isn't.
    @ViewBuilder private var macroSection: some View {
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

    /// The debounced typeahead query behind `.task(id: ingredient.name)`: the shared
    /// ``CatalogTypeahead`` mechanics (settle the keystroke, run the catalog search off the main
    /// actor, drop a superseded result), plus this editor's own gating on a chosen food.
    private func refreshTypeahead() async {
        let text = ingredient.trimmedName
        // Mirror the render gating: nothing to show when a food is chosen or the field is empty.
        guard selectedFoodItem == nil, !text.isEmpty else {
            matchingFoodItems = []
            return
        }
        // nil = superseded by a newer keystroke: keep the current list rather than a stale one.
        guard let hits = await CatalogTypeahead.matches(for: text, catalog: catalog) else { return }
        matchingFoodItems = hits
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

/// The locked-macros panel shown when an ingredient is bound to a catalog food item.
///
/// Displays the resolved macros and the item's reference serving, with a "Manual" escape hatch that
/// unbinds the ingredient and seeds the editable fields from the item's macros.
private struct LockedMacroSummary: View {
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

#if canImport(UIKit)
/// A resolved scanned or label-parsed food awaiting the quick serving-count confirmation before it
/// is logged.
///
/// `kind` selects the truthful log path (barcode vs. nutrition-label provenance), and the fresh `id`
/// gives `sheet(item:)` a new identity per scan.
private struct PendingScannedFood: Identifiable {
    /// How the food was captured — routes the eventual log to `logBarcodeScannedFoodItem` vs.
    /// `logLabelScannedFoodItem` so the meal's provenance stays truthful.
    enum Kind { case barcode, label }
    let id = UUID()
    let item: FoodItem
    let kind: Kind
}
#endif

/// The "Log meal" sheet — the app's quick-log front door, presented from any tab via `FernletSheet`.
///
/// Owns the free-text description field and the unified Capture flow: a camera shot runs
/// ``FoodCaptureRouter`` (barcode → label → meal) behind an analyzing veil, an ambiguous reading
/// opens ``CaptureChooserSheet``, and a library pick attaches as the meal photo via the byte path —
/// the sealed-ready JPEG is held so a 48 MP pick never decodes into a full-resolution bitmap. Save
/// resolves the text through `FernletStore.resolveMeals`; a low-confidence resolution pauses at
/// ``MealReviewSheet`` instead of committing, and barcode/label results confirm a serving count in
/// ``BarcodeServingStepView`` before logging. `didLogMeal` disarms Save after a photo-save failure so
/// the meal can never log twice, and interactive dismissal is disabled while a resolve is in flight.
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
    /// True while the by-hand macro fields (FOOD-24) are revealed. With any nonzero value typed,
    /// Save logs those numbers directly instead of running the resolve cascade.
    @State private var isEnteringMacrosByHand = false
    @State private var manualProtein = 0
    @State private var manualCarbs = 0
    @State private var manualFat = 0
    /// Presents the dedicated Recent-meals surface (FOOD-07) from the capture row.
    @State private var showingRecentMeals = false
    /// Set when a repeat was logged FROM the Recent surface, so that sheet's dismissal also closes
    /// this composer — the same deferred-exit pattern as `pendingScannedFood`'s onDismiss.
    @State private var didLogFromRecent = false
    /// Drives the chips' accessibility degradations (4a·AX3/AX5): one chip per row at
    /// accessibility sizes; the Auto chip drops its inferred value and the section label goes at
    /// the AX5 floor.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// True once a meal has been committed but the sheet stayed open (photo-save failure notice).
    /// The save bar then hides and the pinned header's trailing Done becomes the exit
    /// (`photoFailureDoneAction`) — a second "Save" must never log the same meal twice.
    @State private var didLogMeal = false
    /// Set when the user discards this sheet while a resolve is still running, so the in-flight
    /// resolve drops its result instead of committing a meal they just cancelled.
    @State private var abandonedResolve = false
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
    /// A resolved scanned/label-parsed food held for the quick serving-count confirm step before it is
    /// logged — set by the barcode/label resolve callbacks instead of logging immediately.
    @State private var pendingScannedFood: PendingScannedFood?
    #endif

    var body: some View {
        mealPresentations(mealNavigation)
    }

    /// The log-meal stack itself: the composer plus its seven flow destinations, and the modifiers
    /// that guard a resolve in flight.
    private var mealNavigation: some View {
        NavigationStack(path: $path) {
            mealContent
                .navigationDestination(for: MealFlowDestination.self) { destination in
                    flowDestination(for: destination)
                }
        }
        .background(Color.parchment)
        #if canImport(UIKit)
        .overlay {
            if isAnalyzingCapture {
                CaptureAnalyzingOverlay()
                    .transition(.opacity)
            }
        }
        .animation(FernletMotion.ui, value: isAnalyzingCapture)
        #endif
        // At the sheet ROOT, not just on the composer: the draft guard below lives on the composer
        // page (so a pushed Scan/Import page keeps its own chevron instead of growing a Cancel bar),
        // and a preference declared there stops applying once that page is off screen. Without this
        // line an interactive dismiss from a pushed page while "Matching" is still running would let
        // the unstructured resolve Task commit a meal the user meant to cancel.
        .interactiveDismissDisabled(isResolvingMeal)
        .onAppear {
            store.markLaunchScreenDismissed()
            store.ensureBundledFoodItemsSeeded()
        }
    }

    /// Whether the composer holds anything a swipe-away would silently discard. False once the meal
    /// has actually logged (the sheet then only carries a photo-failure notice).
    private var hasUnsavedDraft: Bool {
        guard !didLogMeal else { return false }
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if handEnteredMacros != nil { return true }
        #if canImport(UIKit)
        if mealPhoto != nil || mealPhotoData != nil { return true }
        #endif
        return false
    }

    /// One pushed destination in the log-meal flow (scanner, embedded recipe editor, web import /
    /// search, and the auto-router landings for a captured photo).
    @ViewBuilder private func flowDestination(for destination: MealFlowDestination) -> some View {
        switch destination {
        case .recipeSearch:
            RecipeSheet(store: store, isEmbeddedInNavigationStack: true)
        case .scanBarcode:
            #if canImport(UIKit)
            // Barcode hit (or a just-remembered product): hand off to the quick serving
            // step, which logs once the count is confirmed (prefilled from last time, so
            // accepting is a single tap).
            BarcodeResolveFlowView(store: store) { foodItem in
                pendingScannedFood = PendingScannedFood(item: foodItem, kind: .barcode)
            }
            #else
            EmptyView()
            #endif
        #if canImport(UIKit)
        case .captureBarcode(let payload):
            // The auto-router already read this barcode from the captured photo — resolve
            // it through the same catalog-hit / name-&-remember path as a live scan.
            BarcodePayloadResolveView(store: store, payload: payload) { foodItem in
                pendingScannedFood = PendingScannedFood(item: foodItem, kind: .barcode)
            }
        case .captureLabel(let result):
            // The auto-router parsed a nutrition label — hand off to the existing
            // name-it-&-remember screen with the macros pre-filled (no barcode, no rescan).
            // Log via the label-scan path so provenance is truthful: this meal came from a
            // scanned nutrition label, not a barcode. The serving step confirms the count.
            BarcodeNotFoundView(store: store, barcode: "", prefilledScan: result) { foodItem in
                pendingScannedFood = PendingScannedFood(item: foodItem, kind: .label)
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

    /// The three sheets layered over the composer — pre-log review, the capture chooser, and the
    /// scanned-food serving step — in their original application order.
    private func mealPresentations<V: View>(_ content: V) -> some View {
        content
            .sheet(item: $reviewContext) { context in
                reviewSheet(context)
            }
            .sheet(isPresented: $showingRecentMeals, onDismiss: {
                // A repeat logged from the Recent surface finishes the whole log flow — the
                // composer beneath has nothing left to do, so it exits once that sheet settles
                // (the same deferred-exit pattern as `pendingScannedFood`'s onDismiss). A plain
                // Done/swipe-away without a log just returns to the composer.
                if didLogFromRecent { dismiss() }
            }) {
                recentMealsSurface
            }
        #if canImport(UIKit)
            .sheet(item: $captureChooser) { context in
                captureChooserSheet(context)
            }
            .sheet(item: $pendingScannedFood, onDismiss: {
                // The serving step closed — whether the user tapped Log, tapped Cancel, or swiped it away.
                // In every case the scan-log flow is finished, so exit the scanner instead of returning the
                // user to the now-paused (frozen) viewfinder behind it. Its only re-arm is `onAppear`, which
                // never fires while it sits under a sheet, so a bare sheet-dismiss would strand them. This is
                // the single exit point mirroring the previous post-log `dismiss()`, now shared by every path.
                dismiss()
            }) { pending in
                servingStepSheet(pending)
            }
        #endif
    }

    /// The dedicated Recent surface (FOOD-07), configured to file the repeat for NOW: the sheet's
    /// own Meal-type choice when the user made one, otherwise the same by-time "Auto" rule a typed
    /// log follows — never the source meal's old slot or note (the store drops the carried note
    /// and stamps the copy "Repeated"; see `FernletStore.copyMeal`).
    private var recentMealsSurface: some View {
        RecentMealsSheet(store: store) { meal in
            let copiedMeal = store.copyMeal(
                meal, mealType: mealType ?? MealParser.classifyMealType(meal.name))
            onLogged([copiedMeal])
            didLogFromRecent = true
            showingRecentMeals = false
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }

    /// The pre-log review sheet for a low-confidence or partially-matched resolution.
    private func reviewSheet(_ context: MealReviewContext) -> some View {
        MealReviewSheet(
            resolution: context.resolution,
            store: store,
            onConfirm: { reviewedMeals, confirmedRecipe in
                confirmReviewedMeals(reviewedMeals, confirmedRecipe: confirmedRecipe, context: context)
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

    /// Commits the user's reviewed meals (and any confirmed recipe), attaches the held photo, and
    /// either dismisses or disarms Save when only the photo failed.
    private func confirmReviewedMeals(
        _ reviewedMeals: [Meal],
        confirmedRecipe: RecipeDefinition?,
        context: MealReviewContext
    ) {
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
    }

    #if canImport(UIKit)
    /// The gentle Barcode · Label · Meal chooser for an ambiguous capture; each branch reuses the
    /// reading the router already made instead of re-scanning the photo.
    private func captureChooserSheet(_ context: CaptureChooserContext) -> some View {
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

    /// The quick serving-count confirm for a scanned/label-parsed food, before it is logged.
    private func servingStepSheet(_ pending: PendingScannedFood) -> some View {
        BarcodeServingStepView(
            foodItem: pending.item,
            initialServings: BarcodeServingMemory.lastServings(for: pending.item.barcode) ?? 1,
            onCancel: {
                // Abandon the log: drop the pending food. Clearing it dismisses this sheet, and the
                // sheet's `onDismiss` then exits the scan-log flow.
                pendingScannedFood = nil
            }
        ) { servings in
            logPendingScannedFood(pending, servings: servings)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }

    /// Logs a confirmed scanned food through the path that keeps its provenance truthful (barcode vs
    /// nutrition label), remembers the serving count, and closes the scan-log flow.
    private func logPendingScannedFood(_ pending: PendingScannedFood, servings: Double) {
        let meal: Meal
        switch pending.kind {
        case .barcode:
            meal = store.logBarcodeScannedFoodItem(pending.item, mealType: mealType, servings: servings)
        case .label:
            meal = store.logLabelScannedFoodItem(pending.item, mealType: mealType, servings: servings)
        }
        BarcodeServingMemory.setLastServings(servings, for: pending.item.barcode)
        onLogged([meal])
        // Clearing the pending food dismisses this sheet; the sheet's `onDismiss` then exits the
        // scan-log flow (same net effect as the old explicit `dismiss()` here).
        pendingScannedFood = nil
    }
    #endif

    private var mealContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                // FOOD-08 order: field → meal-type chips DIRECTLY under it → the capture row —
                // type, slot, Save, without a drag. The title lives in the pinned template header
                // (the draft guard below), not in the scroll.
                VStack(alignment: .leading, spacing: 22) {
                    photoAndIdentifySection

                    SheetField("What did you eat?") {
                        // A one-line log is the common case, so Return saves instead of inserting a
                        // line break; the field still grows to four lines for a longer description.
                        SheetGrowingTextField(text: $description, placeholder: "scrambled eggs and toast") {
                            guard canSaveTypedMeal else { return }
                            saveTapped()
                        }
                    }

                    mealTypeChips

                    captureButtonsSection

                    if isEnteringMacrosByHand {
                        manualMacrosSection
                    }

                    noticeSection
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            // Hidden once the meal has logged (photo-save failure notice): the sheet is then
            // dismiss-only, and a dismiss-only exit belongs in the header's trailing Done — the
            // bottom-right moss pill is retired for it (2a annotation 4 / correction #4).
            if !didLogMeal {
                SheetSaveBar(
                    label: isResolvingMeal ? "Matching" : "Save",
                    disabled: !canSaveTypedMeal
                ) {
                    saveTapped()
                }
            }
        }
        .background(Color.parchment)
        // Two reasons a swipe must not take this sheet away, folded into one guard:
        //  - a resolve in flight (the unstructured Task isn't cancelled on dismiss, so an interactive
        //    dismiss mid-"Matching" could commit a meal the user meant to cancel), and
        //  - a typed description / attached photo, which a swipe-down silently threw out.
        // Cancel dismisses a clean sheet outright and asks first when there's something to lose;
        // discarding mid-resolve also disarms the in-flight commit (`abandonedResolve`). It sits on
        // the composer rather than the whole stack so a pushed page (Scan, Import) keeps its own
        // back chevron instead of growing a second bar above it. The title-bearing form is the
        // 2026-08-21 template chrome: the pinned header carries Cancel and the sheet's serif title.
        // Once `didLogMeal` is set the header's trailing Done is the exit and Cancel is a plain
        // dismiss — `hasUnsavedDraft` is false then, so no discard prompt for a committed meal.
        .fernletDraftGuard(
            isDirty: isResolvingMeal || hasUnsavedDraft,
            title: "Log meal",
            onDone: photoFailureDoneAction
        ) {
            abandonedResolve = isResolvingMeal
            dismiss()
        }
    }

    /// Whether Save (or a Return press) has something to log: the same condition the save bar's
    /// disabled state uses, so Return can never save a form the pill would refuse.
    private var canSaveTypedMeal: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResolvingMeal
    }

    /// The pinned header's trailing Done for the photo-failed state (meal logged, sheet
    /// dismiss-only): non-nil once `didLogMeal` is set, when the save bar has hidden and the
    /// template rule puts the dismiss-only exit top-right instead of in a bottom moss pill.
    private var photoFailureDoneAction: (() -> Void)? {
        guard didLogMeal else { return nil }
        return { dismiss() }
    }

    /// The captured/picked meal photo plus the gated "Identify from photo" action.
    @ViewBuilder private var photoAndIdentifySection: some View {
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
    }

    /// Quiet helpers only (XCUT-14): Capture drops to a cream secondary BESIDE "Scan label" — it
    /// was a full-width moss button one screen-third above the moss Save, and the louder green
    /// wasn't the commit. Recent (its own surface now — FOOD-07) and Import share a second row,
    /// and the stated by-hand macros path (FOOD-24) sits beneath.
    private var captureButtonsSection: some View {
        VStack(spacing: 10) {
            #if canImport(UIKit)
            HStack(spacing: 8) {
                // A camera shot goes through the auto-detect front door; a library pick is just
                // attached as the meal photo (no barcode/label rescan on an arbitrary library image).
                PhotoCaptureControl(
                    onCameraCapture: { handleCapturedPhoto($0) },
                    onLibraryPickData: { data, _ in setLibraryPickedMealPhoto(data) }
                ) {
                    mealSecondaryLabel("Capture", icon: "camera.fill")
                }
                .accessibilityLabel("Capture food")
                mealSecondaryButton("Scan label", icon: "barcode.viewfinder") {
                    path.append(.scanBarcode)
                }
            }
            // Import is a web lookup end to end. Offering it with web nutrition lookup switched
            // off led to a screen that accepted a search and then refused it, so it only appears
            // when the lookup it depends on is actually available.
            if !store.recentMeals.isEmpty || store.allowsWebNutritionLookup {
                HStack(spacing: 8) {
                    if !store.recentMeals.isEmpty {
                        mealSecondaryButton("Recent", icon: "clock.arrow.circlepath") {
                            showingRecentMeals = true
                        }
                    }
                    if store.allowsWebNutritionLookup {
                        mealSecondaryButton("Import", icon: "link.badge.plus") {
                            path.append(.productPageImport)
                        }
                    }
                }
            }
            #else
            if store.allowsWebNutritionLookup {
                mealSecondaryButton("Import", icon: "link.badge.plus") {
                    path.append(.productPageImport)
                }
            }
            #endif
            macrosByHandToggle
        }
    }

    /// The stated path to typing macros (FOOD-24), on the sheet rather than buried behind a scan:
    /// reveals the three protein/carbs/fat fields inline. There is no "you can add them later" —
    /// the fields are right here.
    private var macrosByHandToggle: some View {
        Button {
            withAnimation(FernletMotion.ui) { isEnteringMacrosByHand.toggle() }
        } label: {
            mealSecondaryLabel("Enter macros by hand", icon: "square.and.pencil")
        }
        .buttonStyle(.plain)
    }

    /// The three by-hand macro fields. Editable always; a label scan that reached this composer
    /// would prefill them, but the scan flows commit through their own confirm step, so they
    /// start at zero here. Any nonzero value routes Save through the direct by-hand log.
    private var manualMacrosSection: some View {
        SheetField("Macros") {
            MealMacroEditorRows(protein: $manualProtein, carbs: $manualCarbs, fat: $manualFat)
        }
    }

    /// The meal-slot chips, DIRECTLY under the description field (FOOD-08): six chips in one
    /// fixed order, Breakfast first, wrapping to two rows. The preselected Auto chip STATES its
    /// inference (FOOD-14), recomputed as the text and clock imply. At accessibility sizes the
    /// chips stack one per row (4a·AX3); at the AX5 floor the section label goes (4a·AX5).
    @ViewBuilder private var mealTypeChips: some View {
        if dynamicTypeSize >= .accessibility5 {
            mealTypeChipList
        } else {
            SheetField("Meal type") { mealTypeChipList }
        }
    }

    /// The chip stack itself: a wrapping flow normally, one chip per row at accessibility sizes.
    @ViewBuilder private var mealTypeChipList: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) { mealTypeChipButtons }
        } else {
            FlowLayout(spacing: 8) { mealTypeChipButtons }
        }
    }

    @ViewBuilder private var mealTypeChipButtons: some View {
        autoMealTypeChip
        ForEach(MealType.allCases) { type in
            Button { mealType = type } label: { Text(verbatim: type.displayName) }
                .buttonStyle(ChipButtonStyle(selected: mealType == type))
        }
    }

    /// The Auto chip, stating what it inferred ("Auto · Breakfast") so the user can confirm
    /// rather than guess. The inferred value scales down slightly before wrapping (4a·AX3) and is
    /// dropped entirely at the AX5 floor.
    private var autoMealTypeChip: some View {
        Button { mealType = nil } label: {
            if dynamicTypeSize >= .accessibility5 {
                Text("Auto")
            } else {
                Text("Auto \u{00B7} \(inferredMealType.displayName)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(ChipButtonStyle(selected: mealType == nil))
    }

    /// The slot the "Auto" rule would file this meal under right now — the same
    /// `MealParser.classifyMealType` keyword-then-hour inference the resolve path applies, shown
    /// pre-save for the first time (FOOD-14).
    private var inferredMealType: MealType {
        MealParser.classifyMealType(description)
    }

    /// The calm inline notice line plus the "couldn't read that one" capture banner.
    @ViewBuilder private var noticeSection: some View {
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

    /// The Save bar's action, then the cached-product / web-search / typed-resolve cascade. Also
    /// reached by a Return press in the description field, which is why the photo-failure guard
    /// stays here even though the save bar itself hides once `didLogMeal` is set.
    private func saveTapped() {
        if didLogMeal {
            // The meal already logged (only its photo failed) — never log it a second time.
            dismiss()
            return
        }
        // By-hand macros first (FOOD-24): typed numbers ARE the meal — no resolve, no AI.
        if let macros = handEnteredMacros {
            logHandEnteredMeal(macros)
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
                // No audit here: this only navigates to the product-search view, which auto-runs
                // the lookup on appear and records it at completion with the real outcome.
                // Recording at this navigation would double-log and pre-stamp `.succeeded` on a
                // lookup that hasn't happened yet.
                path.append(.productSearch(mealDescription))
                return
            }
        }
        resolveTypedMeal(mealDescription, type: selectedMealType)
    }

    /// The by-hand macros to log directly, or nil when the section is closed or all-zero (Save
    /// then runs the normal resolve cascade).
    private var handEnteredMacros: Macros? {
        guard isEnteringMacrosByHand else { return nil }
        guard manualProtein > 0 || manualCarbs > 0 || manualFat > 0 else { return nil }
        return Macros(protein: manualProtein, carbs: manualCarbs, fat: manualFat)
    }

    /// Logs the described meal with the typed macros (FOOD-24) — attaching any held photo through
    /// the same disarm-on-photo-failure path the resolve commit uses, so a photo that fails to
    /// seal can never be answered with a second Save that logs the meal twice.
    private func logHandEnteredMeal(_ macros: Macros) {
        let meal = store.logHandEnteredMacroMeal(description: description, mealType: mealType, macros: macros)
        #if canImport(UIKit)
        let photoAttached = attachPhoto(mealPhoto, data: mealPhotoData, to: [meal])
        #else
        let photoAttached = true
        #endif
        onLogged([meal])
        if photoAttached {
            dismiss()
        } else {
            didLogMeal = true
            notice = "Your meal is logged, but its photo couldn't be saved to your private store."
        }
    }

    /// Runs the normal free-text resolve cascade for a typed description: a low-confidence result
    /// pauses at the pre-log review sheet, otherwise it commits and dismisses. Shared by the Save
    /// button and the web-import "log what you typed instead" escape hatch, so the web path is never a
    /// one-way street.
    private func resolveTypedMeal(_ mealDescription: String, type: MealType?) {
        // At most one resolve in flight, enforced HERE rather than only by the Save button's disabled
        // state: the web-import "log what you typed instead" escape calls this after popping the path,
        // and a second tap during that pop would otherwise start a second resolve and commit twice.
        guard !isResolvingMeal else { return }
        #if canImport(UIKit)
        let capturedPhoto = mealPhoto
        let capturedPhotoData = mealPhotoData
        #endif
        isResolvingMeal = true
        Task {
            let resolution = await store.resolveMeals(from: mealDescription, type: type)
            isResolvingMeal = false
            // The sheet was discarded while this resolve was still running: the user cancelled, so
            // nothing here commits.
            guard !abandonedResolve else { return }
            // `needsReview` now covers coverage as well as confidence: a resolution that quietly
            // dropped part of what was typed ("2 eggs and toast" matching only the toast) pauses here
            // too, and the review sheet names the words that found nothing.
            if resolution.needsReview {
                // Pause for a pre-log review instead of silently committing a partial guess.
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

    /// The payload for the pre-log review sheet: the resolution under review plus any captured photo
    /// awaiting attach.
    ///
    /// Identifiable with a fresh `id` per presentation so `sheet(item:)` re-presents even for an
    /// identical resolution.
    private struct MealReviewContext: Identifiable {
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
    ///
    /// The result is a success/failure signal, so it is deliberately NOT `@discardableResult` (R7):
    /// every caller must decide between dismissing and showing the notice.
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

    /// The context handed to ``CaptureChooserSheet`` when auto-detection was ambiguous.
    ///
    /// Carries the captured image plus the router's best-effort label parse and detected barcode, so
    /// the chooser branches reuse those readings instead of re-scanning the same photo.
    private struct CaptureChooserContext: Identifiable {
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

    /// A quiet cream secondary in the capture row. `LocalizedStringKey`, not `String` — a `String`
    /// parameter would silently opt every call site out of localization (the wall's one silent
    /// failure mode); the icon name is a token and stays a plain `String`.
    private func mealSecondaryButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            mealSecondaryLabel(title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func mealSecondaryLabel(_ title: LocalizedStringKey, icon: String) -> some View {
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
            .fernletIconButton("Remove this photo")
            .padding(8)
        }
    }
    #endif
}

/// The dedicated Recent-meals surface (2026-08-21, FOOD-07/FOOD-06), replacing the bare Menu in
/// the log-meal composer's capture row.
///
/// Done top-right is the whole exit (read-only template chrome). Rows are the store's recent
/// meals deduped case-insensitively with the most recent log winning, top eight
/// (`FernletStore.dedupedRecentMeals`); each states meal type, when it was last eaten, and its
/// protein — the only things that tell two identical names apart. The Log pill hands the meal to
/// `onLog`, whose owner copies it onto today (fresh time, re-derived slot, note dropped). At
/// accessibility sizes each row becomes a card — name, then slot and time, then a full-width Log —
/// and the protein figure drops (4d·AX3).
private struct RecentMealsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var store: FernletStore
    /// Logs the chosen meal again; the owning composer copies it onto today and closes the flow.
    var onLog: (Meal) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Recent",
                subtitle: "Tap to log it again with today's time.",
                onDone: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let meals = store.dedupedRecentMeals
                    ForEach(Array(meals.enumerated()), id: \.element.id) { index, meal in
                        if index > 0 { FernletRowDivider() }
                        recentRow(meal)
                    }
                    Text("Repeats collapse into one row \u{2014} the most recent time wins.")
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                        .padding(.top, 16)
                }
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background(Color.parchment)
    }

    /// One recent meal: summary beside the Log pill, unstacking into a card at accessibility sizes.
    @ViewBuilder private func recentRow(_ meal: Meal) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                recentTitle(meal)
                recentDetailLine(meal, includesProtein: false)
                logButton(meal)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    recentTitle(meal)
                    recentDetailLine(meal, includesProtein: true)
                }
                Spacer(minLength: 0)
                logButton(meal)
            }
            .padding(.vertical, 6)
        }
    }

    private func recentTitle(_ meal: Meal) -> some View {
        Text(meal.name)
            .font(.fernlet(.header))
            .foregroundStyle(Color.bark)
            .fernletWrappingText()
    }

    /// "<meal type> · <when> · P <n>g" — the disambiguating line. Protein drops at accessibility
    /// sizes (meal type and time are what tell two identical names apart). Built with `Text`
    /// interpolation (the `+` operator is deprecated-as-error on iOS 26); each interpolated half
    /// keeps its own localization.
    private func recentDetailLine(_ meal: Meal, includesProtein: Bool) -> some View {
        let typeAndWhen = Text(
            "\(Text(verbatim: meal.mealType.displayName)) \u{00B7} \(loggedAtText(meal.loggedAt))"
        )
        let line = includesProtein
            ? Text("\(typeAndWhen) \u{00B7} P \(meal.macros.protein)g")
            : typeAndWhen
        return line
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
    }

    private func logButton(_ meal: Meal) -> some View {
        Button("Log") { onLog(meal) }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityLabel("Log \(meal.name) again")
    }

    /// The row's "when": bare time for today, "Yesterday 7:40" for yesterday, weekday plus time
    /// beyond that.
    private func loggedAtText(_ date: Date) -> Text {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return Text(date, format: .dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) {
            return Text("Yesterday \(date, format: .dateTime.hour().minute())")
        }
        return Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The "Import product" screen: search the web (or paste a product-page URL) for a packaged food,
/// preview the source, and save the extracted nutrition as a catalog item.
///
/// Runs only behind the web-nutrition-lookup opt-in; every lookup is recorded in `AIAuditLog` at
/// dispatch (the query egresses at request time) and settled with its real outcome at completion.
/// Resolution goes through ``FoodProductWebSearch``/``FoodProductWebImporter``, is confirmed in
/// ``FoodProductReviewSheet``, and `onLogAsTyped` offers an escape back to the normal typed-meal
/// resolve when the web can't help.
private struct FoodProductPageImportView: View {
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
                    // This page is always PUSHED, so it titles itself in the nav bar rather than
                    // drawing a display-serif title under an empty one.
                    urlEntry

                    if isLoading {
                        loadingRow
                    }

                    if let notice {
                        noticeSection(notice)
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

        }
        .background(Color.parchment)
        .navigationTitle("Import product")
        .navigationBarTitleDisplayMode(.inline)
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

    /// The calm progress card shown while the search / label read is running.
    private var loadingRow: some View {
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

    /// The outcome line, with the "log what you typed instead" escape when the web can't help.
    private func noticeSection(_ notice: String) -> some View {
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

    private var urlEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetField("Product search or page URL") {
                // A plain-language placeholder: the example URL rendered as a live blue link inside
                // the empty field, which read as content rather than a hint.
                TextField("Product name or paste a page link", text: $lookupText)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { loadPreview() }
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

    /// Says what is off and where to turn it on, in that order — the old copy ("Turn off Manual off
    /// mode…") was a double negative naming a mode by a label the user may never have seen.
    private var webNutritionLookupDisabledMessage: String {
        store.settings.aiStatus == .off
            ? "Web nutrition lookup is off. Turn on AI features and Web nutrition lookup in Settings to search the web."
            : "Web nutrition lookup is off. Turn on Web nutrition lookup in Settings to search the web."
    }

    /// Records the web-nutrition lookup at DISPATCH with a provisional `.fellBack` outcome and returns the
    /// entry id, so the caller can settle the real outcome at completion (Ladder §7.2). The description
    /// egresses at request time, so the entry must exist before the network call — not only if it succeeds.
    /// The on-device model isn't involved (this is the web path), so `modelIdentifier` is intentionally nil.
    private func recordWebNutritionLookupDispatch(_ mealDescription: String) async -> UUID {
        let payload = WebNutritionLookupPayload(mealDescription: mealDescription)
        return await AIAuditLog.shared.record(
            payloadKind: payload.payloadKind,
            destination: .webNutritionLookup,
            includedFields: payload.includedFieldNames,
            outcome: .fellBack
        )
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
        Task {
            // `.webNutritionLookup.leavesDevice == true`: the meal description egresses to the search /
            // import provider the moment this lookup begins, so the audit entry is recorded at DISPATCH
            // (provisional `.fellBack`) — a kill/crash mid-lookup must still leave a "what left my device"
            // record. The real outcome is written back at completion via `updateOutcome` (`.succeeded` when
            // a product resolved, else the provisional `.fellBack`).
            let auditID = await recordWebNutritionLookupDispatch(lookupText)
            var outcome: AIAuditOutcome = .fellBack
            do {
                if let url = normalizedURL {
                    preview = try await FoodProductWebImporter.preview(from: url)
                } else {
                    preview = try await FoodProductWebSearch.preview(for: lookupText)
                }
                if let preview {
                    var product = try await FoodProductWebImporter.importProduct(from: preview, gate: store.aiGate)
                    product.lookupQuery = lookupText
                    importedProduct = product
                    showingProductReview = true
                    outcome = .succeeded
                }
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "Could not import that product page."
            }
            isLoading = false
            await AIAuditLog.shared.updateOutcome(id: auditID, to: outcome)
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

/// The confirmation sheet for a web-imported product: source details, serving size, and macro pills,
/// with Open page / Search again / Confirm & save actions.
///
/// Nothing is persisted until the user confirms — the owning view saves via
/// `FernletStore.saveWebImportedFoodProduct` only from `onConfirm`. The Calories pill renders only
/// behind the explicit calorie opt-in.
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
        product.calories ?? product.macros.calories
    }
}

/// One logged meal in the day list: name, note or component breakdown, macros, a quiet provenance
/// capsule, optional photo thumb, and the delete / Adjust correction actions.
///
/// 2026-08-21 (FOOD-15/FOOD-02): the WHOLE summary is the button — tapping it opens Adjust — with
/// a right-aligned "Adjust ›" on its own trailing 44pt line so it can never wrap. The jargon tag
/// became a quiet slate capsule in plain words (Estimated / Reviewed / From recipe) and is absent
/// entirely for seeded demo logs; the X keeps its confirmation but takes the destructive tint. At
/// accessibility sizes the thumbnail and the C/F figures drop so the name and Adjust stay whole
/// (4b·AX3).
///
/// The photo closures are injected so the row reads the sealed `MealPhotoStore` lazily and can
/// distinguish a photo on another device from one that's here but unreadable (see
/// ``MealPhotoPresence``). The meal-type capsule is suppressed when the row already sits under a
/// meal-type section header.
private struct MealRow: View {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // The whole summary opens Adjust; delete stays OUTSIDE the button so the two
                // targets can't nest (a Button inside a Button label never fires).
                Button(action: onCorrect) {
                    summaryContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                trailingColumn
            }
            adjustLine
        }
        .padding(.vertical, 4)
    }

    /// The tappable summary: optional thumb beside name/note, breakdown, and the macros line.
    private var summaryContent: some View {
        HStack(alignment: .top, spacing: 10) {
            #if canImport(UIKit)
            // The thumbnail is the first thing to give way at accessibility sizes (4b·AX3).
            if let loadData = loadPhotoData, !dynamicTypeSize.isAccessibilitySize {
                MealPhotoThumb(loadData: loadData, hasSealedData: hasPhotoSealedFile ?? { false })
            }
            #endif
            VStack(alignment: .leading, spacing: 8) {
                titleBlock
                if let breakdownText {
                    breakdownCard(breakdownText)
                }
                macrosRow
            }
        }
    }

    /// Name, optional meal-type badge, and the provenance note beneath.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meal.name).font(.fernlet(.header))
                if showsMealTypeBadge {
                    Text(verbatim: meal.mealType.displayName)
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
    }

    /// Calories over the delete X — which keeps its "Remove this meal?" confirmation and now
    /// carries the destructive tint (2b): it stopped reading as a neutral dismiss.
    private var trailingColumn: some View {
        VStack(alignment: .trailing) {
            if showCalories {
                Text("\(meal.calories) cal").font(.fernlet(.stat))
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.terracottaInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete meal")
        }
    }

    /// The right-aligned "Adjust ›" on its own trailing line, in a 44pt frame so it can never
    /// wrap into the macros (FOOD-15). Same action as the row itself — the labelled affordance is
    /// what makes the correction path discoverable.
    private var adjustLine: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: onCorrect) {
                HStack(spacing: 4) {
                    Text("Adjust")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Adjust meal")
        }
    }

    /// The matched-components breakdown line, when the meal has one.
    private func breakdownCard(_ text: String) -> some View {
        Text(text)
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    private var macrosRow: some View {
        HStack(spacing: 14) {
            Text("P \(meal.macros.protein)g").foregroundStyle(Color.moss)
            // C and F give way at accessibility sizes so the name and Adjust stay whole (4b·AX3).
            if !dynamicTypeSize.isAccessibilitySize {
                Text("C \(meal.macros.carbs)g")
                Text("F \(meal.macros.fat)g")
            }
            confidenceTag
            Spacer(minLength: 0)
        }
        .font(.fernlet(.stat))
        .foregroundStyle(Color.slate)
    }

    /// The quiet slate provenance capsule, in plain words (FOOD-02) — absent entirely for seeded
    /// demo logs, whose provenance is a demo artifact rather than something the user did.
    @ViewBuilder private var confidenceTag: some View {
        if !isSeededDemoMeal {
            confidenceTagText
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.slate.opacity(0.10), in: Capsule())
        }
    }

    /// Seeded demo meals carry this exact note (`FernletStore+DemoSeed`); it is the identifying
    /// signal because their confidence token (`logged`) is also a legitimate user stamp.
    private var isSeededDemoMeal: Bool {
        meal.note == "Seeded demo meal."
    }

    /// Plain words for the capsule: recipe-backed rows say "From recipe"; everything else shows
    /// its localized `confidenceLabel` (already plain: Estimated, Reviewed, Scanned label, …).
    private var confidenceTagText: Text {
        switch meal.confidenceToken {
        case .recipe, .recipeNoMacros:
            Text("From recipe")
        default:
            Text(verbatim: meal.confidenceLabel)
        }
    }

    /// The line under the meal name. A component breakdown says where the numbers came from — but
    /// only the food-matching path matched "local foods"; a recipe log and a cooking-mode log both
    /// carry components too and used to claim the same thing.
    private var displayNote: String {
        guard breakdownText != nil else { return meal.note }
        switch meal.mealSource {
        case .recipe, .mealDefinition:
            return "From your recipe."
        case .manual:
            return "Matched from your foods."
        }
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

/// An editable copy of one `MealComponentSnapshot`, used by the correction and pre-log review
/// editors.
///
/// Only `quantity` is mutable; `snapshot` rebuilds the component with its macros and micronutrients
/// scaled proportionally from the captured base quantity, so re-quantifying never invents nutrition
/// data. `nonisolated` so review state can be constructed off the main actor.
private nonisolated struct MealComponentCorrectionInput: Identifiable {
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

    /// A fresh input for an item ADDED (or swapped in) during correction (FOOD-05): resolved
    /// through the catalog at the food item's own reference serving. A new item has no captured
    /// meal base to scale from, so its base IS that reference — macros and micronutrients scaled
    /// exactly as `MealBuilder`'s component snapshots are, never invented.
    static func fresh(from foodItem: FoodItem) -> MealComponentCorrectionInput {
        let unit = foodItem.preferredRecipeUnit
        let quantity = foodItem.defaultRecipeQuantity(for: unit)
        let ingredient = RecipeIngredient(foodItemId: foodItem.id, quantity: quantity, unit: unit.rawValue)
        return MealComponentCorrectionInput(snapshot: MealComponentSnapshot(
            foodItemId: foodItem.id,
            name: foodItem.name,
            quantity: quantity,
            unit: unit.rawValue,
            macros: ingredient.scaledMacros(using: foodItem),
            micronutrients: ingredient.scaledMicronutrients(using: foodItem)
        ))
    }
}

/// The "Adjust meal" sheet behind every meal row's Adjust action (and the post-log toast's —
/// which is why the type is internal with a stable `init(store:meal:)`).
///
/// Edits the meal's name, type, and either its raw macros (when it has no components) or its
/// matched items — which, per FOOD-05, can now be removed outright, replaced when a match looks
/// wrong (a low-confidence match is outlined in sun and says so in words), re-quantified through
/// a real field, or added to via the same debounced catalog typeahead the recipe editor uses.
/// Persists through `FernletStore.updateMealCorrection` with totals recomputed from the corrected
/// snapshots; template chrome — Cancel + pinned title via the draft guard, Save bottom-right.
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
    /// Ids outlined as "Probably not what you meant", decided ONCE at open over the ORIGINAL
    /// matched items — never over items the user adds or swaps in here.
    private let lowConfidenceComponentIDs: Set<UUID>

    init(store: FernletStore, meal: Meal) {
        self.store = store
        self.meal = meal
        _name = State(initialValue: meal.name)
        _mealType = State(initialValue: meal.mealType)
        _protein = State(initialValue: meal.macros.protein)
        _carbs = State(initialValue: meal.macros.carbs)
        _fat = State(initialValue: meal.macros.fat)
        _components = State(initialValue: meal.componentSnapshots.map(MealComponentCorrectionInput.init(snapshot:)))
        lowConfidenceComponentIDs = Self.lowConfidenceComponentIDs(for: meal)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SheetField("Meal name") {
                        TextField("Meal", text: $name)
                            .sheetTextInput()
                    }

                    SheetField("Meal type") {
                        FlowLayout(spacing: 8) {
                            ForEach(MealType.allCases) { type in
                                Button { mealType = type } label: { Text(verbatim: type.displayName) }
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
                            MealCorrectionItemsEditor(
                                components: $components,
                                lowConfidenceComponentIDs: lowConfidenceComponentIDs,
                                catalog: store.foodCatalog
                            )
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Save", disabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                store.updateMealCorrection(
                    mealID: meal.id,
                    name: name,
                    mealType: mealType,
                    macros: components.isEmpty ? Macros(protein: protein, carbs: carbs, fat: fat) : componentMacros,
                    // nil ONLY for a meal that never had matched items (a raw-macros edit). A
                    // component-backed meal always hands its current list through — including an
                    // EMPTY one, which means "the user removed every item": mapping empty to nil
                    // here made the store keep the old snapshots and resurrect the removals.
                    componentSnapshots: meal.componentSnapshots.isEmpty ? nil : components.map(\.snapshot)
                )
                dismiss()
            }
        }
        .background(Color.parchment)
        // Template chrome (2026-08-21): pinned header with Cancel + the sheet's serif title;
        // Cancel raises the discard prompt while edits are unsaved.
        .fernletDraftGuard(isDirty: isDirty, title: "Adjust meal") {
            dismiss()
        }
    }

    private var componentMacros: Macros {
        let totals = MealBuilder.totals(for: components.map(\.snapshot))
        return Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat)
    }

    /// Whether the sheet holds unsaved edits — drives the swipe-away block and Cancel's discard
    /// prompt in the template chrome.
    private var isDirty: Bool {
        if name != meal.name || mealType != meal.mealType { return true }
        if components.isEmpty {
            // Remove-all (FOOD-05): every matched item was removed — an unsaved edit in itself,
            // even though the macro fields still hold the values they were seeded with at init.
            if !meal.componentSnapshots.isEmpty { return true }
            return Macros(protein: protein, carbs: carbs, fat: fat) != meal.macros
        }
        return components.map(\.snapshot) != meal.componentSnapshots
    }

    /// Component ids to outline as "Probably not what you meant" (FOOD-05).
    ///
    /// Heuristic, honestly so: there is no stored per-item match score, so the mismatch is
    /// reconstructed from the names — a component is suspect when more than half of its
    /// meaningful tokens have nothing to do with what the user typed ("French toast sticks"
    /// against "Scrambled eggs and toast" leaves french/sticks unexplained). Single-token names
    /// are never flagged; one shared word is how they matched at all.
    private static func lowConfidenceComponentIDs(for meal: Meal) -> Set<UUID> {
        let mealTokens = meaningfulTokens(in: meal.name)
        guard !mealTokens.isEmpty else { return [] }
        var flagged = Set<UUID>()
        for component in meal.componentSnapshots {
            let componentTokens = meaningfulTokens(in: component.name)
            guard componentTokens.count > 1 else { continue }
            let unexplained = componentTokens.subtracting(mealTokens).count
            if unexplained * 2 > componentTokens.count {
                flagged.insert(component.id)
            }
        }
        return flagged
    }

    /// Tokens worth comparing: lowercased words of length ≥ 3, non-numeric (mirrors
    /// `MealBuilder`'s matching tokens).
    private static func meaningfulTokens(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && Double($0) == nil }
        )
    }
}

/// The Adjust-meal matched-items editor (FOOD-05): per-item remove, a Replace path for a
/// low-confidence match (sun outline + "Probably not what you meant"), a field-styled editable
/// quantity, an "Add an item" catalog typeahead, and a "New total" footer recomputed from the
/// item list through `MealBuilder` — so the number always matches what is on screen.
///
/// Distinct from ``MealComponentEditorRows`` (the pre-log review's editor, which deliberately
/// only re-quantifies): review components map 1:1 onto a suggested recipe's ingredients, so
/// add/remove there would break that invariant — here the meal is already logged and the list is
/// the user's to edit.
private struct MealCorrectionItemsEditor: View {
    @Binding var components: [MealComponentCorrectionInput]
    /// Ids outlined in sun with the Replace affordance (decided at open by the owning sheet).
    let lowConfidenceComponentIDs: Set<UUID>
    var catalog: FoodCatalog
    /// True while the "Add an item" typeahead is revealed (mutually exclusive with Replace).
    @State private var isAddingItem = false
    /// The component whose Replace typeahead is open, if any.
    @State private var replacingComponentID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($components) { $component in
                componentCard($component)
            }
            addItemSection
            newTotalRow
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
    }

    /// One matched item: name + quantity field + stepper + scaled macros, the low-confidence
    /// notice and Replace typeahead when flagged, and the labelled remove.
    private func componentCard(_ component: Binding<MealComponentCorrectionInput>) -> some View {
        let isLowConfidence = lowConfidenceComponentIDs.contains(component.wrappedValue.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(component.wrappedValue.name)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                Spacer()
                quantityField(component)
                Text(component.wrappedValue.unit)
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.moss)
            }
            Stepper(
                "",
                value: component.quantity,
                in: 0...2000,
                step: component.wrappedValue.unit == RecipeUnit.gram.rawValue ? 5 : 0.25
            )
            .labelsHidden()
            scaledMacrosLine(component.wrappedValue)
            if isLowConfidence {
                lowConfidenceNotice(component.wrappedValue)
            }
            if replacingComponentID == component.wrappedValue.id {
                replaceField(for: component.wrappedValue)
            }
            removeButton(component.wrappedValue)
        }
        .padding(12)
        .background(Color.parchment.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        // The sun outline says "look at this one" without shouting (FOOD-05).
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isLowConfidence ? Color.goldenrod : Color.clear, lineWidth: 1.5)
        )
    }

    /// The quantity as a real FIELD — cream fill, taupe underline — so it stops reading as
    /// static text (FOOD-05).
    private func quantityField(_ component: Binding<MealComponentCorrectionInput>) -> some View {
        TextField("Qty", value: component.quantity, format: .number.precision(.fractionLength(0...1)))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .textContentType(.none)
            .font(.fernlet(.stat))
            .foregroundStyle(Color.bark)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: 76)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.softTaupe)
                    .frame(height: 1.5)
                    .padding(.horizontal, 6)
            }
    }

    private func scaledMacrosLine(_ component: MealComponentCorrectionInput) -> some View {
        let macros = component.snapshot.macros
        return Text("P \(macros.protein)g  C \(macros.carbs)g  F \(macros.fat)g")
            .font(.fernlet(.stat))
            .foregroundStyle(Color.slate)
    }

    /// "Probably not what you meant" in words beside the Replace affordance — a bad match can be
    /// replaced rather than deleted-and-re-logged.
    private func lowConfidenceNotice(_ component: MealComponentCorrectionInput) -> some View {
        HStack(spacing: 10) {
            Text("Probably not what you meant")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.bark)
            Spacer(minLength: 0)
            Button("Replace") {
                replacingComponentID = replacingComponentID == component.id ? nil : component.id
                isAddingItem = false
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.moss)
            .fernletTapTarget()
        }
    }

    /// The Replace typeahead, prefilled with the suspect match's name. A pick swaps the item for
    /// a FRESH catalog resolution (`MealComponentCorrectionInput.fresh`).
    private func replaceField(for component: MealComponentCorrectionInput) -> some View {
        MealItemSearchField(catalog: catalog, prompt: "Search the catalog", initialText: component.name) { foodItem in
            if let index = components.firstIndex(where: { $0.id == component.id }) {
                components[index] = .fresh(from: foodItem)
            }
            replacingComponentID = nil
        }
    }

    /// The labelled per-item remove (FOOD-05) — a word in the destructive ink, not a bare x.
    private func removeButton(_ component: MealComponentCorrectionInput) -> some View {
        Button {
            components.removeAll { $0.id == component.id }
        } label: {
            Text("Remove")
                .font(.fernlet(.label))
                .foregroundStyle(Color.terracottaInk)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(component.name)")
    }

    /// "Add an item" opens the same debounced catalog typeahead the recipe editor uses; new items
    /// resolve fresh through the catalog (they have no micronutrient base to scale).
    @ViewBuilder private var addItemSection: some View {
        Button {
            isAddingItem.toggle()
            replacingComponentID = nil
        } label: {
            Label("Add an item", systemImage: "plus.circle")
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if isAddingItem {
            MealItemSearchField(catalog: catalog, prompt: "sourdough toast", initialText: "") { foodItem in
                components.append(.fresh(from: foodItem))
                isAddingItem = false
            }
        }
    }

    /// The named total, recomputed from the item list via `MealBuilder.totals` — always the same
    /// number Save would persist.
    private var newTotalRow: some View {
        let totals = MealBuilder.totals(for: components.map(\.snapshot))
        return HStack(spacing: 14) {
            Text("New total")
                .foregroundStyle(Color.bark)
            Text("P \(totals.macros.protein)g").foregroundStyle(Color.moss)
            Text("C \(totals.macros.carbs)g")
            Text("F \(totals.macros.fat)g")
            Spacer(minLength: 0)
        }
        .font(.fernlet(.stat))
        .foregroundStyle(Color.slate)
    }
}

/// The debounced catalog typeahead field used by Adjust meal's Replace and "Add an item" paths —
/// the recipe editor's search mechanics (``CatalogTypeahead``) and suggestion rows
/// (``CatalogSuggestionRow``), reusable outside the ingredient editor's binding model.
///
/// Picks hand back the raw `FoodItem`; the owner decides what to build from it. The query never
/// runs in `body` — the `.task(id:)` keystroke cancellation is what keeps stale results out.
private struct MealItemSearchField: View {
    var catalog: FoodCatalog
    /// The field's placeholder (authored copy).
    var prompt: LocalizedStringKey
    /// Seed text — the suspect match's name on the Replace path, empty for Add.
    var initialText: String
    var onPick: (FoodItem) -> Void
    @State private var searchText: String
    @State private var matches: [FoodItem] = []

    init(catalog: FoodCatalog, prompt: LocalizedStringKey, initialText: String, onPick: @escaping (FoodItem) -> Void) {
        self.catalog = catalog
        self.prompt = prompt
        self.initialText = initialText
        self.onPick = onPick
        _searchText = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.slate)
                TextField(prompt, text: $searchText)
                    .font(.fernlet(.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.none)
            }
            ForEach(matches) { foodItem in
                CatalogSuggestionRow(foodItem: foodItem) { onPick(foodItem) }
            }
        }
        // One settled-keystroke query at a time, off the main actor — the same contract as the
        // recipe editor's typeahead (see `CatalogTypeahead.matches`).
        .task(id: searchText) {
            guard let hits = await CatalogTypeahead.matches(for: searchText, catalog: catalog) else { return }
            matches = hits
        }
    }
}

// MARK: - Shared meal editor rows (used by correction + pre-log review)

/// The three protein/carb/fat input rows used when a meal has no component breakdown.
///
/// Shared by ``MealCorrectionSheet`` and ``MealReviewSheet`` so post-log correction and pre-log
/// review edit macros identically.
private struct MealMacroEditorRows: View {
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

/// The per-component quantity editor (typeable amount plus stepper, with live scaled macros) for a
/// meal that has matched catalog components.
///
/// Shared by ``MealCorrectionSheet`` and ``MealReviewSheet``; the footer totals recompute through
/// `MealBuilder.totals` so they always match what would be logged.
private struct MealComponentEditorRows: View {
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

/// Mutable review-sheet state for one resolved meal: an editable name, type, and macros or component
/// quantities layered over the immutable base meal.
///
/// `applied` produces the meal the user actually logs — edits folded in, totals and micronutrients
/// recomputed from the edited components, `isAIFallback` cleared, and confidence stamped "Reviewed".
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
        meal.confidence = MealConfidence.reviewed.token
        meal.quality = meal.macros.protein >= Macros.goodProteinThreshold ? .good : .ok
        return meal
    }
}

/// The pre-log review sheet for low-confidence or fabricated resolutions — nothing reaches the diary
/// until the user confirms here.
///
/// Each resolved meal is editable in place (name, type, macros or component quantities), and when the
/// decomposition tier suggested a recipe the sheet offers it with an editable name and yield. On "Log
/// meal" the reviewed meals plus the optionally confirmed recipe are handed back through `onConfirm`,
/// so the caller commits both through the same `commitResolution` path — the recipe is minted only on
/// this confirm, never at resolve time. `isLogging` one-shots the button so a fast double-tap can't
/// log the meal twice.
private struct MealReviewSheet: View {
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
    /// Items the user typed that the resolver bound nothing to (`MealResolution.unmatchedItems`).
    /// Named on screen so a dropped ingredient is visible before the meal is logged, not discovered
    /// afterwards by reading the row.
    private let unmatchedItems: [String]
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
        self.unmatchedItems = resolution.unmatchedItems
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

                    unmatchedItemsCard

                    ForEach($meals) { $meal in
                        VStack(alignment: .leading, spacing: 14) {
                            SheetField("Meal name") {
                                TextField("Meal", text: $meal.name)
                                    .sheetTextInput()
                            }

                            SheetField("Meal type") {
                                FlowLayout(spacing: 8) {
                                    ForEach(MealType.allCases) { type in
                                        Button { $meal.mealType.wrappedValue = type } label: { Text(verbatim: type.displayName) }
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

    /// Names the words nothing was found for, as chips, above the meal being reviewed. Nothing is
    /// guessed on the user's behalf: the meal logs without them unless the user adds the nutrition
    /// themselves below (or backs out and rewords).
    @ViewBuilder private var unmatchedItemsCard: some View {
        if !unmatchedItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't find")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .tracking(0.8)
                FlowLayout(spacing: 8) {
                    ForEach(unmatchedItems, id: \.self) { item in
                        Text(item)
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.bark)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.parchment, in: Capsule())
                            .overlay(Capsule().stroke(Color.goldenrod.opacity(0.5), lineWidth: 1))
                    }
                }
                Text("These aren't counted in the macros below. Adjust the numbers to include them, or log the meal without them.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.goldenrod.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("mealReview.unmatchedItems")
        }
    }

    private var reviewMessage: String {
        switch confidence {
        case .low:
            return "Fernlet wasn't sure this matched what you ate, so it's a rough estimate. Adjust anything that looks off, then log it."
        default:
            return unmatchedItems.isEmpty
                ? "Double-check the items below before logging."
                : "Fernlet matched part of what you typed. Check what's here before logging."
        }
    }
}

#if canImport(UIKit)
/// The 54pt sealed-photo thumbnail on a meal row.
///
/// Loads the photo bytes lazily off the injected closures and renders one of three honest fallbacks
/// via ``MealPhotoPresence``: the decoded image, an "on your other device" glyph (no sealed file
/// here), or a "couldn't be opened" glyph (file present but unreadable).
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
            // A sealed file that's here but won't decode is `.unavailable`, not the neutral "no photo
            // yet" placeholder — classify it honestly instead of continuing past the failed decode.
            guard let decoded = UIImage(data: data) else {
                sealedFileExists = true
                bytesAvailable = false
                return
            }
            bytesAvailable = true
            image = decoded
        }
    }
}
#endif

/// A manual recipe's row in the recipe lists: name, servings, ingredient count, notes preview, and
/// per-serving macros.
///
/// Rendered at `.headerMedium` — a deliberate step down from `MealRow`'s title, since recipes are a
/// shortcut list beneath the meal log rather than the log itself.
private struct RecipeRow: View {
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
                    // Slate like its neighbours: goldenrod on this 12pt row measured 2.4:1, and the
                    // figure carries meaning rather than decoration.
                    Text("\(perServing.calories) cal").foregroundStyle(Color.slate)
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
/// ingredient list, and notes — plus log / edit / share.
///
/// Reached by tapping a recipe in the book (which used to jump straight into the editor). Recipe photos
/// are the user's own pick or the page's one-attempt web default, sealed and keyed by the recipe id.
/// Also hosts the ephemeral F4 "cook for N" view-only scaling, the per-ingredient Swap flow
/// (``IngredientSubstitutionSheet``), the F5 ``CookingModeView`` full-screen cover, and — for web
/// imports — the source-link connection pre-warm plus the explicit "Re-import from source" toolbar
/// refresh (photo and notes preserved; owner decision 2026-08-09).
struct RecipeDetailView: View {
    var store: FernletStore
    /// The recipe as the call site pushed it. Display goes through the computed ``recipe`` so an
    /// in-place "Re-import from source" can swap in the refreshed definition without re-pushing.
    private let initialRecipe: RecipeDefinition
    var onEdit: () -> Void
    /// Persists an F4 substitution FORK into the SAME store the source recipe lives in (blob vs saved).
    /// Wired per call site; a no-op default keeps non-substitutable call sites compiling unchanged.
    var onSaveFork: (RecipeDefinition) -> Void = { _ in }
    /// Logs the recipe. Receives the definition CURRENTLY on screen (`reimportedRecipe ??
    /// initialRecipe`) — not the copy the call site captured at push time — so logging right after
    /// an in-place "Re-import from source" records the refreshed macros the user is looking at,
    /// never the stale pre-refresh snapshot.
    var onLog: (RecipeDefinition, MealType) -> Void
    /// Opens the proximity share sheet for the definition CURRENTLY on screen (same currency rule
    /// as `onLog`: a peer must receive the refreshed ingredients, not a pre-re-import copy).
    var onShare: (RecipeDefinition) -> Void
    /// Logs the meal on cooking-mode COMPLETION, anchored to the day-key captured when the cook STARTED
    /// (F5, §6.4). Distinct from `onLog` (immediate, today): routed per call site to `logRecipe` (manual)
    /// vs `logSavedRecipe` (saved/web), each with an explicit `date:`. Receives the on-screen
    /// definition like `onLog`. A no-op default keeps any non-updated call site compiling; the
    /// real sites wire it.
    var onCookLog: (RecipeDefinition, MealType, String) -> Void = { _, _, _ in }

    /// Creates the detail. Mirrors the old memberwise init exactly (same labels, same defaults) —
    /// it exists only because `initialRecipe` is private, which hides the memberwise init.
    init(
        store: FernletStore,
        recipe: RecipeDefinition,
        onEdit: @escaping () -> Void,
        onSaveFork: @escaping (RecipeDefinition) -> Void = { _ in },
        onLog: @escaping (RecipeDefinition, MealType) -> Void,
        onShare: @escaping (RecipeDefinition) -> Void,
        onCookLog: @escaping (RecipeDefinition, MealType, String) -> Void = { _, _, _ in }
    ) {
        self.store = store
        self.initialRecipe = recipe
        self.onEdit = onEdit
        self.onSaveFork = onSaveFork
        self.onLog = onLog
        self.onShare = onShare
        self.onCookLog = onCookLog
    }

    /// The definition currently on screen: the re-imported refresh when one landed this
    /// presentation, else the recipe the call site pushed. Every read in this view goes through
    /// this, so a successful "Re-import from source" updates the visible page immediately.
    private var recipe: RecipeDefinition { reimportedRecipe ?? initialRecipe }

    /// The refreshed definition after a successful "Re-import from source" — view-local, because
    /// the pushed detail was constructed with a value copy that the store update can't reach.
    @State private var reimportedRecipe: RecipeDefinition?
    /// True while the explicit re-import fetch is in flight; disables the toolbar affordance.
    @State private var isReimporting = false
    /// Calm inline outcome line for the re-import (success or failure copy).
    @State private var reimportNotice: String?

    /// Presents the F5 full-screen cooking-mode flow (mise-en-place → step walker → finish/log).
    @State private var showingCookingMode = false

    /// True while "Log this recipe" has its inline meal-slot chip row open (2026-08-21, FOOD-14 —
    /// the same chip row as the meal sheet, replacing the old Menu). A chip tap logs and closes it.
    @State private var showingLogMealTypes = false
    /// Drives the Steps card's timer-capsule drop and the Cook/Log unstack at accessibility
    /// sizes (4f·AX3).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

    /// Ephemeral "cook for N" yield (F4, decision §11.4): a purely view-time proportional transform
    /// that NEVER mutates or persists the recipe. `nil` means "show the stored base yield"; it resets
    /// to nil whenever the detail is dismissed, because it is plain `@State` on a fresh view instance.
    /// The store log path (`onLog`) keeps its own reference to the original `recipe` and never reads
    /// this, so logging while scaled records one serving exactly as it does un-scaled.
    @State private var cookYield: Int?

    /// The BASE ingredient a swap targets (F4 substitution). Set from a "Swap" tap; drives the
    /// substitution sheet. Always the stored base ingredient, never a scaled display copy — the fork is
    /// built from the recipe's saved quantities, independent of the ephemeral cook-for view scale.
    @State private var substitutionTarget: RecipeIngredient?

    /// The yield currently on screen: the ephemeral cook-for override, or the stored base yield.
    private var effectiveYield: Int { cookYield ?? recipe.servings }

    /// True only when a structured (scalable) recipe is being shown at a yield other than its stored
    /// base — drives the scaled ingredient/total rendering and the "view only" note.
    private var isScaled: Bool { RecipeScaling.isScalable(recipe) && effectiveYield != recipe.servings }

    /// Whole-recipe totals AS DISPLAYED: base totals scaled to the cook-for yield for structured
    /// recipes, or the base totals unchanged (web imports, and the un-scaled case). `perServing`
    /// below is deliberately NOT derived from this — per-serving stays pinned to the base recipe, so
    /// "total scales, per-serving does not".
    private var displayTotals: MacroTotals {
        guard isScaled else { return totals }
        return RecipeScaling.scaledTotals(totals, baseServings: recipe.servings, targetYield: effectiveYield)
    }

    /// Structured ingredients AS DISPLAYED — quantities scaled to the cook-for yield, or the stored
    /// quantities when un-scaled. Empty for web imports (those render free-text lines instead).
    /// Scaling preserves each ingredient's `id`/`foodItemId`, so the `resolvedItems` name lookup and
    /// the `ForEach` identity are unaffected.
    private var displayIngredients: [RecipeIngredient] {
        guard isScaled else { return recipe.ingredients }
        return RecipeScaling.scaledIngredients(recipe, forYield: effectiveYield)
    }

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
        detailPresentations(detailScroll)
    }

    private var detailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                photoSection
                noticeLines
                titleBlock
                macrosCard
                yieldControl
                ingredientsCard
                stepsCard
                if !recipe.notes.isEmpty { notesCard }
                actionsRow
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .background(Color.parchment)
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        // Warm the DNS/TLS connection to the source host while the detail is up, so the source
        // link opens near-instantly (owner decision 2026-08-09; documented in
        // Docs/No-Tracking-Wall.md §4b).
        .prewarmsSourceLinkConnection(for: recipe.webImport)
        .toolbar { reimportToolbar }
        // Resolve the manual recipe's structured ingredients (a FoodCatalog SQLite read) into a cached
        // dictionary, keyed on the ingredient ids so an edit-and-save under this detail (the editor
        // presents over a pushed detail) re-resolves — a once-guard here left added/swapped ingredients
        // rendering as a generic "Ingredient" until pop-and-repush. Unchanged ids don't re-query, so a
        // detail left on screen still doesn't hit SQLite on every store mutation. Web imports have no
        // structured ingredients — they render free-text lines instead.
        .task(id: recipe.ingredients.map(\.foodItemId)) {
            await resolveIngredients()
        }
        .task {
            await loadPhotoIfNeeded()
        }
    }

    /// The photo-save and re-import outcome lines.
    @ViewBuilder private var noticeLines: some View {
        if let photoNotice {
            Text(photoNotice)
                .font(.fernlet(.bodySmall))
                .italic()
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        if let reimportNotice {
            Text(reimportNotice)
                .font(.fernlet(.bodySmall))
                .italic()
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recipe.name)
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)
            Text("\(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
        }
    }

    /// Explicit refresh for a web-imported recipe (owner decision 2026-08-09): repeat imports of the
    /// same URL now skip the network and surface the saved recipe, so THIS is the one way to re-fetch
    /// the page. Photo and notes are preserved (same-id replace — see
    /// `FernletStore.reimportSavedRecipeFromSource`).
    @ToolbarContentBuilder private var reimportToolbar: some ToolbarContent {
        if recipe.webImport?.sourceURL?.isSafariPresentable == true {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmReimportFromSource()
                } label: {
                    Label("Re-import from source", systemImage: "arrow.clockwise")
                }
                .disabled(isReimporting)
                .accessibilityIdentifier("recipeDetail.reimport")
            }
        }
    }

    /// Caches the recipe's structured ingredients resolved through the catalog (see the `.task(id:)`
    /// note above for why this is keyed on the ingredient ids).
    private func resolveIngredients() async {
        let ingredientIDs = recipe.ingredients.map(\.foodItemId)
        guard !ingredientIDs.isEmpty else { return }
        resolvedItems = Dictionary(
            store.foodCatalog.items(ids: ingredientIDs).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Loads the recipe's sealed photo once per presentation, falling back to the lazy web-image
    /// fetch for a share-extension import that stored only the page's image URL.
    private func loadPhotoIfNeeded() async {
        // The photo load keeps its own once-guard — it's a separate cache from the ingredient
        // resolution and shouldn't re-decode when ingredients change.
        guard !didLoadPhoto else { return }
        didLoadPhoto = true
        if let data = store.recipePhotoData(for: recipe.id) {
            photo = await UIImage(data: data)?.byPreparingForDisplay()
        } else if let fetched = await store.fetchRecipeWebImageIfNeeded(for: recipe) {
            // Lazy web-image path (owner decision 2026-08-09): a share-extension-imported
            // recipe stored only the page's image URL — download it on this first open (the
            // user is present), sealed and one-attempt-per-device inside the store method.
            // Recipes whose fetch this device already attempted, whose picture is suppressed
            // (photo deleted), or that arrived over the mesh all no-op there.
            let prepared = await UIImage(data: fetched)?.byPreparingForDisplay()
            // Adopt the fetched bytes only while the user hasn't picked their own photo
            // mid-download — the store re-validates the same race on disk; this mirrors it
            // on screen so a pick during the fetch is never visually clobbered.
            if photo == nil { photo = prepared }
        }
    }

    /// The detail's confirmation + three presentations (source Safari, ingredient swap, cooking
    /// mode), in their original application order.
    private func detailPresentations<V: View>(_ content: V) -> some View {
        content
            .destructiveConfirmation($pendingDestructiveAction)
            .sheet(isPresented: $showingSafari) {
                if let sourceURL = recipe.webImport?.sourceURL, sourceURL.isSafariPresentable {
                    SafariView(url: sourceURL)
                        .ignoresSafeArea()
                }
            }
            .sheet(item: $substitutionTarget) { target in
                IngredientSubstitutionSheet(
                    store: store,
                    recipe: recipe,
                    original: target,
                    originalFoodItem: resolvedItems[target.foodItemId],
                    onSaveFork: onSaveFork
                )
            }
            .fullScreenCover(isPresented: $showingCookingMode) {
                // Carry the detail page's ephemeral "Cook for N" into cooking mode so mise opens at that
                // yield instead of re-defaulting to the base (nil → base yield inside CookingModeView).
                // The completion log routes through onCookLog with the definition on screen at cook
                // start, mirroring onLog's currency rule.
                CookingModeView(store: store, recipe: recipe, initialYield: cookYield, onLogToDay: { mealType, day in
                    onCookLog(recipe, mealType, day)
                })
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
                        .accessibilityLabel("Delete this recipe photo")
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
                Text("Makes \(effectiveYield) serving\(effectiveYield == 1 ? "" : "s"): P \(displayTotals.protein)g · C \(displayTotals.carbs)g · F \(displayTotals.fat)g\(store.settings.showCalories ? " · \(displayTotals.calories) cal" : "")")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
            }
        }
    }

    /// Ephemeral "cook for N" control (F4, §11.4). Shown only for structured recipes — web imports
    /// have free-text ingredient lines with no quantities to rescale, so faking a scale would be a
    /// lie; for them the control is hidden and a one-line note explains why. Everything here is view
    /// state: nothing is written to the store, and dismissing the detail discards the override.
    @ViewBuilder private var yieldControl: some View {
        if RecipeScaling.isScalable(recipe) {
            FernletCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Cook for")
                    Stepper(
                        "\(effectiveYield) serving\(effectiveYield == 1 ? "" : "s")",
                        value: Binding(get: { effectiveYield }, set: { cookYield = $0 }),
                        in: RecipeScaling.yieldRange
                    )
                    .accessibilityIdentifier("recipeDetail.cookForYield")
                    if isScaled {
                        Text("Scaled from \(recipe.servings) serving\(recipe.servings == 1 ? "" : "s") for this view only — your saved recipe is unchanged, and logging still records one serving.")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                        Button("Reset to \(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")") { cookYield = nil }
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.moss)
                            .accessibilityIdentifier("recipeDetail.cookForReset")
                    }
                }
            }
        } else if recipe.webImport != nil {
            Text("Scaling isn't available for imported recipes — their ingredient amounts are free text.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    @ViewBuilder private var ingredientsCard: some View {
        if let webImport = recipe.webImport {
            webImportIngredientsCard(webImport)
        } else {
            structuredIngredientsCard
        }
    }

    /// Web imports keep free-text ingredient lines (no structured food-item resolution) plus the
    /// source URL as a provenance line where a manual recipe's resolved list would be.
    private func webImportIngredientsCard(_ webImport: RecipeWebImport) -> some View {
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
                    SourceLinkRow(url: sourceURL) { showingSafari = true }
                        .padding(.top, 2)
                }
            }
        }
    }

    private var structuredIngredientsCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Ingredients")
                if recipe.ingredients.isEmpty {
                    Text("No ingredients listed.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                } else {
                    ForEach(displayIngredients) { ingredient in
                        structuredIngredientRow(ingredient)
                    }
                }
            }
        }
    }

    /// One resolved ingredient line, with the Swap affordance for structured (scalable) recipes.
    private func structuredIngredientRow(_ ingredient: RecipeIngredient) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.moss.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 7)
            Text(ingredientLine(ingredient))
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            // Swap targets the STORED base ingredient (matched by id), not the scaled
            // display copy — a fork is built from saved quantities. Structured recipes
            // only; web imports have no swappable structured ingredients.
            if RecipeScaling.isScalable(recipe) {
                Spacer(minLength: 6)
                Button {
                    substitutionTarget = recipe.ingredients.first(where: { $0.id == ingredient.id }) ?? ingredient
                } label: {
                    Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The 44pt target centres the glyph well below the ingredient's first text baseline in
                // this top-aligned row; lift it so icon and text read as one line (the target is
                // unchanged — only where it sits).
                .padding(.top, -6)
                .accessibilityLabel("Swap \(resolvedItems[ingredient.foodItemId]?.name ?? "ingredient")")
                .accessibilityIdentifier("recipeDetail.swapIngredient")
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
            // FernletCard hugs its content when nothing inside stretches, which left this card
            // visibly narrower than the macro/ingredient cards above it.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The Steps card (2026-08-21, FOOD-22): the recipe's authored steps, readable WITHOUT
    /// starting cooking mode — Cook stays the hands-free walker, no longer the only way to see
    /// what you wrote. Numbered 44pt circles beside the step text; a quiet timer capsule renders
    /// where `durationSeconds` is set (and drops at accessibility sizes — 4f·AX3).
    @ViewBuilder private var stepsCard: some View {
        if let steps = recipe.steps, !steps.isEmpty {
            FernletCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Steps")
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(number: index + 1, step: step)
                    }
                }
            }
        }
    }

    /// One step: the 44pt numbered circle, the step text, and the trailing timer capsule.
    private func stepRow(number: Int, step: RecipeStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .frame(width: 44, height: 44)
                .background(Color.moss.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(step.text)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
                .padding(.top, 11)
            Spacer(minLength: 0)
            if let seconds = step.durationSeconds, seconds > 0, !dynamicTypeSize.isAccessibilitySize {
                stepTimerCapsule(seconds)
                    .padding(.top, 11)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(step.text)")
    }

    /// The quiet duration capsule — locale-aware unit formatting so an overnight step reads
    /// "8 hr" and a short one "8 min" (seconds appear only for a sub-minute remainder).
    private func stepTimerCapsule(_ seconds: Int) -> some View {
        Label {
            Text(
                Duration.seconds(seconds),
                format: .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
            )
        } icon: {
            Image(systemName: "timer")
        }
        .font(.fernlet(.labelSmall))
        .foregroundStyle(Color.slate)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.parchment, in: Capsule())
    }

    /// "Log this recipe" is the ONE primary (FOOD-14) and opens the same meal-slot chip row the
    /// meal sheet uses, inline — replacing the old Menu; Cook is its cream sibling. At
    /// accessibility sizes the pair unstacks full-width, primary on top (4f·AX3).
    private var actionsRow: some View {
        VStack(spacing: 10) {
            logAndCookRow
            if showingLogMealTypes {
                logMealTypeChips
            }
            // Stacks at accessibility sizes rather than breaking "Share" mid-word.
            AdaptiveStack(spacing: 10) {
                Button { onEdit() } label: {
                    secondaryActionLabel("Edit", icon: "pencil")
                }
                .buttonStyle(.plain)
                Button { onShare(recipe) } label: {
                    secondaryActionLabel("Share", icon: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Cook (cream) beside the primary Log; the pair stacks primary-first at accessibility sizes.
    @ViewBuilder private var logAndCookRow: some View {
        if CookingModeAvailability.canCook(recipe) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    logPrimaryButton
                    cookButton
                }
            } else {
                HStack(spacing: 10) {
                    cookButton
                    logPrimaryButton
                }
            }
        } else {
            logPrimaryButton
        }
    }

    private var logPrimaryButton: some View {
        Button {
            withAnimation(FernletMotion.ui) { showingLogMealTypes.toggle() }
        } label: {
            Label("Log this recipe", systemImage: "fork.knife")
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recipeDetail.log")
    }

    private var cookButton: some View {
        Button { showingCookingMode = true } label: {
            Label("Cook", systemImage: "flame")
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.moss.opacity(0.35), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recipeDetail.cook")
    }

    /// The inline meal-slot chips under the primary — a chip tap logs the definition ON SCREEN
    /// (after a re-import this is the refreshed one) and collapses the row.
    private var logMealTypeChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(MealType.allCases) { mealType in
                Button {
                    showingLogMealTypes = false
                    onLog(recipe, mealType)
                } label: {
                    Text(verbatim: mealType.displayName)
                }
                .buttonStyle(ChipButtonStyle(selected: false))
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

    /// Names the host BEFORE the tap that contacts it. A web-imported recipe can arrive over the
    /// proximity mesh carrying a stranger's source URL (`RecipeWebImport.sourceIsPeerSupplied`), so
    /// the one button that deliberately re-fetches must say whose server it is about to reach — and
    /// it replaces the imported ingredients/macros on screen, which is why it routes through the
    /// shared destructive-confirmation affordance rather than firing on a bare tap.
    private func confirmReimportFromSource() {
        let host = recipe.webImport?.sourceURL?.host() ?? "the source page"
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Re-import from \(host)?",
            message: "Fernlet will contact \(host) and replace this recipe's imported ingredients and nutrition with whatever the page says now. Your photo and notes are kept.",
            confirmLabel: "Re-import",
            auditEvent: "recipe.reimport.confirmed",
            perform: { reimportFromSource() }
        )
    }

    /// Runs the explicit "Re-import from source" (owner decision 2026-08-09): re-fetches the source
    /// page and replaces the definition in place, preserving the photo and notes (the store merges
    /// over the LIVE row, so notes edited while the fetch was in flight survive too). A failed
    /// fetch leaves the recipe exactly as it was — only the notice line reports it — and a recipe
    /// deleted mid-flight reports that instead of a false success. A successful refresh also
    /// re-arms this device's one automatic web-image attempt, so a recipe still missing its
    /// picture gets a fresh download while the user is right here.
    private func reimportFromSource() {
        let current = recipe
        let host = current.webImport?.sourceURL?.host() ?? "the source page"
        isReimporting = true
        reimportNotice = "Refreshing from \(host)..."
        Task {
            do {
                if let refreshed = try await store.reimportSavedRecipeFromSource(current) {
                    reimportedRecipe = refreshed
                    reimportNotice = "Refreshed from \(host). Your photo and notes are kept."
                    // The refresh re-armed the web-image attempt: if the recipe still has no
                    // picture, fetch it now (same post-pick screen guard as the first-open path).
                    if photo == nil, let fetched = await store.fetchRecipeWebImageIfNeeded(for: refreshed) {
                        let prepared = await UIImage(data: fetched)?.byPreparingForDisplay()
                        if photo == nil { photo = prepared }
                    }
                } else {
                    reimportNotice = "This recipe was deleted, so there's nothing to refresh."
                }
            } catch {
                reimportNotice = (error as? LocalizedError)?.errorDescription ?? "Could not re-import this recipe."
            }
            isReimporting = false
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

/// One macro entry row: a tappable value that flips into a focused numeric text field, plus a
/// stepper.
///
/// Commits on focus loss (clamped to `range`); nudging the stepper while editing commits its value
/// and closes the field. Used across the ingredient, correction, and review editors.
private struct MacroInputRow: View {
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
                    // Same DM Sans figures the tapped value shows, so the number doesn't change
                    // typeface the moment it becomes editable.
                    .font(.fernlet(.stat))
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
        if let n = LocaleTolerantNumber.int(from: textValue), range.contains(n) { value = n }
        isEditing = false
    }
}

/// The "Create recipe" chooser: Import (URL or shared Fernlet text) or Manual entry.
///
/// Pushed from the recipe book's Create button. Nutrition-label scanning is deliberately absent here —
/// it belongs to the barcode-not-found handoff, not to recipe creation.
///
/// This view never pops itself. Saving used to clear the editor's destination flag AND call
/// `dismiss()` in the same update; when SwiftUI coalesced the two pops the user landed back on this
/// chooser with the recipe already saved. The push state for the WHOLE branch — chooser and editor
/// alike — belongs to ``RecipeBookSheet`` instead, so finishing is one assignment there and both
/// levels come off together.
private struct RecipeCreationOptionsView: View {
    var store: FernletStore
    /// Reports a finished creation to the recipe book, which collapses the branch and shows the
    /// confirmation line. Both branches hand their saved name straight to it.
    var onCreated: (String) -> Void = { _ in }

    /// The editor this chooser can push: the import screen or the manual editor.
    private enum CreationStep: Hashable { case importing, manual }

    /// Which editor is pushed above the chooser, if any. One optional value rather than two
    /// independent Bools, so "import" and "manual entry" can never both claim the destination.
    @State private var step: CreationStep?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose how to start.")
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.slate)

                VStack(spacing: 10) {
                    // Recipe creation is Import or Manual only. Nutrition-label scanning belongs to the
                    // barcode-not-found handoff (BarcodeNotFoundView, reached from the camera when a scanned
                    // barcode has no catalog match) — not as a standalone recipe-creation entry point.
                    Button { step = .importing } label: {
                        RecipeCreationOptionRow(
                            title: "Import recipe",
                            subtitle: "Paste a recipe URL or Fernlet recipe text.",
                            systemImage: "tray.and.arrow.down"
                        )
                    }
                    .buttonStyle(.plain)

                    Button { step = .manual } label: {
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
        // Saving reports the name and stops there: the book pops the editor AND this chooser with
        // the one assignment it owns. Clearing `step` here too would put a second, racing pop back
        // into the same update — the bug this replaced.
        .navigationDestination(item: $step) { destination in
            switch destination {
            case .importing:
                RecipeImportSheet(store: store, onSaved: onCreated)
            case .manual:
                RecipeSheet(store: store, isEmbeddedInNavigationStack: true, onSaved: onCreated)
            }
        }
    }
}

/// One tappable option card (icon, title, subtitle, chevron) in ``RecipeCreationOptionsView``.
///
/// Purely presentational — the wrapping `Button` (which sets the chooser's `step`) provides the
/// behavior.
private struct RecipeCreationOptionRow: View {
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

/// The 44pt share-icon button on a recipe row.
///
/// Fires the injected action, which builds a `ProximityRecipeShareDraft` for the proximity
/// recipe-share sheet.
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

/// A recipe row's trailing controls line plus its inline log flow (2026-08-21, FOOD-19/FOOD-14):
/// a labelled "Log" pill — replacing the bare fork-icon menu — that opens the meal-slot chip row
/// INLINE beneath the controls; a chip tap logs and collapses it. `trailing` carries the row's
/// other controls (the share button, or nothing). At accessibility sizes the trailing line holds
/// only Log, and the other controls drop to their own line beneath it (4e·AX3).
///
/// Shared by the Food-root recipe preview, the recipe book's rows, and the imported-products list
/// so logging behaves identically everywhere a recipe row appears.
private struct RecipeRowLogControl<Trailing: View>: View {
    /// Logs the row's recipe as the chosen slot (the owner routes to the right store half).
    var onLog: (MealType) -> Void
    @ViewBuilder var trailing: () -> Trailing
    @State private var showingMealTypes = false
    /// Drives the 4e·AX3 degradation: at accessibility sizes the grown Log and Share pills no
    /// longer share one trailing line — Share moves below.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                // 4e·AX3: only Log on the trailing line; the row's other controls move below.
                // (`trailing()` may be an EmptyView, which contributes no row even when modified.)
                logButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
                trailing()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    logButton
                    trailing()
                }
            }
            if showingMealTypes {
                mealTypeChipRow
            }
        }
    }

    /// The labelled Log pill (FOOD-14): reveals or hides the inline meal-slot chip row.
    private var logButton: some View {
        Button("Log") {
            withAnimation(FernletMotion.ui) { showingMealTypes.toggle() }
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
        .accessibilityLabel("Log recipe as meal")
    }

    /// The inline meal-slot chip row a Log tap reveals; a chip tap logs and collapses it.
    private var mealTypeChipRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(MealType.allCases) { mealType in
                Button {
                    showingMealTypes = false
                    onLog(mealType)
                } label: {
                    Text(verbatim: mealType.displayName)
                }
                .buttonStyle(ChipButtonStyle(selected: false))
            }
        }
    }
}

/// A row for a saved web-imported product in the recipe book's "Imported products" section.
///
/// Shows name, brand/source host, serving description, and macros; logging happens via the row's
/// ``RecipeRowLogControl`` beneath.
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

/// The full recipe book: searchable, labelled A–Z lists (Your recipes / Saved from web /
/// Imported products), plus the Create/Planner/List entry points as three equal secondaries
/// (2026-08-21, FOOD-19/FOOD-14).
///
/// Sheet mode carries the template's pinned header with Done in the trailing slot — the book's
/// first close control; pushed mode keeps the back chevron and no Done. Rows push the read-only
/// ``RecipeDetailView``; edit requests are handed back to ``FoodView`` via the two editing
/// bindings (the book dismisses and the owning view presents the right editor sheet). Sharing
/// goes through the proximity recipe-share sheet; row logging goes through ``RecipeRowLogControl``
/// and reports to `onMealsLogged` for the post-log toast.
struct RecipeBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    @Binding var editingRecipe: RecipeDefinition?
    @Binding var editingSavedRecipe: RecipeDefinition?
    /// True when the book is PUSHED inside a host stack (the Food tab) rather than presented as a
    /// sheet. Then it draws no stack of its own — book → detail → editor is one stack, so an edit
    /// started here returns to the recipe instead of dropping to the Food root — and it titles itself
    /// in the nav bar. The Home shortcut still presents it as a sheet, which keeps its own stack.
    var isEmbeddedInNavigationStack = false
    /// Reports meals logged from the book's rows and details so the host can raise the post-log
    /// toast (FLOW-15). FoodView threads its own callback through; the Home sheet route passes
    /// ContentView's. Defaults to a no-op so construction sites compile before wiring.
    var onMealsLogged: ([Meal]) -> Void = { _ in }
    @State private var searchText = ""
    @State private var recipeShareDraft: ProximityRecipeShareDraft?
    /// Calm confirmation after a recipe is created, shown here because this is where the create flow
    /// now lands (see ``RecipeCreationOptionsView``). Clears itself after a beat.
    @State private var createdNotice: String?
    /// The single switch for the whole create-recipe branch: chooser, plus whichever editor the
    /// chooser pushed above it. Clearing it pops BOTH levels at once, so finishing a recipe is one
    /// assignment rather than two pops racing inside one SwiftUI update (the chooser used to clear
    /// its editor flag and `dismiss()` itself in the same tick, and a coalesced pair left the user
    /// standing on the "Import recipe / Manual entry" chooser with the recipe already saved).
    @State private var isCreatingRecipe = false

    @ViewBuilder
    var body: some View {
        if isEmbeddedInNavigationStack {
            bookContent
        } else {
            // Sheet mode gets the template's pinned header with Done in the TRAILING slot — the
            // same slot every sheet uses (FOOD-19: the book finally has a close control). Pushed
            // mode keeps the back chevron and no Done; there is nothing to close.
            NavigationStack {
                VStack(spacing: 0) {
                    SheetHeader(
                        title: "Recipe book",
                        subtitle: "Recipes and saved products, A\u{2013}Z.",
                        onDone: { dismissIfPresented() }
                    )
                    bookContent
                }
            }
            .background(Color.parchment)
        }
    }

    /// Header line, toolbar, search field, and the three labelled A–Z lists — the scrolling half
    /// of ``bookContent``.
    private var bookScrollContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Pushed: the nav bar carries the title. Presented: the pinned SheetHeader above the
            // scroll carries it, so only the pushed mode draws its subtitle here.
            if isEmbeddedInNavigationStack {
                Text("Recipes and saved products, A\u{2013}Z.")
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.slate)
            }
            if let createdNotice {
                Text(createdNotice)
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.moss)
                    .fernletWrappingText()
                    .accessibilityIdentifier("recipeBook.createdNotice")
            }
            createAndPlannerButtons

            TextField("Search recipes and products", text: $searchText)
                .sheetTextInput()
            // Section labels name what you are looking at (FOOD-19): Your recipes, Saved from
            // web, Imported products — only the products had a heading before.
            let allManual = filteredManualRecipes
            if !allManual.isEmpty {
                sectionHeading("Your recipes")
                recipesCard(allManual, isSaved: false)
            }
            let allSaved = filteredSavedRecipes
            if !allSaved.isEmpty {
                sectionHeading("Saved from web")
                recipesCard(allSaved, isSaved: true)
            }
            let allProducts = filteredWebImportedProducts
            if !allProducts.isEmpty {
                importedProductsCard(allProducts)
            }
            if allManual.isEmpty && allSaved.isEmpty && allProducts.isEmpty && !searchText.isEmpty {
                emptySearchState
            }
        }
        .padding(20)
        .padding(.bottom, 24)
    }

    private var bookContent: some View {
        ScrollView {
            bookScrollContent
        }
        .background(Color.parchment)
        .navigationTitle(isEmbeddedInNavigationStack ? "Recipe book" : "")
        .navigationBarTitleDisplayMode(.inline)
        // The create branch hangs off the book, not off the chooser, so `finishCreation` collapses
        // chooser + editor in one go and the user lands back here — the new recipe's home.
        .navigationDestination(isPresented: $isCreatingRecipe) {
            RecipeCreationOptionsView(store: store, onCreated: { name in finishCreation(named: name) })
        }
        .task(id: createdNotice) {
            guard createdNotice != nil else { return }
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                // Superseded by a newer creation (or the book went away) — that one owns the line.
                return
            }
            createdNotice = nil
        }
        .sheet(item: $recipeShareDraft) { draft in
            ProximityRecipeShareSheet(draft: draft, manager: store.recipeShareManager, store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }

    /// Lands a finished creation back on the book. `isCreatingRecipe = false` is the ONLY navigation
    /// change: it removes the chooser destination, and with it the editor the chooser had pushed, so
    /// there is no second pop to be dropped or reordered. The notice is plain state, applied in the
    /// same update but driving nothing but text.
    private func finishCreation(named recipeName: String) {
        isCreatingRecipe = false
        createdNotice = "\u{201C}\(recipeName)\u{201D} added to your recipes."
    }

    /// Closes the book only when it is a sheet. Pushed inside the Food stack there is nothing to
    /// close — the editor sheet presents OVER the book, which is the whole point of pushing it.
    private func dismissIfPresented() {
        guard !isEmbeddedInNavigationStack else { return }
        dismiss()
    }

    /// Create-recipe plus the F3 grocery entry points, as THREE EQUAL secondaries (XCUT-14 —
    /// Create lost its moss fill: entering the book is not the same as committing anything). The
    /// planner persists a per-day plan; the list builder is one-off; both aggregate through the
    /// shared Phase A pipeline and share to Notes.
    private var createAndPlannerButtons: some View {
        // Stacks at accessibility sizes: side by side these broke mid-word at different heights.
        AdaptiveStack(spacing: 12) {
            // A Button rather than a NavigationLink: the push is driven by `isCreatingRecipe`, the
            // one value that also un-pushes the whole branch when a recipe is saved.
            Button {
                isCreatingRecipe = true
            } label: {
                plannerLabel("Create", systemImage: "plus")
            }
            .buttonStyle(.plain)
            NavigationLink {
                WeeklyMealPlannerView(store: store)
            } label: {
                plannerLabel("Planner", systemImage: "calendar")
            }
            .buttonStyle(.plain)
            NavigationLink {
                ShoppingListBuilderView(store: store)
            } label: {
                plannerLabel("List", systemImage: "cart")
            }
            .buttonStyle(.plain)
        }
    }

    /// One of the three equal toolbar secondaries. `LocalizedStringKey` — a `String` parameter
    /// would silently opt the call sites out of localization.
    private func plannerLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.fernlet(.label))
            .foregroundStyle(Color.moss)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    /// A named section heading over one of the book's three lists (FOOD-19).
    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.fernlet(.header))
            .foregroundStyle(Color.bark)
    }

    /// One A–Z card of recipes. `isSaved` selects the saved/web store's methods (edit sheet, log,
    /// share text) over the manual store's — the rows are otherwise identical.
    private func recipesCard(_ recipes: [RecipeDefinition], isSaved: Bool) -> some View {
        FernletCard {
            VStack(spacing: 0) {
                ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                    if index > 0 { FernletRowDivider() }
                    recipeRow(recipe, isSaved: isSaved)
                }
            }
        }
    }

    /// A recipe-book row in the Food-root layout (FOOD-19/FOOD-14): the tappable summary above —
    /// so "2 servings" sits at the trailing edge instead of drifting to the middle — with the
    /// labelled Log pill (inline meal-slot chips) and the share button on their own trailing line.
    private func recipeRow(_ recipe: RecipeDefinition, isSaved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            #if canImport(UIKit)
            // Tapping a recipe opens a read-only detail view (photo, per-serving macros, ingredients,
            // notes) rather than jumping straight into the editor — the detail offers edit/log/share.
            // For a saved/web recipe, Edit opens its notes/delete sheet (no structured ingredients).
            NavigationLink {
                recipeDetail(for: recipe, isSaved: isSaved)
            } label: {
                recipeRowLabel(recipe, isSaved: isSaved)
            }
            .buttonStyle(.plain)
            #else
            Button { beginEditing(recipe, isSaved: isSaved); dismissIfPresented() } label: {
                recipeRowLabel(recipe, isSaved: isSaved)
            }
            .buttonStyle(.plain)
            #endif
            RecipeRowLogControl(onLog: { mealType in
                logRecipe(recipe, mealType: mealType, isSaved: isSaved)
                dismissIfPresented()
            }) {
                RecipeShareButton {
                    recipeShareDraft = shareDraft(for: recipe, isSaved: isSaved)
                }
            }
        }
    }

    @ViewBuilder private func recipeRowLabel(_ recipe: RecipeDefinition, isSaved: Bool) -> some View {
        if isSaved {
            SavedRecipeRow(recipe: recipe)
        } else {
            RecipeRow(recipe: recipe, totals: store.macroTotals(for: recipe), showCalories: store.settings.showCalories)
        }
    }

    #if canImport(UIKit)
    /// The read-only detail for a recipe-book row, wired to the store half the row came from.
    private func recipeDetail(for recipe: RecipeDefinition, isSaved: Bool) -> some View {
        RecipeDetailView(
            store: store,
            recipe: recipe,
            // Pushed inside the Food stack the editor presents OVER this detail and returns to it on
            // save; only the sheet presentation has to close itself first so the editor can appear.
            onEdit: { beginEditing(recipe, isSaved: isSaved); dismissIfPresented() },
            onSaveFork: { fork in
                if isSaved { store.addForkedSavedRecipe(fork) } else { store.addForkedRecipe(fork) }
            },
            onLog: { current, mealType in
                logRecipe(current, mealType: mealType, isSaved: isSaved)
                dismissIfPresented()
            },
            onShare: { current in recipeShareDraft = shareDraft(for: current, isSaved: isSaved) },
            onCookLog: { current, mealType, day in
                if isSaved {
                    store.logSavedRecipe(current, mealType: mealType, date: day)
                } else {
                    store.logRecipe(current, mealType: mealType, date: day)
                }
            }
        )
    }
    #endif

    /// Routes an edit request back to ``FoodView``'s binding for that recipe's store half.
    private func beginEditing(_ recipe: RecipeDefinition, isSaved: Bool) {
        if isSaved { editingSavedRecipe = recipe } else { editingRecipe = recipe }
    }

    /// Logs a recipe through the store method that matches its half (manual vs saved/web) and
    /// reports the committed meal to the host's toast path (`onMealsLogged`, FLOW-15). A nil
    /// `mealType` (a slotless legacy plan entry) falls back to the store's by-time "Auto" rule.
    private func logRecipe(_ recipe: RecipeDefinition, mealType: MealType?, isSaved: Bool) {
        let meal: Meal
        if isSaved {
            meal = store.logSavedRecipe(recipe, mealType: mealType)
        } else {
            meal = store.logRecipe(recipe, mealType: mealType)
        }
        onMealsLogged([meal])
    }

    /// The proximity share draft for a recipe, using its half's share-text builder.
    private func shareDraft(for recipe: RecipeDefinition, isSaved: Bool) -> ProximityRecipeShareDraft {
        ProximityRecipeShareDraft(
            title: recipe.name,
            shareText: isSaved ? store.savedRecipeShareText(for: recipe) : store.recipeShareText(for: recipe),
            payload: store.proximityRecipeSharePayload(for: recipe)
        )
    }

    private func importedProductsCard(_ products: [FoodItem]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("Imported products")
            FernletCard {
                VStack(spacing: 0) {
                    ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                        if index > 0 { FernletRowDivider() }
                        VStack(alignment: .leading, spacing: 6) {
                            WebImportedFoodRow(foodItem: product)
                            RecipeRowLogControl(onLog: { mealType in
                                let meal = store.logWebImportedFoodProduct(product, mealType: mealType)
                                onMealsLogged([meal])
                                dismissIfPresented()
                            }) {
                                EmptyView()
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptySearchState: some View {
        EmptyState(text: "No recipes or products match \u{201C}\(searchText)\u{201D}.")
            .frame(maxWidth: .infinity)
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

/// A `UIViewControllerRepresentable` wrapper around `SFSafariViewController` for in-app source
/// links.
///
/// Belt-and-braces: any non-http(s) URL falls back to an empty controller instead of crashing, but
/// presentation sites should still gate on `URL.isSafariPresentable` so that branch is never reached.
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

/// Pre-warms the connection to a recipe's source link while its page is on screen, so tapping the
/// link opens near-instantly (owner decision 2026-08-09: connection PRE-WARM only — no page
/// snapshot, no `WKWebView`; ``SafariView`` stays the opening surface).
///
/// `SFSafariViewController.prewarmConnections(to:)` performs the DNS lookup and TLS handshake for
/// the eventual Safari presentation — no HTTP request is issued and nothing is rendered. Egress
/// note (Docs/No-Tracking-Wall.md §4b): this contacts the recipe's own source host on
/// detail-appear, before any tap. HTTPS-only (pre-warming plaintext HTTP buys nothing), gated on
/// ``URL/isSafariPresentable``, and the token is invalidated on disappear so warmed connections
/// don't outlive the page that justified them.
///
/// A PEER-SUPPLIED source is excluded entirely (``prewarmURL(for:)``): the justification for the
/// pre-warm is that the user chose the host by importing from it, and that is simply false for a
/// URL a stranger sent over the mesh — a unique per-recipient hostname would otherwise turn every
/// open of that recipe into a DNS+TLS beacon back to the sender.
struct SourceLinkPrewarmModifier: ViewModifier {
    /// The source link to warm; `nil` and non-https URLs make the modifier inert.
    let url: URL?
    /// The live pre-warm token. Non-nil exactly while this view is on screen with a warmable URL;
    /// `invalidate()` on disappear releases the warmed connections.
    @State private var token: SFSafariViewController.PrewarmingToken?

    /// The URL this modifier may warm for a recipe's web import, or nil when it must stay inert.
    /// Nil for a peer-supplied source (the consent boundary above) and for a recipe with no import.
    /// Pure and static so the policy is testable without rendering a view.
    static func prewarmURL(for webImport: RecipeWebImport?) -> URL? {
        guard webImport?.sourceIsPeerSupplied != true else { return nil }
        return webImport?.sourceURL
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard token == nil,
                      let url,
                      url.isSafariPresentable,
                      url.scheme?.lowercased() == "https" else { return }
                token = SFSafariViewController.prewarmConnections(to: [url])
            }
            .onDisappear {
                token?.invalidate()
                token = nil
            }
    }
}

extension View {
    /// Applies ``SourceLinkPrewarmModifier`` for a recipe's own web import: warms the DNS/TLS
    /// connection to its source link (https only) while this view is on screen, releasing it on
    /// disappear. A no-op for `nil`, non-presentable, or non-https URLs — and inert for a
    /// PEER-SUPPLIED source, because a host a stranger chose must not be contacted without a tap.
    func prewarmsSourceLinkConnection(for webImport: RecipeWebImport?) -> some View {
        modifier(SourceLinkPrewarmModifier(url: SourceLinkPrewarmModifier.prewarmURL(for: webImport)))
    }
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

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
///
/// The recipe book and the recent recipes' details are pushed as ``FoodRoute`` path values, so a
/// re-tap of the Food tab pops the whole stack back to this page (``TabReselectModifier``).
struct FoodView: View {
    var store: FernletStore
    /// Reports meals logged from THIS tab's own surfaces (the Planned-today card, recipe rows,
    /// the recipe detail and book, cooking mode's finish) so the host can raise the post-log toast
    /// (FLOW-15). The host (ContentView) passes its toast reporter here; the MealSheet keeps its
    /// separate `onLogged` wiring. Defaults to reporting nowhere so construction sites compile
    /// before wiring.
    var onMealsLogged: MealLogReporter = .none
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
    /// The meal the resumed cook's finish screen logged, held until the cover has gone and then
    /// handed to the toast (``CookedMealHandoff``).
    @State private var cookedMeal = CookedMealHandoff()
    /// The Food tab stack's pushed pages. Cleared in one write when the Food tab is re-tapped.
    @State private var path: [FoodRoute] = []
    /// The root page's own scroll-to-top token; `tabReselect` bumps it only when nothing is pushed.
    @State private var scrollToTopToken = 0
    @Environment(\.scenePhase) private var scenePhase
    /// The user's term of address (the app root sets it from the body profile), for the root page's
    /// copy that describes them: the retry banner's companion line and the empty-day prompt.
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    /// The World's framed look (set at the app root); nil draws today's Food page.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        foodLifecycle(foodSheets(foodRoot))
    }

    /// The Food root's scrolling content: header, macro card, the cooking-resume and pending-retry
    /// cards, today's meals grouped by type, and the recent-recipes preview.
    private var foodRoot: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // b1-frame-root / b2-cooking-resume order: subtitle, a cook under way, the one
                    // primary, then the day's macros.
                    headerRow
                    cookingResumeSection
                    FoodLogMealButton { activeSheet = .meal }

                    macrosSection

                    plannedTodaySection
                    pendingRetrySection
                    todayMealsSection
                    recentRecipesSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .padding(.bottom, 24)
                .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $scrollToTopToken)
            // The dotted parchment page (b1-frame-root), plain parchment outside the World look.
            .fernletPageBackground()
            .navigationTitle("")
            .navigationDestination(for: FoodRoute.self) { foodDestination($0) }
        }
        // No keyboard "Done" here: declared outside the stack it reached none of the stack's pages —
        // each is hosted in its own controller — so the recipe book, its editor's number pads and
        // the import screen showed no accessory at all (2026-10-01). Each page that holds a field
        // declares its own (`RecipeBookSheet`, `RecipeSheet`, `RecipeImportSheet`, …).
        // Re-tapping Food pops everything pushed here back to this page; at this page it scrolls up.
        .tabReselect(token: $tabResetToken, scrollToTopToken: $scrollToTopToken, isAtRoot: { path.isEmpty }) {
            path.removeAll()
        }
        .onChange(of: store.recipes.map(\.id)) { pruneDeadRecipeRoutes() }
        .onChange(of: store.savedRecipes.map(\.id)) { pruneDeadRecipeRoutes() }
    }

    /// Resolves a ``FoodRoute`` pushed from the Food root to its page.
    @ViewBuilder private func foodDestination(_ route: FoodRoute) -> some View {
        switch route {
        case .recipeBook:
            RecipeBookSheet(
                store: store,
                editingRecipe: $editingRecipe,
                editingSavedRecipe: $editingSavedRecipe,
                isEmbeddedInNavigationStack: true,
                onMealsLogged: onMealsLogged
            )
        case .recipeDetail(let id, let isSaved):
            #if canImport(UIKit)
            // Resolved live, so an edit made from the detail shows at once. After a delete the page
            // keeps its last definition until `pruneDeadRecipeRoutes` has popped it (see
            // `LastKnownRecipePage`) instead of sliding away blank.
            LastKnownRecipePage(live: (isSaved ? store.savedRecipes : store.recipes).first(where: { $0.id == id })) {
                recipeDetail(for: $0, isSaved: isSaved)
            }
            #else
            EmptyView()
            #endif
        }
    }

    /// Pops a recent recipe's detail whose recipe was deleted (from its own editor sheet, or by a
    /// sync) — the view-destination link this replaced vanished with the recipe and popped the page.
    private func pruneDeadRecipeRoutes() {
        let kept = FoodRoute.pruned(
            path,
            manualIDs: Set(store.recipes.map(\.id)),
            savedIDs: Set(store.savedRecipes.map(\.id))
        )
        guard kept.count != path.count else { return }
        path = kept
    }

    /// The subtitle (the plate carries the title). The page's one primary, "+ Log a meal", follows it
    /// in the stack (`b1-frame-root` draft 3); it replaced the small "+ meal" pill beside the title.
    private var headerRow: some View {
        ScreenHeader(title: "Food", subtitle: "Eating enough, eating well.", identifier: "screen.food")
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
                    .font(look == nil ? .fernlet(.label) : FernletFramedFont.button)
                    .foregroundStyle(look?.link ?? Color.moss)
                    // The label alone was an 18pt-tall target.
                    .fernletTapTarget()
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
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Planned today")
                FernletCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { FernletDottedRule().padding(.vertical, 6) }
                            plannedTodayRow(item)
                        }
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
                    .font(look == nil ? .fernlet(.headerMedium) : FernletFramedFont.cardTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
                plannedTodayDetailLine(item)
            }
            Spacer(minLength: 0)
            Button("Log") {
                logRecipe(item.recipe, mealType: item.entry.mealType, isSaved: item.isSaved)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
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
        .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.rowDetail)
        .foregroundStyle(look?.dim ?? Color.slate)
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

    /// Meals whose AI estimate is waiting to be retried: the count, the companion's line, and Retry.
    @ViewBuilder private var pendingRetrySection: some View {
        if store.pendingRetryCount > 0 {
            FernletCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        WorldSpriteView(sprite: FoodSprites.clock, scale: 2)
                        Text("\(store.pendingRetryCount) pending")
                            .font(look == nil ? .fernlet(.header) : FernletFramedFont.cardTitle)
                            .foregroundStyle(look?.text ?? Color.bark)
                        Spacer()
                    }
                    Text(FernletVoice.message(for: .retryAvailable, addressing: termOfAddress))
                        .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                    Button("Retry oldest") {
                        Task { await store.retryOldestMeal() }
                    }
                    .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                }
            }
        }
    }

    @ViewBuilder private var todayMealsSection: some View {
        if store.day.meals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Today")
                FernletCard {
                    // "When you are ready" describes the user (*lista*): resolved for them, then drawn verbatim.
                    EmptyState(verbatim: AddressedCopy.string("Nothing yet. Describe a meal when you are ready.", addressing: termOfAddress))
                }
            }
        } else {
            // Each meal type is its own section: the slot's label, then one framed card per meal
            // (b1-frame-root, b2-food-rest), and the slot's total when it holds more than one.
            ForEach(mealsByType) { group in
                // `displayName`, not `rawValue`: the rawValue is the persisted/prompt token and
                // was being rendered as a user-visible heading. `verbatim:` because the domain
                // property has already resolved its own localized string.
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(verbatim: group.type.displayName)
                    ForEach(group.meals) { meal in
                        mealCard(meal)
                    }
                    mealTypeSubtotal(group.meals, type: group.type)
                }
            }
        }
    }

    /// One logged meal's card: a tap opens Adjust, the ✕ asks before removing it.
    private func mealCard(_ meal: Meal) -> some View {
        MealRow(
            meal: meal,
            showCalories: store.settings.showCalories,
            onDelete: { confirmDeleteMeal(meal) },
            onCorrect: { correctingMeal = meal },
            loadPhotoData: meal.photoID.map { id in { store.mealPhotoData(for: id) } },
            hasPhotoSealedFile: meal.photoID.map { id in { store.mealPhotoHasSealedFile(for: id) } },
            showsMealTypeBadge: false,
            dataAttribution: store.dataAttribution(for: meal)
        )
    }

    private var recentRecipesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Recipes")
                Spacer()
                // Pushed, not presented: book → detail → editor then lives in ONE stack, so saving an
                // edit started from the book returns to that recipe instead of dropping to Food root.
                NavigationLink(value: FoodRoute.recipeBook) {
                    Text("Recipe book")
                        .font(look == nil ? .fernlet(.label) : FernletFramedFont.button)
                        .foregroundStyle(look?.link ?? Color.moss)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if recentRecipePreviews.isEmpty {
                FernletCard {
                    EmptyState(text: "No recipes yet. Open the recipe book to create one.")
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(recentRecipePreviews) { preview in
                        recentRecipeCard(preview)
                    }
                }
            }
        }
    }

    /// One recent recipe's card (`b2-food-rest`): a manual recipe and a saved/web recipe share the
    /// card, each logging and sharing through the store half (`isSaved`) that owns it. Tapping the
    /// summary pushes the read-only detail; the editor is reachable only through its Edit.
    @ViewBuilder private func recentRecipeCard(_ preview: RecentRecipePreview) -> some View {
        switch preview {
        case .local(let recipe):
            let perServing = recipePerServing(recipe)
            recipeCard(recipe, isSaved: false, perServing: perServing,
                       calories: store.settings.showCalories ? perServing.calories : nil)
        case .saved(let recipe):
            let macros = recipe.webImport?.macros
            let hasMacros = macros.map { $0.protein > 0 || $0.carbs > 0 || $0.fat > 0 } ?? false
            recipeCard(recipe, isSaved: true, perServing: hasMacros ? macros : nil, calories: nil)
        }
    }

    private func recipeCard(_ recipe: RecipeDefinition, isSaved: Bool, perServing: Macros?, calories: Int?) -> some View {
        FoodRootRecipeCard(
            recipe: recipe,
            isSaved: isSaved,
            perServing: perServing,
            calories: calories,
            onLog: { mealType in logRecipe(recipe, mealType: mealType, isSaved: isSaved) },
            onShare: { recipeShareDraft = store.recipeShareDraft(for: recipe) }
        )
    }

    /// A manual recipe's per-serving macros: the resolved totals over its yield.
    private func recipePerServing(_ recipe: RecipeDefinition) -> Macros {
        let totals = store.macroTotals(for: recipe)
        let divisor = Double(max(recipe.servings, 1))
        return Macros(protein: Int((Double(totals.protein) / divisor).rounded()),
                      carbs: Int((Double(totals.carbs) / divisor).rounded()),
                      fat: Int((Double(totals.fat) / divisor).rounded()))
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
            onShare: { current in recipeShareDraft = store.recipeShareDraft(for: current) },
            onCookLog: { current, mealType, day in
                if isSaved {
                    return store.logSavedRecipe(current, mealType: mealType, date: day)
                }
                return store.logRecipe(current, mealType: mealType, date: day)
            },
            onMealsLogged: onMealsLogged
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
        if isSaved {
            onMealsLogged([store.logSavedRecipe(recipe, mealType: mealType)])
            return
        }
        guard let meal = store.logRecipe(recipe, mealType: mealType) else { return }
        onMealsLogged([meal])
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
                    .recipeSheetFrame(anchor: "sheet.recipeEditor")
            }
            .sheet(item: $editingSavedRecipe) { recipe in
                SavedRecipeNotesSheet(store: store, recipe: recipe)
                    .recipeSheetFrame(anchor: "sheet.savedRecipeNotes")
            }
            .sheet(item: $correctingMeal) { meal in
                // Full height only: at .medium the "Matched items" editor — the thing the user opened
                // this sheet to fix — sat clipped behind the Save pill until they dragged it up.
                MealCorrectionSheet(store: store, meal: meal)
                    .fernletFoodSheet(anchor: "sheet.mealCorrection")
            }
            .sheet(isPresented: $showingNutritionTargets) {
                // Full height (b3-targets): every sheet is, in the World build.
                NutritionTargetsSheet(store: store)
                    .fernletFoodSheet(anchor: "sheet.nutritionTargets")
            }
            .sheet(item: $recipeShareDraft) { draft in
                ProximityRecipeShareSheet(draft: draft, manager: store.recipeShareManager, store: store)
                    .fernletSheet()
            }
    }

    /// Appear/foreground reconciliation plus the cooking-mode cover, applied after the sheets so the
    /// modifier order matches what shipped.
    private func foodLifecycle<V: View>(_ content: V) -> some View {
        content
            .destructiveConfirmation($pendingDestructiveAction)
            // DEBUG: `FERNLET_UI_TEST_FOOD_SCREEN` opens a Food screen with fixtures (a no-op in Release).
            .foodLaneGallery(store: store)
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
            // The finished cook's meal reaches the toast from `onDismiss`, once the cover is gone.
            .fullScreenCover(item: $cookingResume, onDismiss: { cookedMeal.release(to: onMealsLogged) }) { target in
                CookingModeView(
                    store: store,
                    recipe: target.recipe,
                    resuming: true,
                    onLogToDay: { mealType, day in
                        let meal = target.isSaved
                            ? store.logSavedRecipe(target.recipe, mealType: mealType, date: day)
                            : store.logRecipe(target.recipe, mealType: mealType, date: day)
                        cookedMeal.hold(meal, loggedTo: day)
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
                // One key with the slot as its argument, so a translator can put "total" where the
                // language wants it; `verbatim:` here spliced an English word onto a localized one.
                Text("\(type.displayName) total")
                    .foregroundStyle(look?.dim ?? Color.slate)
                Spacer(minLength: 0)
                FoodMacroTag(kind: .protein, grams: protein)
                if store.settings.showCalories {
                    Text("\(calories) cal")
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
            }
            .font(look == nil ? .fernlet(.stat) : FernletFramedFont.rowValue)
            .padding(.horizontal, 4)
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

    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if let look {
            framed(look)
        } else {
            FernletCard { content }
        }
    }

    /// `b2-cooking-resume` (approved 2026-10-23): the calm sage card at the top of Food, its pan in a
    /// tile (bare inside the card, the frame rule), "Pick up where you left off", the recipe and step,
    /// then Resume and Done cooking.
    private func framed(_ look: FernletFramedLook) -> some View {
        let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
        return content
            // The frame rule (ref-frames-rule): pieces inside this card draw flat.
            .environment(\.fernletInFramedSection, true)
            .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15))
            .background(look.sage, in: shape)
            .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
            .background { shape.fill(look.shadow).offset(y: 3) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                FernletIconTile(size: 42) {
                    WorldSpriteView(sprite: WorldSprites.bowl, scale: 3, tint: look?.text ?? Color.bark)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick up where you left off")
                        .font(look == nil ? .fernlet(.headerMedium) : FernletFramedFont.cardTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                        .fernletWrappingText()
                    Text("\(recipeName) · step \(stepNumber) of \(stepCount)")
                        .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                }
                Spacer(minLength: 0)
            }
            buttons
        }
    }

    /// Resume beside Done cooking (which asks first); one above the other when they don't fit.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { resumeButton; doneButton }
            VStack(spacing: 10) { resumeButton; doneButton }
        }
    }

    /// Ends the cook: today's Discard, renamed by the design. It still confirms ("Stop cooking …?").
    private var doneButton: some View {
        Button(action: onDiscard) {
            Text("Done cooking").frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
        .accessibilityIdentifier("cooking.discard")
    }

    private var resumeButton: some View {
        Button(action: onResume) {
            Text("Resume").frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.primary))
        .accessibilityIdentifier("cooking.resume")
    }
}

/// The Food tab's way in to ``NutritionTargetsEditor`` — the same card Settings shows, wrapped in a
/// sheet under the pinned ``SheetHeader``. The editor commits live, so Done sits top-right and is
/// the whole exit (2026-08-21 template) — no bottom bar.
///
/// The macro card names targets the user can't reach from here otherwise; this keeps "nudge a target"
/// a tap away from the numbers it changes, without duplicating the editor.
struct NutritionTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fernletFramedLook) private var look
    var store: FernletStore

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Nutrition targets", onDone: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    NutritionTargetsEditor(store: store)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 10)
            }
        }
        // b3-targets: the sheet's paper (the framed sheet), parchment outside the World look.
        .background(look?.paper ?? Color.parchment)
    }
}

/// A small labeled stat tile (title over value) for macro and calorie figures.
///
/// Shared by the recipe detail's per-serving card, the web-product review sheet and the nearby-share
/// review so nutrition numbers render identically wherever they appear. Both halves are
/// `LocalizedStringKey`: every caller passes a literal ("Protein", "\(grams)g"), and as `String` they
/// were drawn verbatim and never reached the catalog.
struct NutritionPill: View {
    var title: LocalizedStringKey
    var value: LocalizedStringKey

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

/// The "Import recipe" sheet: paste Fernlet recipe data or pull a recipe URL from the pasteboard.
///
/// Text imports decode through `FernletStore.importRecipe(from:)` (the ``RecipeShareCodec`` payload);
/// the Paste-URL button runs `RecipeWebImporter` and lands the result in the saved-recipe store.
/// Reached from ``RecipeCreationOptionsView``.
///
/// What the field still imports (2026-09-30): the text older Fernlet builds shared, which ends in a
/// "Fernlet recipe data:" line, and bare recipe JSON. The text a current build shares ("Share as
/// text", ``RecipeShareText``) carries no data and is for reading, so the field's caption says so up
/// front and `RecipeImportError.missingPayload` names the routes that do carry a recipe into
/// Fernlet: Send in Messages, a nearby share, or a web recipe's Source link through Paste URL.
private struct RecipeImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    /// Called instead of `dismiss()` once a recipe has actually been imported, so the host can pop
    /// past the create-recipe chooser to the book rather than leaving the user on it. `nil` keeps the
    /// plain one-level dismiss.
    var onSaved: ((String) -> Void)?
    /// Reports a log from the matched recipe's detail (its Log, or cooking mode's finish) to the
    /// recipe book's toast route, so logging an already-saved recipe from here is confirmed too.
    var onMealsLogged: MealLogReporter = .none
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
            // Pushed inside the book's create branch: a re-tap of the Food tab asks before it pops
            // pasted text away.
            .tabReselectDraft(isDirty: !importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            // Inside the Food tab the floating tab bar covers the bottom: Import rested under it,
            // like the manual editor's save bar (2026-10-01). A no-op in the recipe book's sheet.
            .fernletTabBarSafeAreaClearance()
    }

    /// `b2-recipe-import` (approved 2026-10-23): Paste URL full width, the shared-text field under its
    /// label, the note, then Import at the bottom right, dimmed until there is something to import.
    /// The title is on the wooden plate (‹ Create).
    private var importContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pasteURLButton
                SectionLabel("Shared recipe text")
                    .padding(.top, 4)
                SheetTextEditor(text: $importText, placeholder: "Paste Fernlet recipe data here", minHeight: 150)
                Text("A recipe shared as text is for reading and won't import here. To save one, have it sent with Send in Messages or shared nearby.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                if let notice {
                    FernletNotice(text: Text(verbatim: notice)) { WorldSpriteView(sprite: WorldSprites.clock, scale: 2) }
                }
                #if canImport(UIKit)
                if let existingRecipe {
                    alreadySavedCard(for: existingRecipe)
                }
                #endif
                HStack {
                    Spacer(minLength: 0)
                    Button("Import") { importSharedText() }
                        .buttonStyle(ActionPillButtonStyle(.primary))
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("recipeImport.import")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .fernletPageBackground()
        .fernletPushedPage("Import recipe")
        // Return adds a line in the paste editor, so the accessory is the way to put the keyboard
        // away. On the page: it is always pushed, beyond the reach of a Done outside its stack.
        .keyboardDoneToolbar()
    }

    /// The pasteboard-URL import affordance, full width with the pixel box; disabled (and relabelled)
    /// while a fetch is in flight so only one import task can ever be in flight.
    private var pasteURLButton: some View {
        Button {
            importFromPasteboardURL()
        } label: {
            HStack(spacing: 8) {
                WorldSpriteView(sprite: isImportingURL ? WorldSprites.clock : WorldSprites.box, scale: 2,
                                tint: WorldPalette.onAccent)
                if isImportingURL { Text("Importing URL") } else { Text("Paste URL") }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.primary))
        .disabled(isImportingURL)
        .accessibilityIdentifier("recipeImport.pasteURL")
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
                    .recipeSheetFrame(anchor: "sheet.savedRecipeNotes")
            }
            .sheet(item: $recipeShareDraft) { draft in
                ProximityRecipeShareSheet(draft: draft, manager: store.recipeShareManager, store: store)
                    .fernletSheet()
            }
        #endif
    }

    #if canImport(UIKit)
    /// The zero-network duplicate state: names the matched recipe and offers to open its detail —
    /// no fetch happened and none will (refreshing is the detail's own "Re-import from source").
    private func alreadySavedCard(for recipe: RecipeDefinition) -> some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    FernletIcon(.check, scale: 2)
                    Text("Already in your recipe book")
                        .font(FernletFramedFont.rowTitleBold)
                        .foregroundStyle(WorldPalette.mossInk)
                }
                Text(verbatim: recipe.name)
                    .font(RecipeType.cardTitle)
                    .foregroundStyle(WorldPalette.bark)
                    .fernletWrappingText()
                Button {
                    showingExistingRecipe = true
                } label: {
                    HStack(spacing: 8) {
                        WorldSpriteView(sprite: WorldSprites.diary, scale: 2)
                        Text("Open saved recipe")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("recipeImport.openExisting")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The matched recipe's read-only detail, wired with local closures (edit → local notes sheet,
    /// share → local proximity draft) because this sheet has no access to `FoodView`'s bindings.
    private func existingRecipeDetail(_ recipe: RecipeDefinition) -> some View {
        RecipeDetailView(
            store: store,
            recipe: recipe,
            onEdit: { editingSavedRecipe = recipe },
            onSaveFork: { store.addForkedSavedRecipe($0) },
            onLog: { current, mealType in onMealsLogged([store.logSavedRecipe(current, mealType: mealType)]) },
            onShare: { current in recipeShareDraft = store.recipeShareDraft(for: current) },
            onCookLog: { current, mealType, day in store.logSavedRecipe(current, mealType: mealType, date: day) },
            onMealsLogged: onMealsLogged
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
            let name = existing.name
            notice = String(localized: "recipeImport.notice.alreadyImported",
                            defaultValue: "\u{201C}\(name)\u{201D} was already imported from this page.",
                            comment: "Import recipe screen: the pasted link is a recipe already in the book. The argument is that recipe's name.")
            return
        }
        existingRecipe = nil

        isImportingURL = true
        notice = String(localized: "recipeImport.notice.fetching", defaultValue: "Fetching recipe...",
                        comment: "Import recipe screen: shown while a pasted recipe link is being fetched")

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
                let name = importedRecipe.name
                notice = String(localized: "recipeImport.notice.added", defaultValue: "\(name) added to your recipes.",
                                comment: "Import recipe screen: a pasted recipe link was imported. The argument is the recipe's name.")
                isImportingURL = false
                do {
                    // A beat so the "added to your recipes" line can be read before the sheet goes.
                    // It is deliberately NOT stretched under VoiceOver and NOT spoken here. This
                    // screen's only host, the recipe book's create branch, passes `onSaved`, so every
                    // import lands back on the book. The book repeats this line, holds it for the
                    // assistive notice window and speaks it once the pop settles
                    // (`RecipeBookSheet.finishCreation`). Holding this screen 12 s would leave its
                    // editor and Import bar live and then pull them away. Speaking here as well
                    // would say the same thing twice. (Owner's pick, 2026-10-18.)
                    try await Task.sleep(for: .seconds(1.2))
                } catch {
                    // Cancelled: the presenting sheet is already being torn down, so there is
                    // nothing left to dismiss.
                    return
                }
                finishImport(named: importedRecipe.name)
            } catch RecipeWebImportError.aiBudgetExhausted {
                // The error's own sentence promises a retry tomorrow. Make it true by queueing the
                // link for the foreground drain, as a shared link is; if the queue cannot take it,
                // say plainly that nothing will retry.
                notice = store.deferPastedRecipeImportUntilTomorrow(url)
                    ? RecipeWebImportError.aiBudgetExhausted.errorDescription
                    : String(localized: "recipeImport.error.aiBudgetExhaustedNotQueued",
                             defaultValue: "The quiet helper is resting for today. Paste this link again tomorrow and I'll try it then.",
                             comment: "Shown when a pasted recipe link needs on-device AI, today's AI budget is spent, AND the link could not be saved for a retry tomorrow — so, unlike the usual resting message, it asks the person to paste it again.")
                isImportingURL = false
            } catch {
                notice = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "recipeImport.error.fallback",
                              defaultValue: "Could not import that recipe.",
                              comment: "Shown when importing a recipe fails and the thrown error carries no description of its own. One key, two call sites — the inline notice on the import screen and the note recorded against a queued share — because the sentence and the situation are the same.")
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
                Text(verbatim: StoredFoodNote.displayedRecipeNotes(recipe.notes))
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
                        Text("· ^[\(recipe.servings) serving](inflect: true)")
                    }
                }
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
                WebImportEstimateNote(uncountedLines: webImport?.uncountedIngredientLines, estimatedLines: webImport?.estimatedIngredientLines)
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
            // World build (b3-recipe-notes draft 2): this is a saved recipe's Edit recipe, where
            // Delete recipe lives; the notes are also on the recipe page itself. Cancel keeps them.
            SheetHeader(title: Text("Edit recipe"), subtitle: Text(verbatim: recipe.name), onCancel: { dismiss() },
                        onDone: {
                // Merge only the field this sheet edits into the LIVE row — writing the whole
                // at-open snapshot back would revert store updates that landed while the sheet
                // was up (e.g. the image fetch stamping a suppression, or a cloud refresh).
                store.updateSavedRecipeNotes(recipe.notes, forRecipeID: recipe.id)
                dismiss()
            })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceLinkSection

                    macrosCard

                    SheetField("Notes") {
                        SheetTextEditor(text: $recipe.notes, placeholder: "cooking notes, substitutions, tips", minHeight: 120)
                    }

                    ingredientLinesCard

                    deleteButton
                }
                .padding(18)
                .padding(.bottom, 10)
            }
        }
        .background(WorldPalette.paper)
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
            FernletCard {
                VStack(alignment: .leading, spacing: 8) {
                    if recipe.servings > 1 { SectionLabel("Per serving") } else { SectionLabel("Macros") }
                    RecipeMacroTags(macros: MacroTotals(protein: macros.protein, carbs: macros.carbs, fat: macros.fat))
                    if recipe.servings > 1 {
                        Text("^[\(recipe.servings) serving](inflect: true)")
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(WorldPalette.dim)
                    }
                    WebImportEstimateNote(uncountedLines: webImport?.uncountedIngredientLines, estimatedLines: webImport?.estimatedIngredientLines)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // An estimate that rounds to all zeros hides the card, not the lines it left out.
            WebImportEstimateNote(uncountedLines: webImport?.uncountedIngredientLines, estimatedLines: webImport?.estimatedIngredientLines)
        }
    }

    @ViewBuilder private var ingredientLinesCard: some View {
        if let ingredientLines = webImport?.ingredientLines, !ingredientLines.isEmpty {
            FernletCard {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Ingredients")
                    ForEach(ingredientLines, id: \.self) { ingredient in
                        RecipeIngredientRow(name: ingredient, amount: "")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// A pushed recipe page that keeps drawing the last definition it resolved once that recipe is gone.
///
/// ``FoodRoute/recipeDetail(id:isSaved:)`` carries only an id and resolves the definition live, so
/// an edit shows at once. Deleting the recipe (from its own editor sheet, or by a sync) empties the
/// live lookup for the update between the delete and `FoodView`'s prune popping the page, and for
/// the pop's slide-out after it. The view-destination link the route replaced captured the recipe,
/// so the page used to leave still showing it; this keeps that by remembering the last live
/// definition. A route that never resolved draws the app's parchment, not the system background.
private struct LastKnownRecipePage<Content: View>: View {
    /// The definition the route resolves to now; `nil` once the recipe has been deleted.
    let live: RecipeDefinition?
    /// Builds the page for a definition.
    let content: (RecipeDefinition) -> Content
    /// The last non-nil ``live``, seeded at the page's first render and kept current by edits.
    @State private var lastKnown: RecipeDefinition?

    init(live: RecipeDefinition?, @ViewBuilder content: @escaping (RecipeDefinition) -> Content) {
        self.live = live
        self.content = content
        _lastKnown = State(initialValue: live)
    }

    var body: some View {
        ZStack {
            if let recipe = live ?? lastKnown {
                content(recipe)
            } else {
                Color.parchment.ignoresSafeArea()
            }
        }
        .onChange(of: live) { _, newValue in
            guard let newValue else { return }
            lastKnown = newValue
        }
    }
}

/// The pages the Food tab's root pushes onto its own `NavigationStack`, as path values.
///
/// A path — rather than the view-destination links these used to be — is what lets a re-tap of the
/// Food tab pop everything to the Food page (``TabReselectModifier``): ContentView can only ask, and
/// only a value path can be cleared from outside the pushed page. Everything a pushed page pushes in
/// turn (the book's create chooser and editors, the planner, a book row's detail) stays that page's
/// own navigation and comes off with the entry beneath it.
///
/// `recipeDetail` carries the recipe's id, not the recipe: `RecipeDefinition` is not `Hashable`, and
/// the destination resolves the definition live so an edit shows at once. `isSaved` names the store
/// half — a manual recipe and a saved/web recipe never match across halves. A route whose recipe is
/// gone is cut by ``pruned(_:manualIDs:savedIDs:)``, which is what the vanished view link used to do.
///
/// The path is typed, so it holds only these values: a pushed page that wants a value link of some
/// other type needs `navigationDestination(isPresented:)`/`(item:)` instead (as the book's create
/// branch does), or the tab moves to `NavigationPath`.
nonisolated enum FoodRoute: Hashable {
    /// The recipe book, pushed rather than presented so book → detail → editor is one stack.
    case recipeBook
    /// A recent recipe's read-only detail, from the Food page's Recipes card.
    case recipeDetail(id: UUID, isSaved: Bool)

    /// Whether this route's recipe still exists in its own store half.
    func isLive(manualIDs: Set<UUID>, savedIDs: Set<UUID>) -> Bool {
        switch self {
        case .recipeBook:
            return true
        case .recipeDetail(let id, let isSaved):
            return (isSaved ? savedIDs : manualIDs).contains(id)
        }
    }

    /// The path cut back to just below the first route whose recipe is gone — everything pushed above a
    /// dead page goes with it. Returns `path` unchanged when every route is live.
    static func pruned(_ path: [FoodRoute], manualIDs: Set<UUID>, savedIDs: Set<UUID>) -> [FoodRoute] {
        guard let firstDead = path.firstIndex(where: { !$0.isLive(manualIDs: manualIDs, savedIDs: savedIDs) }) else {
            return path
        }
        return Array(path[..<firstDead])
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
    /// The camera's "Add by hand": Remember product with no barcode, as the scanner's own hand entry.
    case rememberByHand
}

/// What Log meal's sheet opens with, when something hands it a start: the description already typed,
/// and by-hand macros already open with their numbers (the DEBUG screenshot gallery; nothing in
/// shipping code passes one yet).
struct MealSheetSeed {
    var description: String
    var macros: Macros? = nil
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
    /// Reports the meal "Log & save" logs to the host's toast. The Home sheet passes ContentView's
    /// reporter; the recipe book's create branch passes the book's.
    private var onMealsLogged: MealLogReporter
    @State private var name = ""
    @State private var servings = 1
    @State private var notes = ""
    @State private var ingredients: [ManualRecipeIngredientInput] = []
    /// F5 manual step entry. Held as `[RecipeStep]` directly (Identifiable + mutable `text`), sanitized
    /// on save by `RecipeStepSanitizer` (drops blanks). Empty means "no cooking steps".
    @State private var steps: [RecipeStep] = []
    /// Multipart state (2026-09-24). Empty for a one-part recipe, so `ingredients`/`steps` above stay in
    /// charge exactly as before. Once split, it holds every row and those two stay empty.
    @State private var partsDraft = RecipePartsDraft()
    /// The part a barcode scan lands in, set by that part's Scan button (multipart only).
    @State private var scanTargetPartID: UUID?
    @State private var expandedId: UUID?
    @State private var scannerPath = false
    @State private var didStartScanner = false
    @State private var showingBarcodeScanner = false
    /// Drives the confirmation in front of "Delete recipe" — deleting and dismissing on one tap was
    /// the only unguarded way to lose a whole recipe.
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    /// The at-open draft, so the sheet can tell "nothing typed yet" from "unsaved edits" and only
    /// warn about the second (see ``isDirty``).
    ///
    /// `@State`, like the draft fields it is compared with, so both halves come from the SAME first
    /// init. As a plain `let` it was rebuilt on every re-init of this struct (any redraw of the
    /// presenting view) while the `@State` fields kept their first values — and a new recipe's blank
    /// first row is minted with a fresh id each time, so an untouched editor read as dirty and asked
    /// "Discard your changes?" for nothing.
    @State private var originalDraft: RecipeDraftSnapshot

    init(
        store: FernletStore,
        recipe: RecipeDefinition? = nil,
        isEmbeddedInNavigationStack: Bool = false,
        startsWithScanner: Bool = false,
        onSaved: ((String) -> Void)? = nil,
        onMealsLogged: MealLogReporter = .none
    ) {
        self.store = store
        self.editingRecipe = recipe
        self.isEmbeddedInNavigationStack = isEmbeddedInNavigationStack
        self.startsWithScanner = startsWithScanner
        self.onSaved = onSaved
        self.onMealsLogged = onMealsLogged
        if let recipe {
            let recipeFoods = store.foodCatalog.items(forRecipe: recipe)
            let loadedParts = RecipePartsDraft.parts(for: recipe, foodItems: recipeFoods)
            // A multipart recipe opens into its parts; its flat lists stay empty (the parts hold every row).
            let loadedIngredients = loadedParts.isEmpty ? Self.inputs(for: recipe, foodItems: recipeFoods) : []
            let loadedSteps = loadedParts.isEmpty ? (recipe.steps ?? []) : []
            // The notes field shows a stored default note in the person's language; the save hands the
            // stored English back while the field is left as drawn (``StoredFoodNote``).
            let drawnNotes = StoredFoodNote.displayedRecipeNotes(recipe.notes)
            _name = State(initialValue: recipe.name)
            _servings = State(initialValue: recipe.servings)
            _notes = State(initialValue: drawnNotes)
            _ingredients = State(initialValue: loadedIngredients)
            _steps = State(initialValue: loadedSteps)
            _partsDraft = State(initialValue: RecipePartsDraft(parts: loadedParts))
            // Editing opens on the WHOLE recipe: expanding the first ingredient's search editor pushed
            // the list, servings and steps below the fold, so the user had to tap Done before they
            // could see what they came to change. Blank rows still auto-expand (see `ingredientsSection`).
            _expandedId = State(initialValue: nil)
            _originalDraft = State(initialValue: RecipeDraftSnapshot(
                name: recipe.name,
                servings: recipe.servings,
                notes: drawnNotes,
                ingredients: loadedIngredients,
                steps: loadedSteps,
                parts: loadedParts
            ))
        } else {
            let first = ManualRecipeIngredientInput()
            _ingredients = State(initialValue: [first])
            _expandedId = State(initialValue: first.id)
            _originalDraft = State(initialValue: RecipeDraftSnapshot(
                name: "",
                servings: 1,
                notes: "",
                ingredients: [first],
                steps: [],
                parts: []
            ))
        }
    }

    /// Whether the editor holds edits a swipe-away would silently throw out.
    private var isDirty: Bool {
        originalDraft != RecipeDraftSnapshot(
            name: name, servings: servings, notes: notes, ingredients: ingredients, steps: steps,
            parts: partsDraft.parts
        )
    }

    /// Every ingredient row being edited: the one list of a one-part recipe, or every part's rows.
    private var allIngredientInputs: [ManualRecipeIngredientInput] {
        partsDraft.isMultipart ? partsDraft.allIngredients : ingredients
    }

    @ViewBuilder
    var body: some View {
        if isEmbeddedInNavigationStack {
            // Pushed: no draft guard of its own, so a re-tap of the tab that would pop it asks
            // first (the tab button sits right under the save bar). Pushed inside the Food tab, the
            // floating tab bar covers the page's bottom, so the save bar is lifted above it — it
            // rested under the bar, and a tap on Save selected the tab (2026-10-01). A no-op inside
            // a sheet, which covers the bar.
            recipeContent
                .tabReselectDraft(isDirty: isDirty)
                .fernletTabBarSafeAreaClearance()
        } else {
            NavigationStack {
                recipeContent
                    // Presented as a sheet: a swipe-down used to discard a typed recipe with no
                    // warning. The guard also renders the pinned ``SheetHeader`` (Cancel + title) —
                    // the sheet's title lives there, not in the scroll content (2026-08-21
                    // template). On the editor page, not around the stack: the header's top inset
                    // never reached this page's scroll view through the stack, so the first rows
                    // (the name field) drew under the header and could not be tapped (2026-10-01).
                    // A pushed scanner page keeps its own back chevron, as in `MealSheet`.
                    .fernletDraftGuard(isDirty: isDirty, title: editorTitle) { dismiss() }
            }
            // At the sheet root too: the guard's swipe-dismiss block is a preference of the editor
            // page, and it stops applying once a pushed scanner page covers that page.
            .interactiveDismissDisabled(isDirty)
        }
    }

    private var recipeContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Pushed pages title themselves in the nav bar (see `.navigationTitle` below);
                    // the sheet presentation titles itself in the draft guard's pinned header.
                    SheetField("Recipe name") {
                        TextField("black bean bowls", text: $name, prompt: .fieldPrompt("black bean bowls"))
                            .submitLabel(.done)
                            .sheetTextInput()
                    }

                    SheetField("Notes") {
                        SheetTextEditor(text: $notes, placeholder: "prep notes, substitutions, storage", minHeight: 82)
                    }

                    if partsDraft.isMultipart {
                        partsSection
                    } else {
                        ingredientsSection
                    }

                    perServingCard

                    servingsField

                    if !partsDraft.isMultipart {
                        stepsSection
                        splitIntoPartsButton
                    }

                    deleteRecipeButton
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }

            saveBar
        }
        // b3-recipe-new: the sheet's paper; pushed in a panel (Create recipe › Manual entry), the
        // dotted page under the wooden plate, which carries the title.
        .background { if isEmbeddedInNavigationStack { FernletDottedPage().ignoresSafeArea() } else { WorldPalette.paper.ignoresSafeArea() } }
        // Belt and braces for the unit menu and the steppers: this editor is reached from a routed
        // sheet, its own sheet, and two pushed stacks, and an untinted system control renders Apple
        // blue in any presentation that isn't already tinted.
        .tint(Color.moss)
        // The keyboard "Done" for the Qty and macro number pads, which have no return key. Declared
        // on this page because it is always a page of a stack (pushed, or the root of its own
        // sheet's stack), and a Done declared by the host outside that stack never reaches it.
        .keyboardDoneToolbar()
        .modifier(RecipeEditorPageTitle(isPushed: isEmbeddedInNavigationStack, isNew: editingRecipe == nil))
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
                RecipeIngredientRows(ingredients: $ingredients, expandedId: $expandedId, store: store,
                                     onRemove: removeIngredient)
                // Stacks at accessibility sizes: side by side, "Add ingredient" / "Scan barcode"
                // squeezed to the edge and broke mid-word.
                AdaptiveStack(spacing: 8) {
                    Button {
                        addIngredient()
                    } label: {
                        RecipeEditorActionLabel(title: "Add ingredient")
                    }
                    // R3: the list is bounded where it grows — the same ceiling the paste decoder uses.
                    .disabled(ingredients.count >= RecipeLimits.maxIngredients)

                    #if canImport(UIKit)
                    Button {
                        scanTargetPartID = nil
                        showingBarcodeScanner = true
                    } label: {
                        RecipeEditorActionLabel(title: "Scan barcode", sprite: WorldSprites.barcode)
                    }
                    #endif
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
            }
        }
    }

    /// A multipart recipe's parts, each with its own ingredients and steps (see `RecipePartsEditor`).
    private var partsSection: some View {
        SheetField("Parts") {
            RecipePartsEditor(
                draft: $partsDraft, store: store, expandedId: $expandedId,
                onScanBarcode: { partID in
                    scanTargetPartID = partID
                    showingBarcodeScanner = true
                },
                onRemovePart: requestRemovePart
            )
        }
    }

    /// Offers to split a one-part recipe into parts: its rows become the first part and an empty second
    /// part follows, ready to be named ("a dressing you make first, then the salad").
    private var splitIntoPartsButton: some View {
        Button {
            guard partsDraft.split(ingredients: ingredients, steps: steps) != nil else { return }
            ingredients = []
            steps = []
            expandedId = nil
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Split into parts")
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.mossInk)
                Text("For a recipe made in stages, like a dressing you make first and a salad you put together after.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .modifier(RecipeEditorCardFrame())
        }
        .buttonStyle(.plain)
        .disabled(ingredients.count >= RecipeLimits.maxIngredients)
        .accessibilityIdentifier("recipeEditor.splitIntoParts")
    }

    /// Removes a part, asking first when it holds anything the user typed. When one part is left, the
    /// recipe goes back to a single ingredient list and step list, holding that part's rows.
    private func requestRemovePart(_ partID: UUID) {
        guard !partsDraft.isBlank(partID) else {
            removePart(partID)
            return
        }
        let partName = (partsDraft.parts.first { $0.id == partID }?.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingDestructiveAction = DestructiveConfirmation(
            title: partName.isEmpty ? "Remove this part?" : "Remove \u{201C}\(partName)\u{201D}?",
            message: "The part's ingredients and steps are taken out of this recipe.",
            confirmLabel: "Remove part",
            auditEvent: "recipe.partRemoveConfirmed",
            perform: { removePart(partID) }
        )
    }

    private func removePart(_ partID: UUID) {
        guard let survivor = partsDraft.removePart(partID) else { return }
        ingredients = survivor.ingredients.isEmpty ? [ManualRecipeIngredientInput()] : survivor.ingredients
        steps = survivor.steps
        expandedId = nil
    }

    /// Appends one blank ingredient row, refusing past ``RecipeLimits/maxIngredients`` (R3: the cap
    /// is enforced where the input enters, not only on the button's disabled state).
    private func addIngredient() {
        guard ingredients.count < RecipeLimits.maxIngredients else { return }
        let new = ManualRecipeIngredientInput()
        ingredients.append(new)
        expandedId = new.id
    }

    /// What one serving holds as the rows stand, in the coloured macro tags (calories only behind
    /// the explicit opt-in).
    private var perServingCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Per serving")
                RecipeMacroTags(macros: perServingTotals, showsCalories: store.settings.showCalories)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var servingsField: some View {
        FernletCard {
            HStack(spacing: 10) {
                Text("Servings")
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.bark)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                FernletStepper("Servings", value: $servings, in: 1...RecipeLimits.maxServings, step: 1,
                               display: Text("\(servings)"))
                    .accessibilityIdentifier("recipeEditor.servings")
            }
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
                HStack(spacing: 8) {
                    WorldSpriteView(sprite: WorldSprites.trash, scale: 2, tint: Color.terracottaInk)
                    Text("Delete recipe")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.destructive))
            .accessibilityIdentifier("recipeEditor.delete")
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
                let savedNotes = StoredFoodNote.savedRecipeNotes(editing: notes, stored: editingRecipe.notes)
                if partsDraft.isMultipart {
                    store.updateRecipe(editingRecipe, name: name, servings: servings, notes: savedNotes, parts: partsDraft.parts)
                } else {
                    store.updateRecipe(editingRecipe, name: name, servings: servings, notes: savedNotes,
                                       ingredients: ingredients, steps: steps)
                }
                finishAfterSave(named: name)
            }
        } else {
            createButtons
        }
    }

    /// Creates the recipe from whichever form the editor is in: one list, or parts. Discardable because
    /// "Save recipe" needs only the side effect; "Log & save" logs the recipe it returns.
    @discardableResult private func addDraftRecipe() -> RecipeDefinition {
        guard partsDraft.isMultipart else {
            return store.addRecipe(name: name, servings: servings, notes: notes, ingredients: ingredients, steps: steps)
        }
        return store.addRecipe(name: name, servings: servings, notes: notes, parts: partsDraft.parts)
    }

    /// Stacks at accessibility sizes — side by side, "Save recipe" / "Log & save" squeezed to the
    /// screen edge and broke mid-word.
    private var createButtons: some View {
        // b3-recipe-new: Save recipe and Log & save share the bottom, faded until there's a name and
        // an ingredient.
        AdaptiveStack(spacing: 10) {
            Button {
                addDraftRecipe()
                finishAfterSave(named: name)
            } label: {
                Text("Save recipe").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .opacity(canSave ? 1 : 0.55)

            Button {
                let recipe = addDraftRecipe()
                // Reported before the save finishes, so a host that pops or closes on save already
                // knows a meal toast is coming (the recipe book then leaves the speaking to it).
                if let meal = store.logRecipe(recipe) {
                    onMealsLogged([meal])
                }
                finishAfterSave(named: name)
            } label: {
                Text("Log & save").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
        }
        .disabled(!canSave)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(WorldPalette.paper)
    }

    /// Lands a barcode-resolved food (catalog hit or just-remembered user item) in the ingredient
    /// list, bound to the item exactly as `RecipeIngredientEditor.select` would bind a search pick.
    private func appendIngredient(for foodItem: FoodItem) {
        let unit = foodItem.preferredRecipeUnit
        let grams = foodItem.exactMacros
        let input = ManualRecipeIngredientInput(
            name: foodItem.name,
            selectedFoodItemId: foodItem.id,
            quantity: foodItem.defaultRecipeQuantity(for: unit),
            unit: unit.rawValue,
            protein: grams.protein,
            carbs: grams.carbs,
            fat: grams.fat
        )
        if partsDraft.isMultipart {
            // A part's Scan button aimed the scanner at that part.
            partsDraft.appendIngredient(input, to: scanTargetPartID)
        } else if ingredients.count == 1, ingredients[0].trimmedName.isEmpty {
            ingredients[0] = input
        } else {
            ingredients.append(input)
        }
        expandedId = input.id
    }

    private var canSave: Bool {
        let rows = allIngredientInputs
        let resolved = store.foodCatalog.items(ids: rows.compactMap(\.selectedFoodItemId))
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        rows.contains { !$0.trimmedName.isEmpty } &&
        rows.filter { !$0.trimmedName.isEmpty }.allSatisfy { $0.hasResolvedMacros(foodItems: resolved) }
    }

    private var perServingTotals: MacroTotals {
        let rows = allIngredientInputs
        let resolved = store.foodCatalog.items(ids: rows.compactMap(\.selectedFoodItemId))
        let totals = rows.reduce(into: MacroTotals()) { partial, ingredient in
            guard !ingredient.trimmedName.isEmpty,
                  let macros = ingredient.resolvedMacros(foodItems: resolved) else { return }
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
                    let index = steps.firstIndex(where: { $0.id == step.id }) ?? 0
                    RecipeStepEditorCard(
                        step: $step, index: index, count: steps.count,
                        accessibilityIdentifier: "recipeEditor.step.\(index)",
                        onMove: { moveStep(step.id, by: $0) },
                        onRemove: { removeStep(step.id) }
                    )
                }
                addStepButton
            }
        }
    }

    private var addStepButton: some View {
        Button {
            addStep()
        } label: {
            RecipeEditorActionLabel(title: "Add step")
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
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
            // A pre-fill the person sees in the field and saves as their own words, so it is written
            // in their language; nothing reads it back as a token.
            ingredient.name = result.servingSize
                ?? String(localized: "recipeEditor.scannedIngredient.defaultName", defaultValue: "Scanned serving",
                          comment: "Pre-filled name of a recipe ingredient read from a nutrition label that printed no serving size. The person can edit it.")
        }
        ingredient.quantity = 1
        ingredient.unit = RecipeUnit.serving.rawValue
        ingredient.selectedFoodItemId = nil
        ingredient.protein = result.protein.map(Double.init) ?? ingredient.protein
        ingredient.carbs = result.carbs.map(Double.init) ?? ingredient.carbs
        ingredient.fat = result.fat.map(Double.init) ?? ingredient.fat
        ingredient.scannedMicronutrients = result.micronutrients().hasAnyValue ? result.micronutrients() : ingredient.scannedMicronutrients
        ingredients[0] = ingredient
        expandedId = ingredient.id
    }

    private func scannedRecipeName(from result: NutritionLabelResult) -> String {
        ScannedItemName.prefill(servingSize: result.servingSize)
    }

    private static func inputs(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> [ManualRecipeIngredientInput] {
        let inputs = RecipeEditorInputs.inputs(for: recipe.ingredients, foodItems: foodItems)
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
    /// A multipart recipe's parts (empty for a one-part recipe), so an edit inside any part counts.
    let parts: [RecipeComponentInput]
}

/// The collapsed one-line summary of a recipe ingredient (name plus a quantity/macros line), shown
/// while a different ingredient's editor is expanded.
///
/// Tapping the row re-expands it into ``RecipeIngredientEditor``; the trailing x removes it. The
/// calorie figure in the summary renders only behind the explicit calorie opt-in.
struct CollapsedIngredientRow: View {
    var ingredient: ManualRecipeIngredientInput
    var catalog: FoodCatalog
    /// Macros-first: the trailing calorie figure renders only behind the explicit opt-in.
    var showCalories: Bool
    var onExpand: () -> Void
    var onRemove: () -> Void

    /// The row's grams before rounding, so a typed 3.4 g reads "P3.4g" (whole grams read as before).
    private var grams: PreciseMacros? {
        ingredient.resolvedPreciseMacros(foodItems: catalog.resolved(for: ingredient))
    }

    /// Calories stay whole: derived from the rounded grams, as every total is.
    private var calories: Int? {
        grams?.rounded.calories
    }

    /// The quantity and the grams share one locale separator ("1,5 cup · P3,4g" in de), so the
    /// quantity goes through ``RecipeQuantityDisplay`` rather than a POSIX `%g`. Each shape of the
    /// line is one whole key (the calorie tail is not appended in English).
    private var summaryLine: String {
        let quantity = RecipeQuantityDisplay.display(ingredient.quantity)
        // A named portion (F4b) reads as its words ("2 cup, sliced"); a unit as its token, as before.
        let measure = ingredient.portion?.label ?? ingredient.unit
        guard let grams else {
            return String(localized: "food.ingredientRow.summary.unconverted",
                          defaultValue: "\(quantity) \(measure) · Conversion unavailable",
                          comment: "A collapsed recipe-ingredient row whose amount has no gram conversion. The arguments are the amount and its unit or portion word, shown as saved.")
        }
        let protein = MacroGramEntry.display(grams.protein)
        let carbs = MacroGramEntry.display(grams.carbs)
        let fat = MacroGramEntry.display(grams.fat)
        guard showCalories, let calories else {
            return String(localized: "food.ingredientRow.summary",
                          defaultValue: "\(quantity) \(measure) · P\(protein)g C\(carbs)g F\(fat)g",
                          comment: "A collapsed recipe-ingredient row: the amount and its unit, then grams of protein (P), carbs (C) and fat (F).")
        }
        return String(localized: "food.ingredientRow.summary.calories",
                      defaultValue: "\(quantity) \(measure) · P\(protein)g C\(carbs)g F\(fat)g · \(calories) cal",
                      comment: "A collapsed recipe-ingredient row with calories shown: the amount and its unit, grams of protein (P), carbs (C) and fat (F), then calories.")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onExpand) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ingredient.name)
                        .font(FernletFramedFont.rowTitleBold)
                        .foregroundStyle(WorldPalette.bark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(summaryLine)
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onRemove) {
                FernletIcon(.close, scale: 2)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Two whole labels: an English "ingredient" spliced into the key read English in every language.
            .fernletIconButton(ingredient.name.isEmpty ? "Remove ingredient" : "Remove \(ingredient.name)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .modifier(RecipeEditorCardFrame())
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
/// A detached task does not inherit its parent's cancellation, so the parent's is forwarded to it:
/// a keystroke that supersedes a search already running cancels that search too, and the typed
/// catalog path stops at its next stage boundary (ingredient-search round, F9) instead of finishing
/// work nobody will read.
/// An empty query returns `[]` immediately. Callers must invoke it from `.task(id:)` keyed on the
/// live text, never synchronously in `body`.
///
/// `ranking` has no default, so each field states its order: the recipe editor passes
/// `.ingredientIdentity` (ingredient-search round F5 — the plain ingredient first, the owner's call
/// for recipes), while the meal composer and Adjust meal keep `.standard`.
enum CatalogTypeahead {
    /// One settled-keystroke query. nil = this call was superseded; apply nothing.
    static func matches(for text: String, catalog: FoodCatalog, ranking: FoodSearchRanking) async -> [FoodItem]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Debounce; a newer keystroke cancels this sleep and we bail before doing any work.
        do {
            try await Task.sleep(for: .milliseconds(220))
        } catch {
            return nil
        }
        // Heavy SQLite/index/score work runs off the main actor. `catalog` is Sendable.
        let search = Task.detached { [catalog] in
            catalog.results(for: trimmed, context: .userTyped, ranking: ranking)
        }
        let hits = await withTaskCancellationHandler {
            await search.value
        } onCancel: {
            search.cancel()
        }
        // Drop the result if this task was superseded while the query was running.
        guard !Task.isCancelled else { return nil }
        return hits
    }
}

/// A query-bound typeahead snapshot. Cached rows are visible and selectable only while they answer
/// the field's current normalized query; editing the field makes an older snapshot inert immediately.
nonisolated struct CatalogTypeaheadResultSet {
    private(set) var settledQuery = ""
    private(set) var items: [FoodItem] = []

    mutating func clear() {
        settledQuery = ""
        items = []
    }

    mutating func bind(_ items: [FoodItem], to query: String) {
        settledQuery = Self.normalized(query)
        self.items = items
    }

    func visibleMatches(for query: String) -> [FoodItem] {
        guard isSettled(for: query) else { return [] }
        return items
    }

    func selectable(_ foodItem: FoodItem, for query: String) -> FoodItem? {
        visibleMatches(for: query).first(where: { $0.id == foodItem.id })
    }

    func isSettled(for query: String) -> Bool {
        let normalized = Self.normalized(query)
        return !normalized.isEmpty && settledQuery == normalized
    }

    private static func normalized(_ query: String) -> String {
        FoodItemSearch.normalized(query)
    }
}

/// One catalog typeahead suggestion: name + provenance badge over the reference serving/macros.
///
/// Shared by the recipe editor's ingredient search and Adjust meal's Replace/"Add an item" fields
/// so a suggestion reads identically wherever it appears (FOOD-05).
private struct CatalogSuggestionRow: View {
    var foodItem: FoodItem
    var trailingSystemImage = "plus.circle"
    var onSelect: (() -> Void)?

    /// The reference serving's grams as a row reads them: a custom food typed as 3.4 g shows "3.4",
    /// and every whole-gram food reads exactly as before. The serving size beside them uses the same
    /// locale separator (``RecipeQuantityDisplay``).
    private var grams: (protein: String, carbs: String, fat: String) {
        let exact = foodItem.exactMacros
        return (MacroGramEntry.display(exact.protein), MacroGramEntry.display(exact.carbs),
                MacroGramEntry.display(exact.fat))
    }

    @ViewBuilder
    var body: some View {
        if let onSelect {
            Button(action: onSelect) { rowContent }
                .buttonStyle(.plain)
                // Voice Control: the row's name runs on through its source and serving line;
                // the food's name is what a user says.
                .accessibilityInputLabels([Text(verbatim: foodItem.name)])
        } else {
            // One element, then selected. The trait used to land on an uncombined HStack, which
            // splits into four elements — name, source, macros, check glyph — each read "selected".
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
        }
    }

    private var rowContent: some View {
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
                Text("\(RecipeQuantityDisplay.display(foodItem.servingSize)) \(foodItem.servingUnit) · P\(grams.protein)g C\(grams.carbs)g F\(grams.fat)g")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
                    // "P0g C25g F0g" is a glance format; spoken letter by letter it is noise.
                    .accessibilityLabel(Text("\(RecipeQuantityDisplay.display(foodItem.servingSize)) \(foodItem.servingUnit), protein \(grams.protein) grams, carbs \(grams.carbs) grams, fat \(grams.fat) grams"))
            }
            Spacer()
            // Decorative: the row is the button (add) or carries the selected trait (chosen), so
            // the glyph's own spoken name only added "Add" / "checkmark" to the end of the row.
            Image(systemName: trailingSystemImage)
                .foregroundStyle(Color.moss)
                .accessibilityHidden(true)
        }
        .padding(10)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The shared settled-miss card for catalog searches.
///
/// The action stack is deliberately its own seam: a later recipe-description drafting affordance
/// can join a recipe composer's miss state without changing typeahead state or displacing today's
/// deterministic manual path. This increment adds no AI control or behavior.
private struct CatalogSearchEmptyState: View {
    var actionTitle: LocalizedStringKey
    var action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            EmptyState(text: "No catalog matches.", systemImage: "magnifyingglass")
            Button(action: action) {
                Label(actionTitle, systemImage: "plus.circle")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("catalogSearch.empty")
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
struct RecipeIngredientEditor: View {
    @Binding var ingredient: ManualRecipeIngredientInput
    var catalog: FoodCatalog
    var onSaveCustomIngredient: (ManualRecipeIngredientInput) -> FoodItem?
    var onCollapse: (() -> Void)?
    var onRemove: () -> Void
    /// The person's own "grams in one" for a food (F4b, `RecipePortionGramsMemory`), offered in the
    /// unit menu under "Your size".
    var rememberedPortions: (UUID) -> [RecipeHouseholdMeasure] = { _ in [] }

    /// Typeahead matches, computed off the main thread and debounced (see `.task` below).
    /// The `catalog.results(for:)` call does real work (SQLite + hydrate + index + score) and the
    /// catalog is growing toward ~482k rows, so it must never run synchronously in `body`.
    @State private var typeaheadResults = CatalogTypeaheadResultSet()
    /// True after the user takes the explicit create-it escape — from a settled catalog miss, or from
    /// beneath a list that holds nothing right (ingredient-search round, F9).
    @State private var isCreatingCustomIngredient = false
    /// The label the editor is asking the grams of — "How many grams is one?" (F4b fix round 1, report
    /// §6.3 Rung E) — or nil when it is not asking.
    @State private var askingGramsFor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchHeaderRow
            suggestionList
            quantityUnitRow
            RecipePortionGramsRow(ingredient: $ingredient)
            RecipePortionAskGramsRow(ingredient: $ingredient, askingGramsFor: $askingGramsFor)
            householdCaption
            macroSection
            saveCustomIngredientButton
            removeIngredientButton
        }
        .padding(.vertical, 6)
        .onChange(of: ingredient.name) { _, newValue in
            typeaheadResults.clear()
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
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                FernletIcon(.search, scale: 2)
                TextField("Search ingredient", text: $ingredient.name, prompt: .fieldPrompt("Search ingredient"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.none)
                    .accessibilityIdentifier("recipeIngredient.search")
            }
            .sheetTextInput()
            if let onCollapse, !ingredient.trimmedName.isEmpty {
                Button("Done", action: onCollapse)
                    .buttonStyle(.plain)
                    .font(FernletFramedFont.sheetControl)
                    .foregroundStyle(WorldPalette.mossInk)
                    .fernletTapTarget(minWidth: 44, minHeight: 44)
            }
        }
    }

    /// The labelled way out of an ingredient: a word, at the foot of the card (b3-recipe-new: bottom
    /// right), well away from the search field's Done.
    private var removeIngredientButton: some View {
        Button("Remove ingredient", action: onRemove)
            .buttonStyle(.plain)
            .font(FernletFramedFont.sheetControl)
            .foregroundStyle(Color.terracottaInk)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(ingredient.trimmedName.isEmpty ? "Remove ingredient" : "Remove \(ingredient.name)")
    }

    /// What a household amount counts as, when the line will be saved as grams (ingredient-search
    /// round, F4a/F4b): "1 each" of a banana reads "Counted as 1 medium (118 g)", two eggs "Counted as
    /// 2 eggs (100.6 g)", so the size a USDA portion or typical size supplies is never silent.
    @ViewBuilder private var householdCaption: some View {
        if let counted = householdCaptionText {
            Text(counted)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("recipeIngredient.householdAmount")
        }
    }

    /// The caption for the line as it will be saved, when it is a household choice.
    private var householdCaptionText: AttributedString? {
        guard let selectedFoodItem else { return nil }
        let saved = ingredient.recipeLine(for: selectedFoodItem).savingHouseholdAsGrams(using: selectedFoodItem)
        return RecipeHouseholdCaption.caption(for: saved)
    }

    @ViewBuilder private var suggestionList: some View {
        let visibleMatches = typeaheadResults.visibleMatches(for: ingredient.name)
        if !visibleMatches.isEmpty && selectedFoodItem == nil {
            VStack(spacing: 4) {
                ForEach(visibleMatches) { foodItem in
                    CatalogSuggestionRow(foodItem: foodItem) {
                        guard let current = typeaheadResults.selectable(foodItem, for: ingredient.name) else { return }
                        // B6: a typeahead row picked is a choice made, felt like a chip.
                        FernletFeedback.system.play(.tick)
                        pick(current, among: visibleMatches)
                    }
                }
            }
            .accessibilityIdentifier("recipeIngredient.catalogResults")
            CustomIngredientEscapeRow(isCreating: isCreatingCustomIngredient) { isCreatingCustomIngredient = true }
        } else if showsSettledMiss && !isCreatingCustomIngredient {
            CatalogSearchEmptyState(actionTitle: "Create custom ingredient") {
                isCreatingCustomIngredient = true
            }
            .accessibilityIdentifier("recipeIngredient.catalogMiss")
        } else if isCreatingCustomIngredient {
            Text("Add its macros below, then save the custom ingredient.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
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
        HStack(spacing: 10) {
            TextField("Qty", value: $ingredient.quantity, format: .number, prompt: .fieldPrompt("Qty"))
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.none)
                .sheetTextInput()
                .frame(maxWidth: 92)
            unitMenu
        }
    }

    /// A bound food's own menu (F4b: its USDA portions, typical sizes, and only the units that
    /// convert); an unbound (custom) row keeps every unit, since its amount is its own serving, in the
    /// framed dropdown (`b3-recipe-new`).
    @ViewBuilder private var unitMenu: some View {
        if let selectedFoodItem {
            RecipePortionMenu(
                ingredient: $ingredient,
                choices: RecipePortionPicker.choices(for: selectedFoodItem, personal: rememberedPortions(selectedFoodItem.id)),
                askingGramsFor: $askingGramsFor
            )
        } else {
            FernletDropdown("Unit", selection: $ingredient.unit, options: RecipeUnit.allCases.map(\.rawValue),
                            showsLabel: false, fullWidth: true) { token in
                Text(verbatim: RecipeUnit(rawValue: token)?.label ?? token)
            }
        }
    }

    /// Locked catalog macros (with the "Manual" escape hatch) when the ingredient is bound to a food
    /// item; the three editable macro rows when it isn't.
    @ViewBuilder private var macroSection: some View {
        if let selectedFoodItem {
            if let grams = ingredient.resolvedPreciseMacros(foodItems: catalog.resolved(for: ingredient)) {
                LockedMacroSummary(foodItem: selectedFoodItem, grams: grams) {
                    useManualNutrition(seededFrom: selectedFoodItem)
                }
            } else {
                unweighedAmountPrompt(for: selectedFoodItem)
            }
        } else {
            MacroInputRow(label: "Protein", unit: "g", value: $ingredient.protein, range: 0.0...250.0)
            MacroInputRow(label: "Carbs", unit: "g", value: $ingredient.carbs, range: 0.0...300.0)
            MacroInputRow(label: "Fat", unit: "g", value: $ingredient.fat, range: 0.0...200.0)
        }
    }

    /// A bound amount the food cannot weigh (F4b fix round 1, report §6.3 Rung E): plain words instead of
    /// the old "exact serving basis or one source-backed portion", the "How many grams is one?"
    /// question where the line's own unit is a count or volume (``RecipePortionAskGramsRow``), and the
    /// Manual escape.
    @ViewBuilder private func unweighedAmountPrompt(for foodItem: FoodItem) -> some View {
        Text("Fernlet can't weigh this amount. Choose another unit, or say how many grams one is.")
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.sun)
            .fernletWrappingText()
        if askingGramsFor == nil,
           let label = RecipePortionPicker.labelAskingGrams(heldUnit: ingredient.unit, portion: ingredient.portion) {
            Button("How many grams is one?") { askingGramsFor = label }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("recipeIngredient.askGramsForUnit")
        }
        Button("Use manual nutrition") {
            useManualNutrition(seededFrom: foodItem)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
    }

    /// The debounced typeahead query behind `.task(id: ingredient.name)`: the shared
    /// ``CatalogTypeahead`` mechanics (settle the keystroke, run the catalog search off the main
    /// actor, drop a superseded result), plus this editor's own gating on a chosen food.
    private func refreshTypeahead() async {
        let text = ingredient.trimmedName
        // Mirror the render gating: nothing to show when a food is chosen or the field is empty.
        guard selectedFoodItem == nil, !text.isEmpty else {
            typeaheadResults.clear()
            return
        }
        // nil = superseded by a newer keystroke: keep the current list rather than a stale one. A
        // recipe line wants the ingredient itself first (F5).
        guard let hits = await CatalogTypeahead.matches(for: text, catalog: catalog, ranking: .ingredientIdentity) else {
            return
        }
        typeaheadResults.bind(hits, to: text)
    }

    private var showsSettledMiss: Bool {
        selectedFoodItem == nil
            && typeaheadResults.isSettled(for: ingredient.name)
            && typeaheadResults.visibleMatches(for: ingredient.name).isEmpty
    }

    private var selectedFoodItem: FoodItem? {
        ingredient.selectedFoodItem(in: catalog.resolved(for: ingredient))
    }

    private var canSaveCustomIngredient: Bool {
        guard selectedFoodItem == nil, !ingredient.trimmedName.isEmpty else { return false }
        return ingredient.protein > 0 || ingredient.carbs > 0 || ingredient.fat > 0
    }

    /// A tap on a suggestion: binds the food and, when the pick should teach search (F9b,
    /// ``RecipeSearchPick`` — typed words, a row below the first), keeps those words on the row for the
    /// recipe's save to remember. Nothing is written here: an editor the person cancels teaches nothing.
    private func pick(_ foodItem: FoodItem, among shown: [FoodItem]) {
        let taught = RecipeSearchPick.query(typed: ingredient.name, picked: foodItem, shown: shown)
        select(foodItem)
        ingredient.pickedForSearch = taught
    }

    /// Binds `foodItem` — a suggestion tap (through ``pick(_:among:)``) or a just-saved custom food —
    /// and forgets any earlier pick's words, so only the tap that bound THIS food can teach.
    private func select(_ foodItem: FoodItem) {
        let unit = foodItem.preferredRecipeUnit
        ingredient.name = foodItem.name
        ingredient.selectedFoodItemId = foodItem.id
        ingredient.pickedForSearch = nil
        ingredient.quantity = foodItem.defaultRecipeQuantity(for: unit)
        ingredient.unit = unit.rawValue
        ingredient.portion = nil
        askingGramsFor = nil
        seedManualGrams(foodItem.exactMacros)
        isCreatingCustomIngredient = false
    }

    /// The "Manual" / "Use manual nutrition" escape: unbinds the row and seeds its editable grams.
    ///
    /// F4b fix round 1 (finding s2-C-F4B-C2, report §6.3 item 0d): the row keeps the amount it showed
    /// — a named portion folded into its grams ("2 fruit (272 g)" becomes 272 g, never "2 g") — and the
    /// grams it seeds are the ones the locked panel showed FOR THAT AMOUNT, so the custom food a save
    /// mints from it ("272 g" carrying 272 g of nutrition) is as dense as the food. Only an amount the
    /// food cannot weigh seeds the food's own serving, as before.
    private func useManualNutrition(seededFrom foodItem: FoodItem) {
        let shown = ingredient.resolvedPreciseMacros(foodItems: [foodItem])
        ingredient = ingredient.droppingPortion()
        ingredient.selectedFoodItemId = nil
        ingredient.pickedForSearch = nil
        askingGramsFor = nil
        seedManualGrams(shown ?? foodItem.exactMacros)
    }

    /// Seeds the row's editable grams with `grams` as given (a food's EXACT grams, or the amount shown at
    /// tenths), so a 3.4 g custom food never becomes 3 on its way back into an editable row.
    private func seedManualGrams(_ grams: PreciseMacros) {
        ingredient.protein = grams.protein
        ingredient.carbs = grams.carbs
        ingredient.fat = grams.fat
    }

    private func syncSelection(for name: String) {
        // Only UNBIND when the user edits the name away from a previously-selected food. We deliberately
        // do NOT auto-bind on an exact normalized-name match while typing: with the large branded catalog
        // (tens of thousands of products), common words like "chicken"/"milk"/"eggs" collide with branded
        // product names, so auto-binding would silently hijack the field — locking macros to a random
        // product and hiding the suggestion list. Binding happens only when the user taps a suggestion.
        if let selectedFoodItem, selectedFoodItem.name != name {
            // A named portion's count becomes its grams, never "2 g" (F4b fix round 1).
            ingredient = ingredient.droppingPortion()
            ingredient.selectedFoodItemId = nil
            ingredient.pickedForSearch = nil
            askingGramsFor = nil
        }
        isCreatingCustomIngredient = false
    }
}

/// The locked-macros panel shown when an ingredient is bound to a catalog food item.
///
/// Displays the resolved macros and the item's reference serving, with a "Manual" escape hatch that
/// unbinds the ingredient and seeds the editable fields from the item's macros. The grams read at
/// one decimal place when the food carries a fraction ("P 3.4g"), whole otherwise.
private struct LockedMacroSummary: View {
    var foodItem: FoodItem
    var grams: PreciseMacros
    var onUseManual: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(macroSourceTitle, systemImage: foodItem.source == .manual ? "checkmark.circle.fill" : "lock.fill")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
                Spacer()
                Button("Manual", action: onUseManual)
                    .buttonStyle(.plain)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.slate)
            }
            Text("P \(MacroGramEntry.display(grams.protein))g · C \(MacroGramEntry.display(grams.carbs))g · F \(MacroGramEntry.display(grams.fat))g")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
            // The licence notice for an attributed source (Open Food Facts, ODbL).
            if let attribution = foodItem.source.attributionLine {
                Text(verbatim: attribution)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            Text("\(foodItem.category) · \(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit) reference")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
        .padding(12)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Where the locked macros came from. An Open Food Facts import must not be labelled USDA; the
    /// other sources keep the wording they always had.
    private var macroSourceTitle: LocalizedStringKey {
        switch foodItem.source {
        case .manual: "Saved macros"
        case .openFoodFacts: "Open Food Facts macros"
        case .usda, .aiResolved: "USDA macros"
        }
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

/// What Log meal's camera handed back (or the "Nothing to read here" fallback asked for), held until
/// the cover or sheet has gone and then routed by `MealSheet.applyCameraOutcome`.
private enum FoodCameraOutcome {
    case barcode(String)
    case label(NutritionLabelResult)
    case photo(UIImage)
    case library(Data)
    case byHand
    case unavailable
    case retake
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
    /// The host's meal-logged toast. A meal kept without its photo reports `landedWithCaveat`, and the
    /// toast's one haptic is then the caveat.
    var onLogged: MealLogReporter = .none
    /// A start handed in (the description, by-hand macros); nil opens the sheet empty.
    var seed: MealSheetSeed? = nil
    #if canImport(UIKit)
    /// One router owns the capture detectors, so the chooser branches reuse its injectable
    /// `barcodeDetector` seam (fakes reach every path) rather than newing up their own detector.
    var captureRouter = FoodCaptureRouter()
    #endif
    @State private var description = ""
    /// Query-bound typeahead rows for the primary composer field (research fix 1.11).
    @State private var catalogResults = CatalogTypeaheadResultSet()
    /// The exact row the user chose. Save logs this identity directly; it never re-resolves its name.
    @State private var selectedCatalogFood: FoodItem?
    /// Toggled by the explicit Change selection action to re-run the unchanged selected name.
    @State private var catalogSearchRestart = false
    @State private var mealType: MealType?
    @State private var notice: String?
    @State private var path: [MealFlowDestination] = []
    /// The typed product query held while the user reads the one-time egress disclosure.
    @State private var pendingWebNutritionLookup: String?
    /// Import was tapped with web lookup off: its disclosure is up (form answer 43).
    @State private var asksImportConsent = false
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
    /// Stacks the three helpers at accessibility sizes (the meal-type dropdown stacks itself).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The World's framed look; nil draws today's sheet.
    @Environment(\.fernletFramedLook) private var look
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
    /// Presented when the photo reads as neither a barcode nor a label ("Nothing to read here").
    @State private var captureChooser: CaptureChooserContext?
    /// A resolved scanned/label-parsed food held for the quick serving-count confirm step before it is
    /// logged — set by the barcode/label resolve callbacks instead of logging immediately.
    @State private var pendingScannedFood: PendingScannedFood?
    /// The camera behind the field's camera button (`FoodCaptureCameraView`), full screen.
    @State private var showingCaptureCamera = false
    /// What the camera handed back, applied once its cover has gone (`applyCameraOutcome`).
    @State private var cameraOutcome: FoodCameraOutcome?
    #endif

    var body: some View {
        mealPresentations(mealNavigation)
    }

    /// The log-meal stack itself: the composer plus its seven flow destinations, and the modifiers
    /// that guard a resolve in flight.
    private var mealNavigation: some View {
        NavigationStack(path: $path) {
            mealContent
                // The composer's keyboard "Done" (its macro number pads have no return key). On the
                // root page: the sheet chrome's Done sits outside this stack and reaches no page.
                .keyboardDoneToolbar()
                .navigationDestination(for: MealFlowDestination.self) { destination in
                    flowDestination(for: destination)
                }
        }
        .foodSheetBackground()
        #if canImport(UIKit)
        // T1-4, the caller's half: while the veil reads the photo, the sheet under it is out of
        // VoiceOver's and Switch Control's reach, as it is out of a finger's.
        .accessibilityHidden(isAnalyzingCapture)
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
            applySeed()
        }
    }

    /// Opens with the seed's description and by-hand macros, once (a later appear keeps the edits).
    private func applySeed() {
        guard let seed, description.isEmpty else { return }
        description = seed.description
        if let macros = seed.macros {
            manualProtein = macros.protein
            manualCarbs = macros.carbs
            manualFat = macros.fat
            isEnteringMacrosByHand = true
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
            // Reached when the live camera can't run ("Scan a food" with the camera off): a photo
            // added there goes through the same front door as a camera shot.
            BarcodeResolveFlowView(store: store, backTitle: String(localized: "Log meal"), onPhoto: { image in
                if !path.isEmpty { path.removeLast() }
                handleCapturedPhoto(image)
            }) { foodItem in
                pendingScannedFood = PendingScannedFood(item: foodItem, kind: .barcode)
            }
            #else
            EmptyView()
            #endif
        case .captureBarcode, .captureLabel, .rememberByHand:
            captureDestination(for: destination)
        case .productPageImport:
            FoodProductPageImportView(store: store) { product in
                description = product.name
                notice = Self.productSavedNotice(product.name)
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
                notice = Self.productSavedNotice(product.name)
                path.removeLast()
            }
        }
    }

    /// The capture landings: a barcode the camera (or a photo) read, a nutrition label it read, and the
    /// camera's "Add by hand".
    @ViewBuilder private func captureDestination(for destination: MealFlowDestination) -> some View {
        #if canImport(UIKit)
        switch destination {
        case .captureBarcode(let payload):
            // Resolve the read barcode through the same catalog-hit / name-&-remember path as a live
            // scan.
            BarcodePayloadResolveView(store: store, payload: payload, backTitle: String(localized: "Log meal")) { foodItem in
                pendingScannedFood = PendingScannedFood(item: foodItem, kind: .barcode)
            }
        case .captureLabel(let result):
            // A read nutrition label opens the name-it-&-remember screen with the macros filled in.
            // Logged through the label-scan path so provenance is truthful; the serving step confirms.
            BarcodeNotFoundView(store: store, barcode: "", prefilledScan: result,
                                backTitle: String(localized: "Log meal")) { foodItem in
                pendingScannedFood = PendingScannedFood(item: foodItem, kind: .label)
            }
        default:
            // The camera's "Add by hand": today's scanner hand entry (no barcode, a barcode-kind log).
            BarcodeNotFoundView(store: store, barcode: "", backTitle: String(localized: "Log meal")) { foodItem in
                pendingScannedFood = PendingScannedFood(item: foodItem, kind: .barcode)
            }
        }
        #else
        EmptyView()
        #endif
    }

    /// The composer's notice after a web product was saved from the Import screen.
    private static func productSavedNotice(_ name: String) -> String {
        String(localized: "mealComposer.notice.productSaved",
               defaultValue: "\(name) was saved. Review the meal description, then save your meal.",
               comment: "Log meal sheet: a packaged product was saved from the web and put in the description field. The argument is the product's name.")
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
            .alert("Search the web for nutrition?", isPresented: webNutritionConsentPresented) {
                Button("Continue locally", role: .cancel, action: declineWebNutritionLookup)
                Button("Allow web lookup", action: acceptWebNutritionLookup)
            } message: {
                Text("Fernlet will send the typed product search to DuckDuckGo’s private HTML search. It sends no account identifier, cookies, or health data. Fernlet may then open a product page from the result to read its nutrition label. You can revoke this in Settings at any time. Each web lookup is recorded only on this device in Connection history.")
            }
        #if canImport(UIKit)
            .sheet(item: $captureChooser, onDismiss: applyCameraOutcome) { context in
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
            .fullScreenCover(isPresented: $showingCaptureCamera, onDismiss: applyCameraOutcome) {
                captureCamera
            }
        #endif
    }

    private var webNutritionConsentPresented: Binding<Bool> {
        Binding(
            get: { pendingWebNutritionLookup != nil },
            set: { isPresented in
                if !isPresented { pendingWebNutritionLookup = nil }
            }
        )
    }

    private func acceptWebNutritionLookup() {
        guard let query = pendingWebNutritionLookup else { return }
        pendingWebNutritionLookup = nil
        store.acceptWebNutritionLookupConsent()
        path.append(.productSearch(query))
    }

    private func declineWebNutritionLookup() {
        guard let query = pendingWebNutritionLookup else { return }
        pendingWebNutritionLookup = nil
        store.declineWebNutritionLookupConsent()
        resolveTypedMeal(query, type: mealType)
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
        .fernletSheet()
    }

    /// The pre-log review sheet for a low-confidence or partially-matched resolution.
    private func reviewSheet(_ context: MealReviewContext) -> some View {
        MealReviewSheet(
            resolution: context.resolution,
            store: store,
            onConfirm: { reviewedMeals, confirmedRecipes in
                confirmReviewedMeals(reviewedMeals, confirmedRecipes: confirmedRecipes, context: context)
            },
            onDiscard: {
                // Leave the log sheet open with the original text so the user can adjust and retry.
                reviewContext = nil
            }
        )
        .fernletSheet()
    }

    /// Commits the user's reviewed meals (and the recipes they kept), attaches the held photo, and
    /// either dismisses or disarms Save when only the photo failed.
    private func confirmReviewedMeals(
        _ reviewedMeals: [Meal],
        confirmedRecipes: [RecipeDefinition],
        context: MealReviewContext
    ) {
        // User reviewed it: commit their version, never re-queue an AI retry over it. The recipes the
        // sheet offered and the user kept are minted here — and ONLY here — through the same
        // diary.recipes path, so no recipe reaches the book without an explicit confirm.
        let committed = store.commitResolution(
            MealResolution(
                meals: reviewedMeals,
                createdRecipes: confirmedRecipes,
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
        onLogged(committed, landedWithCaveat: !photoAttached)
        closeAfterLogging(photoAttached: photoAttached)
    }

    #if canImport(UIKit)
    /// "Nothing to read here" (`b3-capture-chooser` draft 2): the fallback for a photo the router
    /// couldn't read as a barcode or a label. Keep it as the meal photo, take it again, or type it.
    private func captureChooserSheet(_ context: CaptureChooserContext) -> some View {
        CaptureChooserSheet(
            image: context.image,
            aiEnabled: store.settings.aiStatus != .off,
            onMeal: {
                captureChooser = nil
                mealPhoto = context.image
                mealPhotoData = nil
            },
            onRetake: {
                captureChooser = nil
                cameraOutcome = .retake
            },
            onTypeInstead: {
                captureChooser = nil
            }
        )
        .fernletSheet()
    }

    /// The camera behind the field's camera button. Each hand-off is held until the cover is gone.
    private var captureCamera: some View {
        FoodCaptureCameraView(
            onBarcode: { finishCamera(.barcode($0)) },
            onLabel: { finishCamera(.label($0)) },
            onPhoto: { finishCamera(.photo($0)) },
            onLibraryPick: { finishCamera(.library($0)) },
            onAddByHand: { finishCamera(.byHand) },
            onUnavailable: { finishCamera(.unavailable) },
            onClose: { showingCaptureCamera = false }
        )
    }

    /// The field's camera button: the live camera where it can run, else "Scan a food" with the camera
    /// off (add a photo instead, or enter it by hand).
    private func openCaptureCamera() {
        if FoodCaptureCameraView.isLiveAvailable {
            showingCaptureCamera = true
        } else {
            path.append(.scanBarcode)
        }
    }

    private func finishCamera(_ outcome: FoodCameraOutcome) {
        cameraOutcome = outcome
        showingCaptureCamera = false
    }

    /// Routes what the camera handed back, once its cover has gone (or the chooser asked to retake).
    private func applyCameraOutcome() {
        guard let outcome = cameraOutcome else { return }
        cameraOutcome = nil
        switch outcome {
        case .barcode(let payload): path.append(.captureBarcode(payload))
        case .label(let result): path.append(.captureLabel(result))
        case .photo(let image): handleCapturedPhoto(image)
        case .library(let data): setLibraryPickedMealPhoto(data)
        case .byHand: path.append(.rememberByHand)
        case .unavailable: path.append(.scanBarcode)
        case .retake: openCaptureCamera()
        }
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
        .fernletSheet()
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
                // b3-meal draft 2: the field with its camera, then the catalog matches, then ONE
                // meal-type dropdown (FOOD-08: directly after the field), then the three small
                // helpers. Save stays pinned; the title lives in the template header.
                VStack(alignment: .leading, spacing: 18) {
                    photoAndIdentifySection

                    FoodSheetField("What did you eat?") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                descriptionField
                                captureCameraButton
                            }
                            mealCatalogSearchState
                        }
                    }

                    FoodMealTypeDropdown(selection: $mealType, inferred: inferredMealType)

                    if isEnteringMacrosByHand {
                        manualMacrosSection
                    }

                    helperButtons

                    noticeSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
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
        .background(look?.paper ?? Color.parchment)
        .onChange(of: description) { _, newValue in
            catalogResults.clear()
            guard selectedCatalogFood?.name != newValue else { return }
            selectedCatalogFood = nil
        }
        .task(id: MealCatalogSearchTaskID(query: description, restart: catalogSearchRestart)) {
            await refreshMealCatalogMatches()
        }
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

    /// The description field: a one-line log is the common case, so Return saves instead of inserting a
    /// line break; the field still grows to four lines for a longer description.
    private var descriptionField: some View {
        SheetGrowingTextField(text: $description, placeholder: "scrambled eggs and toast") {
            guard canSaveTypedMeal else { return }
            saveTapped()
        }
        // The caption above can't name this field (`namesControl` would also swallow the results
        // list beside it), so VoiceOver read the example placeholder as the field's name — easy to
        // mistake for text already typed. The field says what it is for instead.
        .accessibilityLabel("What did you eat?")
        .accessibilityIdentifier("mealComposer.search")
        // Voice Control: the field has no label of its own and its placeholder is an example, so it
        // is named by the question drawn above it.
        .accessibilityInputLabels([Text("What did you eat?"), Text("Search")])
    }

    /// Transient search content between the field and the meal-type dropdown (`b3-meal`): the matches
    /// as rows split by dotted rules, the chosen one with Change selection, or "No catalog matches."
    /// (`b3-meal-macros`), whose way on is the By hand helper below.
    @ViewBuilder private var mealCatalogSearchState: some View {
        if let selectedCatalogFood {
            VStack(spacing: 2) {
                FernletDottedRule()
                FoodCatalogMatchRow(foodItem: selectedCatalogFood, isChosen: true)
                    .accessibilityIdentifier("mealComposer.selectedCatalogFood")
                Button("Change selection", action: changeCatalogSelection)
                    .buttonStyle(.plain)
                    .font(look == nil ? .fernlet(.label) : FernletFramedFont.button)
                    .foregroundStyle(look?.link ?? Color.moss)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("mealComposer.changeCatalogSelection")
            }
        } else if !visibleMealCatalogMatches.isEmpty {
            VStack(spacing: 0) {
                ForEach(visibleMealCatalogMatches) { foodItem in
                    FernletDottedRule()
                    FoodCatalogMatchRow(foodItem: foodItem) {
                        guard let current = catalogResults.selectable(foodItem, for: description) else { return }
                        // B6: a typeahead row picked is a choice made, felt like a chip.
                        FernletFeedback.system.play(.tick)
                        selectCatalogFood(current)
                    }
                }
            }
            .accessibilityIdentifier("mealComposer.catalogResults")
        } else if showsMealCatalogMiss {
            FernletNotice("No catalog matches.") { FernletIcon(.search, scale: 2) }
                .accessibilityIdentifier("mealComposer.catalogMiss")
        }
    }

    private var showsMealCatalogMiss: Bool {
        catalogResults.isSettled(for: description) && visibleMealCatalogMatches.isEmpty
    }

    private var visibleMealCatalogMatches: [FoodItem] {
        catalogResults.visibleMatches(for: description)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectCatalogFood(_ foodItem: FoodItem) {
        description = foodItem.name
        selectedCatalogFood = foodItem
        catalogResults.clear()
    }

    private func changeCatalogSelection() {
        selectedCatalogFood = nil
        catalogResults.clear()
        catalogSearchRestart.toggle()
    }

    private func refreshMealCatalogMatches() async {
        let query = trimmedDescription
        guard selectedCatalogFood == nil, !query.isEmpty else {
            catalogResults.clear()
            return
        }
        // A meal keeps the standard order (F5 is the recipe surfaces' ranking only).
        guard let hits = await CatalogTypeahead.matches(for: query, catalog: store.foodCatalog, ranking: .standard) else {
            return
        }
        catalogResults.bind(hits, to: query)
    }

    /// Cancels on text edits and can deliberately re-run an unchanged query after Change selection.
    private struct MealCatalogSearchTaskID: Hashable {
        let query: String
        let restart: Bool
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
                Button { identifyMealPhoto(photo) } label: {
                    Text(isIdentifyingPhoto ? "Identifying..." : "Identify from photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .disabled(isIdentifyingPhoto)
            }
        }
        #endif
    }

    /// The camera at the end of the field (`b3-meal` draft 2): one camera that reads a barcode or a
    /// nutrition label by itself and otherwise takes the meal photo (`FoodCaptureCameraView`).
    @ViewBuilder private var captureCameraButton: some View {
        #if canImport(UIKit)
        FoodCaptureCameraButton { openCaptureCamera() }
        #endif
    }

    /// Log meal's three small helpers in one row (`b3-meal` draft 2): Recent (its own surface,
    /// FOOD-07; only with recent meals), Import (always since form answer 43: a web lookup end to end,
    /// so with lookup off its tap asks first, ``FoodImportTap``) and By hand (the stated macros path,
    /// FOOD-24). They stack at the largest sizes.
    private var helperButtons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if !store.recentMeals.isEmpty {
                FoodHelperButton(title: "Recent", sprite: FoodSprites.clock) { showingRecentMeals = true }
            }
            FoodHelperButton(title: "Import", sprite: FoodSprites.link, action: tapImport)
            FoodHelperButton(title: "By hand", sprite: WorldSprites.pen, isOn: isEnteringMacrosByHand) {
                withAnimation(FernletMotion.ui) { isEnteringMacrosByHand.toggle() }
            }
            .accessibilityLabel("Enter macros by hand")
            .accessibilityInputLabels([Text("By hand"), Text("Enter macros by hand")])
        }
        // The same disclosure the typed product search shows before its first lookup.
        .alert("Search the web for nutrition?", isPresented: $asksImportConsent) {
            Button("Not now", role: .cancel) { store.declineWebNutritionLookupConsent() }
            Button("Allow web lookup") {
                store.acceptWebNutritionLookupConsent()
                path.append(.productPageImport)
            }
        } message: {
            Text("Fernlet will send the typed product search to DuckDuckGo’s private HTML search. It sends no account identifier, cookies, or health data. Fernlet may then open a product page from the result to read its nutrition label. You can revoke this in Settings at any time. Each web lookup is recorded only on this device in Connection history.")
        }
    }

    /// Import's tap (form answer 43): open it while lookup is on (or, with AI features off, open it to
    /// say how to turn lookup on); otherwise ask for consent first.
    private func tapImport() {
        switch FoodImportTap.resolve(for: store.settings) {
        case .open, .openExplainingOff: path.append(.productPageImport)
        case .askFirst: asksImportConsent = true
        }
    }

    /// The three by-hand macro rows (`b3-meal-macros`). Editable always; a label scan that reached
    /// this composer would prefill them, but the scan flows commit through their own confirm step,
    /// so they start at zero here. Any nonzero value routes Save through the direct by-hand log.
    private var manualMacrosSection: some View {
        FoodSheetField("Macros") {
            MealMacroEditorRows(protein: $manualProtein, carbs: $manualCarbs, fat: $manualFat)
        }
    }

    /// The slot the "Auto" rule would file this meal under right now — the same
    /// `MealParser.classifyMealType` keyword-then-hour inference the resolve path applies, shown
    /// pre-save for the first time (FOOD-14).
    private var inferredMealType: MealType {
        MealParser.classifyMealType(description)
    }

    /// The calm inline notice line (a product saved from the web, a photo not saved or not recognised).
    @ViewBuilder private var noticeSection: some View {
        if let notice {
            Text(notice)
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                .italic(look == nil)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
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
        if let selectedCatalogFood {
            logSelectedCatalogFood(selectedCatalogFood)
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
            if store.shouldOfferWebNutritionLookupConsent {
                pendingWebNutritionLookup = mealDescription
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
        onLogged([meal], landedWithCaveat: !photoAttached)
        closeAfterLogging(photoAttached: photoAttached)
    }

    /// Logs the exact typeahead row the user picked, preserving its catalog identity and reference
    /// serving instead of feeding its display name back through the free-text resolver.
    private func logSelectedCatalogFood(_ foodItem: FoodItem) {
        let meal = store.logCatalogFoodItem(foodItem, mealType: mealType)
        #if canImport(UIKit)
        let photoAttached = attachPhoto(mealPhoto, data: mealPhotoData, to: [meal])
        #else
        let photoAttached = true
        #endif
        onLogged([meal], landedWithCaveat: !photoAttached)
        closeAfterLogging(photoAttached: photoAttached)
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
            onLogged(meals, landedWithCaveat: !photoAttached)
            closeAfterLogging(photoAttached: photoAttached)
        }
    }

    /// Closes the sheet once a log has gone to the toast (`onLogged`, beside each logging call) — or,
    /// when the meal's photo couldn't be sealed, keeps the sheet open on the notice so the photo
    /// never vanishes silently, with Save disarmed so the notice can't be answered with a second tap
    /// that logs the meal again. Shared by every commit path here (typed resolve, review, by-hand
    /// macros, a picked catalog row).
    ///
    /// B9: the second case is a meal that landed with something to read. It is felt as one by the
    /// toast, whose single haptic is `caveat` instead of `done` (every caller reports
    /// `landedWithCaveat: !photoAttached`), so nothing plays here: a `caveat` of its own would land in
    /// the same instant as the toast's.
    private func closeAfterLogging(photoAttached: Bool) {
        guard !photoAttached else {
            dismiss()
            return
        }
        didLogMeal = true
        notice = String(localized: "mealComposer.notice.photoNotSaved",
                        defaultValue: "Your meal is logged, but its photo couldn't be saved to your private store.",
                        comment: "Log meal sheet: the meal was logged but its photo failed to save on the device")
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
            // B15: the guess was waited for ("Identifying…"), so its arrival is felt — `done` as the
            // review sheet comes up with it, `caveat` beside the "couldn't quite tell" line.
            switch outcome {
            case .aiOff:
                break
            case .nothingRecognized:
                notice = String(localized: "mealComposer.notice.photoNotRecognized",
                                defaultValue: "Fernlet couldn't quite tell what's in this photo — want to type what you ate instead?",
                                comment: "Log meal sheet: Identify from photo found no food it could name")
                FernletFeedback.system.play(.caveat)
            case .resolved(let described, let resolution):
                description = described
                reviewContext = MealReviewContext(resolution: resolution, photo: photo, photoData: capturedPhotoData)
                FernletFeedback.system.play(.done)
            }
        }
    }

    // MARK: - Unified Capture auto-routing (Food Capture mockup §2b–2e)

    /// The context handed to ``CaptureChooserSheet`` when the router couldn't read the photo (its
    /// `.ambiguous` route: no barcode, and a label reading too weak to trust).
    ///
    /// Identifiable with a fresh `id` per presentation so `sheet(item:)` re-presents for a retake.
    private struct CaptureChooserContext: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    /// A camera shot's handler: run the auto-router over the still photo (barcode → label → meal),
    /// showing the calm "analyzing…" veil, then route to the matching EXISTING flow. A reading too weak
    /// to trust offers "Nothing to read here"; the meal branch is the graceful default.
    private func handleCapturedPhoto(_ image: UIImage) {
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
            case .ambiguous:
                // Reached only after the barcode scan came up empty and the label read too little:
                // the fallback asks what to do with the photo (draft 2: no "which is it?" question).
                captureChooser = CaptureChooserContext(image: image)
            }
        }
    }

    #endif

    #if canImport(UIKit)
    /// The attached meal photo in an ink frame, with a framed ✕ that takes it off.
    private func mealPhotoPreview(_ image: UIImage) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityIgnoresInvertColors()
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipShape(shape)
                .overlay(shape.strokeBorder(look?.ink ?? Color.bark.opacity(0.10), lineWidth: look == nil ? 1 : 2))
            // Clear BOTH the preview image and the sealed-ready bytes: `attachPhoto` prefers the byte
            // path, so leaving `mealPhotoData` set would re-attach a photo the user explicitly removed.
            Button { mealPhoto = nil; mealPhotoData = nil } label: {
                FernletIconTile(size: 36, isControl: true) { FernletIcon(.close, scale: 2) }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fernletIconButton("Remove this photo")
            .padding(4)
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
struct RecentMealsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fernletFramedLook) private var look
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
                // b3-recent-meals: every meal a row in one framed card, a small framed Log at its end.
                FernletFramedSection(header: nil, footer: Text("Repeats collapse into one row \u{2014} the most recent time wins.")) {
                    ForEach(store.dedupedRecentMeals) { meal in
                        recentRow(meal)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        }
        .foodSheetBackground()
    }

    /// One recent meal: summary beside the Log pill, unstacking at accessibility sizes.
    @ViewBuilder private func recentRow(_ meal: Meal) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                recentTitle(meal)
                recentDetailLine(meal, includesProtein: false)
                logButton(meal)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    recentTitle(meal)
                    recentDetailLine(meal, includesProtein: true)
                }
                Spacer(minLength: 0)
                logButton(meal)
            }
            .padding(.vertical, 10)
        }
    }

    private func recentTitle(_ meal: Meal) -> some View {
        Text(meal.name)
            .font(look == nil ? .fernlet(.header) : FoodFont.cardTitle)
            .foregroundStyle(look?.text ?? Color.bark)
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
            .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.rowDetail)
            .foregroundStyle(look?.dim ?? Color.slate)
    }

    private func logButton(_ meal: Meal) -> some View {
        Button("Log") { onLog(meal) }
            .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
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

    /// World build (`b3-web-import`, approved 2026-10-24): on the sheet's paper, the search field under
    /// its label, the line saying what happens, the primary Find product page, then a framed card while
    /// the label is read. Pushed in the meal sheet's own stack, so the system bar keeps Back to Log meal
    /// (the foundation's rule for pages pushed inside a sheet).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                urlEntry
                if isLoading {
                    loadingRow
                }
                if let notice {
                    noticeSection(notice)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(WorldPalette.paper)
        .fernletPushedPage("Import product")
        .navigationBarTitleDisplayMode(.inline)
        // Always pushed (the meal sheet's stack), so the page declares its own keyboard Done.
        .keyboardDoneToolbar()
        .sheet(isPresented: $showingProductReview) {
            if let preview {
                FoodProductReviewSheet(
                    preview: preview,
                    product: importedProduct,
                    showCalories: store.settings.showCalories,
                    onSearchAgain: searchAgain,
                    onConfirm: saveConfirmedProduct
                )
                .fernletSheet()
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
        FernletCard {
            HStack(spacing: 10) {
                // The clock is decoration; the status text carries the changing, localized operation.
                WorldSpriteView(sprite: WorldSprites.clock, scale: 2)
                Group {
                    if importedProduct == nil && preview != nil {
                        Text("Reading nutrition label...")
                    } else {
                        Text("Finding product page...")
                    }
                }
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.bark)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The outcome line, with the "log what you typed instead" escape when the web can't help.
    private func noticeSection(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FernletNotice(text: Text(verbatim: notice)) { EmptyView() }
            // When the web lookup can't help, don't strand the user here — let them log
            // what they typed through the normal meal flow instead.
            if let onLogAsTyped {
                Button {
                    onLogAsTyped()
                } label: {
                    HStack(spacing: 8) {
                        WorldSpriteView(sprite: WorldSprites.pen, scale: 2)
                        Text("Log what you typed instead")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
            }
        }
    }

    private var urlEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Product search or page URL")
            // A plain-language placeholder: the example URL rendered as a live blue link inside
            // the empty field, which read as content rather than a hint.
            TextField("Product name or paste a page link", text: $lookupText,
                      prompt: .fieldPrompt("Product name or paste a page link"))
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { loadPreview() }
                .sheetTextInput()
            Text("Search for a specific packaged food or paste its product page. Fernlet will read the nutrition label and show the source and extracted values together before saving.")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
            Group {
                if isLoading {
                    actionButton(label: "Finding page") { loadPreview() }
                } else {
                    actionButton(label: "Find product page") { loadPreview() }
                }
            }
            .disabled(isLoading || lookupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Says what is off and where to turn it on, in that order — the old copy ("Turn off Manual off
    /// mode…") was a double negative naming a mode by a label the user may never have seen.
    private var webNutritionLookupDisabledMessage: String {
        store.settings.aiStatus == .off
            ? String(localized: "productImport.notice.lookupOffWithAI",
                     defaultValue: "Web nutrition lookup is off. Turn on AI features and Web nutrition lookup in Settings to search the web.",
                     comment: "Import product screen: web nutrition lookup is off and AI features are off too. Names the two Settings switches.")
            : String(localized: "productImport.notice.lookupOff",
                     defaultValue: "Web nutrition lookup is off. Turn on Web nutrition lookup in Settings to search the web.",
                     comment: "Import product screen: web nutrition lookup is off. Names the Settings switch that turns it on.")
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

    /// The screen's primary action, full width with the pixel magnifier. `LocalizedStringKey`: as a
    /// `String` its "Find product page" label was drawn verbatim and never reached the catalog.
    private func actionButton(label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                FernletIcon(.search, scale: 2, tint: WorldPalette.onAccent)
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.primary))
        .accessibilityIdentifier("productImport.find")
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
                notice = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "productImport.error.fallback",
                              defaultValue: "Could not import that product page.",
                              comment: "Inline notice when importing a packaged food from a product page fails and the thrown error carries no description of its own.")
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
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(spacing: 0) {
            // b3-product-review: like today, no Cancel; swipe down to leave.
            SheetHeader(title: "Confirm product")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FernletCard {
                        VStack(alignment: .leading, spacing: 10) {
                            detail(label: "Product", value: preview.title)
                            FernletDottedRule()
                            detail(label: "Website", value: preview.sourceName)
                            FernletDottedRule()
                            detail(label: "Source URL", value: preview.sourceURL.absoluteString)
                        }
                    }

                    if let product {
                        nutritionSummary(product)
                    }

                    pageButtons
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Confirm & save product", disabled: product == nil) {
                dismiss()
                onConfirm()
            }
        }
        .foodSheetBackground()
        #if canImport(SafariServices)
        .sheet(isPresented: $showingSafari) {
            if preview.sourceURL.isSafariPresentable {
                SafariView(url: preview.sourceURL)
                    .ignoresSafeArea()
            }
        }
        #endif
    }

    /// Open page (when Safari can show it) and Search again, framed secondaries.
    private var pageButtons: some View {
        VStack(spacing: 10) {
            if preview.sourceURL.isSafariPresentable {
                Button { showingSafari = true } label: {
                    HStack(spacing: 8) {
                        WorldSpriteView(sprite: FoodSprites.globe, scale: 2)
                        Text("Open page")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
            }

            Button {
                dismiss()
                onSearchAgain()
            } label: {
                HStack(spacing: 8) {
                    FernletIcon(.search, scale: 2)
                    Text("Search again")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
        }
    }

    /// One caption-over-value row: the framed section label (uppercased after the lookup), the value.
    private func detail(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(label)
            Text(value)
                .font(look == nil ? .fernlet(.body) : FernletFramedFont.body)
                .foregroundStyle(look?.text ?? Color.bark)
                .fernletWrappingText()
        }
    }

    /// The serving size, the macros as framed tiles with their colours (calories only behind the
    /// opt-in), and the check-before-saving line.
    private func nutritionSummary(_ product: ImportedFoodProduct) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FernletCard {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("SERVING SIZE")
                    Text(product.servingSize)
                        .font(.custom(FernletFontName.dmSansBold, size: 20, relativeTo: .title3))
                        .foregroundStyle(look?.text ?? Color.bark)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            FernletTileGrid {
                FoodProductMacroPill(kind: .protein, title: "Protein", value: "\(product.macros.protein)g")
                FoodProductMacroPill(kind: .carbs, title: "Carbs", value: "\(product.macros.carbs)g")
                FoodProductMacroPill(kind: .fat, title: "Fat", value: "\(product.macros.fat)g")
                if showCalories {
                    FoodProductMacroPill(kind: nil, title: "Calories", value: "\(calories(for: product))")
                }
            }

            Text("Check the serving size and nutrition values before saving. Fernlet will add this product to your local food catalog only after confirmation.")
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                .italic(look == nil)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
    }

    private func calories(for product: ImportedFoodProduct) -> Int {
        product.calories ?? product.macros.calories
    }
}

/// One logged meal's card on Food (`b1-frame-root`, `b2-food-rest`): the photo thumb in an ink frame,
/// the name in Fraunces, the note or component breakdown, the macros as coloured tags with a quiet
/// provenance tag, and the pixel ✕ top right.
///
/// The WHOLE summary is the button: tapping it opens Adjust (FOOD-15). The approved card dropped the
/// drawn "Adjust ›" line, so Adjust is the card's tap, its VoiceOver action ("Adjust meal") and its
/// Voice Control name ("Adjust <meal>"). The provenance tag says it in plain words (Estimated /
/// Reviewed / From recipe) and is absent for seeded demo logs; the ✕ keeps its confirmation. At
/// accessibility sizes the thumbnail drops and the tags wrap, so the name stays whole (4b·AX3).
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
    /// The licence notice for the foods this meal was logged from ("Data from Open Food Facts (ODbL)"),
    /// already localized by the domain model; nil when none carries one (tracker §2.6).
    var dataAttribution: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            HStack(alignment: .top, spacing: 10) {
                // The whole summary opens Adjust; delete stays OUTSIDE the button so the two
                // targets can't nest (a Button inside a Button label never fires).
                Button(action: onCorrect) {
                    summaryContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAction(named: Text("Adjust meal"), onCorrect)
                // Voice Control: the meal's name is what a user says; "Adjust <meal>" kept from the
                // drawn Adjust line the approved card dropped.
                .accessibilityInputLabels([Text(verbatim: meal.name), Text("Adjust \(meal.name)")])
                trailingColumn
            }
        }
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
                Text(meal.name)
                    .font(look == nil ? .fernlet(.header) : FoodFont.cardTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
                if showsMealTypeBadge {
                    Text(verbatim: meal.mealType.displayName)
                        .font(.fernlet(.labelSmall))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(meal.mealType.color.opacity(0.25), in: Capsule())
                }
            }
            displayNote
                .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
            if let dataAttribution {
                Text(verbatim: dataAttribution)
                    .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .accessibilityIdentifier("food.mealRow.attribution")
            }
        }
    }

    /// Calories over the delete ✕ (the pixel ✕ in ink, top right), which keeps its "Remove this
    /// meal?" confirmation.
    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Button(role: .destructive, action: onDelete) {
                // Laid out at the icon's size so the name can run up to it (the approved card), but
                // touched across 44 pt.
                FernletIcon(.close, scale: 2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete meal")
            // Voice Control: every row has this X, so "Delete meal" alone brings up numbers; the
            // meal's name makes each one sayable on its own.
            .accessibilityInputLabels([Text("Delete meal"), Text("Delete \(meal.name)")])
            if showCalories {
                Text("\(meal.calories) cal")
                    .font(look == nil ? .fernlet(.stat) : FernletFramedFont.rowValue)
                    .foregroundStyle(look?.dim ?? Color.bark)
            }
        }
    }

    /// The matched-components breakdown line, when the meal has one: a small note on raised paper.
    private func breakdownCard(_ text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return Text(text)
            .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.note)
            .foregroundStyle(look?.dim ?? Color.slate)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(look?.raised ?? Color.cream.opacity(0.65), in: shape)
            .overlay(shape.strokeBorder(look?.rule ?? Color.bark.opacity(0.08), lineWidth: 1))
    }

    /// The coloured P / C / F tags, then the provenance tag; they wrap rather than drop at the
    /// largest sizes.
    private var macrosRow: some View {
        FlowLayout(spacing: 6) {
            // The tags as the flow's own items: a wrapping row nested in a flow measures as infinitely
            // wide and pushes the provenance tag onto a line of its own.
            FoodMacroTagItems(macros: meal.macros)
            confidenceTag
        }
        .accessibilityElement(children: .combine)
    }

    /// The provenance tag, in plain words (FOOD-02): absent for seeded demo logs, whose provenance
    /// is a demo artifact rather than something the user did.
    @ViewBuilder private var confidenceTag: some View {
        if !isSeededDemoMeal {
            if look != nil {
                FernletTag(text: confidenceTagText)
                    .padding(.vertical, 3)
            } else {
                confidenceTagText
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.slate.opacity(0.10), in: Capsule())
            }
        }
    }

    /// Seeded demo meals carry this exact note (`FernletStore+DemoSeed`); it is the identifying
    /// signal because their confidence token (`logged`) is also a legitimate user stamp. Matched on
    /// the frozen English note, never on what the row draws.
    private var isSeededDemoMeal: Bool {
        meal.note == StoredFoodNote.seededDemoMeal
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
    /// carry components too and used to claim the same thing. Without one, the stored note is drawn,
    /// a note Fernlet wrote in the person's language (``StoredFoodNote``).
    private var displayNote: Text {
        guard breakdownText != nil else {
            return Text(verbatim: StoredFoodNote.displayedMealNote(meal.note))
        }
        switch meal.mealSource {
        case .recipe, .mealDefinition:
            return Text("From your recipe.")
        case .manual:
            return Text("Matched from your foods.")
        }
    }

    private var breakdownText: String? {
        if meal.componentSnapshots.isEmpty == false {
            let text = meal.componentSnapshots
                .map { "\($0.quantity.formatted(.number.precision(.fractionLength(0...1)))) \($0.unit) \($0.name)" }
                .joined(separator: ", ")
            return text.isEmpty ? nil : text
        }
        // A legacy row's breakdown lives in its note; the prefix is the frozen English it was written with.
        let prefix = StoredFoodNote.matchedFromFoodSelectionPrefix
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
/// data. `nonisolated` so review state can be constructed off the main actor. Internal (not private)
/// only so `MealBuilderTests` can pin the re-quantifying rule.
///
/// A component rebuilt from a stored snapshot has only whole grams to scale from. One added fresh
/// from a decimal custom food (``fresh(from:)``) also keeps that food's exact grams at the base
/// quantity (`exactBaseMacros`), so re-quantifying rounds ONCE, by ``FoodItem/scaledMacros(by:)``'s
/// rule: 3 servings of a 3.4 g food save 10 g, as they count in a recipe, never 3 × 3 = 9.
nonisolated struct MealComponentCorrectionInput: Identifiable {
    let id: UUID
    let foodItemId: UUID?
    let name: String
    var quantity: Double
    let unit: String
    let baseQuantity: Double
    let baseMacros: Macros
    let baseMicronutrients: Micronutrients
    let bindScore: Int?
    /// A decimal food's grams at `baseQuantity`, unrounded; `nil` for a stored snapshot or a
    /// whole-gram food, which keep the legacy whole-gram rescale.
    let exactBaseMacros: PreciseMacros?

    init(snapshot: MealComponentSnapshot) {
        self.init(snapshot: snapshot, exactBaseMacros: nil)
    }

    private init(snapshot: MealComponentSnapshot, exactBaseMacros: PreciseMacros?) {
        id = snapshot.id
        foodItemId = snapshot.foodItemId
        name = snapshot.name
        quantity = snapshot.quantity
        unit = snapshot.unit
        baseQuantity = max(snapshot.quantity, 0.01)
        baseMacros = snapshot.macros
        baseMicronutrients = snapshot.micronutrients
        bindScore = snapshot.bindScore
        self.exactBaseMacros = exactBaseMacros
    }

    var snapshot: MealComponentSnapshot {
        let scale = max(quantity, 0) / baseQuantity
        let macros = exactBaseMacros.map { $0.scaledToTenths(by: scale).rounded } ?? baseMacros.scaled(by: scale)
        return MealComponentSnapshot(
            id: id,
            foodItemId: foodItemId,
            name: name,
            quantity: quantity,
            unit: unit,
            macros: macros,
            micronutrients: baseMicronutrients.scaled(by: scale),
            bindScore: bindScore
        )
    }

    /// A fresh input for an item ADDED (or swapped in) during correction (FOOD-05): resolved
    /// through the catalog at the food item's own reference serving. A new item has no captured
    /// meal base to scale from, so its base IS that reference — macros and micronutrients scaled
    /// exactly as `MealBuilder`'s component snapshots are, never invented. A decimal food also
    /// carries its exact grams at that base, so a later quantity change rounds once from them.
    static func fresh(from foodItem: FoodItem) -> MealComponentCorrectionInput? {
        let unit = foodItem.preferredRecipeUnit
        let quantity = foodItem.defaultRecipeQuantity(for: unit)
        let ingredient = RecipeIngredient(foodItemId: foodItem.id, quantity: quantity, unit: unit.rawValue)
        guard let conversion = ingredient.servingConversion(using: foodItem) else { return nil }
        let exactBase = foodItem.hasFractionalMacros ? foodItem.exactMacros.scaled(by: conversion.servingScale) : nil
        let snapshot = MealComponentSnapshot(
            foodItemId: foodItem.id,
            name: foodItem.name,
            quantity: conversion.componentQuantity,
            unit: conversion.componentUnit,
            macros: conversion.scaledMacros(for: foodItem),
            micronutrients: conversion.scaledMicronutrients(for: foodItem)
        )
        return MealComponentCorrectionInput(snapshot: snapshot, exactBaseMacros: exactBase)
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
    /// Research §26 fix 1.10: the search-text → chosen-food pairs this sheet's Replace picks have
    /// produced, held until Save. Held rather than written at the pick because a correction the user
    /// CANCELS out of must teach the app nothing — see ``FoodSearchCorrectionDraft``.
    @State private var correctionDraft = FoodSearchCorrectionDraft()
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
                // b3-meal-adjust draft 2: name, the one meal-type dropdown (as on Log meal and
                // Check this meal), then the macros or the matched items.
                VStack(alignment: .leading, spacing: 18) {
                    FoodSheetField("Meal name") {
                        TextField("Meal", text: $name, prompt: .fieldPrompt("Meal"))
                            .sheetTextInput()
                    }

                    FernletDropdown("Meal type", selection: $mealType, options: MealType.allCases) {
                        Text(verbatim: $0.displayName)
                    }

                    if components.isEmpty {
                        FoodSheetField("Macros") {
                            MealMacroEditorRows(protein: $protein, carbs: $carbs, fat: $fat)
                        }
                    } else {
                        FoodSheetField("Matched items") {
                            MealCorrectionItemsEditor(
                                components: $components,
                                correctionDraft: $correctionDraft,
                                lowConfidenceComponentIDs: lowConfidenceComponentIDs,
                                catalog: store.foodCatalog,
                                onSaveCustomIngredient: { store.saveCustomIngredient($0) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
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
                // Fix 1.10, after the correction is committed: the searches this save corrected are
                // remembered on THIS device only, so the same search answers with the user's own pick
                // first next time. A no-op when nothing was replaced.
                store.rememberFoodSearchCorrections(correctionDraft.corrections)
                dismiss()
            }
        }
        .foodSheetBackground()
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
    /// The captured bind score is the only confidence signal used here. Missing scores are
    /// intentionally reviewable: a legacy, manual, or invalid snapshot cannot masquerade as a
    /// confident automatic match.
    private static func lowConfidenceComponentIDs(for meal: Meal) -> Set<UUID> {
        Set(meal.componentSnapshots.compactMap { component in
            component.hasConfidentBind ? nil : component.id
        })
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
    /// Research §26 fix 1.10: the corrections this sheet has made, recorded here at each Replace pick
    /// and written by the owning sheet's Save (never here — see ``MealCorrectionSheet``).
    @Binding var correctionDraft: FoodSearchCorrectionDraft
    /// Ids outlined in sun with the Replace affordance (decided at open by the owning sheet).
    let lowConfidenceComponentIDs: Set<UUID>
    var catalog: FoodCatalog
    /// Persists a custom food through the store's one de-duplicating upsert seam.
    var onSaveCustomIngredient: (ManualRecipeIngredientInput) -> FoodItem?
    /// True while the "Add an item" typeahead is revealed (mutually exclusive with Replace).
    @State private var isAddingItem = false
    /// The component whose Replace typeahead is open, if any.
    @State private var replacingComponentID: UUID?
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        // b3-meal-adjust draft 2: each item its own framed card (gold when it looks wrong), then
        // "+ Add an item" as a framed button, then the new total as coloured tags.
        VStack(alignment: .leading, spacing: 12) {
            ForEach($components) { $component in
                componentCard($component)
            }
            addItemSection
            FoodMacroTotalRow(title: "New total", macros: newTotal)
        }
    }

    /// One matched item: the shared card, then the low-confidence notice and Replace typeahead when
    /// flagged, and the labelled remove.
    private func componentCard(_ component: Binding<MealComponentCorrectionInput>) -> some View {
        let item = component.wrappedValue
        let isLowConfidence = lowConfidenceComponentIDs.contains(item.id)
        return FoodMatchedItemCard(component: component, isLowConfidence: isLowConfidence) {
            HStack(spacing: 12) {
                if isLowConfidence { lowConfidenceNotice(item) }
                Spacer(minLength: 0)
                removeButton(item)
            }
            if replacingComponentID == item.id {
                replaceField(for: item)
            }
        }
    }

    /// The total the list adds up to, through `MealBuilder.totals`: always what Save would persist.
    private var newTotal: Macros {
        let totals = MealBuilder.totals(for: components.map(\.snapshot))
        return Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat)
    }

    /// "Probably not what you meant" in words beside the Replace affordance — a bad match can be
    /// replaced rather than deleted-and-re-logged.
    private func lowConfidenceNotice(_ component: MealComponentCorrectionInput) -> some View {
        HStack(spacing: 12) {
            Text("Probably not what you meant")
                .font(FoodFont.noteStrong)
                .foregroundStyle(Color.goldenrodInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Replace") {
                replacingComponentID = replacingComponentID == component.id ? nil : component.id
                isAddingItem = false
            }
            .buttonStyle(.plain)
            .font(FernletFramedFont.button)
            .foregroundStyle(look?.link ?? Color.moss)
            .fernletTapTarget()
        }
    }

    /// The Replace typeahead, prefilled with the suspect match's name. A pick swaps the item for
    /// a FRESH catalog resolution (`MealComponentCorrectionInput.fresh`) and records the correction
    /// (fix 1.10) for the owning sheet to save.
    private func replaceField(for component: MealComponentCorrectionInput) -> some View {
        MealItemSearchField(
            catalog: catalog,
            prompt: "Search the catalog",
            initialText: component.name,
            onCreate: onSaveCustomIngredient
        ) { foodItem, searchText in
            if let index = components.firstIndex(where: { $0.id == component.id }),
               let fresh = MealComponentCorrectionInput.fresh(from: foodItem) {
                components[index] = fresh
            }
            correctionDraft.record(searchText: searchText, prefilledWith: component.name, foodItemID: foodItem.id)
            replacingComponentID = nil
        }
    }

    /// The labelled per-item remove (FOOD-05) — a word in the destructive ink, not a bare x.
    private func removeButton(_ component: MealComponentCorrectionInput) -> some View {
        Button {
            components.removeAll { $0.id == component.id }
        } label: {
            Text("Remove")
                .font(look == nil ? .fernlet(.label) : FernletFramedFont.button)
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
            HStack(spacing: 8) {
                FernletIcon(.plus, scale: 2)
                Text("Add an item")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
        if isAddingItem {
            // Deliberately NOT a fix-1.10 write site: adding an item is not correcting a wrong match,
            // and §26 scopes the correction memory to the Replace path. The pick's query is ignored here.
            MealItemSearchField(
                catalog: catalog,
                prompt: "sourdough toast",
                initialText: "",
                onCreate: onSaveCustomIngredient
            ) { foodItem, _ in
                if let fresh = MealComponentCorrectionInput.fresh(from: foodItem) {
                    components.append(fresh)
                    isAddingItem = false
                }
            }
        }
    }
}

/// The debounced catalog typeahead field used by Adjust meal's Replace and "Add an item" paths —
/// the recipe editor's search mechanics (``CatalogTypeahead``) and suggestion rows
/// (``CatalogSuggestionRow``), reusable outside the ingredient editor's binding model.
///
/// Picks hand back the raw `FoodItem` AND the text that was in the field when it was picked; the
/// owner decides what to build from either. (The query rides along for research §26 fix 1.10's
/// correction memory, whose key is what the user searched — a caller that does not learn from picks
/// ignores it.) The query never runs in `body` — the `.task(id:)` keystroke cancellation is what
/// keeps stale results out.
private struct MealItemSearchField: View {
    var catalog: FoodCatalog
    /// The field's placeholder (authored copy).
    var prompt: LocalizedStringKey
    /// Seed text — the suspect match's name on the Replace path, empty for Add.
    var initialText: String
    /// Persists the custom-food escape through the same upsert as recipe ingredients.
    var onCreate: (ManualRecipeIngredientInput) -> FoodItem?
    /// Fires with the picked food and the field's text at the moment of the pick.
    var onPick: (FoodItem, String) -> Void
    @State private var searchText: String
    @State private var typeaheadResults = CatalogTypeaheadResultSet()
    @State private var isCreatingCustomFood = false

    init(
        catalog: FoodCatalog,
        prompt: LocalizedStringKey,
        initialText: String,
        onCreate: @escaping (ManualRecipeIngredientInput) -> FoodItem?,
        onPick: @escaping (FoodItem, String) -> Void
    ) {
        self.catalog = catalog
        self.prompt = prompt
        self.initialText = initialText
        self.onCreate = onCreate
        self.onPick = onPick
        _searchText = State(initialValue: initialText)
    }

    var body: some View {
        let visibleMatches = typeaheadResults.visibleMatches(for: searchText)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                FernletIcon(.search, scale: 2)
                TextField(prompt, text: $searchText, prompt: .fieldPrompt(prompt))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.none)
                    .sheetTextInput()
                    .accessibilityIdentifier("mealCorrection.catalogSearch")
            }
            if !visibleMatches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(visibleMatches) { foodItem in
                        FernletDottedRule()
                        FoodCatalogMatchRow(foodItem: foodItem) {
                            guard let current = typeaheadResults.selectable(foodItem, for: searchText) else { return }
                            // B6: a typeahead row picked is a choice made, felt like a chip.
                            FernletFeedback.system.play(.tick)
                            onPick(current, searchText)
                        }
                    }
                }
                .accessibilityIdentifier("mealCorrection.catalogResults")
            }
            if showsSettledMiss && !isCreatingCustomFood {
                FernletNotice("No catalog matches.") { FernletIcon(.search, scale: 2) }
                Button { isCreatingCustomFood = true } label: {
                    HStack(spacing: 8) {
                        FernletIcon(.plus, scale: 2)
                        Text("Create custom food")
                    }
                }
                .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                .accessibilityIdentifier("catalogSearch.empty")
            }
            if isCreatingCustomFood {
                CatalogCustomFoodEditor(name: trimmedQuery, onSave: onCreate) { foodItem in
                    onPick(foodItem, searchText)
                }
            }
        }
        .onChange(of: searchText) { _, _ in
            typeaheadResults.clear()
            isCreatingCustomFood = false
        }
        // One settled-keystroke query at a time, off the main actor — the same contract as the
        // recipe editor's typeahead (see `CatalogTypeahead.matches`).
        .task(id: searchText) {
            let query = trimmedQuery
            guard !query.isEmpty else {
                typeaheadResults.clear()
                return
            }
            // Adjust meal corrects a logged meal: the standard order (F5 is recipes only).
            guard let hits = await CatalogTypeahead.matches(for: query, catalog: catalog, ranking: .standard) else { return }
            typeaheadResults.bind(hits, to: query)
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsSettledMiss: Bool {
        typeaheadResults.isSettled(for: searchText)
            && typeaheadResults.visibleMatches(for: searchText).isEmpty
    }
}

/// The existing custom-ingredient plausibility policy reduced to the editor's save-or-review choice.
nonisolated enum CatalogCustomFoodSaveGate {
    /// Either persists immediately or requires the existing plausibility review before persistence.
    enum Decision: Equatable {
        case save
        case review(NutritionPlausibilityReport)
    }

    static func decision(for input: ManualRecipeIngredientInput) -> Decision {
        let report = CustomIngredientUpsert.plausibility(of: input)
        return report.needsReview ? .review(report) : .save
    }
}

/// Inline custom-food editor shown only after an Adjust-meal catalog miss.
///
/// It captures the three values the existing custom-ingredient model can represent and persists
/// through the injected store seam. Growth is fixed: three bounded fields and one save action.
private struct CatalogCustomFoodEditor: View {
    var name: String
    var onSave: (ManualRecipeIngredientInput) -> FoodItem?
    var onCreated: (FoodItem) -> Void
    // Grams, to a tenth: a custom food is an ingredient, and "3.4 g" is a value a label prints.
    @State private var protein = 0.0
    @State private var carbs = 0.0
    @State private var fat = 0.0
    @State private var showingPlausibilityReview = false
    @State private var pendingReviewInput: ManualRecipeIngredientInput?
    @State private var reviewReport = NutritionPlausibilityReport.clean

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add macros for this custom food.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(Color.slate)
                // Decimal grams to a tenth: today's shared ingredient rows (a label prints "3.4 g").
                MacroInputRow(label: "Protein", unit: "g", value: $protein, range: 0.0...300.0)
                MacroInputRow(label: "Carbs", unit: "g", value: $carbs, range: 0.0...500.0)
                MacroInputRow(label: "Fat", unit: "g", value: $fat, range: 0.0...300.0)
                Button("Save custom food", action: attemptSave)
                    .buttonStyle(ActionPillButtonStyle(.primary, size: .small))
                    .disabled(!canSave)
                    .accessibilityIdentifier("catalogSearch.saveCustomFood")
            }
        }
        .confirmationDialog(
            reviewTitle,
            isPresented: $showingPlausibilityReview,
            titleVisibility: .visible
        ) {
            Button("Save anyway", action: savePendingReview)
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text(verbatim: reviewMessage)
        }
    }

    private var canSave: Bool {
        !name.isEmpty && (protein > 0 || carbs > 0 || fat > 0)
    }

    private func attemptSave() {
        guard canSave else { return }
        let input = currentInput
        switch CatalogCustomFoodSaveGate.decision(for: input) {
        case .save:
            persist(input)
        case .review(let report):
            pendingReviewInput = input
            reviewReport = report
            showingPlausibilityReview = true
        }
    }

    private var currentInput: ManualRecipeIngredientInput {
        ManualRecipeIngredientInput(
            name: name,
            quantity: 1,
            unit: RecipeUnit.serving.rawValue,
            protein: protein,
            carbs: carbs,
            fat: fat
        )
    }

    private var reviewFindings: [NutritionPlausibilityFinding] {
        reviewReport.contradictions.isEmpty ? reviewReport.advisories : reviewReport.contradictions
    }

    private var reviewTitle: LocalizedStringKey {
        reviewReport.contradictions.isEmpty ? "Worth a second look" : "These numbers don't add up"
    }

    private var reviewMessage: String {
        NutritionPlausibilityReport.message(for: reviewFindings, limit: 3) ?? ""
    }

    private func savePendingReview() {
        guard let input = pendingReviewInput else { return }
        persist(input)
    }

    private func persist(_ input: ManualRecipeIngredientInput) {
        guard let foodItem = onSave(input) else { return }
        pendingReviewInput = nil
        onCreated(foodItem)
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
        // b3-meal-macros draft 2: one framed card, each macro its coloured square, the tappable
        // amount and a framed − + stepper. Protein 0–300 g, carbs 0–500 g, fat 0–300 g, steps of 1.
        FernletCard {
            VStack(spacing: 12) {
                FoodMacroAmountRow(kind: .protein, grams: $protein, range: 0...300)
                FoodMacroAmountRow(kind: .carbs, grams: $carbs, range: 0...500)
                FoodMacroAmountRow(kind: .fat, grams: $fat, range: 0...300)
            }
        }
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
        // b3-meal-review draft 2: each item its own framed card (the matched items the owner liked),
        // then the total as coloured tags.
        VStack(alignment: .leading, spacing: 12) {
            ForEach($components) { $component in
                FoodMatchedItemCard(component: $component) { EmptyView() }
            }
            FoodMacroTotalRow(title: "Total", macros: componentMacros)
        }
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
/// Each resolved meal is editable in place (name, type, macros or component quantities), and every
/// recipe the resolution offers — the decomposition tier's suggested recipe and the plan tiers' recipes
/// for multi-ingredient items — is shown with a switch and an editable name and yield
/// (``MealReviewRecipeOffer``). On "Log meal" the reviewed meals plus the recipes still switched on are
/// handed back through `onConfirm`, so the caller commits both through the same `commitResolution`
/// path — a recipe is minted only on this confirm, never at resolve time. `isLogging` one-shots the
/// button so a fast double-tap can't log the meal twice.
struct MealReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    private let confidence: MealResolutionConfidence
    /// The recipes the person kept (empty when they switched every offer off) are passed back
    /// alongside the reviewed meals so the caller can persist them through the SAME
    /// `commitResolution`/`diary.recipes` path — minting happens only on this confirm.
    var onConfirm: ([Meal], [RecipeDefinition]) -> Void
    var onDiscard: () -> Void
    /// Items the user typed that the resolver bound nothing to (`MealResolution.unmatchedItems`).
    /// Named on screen so a dropped ingredient is visible before the meal is logged, not discovered
    /// afterwards by reading the row.
    private let unmatchedItems: [String]
    @State private var meals: [EditableReviewMeal]
    /// One-shot guard so a fast double-tap on "Log meal" can't fire onConfirm twice — which would
    /// append the same meal id twice and double its macros.
    @State private var isLogging = false
    /// Every recipe the resolution offers, with the person's choices; empty when it offers none.
    @State private var recipeOffers: [MealReviewRecipeOffer]
    /// Whether the rough estimate's full sentence shows under the one-line note (the pixel ⓘ).
    @State private var showsFullNote = false
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        resolution: MealResolution,
        store: FernletStore,
        onConfirm: @escaping ([Meal], [RecipeDefinition]) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.store = store
        self.confidence = resolution.confidence
        self.unmatchedItems = resolution.unmatchedItems
        self.onConfirm = onConfirm
        self.onDiscard = onDiscard
        _meals = State(initialValue: resolution.meals.map(EditableReviewMeal.init(base:)))
        _recipeOffers = State(initialValue: MealReviewRecipeOffer.offers(for: resolution))
    }

    /// The recipes to mint: every offer still switched on, rebuilt from the reviewed component grams
    /// with the person's name and yield (``MealReviewRecipeOffer/confirmedRecipe(reviewedComponents:)``).
    private var confirmedRecipes: [RecipeDefinition] {
        let reviewedComponents = meals.flatMap(\.components)
        return recipeOffers.compactMap { $0.confirmedRecipe(reviewedComponents: reviewedComponents) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // b3-meal-review draft 2: Discard top left (it's the way back), the title inside the
            // sheet, then Fernlet's note on one line.
            SheetHeader(title: Text("Check this meal")) { discardButton }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    noteLine
                    unmatchedItemsCard
                    ForEach($meals) { $meal in
                        reviewedMealFields($meal)
                    }
                    if !recipeOffers.isEmpty {
                        recipeOfferSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Log meal", disabled: isLogging) {
                guard !isLogging else { return }
                isLogging = true
                onConfirm(meals.map(\.applied), confirmedRecipes)
            }
        }
        .foodSheetBackground()
        // The keyboard "Done" for the Qty and macro pads, which have no return key. This sheet is
        // presented by the meal sheet's root page, and a sheet is a host of its own: that page's
        // Done never reaches it, so its root declares one.
        .keyboardDoneToolbar()
    }

    /// Discard, in the header's leading slot (Cancel's place): leaves the log sheet open with the
    /// original text so the person can adjust and retry. Escape presses it too.
    private var discardButton: some View {
        Button("Discard", action: onDiscard)
            .buttonStyle(.plain)
            .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
            .foregroundStyle(look?.dim ?? Color.slate)
            .fernletTapTarget()
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("mealReview.discard")
    }

    /// Fernlet's note in one line (draft 2, "the subheader needs work"): for a rough estimate the gold
    /// tag and "Check the items before logging.", with a pixel ⓘ that shows the full sentence;
    /// otherwise the sentence itself, which is short.
    @ViewBuilder private var noteLine: some View {
        if confidence == .low {
            // The tag stacks above the line at the largest sizes, so neither breaks mid-word.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
            VStack(alignment: .leading, spacing: 8) {
                layout {
                    FernletTag("Rough estimate", fill: Self.estimateGold)
                        .fixedSize()
                    HStack(alignment: .center, spacing: 8) {
                        Text("Check the items before logging.")
                            .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.note)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .fixedSize(horizontal: false, vertical: true)
                            // One line while it fits: the line takes its width before the spacer.
                            .layoutPriority(1)
                        infoButton
                        Spacer(minLength: 0)
                    }
                }
                if showsFullNote { fullNote }
            }
        } else {
            fullNote
        }
    }

    /// The kit's gold tag fill (`.ptag.gold`); its word stays dark ink in both modes.
    private static let estimateGold = WorldPalette.rgb(0xF2D58A)

    private var fullNote: some View {
        Text(reviewMessage)
            .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
            .foregroundStyle(look?.dim ?? Color.slate)
            .fernletWrappingText()
    }

    /// The pixel ⓘ: shows or hides the full sentence under the line.
    private var infoButton: some View {
        Button { withAnimation(FernletMotion.ui) { showsFullNote.toggle() } } label: {
            WorldSpriteView(sprite: FoodSprites.info, scale: 2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About this estimate")
        .accessibilityValue(showsFullNote ? Text(reviewMessage) : Text(verbatim: ""))
    }

    /// One reviewed meal: its name, the meal-type dropdown, then its macros or matched items.
    @ViewBuilder private func reviewedMealFields(_ meal: Binding<EditableReviewMeal>) -> some View {
        FoodSheetField("Meal name") {
            TextField("Meal", text: meal.name, prompt: .fieldPrompt("Meal"))
                .sheetTextInput()
                .accessibilityLabel("Meal name")
        }
        FernletDropdown("Meal type", selection: meal.mealType, options: MealType.allCases) {
            Text(verbatim: $0.displayName)
        }
        if meal.wrappedValue.components.isEmpty {
            FoodSheetField("Macros") {
                MealMacroEditorRows(protein: meal.protein, carbs: meal.carbs, fat: meal.fat)
            }
        } else {
            FoodSheetField("Matched items") {
                MealComponentEditorRows(components: meal.components)
            }
        }
    }

    /// Offers each recipe the resolution built for saving to the recipe book: an opt-out toggle plus an
    /// editable name and yield per recipe, the built name above each when there is more than one. Nothing
    /// here is persisted until the user taps "Log meal" (the offers are carried back through
    /// `confirmedRecipes`), so declining or editing costs nothing.
    @ViewBuilder private var recipeOfferSection: some View {
        ForEach($recipeOffers) { $offer in
            FernletCard {
                VStack(alignment: .leading, spacing: 14) {
                    if recipeOffers.count > 1 {
                        Text(verbatim: offer.base.name)
                            .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.note)
                            .foregroundStyle(look?.dim ?? Color.slate)
                    }
                    Toggle(isOn: $offer.isSaved) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save as a recipe")
                                .font(look == nil ? .fernlet(.label) : FoodFont.rowName)
                                .foregroundStyle(look?.text ?? Color.bark)
                            Text("Keep this in your recipe book to log again later.")
                                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.note)
                                .foregroundStyle(look?.dim ?? Color.slate)
                                .fernletWrappingText()
                        }
                    }
                    .tint(Color.moss)
                    .accessibilityIdentifier("mealReview.saveAsRecipe")

                    if offer.isSaved {
                        recipeOfferFields($offer)
                    }
                }
            }
        }
    }

    /// The name and yield of one offer the person is keeping.
    @ViewBuilder private func recipeOfferFields(_ offer: Binding<MealReviewRecipeOffer>) -> some View {
        FoodSheetField("Recipe name") {
            TextField("Recipe", text: offer.name, prompt: .fieldPrompt("Recipe"))
                .sheetTextInput()
                .accessibilityIdentifier("mealReview.recipeName")
        }
        FoodSheetField("Makes") {
            HStack {
                // Grammar agreement, not a spliced English "s" (see `RecipeRow`).
                Text("^[\(offer.wrappedValue.servings) serving](inflect: true)")
                    .font(look == nil ? .fernlet(.body) : FernletFramedFont.rowTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                Spacer(minLength: 8)
                FernletStepper("Makes", value: offer.servings, in: 1...24, step: 1)
                    .accessibilityValue(Text("^[\(offer.wrappedValue.servings) serving](inflect: true)"))
                    .accessibilityIdentifier("mealReview.recipeServings")
            }
        }
    }

    /// Names the words nothing was found for, as chips, above the meal being reviewed. Nothing is
    /// guessed on the user's behalf: the meal logs without them unless the user adds the nutrition
    /// themselves below (or backs out and rewords).
    @ViewBuilder private var unmatchedItemsCard: some View {
        if !unmatchedItems.isEmpty {
            let shape = RoundedRectangle(cornerRadius: 10)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Couldn't find")
                FlowLayout(spacing: 8) {
                    ForEach(unmatchedItems, id: \.self) { item in
                        FernletTag(text: Text(verbatim: item), fill: Self.estimateGold)
                    }
                }
                Text("These words weren't matched to a food, so they aren't counted below. Check the matched items or adjust the numbers before logging.")
                    .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.note)
                    .foregroundStyle(look?.text ?? Color.slate)
                    .fernletWrappingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            // The "Couldn't find" card (kept from today): the warning notice's paper in an ink frame.
            .background(look?.warn ?? Color.goldenrod.opacity(0.10), in: shape)
            .overlay { if let look { shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth) } }
            .accessibilityIdentifier("mealReview.unmatchedItems")
        }
    }

    /// The line under the title. `LocalizedStringKey`: as a `String` it was drawn verbatim.
    private var reviewMessage: LocalizedStringKey {
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
    @Environment(\.fernletFramedLook) private var look

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
                    .accessibilityIgnoresInvertColors()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if presence == .onOtherDevice {
                // Photo taken on another device; day data synced here, the bytes didn't. A quiet,
                // deliberate glyph rather than the same "no photo yet" fork-and-knife.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cream)
                    .frame(width: 54, height: 54)
                    .overlay(Image(systemName: "iphone.and.arrow.forward").font(.caption).foregroundStyle(Color.slate))
                    .accessibilityLabel("Photo on your other device")
            } else if presence == .unavailable {
                // The sealed file is here but wouldn't open (corrupt / undecryptable) — a distinct,
                // honest glyph rather than claiming it lives on another device.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cream)
                    .frame(width: 54, height: 54)
                    .overlay(Image(systemName: "photo.badge.exclamationmark").font(.caption).foregroundStyle(Color.slate))
                    .accessibilityLabel("Photo couldn't be opened")
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cream)
                    .frame(width: 54, height: 54)
                    .overlay(Image(systemName: "fork.knife").font(.caption).foregroundStyle(Color.slate))
            }
        }
        // The World card's thumb sits in a 2-pt ink frame (b1-frame-root).
        .overlay { if let look { RoundedRectangle(cornerRadius: 8).strokeBorder(look.ink, lineWidth: 2) } }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // `.headerMedium` (20pt), a step down from the 24pt `.header` that `MealRow` uses above
                // this section. Deliberate hierarchy rather than an inconsistency: meals are the log,
                // recipes are a shortcut list beneath it.
                Text(recipe.name)
                    .font(.fernlet(.headerMedium))
                Spacer()
                // Automatic grammar agreement. These spliced an English "s" in by count, which no
                // translation can follow.
                Text("^[\(recipe.servings) serving](inflect: true)")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.slate)
            }
            Text("^[\(recipe.ingredients.count) ingredient](inflect: true)")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.slate)
            if !recipe.notes.isEmpty {
                Text(verbatim: StoredFoodNote.displayedRecipeNotes(recipe.notes))
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    // A two-line preview, except at accessibility sizes, where two lines held only
                    // the first few words.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
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
/// The World build draws it as ONE page (`b2-recipe-detail` draft 3 on top, `b3-recipe-notes` draft 2
/// at the bottom, approved 2026-10-24): the photo slot and name, "Each serving gives", the compact
/// ingredient rows with Cook for, the wooden Start cooking, Log it / Share / Edit, the steps, the notes
/// (edited in place; the separate notes sheet is gone) and where a web recipe came from with its
/// Re-import. Pushed in a panel, it hands "Recipe" to the wooden plate. The pieces are in
/// `World/Recipes/RecipePageSections.swift`.
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
    /// definition like `onLog`, and returns the meal it logged (`nil` when the recipe built none),
    /// which this view hands to ``onMealsLogged`` once the cooking cover has gone. A no-op default
    /// keeps any non-updated call site compiling; the real sites wire it.
    var onCookLog: (RecipeDefinition, MealType, String) -> Meal? = { _, _, _ in nil }
    /// Where the finished cook's meal is reported, with the day it was logged to (the day the cook
    /// began, which can be yesterday). Released from the cooking cover's `onDismiss`, so the toast
    /// shows over the page the cover uncovers, not behind the closing cover.
    var onMealsLogged: MealLogReporter = .none

    /// Creates the detail. Mirrors the old memberwise init exactly (same labels, same defaults) —
    /// it exists only because `initialRecipe` is private, which hides the memberwise init.
    init(
        store: FernletStore,
        recipe: RecipeDefinition,
        onEdit: @escaping () -> Void,
        onSaveFork: @escaping (RecipeDefinition) -> Void = { _ in },
        onLog: @escaping (RecipeDefinition, MealType) -> Void,
        onShare: @escaping (RecipeDefinition) -> Void,
        onCookLog: @escaping (RecipeDefinition, MealType, String) -> Meal? = { _, _, _ in nil },
        onMealsLogged: MealLogReporter = .none
    ) {
        self.store = store
        self.initialRecipe = recipe
        self.onEdit = onEdit
        self.onSaveFork = onSaveFork
        self.onLog = onLog
        self.onShare = onShare
        self.onCookLog = onCookLog
        self.onMealsLogged = onMealsLogged
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
    /// The meal the cook's finish screen logged, held until the cover has gone (``CookedMealHandoff``).
    @State private var cookedMeal = CookedMealHandoff()

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

    /// One page (`b2-recipe-detail` draft 3 on top, `b3-recipe-notes` draft 2 at the bottom, approved
    /// 2026-10-24): the photo and name, what a serving gives, the ingredients with Cook for, the
    /// wooden Start cooking, Log it / Share / Edit, then the steps, the notes and where it came from.
    private var detailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                noticeLines
                headerCard
                macrosCard
                ingredientsCard
                if CookingModeAvailability.canCook(recipe) { cookButton }
                RecipePageActions(onLog: { onLog(recipe, $0) }, onShare: { onShare(recipe) }, onEdit: onEdit)
                stepsCard
                RecipeNotesCard(notes: StoredFoodNote.displayedRecipeNotes(recipe.notes), onSave: saveNotes)
                sourceCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .fernletPageBackground()
        .fernletPushedPage("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        // A6: a recipe photo that couldn't be sealed is a failure the person should feel, not only
        // read in the italic notice line.
        .fernletFeedback(.failed, trigger: photoNotice) { _, notice in notice != nil }
        // Warm the DNS/TLS connection to the source host while the detail is up, so the source
        // link opens near-instantly (owner decision 2026-08-09; documented in
        // Docs/No-Tracking-Wall.md §4b).
        .prewarmsSourceLinkConnection(for: recipe.webImport)
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
            FernletNotice(text: Text(verbatim: photoNotice), tone: .warn) { EmptyView() }
        }
        if let reimportNotice {
            FernletNotice(text: Text(verbatim: reimportNotice)) { WorldSpriteView(sprite: WorldSprites.clock, scale: 2) }
        }
    }

    /// The photo slot beside the name and its yield (`b2-recipe-detail`).
    private var headerCard: some View {
        RecipePageHeaderCard(name: recipe.name, yieldLine: Text("^[\(recipe.servings) serving](inflect: true)")) {
            RecipePhotoSlot(photo: photo, onCamera: { save($0) }, onLibraryData: { saveLibraryData($0) },
                            onLibraryFailed: { photoNotice = Self.photoNotSavedNotice },
                            onDelete: { confirmRemovePhoto() })
        }
    }

    /// Where a web recipe came from, with the explicit refresh (owner decision 2026-08-09): repeat
    /// imports of the same URL skip the network and surface the saved recipe, so Re-import is the one
    /// way to re-fetch the page. Photo and notes are preserved (same-id replace — see
    /// `FernletStore.reimportSavedRecipeFromSource`). It sat in the navigation bar, which the World
    /// plate replaces, so it lives with the source now.
    @ViewBuilder private var sourceCard: some View {
        if let sourceURL = recipe.webImport?.sourceURL {
            let presentable = sourceURL.isSafariPresentable
            RecipeSourceCard(url: sourceURL, isReimporting: isReimporting,
                             onOpen: { if presentable { showingSafari = true } },
                             onReimport: presentable ? { confirmReimportFromSource() } : nil)
        }
    }

    /// Saves the Notes card's text: the stored English when the person left a seeded note as drawn,
    /// else what they typed (``StoredFoodNote/savedRecipeNotes(editing:stored:)``).
    private func saveNotes(_ typed: String) {
        let notes = StoredFoodNote.savedRecipeNotes(editing: typed, stored: recipe.notes)
        store.updateRecipeNotes(notes, forRecipeID: recipe.id)
        reimportedRecipe?.notes = notes
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
                .fernletSheet()
            }
            .fullScreenCover(isPresented: $showingCookingMode, onDismiss: { cookedMeal.release(to: onMealsLogged) }) {
                // Carry the detail page's ephemeral "Cook for N" into cooking mode so mise opens at that
                // yield instead of re-defaulting to the base (nil → base yield inside CookingModeView).
                // The completion log routes through onCookLog with the definition on screen at cook
                // start, mirroring onLog's currency rule; its meal reaches the toast from `onDismiss`.
                CookingModeView(store: store, recipe: recipe, initialYield: cookYield, onLogToDay: { mealType, day in
                    cookedMeal.hold(onCookLog(recipe, mealType, day), loggedTo: day)
                })
            }
    }

    /// "Each serving gives" (`b2-recipe-detail`): per serving stays pinned to the base recipe while
    /// the whole-recipe line follows Cook for.
    private var macrosCard: some View {
        RecipeServingCard(
            perServing: perServing,
            showsCalories: store.settings.showCalories,
            totalsLine: totalsLine,
            estimateNote: WebImportEstimateNote(
                uncountedLines: recipe.webImport?.uncountedIngredientLines,
                estimatedLines: recipe.webImport?.estimatedIngredientLines
            )
        )
    }

    /// "Makes 4 servings: P 40g · C 120g · F 30g", with calories only behind the opt-in. Two whole
    /// keys: the calorie tail used to be an English string spliced into the key, and the servings an
    /// English plural picked by count.
    private var totalsLine: Text {
        let totals = displayTotals
        guard store.settings.showCalories else {
            return Text("Makes ^[\(effectiveYield) serving](inflect: true): P \(totals.protein)g · C \(totals.carbs)g · F \(totals.fat)g")
        }
        return Text("Makes ^[\(effectiveYield) serving](inflect: true): P \(totals.protein)g · C \(totals.carbs)g · F \(totals.fat)g · \(totals.calories) cal")
    }

    /// Ephemeral "cook for N" control (F4, §11.4), in the Ingredients card's header
    /// (`b2-recipe-detail`). Shown only for structured recipes — web imports have free-text
    /// ingredient lines with no quantities to rescale, so faking a scale would be a lie. Everything
    /// here is view state: nothing is written to the store, and leaving the page discards it.
    private var cookForStepper: some View {
        HStack(spacing: 8) {
            Text("Cook for")
                .font(FernletFramedFont.rowTitleBold)
                .foregroundStyle(WorldPalette.bark)
                .accessibilityHidden(true)
            FernletStepper("Cook for", value: Binding(get: { effectiveYield }, set: { cookYield = $0 }),
                           in: RecipeScaling.yieldRange, step: 1, display: Text("\(effectiveYield)"))
                .accessibilityIdentifier("recipeDetail.cookForYield")
        }
        // Its ideal width, never squeezed: where the label and the stepper don't fit beside
        // "Ingredients", the card's header stacks them instead (a squeezed "Cook for" broke per letter).
        .fixedSize()
    }

    /// The scaled-view note and its reset, under the ingredients while Cook for differs from the
    /// recipe's own yield; for a web import, why there is no Cook for.
    @ViewBuilder private var yieldNote: some View {
        if isScaled {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scaled from ^[\(recipe.servings) serving](inflect: true) for this view only — your saved recipe is unchanged, and logging still records one serving.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                Button { cookYield = nil } label: {
                    Text("Reset to ^[\(recipe.servings) serving](inflect: true)")
                }
                .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                .accessibilityIdentifier("recipeDetail.cookForReset")
            }
        } else if recipe.webImport != nil {
            Text("Scaling isn't available for imported recipes — their ingredient amounts are free text.")
                .font(FernletFramedFont.note)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
        }
    }

    /// The Ingredients card: its label and Cook for on top, then one compact row per ingredient
    /// (`b2-recipe-detail` draft 3: a 30-ingredient recipe is a list you scroll).
    private var ingredientsCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        SectionLabel("Ingredients")
                        Spacer(minLength: 8)
                        if RecipeScaling.isScalable(recipe) { cookForStepper }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Ingredients")
                        if RecipeScaling.isScalable(recipe) { cookForStepper }
                    }
                }
                ingredientRows
                yieldNote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var ingredientRows: some View {
        if let webImport = recipe.webImport {
            webImportIngredientRows(webImport)
        } else if recipe.ingredients.isEmpty {
            Text("No ingredients listed.")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
        } else if recipe.isMultipart {
            RecipePartsIngredientList(parts: RecipePartsLayout.parts(of: recipe, displaying: displayIngredients)) {
                structuredIngredientRow($0)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayIngredients) { ingredient in
                    structuredIngredientRow(ingredient)
                }
            }
        }
    }

    /// Web imports keep free-text ingredient lines (no structured food-item resolution): each line is
    /// a compact row whose icon is chosen from its words, with no separate amount.
    @ViewBuilder private func webImportIngredientRows(_ webImport: RecipeWebImport) -> some View {
        if webImport.ingredientLines.isEmpty {
            Text("No ingredients listed.")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(webImport.ingredientLines, id: \.self) { line in
                    RecipeIngredientRow(name: line, amount: "")
                }
            }
        }
    }

    /// One resolved ingredient: its icon, name and amount, the typical-size note, and the Swap
    /// affordance for structured (scalable) recipes.
    private func structuredIngredientRow(_ ingredient: RecipeIngredient) -> some View {
        let name = resolvedItems[ingredient.foodItemId]?.name
        return RecipeIngredientRow(
            name: RecipeIngredientLine.displayName(name),
            amount: ingredient.amountText,
            artName: name,
            // A household amount read from the curated typical-size table stays marked as an
            // estimate after the editor closes (F4b fix round 1, finding s2-L-F4b-DT-2).
            note: isTypicalSizeEstimate(ingredient) ? AnyView(RecipeTypicalSizeEstimateNote()) : nil
        ) {
            // Swap targets the STORED base ingredient (matched by id), not the scaled display copy — a
            // fork is built from saved quantities. Structured recipes only.
            if RecipeScaling.isScalable(recipe) {
                RecipeIconButton(sprite: WorldSprites.swap, label: swapLabel(for: ingredient), size: 30) {
                    substitutionTarget = recipe.ingredients.first(where: { $0.id == ingredient.id }) ?? ingredient
                }
                .accessibilityInputLabels([swapLabel(for: ingredient), Text("Swap")])
                .accessibilityIdentifier("recipeDetail.swapIngredient")
            }
        }
    }

    /// The Swap button's spoken name: the food's own name, or a whole sentence of its own while the
    /// food is unresolved (an English "ingredient" used to be spliced into the key).
    private func swapLabel(for ingredient: RecipeIngredient) -> Text {
        guard let name = resolvedItems[ingredient.foodItemId]?.name else { return Text("Swap ingredient") }
        return Text("Swap \(name)")
    }

    /// The Steps card (2026-08-21, FOOD-22): the recipe's authored steps, readable WITHOUT starting
    /// cooking mode, each number on a small wooden square (`b3-recipe-notes`).
    @ViewBuilder private var stepsCard: some View {
        if let steps = recipe.steps, !steps.isEmpty {
            FernletCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Steps")
                    if recipe.isMultipart {
                        // Part by part, in making order, numbered from 1 within each part.
                        RecipePartsStepList(parts: recipe.resolvedComponents) { RecipeStepRow(number: $0, step: $1) }
                    } else {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            RecipeStepRow(number: index + 1, step: step)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The wooden Start cooking (`b2-recipe-detail` draft 3): right under the ingredients, so it shows
    /// without scrolling on a short recipe. Opens cooking mode full screen.
    private var cookButton: some View {
        Button { showingCookingMode = true } label: {
            Text("Start cooking")
        }
        .buttonStyle(RecipeWoodButtonStyle())
        .accessibilityIdentifier("recipeDetail.cook")
    }

    /// The inline line when a recipe photo couldn't be sealed (camera, library pick or its failure).
    private static var photoNotSavedNotice: String {
        String(localized: "recipeDetail.photo.notSaved",
               defaultValue: "Couldn't save this photo to your private store. Please try again.",
               comment: "Recipe page: the photo the person took or picked could not be saved on the device")
    }

    /// Whether the line's household amount is a USDA typical size rather than the food's own portion.
    private func isTypicalSizeEstimate(_ ingredient: RecipeIngredient) -> Bool {
        resolvedItems[ingredient.foodItemId].map(ingredient.isTypicalSizeEstimate(using:)) ?? false
    }

    private func save(_ image: UIImage) {
        // saveRecipePhoto is fail-closed (false on jpeg/keychain/disk failure). Only reflect the photo
        // when it actually sealed to disk — otherwise a false success would show it, then it would vanish
        // on next open when the store read finds nothing.
        guard store.saveRecipePhoto(image, for: recipe.id) else {
            photoNotice = Self.photoNotSavedNotice
            return
        }
        photo = image
        photoNotice = nil
    }

    /// Library pick: seal the picked `Data` through the bounded ImageIO downscale (no full-res bitmap),
    /// then show the just-sealed (≤1600px) bytes rather than re-decoding the full-resolution original.
    private func saveLibraryData(_ data: Data) {
        guard store.saveRecipePhoto(data: data, for: recipe.id) else {
            photoNotice = Self.photoNotSavedNotice
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
    ///
    /// A source URL with no host gets whole sentences of its own: an English "the source page" used
    /// to be spliced into each of them.
    private func confirmReimportFromSource() {
        let host = recipe.webImport?.sourceURL?.host()
        let title: LocalizedStringKey = if let host { "Re-import from \(host)?" } else { "Re-import from the source page?" }
        let message: LocalizedStringKey = if let host {
            "Fernlet will contact \(host) and replace this recipe's imported ingredients and nutrition with whatever the page says now. Your photo and notes are kept."
        } else {
            "Fernlet will contact the source page and replace this recipe's imported ingredients and nutrition with whatever the page says now. Your photo and notes are kept."
        }
        pendingDestructiveAction = DestructiveConfirmation(
            title: title,
            message: message,
            confirmLabel: "Re-import",
            auditEvent: "recipe.reimport.confirmed",
            perform: { reimportFromSource() }
        )
    }

    /// The re-import's progress and success lines, each one whole sentence with or without the host.
    private static func reimportLine(refreshed: Bool, host: String?) -> String {
        switch (refreshed, host) {
        case (false, let host?):
            String(localized: "recipeDetail.reimport.refreshing", defaultValue: "Refreshing from \(host)...",
                   comment: "Inline line on a web recipe's page while it is re-imported. The argument is the source website's host name, e.g. 'example.com'.")
        case (false, nil):
            String(localized: "recipeDetail.reimport.refreshing.noHost", defaultValue: "Refreshing from the source page...",
                   comment: "Inline line on a web recipe's page while it is re-imported from a source link with no host name.")
        case (true, let host?):
            String(localized: "recipeDetail.reimport.refreshed", defaultValue: "Refreshed from \(host). Your photo and notes are kept.",
                   comment: "Inline line after a web recipe was re-imported. The argument is the source website's host name, e.g. 'example.com'.")
        case (true, nil):
            String(localized: "recipeDetail.reimport.refreshed.noHost",
                   defaultValue: "Refreshed from the source page. Your photo and notes are kept.",
                   comment: "Inline line after a web recipe was re-imported from a source link with no host name.")
        }
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
        let host = current.webImport?.sourceURL?.host()
        isReimporting = true
        reimportNotice = Self.reimportLine(refreshed: false, host: host)
        Task {
            do {
                if let refreshed = try await store.reimportSavedRecipeFromSource(current) {
                    reimportedRecipe = refreshed
                    reimportNotice = Self.reimportLine(refreshed: true, host: host)
                    // The refresh re-armed the web-image attempt: if the recipe still has no
                    // picture, fetch it now (same post-pick screen guard as the first-open path).
                    if photo == nil, let fetched = await store.fetchRecipeWebImageIfNeeded(for: refreshed) {
                        let prepared = await UIImage(data: fetched)?.byPreparingForDisplay()
                        if photo == nil { photo = prepared }
                    }
                } else {
                    reimportNotice = String(localized: "recipeDetail.reimport.deleted",
                                            defaultValue: "This recipe was deleted, so there's nothing to refresh.",
                                            comment: "Inline line when a web recipe was deleted while its re-import was running.")
                }
            } catch {
                reimportNotice = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "recipeImport.error.reimportFallback",
                              defaultValue: "Could not re-import this recipe.",
                              comment: "Inline notice when refreshing an imported recipe from its source page fails and the thrown error carries no description of its own.")
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
/// Commits on focus loss (an entry `range` rejects reverts to the current value); nudging the stepper
/// while editing commits its value and closes the field. Two modes, one control:
/// - **Decimal grams** (`Binding<Double>`): the ingredient editors — a recipe's manual rows and
///   Adjust meal's custom food. A decimal pad; "3.4" and "3,4" both commit 3.4 (``MacroGramEntry``,
///   tenths of a gram); the stepper moves a whole gram and keeps the fraction.
/// - **Whole grams** (`Binding<Int>`): the meal-level editors (quick log, correction, pre-log review),
///   which write `Meal.macros`. A number pad, whole grams only, exactly as before.
///
/// The field opens prefilled with the current value in the same form the row shows it ("3", never
/// "3.0"); there is no placeholder.
private struct MacroInputRow: View {
    let label: LocalizedStringKey
    let unit: String
    @Binding var grams: Double
    let range: ClosedRange<Double>
    let allowsDecimals: Bool
    @State private var isEditing = false
    @State private var textValue = ""
    @FocusState private var isFocused: Bool

    /// Decimal grams, to a tenth (the ingredient editors). Every write is quantized to a tenth and held
    /// inside `range`, so a stepper nudge's floating-point residue (or a step below 0 from 0.4) never
    /// reaches the model: what is stored is what shows.
    init(label: LocalizedStringKey, unit: String, value: Binding<Double>, range: ClosedRange<Double>) {
        self.label = label
        self.unit = unit
        _grams = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max(MacroGramEntry.quantized($0), range.lowerBound), range.upperBound) }
        )
        self.range = range
        allowsDecimals = true
    }

    /// Whole grams (the meal-level editors), bridged onto the same control. A value only ever reaches
    /// the binding from the stepper or a whole-number parse, both inside `range`, and
    /// ``Macros/clampedInt(_:)`` makes the conversion total anyway.
    init(label: LocalizedStringKey, unit: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.label = label
        self.unit = unit
        _grams = Binding(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = Macros.clampedInt($0) }
        )
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        allowsDecimals = false
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Spacer()
            if isEditing {
                TextField("", text: $textValue)
                    .keyboardType(allowsDecimals ? .decimalPad : .numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(.none)
                    .multilineTextAlignment(.trailing)
                    // Same DM Sans figures the tapped value shows, so the number doesn't change
                    // typeface the moment it becomes editable. Wide enough for "250.5".
                    .font(.fernlet(.stat))
                    .frame(width: 64)
                    .focused($isFocused)
                    // `TextField("")` has no name of its own; the row's caption is a separate
                    // element, so VoiceOver announced a bare "text field" with nothing to say whose.
                    .accessibilityLabel(Text(label))
                    .onAppear {
                        isFocused = true
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Button {
                    textValue = MacroGramEntry.display(grams)
                    isEditing = true
                } label: {
                    Text("\(MacroGramEntry.display(grams))\(unit)")
                        .font(.fernlet(.stat))
                        .foregroundStyle(Color.moss)
                        .underline()
                }
                .buttonStyle(.plain)
                // "0g" alone was an 18pt-square target beside the stepper.
                .fernletTapTarget()
                // Spoke only "12g, button" — the macro it belongs to was the caption beside it, a
                // different element. Name first, amount as the value, so it reads as a field.
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(verbatim: "\(MacroGramEntry.display(grams))\(unit)"))
                .accessibilityHint("Double-tap to type an amount.")
            }
            Stepper("", value: $grams, in: range, step: 1)
                .labelsHidden()
                // `.labelsHidden()` hides the drawn label AND the spoken one: the stepper's two
                // halves read "Increment" / "Decrement" with no macro named. Same name and value
                // as the amount beside it.
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(verbatim: "\(MacroGramEntry.display(grams))\(unit)"))
                .onChange(of: grams) { _, _ in
                    if isEditing {
                        isFocused = false
                        isEditing = false
                    }
                }
        }
    }

    private func commit() {
        if let parsed = MacroGramEntry.parse(textValue, in: range, allowsDecimals: allowsDecimals) {
            grams = parsed
        }
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
    /// The recipe book's toast route, for meals logged inside the branch: the import screen's
    /// matched-recipe detail, and the manual editor's "Log & save".
    var onMealsLogged: MealLogReporter = .none
    /// Told when "Log & save" logged the recipe it created. Runs before `onCreated`, so the book
    /// knows the meal toast will speak for that save.
    var onCreatedRecipeLogged: () -> Void = {}
    /// The user's term of address (the app root sets it from the body profile), which Manual
    /// entry's "yourself" agrees with.
    @Environment(\.fernletTermOfAddress) private var termOfAddress

    /// The editor this chooser can push: the import screen or the manual editor.
    private enum CreationStep: Hashable { case importing, manual }

    /// Which editor is pushed above the chooser, if any. One optional value rather than two
    /// independent Bools, so "import" and "manual entry" can never both claim the destination.
    @State private var step: CreationStep?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose how to start.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)

                // Recipe creation is Import or Manual only. Nutrition-label scanning belongs to the
                // barcode-not-found handoff (BarcodeNotFoundView, reached from the camera when a scanned
                // barcode has no catalog match) — not as a standalone recipe-creation entry point.
                Button { step = .importing } label: {
                    RecipeCreationOptionRow(
                        title: "Import recipe",
                        subtitle: Text("Paste a recipe link or Fernlet recipe data."),
                        sprite: WorldSprites.box
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recipeCreate.import")

                Button { step = .manual } label: {
                    RecipeCreationOptionRow(
                        title: "Manual entry",
                        subtitle: Text(AddressedCopy.attributed("Enter ingredients, macros, servings, and notes yourself.", addressing: termOfAddress)),
                        sprite: WorldSprites.pen
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recipeCreate.manual")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .fernletPageBackground()
        .fernletPushedPage("Create recipe")
        .navigationBarTitleDisplayMode(.inline)
        // Saving reports the name and stops there: the book pops the editor AND this chooser with
        // the one assignment it owns. Clearing `step` here too would put a second, racing pop back
        // into the same update — the bug this replaced.
        .navigationDestination(item: $step) { destination in
            switch destination {
            case .importing:
                RecipeImportSheet(store: store, onSaved: onCreated, onMealsLogged: onMealsLogged)
            case .manual:
                RecipeSheet(
                    store: store,
                    isEmbeddedInNavigationStack: true,
                    onSaved: onCreated,
                    onMealsLogged: onMealsLogged.then(onCreatedRecipeLogged)
                )
            }
        }
    }
}

/// One tappable option card (icon, title, subtitle, chevron) in ``RecipeCreationOptionsView``.
///
/// Purely presentational — the wrapping `Button` (which sets the chooser's `step`) provides the
/// behavior.
private struct RecipeCreationOptionRow: View {
    /// Display text, so `LocalizedStringKey`: a `String` here bound `Text`'s verbatim overload and
    /// left both rows English in every language (fixed 2026-09-30).
    var title: LocalizedStringKey
    /// A `Text` the caller builds, for the same reason never a `String`: Manual entry's "yourself"
    /// describes the user (*tú mismo*), so its caller resolves it for them through `AddressedCopy`.
    var subtitle: Text
    /// The option's pixel icon on its framed tile (`b2-recipe-create`).
    var sprite: WorldSprite

    var body: some View {
        FernletCard {
            HStack(alignment: .center, spacing: 12) {
                RecipeSpriteTile(sprite: sprite)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(FernletFramedFont.rowTitleBold)
                        .foregroundStyle(WorldPalette.bark)
                    subtitle
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FernletIcon(.chevron, scale: 2)
            }
        }
        .contentShape(Rectangle())
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

/// The full recipe book: searchable, labelled A–Z lists (Your recipes / Saved from web /
/// Imported products), plus the Create/Planner/List entry points as three equal secondaries
/// (2026-08-21, FOOD-19/FOOD-14).
///
/// The World build draws it as `b2-recipe-book` (draft 3, approved 2026-10-24): pushed inside the Food
/// panel it hands "Recipe book" to the wooden plate (‹ Food), and every recipe is its own card
/// (``RecipeBookCard``: photo, name, servings, notes, coloured macro tags, a small Log menu and the
/// pixel Share). Sheet mode carries the template's pinned header with Done in the trailing slot.
/// Cards push the read-only ``RecipeDetailView``; edit requests are handed back to ``FoodView`` via
/// the two editing bindings (the book dismisses and the owning view presents the right editor
/// sheet). Sharing goes through the proximity recipe-share sheet; Log reports to `onMealsLogged` for
/// the post-log toast.
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
    /// Reports meals logged from the book's rows and details, its planner, its create branch and
    /// cooking mode so the host can raise the post-log toast (FLOW-15). FoodView threads its own
    /// reporter through; the Home sheet route passes ContentView's. Defaults to reporting nowhere
    /// so construction sites compile before wiring.
    var onMealsLogged: MealLogReporter = .none
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
    /// Set when the create branch's "Log & save" logged the recipe it created. That save's meal
    /// toast speaks for it, Undo included, so ``finishCreation(named:)`` shows the "added" line but
    /// leaves the announcement to the toast: two sentences posted together cut each other off.
    @State private var createdRecipeWasLogged = false

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
        LazyVStack(alignment: .leading, spacing: 14) {
            // Pushed: the plate carries the title. Presented: the pinned SheetHeader above the
            // scroll carries it, so only the pushed mode draws its subtitle here.
            if isEmbeddedInNavigationStack {
                Text("Recipes and saved products, A\u{2013}Z.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            if let createdNotice {
                Text(createdNotice)
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.mossInk)
                    .fernletWrappingText()
                    .accessibilityIdentifier("recipeBook.createdNotice")
            }
            createAndPlannerButtons
            searchField
            // Section labels name what you are looking at (FOOD-19): Your recipes, Saved from
            // web, Imported products. Each recipe is its own card (b2-recipe-book, draft 3).
            let allManual = filteredManualRecipes
            if !allManual.isEmpty {
                sectionHeading("Your recipes")
                recipeCards(allManual, isSaved: false)
            }
            let allSaved = filteredSavedRecipes
            if !allSaved.isEmpty {
                sectionHeading("Saved from web")
                recipeCards(allSaved, isSaved: true)
            }
            let allProducts = filteredWebImportedProducts
            if !allProducts.isEmpty {
                importedProductsCard(allProducts)
            }
            if allManual.isEmpty && allSaved.isEmpty && allProducts.isEmpty && !searchText.isEmpty {
                emptySearchState
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 28)
    }

    /// The search field with its pixel magnifier inside the framed field (`b2-recipe-book`).
    private var searchField: some View {
        HStack(spacing: 9) {
            FernletIcon(.search, scale: 2)
            TextField("Search recipes and products", text: $searchText,
                      prompt: .fieldPrompt("Search recipes and products"))
        }
        .sheetTextInput()
    }

    /// The page in its frame: pushed, the World plate carries "Recipe book" (`b1-frame-push`);
    /// presented, the sheet's own header does.
    @ViewBuilder private var bookContent: some View {
        if isEmbeddedInNavigationStack {
            bookPage.fernletPushedPage("Recipe book")
        } else {
            bookPage
        }
    }

    private var bookPage: some View {
        ScrollView {
            bookScrollContent
        }
        .fernletPageBackground()
        .navigationBarTitleDisplayMode(.inline)
        // The search field's keyboard "Done": this content is always a page of a stack (pushed in
        // the Food tab, or the root of the sheet's own stack), out of reach of any host's Done.
        .keyboardDoneToolbar()
        // The create branch hangs off the book, not off the chooser, so `finishCreation` collapses
        // chooser + editor in one go and the user lands back here — the new recipe's home.
        .navigationDestination(isPresented: $isCreatingRecipe) {
            RecipeCreationOptionsView(
                store: store,
                onCreated: { name in finishCreation(named: name) },
                onMealsLogged: loggedInBook,
                onCreatedRecipeLogged: { createdRecipeWasLogged = true }
            )
        }
        .task(id: createdNotice) {
            guard createdNotice != nil else { return }
            // A confirmation line with nothing to act on, so the notice window applies. It is read
            // as the line appears, because VoiceOver can be turned on mid-session. 4 s was gone
            // before VoiceOver's cursor could reach it.
            let window = FernletDismissalWindow.system.window(
                standard: .seconds(4),
                assistive: FernletDismissalWindow.assistiveNoticeWindow)
            do {
                try await Task.sleep(for: window)
            } catch {
                // Superseded by a newer creation (or the book went away) — that one owns the line.
                return
            }
            createdNotice = nil
        }
        .sheet(item: $recipeShareDraft) { draft in
            ProximityRecipeShareSheet(draft: draft, manager: store.recipeShareManager, store: store)
                .fernletSheet()
        }
    }

    /// Lands a finished creation back on the book. `isCreatingRecipe = false` is the ONLY navigation
    /// change: it removes the chooser destination, and with it the editor the chooser had pushed, so
    /// there is no second pop to be dropped or reordered. The notice is plain state, applied in the
    /// same update but driving nothing but text.
    private func finishCreation(named recipeName: String) {
        isCreatingRecipe = false
        createdNotice = String(localized: "recipeBook.notice.added", defaultValue: "\u{201C}\(recipeName)\u{201D} added to your recipes.",
                               comment: "Recipe book: a recipe was just created or imported. The argument is its name, in quotation marks.")
        // "Log & save": the meal toast's sentence (with its Undo) is the one spoken.
        guard !createdRecipeWasLogged else {
            createdRecipeWasLogged = false
            return
        }
        // The line appears with no focus change while the pop moves VoiceOver's cursor, so the
        // landing is spoken once the pop has settled. An unstructured Task, as the sheet-closing
        // confirmations use, so nothing about this update cancels it. This is the one confirmation
        // for every way in, so a web import is not spoken twice. It speaks the event, not the name,
        // which the line itself carries.
        Task { @MainActor in await TaskConfirmation.recipeAdded.announceAfterSheetCloses() }
    }

    /// Closes the book only when it is a sheet. Pushed inside the Food stack there is nothing to
    /// close — the editor sheet presents OVER the book, which is the whole point of pushing it.
    private func dismissIfPresented() {
        guard !isEmbeddedInNavigationStack else { return }
        dismiss()
    }

    /// The toast route for logs made deeper in the book: the planner, the create branch and cooking
    /// mode. Reports to the host, then closes the book when it is a sheet, as the rows' and the
    /// detail's own Log already do: the toast overlays the tab pages, and a sheet left standing
    /// would hide it and its Undo. Pushed in the Food tab nothing closes; the toast shows over the
    /// page the log was made on.
    private var loggedInBook: MealLogReporter {
        onMealsLogged.then { dismissIfPresented() }
    }

    /// Create-recipe plus the F3 grocery entry points, as THREE EQUAL secondaries (XCUT-14 —
    /// Create lost its moss fill: entering the book is not the same as committing anything). The
    /// planner persists a per-day plan; the list builder is one-off; both aggregate through the
    /// shared Phase A pipeline and share to Notes.
    private var createAndPlannerButtons: some View {
        // Stacks at accessibility sizes: side by side these broke mid-word at different heights.
        AdaptiveStack(spacing: 10) {
            // A Button rather than a NavigationLink: the push is driven by `isCreatingRecipe`, the
            // one value that also un-pushes the whole branch when a recipe is saved.
            Button {
                isCreatingRecipe = true
            } label: {
                RecipeBookToolButtonLabel(title: Text("Create"), sprite: nil, usesPlusIcon: true)
            }
            .accessibilityIdentifier("recipeBook.create")
            NavigationLink {
                WeeklyMealPlannerView(store: store, onMealsLogged: loggedInBook)
            } label: {
                RecipeBookToolButtonLabel(title: Text("Planner"), sprite: WorldSprites.diary)
            }
            NavigationLink {
                ShoppingListBuilderView(store: store)
            } label: {
                RecipeBookToolButtonLabel(title: Text("List"), sprite: WorldSprites.box)
            }
        }
        .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
    }

    /// A named section heading over one of the book's three lists (FOOD-19): the framed look's label
    /// with its moss square.
    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        SectionLabel(title)
            .padding(.top, 4)
    }

    /// One A–Z run of recipe cards. `isSaved` selects the saved/web store's methods (edit sheet, log,
    /// share text) over the manual store's — the cards are otherwise identical.
    @ViewBuilder private func recipeCards(_ recipes: [RecipeDefinition], isSaved: Bool) -> some View {
        ForEach(recipes) { recipe in
            recipeCard(recipe, isSaved: isSaved)
        }
    }

    /// A recipe as its card (b2-recipe-book, draft 3): the tappable summary pushes the read-only
    /// recipe page; Log opens the meal-type menu and Share the sharing sheet, in place.
    private func recipeCard(_ recipe: RecipeDefinition, isSaved: Bool) -> some View {
        RecipeBookCard(
            macros: perServingMacros(recipe),
            showsCalories: store.settings.showCalories,
            estimateNote: isSaved ? WebImportEstimateNote(uncountedLines: recipe.webImport?.uncountedIngredientLines,
                                                          estimatedLines: recipe.webImport?.estimatedIngredientLines) : nil,
            onLog: { mealType in
                logRecipe(recipe, mealType: mealType, isSaved: isSaved)
                dismissIfPresented()
            },
            onShare: { recipeShareDraft = store.recipeShareDraft(for: recipe) }
        ) {
            #if canImport(UIKit)
            NavigationLink {
                recipeDetail(for: recipe, isSaved: isSaved)
            } label: {
                RecipeCardSummary(recipe: recipe, loadPhoto: { store.recipePhotoData(for: recipe.id) })
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recipeBook.recipe")
            #else
            Button { beginEditing(recipe, isSaved: isSaved); dismissIfPresented() } label: {
                RecipeCardSummary(recipe: recipe, loadPhoto: nil)
            }
            .buttonStyle(.plain)
            #endif
        }
    }

    /// A recipe's per-serving macros: a web import's own figures (nil when its page carried none),
    /// or a manual recipe's resolved totals divided by its servings.
    private func perServingMacros(_ recipe: RecipeDefinition) -> MacroTotals? {
        if let macros = recipe.webImport?.macros {
            guard macros.protein > 0 || macros.carbs > 0 || macros.fat > 0 else { return nil }
            return MacroTotals(protein: macros.protein, carbs: macros.carbs, fat: macros.fat)
        }
        let totals = store.macroTotals(for: recipe)
        let divisor = Double(max(recipe.servings, 1))
        return MacroTotals(protein: Int((Double(totals.protein) / divisor).rounded()),
                           carbs: Int((Double(totals.carbs) / divisor).rounded()),
                           fat: Int((Double(totals.fat) / divisor).rounded()))
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
            onShare: { current in recipeShareDraft = store.recipeShareDraft(for: current) },
            onCookLog: { current, mealType, day in
                if isSaved {
                    return store.logSavedRecipe(current, mealType: mealType, date: day)
                }
                return store.logRecipe(current, mealType: mealType, date: day)
            },
            onMealsLogged: loggedInBook
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
        if isSaved {
            onMealsLogged([store.logSavedRecipe(recipe, mealType: mealType)])
            return
        }
        guard let meal = store.logRecipe(recipe, mealType: mealType) else { return }
        onMealsLogged([meal])
    }

    @ViewBuilder private func importedProductsCard(_ products: [FoodItem]) -> some View {
        sectionHeading("Imported products")
        ForEach(products) { product in
            ImportedProductCard(product: product) { mealType in
                let meal = store.logWebImportedFoodProduct(product, mealType: mealType)
                onMealsLogged([meal])
                dismissIfPresented()
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

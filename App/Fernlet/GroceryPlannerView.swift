//
//  GroceryPlannerView.swift
//  Fernlet
//
//  F3 — grocery list (decision §11.3). Two user-initiated planning surfaces, both inside the
//  Food/recipe area (§582's anti-dashboard rule constrains ambient nudges, not a planner the user
//  opens deliberately):
//
//  - Phase A `ShoppingListBuilderView`: multi-select recipes → aggregate → share. No persistence.
//  - Phase B `WeeklyMealPlannerView`: assign recipes to the week's days (persisted on
//    `FernletDay.plannedRecipeIDs`), then "Create shopping list" runs the week through Phase A.
//
//  Delivery is `ShareLink` with plain text — Notes receives it as a new note; there is no public API
//  to write Notes directly (§11.3), so the share sheet IS the mechanism.
//

import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI

// MARK: - Phase A — select, aggregate, share

/// The Phase A shopping-list builder: multi-select recipes (with an optional "cook for N" yield per
/// scalable recipe), preview the aggregated list, and share it as plain text.
///
/// Reached from the recipe book and from ``WeeklyMealPlannerView``'s "Create shopping list" (which
/// pre-seeds `initialSelection` with the week's plan, once). Aggregation runs through
/// `FernletStore.groceryListText(for:)` — the pure `GroceryAggregation` engine — and delivery is a
/// `ShareLink` (the share sheet IS the push-to-Notes mechanism). Nothing here persists: the selection
/// and yields are view state, and the list is one-shot text.
struct ShoppingListBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    /// Recipe ids to pre-select — the week's plan when launched from the planner (Phase B), empty for
    /// a one-off list. Dangling ids simply don't match a recipe and are ignored.
    var initialSelection: [UUID] = []

    @State private var selectedIDs: Set<UUID> = []
    @State private var yieldByID: [UUID: Int] = [:]
    @State private var searchText = ""
    /// Seed `selectedIDs` from `initialSelection` exactly once. Keying the seed off `selectedIDs.isEmpty`
    /// re-seeds on every `onAppear` — so deselecting everything, pushing a detail, and popping back would
    /// resurrect the whole week's plan. A one-shot flag makes an empty selection a stable user choice.
    @State private var didSeed = false

    /// Both recipe stores unioned, exactly as the recipe-book UI does (manual/peer + web-import).
    private var allRecipes: [RecipeDefinition] {
        (store.recipes + store.savedRecipes)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredRecipes: [RecipeDefinition] {
        guard !searchText.isEmpty else { return allRecipes }
        return allRecipes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var selections: [FernletStore.GrocerySelection] {
        allRecipes
            .filter { selectedIDs.contains($0.id) }
            .map { FernletStore.GrocerySelection(recipe: $0, yieldOverride: yieldByID[$0.id]) }
    }

    private var listText: String { store.groceryListText(for: selections) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // A pushed page titles itself in the nav bar (see `.navigationTitle` below); drawing
                // the title in the body as well left ~90pt of empty bar above it.
                Text("Pick recipes, then share the combined list to Notes.")
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("screen.shoppingList")

                if allRecipes.isEmpty {
                    EmptyState(text: "No recipes yet. Create one in the recipe book first.")
                        .frame(maxWidth: .infinity)
                } else {
                    TextField("Search recipes", text: $searchText)
                        .sheetTextInput()

                    FernletCard {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredRecipes.enumerated()), id: \.element.id) { index, recipe in
                                if index > 0 { FernletRowDivider() }
                                recipeSelectRow(recipe)
                            }
                        }
                    }

                    if !selections.isEmpty {
                        listPreview
                        ShareLink(item: listText) {
                            Label("Share shopping list", systemImage: "square.and.arrow.up")
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.onMoss)
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityIdentifier("shoppingList.share")
                    } else {
                        EmptyState(text: "Select recipes to build a list.")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .background(Color.parchment)
        .navigationTitle("Shopping list")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !didSeed {
                didSeed = true
                selectedIDs = Set(initialSelection)
            }
        }
    }

    @ViewBuilder
    private func recipeSelectRow(_ recipe: RecipeDefinition) -> some View {
        let isSelected = selectedIDs.contains(recipe.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle(recipe)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.moss : Color.slate)
                        .font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.name)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                        Text(recipe.isWebImport ? "Imported \u{00B7} free-text ingredients"
                                                : "\(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected, RecipeScaling.isScalable(recipe) {
                let current = yieldByID[recipe.id] ?? recipe.servings
                Stepper(value: Binding(
                    get: { yieldByID[recipe.id] ?? recipe.servings },
                    set: { yieldByID[recipe.id] = RecipeScaling.clampedYield($0) }
                ), in: RecipeScaling.yieldRange) {
                    Text("Cook for \(current)")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.bark)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 6)
    }

    private var listPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Preview")
            FernletCard {
                Text(listText)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.bark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func toggle(_ recipe: RecipeDefinition) {
        if selectedIDs.contains(recipe.id) {
            selectedIDs.remove(recipe.id)
            yieldByID[recipe.id] = nil
        } else {
            selectedIDs.insert(recipe.id)
        }
    }
}

// MARK: - Phase B — weekly meal planner

/// The Phase B weekly meal planner: assign recipes (with a meal slot) to each day of a browsable
/// week, then run the week's de-duplicated plan through ``ShoppingListBuilderView``.
///
/// The plan is the only persisted state in the grocery feature — typed
/// `FernletDay.plannedMeals` entries (recipe id + meal slot) written in parallel with the legacy
/// `plannedRecipeIDs` via `FernletStore.planRecipe(_:mealType:date:)`/`unplanRecipe`, read merged
/// through `FernletDay.plannedMealEntries`. Past/future day rows aren't the observed `store.day`,
/// so the view keeps its own `plannedByDay` copy and reloads it after every mutation and week
/// switch. Dangling ids (recipes since deleted) are dropped silently.
///
/// 2026-08-21 (FOOD-35 / XCUT-21): today's card carries the moss outline, a "N planned" count and
/// per-recipe Log pills that log against the planned meal slot; other days keep remove only, now
/// in the destructive tint. Logging confirms inline (a quiet line under the header) rather than
/// through the cross-tab toast — the planner is a pushed page, not a tab root.
struct WeeklyMealPlannerView: View {
    var store: FernletStore

    /// A day key wrapped for `.sheet(item:)` identity — avoids a broad retroactive `String: Identifiable`.
    ///
    /// Setting one presents the ``RecipePickerSheet`` for that day; the key doubles as the plan date.
    private struct DayPick: Identifiable { let id: String }

    @State private var weekOffset = 0
    @State private var plannedByDay: [String: [PlannedMealEntry]] = [:]
    @State private var pickingForDay: DayPick?
    /// The recipe name a Log pill just committed — drives the quiet inline confirmation line,
    /// which clears itself after a beat (same pattern as the recipe book's created notice).
    @State private var loggedRecipeName: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let calendar = Calendar.current

    private var weekDayKeys: [String] {
        let base = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: calendar.startOfDay(for: Date())) ?? Date()
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: base) else { return [] }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: interval.start).map(FernletDate.dayKey(for:))
        }
    }

    private var recipeByID: [UUID: RecipeDefinition] {
        Dictionary((store.recipes + store.savedRecipes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var plannedIDsThisWeek: [UUID] {
        // Union across the visible week, de-duplicated (a recipe planned twice is bought once).
        var seen = Set<UUID>()
        return weekDayKeys.flatMap { plannedByDay[$0] ?? [] }.map(\.recipeID).filter { seen.insert($0).inserted }
    }

    /// Today's plan key — the ONE day whose card gets the moss outline and Log pills.
    private var todayKey: String { FernletDate.dayKey(for: Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Pushed page: the nav bar carries the title (see `.navigationTitle` below), so the
                // body keeps only the line that says what this screen is for.
                Text("Assign recipes to your week, then build one shopping list.")
                    .font(.fernlet(.bodySmall))
                    .italic()
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("screen.mealPlanner")

                if let loggedRecipeName {
                    Text("\u{201C}\(loggedRecipeName)\u{201D} logged to today.")
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.moss)
                        .fernletWrappingText()
                        .accessibilityIdentifier("mealPlanner.loggedNotice")
                }

                weekSwitcher

                ForEach(weekDayKeys, id: \.self) { key in
                    dayCard(key)
                }

                NavigationLink {
                    ShoppingListBuilderView(store: store, initialSelection: plannedIDsThisWeek)
                } label: {
                    Label("Create shopping list", systemImage: "cart")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.onMoss)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(plannedIDsThisWeek.isEmpty ? Color.slate : Color.moss,
                                    in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(plannedIDsThisWeek.isEmpty)
                .accessibilityIdentifier("mealPlanner.createList")
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .background(Color.parchment)
        .navigationTitle("Meal planner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        // The confirmation line clears after a beat; a newer log supersedes the sleeper.
        .task(id: loggedRecipeName) {
            guard loggedRecipeName != nil else { return }
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            loggedRecipeName = nil
        }
        .sheet(item: $pickingForDay) { pick in
            RecipePickerSheet(store: store) { recipeID, mealType in
                store.planRecipe(recipeID, mealType: mealType, date: pick.id)
                reload()
            }
        }
    }

    private var weekSwitcher: some View {
        HStack {
            Button { weekOffset -= 1; reload() } label: {
                Image(systemName: "chevron.left").foregroundStyle(Color.moss)
            }
            .fernletIconButton("Previous week")
            Spacer()
            Text(weekLabel)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            Spacer()
            Button { weekOffset += 1; reload() } label: {
                Image(systemName: "chevron.right").foregroundStyle(Color.moss)
            }
            .fernletIconButton("Next week")
        }
        .padding(.horizontal, 4)
    }

    private var weekLabel: String {
        if weekOffset == 0 { return "This week" }
        if weekOffset == 1 { return "Next week" }
        if weekOffset == -1 { return "Last week" }
        return weekOffset > 0 ? "In \(weekOffset) weeks" : "\(-weekOffset) weeks ago"
    }

    @ViewBuilder
    private func dayCard(_ key: String) -> some View {
        let entries = plannedByDay[key] ?? []
        let isToday = key == todayKey
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                dayCardHeader(key, plannedCount: entries.count, isToday: isToday)
                if entries.isEmpty {
                    Text("Nothing planned.")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                } else {
                    ForEach(entries) { entry in
                        // A dangling id (recipe since deleted) resolves to nothing and is dropped silently.
                        if let recipe = recipeByID[entry.recipeID] {
                            plannedEntryRow(entry, recipe: recipe, dayKey: key, isToday: isToday)
                        }
                    }
                }
            }
        }
        // Today's card is the one with the moss outline, so it is findable at a glance (FOOD-35).
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isToday ? Color.moss.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
    }

    /// A day card's heading row: the day name (with a "N planned" count on today), and the add
    /// affordance. The `mealPlanner.add` identifier is a UI-test token and stays on the button.
    private func dayCardHeader(_ key: String, plannedCount: Int, isToday: Bool) -> some View {
        HStack(spacing: 8) {
            dayHeadingText(key, isToday: isToday)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            if isToday, plannedCount > 0 {
                Text("\(plannedCount) planned")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.parchment, in: Capsule())
            }
            Spacer()
            Button { pickingForDay = DayPick(id: key) } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.moss)
            }
            .fernletIconButton("Add a meal to \(dayHeading(key))")
            .accessibilityIdentifier("mealPlanner.add")
        }
    }

    /// One planned recipe on a day card: name over its planned meal slot, with a Log pill (today
    /// only — logging Saturday's dinner on Friday is almost always a mis-tap) and the
    /// destructive-tinted remove. At accessibility sizes the controls drop to their own line so
    /// neither target shrinks.
    @ViewBuilder
    private func plannedEntryRow(_ entry: PlannedMealEntry, recipe: RecipeDefinition, dayKey: String, isToday: Bool) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                plannedEntrySummary(entry, recipe: recipe)
                HStack(spacing: 12) {
                    if isToday { logPill(entry, recipe: recipe) }
                    Spacer(minLength: 0)
                    removeButton(entry, recipe: recipe, dayKey: dayKey)
                }
            }
        } else {
            HStack(spacing: 12) {
                plannedEntrySummary(entry, recipe: recipe)
                Spacer(minLength: 0)
                if isToday { logPill(entry, recipe: recipe) }
                removeButton(entry, recipe: recipe, dayKey: dayKey)
            }
        }
    }

    /// The planned recipe's name over its meal slot (omitted for a legacy slotless entry).
    private func plannedEntrySummary(_ entry: PlannedMealEntry, recipe: RecipeDefinition) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recipe.name)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            if let mealType = entry.mealType {
                Text(verbatim: mealType.displayName)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
        }
    }

    /// The Log pill: logs one serving against the meal slot the recipe was planned for — the plan
    /// already knows, so the user isn't asked twice. A slotless legacy entry falls back to the
    /// by-time "Auto" rule inside `logRecipe`.
    private func logPill(_ entry: PlannedMealEntry, recipe: RecipeDefinition) -> some View {
        Button("Log") { logPlanned(entry, recipe: recipe) }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityLabel("Log \(recipe.name)")
            .accessibilityIdentifier("mealPlanner.log")
    }

    /// The remove control, in the destructive tint (XCUT-21) — no neutral minus.
    private func removeButton(_ entry: PlannedMealEntry, recipe: RecipeDefinition, dayKey: String) -> some View {
        Button {
            store.unplanRecipe(entry.recipeID, date: dayKey)
            reload()
        } label: {
            Image(systemName: "minus.circle")
                .foregroundStyle(Color.terracottaInk)
        }
        .fernletIconButton("Remove \(recipe.name) from \(dayHeading(dayKey))")
    }

    /// Logs a planned recipe to today through the store half that owns it, then raises the quiet
    /// inline confirmation. The plan entry is kept — a plan describes the day, not a to-do list.
    private func logPlanned(_ entry: PlannedMealEntry, recipe: RecipeDefinition) {
        if store.savedRecipes.contains(where: { $0.id == recipe.id }) {
            store.logSavedRecipe(recipe, mealType: entry.mealType)
        } else {
            store.logRecipe(recipe, mealType: entry.mealType)
        }
        loggedRecipeName = recipe.name
    }

    private func dayHeading(_ key: String) -> String {
        guard let date = FernletDate.date(fromDayKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// The card's heading: "Today · Friday" for today (FOOD-35's at-a-glance marker beside the
    /// moss outline), the full formatted date for every other day.
    private func dayHeadingText(_ key: String, isToday: Bool) -> Text {
        guard isToday, let date = FernletDate.date(fromDayKey: key) else {
            return Text(verbatim: dayHeading(key))
        }
        return Text("Today \u{00B7} \(date, format: .dateTime.weekday(.wide))")
    }

    /// Reloads the visible week's plan from the store — the MERGED typed+legacy read
    /// (`plannedMealEntries`), so a plan written by an older build still renders. Past/future day
    /// rows aren't the observed `store.day`, so the view holds its own copy and refreshes it after
    /// every mutation.
    private func reload() {
        var next: [String: [PlannedMealEntry]] = [:]
        for key in weekDayKeys {
            next[key] = store.loadDay(for: key).plannedMealEntries
        }
        plannedByDay = next
    }
}

// MARK: - Recipe picker (assign to a day)

/// The searchable "Add a meal" sheet the planner presents to assign one recipe to a day.
///
/// Two steps (2026-08-21, FOOD-35): tapping a recipe row opens the meal-slot chip step inline in
/// place of the list, and choosing a slot fires `onPick` with the recipe id AND the meal type,
/// then dismisses — the owning ``WeeklyMealPlannerView`` performs the actual `planRecipe` write
/// and reload. Lists both recipe stores unioned A–Z (matching the recipe book).
private struct RecipePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    var onPick: (UUID, MealType) -> Void

    @State private var searchText = ""
    /// The recipe awaiting its meal-slot choice — non-nil switches the sheet to the chip step.
    @State private var pendingRecipe: RecipeDefinition?

    private var recipes: [RecipeDefinition] {
        let all = (store.recipes + store.savedRecipes)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let pendingRecipe {
                        mealTypeStep(pendingRecipe)
                    } else {
                        recipeListStep
                    }
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("Add a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Step 1: the searchable A–Z recipe list. Tapping a row advances to the meal-slot step.
    @ViewBuilder private var recipeListStep: some View {
        TextField("Search recipes", text: $searchText)
            .sheetTextInput()
        if recipes.isEmpty {
            EmptyState(text: "No recipes to add.")
                .frame(maxWidth: .infinity)
        } else {
            FernletCard {
                VStack(spacing: 0) {
                    ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                        if index > 0 { FernletRowDivider() }
                        Button {
                            pendingRecipe = recipe
                        } label: {
                            HStack {
                                Text(recipe.name)
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                Spacer()
                                Image(systemName: "plus")
                                    .foregroundStyle(Color.moss)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Step 2: the meal-slot chips for the chosen recipe — the choice the plan carries so logging
    /// it later never asks again. "Back" returns to the list without planning anything.
    private func mealTypeStep(_ recipe: RecipeDefinition) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recipe.name)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            SheetField("Plan it for") {
                FlowLayout(spacing: 8) {
                    ForEach(MealType.allCases) { type in
                        Button { onPick(recipe.id, type); dismiss() } label: {
                            Text(verbatim: type.displayName)
                        }
                        .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
            }
            Button("Back to recipes") { pendingRecipe = nil }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .fernletTapTarget()
        }
    }
}

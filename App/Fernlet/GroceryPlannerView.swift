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

    /// World build (`b2-shopping`, approved 2026-10-23): pushed under the wooden plate, the line, the
    /// search field, the recipes with framed checkboxes, then the preview and Share once any is picked.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // A pushed page: the plate carries the title.
                Text("Pick recipes, then share the combined list to Notes.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("screen.shoppingList")

                if allRecipes.isEmpty {
                    EmptyState(text: "No recipes yet. Create one in the recipe book first.")
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 9) {
                        FernletIcon(.search, scale: 2)
                        TextField("Search recipes", text: $searchText, prompt: .fieldPrompt("Search recipes"))
                    }
                    .sheetTextInput()

                    FernletCard {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredRecipes.enumerated()), id: \.element.id) { index, recipe in
                                if index > 0 { FernletDottedRule() }
                                recipeSelectRow(recipe)
                            }
                        }
                    }
                    selectionFooter
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .fernletPageBackground()
        .fernletPushedPage("Shopping list")
        .navigationBarTitleDisplayMode(.inline)
        // Always pushed (the recipe book or the planner), so the page declares its own keyboard
        // "Done": one declared outside the stack never reaches a page inside it.
        .keyboardDoneToolbar()
        .onAppear {
            if !didSeed {
                didSeed = true
                selectedIDs = Set(initialSelection)
            }
        }
    }

    /// The preview and Share once a recipe is picked; the hint before.
    @ViewBuilder private var selectionFooter: some View {
        if !selections.isEmpty {
            listPreview
            ShareLink(item: listText) {
                HStack(spacing: 8) {
                    WorldSpriteView(sprite: WorldSprites.share, scale: 2, tint: WorldPalette.onAccent)
                    Text("Share shopping list")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .accessibilityIdentifier("shoppingList.share")
        } else {
            Text("Select recipes to build a list.")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func recipeSelectRow(_ recipe: RecipeDefinition) -> some View {
        let isSelected = selectedIDs.contains(recipe.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle(recipe)
            } label: {
                HStack(spacing: 14) {
                    ShoppingCheckbox(isOn: isSelected)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.name)
                            .font(FernletFramedFont.rowTitle)
                            .foregroundStyle(WorldPalette.bark)
                        Group {
                            if recipe.isWebImport {
                                Text("Imported \u{00B7} free-text ingredients")
                            } else {
                                // Grammar agreement, never an English "s" picked by count.
                                Text("^[\(recipe.servings) serving](inflect: true)")
                            }
                        }
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // T1-5: a hand-rolled checkbox row — the box's fill is otherwise invisible to VoiceOver
            // and Differentiate Without Color.
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected, RecipeScaling.isScalable(recipe) {
                let current = yieldByID[recipe.id] ?? recipe.servings
                HStack(spacing: 10) {
                    Text("Cook for \(current)")
                        .font(FernletFramedFont.rowDetailBold)
                        .foregroundStyle(WorldPalette.bark)
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    FernletStepper("Cook for \(current)", value: Binding(
                        get: { yieldByID[recipe.id] ?? recipe.servings },
                        set: { yieldByID[recipe.id] = RecipeScaling.clampedYield($0) }
                    ), in: RecipeScaling.yieldRange, step: 1)
                }
                .padding(.leading, 38)
                .padding(.bottom, 6)
            }
        }
    }

    private var listPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Preview")
            FernletCard {
                Text(listText)
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.bark)
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
/// in the destructive tint. A Log confirms through the meal-logged toast with Undo (2026-10-20,
/// B1), which replaced a quiet inline line that offered no Undo and was never spoken. The planner
/// is pushed from the recipe book: in the Food tab the toast shows over it, and in the book
/// presented from Home the book closes on a log, as it does for every other log made in it.
struct WeeklyMealPlannerView: View {
    var store: FernletStore
    /// The recipe book's toast route (``MealLogReporter``): the Log pill reports what it logged.
    var onMealsLogged: MealLogReporter = .none

    /// A day key wrapped for `.sheet(item:)` identity — avoids a broad retroactive `String: Identifiable`.
    ///
    /// Setting one presents the ``RecipePickerSheet`` for that day; the key doubles as the plan date.
    private struct DayPick: Identifiable { let id: String }

    @State private var weekOffset = 0
    @State private var plannedByDay: [String: [PlannedMealEntry]] = [:]
    @State private var pickingForDay: DayPick?
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
            VStack(alignment: .leading, spacing: 14) {
                // Pushed page: the plate carries the title, so the body keeps only the line that says
                // what this screen is for.
                Text("Assign recipes to your week, then build one shopping list.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("screen.mealPlanner")

                weekSwitcher

                ForEach(weekDayKeys, id: \.self) { key in
                    dayCard(key)
                }

                NavigationLink {
                    ShoppingListBuilderView(store: store, initialSelection: plannedIDsThisWeek)
                } label: {
                    HStack(spacing: 8) {
                        WorldSpriteView(sprite: WorldSprites.box, scale: 2, tint: WorldPalette.onAccent)
                        Text("Create shopping list")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .disabled(plannedIDsThisWeek.isEmpty)
                .accessibilityIdentifier("mealPlanner.createList")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .fernletPageBackground()
        .fernletPushedPage("Meal planner")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(item: $pickingForDay) { pick in
            RecipePickerSheet(store: store) { recipeID, mealType in
                store.planRecipe(recipeID, mealType: mealType, date: pick.id)
                reload()
            }
            .fernletSheet()
        }
    }

    /// "‹ This week ›" (`b2-planner`): pixel arrows either side of the week's name in Fraunces.
    private var weekSwitcher: some View {
        HStack {
            Button { weekOffset -= 1; reload() } label: {
                FernletIcon(.back, scale: 2).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fernletIconButton("Previous week")
            Spacer()
            weekLabel
                .font(RecipeType.cardTitle)
                .foregroundStyle(WorldPalette.bark)
            Spacer()
            Button { weekOffset += 1; reload() } label: {
                FernletIcon(.chevron, scale: 2).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fernletIconButton("Next week")
        }
    }

    /// The switcher's heading. `Text`, not `String`: as a `String` it was drawn verbatim and never
    /// reached the catalog, and the counts agree by grammar rather than by an English plural.
    private var weekLabel: Text {
        if weekOffset == 0 { return Text("This week") }
        if weekOffset == 1 { return Text("Next week") }
        if weekOffset == -1 { return Text("Last week") }
        return weekOffset > 0
            ? Text("In ^[\(weekOffset) week](inflect: true)")
            : Text("^[\(-weekOffset) week](inflect: true) ago")
    }

    @ViewBuilder
    private func dayCard(_ key: String) -> some View {
        let entries = plannedByDay[key] ?? []
        let isToday = key == todayKey
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                dayCardHeader(key, plannedCount: entries.count, isToday: isToday)
                if entries.isEmpty {
                    Text("Nothing planned.")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                } else {
                    ForEach(entries) { entry in
                        // A dangling id (recipe since deleted) resolves to nothing and is dropped silently.
                        if let recipe = recipeByID[entry.recipeID] {
                            FernletDottedRule()
                            plannedEntryRow(entry, recipe: recipe, dayKey: key, isToday: isToday)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Today's card is the one with the moss outline, so it is findable at a glance (FOOD-35,
        // b2-planner draft 2: a 3-pt moss ring outside the frame).
        .overlay(
            RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius + 3, style: .continuous)
                .strokeBorder(isToday ? WorldPalette.moss : Color.clear, lineWidth: 3)
                .padding(-4)
        )
    }

    /// A day card's heading row: the day name (with a "N planned" count on today), and the add
    /// affordance. The `mealPlanner.add` identifier is a UI-test token and stays on the button.
    private func dayCardHeader(_ key: String, plannedCount: Int, isToday: Bool) -> some View {
        HStack(spacing: 8) {
            dayHeadingText(key, isToday: isToday)
                .font(RecipeType.cardTitle)
                .foregroundStyle(WorldPalette.bark)
                .fixedSize(horizontal: false, vertical: true)
            if isToday, plannedCount > 0 {
                FernletTag(text: Text("\(plannedCount) planned"))
            }
            Spacer()
            Button { pickingForDay = DayPick(id: key) } label: {
                RecipeSpriteTile(sprite: WorldSprites.plus, size: 34, isControl: true)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fernletIconButton("Add a meal to \(dayHeading(key))")
            // Voice Control: one plus per day card, so the weekday is what makes each sayable and
            // unique; the full date in the label is more than anyone should have to dictate.
            .accessibilityInputLabels([Text("Add to \(spokenWeekday(key))"), Text("Add meal \(spokenWeekday(key))")])
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

    /// The planned recipe's photo (or its bowl tile), its name over its meal slot (the slot omitted for
    /// a legacy slotless entry), as `b2-planner` draft 2 draws a planned meal.
    private func plannedEntrySummary(_ entry: PlannedMealEntry, recipe: RecipeDefinition) -> some View {
        HStack(spacing: 10) {
            RecipePhotoThumb(recipeID: recipe.id, load: { store.recipePhotoData(for: recipe.id) })
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(FernletFramedFont.bodyBold)
                    .foregroundStyle(WorldPalette.bark)
                    .fixedSize(horizontal: false, vertical: true)
                if let mealType = entry.mealType {
                    Text(verbatim: mealType.displayName)
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                }
            }
        }
    }

    /// The Log pill: logs one serving against the meal slot the recipe was planned for — the plan
    /// already knows, so the user isn't asked twice. A slotless legacy entry falls back to the
    /// by-time "Auto" rule inside `logRecipe`.
    private func logPill(_ entry: PlannedMealEntry, recipe: RecipeDefinition) -> some View {
        Button("Log") { logPlanned(entry, recipe: recipe) }
            .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
            .accessibilityLabel("Log \(recipe.name)")
            .accessibilityIdentifier("mealPlanner.log")
    }

    /// The remove control, the framed look's pixel ✕ (`b2-planner` draft 2).
    private func removeButton(_ entry: PlannedMealEntry, recipe: RecipeDefinition, dayKey: String) -> some View {
        Button {
            store.unplanRecipe(entry.recipeID, date: dayKey)
            reload()
        } label: {
            FernletIcon(.close, scale: 2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fernletIconButton("Remove \(recipe.name) from \(dayHeading(dayKey))")
    }

    /// Logs a planned recipe to today through the store half that owns it, then reports the meal to
    /// the toast. The plan entry is kept — a plan describes the day, not a to-do list.
    private func logPlanned(_ entry: PlannedMealEntry, recipe: RecipeDefinition) {
        if store.savedRecipes.contains(where: { $0.id == recipe.id }) {
            onMealsLogged([store.logSavedRecipe(recipe, mealType: entry.mealType)])
        } else if let meal = store.logRecipe(recipe, mealType: entry.mealType) {
            onMealsLogged([meal])
        }
    }

    private func dayHeading(_ key: String) -> String {
        guard let date = FernletDate.date(fromDayKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// The day's weekday alone ("Friday"): the part of ``dayHeading(_:)`` a Voice Control user says.
    private func spokenWeekday(_ key: String) -> String {
        guard let date = FernletDate.date(fromDayKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.wide))
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

    /// World build (`b3-planner-picker`, approved 2026-10-24): the sheet frame with Done top right and
    /// the title inside, the search field, the recipes with framed +, and once one is tapped, its card
    /// with "Plan it for" and the meal chips under the list.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    recipeListStep
                    if let pendingRecipe {
                        mealTypeStep(pendingRecipe)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .background(WorldPalette.paper)
            .fernletSheetToolbar(title: "Add a meal", onDone: { dismiss() })
            // The search field's keyboard "Done", on the stack's root page: one declared on the
            // stack itself would reach no page in it.
            .keyboardDoneToolbar()
        }
    }

    /// Step 1: the searchable A–Z recipe list. Tapping a row opens the meal-slot step under it.
    @ViewBuilder private var recipeListStep: some View {
        HStack(spacing: 9) {
            FernletIcon(.search, scale: 2)
            TextField("Search recipes", text: $searchText, prompt: .fieldPrompt("Search recipes"))
        }
        .sheetTextInput()
        if recipes.isEmpty {
            EmptyState(text: "No recipes to add.")
                .frame(maxWidth: .infinity)
        } else {
            FernletCard {
                VStack(spacing: 0) {
                    ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                        if index > 0 { FernletDottedRule() }
                        recipeRow(recipe)
                    }
                }
            }
        }
    }

    private func recipeRow(_ recipe: RecipeDefinition) -> some View {
        Button {
            pendingRecipe = recipe
        } label: {
            HStack(spacing: 10) {
                Text(recipe.name)
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.bark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RecipeSpriteTile(sprite: WorldSprites.plus, size: 32)
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(pendingRecipe?.id == recipe.id ? .isSelected : [])
    }

    /// Step 2: the meal-slot chips for the chosen recipe — the choice the plan carries so logging
    /// it later never asks again. "Back to recipes" closes the step without planning anything.
    private func mealTypeStep(_ recipe: RecipeDefinition) -> some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: recipe.name)
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.bark)
                SectionLabel("Plan it for")
                FlowLayout(spacing: 8) {
                    ForEach(MealType.allCases) { type in
                        Button { onPick(recipe.id, type); dismiss() } label: {
                            Text(verbatim: type.displayName)
                        }
                        .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
                Button("Back to recipes") { pendingRecipe = nil }
                    .buttonStyle(.plain)
                    .font(FernletFramedFont.sheetControl)
                    .foregroundStyle(WorldPalette.mossInk)
                    .frame(maxWidth: .infinity)
                    .fernletTapTarget()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

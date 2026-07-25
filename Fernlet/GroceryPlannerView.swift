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
                ScreenHeader(
                    title: "Shopping list",
                    subtitle: "Pick recipes, then share the combined list to Notes.",
                    subtitleFirst: false,
                    identifier: "screen.shoppingList")

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
                                .foregroundStyle(Color.cream)
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
        .navigationTitle("")
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

struct WeeklyMealPlannerView: View {
    var store: FernletStore

    /// A day key wrapped for `.sheet(item:)` identity — avoids a broad retroactive `String: Identifiable`.
    private struct DayPick: Identifiable { let id: String }

    @State private var weekOffset = 0
    @State private var plannedByDay: [String: [UUID]] = [:]
    @State private var pickingForDay: DayPick?

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
        return weekDayKeys.flatMap { plannedByDay[$0] ?? [] }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: "Meal planner",
                    subtitle: "Assign recipes to your week, then build one shopping list.",
                    subtitleFirst: false,
                    identifier: "screen.mealPlanner")

                weekSwitcher

                ForEach(weekDayKeys, id: \.self) { key in
                    dayCard(key)
                }

                NavigationLink {
                    ShoppingListBuilderView(store: store, initialSelection: plannedIDsThisWeek)
                } label: {
                    Label("Create shopping list", systemImage: "cart")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.cream)
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
        .navigationTitle("")
        .onAppear(perform: reload)
        .sheet(item: $pickingForDay) { pick in
            RecipePickerSheet(store: store) { recipeID in
                store.planRecipe(recipeID, date: pick.id)
                reload()
            }
        }
    }

    private var weekSwitcher: some View {
        HStack {
            Button { weekOffset -= 1; reload() } label: {
                Image(systemName: "chevron.left").foregroundStyle(Color.moss)
            }
            Spacer()
            Text(weekLabel)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            Spacer()
            Button { weekOffset += 1; reload() } label: {
                Image(systemName: "chevron.right").foregroundStyle(Color.moss)
            }
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
        let ids = plannedByDay[key] ?? []
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(dayHeading(key))
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Spacer()
                    Button { pickingForDay = DayPick(id: key) } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.moss)
                    }
                    .accessibilityIdentifier("mealPlanner.add")
                }
                if ids.isEmpty {
                    Text("No meals planned")
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                } else {
                    ForEach(ids, id: \.self) { id in
                        // A dangling id (recipe since deleted) resolves to nothing and is dropped silently.
                        if let recipe = recipeByID[id] {
                            HStack {
                                Text(recipe.name)
                                    .font(.fernlet(.body))
                                    .foregroundStyle(Color.bark)
                                Spacer()
                                Button {
                                    store.unplanRecipe(id, date: key)
                                    reload()
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(Color.slate)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayHeading(_ key: String) -> String {
        guard let date = FernletDate.date(fromDayKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// Reloads the visible week's plan from the store. Past/future day rows aren't the observed
    /// `store.day`, so the view holds its own copy and refreshes it after every mutation.
    private func reload() {
        var next: [String: [UUID]] = [:]
        for key in weekDayKeys {
            next[key] = store.loadDay(for: key).plannedRecipeIDs
        }
        plannedByDay = next
    }
}

// MARK: - Recipe picker (assign to a day)

private struct RecipePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    var onPick: (UUID) -> Void

    @State private var searchText = ""

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
                                        onPick(recipe.id)
                                        dismiss()
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
}

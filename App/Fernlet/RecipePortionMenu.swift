//
//  RecipePortionMenu.swift
//  Fernlet
//
//  Ingredient-search round F4b (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.3 Rung A, §8 F4b;
//  owner decision 2026-09-30): the recipe editor's per-food amount menu. A bound ingredient's unit menu
//  lists what the food itself says one of something weighs — "1 medium (118 g)", "1 cup, sliced
//  (150 g)" — then a USDA typical size where the food states none (badged as an estimate the person
//  may correct), then the units that convert. Units that cannot convert are hidden. Every rule behind
//  the list lives in `RecipePortionPicker`; this file is the SwiftUI half.
//

import SwiftUI
import FernletDomainModel

#if canImport(UIKit)
import FernletUI
#endif

/// The unit menu of a recipe ingredient row bound to a catalog food: a `Menu` holding one inline
/// `Picker` over ``RecipePortionPicker/Choices``, sectioned into the food's own portions, the person's
/// own sizes, USDA typical sizes (estimates) and units.
///
/// The row holds a choice one of two ways (``ManualRecipeIngredientInput/portion``): a unit — including
/// a portion that is one of a unit, such as a banana's "medium" for "each", held as that unit so the
/// line saves exactly as a typed "1 each" always has — or a named portion, whose amount is saved as its
/// grams.
struct RecipePortionMenu: View {
    @Binding var ingredient: ManualRecipeIngredientInput
    let choices: RecipePortionPicker.Choices

    var body: some View {
        Menu {
            Picker("Unit", selection: selection) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.options) { option in
                            RecipePortionMenuItem(option: option).tag(option.id)
                        }
                    } header: {
                        if section.source == .typicalSize {
                            Text("USDA typical size, estimate")
                        } else if section.source == .personal {
                            Text("Your size")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                RecipePortionMenuLabel(option: currentOption)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.fernlet(.label))
            .foregroundStyle(Color.moss)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Unit")
        .accessibilityIdentifier("recipeIngredient.unit")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The options in menu order, plus the row's current choice when the menu no longer lists it (a
    /// unit a legacy line was typed in that cannot convert) so the picker always shows what is held.
    private var options: [RecipePortionOption] {
        guard let current = currentOption, !choices.options.contains(current) else { return choices.options }
        return choices.options + [current]
    }

    /// The options grouped by where their weight comes from, in menu order.
    private var sections: [RecipePortionMenuSection] {
        let order: [RecipePortionOption.Source] = [.usdaPortion, .personal, .typicalSize, .unit]
        return order.compactMap { source in
            let matching = options.filter { $0.source == source }
            return matching.isEmpty ? nil : RecipePortionMenuSection(source: source, options: matching)
        }
    }

    /// The option the row holds: its named portion, else the option shown for its unit.
    private var currentOption: RecipePortionOption? {
        if let portion = ingredient.portion { return portion }
        guard let unit = RecipeUnit.normalized(ingredient.unit) else { return nil }
        return choices.option(for: unit) ?? RecipePortionOption(unit: unit)
    }

    private var selection: Binding<String> {
        Binding(
            get: { currentOption?.id ?? "" },
            set: { choose($0) }
        )
    }

    /// Applies a menu pick: a unit, or a portion that is one of a unit, is held as that unit; any other
    /// named portion is held as the portion (its amount counted in it, saved as grams). The amount is
    /// carried over by ``RecipePortionPicker/quantity(afterChoosing:standingIn:from:unit:portion:)``.
    private func choose(_ id: String) {
        guard let option = options.first(where: { $0.id == id }), option != currentOption else { return }
        let standIn = choices.unit(standingIn: option)
        ingredient.quantity = RecipePortionPicker.quantity(
            afterChoosing: option, standingIn: standIn, from: ingredient.quantity,
            unit: ingredient.unit, portion: ingredient.portion
        )
        if let unit = option.unit ?? standIn {
            ingredient.portion = nil
            ingredient.unit = unit.rawValue
        } else {
            ingredient.portion = option
            ingredient.unit = RecipeUnit.gram.rawValue
        }
    }
}

/// One section of ``RecipePortionMenu``: the options whose weight comes from one source.
struct RecipePortionMenuSection: Identifiable {
    /// Where the section's weights come from.
    let source: RecipePortionOption.Source
    /// The section's options, in menu order.
    let options: [RecipePortionOption]

    var id: RecipePortionOption.Source { source }
}

/// One menu item: a unit by its name, a named portion as one of it with its grams — "1 medium
/// (118 g)". The portion words are USDA's (or a curated token), shown verbatim like a food name.
struct RecipePortionMenuItem: View {
    let option: RecipePortionOption

    var body: some View {
        if let unit = option.unit {
            Text(unit.label)
        } else if let grams = option.gramsPerOne {
            Text("1 \(option.label) (\(grams, format: .number.precision(.fractionLength(0...1))) g)")
        }
    }
}

/// The menu's closed label: the unit's name, or the portion's words ("medium", "cup, sliced").
struct RecipePortionMenuLabel: View {
    let option: RecipePortionOption?

    var body: some View {
        if let unit = option?.unit {
            Text(unit.label)
        } else if let option {
            Text(verbatim: option.label)
        } else {
            Text("Unit")
        }
    }
}

/// Beneath the menu when the row is counted in a USDA typical size or the person's own size: the badge
/// that says which, and the grams one weighs, which the person may correct. A corrected typical size
/// becomes the person's own size for that food, remembered when the recipe is saved
/// (``RecipePortionGramsMemory``).
struct RecipePortionGramsRow: View {
    @Binding var ingredient: ManualRecipeIngredientInput

    var body: some View {
        if let portion = ingredient.portion, portion.hasEditableGrams {
            VStack(alignment: .leading, spacing: 6) {
                Text(portion.isEstimate ? "USDA typical size, estimate" : "Your size")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.parchment, in: Capsule())
                    .accessibilityIdentifier("recipeIngredient.portionBadge")
                HStack(spacing: 8) {
                    Text("1 \(portion.label) =")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.bark)
                    TextField("Grams", value: grams, format: .number)
                        .keyboardType(.decimalPad)
                        .font(.fernlet(.label))
                        .frame(maxWidth: 80)
                        .accessibilityLabel("Grams in one \(portion.label)")
                        .accessibilityIdentifier("recipeIngredient.portionGrams")
                    Text("g")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                }
            }
        }
    }

    /// The grams one weighs; an edit that changes them makes the portion the person's own size. A
    /// value that is not a usable weight is ignored.
    private var grams: Binding<Double> {
        Binding(
            get: { ingredient.portion?.gramsPerOne ?? 0 },
            set: { newValue in
                guard let portion = ingredient.portion, newValue.isFinite, newValue > 0,
                      newValue <= RecipeConversionLimits.maxGrams,
                      abs(newValue - (portion.gramsPerOne ?? 0)) > 0.0001 else { return }
                ingredient.portion = RecipePortionOption(source: .personal, label: portion.label,
                                                         gramsPerOne: newValue, dimension: portion.dimension)
            }
        )
    }
}

/// The "Counted as …" caption under a recipe line whose amount is saved as grams beside a household
/// choice (F4a, F4b): "Counted as 2 eggs (100.6 g)", "Counted as 2 cups, sliced (300 g)", "Counted as 2
/// medium (236 g)". The noun agrees with the count through automatic grammar agreement
/// (`^[…](inflect: true)`) where the label ends in one; a size word stays as it is — "2 medium", never
/// "2 mediums" (``RecipeHouseholdMeasure/headTakesPlural``).
enum RecipeHouseholdCaption {
    /// The caption for a SAVED line (``RecipeIngredient/savingHouseholdAsGrams(using:)``), or nil when
    /// the line is not grams beside a household choice.
    static func caption(for line: RecipeIngredient, locale: Locale = .autoupdatingCurrent) -> AttributedString? {
        guard let measure = line.householdMeasure, measure.isValid, RecipeUnit.normalized(line.unit) == .gram,
              line.quantity.isFinite, line.quantity > 0 else { return nil }
        let count = line.quantity / measure.gramsPerUnit
        let grams = line.quantity
        let head = measure.labelHead
        let qualifier = measure.labelQualifier
        guard measure.headTakesPlural else {
            return AttributedString(
                localized: "Counted as \(count, format: .number.precision(.fractionLength(0...2))) \(head)\(qualifier) (\(grams, format: .number.precision(.fractionLength(0...1))) g)",
                locale: locale
            )
        }
        return AttributedString(
            localized: "Counted as ^[\(count, format: .number.precision(.fractionLength(0...2))) \(head)](inflect: true)\(qualifier) (\(grams, format: .number.precision(.fractionLength(0...1))) g)",
            locale: locale
        )
    }
}

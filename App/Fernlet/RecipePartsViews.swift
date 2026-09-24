//
//  RecipePartsViews.swift
//  Fernlet
//
//  Multipart recipes (owner decision 2026-09-24): the read-side views that group a recipe's
//  ingredients and steps under its parts ("Lemon dressing", then "Salad") on the recipe detail and in
//  cooking mode's mise en place. The grouping itself is the domain's single rule,
//  `RecipeDefinition.resolvedComponents`; these views only lay it out. A one-part recipe never reaches
//  them: its screens render exactly as before.
//

import SwiftUI
import FernletDomainModel
#if canImport(UIKit)
import FernletUI
#endif

/// Groups what a screen DISPLAYS under the recipe's parts.
///
/// The detail and mise en place may show scaled copies of the ingredients ("cook for 6"). Scaling keeps
/// every ingredient's `id`, so each part's stored rows are swapped for the displayed copy with the same
/// id, and the grouping never has to be recomputed from scaled values.
enum RecipePartsLayout {
    /// The recipe's parts, with each ingredient replaced by its displayed copy when there is one.
    static func parts(of recipe: RecipeDefinition, displaying displayed: [RecipeIngredient]) -> [ResolvedRecipeComponent] {
        let displayedByID = Dictionary(displayed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return recipe.resolvedComponents.map { part in
            var shown = part
            shown.ingredients = part.ingredients.map { displayedByID[$0.id] ?? $0 }
            return shown
        }
    }
}

#if canImport(UIKit)

/// The heading over one part of a multipart recipe: "PART 1 OF 2" above the part's name.
///
/// One accessibility element that VoiceOver reads as a heading ("Part 1 of 2: Lemon dressing"), so a
/// cook can jump between parts with the Headings rotor.
struct RecipePartHeader: View {
    let name: String
    /// 1-based position of this part in making order.
    let position: Int
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Part \(position) of \(count)")
                .font(.fernlet(.labelSmall))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.slate)
            Text(verbatim: name)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Part \(position) of \(count): \(name)"))
        .accessibilityAddTraits(.isHeader)
    }
}

/// A multipart recipe's ingredient rows, each part's under its ``RecipePartHeader``.
///
/// A part with no ingredients (a steps-only "Assemble" part) is skipped here and still counted in the
/// "Part N of M" numbering, so the numbers match the steps list.
struct RecipePartsIngredientList<Row: View>: View {
    let parts: [ResolvedRecipeComponent]
    @ViewBuilder let row: (RecipeIngredient) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                if !part.ingredients.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        RecipePartHeader(name: part.name ?? "", position: index + 1, count: parts.count)
                        ForEach(part.ingredients) { ingredient in
                            row(ingredient)
                        }
                    }
                }
            }
        }
    }
}

/// A multipart recipe's steps, each part's under its ``RecipePartHeader`` with numbering restarting at
/// 1 in every part ("make the dressing: 1, 2; assemble the salad: 1, 2, 3").
///
/// A part with no steps (a dressing that is just a list of ingredients) is skipped here and still
/// counted in the "Part N of M" numbering.
struct RecipePartsStepList<Row: View>: View {
    let parts: [ResolvedRecipeComponent]
    /// Builds one row from the step's 1-based number within its part, and the step.
    @ViewBuilder let row: (Int, RecipeStep) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                if !part.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        RecipePartHeader(name: part.name ?? "", position: index + 1, count: parts.count)
                        ForEach(Array(part.steps.enumerated()), id: \.element.id) { stepIndex, step in
                            row(stepIndex + 1, step)
                        }
                    }
                }
            }
        }
    }
}

#endif

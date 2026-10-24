import FernletDomainModel
import FernletUI
import SwiftUI

/// One recipe as a card in the recipe book (`b2-recipe-book`, draft 3, approved 2026-10-24): the photo
/// on top when there is one (182 pt, the card the same size), the name, "2 servings · 3 ingredients",
/// a two-line preview of the notes, then one row of coloured macro tags, a small Log and the pixel
/// Share button. The Food page's recipe cards (`b2-food-rest`) are drawn the same way.
///
/// `summary` is the tappable top half (a `NavigationLink` to the recipe page); the bottom row acts in
/// place. At widths where the row doesn't fit (calories on, Spanish, larger text) the tags take their
/// own line above Log and Share.
struct RecipeBookCard<Summary: View>: View {
    /// The per-serving macros, or nil for a web recipe whose page carried none.
    let macros: MacroTotals?
    var showsCalories = false
    /// The web import's estimate caveat under the tags, when it has one.
    var estimateNote: WebImportEstimateNote?
    let onLog: (MealType) -> Void
    /// Opens recipe sharing; nil hides Share (a saved product).
    var onShare: (() -> Void)?
    @ViewBuilder let summary: () -> Summary

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                summary()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        tags
                        Spacer(minLength: 6)
                        controls
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        tags
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            controls
                        }
                    }
                }
                if let estimateNote { estimateNote }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var tags: some View {
        if let macros {
            RecipeMacroTags(macros: macros, showsCalories: showsCalories)
        }
    }

    /// The small Log menu and the framed Share icon (owner's draft-2 note: "a smaller Log"; its touch
    /// area stays 44 pt).
    private var controls: some View {
        HStack(spacing: 6) {
            RecipeLogMenu(title: Text("Log"), spokenLabel: Text("Log recipe as meal"), identifier: "recipeBook.log",
                          onLog: onLog)
                .fixedSize()
            if let onShare {
                RecipeIconButton(sprite: WorldSprites.share, label: Text("Share recipe"), action: onShare)
            }
        }
    }
}

/// The tappable top half of a recipe card: the photo banner, the name, the servings and ingredient
/// count (or a web recipe's source), and a two-line preview of the notes.
struct RecipeCardSummary: View {
    let recipe: RecipeDefinition
    /// Reads the recipe's sealed photo; nil skips the banner.
    var loadPhoto: (() -> Data?)?
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let loadPhoto {
                RecipeCardPhoto(recipeID: recipe.id, load: loadPhoto)
                    .padding(.bottom, 4)
            }
            Text(verbatim: recipe.name)
                .font(RecipeType.cardTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            detailLine
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(look?.dim ?? Color.slate)
            if !recipe.notes.isEmpty {
                Text(verbatim: StoredFoodNote.displayedRecipeNotes(recipe.notes))
                    .font(FernletFramedFont.body)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .multilineTextAlignment(.leading)
                    // A two-line preview, except at accessibility sizes, where two lines held only
                    // the first few words.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "2 servings · 3 ingredients"; a web recipe counts its ingredient lines and names its source.
    private var detailLine: Text {
        let count = recipe.webImport?.ingredientLines.count ?? recipe.ingredients.count
        let line = Text("^[\(recipe.servings) serving](inflect: true) · ^[\(count) ingredient](inflect: true)")
        guard let host = recipe.webImport?.sourceURL?.host() else { return line }
        return Text("\(line) · \(host)")
    }
}

/// A product saved from a web page, as a card in the recipe book's "Imported products": its name, its
/// brand or source, the serving, the macro tags and Log.
struct ImportedProductCard: View {
    let product: FoodItem
    let onLog: (MealType) -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        RecipeBookCard(macros: MacroTotals(protein: product.macros.protein, carbs: product.macros.carbs,
                                           fat: product.macros.fat),
                       onLog: onLog) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: product.name)
                    .font(RecipeType.cardTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fixedSize(horizontal: false, vertical: true)
                sourceLine
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .lineLimit(1)
                if let servingDescription = product.servingDescription, !servingDescription.isEmpty {
                    Text("Serving: \(servingDescription)")
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// The brand or source host as data, else a localized stand-in.
    private var sourceLine: Text {
        if let source = product.brandSource ?? product.sourceURL?.host() { return Text(verbatim: source) }
        return Text("Saved web product")
    }
}

/// The recipe book's three equal secondaries (`b2-recipe-book`: "+ Create", the planner's book and the
/// list's box), small framed buttons with pixel icons, stacked at accessibility sizes.
struct RecipeBookToolButtonLabel: View {
    let title: Text
    let sprite: WorldSprite?
    var usesPlusIcon = false

    var body: some View {
        HStack(spacing: 7) {
            if usesPlusIcon {
                FernletIcon(.plus, scale: 2)
            } else if let sprite {
                WorldSpriteView(sprite: sprite, scale: 2)
            }
            title
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

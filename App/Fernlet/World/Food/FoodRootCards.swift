import FernletDomainModel
import FernletUI
import SwiftUI

/// The Food screens' own type sizes, where the approved Food drafts draw smaller than the kit's
/// general ones (`FernletFramedFont`).
nonisolated enum FoodFont {
    /// A meal's or recipe's name on its Food card (`b1-frame-root`, `b2-food-rest`): Fraunces 19, so
    /// "Greek yogurt with berries" holds one line beside its photo and ✕.
    static let cardTitle = Font.custom(FernletFontName.frauncesSemiBold, size: 19, relativeTo: .title3)
    /// A row's name in the kit's semibold (`.sl b`): DM Sans Medium 16.5 at semibold. A weight on the
    /// regular face draws regular; the medium face takes it.
    static let rowName = Font.custom(FernletFontName.dmSansMedium, size: 16.5, relativeTo: .body).weight(.semibold)
    /// A row's figure in bold (a value at a row's end).
    static let rowNameBold = Font.custom(FernletFontName.dmSansMedium, size: 16.5, relativeTo: .body).weight(.bold)
    /// A small strong line (a group's caption, "Probably not what you meant"): 13.5 semibold.
    static let noteStrong = Font.custom(FernletFontName.dmSansMedium, size: 13.5, relativeTo: .footnote).weight(.semibold)
    /// A typed figure in bold (an amount, a target): 16 bold.
    static let fieldBold = Font.custom(FernletFontName.dmSansMedium, size: 16, relativeTo: .body).weight(.bold)
    /// A typed figure a little lighter (a matched item's amount): 16 semibold.
    static let fieldStrong = Font.custom(FernletFontName.dmSansMedium, size: 16, relativeTo: .body).weight(.semibold)
}

/// The Food panel's one primary action (`b1-frame-root` draft 3): "+ Log a meal" in moss across the page,
/// under the panel's subtitle. It opens the Log meal sheet; it replaced the small "+ meal" header pill.
struct FoodLogMealButton: View {
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FernletIcon(.plus, scale: 2, tint: look?.onAccent ?? Color.onMoss)
                Text("Log a meal")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.primary))
        .accessibilityIdentifier("food.logMeal")
    }
}

/// A recipe card on the Food panel, below the fold (`b2-food-rest`, approved 2026-10-23, redrawn for the
/// recipe-book note): the name in Fraunces, "4 servings · 4 ingredients", the notes' first lines, then
/// the per-serving macros as coloured tags with a small Log and a framed share button at the end.
///
/// Tapping the summary pushes the recipe's page (the caller's `NavigationLink` value). Log is one menu of
/// meal slots, the same choice the meal sheet's dropdown offers; a choice logs at once.
///
/// It draws a manual recipe and a saved web recipe alike: a web recipe adds its source's host and the
/// first ingredient lines, and shows tags only when its import carried macros.
struct FoodRootRecipeCard: View {
    let recipe: RecipeDefinition
    let isSaved: Bool
    /// The per-serving macros, or nil when a web import carried none.
    let perServing: Macros?
    /// Per-serving calories, when Show calories is on.
    var calories: Int? = nil
    let onLog: (MealType) -> Void
    let onShare: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink(value: FoodRoute.recipeDetail(id: recipe.id, isSaved: isSaved)) {
                    FoodRecipeCardSummary(recipe: recipe, isSaved: isSaved)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                controls
            }
        }
    }

    /// The tags with Log and Share at the end; at the largest sizes the buttons take their own line.
    @ViewBuilder private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                tags
                HStack(spacing: 10) { Spacer(minLength: 0); buttons }
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                tags
                Spacer(minLength: 0)
                buttons
            }
        }
    }

    @ViewBuilder private var tags: some View {
        if let perServing {
            FoodMacroTagRow(macros: perServing, calories: calories)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            FoodRecipeLogMenu(onLog: onLog)
            FoodShareIconButton(action: onShare)
        }
    }
}

/// The text half of ``FoodRootRecipeCard``: name, servings and ingredients, the notes' first lines, and
/// for a web recipe its source host and first ingredient lines.
struct FoodRecipeCardSummary: View {
    let recipe: RecipeDefinition
    let isSaved: Bool
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recipe.name)
                .font(FoodFont.cardTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .fernletWrappingText()
            countsLine
            if let host = recipe.webImport?.sourceURL.map({ $0.host() ?? $0.absoluteString }) {
                Text(verbatim: host).font(FernletFramedFont.note).foregroundStyle(dim).lineLimit(1)
            }
            if !recipe.notes.isEmpty {
                Text(verbatim: StoredFoodNote.displayedRecipeNotes(recipe.notes))
                    .font(FernletFramedFont.body)
                    .foregroundStyle(dim)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            if isSaved { webLines }
        }
    }

    private var dim: Color { look?.dim ?? Color.slate }

    /// "4 servings · 4 ingredients" (a web recipe has no structured ingredients, so only its servings).
    private var countsLine: some View {
        FlowLayout(spacing: 4) {
            Text("^[\(recipe.servings) serving](inflect: true)")
            if !isSaved {
                Text(verbatim: "\u{00B7}").accessibilityHidden(true)
                Text("^[\(recipe.ingredients.count) ingredient](inflect: true)")
            }
        }
        .font(FernletFramedFont.body)
        .foregroundStyle(dim)
    }

    /// A web recipe's first four ingredient lines and its estimate caveat.
    @ViewBuilder private var webLines: some View {
        let lines = recipe.webImport?.ingredientLines ?? []
        if !lines.isEmpty {
            Text(verbatim: lines.prefix(4).joined(separator: " | "))
                .font(FernletFramedFont.note)
                .foregroundStyle(dim)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        }
        WebImportEstimateNote(uncountedLines: recipe.webImport?.uncountedIngredientLines,
                              estimatedLines: recipe.webImport?.estimatedIngredientLines)
    }
}

/// A recipe card's small Log (`.pxbtn.sm`): one tap opens the meal slots, and a choice logs the recipe
/// there. It replaced the inline row of six slot chips (the owner's "meal type is one dropdown").
struct FoodRecipeLogMenu: View {
    let onLog: (MealType) -> Void

    var body: some View {
        Menu {
            ForEach(MealType.allCases) { type in
                Button { onLog(type) } label: { Text(verbatim: type.displayName) }
            }
        } label: {
            Text("Log")
        }
        .menuStyle(.button)
        .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
        .accessibilityLabel("Log recipe as meal")
        .accessibilityIdentifier("food.recipe.log")
    }
}

/// The framed share button on a recipe card (`b2-recipe-book` draft 3's new share icon): the pixel
/// tray-and-arrow on raised paper in an ink frame, 44 pt.
struct FoodShareIconButton: View {
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            Group {
                if let look {
                    FernletIconTile(size: 44, fill: look.raised) {
                        WorldSpriteView(sprite: FoodSprites.share, scale: 2)
                    }
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .frame(width: 44, height: 44)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share recipe")
    }
}

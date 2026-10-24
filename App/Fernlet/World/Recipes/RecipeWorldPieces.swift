import FernletDomainModel
import FernletUI
import SwiftUI
import UIKit

// The small pieces the recipe screens share in the one design language (World Review Batches 2 and 3,
// approved 2026-10-23/24): coloured macro tags, framed icon buttons and tiles, the wooden Start cooking
// button, the meal-type Log menu, an ingredient's compact row and a step's numbered badge. Each reads the
// framed look and falls back to today's colours without it.

/// Protein, carbs and fat as three tags (`b2-recipe-book` draft 3, the owner's note "add some color"):
/// the Food screens' own ``FoodMacroTag`` (one tag for both lanes: a framed square in the macro's colour
/// on a light tint of it, the text in the page's ink so it keeps its contrast). Calories follow as a
/// plain framed tag when the person has them on.
struct RecipeMacroTags: View {
    let macros: MacroTotals
    var showsCalories = false
    @Environment(\.fernletFramedLook) private var look

    /// One row of tags, or a column where a row doesn't fit (larger text).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { tags }
            VStack(alignment: .leading, spacing: 5) { tags }
        }
    }

    @ViewBuilder private var tags: some View {
        ForEach(FoodMacroKind.allCases, id: \.self) { kind in
            FoodMacroTag(kind: kind, grams: grams(of: kind))
        }
        if showsCalories {
            calorieTag
        }
    }

    /// This recipe's grams of `kind`.
    private func grams(of kind: FoodMacroKind) -> Int {
        switch kind {
        case .protein: macros.protein
        case .carbs: macros.carbs
        case .fat: macros.fat
        }
    }

    /// The calories as a plain tag (`.mtag3` without a colour square) in a 2-pt ink frame.
    private var calorieTag: some View {
        let ink = look?.ink ?? Color.bark
        let shape = RoundedRectangle(cornerRadius: 7)
        return Text("\(macros.calories) cal")
            .font(RecipeType.tag)
            .foregroundStyle(look?.text ?? Color.bark)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(look?.raised ?? Color.cream, in: shape)
            .overlay(shape.strokeBorder(ink, lineWidth: FernletFramedLook.frameWidth))
    }
}

extension View {
    /// A recipe sheet's frame, applied at its PRESENTER (the presenter's presentation modifiers win
    /// over anything inside the sheet): the World sheet (`b1-frame-sheet`: full height, paper, the
    /// wooden grabber) with the UX anchor, moss tint and keyboard Done that the app's other sheets get
    /// from `fernletSheetChrome`. Never also apply ``SwiftUI/View/fernletSheet()`` inside the sheet.
    func recipeSheetFrame(anchor: String) -> some View {
        uxScreenAnchor(anchor)
            .fernletSheet()
            .tint(Color.moss)
            .keyboardDoneToolbar()
    }
}

/// The recipe editor's title: pushed (Create recipe › Manual entry) it hands "New recipe" or "Edit
/// recipe" to the wooden plate (`b1-frame-push`); presented, its draft guard's sheet header carries it
/// and the page's own bar stays untitled.
struct RecipeEditorPageTitle: ViewModifier {
    let isPushed: Bool
    let isNew: Bool

    func body(content: Content) -> some View {
        if !isPushed {
            content.navigationTitle("")
        } else if isNew {
            content.fernletPushedPage("New recipe")
        } else {
            content.fernletPushedPage("Edit recipe")
        }
    }
}

/// The recipe screens' type sizes that the kit draws beyond ``FernletFramedFont``'s set.
nonisolated enum RecipeType {
    /// A macro tag's figure (`.mtag3`): DM Sans semibold 13.
    static let tag = Font.custom(FernletFontName.dmSansBold, size: 13, relativeTo: .footnote)
    /// A recipe card's title in the book (`.ac-t` at 20).
    static let cardTitle = Font.custom(FernletFontName.frauncesSemiBold, size: 20, relativeTo: .title3)
    /// The recipe page's title beside its photo (25).
    static let pageTitle = Font.custom(FernletFontName.frauncesSemiBold, size: 25, relativeTo: .title2)
    /// A big Fraunces line: the cooking step (30) and Mise en place / All done (`.bigt`, 34).
    static func display(_ size: CGFloat) -> Font {
        Font.custom(FernletFontName.frauncesSemiBold, size: size, relativeTo: .largeTitle)
    }
    /// An ingredient's name in its row (`.ingr .in`): DM Sans semibold 15.
    static let ingredientName = Font.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .body)
    /// An ingredient's amount (`.ingr .iq`): DM Sans 14.
    static let ingredientAmount = Font.custom(FernletFontName.dmSans, size: 14, relativeTo: .subheadline)
    /// The wooden Start cooking button (17 bold).
    static let woodButton = Font.custom(FernletFontName.dmSansBold, size: 17, relativeTo: .body)
}

/// A pixel sprite on a framed tile of raised paper (`.icci`, `.ingr .is`): the art centred in a
/// `size`-point square with a 2-pt ink frame. Decorative; the control around it carries the name.
/// Inside a section it sits bare (the frame rule), unless it is a button's face (`isControl`).
struct RecipeSpriteTile: View {
    let sprite: WorldSprite
    var size: CGFloat = 42
    var scale: CGFloat = 2
    var fill: Color? = nil
    /// One colour for every pixel (the white bowl drawn in the ink token); nil keeps the sprite's own.
    var tint: Color? = nil
    /// A button's face keeps its frame inside a section, as every control does.
    var isControl = false

    var body: some View {
        WorldSpriteView(sprite: sprite, scale: scale, tint: tint)
            .frame(width: size, height: size)
            .fernletFrameRulePiece(isControl ? .button : .iconSquare, fill: fill, cornerRadius: size < 34 ? 6 : 9)
            .accessibilityHidden(true)
    }
}

/// A framed pixel-icon button (Share on a recipe card, a planner day's +, a swap): the sprite on a
/// raised tile, its touch area grown to 44 pt, named by `label` for VoiceOver and Voice Control.
struct RecipeIconButton: View {
    let sprite: WorldSprite
    let label: Text
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RecipeSpriteTile(sprite: sprite, size: size, isControl: true)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The wooden Start cooking button (`b2-recipe-detail` draft 3, `b3-cook-mise`): full width, wood in a
/// 2-pt ink frame with a light top edge and a darker bottom band, the bowl sprite and the word in bark.
/// Wood is the navigation material, so this is the one wooden action: it leaves the page for cooking.
struct RecipeWoodButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return HStack(spacing: 10) {
            WorldSpriteView(sprite: WorldSprites.bowlInk, scale: 3)
            configuration.label
                .font(RecipeType.woodButton)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(WorldPalette.bark)
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.vertical, 4)
        .background(WorldPalette.wood, in: shape)
        .overlay(alignment: .top) { WorldPalette.woodHigh.frame(height: 3).padding(.top, 2) }
        .overlay(alignment: .bottom) { WorldPalette.woodLow.frame(height: 4).padding(.bottom, 2) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
        .background { shape.fill(WorldPalette.ink.opacity(0.3)).offset(y: 3) }
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// "Log" as one menu of meal types (owner, 2026-10-24: "Meal type is one dropdown, on every meal
/// screen"), replacing the row of chips a tap used to open. Choosing a meal logs at once.
struct RecipeLogMenu: View {
    /// The button's word ("Log", "Log it").
    let title: Text
    /// Its spoken name, when it says more than the word.
    var spokenLabel: Text?
    var size: FernletActionPillSize = .small
    var showsPlus = false
    /// Spread the button across its slot (the recipe page's three equal secondaries).
    var fillsWidth = false
    var identifier: String?
    let onLog: (MealType) -> Void

    var body: some View {
        Menu {
            ForEach(MealType.allCases) { mealType in
                Button { onLog(mealType) } label: { Text(verbatim: mealType.displayName) }
            }
        } label: {
            HStack(spacing: 7) {
                if showsPlus { FernletIcon(.plus, scale: 2) }
                title.lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .menuStyle(.button)
        .buttonStyle(ActionPillButtonStyle(.secondary, size: size))
        .accessibilityLabel(spokenLabel ?? title)
        .accessibilityInputLabels([title])
        .accessibilityIdentifier(identifier ?? "recipe.logMenu")
    }
}

/// One ingredient as a compact row (`.ingr`, `b2-recipe-detail` draft 3: "a recipe with 30 items is a
/// list you scroll"): a 30-pt framed pixel icon, the name, the amount, and an optional trailing control
/// (the swap). A dotted rule sits above every row but the first.
struct RecipeIngredientRow<Trailing: View>: View {
    let name: String
    let amount: String
    /// The name the icon is chosen from (the food's own name, before any display decoration).
    var artName: String?
    var showsRule = true
    var note: AnyView?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsRule { FernletDottedRule() }
            HStack(alignment: .center, spacing: 10) {
                RecipeSpriteTile(sprite: RecipeIngredientArt.sprite(forIngredientNamed: artName ?? name), size: 30)
                lines
                trailing()
            }
            .padding(.vertical, 5)
        }
    }

    /// The name and amount side by side, stacked at accessibility sizes so neither breaks mid-word.
    @ViewBuilder private var lines: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                             : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(RecipeType.ingredientName)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fixedSize(horizontal: false, vertical: true)
                if let note { note }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: amount)
                .font(RecipeType.ingredientAmount)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fixedSize(horizontal: !stacked, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

extension RecipeIngredientRow where Trailing == EmptyView {
    /// A row with no trailing control (cooking mode's mise en place).
    init(name: String, amount: String, artName: String? = nil, showsRule: Bool = true) {
        self.init(name: name, amount: amount, artName: artName, showsRule: showsRule, note: nil) { EmptyView() }
    }
}

/// A step's number on a small wooden square (`b3-recipe-notes`): 26 pt, bark on wood in a 2-pt ink frame,
/// or wood alone inside a section (the frame rule, `ref-frames-notes`).
struct RecipeStepBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(FernletFramedFont.tag)
            .foregroundStyle(WorldPalette.bark)
            .frame(minWidth: 26, minHeight: 26)
            .fernletFrameRulePiece(.tile, fill: WorldPalette.wood, cornerRadius: 6)
            .accessibilityHidden(true)
    }
}

/// One titled card of a recipe review sheet (`b3-recipe-incoming`, `b3-messages-recipe`): the framed
/// section label, then its content, full width.
struct RecipeReviewCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(title)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A framed pixel checkbox (`.cbx`, `b2-shopping`): 24 pt of raised paper in a 2-pt ink frame, filled
/// with the accent and a white pixel check when on. Decorative: its row carries the selected trait.
struct ShoppingCheckbox: View {
    let isOn: Bool
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        ZStack {
            shape.fill(isOn ? (look?.accent ?? Color.moss) : (look?.raised ?? Color.cream))
            if isOn { FernletIcon(.check, scale: 2, tint: look?.onAccent ?? Color.white) }
        }
        .frame(width: 24, height: 24)
        .overlay(shape.strokeBorder(look?.ink ?? Color.bark, lineWidth: FernletFramedLook.frameWidth))
        .accessibilityHidden(true)
    }
}

/// A recipe's photo as a small framed square (`b2-planner` draft 2: a planned meal's photo or tile),
/// loaded once as a thumbnail; a recipe without one shows the pixel bowl on a framed tile.
struct RecipePhotoThumb: View {
    let recipeID: UUID
    let load: () -> Data?
    var size: CGFloat = 44
    @State private var image: UIImage?
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityIgnoresInvertColors()
                    .frame(width: size, height: size)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(look?.ink ?? Color.clear, lineWidth: 2))
            } else {
                RecipeSpriteTile(sprite: WorldSprites.bowl, size: size, tint: WorldPalette.iconInk)
            }
        }
        .accessibilityHidden(true)
        .task(id: recipeID) {
            guard let data = load() else { image = nil; return }
            image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: size * 3, height: size * 3))
        }
    }
}

/// A recipe's sealed photo as a card's banner (`b2-recipe-book` draft 3: "a bigger photo in the same
/// card", 182 pt): loaded once per card as a thumbnail, never the full image, so a long book stays
/// light. Draws nothing for a recipe without a photo.
struct RecipeCardPhoto: View {
    let recipeID: UUID
    let load: () -> Data?
    var height: CGFloat = 182
    @State private var image: UIImage?
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityIgnoresInvertColors()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(look?.ink ?? Color.clear, lineWidth: 2))
                    .accessibilityHidden(true)
            }
        }
        .task(id: recipeID) {
            guard let data = load() else { image = nil; return }
            image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: 900, height: 600))
        }
    }
}

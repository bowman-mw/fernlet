import FernletDomainModel
import FernletUI
import SwiftUI

/// The three macros, in the order every Food screen draws them (protein, carbs, fat), each with its one
/// data colour (`WorldPalette.protein`, `.carbs`, `.fat`: moss, gold and terracotta, the macro card's
/// bars). A display-only enum: nothing persists it.
nonisolated enum FoodMacroKind: CaseIterable, Sendable {
    case protein, carbs, fat

    /// The macro's data colour.
    var colour: Color {
        switch self {
        case .protein: WorldPalette.protein
        case .carbs: WorldPalette.carbs
        case .fat: WorldPalette.fat
        }
    }

    /// How strongly a tag's fill takes the colour (the kit's `.mtag3` fills: a fifth for protein and fat,
    /// a quarter for the lighter gold).
    var tagFillOpacity: Double {
        self == .carbs ? 0.24 : 0.2
    }

    /// The grams of this macro in `macros`.
    func grams(in macros: Macros) -> Int {
        switch self {
        case .protein: macros.protein
        case .carbs: macros.carbs
        case .fat: macros.fat
        }
    }
}

/// One coloured macro tag (`.mtag3`, designs `b2-food-rest` and `b2-recipe-book` draft 3, approved
/// 2026-10-24; the recipe screens draw it too, through ``RecipeMacroTags``): a small framed square of the macro's colour, then "P 28g", on that colour at a fifth in a
/// 2-pt ink frame. The word stays the page's ink, so it reads in light and dark alike.
///
/// The words are today's keys ("P %lldg", "C %lldg", "F %lldg"), so the macro letters follow the
/// language (Spanish draws P, C, G). Without the framed look it is today's plain figure.
struct FoodMacroTag: View {
    let kind: FoodMacroKind
    let grams: Int
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if let look {
            framed(look)
        } else {
            label.font(.fernlet(.stat)).foregroundStyle(kind == .protein ? Color.moss : Color.slate)
        }
    }

    /// The figure itself, through the shipped macro keys.
    private var label: Text {
        switch kind {
        case .protein: Text("P \(grams)g")
        case .carbs: Text("C \(grams)g")
        case .fat: Text("F \(grams)g")
        }
    }

    private func framed(_ look: FernletFramedLook) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        return HStack(spacing: 5) {
            kind.colour
                .frame(width: 8, height: 8)
                .overlay(Rectangle().strokeBorder(look.ink, lineWidth: 1.5))
                .accessibilityHidden(true)
            label
                .font(FernletFramedFont.chip)
                .foregroundStyle(look.text)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 8))
        // The colour at a fifth over the card's paper, so the tint reads the same on any card.
        .background(kind.colour.opacity(kind.tagFillOpacity), in: shape)
        .background(look.paper, in: shape)
        .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
    }
}

/// A row of the three macro tags (and the calories, when Show calories is on), wrapping onto a second
/// line when the row runs out of width (the largest text sizes, a long Spanish figure). One element to
/// VoiceOver, read as its figures.
///
/// `wraps: false` keeps the tags on one line at their own width, for a row that sits beside other
/// content (a total, a stepper). (`FlowLayout` now reports its one row's width when offered no width,
/// so a `.fixedSize()` wrapping row no longer traps; it simply never wraps.)
struct FoodMacroTagRow: View {
    let macros: Macros
    /// Calories to draw after the tags; nil when Show calories is off.
    var calories: Int? = nil
    /// False draws the tags on one line at their own width.
    var wraps = true

    var body: some View {
        Group {
            if wraps {
                FlowLayout(spacing: 6) { FoodMacroTagItems(macros: macros, calories: calories) }
            } else {
                HStack(spacing: 6) { FoodMacroTagItems(macros: macros, calories: calories) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The macro tags (and the calories) as loose views, for a layout that holds more beside them (a meal
/// card's provenance tag): each one is its own subview of the enclosing layout.
struct FoodMacroTagItems: View {
    let macros: Macros
    /// Calories to draw after the tags; nil when Show calories is off.
    var calories: Int? = nil
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        ForEach(FoodMacroKind.allCases, id: \.self) { kind in
            FoodMacroTag(kind: kind, grams: kind.grams(in: macros))
        }
        if let calories {
            Text("\(calories) cal")
                .font(look == nil ? .fernlet(.stat) : FernletFramedFont.chip)
                .foregroundStyle(look?.dim ?? Color.slate)
                .padding(.vertical, 4)
        }
    }
}

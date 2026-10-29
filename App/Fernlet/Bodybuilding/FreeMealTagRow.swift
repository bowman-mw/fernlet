import FernletUI
import SwiftUI

/// The small F that marks a free meal (World bodybuilding spec §6, `bb-free`; the mockup's `.bbfree`):
/// a gold square with a dark F in a brown frame. Its colours are fixed in both modes (dark brown on gold
/// is well past AA either way). The Day calendar draws the same mark in a cell; it is decoration to
/// VoiceOver, since the element carrying it says "Free meal".
struct FreeMealMark: View {
    /// The square's side, 14 pt at the default size, growing with the text.
    @ScaledMetric(relativeTo: .caption2) private var side: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.28)
        Text(verbatim: "F")
            .font(.custom(FernletFontName.dmSansBold, size: 10, relativeTo: .caption2))
            .foregroundStyle(WorldPalette.rgb(0x5A3C0A))
            .frame(width: side, height: side)
            .background(WorldPalette.rgb(0xF2D58A), in: shape)
            .overlay(shape.strokeBorder(WorldPalette.rgb(0x8A5F14), lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// Log meal's Tag row (`bb-free`), shown only while the Bodybuilding goal is chosen: the section label
/// "Tag" and one "Free meal" chip with the small F. The chip toggles `isFreeMeal`; Log meal seals the tag
/// for the meals it logs when Save lands. It reads "Free meal, tag" and says when it is selected. The
/// word is always "Free meal" (owner's answer 3), never "cheat".
struct FreeMealTagRow: View {
    @Binding var isFreeMeal: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            SectionLabel("Tag")
            chip
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chip: some View {
        Button {
            isFreeMeal.toggle()
            FernletFeedback.system.play(.tick)
        } label: {
            HStack(spacing: 6) {
                FreeMealMark()
                Text("Free meal", comment: "Log meal sheet, Bodybuilding goal: the chip that tags this meal as a free meal (never 'cheat meal')")
            }
        }
        .buttonStyle(ChipButtonStyle(selected: isFreeMeal))
        .accessibilityLabel(Text("Free meal, tag", comment: "VoiceOver name of Log meal's Free meal chip (Bodybuilding goal); 'tag' says what kind of control it is"))
        .accessibilityInputLabels([Text("Free meal")])
        .accessibilityAddTraits(isFreeMeal ? .isSelected : [])
        .accessibilityIdentifier("mealComposer.freeMeal")
    }
}

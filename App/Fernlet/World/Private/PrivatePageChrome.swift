import FernletDomainModel
import FernletUI
import PrivateHealthStore
import SwiftUI

/// The framed primary beside a Private page's subtitle: "+ Write" on Journal and "+ Log" on Cycle
/// (World Review Batch 2, `b2-journal` draft 2 and `b2-cycle`). The pixel plus leads the word, in the
/// look's on-accent ink; without the framed look it is the app's moss action pill.
///
/// Voice Control answers to the drawn word first, then the longer spoken name it replaced
/// ("New journal entry"), so neither the old command nor the new one stops working.
struct PrivatePageActionButton: View {
    let title: LocalizedStringKey
    /// The fuller spoken name (today's icon button's label), kept as a second input label.
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            PrivateActionLabel(title: title)
        }
        .buttonStyle(ActionPillButtonStyle(.primary))
        .frame(maxWidth: 200)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityInputLabels([Text(title), Text(accessibilityLabel)])
    }
}

/// The label of a Private page's framed primary: the pixel plus in the on-accent ink, then the word,
/// filling the button's width. Also the label of Cycle's "+ Log" menu.
struct PrivateActionLabel: View {
    let title: LocalizedStringKey
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 8) {
            FernletIcon(.plus, scale: 2, tint: look?.onAccent ?? Color.onMoss)
                .accessibilityHidden(true)
            Text(title)
                .font(FernletFramedFont.button)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A day's score as the status plate's pixel hearts (`b2-journal-day`): six hearts with halves, four
/// at the largest text sizes, no gold (gold hearts belong to today's live care, not a day's record).
/// Drawn by ``WorldHeartRow`` from a ``WorldStatus`` built for the score alone, so the day page and
/// the plate can never count hearts differently. Hidden from VoiceOver: the percentage beside it
/// says the same thing.
struct DayScoreHearts: View {
    /// The day's score, 0...1.
    let score: Double
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let status = WorldStatus.make(
            score: score, goldHearts: 0, macros: MacroTotals(),
            targets: NutritionTargets(calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sodiumLimit: 0, saturatedFatLimit: 0),
            bottles: 0, bottleTarget: 0)
        WorldHeartRow(status: status, count: dynamicTypeSize.isAccessibilitySize ? 4 : 6, scale: 4)
    }
}

/// A Private day page's own heading when the plate already names the page (`b2-cycle-day`: the plate
/// reads "Cycle day", the page "October 12" in Fraunces 40 with the phase beneath). A header for
/// VoiceOver's rotor.
struct PrivateDayTitle: View {
    let title: Text
    let subtitle: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.custom(FernletFontName.frauncesSemiBold, size: 40, relativeTo: .largeTitle))
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                subtitle
                    .font(FernletFramedFont.fieldBold)
                    .foregroundStyle(WorldPalette.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The framed day cell behind a Private calendar's numeral (`b2-journal`, `b2-cycle`): an 8-pt
/// rounded square in the cell's fill, and today outlined in 2.5-pt ink. The numeral and any marks are
/// the caller's.
struct PrivateCalendarCellBackground: View {
    let fill: Color
    let isToday: Bool
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        shape
            .fill(fill)
            .overlay { if isToday { shape.strokeBorder(look?.ink ?? Color.bark, lineWidth: 2.5) } }
    }

    /// The day numeral's face: DM Sans 16 (today bold) under the framed look; today's 14-pt faces
    /// without it.
    static func numeralFont(isToday: Bool, framed: Bool) -> Font {
        if framed {
            return Font.custom(FernletFontName.dmSansMedium, size: 16, relativeTo: .subheadline)
                .weight(isToday ? .heavy : .regular)
        }
        return isToday
            ? .custom(FernletFontName.frauncesSemiBold, size: 14, relativeTo: .subheadline)
            : .fernlet(.stat)
    }
}

extension JournalMonthCell {
    /// The framed cell's fill (`b2-journal`): bare for future days and blank pads, the feeling's tint
    /// on a day that carries one, sage for today, and the paper's low tone for every other day.
    func framedFill(look: FernletFramedLook) -> Color {
        if isFuture || day == nil { return .clear }
        if let tag { return tag.color.opacity(isToday ? 0.55 : 0.45) }
        if isToday { return look.sage }
        return look.paperLow
    }
}

extension CycleMonthCell {
    /// The framed cell's fill (`b2-cycle`): a logged flow keeps today's rose tones (the legend's
    /// three swatches), a forecast keeps its wash, today is sage, a past day the paper's low tone,
    /// and future days and blank pads stay bare.
    func framedFill(look: FernletFramedLook) -> Color {
        guard day != nil else { return .clear }
        if entry?.flowLevel != nil { return fill }
        if isFuture { return projectedLevel == nil ? .clear : fill }
        return isToday ? look.sage : look.paperLow
    }
}

/// One feeling or flow swatch in a Private calendar's legend: a small framed square in the colour,
/// then the word (`b2-journal`, `b2-cycle`). Under Differentiate Without Color the caller passes the
/// mark the day cells draw, so the legend stays a working key without hue.
struct PrivateLegendSwatch: View {
    let fill: Color
    let label: Text
    /// The SF Symbol the cells draw under Differentiate Without Color, or nil for the colour alone.
    var symbol: String? = nil
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(look?.text ?? Color.bark)
                    .frame(width: 12, height: 12)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(fill)
                    .frame(width: 12, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(look?.ink ?? Color.bark, lineWidth: 1.5))
            }
            label
                .font(look != nil ? FernletFramedFont.rowDetail.weight(.medium) : .fernlet(.labelSmall))
                .foregroundStyle(look?.dim ?? Color.slate)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

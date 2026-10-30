//
//  BodybuildingWeekList.swift
//  Fernlet
//
//  The Day calendar's week (World round 7, `bb-week`; spec §3): one row a day with every signal that is
//  on (the training, weight, sleep, bathroom visits, steps, protein · carbs · fat bars, the free-meal tag,
//  how the day felt). Days to come are dashed and empty. Each row reads as one day; holding it marks its
//  week as a deload week. Nothing is counted against anyone: hearts show only what was there.
//

import FernletDomainModel
import FernletUI
import SwiftUI

/// The week's rows and the closing hint.
struct BodybuildingWeekList: View {
    let days: [BodybuildingDay]
    let settings: BodybuildingCalendarSettings
    let calendar: Calendar
    let onMarkDeload: (String, Bool) -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(days) { day in
                BodybuildingWeekRow(day: day, settings: settings, calendar: calendar, onMarkDeload: onMarkDeload)
            }
            BodybuildingCalendarText.hint
                .font(FernletFramedFont.note)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
    }
}

/// One day of the week as one control: a link to its card (a plain dashed row for a day to come).
struct BodybuildingWeekRow: View {
    let day: BodybuildingDay
    let settings: BodybuildingCalendarSettings
    let calendar: Calendar
    let onMarkDeload: (String, Bool) -> Void
    @Environment(\.fernletTermOfAddress) private var address

    var body: some View {
        let signals = BodybuildingCalendarCopy.readingOrder.filter(settings.isOn)
        let summary = BodybuildingCalendarSpeech.summary(for: day, signals: signals, calendar: calendar, address: address)
        control
            .contextMenu { BodybuildingDeloadMenuToggle(day: day, onMarkDeload: onMarkDeload) }
            .accessibilityLabel(Text(verbatim: summary))
            .accessibilityInputLabels([Text(verbatim: BodybuildingCalendarCopy.dayTitle(day.dateKey, calendar: calendar)),
                                       Text(verbatim: BodybuildingCalendarCopy.shortDayTitle(day.dateKey, calendar: calendar))])
            .accessibilityAction(named: BodybuildingDeloadMenuToggle.actionName(isDeload: day.isDeload)) {
                onMarkDeload(day.dateKey, !day.isDeload)
            }
            .accessibilityIdentifier("bodybuilding.week.\(day.dateKey)")
    }

    @ViewBuilder
    private var control: some View {
        let card = BodybuildingWeekRowCard(day: day, settings: settings, calendar: calendar)
        if day.isFuture {
            card.accessibilityElement(children: .ignore)
        } else {
            NavigationLink(value: MoveRoute.dayCalendarDay(day.dateKey)) { card }
                .buttonStyle(.plain)
        }
    }
}

/// A week row's drawing: the day and its training over a line of small figures.
struct BodybuildingWeekRowCard: View {
    let day: BodybuildingDay
    let settings: BodybuildingCalendarSettings
    let calendar: Calendar
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading
            if !day.isFuture { BodybuildingWeekFigures(day: day, settings: settings) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background }
        .overlay { border }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// "Tue 27  Push · Free meal" with the weight at the end, or "Fri 30  Still to come". At the
    /// accessibility text sizes (where this list stands in for the month) the training goes on its own
    /// line under the day and the weight, so a long workout name wraps by words.
    @ViewBuilder
    private var heading: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    dayTitle
                    Spacer(minLength: 0)
                    weightText
                }
                dayLine
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                dayTitle
                dayLine
                Spacer(minLength: 0)
                weightText
            }
        }
    }

    /// "Tue 27".
    private var dayTitle: some View {
        Text(verbatim: BodybuildingCalendarCopy.shortDayTitle(day.dateKey, calendar: calendar))
            .font(FernletFramedFont.rowValueBold)
            .foregroundStyle(day.isFuture ? (look?.dim ?? Color.slate) : (look?.text ?? Color.bark))
    }

    /// The training line, or "Still to come".
    @ViewBuilder
    private var dayLine: some View {
        if day.isFuture {
            Text("Still to come", comment: "Day calendar week list: a day that has not happened yet")
                .font(FernletFramedFont.rowValue)
                .foregroundStyle(look?.dim ?? Color.slate)
        } else {
            trainingLine
        }
    }

    /// The day's weight, while Weight is on and the day has one.
    @ViewBuilder
    private var weightText: some View {
        if settings.isOn(.weight), !day.isFuture, let kilograms = day.weightKilograms {
            Text(verbatim: BodybuildingCalendarCopy.weight(kilograms))
                .font(FernletFramedFont.rowValue)
                .foregroundStyle(look?.text ?? Color.bark)
        }
    }

    /// The training and the free-meal tag, as far as they are on (stacked at the accessibility sizes).
    private var trainingLine: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        return layout {
            if settings.isOn(.training) {
                Text(verbatim: BodybuildingCalendarCopy.training(day))
                    .font(FernletFramedFont.rowValue)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
            }
            if settings.isOn(.freeMeals), day.freeMeal {
                HStack(spacing: 4) {
                    BodybuildingFreeMealMark()
                    BodybuildingCalendarText.freeMeal
                        .font(FernletFramedFont.rowDetailBold)
                        .foregroundStyle(look?.text ?? Color.bark)
                }
            }
        }
    }

    /// Paper with soft stripes in a deload week; clear for a day to come.
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return ZStack {
            shape.fill(day.isFuture ? Color.clear : (look?.paper ?? Color.cream))
            if day.isDeload {
                BodybuildingStripes()
            } else if day.isSuggestedDeload {
                BodybuildingStripes(isFaint: true)
            }
        }
        .clipShape(shape)
    }

    /// Moss around today, dashed for days to come, ink around the rest.
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return Group {
            if day.isToday {
                shape.strokeBorder(WorldPalette.moss, lineWidth: 2.5)
            } else if day.isFuture {
                shape.strokeBorder(look?.dim ?? Color.slate, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            } else {
                shape.strokeBorder(look?.ink ?? Color.bark, lineWidth: 2)
            }
        }
    }
}

/// A week row's line of figures: sleep, bathroom visits, steps, the macro bars and how the day felt,
/// each only when its signal is on and the day holds it. Wraps at large text sizes.
struct BodybuildingWeekFigures: View {
    let day: BodybuildingDay
    let settings: BodybuildingCalendarSettings
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FlowLayout(spacing: 10) {
            if settings.isOn(.sleep), let hours = day.sleepHours {
                figure(.sleep, BodybuildingCalendarCopy.sleepShort(hours))
            }
            if settings.isOn(.bathroom), let visits = day.bathroomVisits {
                figure(.bathroom, visits.formatted())
            }
            if settings.isOn(.steps), let steps = day.steps {
                figure(.steps, steps.formatted())
            }
            if settings.isOn(.macros), let targets = day.macroTargets {
                BodybuildingMacroBars(macros: day.macros, targets: targets, height: 6, showsTrack: true)
                    .frame(width: 72)
            }
            if settings.isOn(.dayFelt) { BodybuildingDayFeltMark(day: day) }
        }
        .accessibilityHidden(true)
    }

    /// A signal's small icon and its value.
    private func figure(_ signal: BodybuildingSignal, _ value: String) -> some View {
        HStack(spacing: 4) {
            BodybuildingSignalIcon(signal: signal, scale: 1.5)
            Text(verbatim: value)
                .font(FernletFramedFont.rowValue)
                .foregroundStyle(look?.text ?? Color.bark)
        }
    }
}

/// How the day felt in a week row: up to five hearts for the care score (only the hearts that are
/// there, never empty ones), or the day's mood word when there is no score.
struct BodybuildingDayFeltMark: View {
    let day: BodybuildingDay
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.fernletTermOfAddress) private var address

    var body: some View {
        if let score = day.careScore {
            HStack(spacing: 2) {
                ForEach(0..<Self.hearts(for: score), id: \.self) { _ in
                    WorldSpriteView(sprite: WorldSprites.heartSm, scale: 1.5)
                }
            }
        } else if let feeling = day.feeling {
            Text(verbatim: feeling.label(addressing: address))
                .font(FernletFramedFont.rowValue)
                .foregroundStyle(look?.text ?? Color.bark)
        }
    }

    /// One heart per started fifth of the care score, at least one for a day that has a score.
    static func hearts(for score: Int) -> Int {
        min(max((min(max(score, 0), 100) + 19) / 20, 1), 5)
    }
}

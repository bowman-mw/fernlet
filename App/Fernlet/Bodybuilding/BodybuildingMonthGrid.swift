//
//  BodybuildingMonthGrid.swift
//  Fernlet
//
//  The Day calendar's month (World round 7, `bb-month`, `bb-deload`, `bb-deload-suggest`; spec §2, §8,
//  §9): a Monday-first grid of day cells under the weekday names, a legend naming each mark, and the
//  weight line under it. At the largest text sizes the grid keeps its seven columns at a readable width
//  and scrolls sideways instead of squeezing. Holding a day offers "Deload week" for its week.
//

import FernletDomainModel
import FernletUI
import SwiftUI

/// The month grid with its legend and weight line.
struct BodybuildingMonthGrid: View {
    let snapshot: BodybuildingCalendarSnapshot
    let settings: BodybuildingCalendarSettings
    let calendar: Calendar
    /// Marks or clears the week holding a day key as a deload week.
    let onMarkDeload: (String, Bool) -> Void
    @ScaledMetric(relativeTo: .caption) private var cellMinWidth: CGFloat = 40
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                grid
                ScrollView(.horizontal) { grid.padding(.vertical, 2) }
            }
            BodybuildingMonthLegend(signals: settings.monthCellSignals, showsSuggested: snapshot.showsSuggestionCard)
            BodybuildingCalendarText.hint
                .font(FernletFramedFont.note)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
            if settings.showsWeightLine {
                BodybuildingWeightLine(readings: snapshot.monthWeights, dayKeys: snapshot.layout.dayKeys,
                                       todayKey: snapshot.todayKey, calendar: calendar)
            }
        }
    }

    /// The weekday names over the rows of cells, every column at least ``cellMinWidth`` wide.
    private var grid: some View {
        let headers = BodybuildingCalendarCopy.weekdayHeaders(calendar: calendar)
        return Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, name in
                    Text(verbatim: name)
                        .font(MoveFont.caption)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .lineLimit(1)
                        .frame(minWidth: cellMinWidth, maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
            ForEach(Array(snapshot.gridRows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        cell(key).frame(minWidth: cellMinWidth, maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// One grid slot: a blank, or the day's cell as a control.
    @ViewBuilder
    private func cell(_ key: String?) -> some View {
        if let key, let day = snapshot.days[key] {
            BodybuildingDayCellButton(day: day, signals: settings.monthCellSignals, calendar: calendar,
                                      onMarkDeload: onMarkDeload)
        } else {
            Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }
}

/// A month cell as one control: tapping a day that has been opens its card; VoiceOver reads the whole
/// day as one element; holding it (or its accessibility action) marks its week as a deload week.
struct BodybuildingDayCellButton: View {
    let day: BodybuildingDay
    let signals: [BodybuildingSignal]
    let calendar: Calendar
    let onMarkDeload: (String, Bool) -> Void
    @Environment(\.fernletTermOfAddress) private var address

    var body: some View {
        let number = BodybuildingCalendarCopy.dayNumber(day.dateKey, calendar: calendar)
        let summary = BodybuildingCalendarSpeech.summary(for: day, signals: signals, calendar: calendar, address: address)
        control(number: number)
            .contextMenu { BodybuildingDeloadMenuToggle(day: day, onMarkDeload: onMarkDeload) }
            .accessibilityLabel(Text(verbatim: summary))
            .accessibilityInputLabels([Text(verbatim: BodybuildingCalendarCopy.dayTitle(day.dateKey, calendar: calendar)),
                                       Text(verbatim: number)])
            .accessibilityAction(named: BodybuildingDeloadMenuToggle.actionName(isDeload: day.isDeload)) {
                onMarkDeload(day.dateKey, !day.isDeload)
            }
            .accessibilityIdentifier("bodybuilding.month.\(day.dateKey)")
    }

    /// A link to the day's card for a day that has been; the bare cell for one to come.
    @ViewBuilder
    private func control(number: String) -> some View {
        let cell = BodybuildingDayCell(day: day, signals: signals, number: number)
        if day.isFuture {
            cell.accessibilityElement(children: .ignore)
        } else {
            NavigationLink(value: MoveRoute.dayCalendarDay(day.dateKey)) { cell }
                .buttonStyle(.plain)
        }
    }
}

/// "Deload week" in a day's hold menu: a switch for the week holding the day.
struct BodybuildingDeloadMenuToggle: View {
    let day: BodybuildingDay
    let onMarkDeload: (String, Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { day.isDeload }, set: { onMarkDeload(day.dateKey, $0) })) {
            BodybuildingCalendarText.deloadWeek
        }
    }

    /// The day's accessibility action: mark its week, or clear the mark.
    static func actionName(isDeload: Bool) -> Text {
        isDeload
            ? Text("Clear the deload week", comment: "Day calendar, VoiceOver action on a day: stop marking its week as a deload week")
            : Text("Mark as a deload week", comment: "Day calendar, VoiceOver action on a day: mark its whole week as a deload week (a planned lighter training week)")
    }
}

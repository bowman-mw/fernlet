//
//  MonthCalendarCard.swift
//  Fernlet
//
//  The shared month-grid calendar chrome used by the journal, period, and intimacy
//  calendars: one layout model (canonical day keys) plus one card view (paging
//  chevrons, weekday row, 7-column grid) that each feature fills with its own cells.
//

import SwiftUI
import FernletFoundation
import FernletUI

// MARK: - Grid Model

/// One real day in a rendered calendar month: its ordinal, resolved `Date`, canonical day key,
/// and today/future flags.
///
/// `dateKey` is derived by round-tripping the layout calendar's year/month/day through
/// `FernletDate.dayKey`, so it matches every producer of the canonical `"yyyy-MM-dd"` key
/// (day records, HealthKit caches, sealed-store indexes) regardless of device locale or calendar.
struct MonthGridDay {
    /// The 1-based day ordinal within the displayed month.
    let day: Int
    /// The resolved date for this day (midnight in the layout calendar), if the calendar could
    /// produce one.
    let date: Date?
    /// The canonical `"yyyy-MM-dd"` key for this day (see `FernletDate.dayKey`).
    let dateKey: String
    /// Whether this day's key equals the supplied today key.
    let isToday: Bool
    /// Whether this day's key sorts after the supplied today key.
    let isFuture: Bool
}

/// Pure month-layout math shared by the journal, period, and intimacy calendars: localized title,
/// weekday symbols, the leading-blank pad count, and one ``MonthGridDay`` per day of the month.
///
/// Day keys are canonicalized through `FernletDate.dayKey` (with a plain `%04d-%02d-%02d`
/// fallback if the calendar cannot resolve a date), never through a locale-following formatter —
/// a locale- or calendar-dependent key would miss every event/today lookup keyed by the pinned
/// POSIX/Gregorian day key. A plain struct so the layout math is testable without SwiftUI.
struct MonthGridModel {
    /// The localized wide-month + year title for the displayed month.
    let monthTitle: String
    /// The layout calendar's very-short weekday symbols, in column order.
    let weekdaySymbols: [String]
    /// How many blank pad cells precede day 1 in the 7-column grid.
    let leadingBlanks: Int
    /// One entry per day of the displayed month, in order.
    let days: [MonthGridDay]

    /// Lays out the month containing `date`, marking today/future days against `todayKey`.
    init(date: Date, todayKey: String, calendar: Calendar = .current) {
        let monthInterval = calendar.dateInterval(of: .month, for: date)
        let start = monthInterval?.start ?? date
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<2
        let firstWeekday = calendar.component(.weekday, from: start)

        self.monthTitle = date.formatted(.dateTime.month(.wide).year())
        self.weekdaySymbols = calendar.veryShortWeekdaySymbols
        self.leadingBlanks = firstWeekday - 1

        let year = calendar.component(.year, from: start)
        let month = calendar.component(.month, from: start)
        self.days = range.map { d in
            let cellDate = calendar.date(from: DateComponents(year: year, month: month, day: d))
            let key = cellDate.map { FernletDate.dayKey(for: $0) } ?? String(format: "%04d-%02d-%02d", year, month, d)
            return MonthGridDay(
                day: d,
                date: cellDate,
                dateKey: key,
                isToday: key == todayKey,
                isFuture: key > todayKey
            )
        }
    }
}

// MARK: - Card

/// The shared month-calendar card chrome: paging chevrons (future months disabled) over a
/// 7-column `LazyVGrid` of weekday symbols and caller-rendered day cells, inside a `FernletCard`.
///
/// Owns only layout and paging; each calendar (journal, period, intimacy) supplies its own
/// `cell` builder — called with `nil` for each leading blank pad and with a ``MonthGridDay`` per
/// real day — plus an optional `footer` (legends) rendered below the grid.
struct MonthCalendarCard<Cell: View, Footer: View>: View {
    @Binding var displayedMonth: Date
    var todayKey: String
    var cell: (MonthGridDay?) -> Cell
    var footer: () -> Footer

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private var cal: Calendar { .current }

    /// One rendered grid slot: a leading blank (`day == nil`) or a real day. Freshly identified
    /// per render, preserving the per-render cell identity the three calendars always had.
    private struct Slot: Identifiable {
        let id = UUID()
        let day: MonthGridDay?
    }

    /// Creates the card with an explicit footer rendered below the grid.
    init(
        displayedMonth: Binding<Date>,
        todayKey: String,
        @ViewBuilder cell: @escaping (MonthGridDay?) -> Cell,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self._displayedMonth = displayedMonth
        self.todayKey = todayKey
        self.cell = cell
        self.footer = footer
    }

    var body: some View {
        let model = MonthGridModel(date: displayedMonth, todayKey: todayKey)
        let slots = (0..<model.leadingBlanks).map { _ in Slot(day: nil) }
            + model.days.map { Slot(day: $0) }
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Button {
                        displayedMonth = cal.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    Text(model.monthTitle)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity)

                    let isCurrentMonth = cal.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
                    Button {
                        if !isCurrentMonth {
                            displayedMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isCurrentMonth ? Color.slate.opacity(0.25) : Color.slate)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrentMonth)
                }

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, day in
                        Text(day).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                    }
                    ForEach(slots) { slot in
                        cell(slot.day)
                    }
                }

                footer()
            }
        }
    }
}

extension MonthCalendarCard where Footer == EmptyView {
    /// Creates the card with no footer below the grid.
    init(
        displayedMonth: Binding<Date>,
        todayKey: String,
        @ViewBuilder cell: @escaping (MonthGridDay?) -> Cell
    ) {
        self.init(displayedMonth: displayedMonth, todayKey: todayKey, cell: cell, footer: { EmptyView() })
    }
}

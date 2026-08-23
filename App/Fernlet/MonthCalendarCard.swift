//
//  MonthCalendarCard.swift
//  Fernlet
//
//  The shared month-grid calendar chrome used by the journal and cycle calendars:
//  one layout model (canonical day keys) plus one card view (paging chevrons,
//  weekday row, 7-column grid) that each feature fills with its own cells.
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

/// Pure month-layout math shared by the journal and cycle calendars: localized title,
/// weekday symbols, the leading-blank pad count, and one ``MonthGridDay`` per day of the month.
///
/// Day keys are canonicalized through `FernletDate.dayKey` (with a plain `%04d-%02d-%02d`
/// fallback if the calendar cannot resolve a date), never through a locale-following formatter —
/// a locale- or calendar-dependent key would miss every event/today lookup keyed by the pinned
/// POSIX/Gregorian day key. A plain struct so the layout math is testable without SwiftUI.
struct MonthGridModel {
    /// The localized wide-month + year title for the displayed month.
    let monthTitle: String
    /// The layout calendar's very-short weekday symbols, rotated into column order — that is,
    /// starting at the calendar's own `firstWeekday` rather than always at Sunday.
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
        self.weekdaySymbols = Self.orderedWeekdaySymbols(for: calendar)
        self.leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7

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

    /// `veryShortWeekdaySymbols` rotated so index 0 is the calendar's own first weekday.
    ///
    /// Foundation always returns those symbols Sunday-first regardless of locale — the locale's
    /// preference lives in `Calendar.firstWeekday` instead (2 in es/fr/de and most of Europe,
    /// 7 in much of the Middle East). Rendering the array unrotated printed a Sunday-first header
    /// over a Monday-first grid, so every day cell in those locales sat under the wrong letter.
    private static func orderedWeekdaySymbols(for calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        // `firstWeekday` is 1-based (1 = Sunday); a malformed calendar leaves the order untouched.
        let offset = calendar.firstWeekday - 1
        guard offset > 0, offset < symbols.count else { return symbols }
        return Array(symbols[offset...] + symbols[..<offset])
    }
}

// MARK: - Card

/// The shared month-calendar card chrome: paging chevrons (future months disabled) over a
/// 7-column `LazyVGrid` of weekday symbols and caller-rendered day cells, inside a `FernletCard`.
///
/// Owns only layout and paging; each calendar (journal, cycle) supplies its own
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
        let isCurrentMonth = cal.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                pagingHeader(model.monthTitle, isCurrentMonth: isCurrentMonth)
                grid(model)
                footer()
            }
        }
    }

    /// The month title flanked by the two paging chevrons.
    ///
    /// Extracted from `body` so both it and ``grid(_:)`` stay well under the Power-of-10 60-line
    /// ceiling as accessibility modifiers accumulate on the grid.
    @ViewBuilder
    private func pagingHeader(_ title: String, isCurrentMonth: Bool) -> some View {
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
            // 44pt target + a spoken name: VoiceOver read "chevron.left" before.
            .fernletIconButton("Previous month")

            monthTitleView(title, isCurrentMonth: isCurrentMonth)

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
            .fernletIconButton("Next month")
        }
    }

    /// The 7-column grid: the weekday-initial row, then the leading pads and one caller-rendered
    /// cell per day of the month.
    ///
    /// Two things are deliberately taken OUT of the accessibility tree here (review T2-17):
    /// - **The weekday initials.** Seven single letters ("M", "T", "T", …) spoken before every
    ///   grid are noise, and two of them are literally the same letter.
    /// - **The leading pad cells.** A month starting on a Saturday put SIX nameless blanks between
    ///   the header and day 1. They exist to align column 1 with the right weekday — a purely
    ///   visual job — so they are hidden rather than labelled.
    ///
    /// Hiding the initials puts a CONTRACT on the caller's cell: **each cell must name its own
    /// weekday.** VoiceOver reads a date, not a column, so once the header is gone a cell that says
    /// only "Day 12" leaves a blind user with no way to tell which weekday — or which column — any
    /// of thirty otherwise identical cells is, and paging by week becomes impossible. The header
    /// was hidden here before any cell held up its end, which made that a defect rather than a
    /// redundancy; `CycleMonthCell.accessibilityLabel` now opens every sentence with the
    /// abbreviated weekday ("Wed, day 12, …") via its `longWeekdayText`.
    ///
    /// T2-17's remaining part — naming *predicted* days, which are visually distinguished but
    /// spoke identically to logged ones — lives on the cycle cell's own label, since only that
    /// calendar has forecasts: see `CycleMonthCell.accessibilityLabel`.
    private func grid(_ model: MonthGridModel) -> some View {
        let slots = (0..<model.leadingBlanks).map { _ in Slot(day: nil) }
            + model.days.map { Slot(day: $0) }
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, day in
                Text(day)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .accessibilityHidden(true)
            }
            ForEach(slots) { slot in
                cell(slot.day)
                    .accessibilityHidden(slot.day == nil)
            }
        }
    }

    /// The centered month title — a plain label on the current month, and a "Today" button on any
    /// other, because after paging back several months the only way home was tapping forward once
    /// per month. Rendered as two distinct views rather than one `.disabled` button so the title
    /// never reads as a greyed-out control on the month the user is normally looking at.
    @ViewBuilder
    private func monthTitleView(_ title: String, isCurrentMonth: Bool) -> some View {
        if isCurrentMonth {
            Text(title)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
                .frame(maxWidth: .infinity)
        } else {
            Button {
                displayedMonth = .now
            } label: {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text("Today")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.moss)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title). Back to this month")
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

//
//  BodybuildingCalendarPage.swift
//  Fernlet
//
//  The Bodybuilding goal's Day calendar in Move (World round 7, piece C; spec §2–§4, §8, §9): pushed from
//  the Move root's Day calendar card, with "‹ Move" and ✕ on the plate and Month | Week at the top right
//  (it opens on the person's choice in Calendar signals). The month and the week page back and forward
//  with the chevrons beside the heading (owner's answer 6, 2026-10-30), and at the accessibility text
//  sizes the page shows the week list instead of the month (answer 8). The suggested deload week's card
//  sits on top while Fernlet suggests one. It redraws when a tally changes, when the calendar's
//  preferences change, when it pages, and once the weights arrive from Health.
//

import FernletDomainModel
import FernletUI
import SwiftUI

/// The Day calendar page.
struct BodybuildingCalendarPage: View {
    var store: FernletStore
    /// Pushes Calendar signals on the Move stack.
    let onOpenSignals: () -> Void
    /// Month or week; nil until the page first appears, then the person's "Opens on".
    @State private var mode: BodybuildingCalendarMode?
    /// Months from the one holding today (``BodybuildingCalendarPaging/months``).
    /// DEBUG `FERNLET_UI_TEST_BB_SCENARIO=paged` opens one back, for the paging shots.
    @State private var monthOffset = UITestSupport.bodybuildingScenario == "paged" ? -1 : 0
    /// Weeks from this one (``BodybuildingCalendarPaging/weeks``).
    @State private var weekOffset = UITestSupport.bodybuildingScenario == "paged" ? -1 : 0
    @State private var snapshot = BodybuildingCalendarSnapshot.empty
    @State private var weights: [String: Double] = [:]
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if snapshot.showsSuggestionCard {
                    BodybuildingDeloadSuggestionCard(onAccept: acceptSuggestion, onDecline: declineSuggestion)
                }
                header
                if pageOffset != 0 { backToNowButton }
                content
                MoveLinkCard(title: Text(BodybuildingCalendarText.signalsTitle), sprite: WorldSprites.gear, inksSprite: true,
                             identifier: "bodybuilding.calendar.signals", action: onOpenSignals)
            }
            .padding(16)
        }
        .fernletPageBackground()
        .fernletPushedPage(BodybuildingCalendarText.pageTitle)
        .accessibilityIdentifier("screen.bodybuilding.calendar")
        .task(id: PageKey(month: monthOffset, week: weekOffset)) { await load() }
        .onChange(of: store.bodyTallyChangeToken) { _, _ in reload() }
        .onChange(of: store.bodybuildingCalendarSettings) { _, _ in reload() }
    }

    /// What the page loads for: the month and week offsets.
    private struct PageKey: Hashable {
        let month: Int
        let week: Int
    }

    /// The mode shown: the week list at the accessibility text sizes, where seven columns no longer fit
    /// (owner's answer 8); else the person's pick on this page, else their "Opens on".
    private var shownMode: BodybuildingCalendarMode {
        dynamicTypeSize.isAccessibilitySize ? .week : mode ?? store.bodybuildingCalendarSettings.opensOn
    }

    /// The offset of the mode shown.
    private var pageOffset: Int { shownMode == .month ? monthOffset : weekOffset }

    /// "‹ October ›" or "‹ This week ›", with Month | Week beside it (under it when they do not fit on one
    /// line; gone at the accessibility sizes, which always show the week).
    /// The switch goes under the heading whenever the heading would have to wrap beside it ("September").
    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            pager(wraps: true)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    pager(wraps: false)
                    modePicker.frame(width: 170)
                }
                VStack(alignment: .leading, spacing: 10) {
                    pager(wraps: true)
                    modePicker.frame(maxWidth: 170)
                }
            }
        }
    }

    /// "‹ heading ›"; the heading keeps to one line unless `wraps`.
    private func pager(wraps: Bool) -> some View {
        HStack(spacing: 4) {
            pageButton(forward: false)
            Group {
                if wraps {
                    heading.fernletWrappingText()
                } else {
                    heading.fixedSize()
                }
            }
            .font(.custom(FernletFontName.frauncesSemiBold, size: 22, relativeTo: .title2))
            .foregroundStyle(look?.text ?? Color.bark)
            .accessibilityAddTraits(.isHeader)
            pageButton(forward: true)
            Spacer(minLength: 0)
        }
    }

    /// Month | Week (sized by the caller: a fixed width beside the heading, so the fit is measured true).
    private var modePicker: some View {
        FernletSegmentedPicker("Calendar view", selection: modeBinding, options: BodybuildingCalendarMode.allCases) {
            Text(verbatim: $0.displayName)
        }
        .accessibilityIdentifier("bodybuilding.calendar.mode")
    }

    /// The month's name (with its year when not this year's), "This week", or a paged week's dates.
    @ViewBuilder
    private var heading: some View {
        let calendar = store.bodybuildingWeekCalendar
        if shownMode == .month {
            Text(verbatim: BodybuildingCalendarCopy.monthTitle(snapshot.layout, calendar: calendar, todayKey: snapshot.todayKey))
        } else if weekOffset == 0 {
            Text("This week", comment: "Day calendar: the week view's heading")
        } else {
            Text(verbatim: BodybuildingCalendarCopy.weekRangeTitle(snapshot.weekKeys, calendar: calendar, todayKey: snapshot.todayKey))
        }
    }

    /// A paging chevron: the pixel back or forward arrow, 44 pt, faded and still at the paging limit.
    private func pageButton(forward: Bool) -> some View {
        let isMonth = shownMode == .month
        let range = isMonth ? BodybuildingCalendarPaging.months : BodybuildingCalendarPaging.weeks
        let atLimit = forward ? pageOffset >= range.upperBound : pageOffset <= range.lowerBound
        let label: LocalizedStringKey = switch (isMonth, forward) {
        case (true, false): "Previous month"
        case (true, true): "Next month"
        case (false, false): "Previous week"
        case (false, true): "Next week"
        }
        return Button { page(by: forward ? 1 : -1) } label: {
            FernletIcon(forward ? .chevron : .back, scale: 3)
                .opacity(atLimit ? 0.3 : 1)
        }
        .buttonStyle(.plain)
        .disabled(atLimit)
        .fernletIconButton(label)
        .accessibilityIdentifier(forward ? "bodybuilding.calendar.next" : "bodybuilding.calendar.previous")
    }

    /// "This month" or "This week": back to the month or week holding today, shown once the page has moved.
    private var backToNowButton: some View {
        Button {
            if shownMode == .month { monthOffset = 0 } else { weekOffset = 0 }
        } label: {
            if shownMode == .month { Text("This month") } else { Text("This week") }
        }
        .buttonStyle(ChipButtonStyle(selected: false))
        .accessibilityIdentifier("bodybuilding.calendar.backToNow")
    }

    /// Moves the shown month or week by `delta`, within ``BodybuildingCalendarPaging``.
    private func page(by delta: Int) {
        if shownMode == .month {
            monthOffset = BodybuildingCalendarPaging.step(monthOffset, by: delta, in: BodybuildingCalendarPaging.months)
        } else {
            weekOffset = BodybuildingCalendarPaging.step(weekOffset, by: delta, in: BodybuildingCalendarPaging.weeks)
        }
        FernletFeedback.system.play(.tick)
    }

    /// The month grid or the week list.
    @ViewBuilder
    private var content: some View {
        let settings = store.bodybuildingCalendarSettings
        if shownMode == .month {
            BodybuildingMonthGrid(snapshot: snapshot, settings: settings, calendar: store.bodybuildingWeekCalendar,
                                  onMarkDeload: markDeload)
        } else {
            BodybuildingWeekList(days: snapshot.weekDays, settings: settings, calendar: store.bodybuildingWeekCalendar,
                                 onMarkDeload: markDeload)
        }
    }

    /// The page's pick of month or week (never saved: "Opens on" is the saved default).
    private var modeBinding: Binding<BodybuildingCalendarMode> {
        Binding(get: { shownMode }, set: { mode = $0 })
    }

    /// Builds the days now, then again once Health's weights arrive.
    private func load() async {
        reload()
        let keys = BodybuildingCalendarGrid.visibleKeys(rows: snapshot.gridRows, weekKeys: snapshot.weekKeys)
        guard let first = keys.first, let last = keys.last else { return }
        let read = await BodyWeightReader.load(from: first, through: last,
                                               isDecoy: store.duressSessionActive, source: HealthBodyWeightSource(),
                                               calendar: store.bodybuildingWeekCalendar)
        let merged = weights.merging(read) { _, new in new }
        guard merged != weights else { return }
        weights = merged
        reload()
    }

    /// Rebuilds the snapshot from the store and the weights already read.
    private func reload() {
        snapshot = store.bodybuildingCalendarSnapshot(weights: weights, monthOffset: monthOffset, weekOffset: weekOffset)
    }

    /// Hold menu or accessibility action: marks or clears the week holding `dayKey`.
    private func markDeload(_ dayKey: String, _ isDeload: Bool) {
        store.markDeloadWeek(start: dayKey, isDeload: isDeload)
        reload()
    }

    /// "Make next week a deload".
    private func acceptSuggestion() {
        store.acceptDeloadSuggestion()
        reload()
    }

    /// "Not now".
    private func declineSuggestion() {
        store.declineDeloadSuggestion()
        reload()
    }
}

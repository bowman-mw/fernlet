//
//  BodybuildingCalendarPage.swift
//  Fernlet
//
//  The Bodybuilding goal's Day calendar in Move (World round 7, piece C; spec §2–§4, §8, §9): pushed from
//  the Move root's Day calendar card, with "‹ Move" and ✕ on the plate and Month | Week at the top right
//  (it opens on the person's choice in Calendar signals). The suggested deload week's card sits on top
//  while Fernlet suggests one. It redraws when a tally changes, when the calendar's preferences change,
//  and once the weights arrive from Health.
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
    @State private var snapshot = BodybuildingCalendarSnapshot.empty
    @State private var weights: [String: Double] = [:]
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if snapshot.showsSuggestionCard {
                    BodybuildingDeloadSuggestionCard(onAccept: acceptSuggestion, onDecline: declineSuggestion)
                }
                header
                content
                MoveLinkCard(title: Text(BodybuildingCalendarText.signalsTitle), sprite: WorldSprites.gear, inksSprite: true,
                             identifier: "bodybuilding.calendar.signals", action: onOpenSignals)
            }
            .padding(16)
        }
        .fernletPageBackground()
        .fernletPushedPage(BodybuildingCalendarText.pageTitle)
        .accessibilityIdentifier("screen.bodybuilding.calendar")
        .task { await load() }
        .onChange(of: store.bodyTallyChangeToken) { _, _ in reload() }
        .onChange(of: store.bodybuildingCalendarSettings) { _, _ in reload() }
    }

    /// The mode shown: the person's pick on this page, else their "Opens on".
    private var shownMode: BodybuildingCalendarMode { mode ?? store.bodybuildingCalendarSettings.opensOn }

    /// "October" or "This week", with Month | Week beside it (above it at the largest text sizes).
    private var header: some View {
        AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
            Group {
                if shownMode == .month {
                    Text(verbatim: BodybuildingCalendarCopy.monthTitle(snapshot.layout, calendar: store.bodybuildingWeekCalendar))
                } else {
                    Text("This week", comment: "Day calendar: the week view's heading")
                }
            }
            .font(.custom(FernletFontName.frauncesSemiBold, size: 22, relativeTo: .title2))
            .foregroundStyle(look?.text ?? Color.bark)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            FernletSegmentedPicker("Calendar view", selection: modeBinding, options: BodybuildingCalendarMode.allCases) {
                Text(verbatim: $0.displayName)
            }
            .frame(maxWidth: 170)
            .accessibilityIdentifier("bodybuilding.calendar.mode")
        }
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
        guard read != weights else { return }
        weights = read
        reload()
    }

    /// Rebuilds the snapshot from the store and the weights already read.
    private func reload() {
        snapshot = store.bodybuildingCalendarSnapshot(weights: weights)
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

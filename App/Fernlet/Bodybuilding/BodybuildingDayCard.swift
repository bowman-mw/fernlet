//
//  BodybuildingDayCard.swift
//  Fernlet
//
//  A day's details on the Day calendar (World round 7, `bb-day`; spec §10): all eight signals on one
//  card whatever is switched on, the day's deload mark, and Edit the day, which opens the approved Edit
//  day sheet (`DayEditSheet`). Each row reads its name and value.
//

import FernletDomainModel
import FernletUI
import SwiftUI

/// The pushed day page.
struct BodybuildingDayCard: View {
    var store: FernletStore
    let dateKey: String
    @State private var day: BodybuildingDay?
    @State private var showsEditor = false
    @Environment(CaptureProtectionState.self) private var captureProtection
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.fernletTermOfAddress) private var address

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let day {
                    header(day)
                    FernletFramedSection {
                        ForEach(BodybuildingCalendarCopy.dayCardOrder) { signal in row(signal, day: day) }
                    }
                    if !day.isFuture {
                        Button { showsEditor = true } label: {
                            Text("Edit the day", comment: "Day calendar day card: opens the Edit day sheet for this day")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ActionPillButtonStyle(.secondary))
                        .accessibilityIdentifier("bodybuilding.day.edit")
                    }
                }
            }
            .padding(16)
        }
        .fernletPageBackground()
        .fernletPushedPage(BodybuildingCalendarText.pageTitle)
        .accessibilityIdentifier("screen.bodybuilding.day")
        .task { await load() }
        .onChange(of: store.bodyTallyChangeToken) { _, _ in Task { await load() } }
        .sheet(isPresented: $showsEditor, onDismiss: { Task { await load() } }) {
            DayEditSheet(store: store, dateKey: dateKey, initialDay: store.loadDay(for: dateKey))
                .fernletSheet()
                .environment(captureProtection)
        }
    }

    /// "Wednesday 21" with the deload chip beside it.
    private func header(_ day: BodybuildingDay) -> some View {
        AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
            Text(verbatim: BodybuildingCalendarCopy.dayTitle(day.dateKey, calendar: store.bodybuildingWeekCalendar))
                .font(.custom(FernletFontName.frauncesSemiBold, size: 22, relativeTo: .title2))
                .foregroundStyle(look?.text ?? Color.bark)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            if day.isDeload {
                chip(BodybuildingCalendarText.deloadWeek, faint: false)
            } else if day.isSuggestedDeload {
                chip(BodybuildingCalendarText.suggestedDeloadWeek, faint: true)
            }
        }
    }

    /// The deload mark: the stripes' swatch and its name in a framed chip.
    private func chip(_ name: Text, faint: Bool) -> some View {
        HStack(spacing: 6) {
            BodybuildingDeloadSwatch(isFaint: faint)
            name.font(FernletFramedFont.rowDetailBold).foregroundStyle(look?.text ?? Color.bark)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(look?.raised ?? Color.cream, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(look?.ink ?? Color.bark, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }

    /// One signal's row: icon, name, value; read as name then value.
    private func row(_ signal: BodybuildingSignal, day: BodybuildingDay) -> some View {
        let value = BodybuildingCalendarSpeech.cardValue(signal, day: day, address: address)
        return HStack(spacing: 12) {
            FernletIconTile(size: 32) { BodybuildingSignalIcon(signal: signal) }
            Text(verbatim: rowName(signal))
                .font(FernletFramedFont.rowTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fernletWrappingText()
            Text(verbatim: value.shown)
                .font(FernletFramedFont.rowValueBold)
                .foregroundStyle(look?.text ?? Color.bark)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: rowName(signal)))
        .accessibilityValue(Text(verbatim: value.spoken))
        .accessibilityIdentifier("bodybuilding.day.row.\(signal.rawValue)")
    }

    /// The row's name: the signal's, with the day card's own words for macros and free meals.
    private func rowName(_ signal: BodybuildingSignal) -> String {
        switch signal {
        case .macros: String(localized: "bodybuilding.day.macros", defaultValue: "Protein · carbs · fat",
                             comment: "Day calendar day card: the row with grams of protein, carbs and fat eaten that day")
        case .freeMeals: String(localized: "bodybuilding.day.freeMeal", defaultValue: "Free meal",
                                comment: "Day calendar day card: the row saying whether a meal that day is tagged Free meal (a planned, relaxed meal; never 'cheat')")
        default: signal.displayName
        }
    }

    /// Builds the day, with its weight from Health (none in a decoy session).
    private func load() async {
        let calendar = store.bodybuildingWeekCalendar
        day = store.bodybuildingDays(for: [dateKey], weights: [:]).first
        let weights = await BodyWeightReader.load(from: dateKey, through: dateKey, isDecoy: store.duressSessionActive,
                                                  source: HealthBodyWeightSource(), calendar: calendar)
        guard !weights.isEmpty else { return }
        day = store.bodybuildingDays(for: [dateKey], weights: weights).first
    }
}

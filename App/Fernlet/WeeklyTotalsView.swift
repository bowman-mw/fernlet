//
//  WeeklyTotalsView.swift
//  Fernlet
//
//  The Move tab's "Weekly totals" sub-screen (comparison report idea 18): hard sets per muscle group
//  and aerobic minutes for one week, beside neutral reference ranges. Information, not a streak —
//  the same rule as the Exercise history screen: as-logged totals only, no trends, no grades, no
//  streaks, no praise, no "you're behind", and nothing that reaches out when the screen is closed.
//

import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI

/// The copy and number formatting behind ``WeeklyTotalsView``, resolved to final strings so the
/// screen and its tests read the same words.
///
/// Numbers go through formatters (locale digits and separators); every sentence that carries a
/// number is a catalog key with the number as an argument. The words are deliberately flat: a count,
/// a reference range stated once, and no comparison between them.
enum WeeklyTotalsCopy {

    /// A muscle's set count as drawn on its row: "12", or "9.5" when half sets are involved.
    static func setsNumber(_ sets: Double) -> String {
        sets.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// What VoiceOver says after a row's muscle name: "12 hard sets", "1 hard set", "9.5 hard sets".
    ///
    /// Whole counts go through a plural-varied key with an integer argument; a count with a half
    /// goes through its own key with the formatted number, because a plural rule needs a number it
    /// can classify and English always says "sets" after a fraction.
    static func setsValue(_ sets: Double) -> String {
        // `Int(exactly:)` is nil for a fraction (and for a non-finite value), so it is both the
        // whole-number test and a conversion that cannot trap.
        guard let whole = Int(exactly: sets) else {
            let number = setsNumber(sets)
            return String(localized: "weekly.sets.spoken.half", defaultValue: "\(number) hard sets",
                          comment: "Weekly totals screen, spoken after a muscle name: how many hard sets it had this week. The number always has a half (for example 9.5), because helper muscles get half a set.")
        }
        return String(localized: "weekly.sets.spoken.whole", defaultValue: "\(whole) hard sets",
                      comment: "Weekly totals screen, spoken after a muscle name: how many hard sets it had this week, a whole number. Needs a plural variation per language; English also needs the one-set form.")
    }

    /// The reference range, stated once above the rows: "10–20 hard sets a week per muscle is a
    /// common range for muscle growth."
    static var setsReference: String {
        let low = WeeklyTrainingSummaryBuilder.referenceSetsLow.formatted()
        let high = WeeklyTrainingSummaryBuilder.referenceSetsHigh.formatted()
        return String(localized: "weekly.sets.reference",
                      defaultValue: "\(low)–\(high) hard sets a week per muscle is a common range for muscle growth.",
                      comment: "Weekly totals screen: neutral context above the per-muscle set counts. The numbers are the low and high ends of the range (10 and 20). Keep it a plain statement, never advice or a target.")
    }

    /// The aerobic total as drawn: "95 of 150 minutes".
    static func aerobicLine(minutes: Int) -> String {
        let logged = minutes.formatted()
        let guideline = WeeklyTrainingSummaryBuilder.aerobicGuidelineMinutes.formatted()
        return String(localized: "weekly.aerobic.line", defaultValue: "\(logged) of \(guideline) minutes",
                      comment: "Weekly totals screen: aerobic minutes logged this week out of the 150-minute guideline, e.g. '95 of 150 minutes'. The first number is what was logged; the second is always 150.")
    }

    /// The aerobic total as VoiceOver says it: "95 of 150 aerobic minutes".
    static func aerobicSpoken(minutes: Int) -> String {
        let logged = minutes.formatted()
        let guideline = WeeklyTrainingSummaryBuilder.aerobicGuidelineMinutes.formatted()
        return String(localized: "weekly.aerobic.spoken", defaultValue: "\(logged) of \(guideline) aerobic minutes",
                      comment: "Weekly totals screen, spoken: aerobic minutes logged this week out of the 150-minute guideline. The first number is what was logged; the second is always 150.")
    }

    /// Where the 150 comes from, stated once under the bar.
    static var aerobicReference: String {
        let moderate = WeeklyTrainingSummaryBuilder.aerobicGuidelineMinutes.formatted()
        let vigorous = WeeklyTrainingSummaryBuilder.vigorousGuidelineMinutes.formatted()
        return String(localized: "weekly.aerobic.reference",
                      defaultValue: "The WHO guideline for adults is at least \(moderate) minutes of moderate activity a week, or \(vigorous) minutes of vigorous activity.",
                      comment: "Weekly totals screen: neutral context under the aerobic minutes. The numbers are the World Health Organization's weekly minimums (150 moderate, 75 vigorous). Keep it a plain statement, never advice.")
    }

    /// How far the bar is filled: the share of the guideline logged, never past full.
    static func aerobicFraction(minutes: Int) -> Double {
        let guideline = WeeklyTrainingSummaryBuilder.aerobicGuidelineMinutes
        guard guideline > 0, minutes > 0 else { return 0 }
        return min(1, Double(minutes) / Double(guideline))
    }

    /// The week's dates as a localized range: "Oct 19 – 25".
    static func weekRange(start: Date, end: Date) -> String {
        guard start < end else { return start.formatted(.dateTime.month(.abbreviated).day()) }
        return (start..<end).formatted(.interval.month(.abbreviated).day())
    }
}

/// The Move sub-screen with one week's hard sets per muscle group and aerobic minutes, stepping
/// back through the last four weeks.
///
/// Pushed from the Move root via ``MoveRoute/weeklyTotals`` and drawn with the pushed-screen chrome
/// ``ExerciseHistoryView`` uses (own `ScreenHeader`, parchment background, inline empty nav title).
/// The day history loads once per appearance into `@State` (the same snapshot idiom); the week's
/// totals are recomputed from it by ``WeeklyTrainingSummaryBuilder`` as the user steps. The week
/// follows the user's calendar, so it starts on their `firstWeekday`.
struct WeeklyTotalsView: View {
    var store: FernletStore
    @State private var days: [String: FernletDay] = [:]
    /// 0 for the current week, up to ``WeeklyTrainingSummaryBuilder/maxWeeksBack``.
    @State private var weeksBack = 0

    /// The selected week's totals, or nil when today's key doesn't parse (never in practice).
    private var summary: WeeklyTrainingSummary? {
        guard let today = FernletDate.date(fromDayKey: store.todayKey) else { return nil }
        return WeeklyTrainingSummaryBuilder.summary(days: days, today: today, weeksBack: weeksBack, calendar: .current)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(
                    title: Text("Weekly totals", comment: "Title of the Move tab screen with one week's sets per muscle and aerobic minutes; also the label of the link that opens it."),
                    subtitle: Text("Sets per muscle and aerobic minutes, as logged.", comment: "Subtitle of the Weekly totals screen."),
                    identifier: "screen.weeklyTotals")
                if let summary {
                    WeeklyTotalsWeekHeader(summary: summary, weeksBack: $weeksBack)
                    WeeklySetsSection(muscleSets: summary.muscleSets)
                    WeeklyAerobicSection(minutes: summary.aerobicMinutes)
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        // The page draws its own ScreenHeader, so the bar carries only the back button.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { days = store.loadDays() }
    }
}

/// The week being shown, between the step-back and step-forward buttons.
///
/// The user can step back ``WeeklyTrainingSummaryBuilder/maxWeeksBack`` weeks and forward to the
/// current one, never into the future. An unavailable direction draws an empty slot of the same size
/// instead of a disabled button, so there is no dead control for VoiceOver or Voice Control to find.
struct WeeklyTotalsWeekHeader: View {
    var summary: WeeklyTrainingSummary
    @Binding var weeksBack: Int

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            stepButton(symbol: "chevron.left", label: Text("Previous week"), identifier: "weeklyTotals.previousWeek",
                       available: weeksBack < WeeklyTrainingSummaryBuilder.maxWeeksBack) { weeksBack += 1 }
            VStack(spacing: 2) {
                Text(verbatim: WeeklyTotalsCopy.weekRange(start: summary.weekStart, end: summary.weekEnd))
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
                if weeksBack == 0 {
                    Text("This week", comment: "Weekly totals screen: caption under the date range when it is the current week.")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            stepButton(symbol: "chevron.right", label: Text("Next week"), identifier: "weeklyTotals.nextWeek",
                       available: weeksBack > 0) { weeksBack -= 1 }
        }
    }

    /// One chevron button, or an empty slot of the same size when the step isn't available.
    @ViewBuilder private func stepButton(
        symbol: String, label: Text, identifier: String, available: Bool, action: @escaping () -> Void
    ) -> some View {
        if available {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.slate)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        } else {
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }
}

/// The week's hard sets per muscle group: the reference range, one row per muscle trained, and how
/// sets are counted. Muscles with no sets are left out rather than listed at zero.
struct WeeklySetsSection: View {
    var muscleSets: [WeeklyTrainingSummary.MuscleSets]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WeeklySectionHeading("Hard sets per muscle")
            FernletScrollSection { card }
        }
    }

    /// The card: the reference line, the rows (or the quiet empty line), and how sets are counted.
    @ViewBuilder private var card: some View {
        Text(verbatim: WeeklyTotalsCopy.setsReference)
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
            .padding(.vertical, 6)
        if muscleSets.isEmpty {
            EmptyState(text: "No lifting sets logged.")
        } else {
            ForEach(muscleSets) { row in
                FernletRowDivider()
                WeeklyMuscleSetsRow(row: row)
            }
        }
        FernletRowDivider()
        Text("A set counts in full for the muscles a lift mainly works, and as half a set for the muscles that help. A guided session marked done counts the sets it planned. Warm-ups, stretches, holds and ramp-up sets aren't counted.",
             comment: "Weekly totals screen: how the per-muscle set counts are worked out. 'Marked done' = the guided session's Mark done button, used instead of running it set by set.")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
            .padding(.vertical, 6)
    }
}

/// One muscle's row: its name and its set count. VoiceOver reads it as one element, the name then
/// the count with its noun ("Chest, 12 hard sets"); at accessibility text sizes the count drops
/// under the name instead of squeezing beside it.
struct WeeklyMuscleSetsRow: View {
    var row: WeeklyTrainingSummary.MuscleSets

    var body: some View {
        AdaptiveStack(spacing: 4, horizontalAlignment: .leading) {
            Text(verbatim: row.muscle.displayName)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: WeeklyTotalsCopy.setsNumber(row.sets))
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.muscle.displayName))
        .accessibilityValue(Text(verbatim: WeeklyTotalsCopy.setsValue(row.sets)))
    }
}

/// The week's aerobic minutes as "95 of 150 minutes" over a plain bar, then where the 150 comes from
/// and what counts. The bar is one colour whatever it shows and stops at full; it carries nothing
/// the sentence above it doesn't, so it is hidden from VoiceOver.
struct WeeklyAerobicSection: View {
    var minutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WeeklySectionHeading("Aerobic minutes")
            FernletScrollSection { card }
        }
    }

    /// The card: the total over its bar (or the quiet empty line), then the guideline and what counts.
    @ViewBuilder private var card: some View {
        if minutes > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: WeeklyTotalsCopy.aerobicLine(minutes: minutes))
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                WeeklyAerobicBar(fraction: WeeklyTotalsCopy.aerobicFraction(minutes: minutes))
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WeeklyTotalsCopy.aerobicSpoken(minutes: minutes)))
        } else {
            EmptyState(text: "No aerobic minutes logged.")
        }
        FernletRowDivider()
        Text(verbatim: WeeklyTotalsCopy.aerobicReference)
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
            .padding(.top, 6)
        Text("Counts cardio, sports and dance, including workouts from Apple Health. A strength session adds only the planned minutes of a cardio block inside it; yoga, Pilates and other mind-body sessions aren't counted.",
             comment: "Weekly totals screen: which workouts the aerobic minutes include. A 'cardio block' is a cardio part inside a lifting session, such as 'Easy cardio - 20 min'; its minutes count as planned.")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
            .padding(.vertical, 6)
    }
}

/// A section heading on the Weekly totals screen: sentence case in the label face, read by VoiceOver
/// as a heading (h2, under the screen's h1 title).
///
/// Not the shared uppercase ``SectionLabel`` (a titled `FernletScrollSection`'s header). In the
/// accessibility audit's Dynamic Type pass that caption, tracked and uppercased by `.textCase`,
/// reported "HARD SETS PER MUSCLE" as clipped once it wrapped at accessibility sizes (bundle 6,
/// 2026-10-20), the same finding the frozen audit baselines carry for other long captions ("WHAT
/// DID YOU EAT?", "PERSONAL CARE TASKS"). Plain text with no tracking and no case transform wraps
/// as it measures.
struct WeeklySectionHeading: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.fernlet(.label))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h2)
    }
}

/// A plain horizontal bar filled to `fraction` (0…1) in one colour. Decorative: hidden from
/// VoiceOver, with no colour change at any level, so it never reads as a grade.
struct WeeklyAerobicBar: View {
    var fraction: Double

    var body: some View {
        Capsule()
            .fill(Color.bark.opacity(0.1))
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.moss)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .accessibilityHidden(true)
    }
}

/// The quiet "Weekly totals" link on the Move root, under "Exercise history", in the same row chrome
/// so the two navigation rows read alike. Opens ``WeeklyTotalsView``.
struct WeeklyTotalsLink: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .accessibilityHidden(true)
                Text("Weekly totals", comment: "Title of the Move tab screen with one week's sets per muscle and aerobic minutes; also the label of the link that opens it.")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.cream.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("move.weeklyTotals")
    }
}

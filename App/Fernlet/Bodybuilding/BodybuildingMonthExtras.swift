//
//  BodybuildingMonthExtras.swift
//  Fernlet
//
//  Around the month grid (World round 7, `bb-month`, `bb-deload-suggest`): the legend that names each
//  mark, and the weight line under the grid, a line to read and never a target (no goal line, no arrow,
//  no delta).
//

import FernletDomainModel
import FernletUI
import SwiftUI

/// The words the Day calendar draws in more than one place, so each key carries one note.
enum BodybuildingCalendarText {
    /// The pushed page's title on the plate, and the Move link card's name.
    static let pageTitle = LocalizedStringResource(
        "Day calendar", comment: "Title of the Bodybuilding goal's day calendar in Move; also the label of the Move card that opens it")
    /// The Calendar signals page's title on the plate, and the calendar's card that opens it.
    static let signalsTitle = LocalizedStringResource(
        "Calendar signals", comment: "Title of the Day calendar's page that chooses which signals it shows; also the label of the card that opens it")
    /// The stripes' name in the legend, the hold menu's switch, the day card's chip.
    static var deloadWeek: Text {
        Text("Deload week", comment: "Day calendar: a deload week (a planned lighter training week): the hold menu's switch, the legend's name for its stripes, a day's chip")
    }
    /// A meal tagged as a free meal: the legend's name for the F, the week row's tag, the day card's row.
    static var freeMeal: Text {
        Text("Free meal", comment: "Day calendar: a meal tagged as a free meal (a planned, relaxed meal; never 'cheat'): the legend's name for the F, the day card's row")
    }
    /// How to open a day and mark a week, under the month and the week.
    static var hint: Text {
        Text("Tap a day for its details. Hold a day to mark its week as a deload week.",
            comment: "Day calendar: how to open a day and how to mark a deload week (a planned lighter training week)")
    }
    /// The suggested week's name in the legend and on the day card.
    static var suggestedDeloadWeek: Text {
        Text("Suggested deload week", comment: "Day calendar: the week Fernlet suggests as a deload week, drawn dashed with faint stripes until the person decides")
    }
}

/// The legend under the grid: one entry per mark the cells draw, then the deload stripes (and the
/// suggested week's dashes while the suggestion stands).
struct BodybuildingMonthLegend: View {
    let signals: [BodybuildingSignal]
    let showsSuggested: Bool
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FlowLayout(spacing: 10) {
            ForEach(signals) { signal in
                entry(mark(for: signal), name(for: signal))
            }
            entry(AnyView(BodybuildingDeloadSwatch()), BodybuildingCalendarText.deloadWeek)
            if showsSuggested {
                entry(AnyView(BodybuildingDeloadSwatch(isFaint: true)), BodybuildingCalendarText.suggestedDeloadWeek)
            }
        }
    }

    /// A mark and its name, read together.
    private func entry(_ mark: AnyView, _ name: Text) -> some View {
        HStack(spacing: 5) {
            mark
            name
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
        .accessibilityElement(children: .combine)
    }

    /// The legend's drawing of `signal`'s mark.
    private func mark(for signal: BodybuildingSignal) -> AnyView {
        switch signal {
        case .sleep: AnyView(BodybuildingBar(fraction: 1, color: BodybuildingPalette.sleep).frame(width: 16))
        case .steps: AnyView(BodybuildingBar(fraction: 1, color: BodybuildingPalette.steps).frame(width: 16))
        case .bathroom: AnyView(BodybuildingDots(count: 2))
        case .macros: AnyView(BodybuildingMacroBars(macros: Macros(protein: 1, carbs: 1, fat: 1),
                                                    targets: Macros(protein: 1, carbs: 1, fat: 1), height: 3).frame(width: 24))
        default: AnyView(BodybuildingSignalIcon(signal: signal, scale: signal == .dayFelt ? 1 : 5.0 / 3.0))
        }
    }

    /// The legend's name for `signal`'s mark.
    private func name(for signal: BodybuildingSignal) -> Text {
        switch signal {
        case .training: Text("Trained", comment: "Day calendar legend: the dumbbell means a workout was logged that day")
        case .sleep: Text("Sleep, 8 h full", comment: "Day calendar legend: the blue bar is sleep, and it is full at 8 hours")
        case .freeMeals: BodybuildingCalendarText.freeMeal
        default: Text(verbatim: signal.displayName)
        }
    }
}

/// A small square with the deload stripes (the legend's, the day card's chip), dashed for the
/// suggested week.
struct BodybuildingDeloadSwatch: View {
    /// The suggested week: faint stripes in a dashed frame.
    var isFaint = false
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        BodybuildingStripes(isFaint: isFaint)
            .background(isFaint ? Color.clear : (look?.paper ?? Color.cream))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(look?.ink ?? Color.bark, style: StrokeStyle(lineWidth: 1.5, dash: isFaint ? [3, 2] : []))
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// The weight line under the grid (`bb-month`): the month's readings joined in moss, the latest one
/// named, and the line that says it is there to read, never to beat.
struct BodybuildingWeightLine: View {
    let readings: [(key: String, kilograms: Double)]
    /// The month's days, for the line's horizontal spacing.
    let dayKeys: [String]
    let todayKey: String
    let calendar: Calendar
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Weight", comment: "Day calendar: the weight line's title under the month grid")
                        .font(FernletFramedFont.rowTitleBold)
                        .foregroundStyle(look?.text ?? Color.bark)
                    Spacer(minLength: 0)
                    if let latest = latestLine {
                        Text(verbatim: latest)
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if readings.count >= 2 {
                    BodybuildingWeightPath(points: BodybuildingWeightLineGeometry.unitPoints(readings, dayKeys: dayKeys))
                        .stroke(WorldPalette.moss, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .frame(height: 40)
                        .accessibilityHidden(true)
                }
                footnote
                    .font(FernletFramedFont.note)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fernletWrappingText()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bodybuilding.weightLine")
    }

    /// "178.4 lb today", or "178.1 lb on Oct 27" when today has no reading yet.
    private var latestLine: String? {
        guard let last = readings.last else { return nil }
        let weight = BodybuildingCalendarCopy.weight(last.kilograms)
        if last.key == todayKey {
            return String(localized: "bodybuilding.weight.today", defaultValue: "\(weight) today",
                          comment: "Day calendar weight line: today's weight, e.g. '178.4 lb today'")
        }
        let date = BodybuildingWeeks.date(fromDayKey: last.key, calendar: calendar)?
            .formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()) ?? last.key
        return String(localized: "bodybuilding.weight.onDay", defaultValue: "\(weight) on \(date)",
                      comment: "Day calendar weight line: the latest weight and its day, e.g. '178.1 lb on Oct 27'")
    }

    /// The line under the chart.
    private var footnote: Text {
        readings.isEmpty
            ? Text("No weight from Health this month.", comment: "Day calendar weight line: Health has no weight readings for this month, or Health is off")
            : Text("A line, not a goal: it's there to read, never to beat.", comment: "Day calendar weight line: the weight is shown to read, never as a target to beat")
    }
}

/// The weight line's points in a unit square: x by day of the month, y from the month's lowest
/// (bottom) to highest (top) reading; a flat month sits in the middle.
nonisolated enum BodybuildingWeightLineGeometry {
    static func unitPoints(_ readings: [(key: String, kilograms: Double)], dayKeys: [String]) -> [CGPoint] {
        let index = Dictionary(dayKeys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let values = readings.map(\.kilograms)
        guard let low = values.min(), let high = values.max() else { return [] }
        let span = high - low
        let width = Double(max(dayKeys.count - 1, 1))
        return readings.compactMap { reading in
            guard let day = index[reading.key] else { return nil }
            let y = span > 0 ? (reading.kilograms - low) / span : 0.5
            return CGPoint(x: Double(day) / width, y: 1 - y)
        }
    }
}

/// The weight line's path through unit points, scaled to its frame.
struct BodybuildingWeightPath: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = rect.insetBy(dx: 2, dy: 3)
        for (offset, point) in points.enumerated() {
            let placed = CGPoint(x: inset.minX + point.x * inset.width, y: inset.minY + point.y * inset.height)
            if offset == 0 { path.move(to: placed) } else { path.addLine(to: placed) }
        }
        return path
    }
}

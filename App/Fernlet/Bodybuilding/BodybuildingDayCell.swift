//
//  BodybuildingDayCell.swift
//  Fernlet
//
//  One day of the month grid (World round 7, `bb-month`, `bb-deload`, `bb-deload-suggest`): the day's
//  number, then up to four marks (a dumbbell when trained, the sleep bar full at 8 h, bathroom dots, a
//  small F for a free meal; or the steps, macros and how-the-day-felt marks when those are chosen), on
//  paper with soft stripes in a deload week, ringed in moss today, dashed and empty for days to come.
//

import FernletDomainModel
import FernletUI
import SwiftUI

/// One month cell, drawn only (the grid's ``BodybuildingDayCellButton`` makes it a control and reads it).
struct BodybuildingDayCell: View {
    let day: BodybuildingDay
    /// The marks the cell draws (``BodybuildingCalendarSettings/monthCellSignals``).
    let signals: [BodybuildingSignal]
    /// The day of the month as drawn.
    let number: String
    @ScaledMetric(relativeTo: .caption) private var minHeight: CGFloat = 62
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 2) {
                Text(verbatim: number)
                    .font(.custom(FernletFontName.dmSansBold, size: 13, relativeTo: .caption))
                    .foregroundStyle(day.isFuture ? (look?.dim ?? Color.slate) : (look?.text ?? Color.bark))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if shows(.freeMeals), day.freeMeal, !day.isFuture { BodybuildingFreeMealMark() }
            }
            if !day.isFuture { marks }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background { background }
        .overlay { border }
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Whether the cell draws `signal`.
    private func shows(_ signal: BodybuildingSignal) -> Bool { signals.contains(signal) }

    /// The marks under the number, in a fixed order whatever was chosen.
    private var marks: some View {
        VStack(alignment: .leading, spacing: 3) {
            if shows(.training) {
                centered { if day.trained { BodybuildingSignalIcon(signal: .training, scale: 5.0 / 3.0) } }
                    .frame(minHeight: 9)
            }
            if shows(.dayFelt), day.hasDayFelt {
                centered { BodybuildingSignalIcon(signal: .dayFelt, scale: 1) }
            }
            if shows(.sleep), let hours = day.sleepHours {
                BodybuildingBar(fraction: hours / 8, color: BodybuildingPalette.sleep)
            }
            if shows(.steps), let steps = day.steps {
                BodybuildingBar(fraction: Double(steps) / 10_000, color: BodybuildingPalette.steps)
            }
            if shows(.macros), let targets = day.macroTargets {
                BodybuildingMacroBars(macros: day.macros, targets: targets, height: 2)
            }
            if shows(.bathroom), let visits = day.bathroomVisits {
                BodybuildingDots(count: visits)
            }
        }
    }

    /// `content` centred across the cell.
    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
    }

    /// Paper for a day that has been, clear for one to come; stripes over a deload or the suggested week.
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
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
        let shape = RoundedRectangle(cornerRadius: 6)
        let ink = look?.ink ?? Color.bark
        return Group {
            if day.isToday {
                shape.strokeBorder(WorldPalette.moss, lineWidth: 2.5)
            } else if day.isFuture {
                shape.strokeBorder(look?.dim ?? Color.slate, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            } else {
                shape.strokeBorder(ink, lineWidth: 1.5)
            }
        }
    }
}

/// Protein, carbs and fat as three short bars against the day's targets (`.bbm`), never past full.
struct BodybuildingMacroBars: View {
    let macros: Macros
    let targets: Macros
    var height: CGFloat = 5
    var showsTrack = false

    var body: some View {
        HStack(spacing: 2) {
            BodybuildingBar(fraction: share(macros.protein, of: targets.protein), color: WorldPalette.protein,
                            height: height, showsTrack: showsTrack)
            BodybuildingBar(fraction: share(macros.carbs, of: targets.carbs), color: WorldPalette.carbs,
                            height: height, showsTrack: showsTrack)
            BodybuildingBar(fraction: share(macros.fat, of: targets.fat), color: WorldPalette.fat,
                            height: height, showsTrack: showsTrack)
        }
        .accessibilityHidden(true)
    }

    /// How much of `target` `grams` fills, 0 when there is no target.
    private func share(_ grams: Int, of target: Int) -> Double {
        target > 0 ? Double(max(grams, 0)) / Double(target) : 0
    }
}

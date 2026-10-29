//
//  BodybuildingCalendarCopy.swift
//  Fernlet
//
//  The Day calendar's words, resolved to final strings so the views and the tests read the same text
//  (World round 7, piece C). Numbers go through formatters; every sentence that carries a number is a
//  catalog key with the number as an argument, and counts carry plural variations. Gentle on purpose:
//  values as they are, never a comparison, a delta or a grade.
//

import FernletDomainModel
import Foundation

/// The Day calendar's display and spoken copy.
nonisolated enum BodybuildingCalendarCopy {
    /// The order the week list and the day card read a day's signals in (the approved `bb-week` row).
    static let readingOrder: [BodybuildingSignal] = [.training, .weight, .sleep, .bathroom, .steps, .macros,
                                                     .freeMeals, .dayFelt]

    /// The day card's row order (the approved `bb-day` card).
    static let dayCardOrder: [BodybuildingSignal] = [.weight, .sleep, .bathroom, .training, .steps, .macros,
                                                     .freeMeals, .dayFelt]

    // MARK: Dates

    /// "Wednesday 21": the day's weekday and number (the day card's heading, the cell's first words).
    static func dayTitle(_ key: String, calendar: Calendar) -> String {
        guard let date = BodybuildingWeeks.date(fromDayKey: key, calendar: calendar) else { return key }
        let weekday = date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
        let number = dayNumber(key, calendar: calendar)
        return String(localized: "bodybuilding.day.title", defaultValue: "\(weekday) \(number)",
                      comment: "Day calendar: a day's name, the weekday then the day of the month, e.g. 'Wednesday 21'")
    }

    /// "Mon 26": the week list's short day name.
    static func shortDayTitle(_ key: String, calendar: Calendar) -> String {
        guard let date = BodybuildingWeeks.date(fromDayKey: key, calendar: calendar) else { return key }
        let weekday = date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
        let number = dayNumber(key, calendar: calendar)
        return String(localized: "bodybuilding.day.shortTitle", defaultValue: "\(weekday) \(number)",
                      comment: "Day calendar week list: a day's short name, the short weekday then the day of the month, e.g. 'Mon 26'")
    }

    /// The day of the month as drawn in a cell: "21".
    static func dayNumber(_ key: String, calendar: Calendar) -> String {
        guard let date = BodybuildingWeeks.date(fromDayKey: key, calendar: calendar) else { return key }
        return calendar.component(.day, from: date).formatted()
    }

    /// "October": the month's name over the grid.
    static func monthTitle(_ layout: BodybuildingMonthLayout, calendar: Calendar) -> String {
        guard let date = BodybuildingWeeks.date(fromDayKey: layout.firstDayKey, calendar: calendar) else { return "" }
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide))
    }

    /// The seven short weekday names over the grid, Monday first, in the reader's language.
    static func weekdayHeaders(calendar: Calendar) -> [String] {
        var named = calendar
        named.locale = .current
        let symbols = named.shortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return Array(repeating: "", count: 7) }
        return Array(symbols[1...] + symbols[..<1])
    }

    // MARK: Values

    /// "178.4 lb": a weight in the reader's unit, one decimal.
    static func weight(_ kilograms: Double) -> String {
        Measurement(value: kilograms, unit: UnitMass.kilograms).formatted(
            .measurement(width: .abbreviated, usage: .personWeight, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// "7.5 h": hours slept as the week list and the day card draw them.
    static func sleepShort(_ hours: Double) -> String {
        let number = hours.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "bodybuilding.sleep.short", defaultValue: "\(number) h",
                      comment: "Day calendar: hours slept, short, e.g. '7.5 h'")
    }

    /// "8 hours of sleep": hours slept as VoiceOver says them.
    static func sleepSpoken(_ hours: Double) -> String {
        let duration = Measurement(value: hours, unit: UnitDuration.hours).formatted(
            .measurement(width: .wide, numberFormatStyle: .number.precision(.fractionLength(0...1))))
        return String(localized: "bodybuilding.sleep.spoken", defaultValue: "\(duration) of sleep",
                      comment: "Day calendar, spoken: hours slept, e.g. '8 hours of sleep'. The hours arrive already formatted with their unit.")
    }

    /// "3 bathroom visits".
    static func bathroomSpoken(_ count: Int) -> String {
        String(localized: "bodybuilding.bathroom.spoken", defaultValue: "\(count) bathroom visits",
               comment: "Day calendar, spoken: how many bathroom visits were counted that day. Needs a plural variation; English also needs '1 bathroom visit'.")
    }

    /// "9,875 steps".
    static func stepsSpoken(_ count: Int) -> String {
        String(localized: "bodybuilding.steps.spoken", defaultValue: "\(count) steps",
               comment: "Day calendar, spoken: steps walked that day. Needs a plural variation; English also needs '1 step'.")
    }

    /// "142 · 260 · 71 g": protein, carbs and fat in grams.
    static func macrosShort(_ macros: Macros) -> String {
        let protein = grams(macros.protein), carbs = grams(macros.carbs), fat = grams(macros.fat)
        return String(localized: "bodybuilding.macros.short", defaultValue: "\(protein) · \(carbs) · \(fat) g",
                      comment: "Day calendar: grams of protein, carbs and fat eaten that day, in that order, e.g. '142 · 260 · 71 g'")
    }

    /// "142 grams of protein, 260 grams of carbs, 71 grams of fat".
    static func macrosSpoken(_ macros: Macros) -> String {
        let protein = grams(macros.protein), carbs = grams(macros.carbs), fat = grams(macros.fat)
        return String(localized: "bodybuilding.macros.spoken",
                      defaultValue: "\(protein) grams of protein, \(carbs) grams of carbs, \(fat) grams of fat",
                      comment: "Day calendar, spoken: grams of protein, carbs and fat eaten that day")
    }

    /// A gram figure as a whole number.
    private static func grams(_ value: Int) -> String {
        max(value, 0).formatted()
    }

    /// The training's name for the week list and the day card: the split ("Legs"), "Legs, lighter" in a
    /// deload week, or "Rest" on a day with no workout.
    static func training(_ day: BodybuildingDay) -> String {
        guard day.trained else {
            return String(localized: "bodybuilding.training.rest", defaultValue: "Rest",
                          comment: "Day calendar: a day with no workout logged (a rest day)")
        }
        let name = day.trainingName ?? String(localized: "bodybuilding.training.trained", defaultValue: "Trained",
                                              comment: "Day calendar: a day with a workout that has no name")
        guard day.isDeload else { return name }
        return String(localized: "bodybuilding.training.lighter", defaultValue: "\(name), lighter",
                      comment: "Day calendar: the day's training in a deload week, e.g. 'Legs, lighter'")
    }

    /// How the day felt: the day's last mood ("Good"), else its care score ("Care score 80%"); nil when
    /// neither is known.
    static func dayFelt(_ day: BodybuildingDay, address: TermOfAddress) -> String? {
        if let feeling = day.feeling { return feeling.label(addressing: address) }
        guard let score = day.careScore else { return nil }
        return String(localized: "worldToday.careScore", defaultValue: "Care score \(score)%",
                      comment: "World Today panel, Today card: the care score beside its hearts")
    }
}

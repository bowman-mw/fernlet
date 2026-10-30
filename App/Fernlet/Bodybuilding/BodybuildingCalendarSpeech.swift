//
//  BodybuildingCalendarSpeech.swift
//  Fernlet
//
//  What VoiceOver says for a Day calendar day (World round 7, piece C; spec §2, §3, §8–§10): each month
//  cell and each week row is one element that reads the day, where it sits (today, a deload week, the
//  suggested deload week) and the signals it draws, e.g. "Wednesday 21, deload week, trained legs,
//  8 hours of sleep, 3 bathroom visits". A signal with nothing logged is left out, never read as a gap.
//

import FernletDomainModel
import Foundation

/// The Day calendar's spoken summaries and the day card's row values.
nonisolated enum BodybuildingCalendarSpeech {
    /// One day's spoken summary: its name, where it sits, then each of `signals` that has a value.
    static func summary(for day: BodybuildingDay, signals: [BodybuildingSignal], calendar: Calendar,
                        address: TermOfAddress) -> String {
        var parts = [BodybuildingCalendarCopy.dayTitle(day.dateKey, calendar: calendar)]
        parts += placement(of: day)
        if !day.isFuture {
            parts += signals.prefix(BodybuildingSignal.allCases.count).compactMap { spoken($0, day: day, address: address) }
        }
        return parts.joined(separator: ", ")
    }

    /// Today, still to come, a deload week, the suggested deload week: what the day's frame shows.
    static func placement(of day: BodybuildingDay) -> [String] {
        var parts: [String] = []
        if day.isToday {
            parts.append(String(localized: "bodybuilding.spoken.today", defaultValue: "today",
                                comment: "Day calendar, spoken after a day's name: the day is today"))
        }
        if day.isFuture {
            parts.append(String(localized: "bodybuilding.spoken.future", defaultValue: "still to come",
                                comment: "Day calendar, spoken after a day's name: the day has not happened yet"))
        }
        if day.isDeload {
            parts.append(String(localized: "bodybuilding.spoken.deload", defaultValue: "deload week",
                                comment: "Day calendar, spoken after a day's name: the day is in a deload week (a planned lighter training week)"))
        } else if day.isSuggestedDeload {
            parts.append(String(localized: "bodybuilding.spoken.suggestedDeload", defaultValue: "suggested deload week",
                                comment: "Day calendar, spoken after a day's name: Fernlet suggests this week as a deload week; nothing is decided yet"))
        }
        return parts
    }

    /// One signal as spoken, or nil when the day holds nothing for it.
    static func spoken(_ signal: BodybuildingSignal, day: BodybuildingDay, address: TermOfAddress) -> String? {
        switch signal {
        case .training: return trainingSpoken(day)
        case .sleep: return day.sleepHours.map(BodybuildingCalendarCopy.sleepSpoken)
        case .bathroom: return day.bathroomVisits.map(BodybuildingCalendarCopy.bathroomSpoken)
        case .freeMeals:
            guard day.freeMeal else { return nil }
            return String(localized: "bodybuilding.spoken.freeMeal", defaultValue: "free meal",
                          comment: "Day calendar, spoken: a meal that day carries the Free meal tag (a planned, relaxed meal; never 'cheat')")
        case .weight: return day.weightKilograms.map(BodybuildingCalendarCopy.weight)
        case .steps: return day.steps.map(BodybuildingCalendarCopy.stepsSpoken)
        case .macros:
            guard day.macros.protein + day.macros.carbs + day.macros.fat > 0 else { return nil }
            return BodybuildingCalendarCopy.macrosSpoken(day.macros)
        case .dayFelt: return BodybuildingCalendarCopy.dayFelt(day, address: address)
        }
    }

    /// "trained legs", "trained", or "rest day".
    private static func trainingSpoken(_ day: BodybuildingDay) -> String {
        guard day.trained else {
            return String(localized: "bodybuilding.spoken.rest", defaultValue: "rest day",
                          comment: "Day calendar, spoken: no workout was logged that day")
        }
        guard let name = day.trainingName else {
            return String(localized: "bodybuilding.spoken.trained", defaultValue: "trained",
                          comment: "Day calendar, spoken: a workout was logged that day")
        }
        return String(localized: "bodybuilding.spoken.trainedName", defaultValue: "trained \(name)",
                      comment: "Day calendar, spoken: the workout logged that day, e.g. 'trained legs'")
    }

    /// The day card's value for `signal`: what the row draws and what VoiceOver reads after the name.
    /// A signal with nothing logged draws a dash and reads "none".
    static func cardValue(_ signal: BodybuildingSignal, day: BodybuildingDay,
                          address: TermOfAddress) -> (shown: String, spoken: String) {
        if let both = cardValueIfLogged(signal, day: day, address: address) { return both }
        return ("–", String(localized: "bodybuilding.value.none", defaultValue: "None",
                            comment: "Day calendar day card, spoken: nothing is logged for this signal that day"))
    }

    /// The day card's value when the day holds one.
    private static func cardValueIfLogged(_ signal: BodybuildingSignal, day: BodybuildingDay,
                                          address: TermOfAddress) -> (shown: String, spoken: String)? {
        switch signal {
        case .weight: return day.weightKilograms.map { (shown: BodybuildingCalendarCopy.weight($0), spoken: BodybuildingCalendarCopy.weight($0)) }
        case .sleep: return day.sleepHours.map { (shown: BodybuildingCalendarCopy.sleepShort($0), spoken: BodybuildingCalendarCopy.sleepSpoken($0)) }
        case .bathroom: return day.bathroomVisits.map { (shown: $0.formatted(), spoken: BodybuildingCalendarCopy.bathroomSpoken($0)) }
        case .training:
            let name = BodybuildingCalendarCopy.training(day)
            return (name, name)
        case .steps: return day.steps.map { (shown: $0.formatted(), spoken: BodybuildingCalendarCopy.stepsSpoken($0)) }
        case .macros:
            guard day.macros.protein + day.macros.carbs + day.macros.fat > 0 else { return nil }
            return (BodybuildingCalendarCopy.macrosShort(day.macros), BodybuildingCalendarCopy.macrosSpoken(day.macros))
        case .freeMeals:
            let word = day.freeMeal
                ? String(localized: "bodybuilding.value.yes", defaultValue: "Yes", comment: "Day calendar day card: a meal that day is tagged Free meal")
                : String(localized: "bodybuilding.value.no", defaultValue: "No", comment: "Day calendar day card: no meal that day is tagged Free meal")
            return (word, word)
        case .dayFelt: return BodybuildingCalendarCopy.dayFelt(day, address: address).map { (shown: $0, spoken: $0) }
        }
    }
}

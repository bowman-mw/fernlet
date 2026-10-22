// WidgetThoughtLines.swift
// FernletWidgets
//
// The companion's lines on the thought widget: a widget-only set of whole sentences, chosen by the
// day's state and the time of day (design round 2, 2026-10-21). Never the app's Home thought, which
// can quote today's journal tag or draw on the AI's memory — neither may reach the Home Screen.

import Foundation

/// The part of the day a thought belongs to: morning until noon, then afternoon until the person's
/// bedtime (the sleepy wind-down), then the night once the companion is asleep.
///
/// The bedtime and night slots come from the emotion timeline the app publishes, so they follow the
/// person's own bedtime rather than a fixed clock (owner decision 2026-10-21).
enum WidgetThoughtSlot: Equatable {
    case morning
    case afternoon
    case bedtime
    case night

    /// The slot at `date` for the feeling drawn then.
    static func at(_ date: Date, emotion: WidgetCompanionEmotion?, calendar: Calendar = .current) -> WidgetThoughtSlot {
        if emotion == .asleep { return .night }
        if emotion == .sleepy { return .bedtime }
        return calendar.component(.hour, from: date) < 12 ? .morning : .afternoon
    }
}

/// The widget's own lines. Each is one whole localized sentence — never assembled from parts, never
/// built from a tag — keyed `widget.thought.<state>.<slot>`.
enum WidgetThoughtLines {
    /// The line for a state and slot. Asleep has one set of lines whatever the state, because an
    /// asleep companion says nothing about the day; a day with no state yet speaks gently.
    static func line(state: WidgetCompanionState?, slot: WidgetThoughtSlot) -> String {
        if slot == .night { return asleepLine }
        guard let state else { return freshDayLine }
        switch state {
        case .thriving: return thriving(slot)
        case .okay: return okay(slot)
        case .tired: return tired(slot)
        case .resting: return resting(slot)
        case .sick: return sick(slot)
        }
    }

    private static var asleepLine: String {
        String(localized: "widget.thought.asleep", defaultValue: "Sleeping soundly.",
               comment: "The companion's line on the thought widget while it is asleep. Says nothing about how the day went")
    }

    private static var freshDayLine: String {
        String(localized: "widget.thought.freshDay", defaultValue: "A brand-new day.",
               comment: "The companion's line on the thought widget before the app has worked out today's state")
    }

    private static func thriving(_ slot: WidgetThoughtSlot) -> String {
        switch slot {
        case .morning: String(localized: "widget.thought.thriving.morning", defaultValue: "Woke up feeling light today.",
                              comment: "Companion's line on the thought widget: a thriving day, morning")
        case .afternoon: String(localized: "widget.thought.thriving.afternoon", defaultValue: "The sun found me this afternoon.",
                                comment: "Companion's line on the thought widget: a thriving day, afternoon")
        case .bedtime, .night: String(localized: "widget.thought.thriving.bedtime", defaultValue: "Getting cozy for the night.",
                                      comment: "Companion's line on the thought widget: a thriving day, at bedtime")
        }
    }

    private static func okay(_ slot: WidgetThoughtSlot) -> String {
        switch slot {
        case .morning: String(localized: "widget.thought.okay.morning", defaultValue: "Taking the morning slowly.",
                              comment: "Companion's line on the thought widget: an okay day, morning")
        case .afternoon: String(localized: "widget.thought.okay.afternoon", defaultValue: "Just pottering about.",
                                comment: "Companion's line on the thought widget: an okay day, afternoon")
        case .bedtime, .night: String(localized: "widget.thought.okay.bedtime", defaultValue: "Winding down now.",
                                      comment: "Companion's line on the thought widget: an okay day, at bedtime")
        }
    }

    private static func tired(_ slot: WidgetThoughtSlot) -> String {
        switch slot {
        case .morning: String(localized: "widget.thought.tired.morning", defaultValue: "Still a little sleepy. That's okay.",
                              comment: "Companion's line on the thought widget: a tired day, morning. Gentle, never a nudge")
        case .afternoon: String(localized: "widget.thought.tired.afternoon", defaultValue: "A slow sort of day.",
                                comment: "Companion's line on the thought widget: a tired day, afternoon")
        case .bedtime, .night: String(localized: "widget.thought.tired.bedtime", defaultValue: "Ready for a long rest.",
                                      comment: "Companion's line on the thought widget: a tired day, at bedtime")
        }
    }

    private static func resting(_ slot: WidgetThoughtSlot) -> String {
        switch slot {
        case .morning: String(localized: "widget.thought.resting.morning", defaultValue: "Curled up a while longer.",
                              comment: "Companion's line on the thought widget: a resting day, morning")
        case .afternoon: String(localized: "widget.thought.resting.afternoon", defaultValue: "Having a quiet nap.",
                                comment: "Companion's line on the thought widget: a resting day, afternoon")
        case .bedtime, .night: String(localized: "widget.thought.resting.bedtime", defaultValue: "Snuggling in for the night.",
                                      comment: "Companion's line on the thought widget: a resting day, at bedtime")
        }
    }

    private static func sick(_ slot: WidgetThoughtSlot) -> String {
        switch slot {
        case .morning: String(localized: "widget.thought.sick.morning", defaultValue: "Taking it gently today.",
                              comment: "Companion's line on the thought widget: an unwell day, morning. Never suggests exercise")
        case .afternoon: String(localized: "widget.thought.sick.afternoon", defaultValue: "Tucked in with a blanket.",
                                comment: "Companion's line on the thought widget: an unwell day, afternoon")
        case .bedtime, .night: String(localized: "widget.thought.sick.bedtime", defaultValue: "Resting up for tomorrow.",
                                      comment: "Companion's line on the thought widget: an unwell day, at bedtime")
        }
    }
}

// WorkoutActivityLoadText.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The words for a set's load on the guided-workout Live Activity: the weight the runner shows, the
// engine's range, and last time's numbers — drawn ("105 lb", "95–110 lb", "Last time: 3 × 8 @ 100 lb")
// and spoken ("Suggested weight 105 pounds, range 95 to 110 pounds, last time 3 by 8 at 100 pounds").
// The content state carries numbers and unit tokens only; every word and number format is chosen here,
// in the reading process's own locale.
//
// Dual membership: the widget draws these, the app's runner formats its weights through the same
// `weight(_:unit:width:locale:)` and `range(low:high:unit:locale:)`, so the Lock Screen and the
// weight panel never show one weight two ways, and the unit tests reach every string. Neither target
// is an SPM module, so `String(localized:)` resolves against `Bundle.main` — the widget's catalog in
// the extension, the app's in the app — and both catalogs carry the same English keys.
//
// S3 wall: Foundation only. No domain import — units cross as `LoadUnit` raw tokens ("lb" / "kg").

import Foundation

/// Formats a set's load for the guided-workout Live Activity, drawn and spoken.
///
/// Pure functions of a ``WorkoutActivityAttributes/ContentState/Load`` and a locale; nothing here
/// reads a clock or a store. Weights use the locale's number format with at most one decimal and the
/// unit as given (`usage: .asProvided` — a 45 lb plate is never converted to 20.4 kg). A weight with
/// no unit token is drawn as a bare number rather than with a guessed unit. `nonisolated`: pure, so
/// the widget's views, the app's runner and the tests can all call it.
nonisolated enum WorkoutActivityLoadText {
    /// The load a content state carries.
    typealias Load = WorkoutActivityAttributes.ContentState.Load

    /// The mass unit a `LoadUnit` raw token names, or nil for none or an unknown token.
    static func unit(_ raw: String?) -> UnitMass? {
        switch raw {
        case "kg": return .kilograms
        case "lb": return .pounds
        default: return nil
        }
    }

    /// One weight in the locale's format: "105 lb" or "62,5 kg" abbreviated, "105 pounds" wide (the
    /// spoken form). A bare number when `unit` is nil.
    static func weight(_ value: Double, unit: UnitMass?, width: Measurement<UnitMass>.FormatStyle.UnitWidth,
                       locale: Locale) -> String {
        guard let unit else { return number(value, locale: locale) }
        let digits = FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(0...1))
        let style = Measurement<UnitMass>.FormatStyle(width: width, locale: locale, usage: .asProvided,
                                                      numberFormatStyle: digits)
        return Measurement(value: value, unit: unit).formatted(style)
    }

    /// A range as drawn: "95–110 lb" (the unit once, after the top), the runner's own shape. One weight
    /// when the range is a single step; nil when either end is missing.
    static func range(low: Double?, high: Double?, unit: UnitMass?, locale: Locale) -> String? {
        guard let low, let high else { return nil }
        guard high - low > 0.01 else { return weight(low, unit: unit, width: .abbreviated, locale: locale) }
        return "\(number(low, locale: locale))–\(weight(high, unit: unit, width: .abbreviated, locale: locale))"
    }

    /// A bare number in the locale's format, at most one decimal ("62,5").
    static func number(_ value: Double, locale: Locale) -> String {
        value.formatted(FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(0...1)))
    }

    // MARK: Drawn

    /// The set's weight as the runner shows it — the suggestion until the lifter picks another — or nil.
    static func weightText(_ load: Load, locale: Locale = .current) -> String? {
        guard let value = load.weight, value.isFinite, value > 0 else { return nil }
        return weight(value, unit: unit(load.unitRaw), width: .abbreviated, locale: locale)
    }

    /// The engine's range ("95–110 lb"), or nil when it gave none or only one weight.
    static func rangeText(_ load: Load, locale: Locale = .current) -> String? {
        guard let low = load.rangeLow, let high = load.rangeHigh, high - low > 0.01 else { return nil }
        return range(low: low, high: high, unit: unit(load.unitRaw), locale: locale)
    }

    /// Whether the load has a weight or a range to draw — the weight stack beside the countdown.
    static func drawsWeight(_ load: Load) -> Bool {
        weightText(load) != nil || rangeText(load) != nil
    }

    /// Last time's numbers as drawn: "3 × 8 @ 100 lb", "3 × 8" with no weight, "100 lb" with no sets;
    /// nil when there are none.
    static func lastNumbers(_ load: Load, locale: Locale = .current) -> String? {
        let lastWeight = lastWeightText(load, width: .abbreviated, locale: locale)
        guard let sets = load.lastSets, sets > 0, let reps = load.lastReps, !reps.isEmpty else { return lastWeight }
        guard let lastWeight else {
            return String(localized: "\(sets) × \(reps)", locale: locale,
                          comment: "Live Activity: last time's sets × reps for this lift, e.g. '3 × 8'. Reps are as logged ('8', '8-10').")
        }
        return String(localized: "\(sets) × \(reps) @ \(lastWeight)", locale: locale,
                      comment: "Live Activity: last time's sets × reps @ weight for this lift, e.g. '3 × 8 @ 100 lb'. The weight arrives formatted with its unit.")
    }

    /// "Last time: 3 × 8 @ 100 lb", or nil when this lift was never logged — the workout editor's own
    /// "Last time: …" key, so the line reads the same everywhere it appears.
    static func lastTimeLine(_ load: Load, locale: Locale = .current) -> String? {
        guard let numbers = lastNumbers(load, locale: locale) else { return nil }
        return String(localized: "Last time: \(numbers)", locale: locale)
    }

    // MARK: Spoken

    /// The whole load as one VoiceOver sentence — "Suggested weight 105 pounds, range 95 to 110
    /// pounds, last time 3 by 8 at 100 pounds" — or nil when there is nothing to say.
    ///
    /// Each clause is a whole localized phrase; the locale's list format joins them (a comma list in
    /// English), so no clause is assembled from fragments.
    static func spokenSummary(_ load: Load, locale: Locale = .current) -> String? {
        let clauses = [spokenWeight(load, locale: locale), spokenRange(load, locale: locale),
                       spokenLastTime(load, locale: locale)].compactMap { $0 }
        guard !clauses.isEmpty else { return nil }
        return clauses.formatted(.list(type: .and, width: .narrow).locale(locale))
    }

    /// "Suggested weight 105 pounds" while the weight is still the suggestion, "Weight 110 pounds"
    /// once the lifter picked their own; nil without a weight.
    static func spokenWeight(_ load: Load, locale: Locale = .current) -> String? {
        guard let value = load.weight, value.isFinite, value > 0 else { return nil }
        let words = weight(value, unit: unit(load.unitRaw), width: .wide, locale: locale)
        guard let suggested = load.suggested, abs(suggested - value) < 0.01 else {
            return String(localized: "Weight \(words)", locale: locale,
                          comment: "VoiceOver, Live Activity: the weight the lifter picked for this set, e.g. 'Weight 110 pounds'.")
        }
        return String(localized: "Suggested weight \(words)", locale: locale,
                      comment: "VoiceOver, Live Activity: the weight Fernlet suggests for this set, e.g. 'Suggested weight 105 pounds'.")
    }

    /// "range 95 to 110 pounds", or nil without a range of more than one weight.
    static func spokenRange(_ load: Load, locale: Locale = .current) -> String? {
        guard let low = load.rangeLow, let high = load.rangeHigh, high - low > 0.01 else { return nil }
        let lowWords = number(low, locale: locale)
        let highWords = weight(high, unit: unit(load.unitRaw), width: .wide, locale: locale)
        return String(localized: "range \(lowWords) to \(highWords)", locale: locale,
                      comment: "VoiceOver, Live Activity: the weight range for this set, spoken after the weight, e.g. 'range 95 to 110 pounds'.")
    }

    /// "last time 3 by 8 at 100 pounds" (or without the weight, or the weight alone), or nil.
    static func spokenLastTime(_ load: Load, locale: Locale = .current) -> String? {
        let lastWeight = lastWeightText(load, width: .wide, locale: locale)
        guard let sets = load.lastSets, sets > 0, let reps = load.lastReps, !reps.isEmpty else {
            return lastWeight.map {
                String(localized: "last time \($0)", locale: locale,
                       comment: "VoiceOver, Live Activity: last time's weight for this lift, e.g. 'last time 100 pounds'.")
            }
        }
        guard let lastWeight else {
            return String(localized: "last time \(sets) by \(reps)", locale: locale,
                          comment: "VoiceOver, Live Activity: last time's sets by reps for this lift, e.g. 'last time 3 by 8'.")
        }
        return String(localized: "last time \(sets) by \(reps) at \(lastWeight)", locale: locale,
                      comment: "VoiceOver, Live Activity: last time's sets by reps at weight, e.g. 'last time 3 by 8 at 100 pounds'.")
    }

    /// Last time's weight in the given width, or nil without one.
    private static func lastWeightText(_ load: Load, width: Measurement<UnitMass>.FormatStyle.UnitWidth,
                                       locale: Locale) -> String? {
        guard let value = load.lastWeight, value.isFinite, value > 0 else { return nil }
        return weight(value, unit: unit(load.lastUnitRaw), width: width, locale: locale)
    }
}

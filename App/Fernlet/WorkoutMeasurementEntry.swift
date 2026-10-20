//
//  WorkoutMeasurementEntry.swift
//  Fernlet
//
//  The display/entry boundary for workout distance and treadmill speed (2026-10-20, idea 16).
//  Storage stays in US units exactly as before — `Workout.distanceMiles`,
//  `PlannedWorkout.targetDistanceMiles`, HealthKit's mile quantity, the trainer export's
//  `distanceMiles`, and a treadmill line's "5.5 mph" — the way enum raw values stay stable English
//  tokens. What a person types and reads follows the device's measurement system, as Apple Fitness
//  does (2026-10-20, N9): miles and mph where `Locale.measurementSystem` is `.us` or `.uk` — the UK
//  is metric but reads road distance and speed in miles — and kilometres and km/h on `.metric`.
//
//  Loads and the body are a different rule: pounds, and body weight and height in US units, only
//  where the system is `.us` (`WorkoutLoadContextBuilder.defaultUnit(for:)`, `BodyMeasurementEntry`),
//  because a UK gym's plates and scales read kilograms.
//

import Foundation
import FernletDomainModel

/// Converts stored miles and mph to and from the units a person reads.
///
/// Every member takes an optional `imperial` override (nil reads the device) so the conversions are
/// testable without changing the process locale. `nonisolated` and stateless: the line helpers run
/// inside views and the parsers inside the sheets' static rules.
nonisolated enum WorkoutMeasurementEntry {

    /// Kilometres in one statute mile (exact, by definition).
    static let kilometersPerMile = 1.609344

    /// Whether this device reads miles and mph. Read per call, never cached, so a change of region
    /// shows on the next draw.
    static var usesImperial: Bool { readsImperial(Locale.current) }

    /// Whether `locale` reads distance in miles and speed in mph: the US system, and the UK's (which
    /// is metric everywhere but the road). Every other system reads kilometres and km/h.
    static func readsImperial(_ locale: Locale) -> Bool {
        locale.measurementSystem == .us || locale.measurementSystem == .uk
    }

    // MARK: - Distance

    /// The miles to STORE for a Distance field's text: miles as typed on an imperial device,
    /// kilometres converted elsewhere. Nil when the text is not a number.
    static func miles(fromEntry text: String, imperial: Bool? = nil) -> Double? {
        guard let value = LocaleTolerantNumber.double(from: text) else { return nil }
        return (imperial ?? usesImperial) ? value : value / kilometersPerMile
    }

    /// The Distance field's text for a stored distance: exactly what the plan sheet seeded before on
    /// an imperial device (`String(miles)`), kilometres with up to two decimals in the device's own
    /// number format elsewhere.
    static func entryText(miles: Double, imperial: Bool? = nil, locale: Locale = .current) -> String {
        guard !(imperial ?? usesImperial) else { return String(miles) }
        let kilometers = miles * kilometersPerMile
        return kilometers.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
    }

    /// A stored distance as a person reads it: "3.1 mi", or "5 km".
    static func distanceText(miles: Double, imperial: Bool? = nil, locale: Locale = .current) -> String {
        let stored = Measurement(value: miles, unit: UnitLength.miles)
        let shown = (imperial ?? usesImperial) ? stored : stored.converted(to: .kilometers)
        return shown.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                            numberFormatStyle: .number.precision(.fractionLength(0...2))).locale(locale))
    }

    // MARK: - Treadmill speed

    /// The speed a treadmill line STORES before its " mph": the typed text unchanged on an imperial
    /// device (what the line always held), the typed km/h converted to mph elsewhere, written with a
    /// "." and at most two decimals so it reads back the same on any device. Text that is not a number
    /// is kept as typed.
    static func storedSpeed(fromEntry text: String, imperial: Bool? = nil) -> String {
        guard !(imperial ?? usesImperial), let kmh = LocaleTolerantNumber.double(from: text) else { return text }
        let mph = kmh / kilometersPerMile
        return mph.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }

    /// The Speed field's text for a stored line's mph value: unchanged on an imperial device, km/h
    /// with up to one decimal in the device's number format elsewhere — the inverse of
    /// ``storedSpeed(fromEntry:imperial:)``, so reopening and re-saving a line writes it back unchanged.
    static func speedEntry(fromStored mph: String, imperial: Bool? = nil, locale: Locale = .current) -> String {
        guard !(imperial ?? usesImperial), let value = LocaleTolerantNumber.double(from: mph) else { return mph }
        let kmh = value * kilometersPerMile
        return kmh.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))
    }

    /// One logged or planned line as a screen draws it: the planner's frozen descriptors in the
    /// user's language (``WorkoutPlanLine``), then every "5.5 mph" in km/h on a metric device. The
    /// stored line is never changed.
    static func drawnLine(_ line: String, imperial: Bool? = nil, locale: Locale = .current) -> String {
        displayedSpeeds(in: WorkoutPlanLine.displayed(line), imperial: imperial, locale: locale)
    }

    /// `line` with each "<number> mph" read in km/h on a metric device; unchanged on an imperial one.
    static func displayedSpeeds(in line: String, imperial: Bool? = nil, locale: Locale = .current) -> String {
        guard !(imperial ?? usesImperial), line.contains("mph"),
              let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*mph\b"#) else { return line }
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        var result = line
        // Last match first, so the earlier matches' ranges still point at unchanged text.
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result), let number = Range(match.range(at: 1), in: result),
                  let mph = LocaleTolerantNumber.double(from: String(result[number])) else { continue }
            result.replaceSubrange(whole, with: speedText(mph: mph, locale: locale))
        }
        return result
    }

    /// A stored mph value as a metric reader reads it: "9 km/h".
    static func speedText(mph: Double, locale: Locale = .current) -> String {
        Measurement(value: mph, unit: UnitSpeed.milesPerHour).converted(to: .kilometersPerHour)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0...1))).locale(locale))
    }
}

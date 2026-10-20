// WorkoutActivityZoneText.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The words for a guided cardio segment's heart-rate cue (comparison report idea 9, roadmap step 4b,
// 2026-10-20): the live reading against its target ("118 bpm · aim 110–125"), where it sits ("in
// range", "a little high", "a little low"), the same said in full for VoiceOver, and the talk test
// that stands in whenever there is no live reading. The content state carries numbers only
// (`WorkoutActivityAttributes.ContentState.Zone`); every word is chosen here, in the reading process's
// own locale, so the Lock Screen, the Dynamic Island and the runner never word one reading two ways.
//
// Gentle by rule: "aim", "a little high", never a warning, never colour alone. Neither target is an
// SPM module, so `String(localized:)` resolves against `Bundle.main` — the widget's catalog in the
// extension, the app's in the app — and both catalogs carry the same English keys.
//
// S3 wall: Foundation only. No domain import; the zone crosses as plain integers.

import Foundation

/// Words a cardio segment's heart-rate cue for the Live Activity and the runner, drawn and spoken.
///
/// Pure functions of a ``WorkoutActivityAttributes/ContentState/Zone`` and a locale; nothing here reads
/// a clock, a store or a sensor. A cue with a live reading (``WorkoutActivityAttributes/ContentState/Zone/isLive``)
/// is worded as the reading; one without it as the talk test for its target zone. `nonisolated`: pure, so
/// the widget's views, the app's runner and the tests can all call it.
nonisolated enum WorkoutActivityZoneText {
    /// The cue a content state carries.
    typealias Zone = WorkoutActivityAttributes.ContentState.Zone

    /// The highest target zone the talk test words as "short sentences"; above it, "a few words".
    static let conversationalZoneLimit = 3

    /// "118 bpm · aim 110–125", or nil without a live reading.
    static func readout(_ zone: Zone, locale: Locale = .current) -> String? {
        guard let bpm = zone.bpm, let range = zone.range, zone.isLive else { return nil }
        return String(localized: "\(bpm) bpm · aim \(range.lowerBound)–\(range.upperBound)", locale: locale,
                      comment: "Guided cardio, Live Activity and runner: the live heart rate in beats per minute and the target range to aim for, e.g. '118 bpm · aim 110–125'. Gentle: 'aim', never a limit.")
    }

    /// The Lock Screen's and the Dynamic Island's one line: the live reading with where it sits — "118
    /// bpm · aim 110–125 · in range" — or, with no live reading, the short talk test. Nil when the cue
    /// names nothing at all.
    static func line(_ zone: Zone, locale: Locale = .current) -> String? {
        guard let bpm = zone.bpm, let range = zone.range, let band = zone.band else {
            return talkTest(zone, locale: locale)
        }
        let word = bandWord(band, locale: locale)
        return String(localized: "\(bpm) bpm · aim \(range.lowerBound)–\(range.upperBound) · \(word)", locale: locale,
                      comment: "Guided cardio, Live Activity: the live heart rate, the range to aim for and where it sits, on one line, e.g. '118 bpm · aim 110–125 · in range'. The last part is 'in range', 'a little high' or 'a little low'.")
    }

    /// Where a live reading sits, in a calm word: "in range", "a little high" or "a little low".
    static func bandWord(_ band: Zone.Band, locale: Locale = .current) -> String {
        switch band {
        case .inRange:
            String(localized: "in range", locale: locale,
                   comment: "Guided cardio: the live heart rate is inside the target range. Calm, lower case, said beside the reading.")
        case .high:
            String(localized: "a little high", locale: locale,
                   comment: "Guided cardio: the live heart rate is above the target range. Gentle — never a warning; the person may ease off if they like.")
        case .low:
            String(localized: "a little low", locale: locale,
                   comment: "Guided cardio: the live heart rate is below the target range. Gentle — never a push.")
        }
    }

    /// The whole live cue as one VoiceOver sentence — "Heart rate 118, aiming for 110 to 125, a little
    /// high" — or nil without a live reading.
    static func spoken(_ zone: Zone, locale: Locale = .current) -> String? {
        guard let bpm = zone.bpm, let range = zone.range, let band = zone.band else { return nil }
        let word = bandWord(band, locale: locale)
        return String(localized: "Heart rate \(bpm), aiming for \(range.lowerBound) to \(range.upperBound), \(word)",
                      locale: locale,
                      comment: "VoiceOver, guided cardio: the live heart rate, the range to aim for and where it sits, e.g. 'Heart rate 118, aiming for 110 to 125, a little high'. The last part is 'in range', 'a little high' or 'a little low'.")
    }

    /// The short talk test for the Lock Screen and the Dynamic Island when there is no live reading:
    /// "Aim: talk in short sentences" for zone 2, "Aim: a few words at a time" for zone 4. Nil when the
    /// cue names no target.
    static func talkTest(_ zone: Zone, locale: Locale = .current) -> String? {
        guard let target = zone.target else { return nil }
        guard target > conversationalZoneLimit else {
            return String(localized: "Aim: talk in short sentences", locale: locale,
                          comment: "Guided cardio, Live Activity: the talk test for an easy or steady part (heart-rate zone 2), shown when there is no live heart rate. Short — it shares a line with the countdown.")
        }
        return String(localized: "Aim: a few words at a time", locale: locale,
                      comment: "Guided cardio, Live Activity: the talk test for an interval's hard part (heart-rate zone 4), shown when there is no live heart rate. Short — it shares a line with the countdown.")
    }
}

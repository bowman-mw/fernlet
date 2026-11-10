// WorkoutInjuryEasing.swift
// FernletDomainModel
//
// "No longer an issue" (the owner's fix s5, 2026-11-10): the one switch that ends an injured area's
// limit without a cliff. Turning it on for an area in Workout setup → Areas to work around gives the
// area the Mild treatment — lighter, supported moves, no calibration or max test — for two weeks from
// the next workout logged, and then the area returns to normal by itself. No stages, no check-ins, no
// episodes: one token per area.
//
// The stored shape (``WorkoutProfile/injuryEasingTokens``, the settings blob's top-level
// `workoutInjuryEasing`): a JSON object of area token → one string, either
// - ``InjuryEasing/pendingToken`` — the switch is on and no workout has been logged since; or
// - a day key ("2026-11-12") — the day of the first workout logged after the switch went on. The
//   area is eased from then for ``InjuryEasing/days`` days, and has no limit at all after that.
// The token replaces whatever the picker and the free-text note say about its area for as long as it
// is there: the picker's severity is ignored (and tidied away the next time the setup sheet is saved),
// and a limit that came from the note stops applying — the note's text is never edited, and the
// section says under it that it is no longer applied. Turning the switch off removes the token and
// the area is exactly what the picker and the note say again.
//
// Optional and additive: a blob without the key decodes to no tokens and plans as before, and the key
// is written only when a token exists. The map is carried verbatim, so an area or a value a newer
// build wrote survives a re-save here; a value this build cannot read is treated as easing — the safe
// direction, as an unknown severity reads as severe. A build older than this one never sees the key
// (its top-level key parking keeps it) and goes on applying the picker's stored severity: stricter
// than intended, never looser. The tokens are FROZEN (the localization wall).

import Foundation
import FernletFoundation

/// Where an area marked "No longer an issue" stands on a given day.
public nonisolated enum InjuryEasingState: Equatable, Sendable {
    /// Being eased back in: the Mild treatment.
    case easing
    /// The two weeks are over: no limit, from the picker or from the note.
    case healed
}

/// The rules of the "No longer an issue" switch: its tokens, its length, and what a token means today.
///
/// Pure and deterministic over a token and a day key.
public nonisolated enum InjuryEasing {
    /// The FROZEN token of a switch that is on with no workout logged since.
    public static let pendingToken = "pending"
    /// How long the Mild treatment lasts once the first workout is logged: two weeks.
    public static let days = 14
    /// The most tokens kept: one per body area, with room for areas a newer build adds.
    public static let maxEntries = 32

    /// What `token` means on `todayKey`: easing while pending or inside the two weeks from its day
    /// key, healed after them. A token this build cannot read is easing (the safe direction).
    public static func state(token: String, todayKey: String) -> InjuryEasingState {
        guard token != pendingToken, let start = FernletDate.date(fromDayKey: token),
              let today = FernletDate.date(fromDayKey: todayKey) else { return .easing }
        let elapsed = Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
        return elapsed >= days ? .healed : .easing
    }

    /// The last day the Mild treatment applies for a started token; nil while it is pending or
    /// unreadable.
    public static func lastEasedDay(token: String) -> Date? {
        guard token != pendingToken, let start = FernletDate.date(fromDayKey: token) else { return nil }
        return Calendar.current.date(byAdding: .day, value: days - 1, to: start)
    }

    /// A decoded token map, bounded: at most ``maxEntries`` pairs in key order, each key and value
    /// no longer than ``EnumDecodeCompat/unknownTokenLengthLimit``.
    static func bounded(_ tokens: [String: String]) -> [String: String] {
        let limit = EnumDecodeCompat.unknownTokenLengthLimit
        var kept: [String: String] = [:]
        for key in tokens.keys.sorted().prefix(maxEntries) {
            guard let value = tokens[key], !key.isEmpty, !value.isEmpty, key.count <= limit, value.count <= limit else { continue }
            kept[key] = value
        }
        return kept
    }
}

extension WorkoutProfile {
    /// The areas marked "No longer an issue", each with its stored token — the areas this build
    /// knows only (a newer build's stay in ``injuryEasingTokens`` untouched).
    public var injuryEasing: [BodyArea: String] {
        var typed: [BodyArea: String] = [:]
        for (key, value) in injuryEasingTokens {
            guard let area = BodyArea(rawValue: key) else { continue }
            typed[area] = value
        }
        return typed
    }

    /// Replaces the tokens of the areas this build knows with `typed`, keeping any other area's
    /// token as it was stored. What the setup sheet saves.
    public mutating func setInjuryEasing(_ typed: [BodyArea: String]) {
        var tokens = injuryEasingTokens.filter { BodyArea(rawValue: $0.key) == nil }
        for (area, token) in typed where !token.isEmpty { tokens[area.rawValue] = token }
        injuryEasingTokens = InjuryEasing.bounded(tokens)
    }

    /// Where each area marked "No longer an issue" stands on `todayKey`.
    public func injuryEasingStates(todayKey: String) -> [BodyArea: InjuryEasingState] {
        injuryEasing.mapValues { InjuryEasing.state(token: $0, todayKey: todayKey) }
    }

    /// Starts the two weeks of every area still waiting for a workout: called when a workout is
    /// logged, with the day it is logged on. Returns whether anything changed (so the caller saves
    /// only then). An area already started keeps its day.
    @discardableResult
    public mutating func startInjuryEasing(onDayKey dayKey: String) -> Bool {
        guard FernletDate.date(fromDayKey: dayKey) != nil else { return false }
        var changed = false
        for (key, value) in injuryEasingTokens where value == InjuryEasing.pendingToken && BodyArea(rawValue: key) != nil {
            injuryEasingTokens[key] = dayKey
            changed = true
        }
        return changed
    }

    /// Takes the tokens ``FernletSettings`` decoded from its top level, bounded.
    mutating func adoptInjuryEasingTokens(_ tokens: [String: String]) {
        injuryEasingTokens = InjuryEasing.bounded(tokens)
    }

    /// The limits the planner applies today (``injuryLimits(onDayKey:)`` for the device's own day).
    public var injuryLimits: InjuryLimits {
        injuryLimits(onDayKey: FernletDate.dayKey(for: Date()))
    }

    /// The limits the planner applies on `todayKey`, combined from the picker, the note, the older
    /// avoided sets and the "No longer an issue" switch. The picker wins for an area it names;
    /// everything the note or the older sets imply on top is severe. An area with the switch on is
    /// taken out of all three and is mild while it is being eased (``InjuryEasingState/easing``),
    /// then has no limit.
    public func injuryLimits(onDayKey todayKey: String) -> InjuryLimits {
        let explicit = injuryAreas
        let note = InjuryNoteMatcher.match(injuryNotes)
        let legacy = BodyArea.legacyAreas(avoidedMuscles: avoidedMuscles, avoidedMovements: avoidedMovements)
        let easing = injuryEasingStates(todayKey: todayKey)
        let switched = Set(easing.keys)
        let implied = legacy.union(note.areas).subtracting(explicit.keys)
        let severe = Set(explicit.filter { $0.value == .severe }.keys).union(implied).subtracting(switched)
        let mild = Set(explicit.filter { $0.value == .mild }.keys).subtracting(switched)
            .union(easing.filter { $0.value == .easing }.keys)
        // An older build mirrored a severe area into the avoided sets; a switched area's share of
        // them goes too, or the mirror would keep leaving its work out (the next save of the setup
        // sheet rewrites the sets without it).
        var muscles = avoidedMuscles
        var movements = avoidedMovements
        for area in switched.intersection(legacy) {
            muscles.subtract(area.muscles)
            movements.subtract(area.movements)
        }
        return InjuryLimits(
            severeAreas: severe, mildAreas: mild,
            avoidedMuscles: muscles.union(note.muscles), avoidedMovements: movements
        )
    }
}

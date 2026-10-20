// WorkoutSessionOptions.swift
// FernletDomainModel
//
// The session-time budget and the stretch-block switches (2026-10-20, idea 5 of the comparison
// report). Until now Fernlet had no session-length input: time reached the planner only through the
// AI adjust's free text, which reshapes the lifting block alone, or the "Anything else?" note, which
// is only a name-match bias — while the owner's warm-up flow added about eight minutes before every
// first lift. These are the synced workout preferences that shape a session's length: how long it may
// run, how much of the warm-up flow it walks, and whether it ends with the cool-down. The planner reads
// them together as ``WorkoutSessionOptions``; ``WorkoutSessionBudget`` does the fitting.

import Foundation

/// How long a session may run: 20, 30, 45 or 60 minutes, or no limit.
///
/// A synced workout preference (`FernletSettings.workoutSessionLength`), overridable for one day on
/// the plan sheet. The planner fits each session into it (``WorkoutSessionBudget``); ``noLimit`` —
/// the default — plans every session exactly as before. The raw values are FROZEN tokens: persisted in
/// the settings blob and decoded tolerantly with a parked side channel (``EnumDecodeCompat``), so a
/// newer build's length survives an older build's re-save. Screens read ``displayName``.
public nonisolated enum WorkoutSessionLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case noLimit
    case min20
    case min30
    case min45
    case min60

    public var id: String { rawValue }

    /// The budget in minutes; nil for no limit.
    public var minutes: Int? {
        switch self {
        case .noLimit: nil
        case .min20: 20
        case .min30: 30
        case .min45: 45
        case .min60: 60
        }
    }

    /// The choice on screen, localized. Never persisted or matched — ``rawValue`` is the token.
    public var displayName: String {
        switch self {
        case .noLimit: String(localized: "workoutSessionLength.noLimit", defaultValue: "No limit",
                              bundle: .module, comment: "Workout session length choice: no time limit on the session")
        case .min20: String(localized: "workoutSessionLength.min20", defaultValue: "20 min",
                            bundle: .module, comment: "Workout session length choice: twenty minutes")
        case .min30: String(localized: "workoutSessionLength.min30", defaultValue: "30 min",
                            bundle: .module, comment: "Workout session length choice: thirty minutes")
        case .min45: String(localized: "workoutSessionLength.min45", defaultValue: "45 min",
                            bundle: .module, comment: "Workout session length choice: forty-five minutes")
        case .min60: String(localized: "workoutSessionLength.min60", defaultValue: "60 min",
                            bundle: .module, comment: "Workout session length choice: sixty minutes")
        }
    }
}

/// How much of the warm-up stretch flow a lifting session walks.
///
/// ``full`` (the default) is the owner's 23-step flow exactly as written
/// (``WorkoutSessionBlocks/warmUpFlow``); ``short`` is about four minutes of it, in its own order,
/// chosen for the muscles the day trains (``WorkoutSessionBlocks/shortWarmUpSeconds``); ``off``
/// leaves the warm-up out. A time budget can still swap the full flow for the short one. A synced
/// preference (`FernletSettings.workoutWarmUp`) with frozen tokens and parked decoding.
public nonisolated enum WorkoutWarmUpMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case short
    case off

    public var id: String { rawValue }

    /// The choice on screen, localized. Never persisted or matched — ``rawValue`` is the token.
    public var displayName: String {
        switch self {
        case .full: String(localized: "workoutWarmUp.full", defaultValue: "Full",
                           bundle: .module, comment: "Warm-up stretches choice: the whole stretch flow")
        case .short: String(localized: "workoutWarmUp.short", defaultValue: "Short",
                            bundle: .module, comment: "Warm-up stretches choice: about four minutes of the flow")
        case .off: String(localized: "workoutWarmUp.off", defaultValue: "Off",
                          bundle: .module, comment: "Warm-up stretches choice: no warm-up stretches")
        }
    }
}

/// Whether a lifting session ends with its cool-down stretches.
///
/// ``full`` (the default) keeps the coverage-chosen cool-down (``WorkoutSessionBlocks``), which a
/// time budget may still trim to two stretches; ``off`` leaves it out. Shown as a switch; the raw
/// values are FROZEN tokens with parked decoding (`FernletSettings.workoutCoolDown`), named so a later
/// "short" can join without a new key.
public nonisolated enum WorkoutCoolDownMode: String, Codable, CaseIterable, Sendable {
    case full
    case off
}

/// The session preferences the planner reads together: the time budget and the two stretch blocks.
///
/// Built from the synced settings (`FernletSettings.workoutSessionOptions`), with the plan sheet's
/// one-day length laid over it. The default is today's behaviour: no limit, the full warm-up flow and
/// the cool-down.
public nonisolated struct WorkoutSessionOptions: Equatable, Sendable {
    public var length: WorkoutSessionLength
    public var warmUp: WorkoutWarmUpMode
    public var coolDown: WorkoutCoolDownMode

    public init(
        length: WorkoutSessionLength = .noLimit, warmUp: WorkoutWarmUpMode = .full,
        coolDown: WorkoutCoolDownMode = .full
    ) {
        self.length = length
        self.warmUp = warmUp
        self.coolDown = coolDown
    }
}

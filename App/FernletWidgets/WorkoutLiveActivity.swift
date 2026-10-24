// WorkoutLiveActivity.swift
// FernletWidgets (widget target only — renders the activity the app requests).
//
// The Lock Screen card + Dynamic Island for the guided-workout rest timer. Registered in
// FernletWidgetsBundle. Gentle, zero-pressure copy ("Rest", "Next up", "Nicely done"), mirroring
// Fernlet/GuidedWorkout.swift.
//
// WORLD LOOK (World Review Batch 4, b4-la-workout-* and b4-di-workout-*, approved 2026-10-24): the
// Lock Screen card is paper in an ink frame, light or dark with the Lock Screen (LiveActivityLook),
// with pixel icons, Fraunces for the exercise and the countdown, pixel progress squares in the header
// and framed buttons. The Dynamic Island stays black; its icons are pixel art in leaf green, its
// numbers Fraunces, its buttons framed. Every value, control and spoken label is the same as before.
//
// CRASH RULE (a prior in-app review caught this exact bug): the rest countdown is ALWAYS rendered
// from the FIXED `restStartedAt...restEndsAt` window — never `Date()...restEndsAt`, whose lower bound
// inverts and fatalErrors once the deadline passes. `Text(timerInterval:)` clamps a fixed window to
// 0:00 after expiry, so over-resting is safe. The window is only trusted when both ends are non-nil
// AND `restStartedAt <= restEndsAt`; otherwise a static "Rest" label stands in.
//
// LOAD RULE: the set's weight, range and last time's numbers (`ContentState.load`) are DISPLAY ONLY.
// The Live Activity never edits a weight — its only controls move the run (Done set / Next) or the rest
// (−15 s / Skip rest / +15 s); the runner's weight panel is the one place a weight is picked. Compact
// and minimal stay as they were: the load lives on the Lock Screen and in the expanded Island only.
//
// ZONE RULE: a cardio segment's heart-rate cue (`ContentState.zone`) is one calm line — the live reading
// against its target with a word for where it sits ("118 bpm · aim 110–125 · in range"), or, with no live
// reading, the short talk test. Words, never colour alone; nothing pulses. Lock Screen and expanded
// Island only, in the line the load uses for a lift (a segment has no load).

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The guided-workout Live Activity widget: the Lock Screen card plus every Dynamic Island
/// presentation (expanded, compact, minimal).
///
/// Registered in ``FernletWidgetsBundle`` alongside ``CookingLiveActivity``. Renders the
/// ``WorkoutActivityAttributes`` content the app publishes; its interactive controls are the "Done
/// set" / "Skip rest" buttons (``GuidedWorkoutMarkSetDoneIntent`` / ``GuidedWorkoutSkipRestIntent``)
/// and, beside "Skip rest", "−15 s" / "+15 s" (``GuidedWorkoutShortenRestIntent`` /
/// ``GuidedWorkoutAddRestIntent``), which the system executes in the app's process. The set's weight
/// and last time's numbers are shown, never edited. Stale snapshots (jetsam / force-quit orphans)
/// degrade to a dimmed "Paused" register instead of a frozen timer or set count.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            // Lock Screen / banner: paper in an ink frame, light or dark with the Lock Screen.
            LiveActivityCard {
                WorkoutLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
            }
        } dynamicIsland: { context in
            let state = context.state
            // Orphaned (jetsammed / force-quit) activities go stale; render a gentle "paused" register
            // instead of a frozen live timer or a stale "Set X of Y".
            let isStale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WorkoutIslandLeading(title: context.attributes.workoutTitle, state: state, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutIslandTrailing(state: state, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The exercise or "Rest" heads the bottom region, flush left under the header as
                    // the design draws it, rather than centred under the camera.
                    VStack(alignment: .leading, spacing: 8) {
                        WorkoutIslandCenter(state: state, isStale: isStale)
                        WorkoutIslandBottom(state: state, isStale: isStale)
                    }
                }
            } compactLeading: {
                // Compact slots carry no text, so the icon's label is the only word saying WHICH
                // activity is running.
                LiveActivitySpriteView(sprite: LiveActivitySprites.dumbbell, scale: 2, tint: LiveActivityIslandLook.leaf,
                                       label: Text("Workout"))
                    .opacity(isStale ? 0.5 : 1)
            } compactTrailing: {
                WorkoutIslandCompactTrailing(state: state, isStale: isStale)
            } minimal: {
                WorkoutIslandMinimal(state: state, isStale: isStale)
            }
            .keylineTint(LiveActivityIslandLook.leaf)
        }
    }
}

// MARK: - Dynamic Island regions
//
// One private view per Island slot (R4: `body` stays a wiring diagram). Each is a pure function of
// `state`/`isStale`.

/// Expanded-Island leading slot: the workout title with its pixel icon (the dumbbell, or the runner on
/// a cardio part), dimmed when stale.
private struct WorkoutIslandLeading: View {
    let title: String
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 6) {
            LiveActivitySpriteView(sprite: workoutIcon(state), scale: 2, tint: LiveActivityIslandLook.leaf)
                .opacity(isStale ? 0.5 : 1)
            Text(verbatim: title)
                .font(.footnote)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
        }
    }
}

/// Expanded-Island trailing slot: "Warm-up X of Y" on a warm-up set, else "Set X of Y", omitted while
/// stale or for a single-step entry.
private struct WorkoutIslandTrailing: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        // No live "Set X of Y" once the snapshot is stale — it would read as if still going.
        if !isStale, let warmUp = state.warmUp {
            warmUpLabel(warmUp)
                .font(.footnote)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
        } else if !isStale && !isSimpleStep(state) && state.totalSets > 1 {
            Text("Set \(state.setNumber) of \(state.totalSets)")
                .font(.footnote)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
        }
    }
}

/// Expanded-Island title: "Rest" in leaf green / the exercise name, or a dimmed "Paused" when stale.
private struct WorkoutIslandCenter: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("Paused")
                .font(.headline)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
        } else {
            // Two Texts, not one over a ternary: a `String` ternary draws "Rest" verbatim, unlocalized.
            Group {
                if state.phase == .resting { Text("Rest") } else { Text(verbatim: state.exerciseName) }
            }
            .font(.headline)
            .foregroundStyle(state.phase == .resting ? LiveActivityIslandLook.leaf : LiveActivityIslandLook.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

/// Expanded-Island bottom slot: the countdown / set line, the set's weight and last time, and the
/// interactive controls — or the gentle "open Fernlet" line for a stale activity.
private struct WorkoutIslandBottom: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("Open Fernlet to pick it back up")
                .font(.footnote)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            liveContent
        }
    }

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.phase == .resting {
                restHeader
                nextUpLine(state)
                    .font(.footnote)
                    .foregroundStyle(LiveActivityIslandLook.soft)
                    .lineLimit(1)
            } else {
                setRepsLine(state)
                    .font(.subheadline)
                    .foregroundStyle(LiveActivityIslandLook.soft)
                if let load = state.load {
                    workingLoadRow(load)
                }
                if let zone = state.zone {
                    WorkoutZoneLine(zone: zone, color: LiveActivityIslandLook.soft)
                }
            }
            guidedActionButton(state, onIsland: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The rest countdown in Fraunces, beside the set's weight and last time when the lift has them.
    /// The countdown takes its width first, so the numbers beside it shrink before it ever truncates.
    @ViewBuilder private var restHeader: some View {
        let countdown = RestCountdownText(state: state, font: LiveActivityFont.islandCountdown,
                                          color: LiveActivityIslandLook.text)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        if let load = state.load {
            HStack(alignment: .center, spacing: 12) {
                countdown
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                WorkoutLoadStack(load: load, showsLastTime: true, weightColor: LiveActivityIslandLook.text,
                                 detailColor: LiveActivityIslandLook.soft)
            }
        } else {
            countdown
        }
    }

    /// Working a lift: its weight and range at the leading edge, last time's numbers at the trailing.
    private func workingLoadRow(_ load: WorkoutActivityAttributes.ContentState.Load) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            if WorkoutActivityLoadText.drawsWeight(load) {
                WorkoutLoadStack(load: load, alignment: .leading, weightColor: LiveActivityIslandLook.text,
                                 detailColor: LiveActivityIslandLook.soft)
            }
            Spacer(minLength: 8)
            WorkoutLastTimeLine(load: load, color: LiveActivityIslandLook.soft)
        }
    }
}

/// Compact-Island trailing slot: pixel pause bars when stale, else the countdown, set count, or the
/// pixel runner.
private struct WorkoutIslandCompactTrailing: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            // Degrade to still pause bars — never a frozen timer or set count.
            LiveActivitySpriteView(sprite: LiveActivitySprites.pause, scale: 2, tint: LiveActivityIslandLook.text,
                                   label: Text("Paused"))
        } else if state.phase == .resting {
            // No label here on purpose: a label REPLACES a timer Text's content, which would trade
            // the live countdown for a fixed phrase. The countdown speaks itself; the compact
            // leading slot supplies the noun.
            RestCountdownText(state: state, font: compactIslandFont, color: LiveActivityIslandLook.text)
                .frame(maxWidth: 44)
        } else if holdWindow(state) != nil {
            HoldCountdownText(state: state, font: compactIslandFont, color: LiveActivityIslandLook.text)
                .frame(maxWidth: 44)
        } else if let warmUp = state.warmUp {
            Text("\(warmUp.index)/\(warmUp.count)")
                .font(compactIslandFont)
                .foregroundStyle(LiveActivityIslandLook.text)
                // "1/3" on a warm-up set is spoken as the expanded slot's words: "Warm-up 1 of 3".
                .accessibilityLabel(warmUpLabel(warmUp))
        } else if !isSimpleStep(state) {
            Text("\(state.setNumber)/\(state.totalSets)")
                .font(compactIslandFont)
                .foregroundStyle(LiveActivityIslandLook.text)
                // "3/5" is read as "three slash five"; the expanded slot's own wording, spoken.
                .accessibilityLabel(Text("Set \(state.setNumber) of \(state.totalSets)"))
        } else {
            LiveActivitySpriteView(sprite: LiveActivitySprites.runner, scale: 2, tint: LiveActivityIslandLook.leaf,
                                   label: Text("In progress"))
        }
    }
}

/// Minimal-Island slot: pause bars when stale, the width-clamped countdown while resting or holding,
/// else the pixel dumbbell.
private struct WorkoutIslandMinimal: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            LiveActivitySpriteView(sprite: LiveActivitySprites.pause, scale: 2, tint: LiveActivityIslandLook.leaf,
                                   label: Text("Paused"))
                .opacity(0.5)
        } else if state.phase == .resting {
            // The minimal slot is a tiny circle: clamp the timer's width and scale digits down,
            // or the Text reserves room for its widest possible value ("88:88") and overflows.
            RestCountdownText(state: state, font: compactIslandFont,
                              color: LiveActivityIslandLook.text, maxWidth: 34)
        } else if holdWindow(state) != nil {
            HoldCountdownText(state: state, font: compactIslandFont,
                              color: LiveActivityIslandLook.text, maxWidth: 34)
        } else {
            LiveActivitySpriteView(sprite: LiveActivitySprites.dumbbell, scale: 2, tint: LiveActivityIslandLook.leaf,
                                   label: Text("Workout"))
        }
    }
}

/// The compact and minimal slots' numbers: monospaced and semibold, as the design draws "3/5".
private let compactIslandFont = Font.system(.footnote, design: .monospaced).weight(.semibold)

/// The workout's pixel icon: the runner on a cardio part, the dumbbell otherwise.
private func workoutIcon(_ state: WorkoutActivityAttributes.ContentState) -> LiveActivitySprite {
    state.paceRaw == nil ? LiveActivitySprites.dumbbell : LiveActivitySprites.runner
}

// MARK: - Shared helpers

/// A single-step entry (a cardio/mobility line the app clamps to one "set" with empty reps): show
/// the movement without an awkward "Set 1 of 1".
private func isSimpleStep(_ state: WorkoutActivityAttributes.ContentState) -> Bool {
    state.reps.isEmpty && state.totalSets <= 1
}

/// The working-state line: "Set 2 of 4 · 12 reps", or the gentle line for a single-step move.
///
/// Returns `Text`, not `String`: these were English literals assembled with `joined(separator:)`,
/// which no string catalog can see and no translator can reorder. Each shape is now one whole
/// harvested sentence — a language that puts the rep count first, or separates clauses differently,
/// can say so, which a runtime join of pre-built fragments can never allow.
private func setRepsLine(_ state: WorkoutActivityAttributes.ContentState) -> Text {
    if holdWindow(state) != nil { return holdLine(state) }
    if let warmUp = state.warmUp, !state.reps.isEmpty {
        return Text("Warm-up \(warmUp.index) of \(warmUp.count) · \(state.reps) reps",
                    comment: "Live Activity: the working line on a lighter warm-up set before a lift's working sets, e.g. 'Warm-up 1 of 3 · 8 reps'.")
    }
    guard !isSimpleStep(state) else { return Text("Take it at your own pace") }
    guard !state.reps.isEmpty else { return Text("Set \(state.setNumber) of \(state.totalSets)") }
    return Text("Set \(state.setNumber) of \(state.totalSets) · \(state.reps) reps")
}

/// "Warm-up 1 of 3" — a warm-up set's place among its lift's warm-up sets: the expanded Island's
/// trailing words, and what VoiceOver says for the compact "1/3".
private func warmUpLabel(_ warmUp: (index: Int, count: Int)) -> Text {
    Text("Warm-up \(warmUp.index) of \(warmUp.count)",
         comment: "Live Activity: which lighter warm-up set this is before a lift's working sets, e.g. 'Warm-up 1 of 3'. Also what VoiceOver reads for the compact '1/3'.")
}

/// The ordered hold window of a timed step being worked (a stretch, a plank), or nil. Same rule as
/// the rest window: only a present, ordered pair is ever handed to `Text(timerInterval:)`.
private func holdWindow(_ state: WorkoutActivityAttributes.ContentState) -> ClosedRange<Date>? {
    guard state.phase == .working, let start = state.holdStartsAt, let end = state.holdEndsAt, start <= end else {
        return nil
    }
    return start...end
}

/// The working line for a timed step: the side and the hold ("Left side · hold 20 s"), or the set
/// and the hold for a timed set ("Set 1 of 2 · hold 30 s"), or a cardio segment's pace and round.
/// Whole sentences, as ``setRepsLine(_:)``.
private func holdLine(_ state: WorkoutActivityAttributes.ContentState) -> Text {
    if let pace = state.paceRaw { return segmentLine(pace: pace, round: state.round, rounds: state.rounds) }
    if state.totalSets > 1 {
        return Text("Set \(state.setNumber) of \(state.totalSets) · hold \(state.reps)")
    }
    switch state.sideRaw {
    case "left": return Text("Left side · hold \(state.reps)")
    case "right": return Text("Right side · hold \(state.reps)")
    default: return Text("Hold \(state.reps)")
    }
}

/// A cardio segment's line: its pace in words — never by colour alone — and, for an interval, its
/// round ("Hard · round 3 of 8"). The pace tokens are `GuidedWorkoutRunState.PaceToken`'s.
private func segmentLine(pace: String, round: Int?, rounds: Int?) -> Text {
    if let round, let rounds {
        switch pace {
        case GuidedWorkoutRunState.PaceToken.hard: return Text("Hard · round \(round) of \(rounds)")
        case GuidedWorkoutRunState.PaceToken.easy: return Text("Easy · round \(round) of \(rounds)")
        default: return Text("Round \(round) of \(rounds)")
        }
    }
    switch pace {
    case GuidedWorkoutRunState.PaceToken.hard: return Text("Hard pace")
    case GuidedWorkoutRunState.PaceToken.easy: return Text("Easy pace")
    default: return Text("Steady pace")
    }
}

/// The resting line: what the rest is leading into. Same fork, same reason, as ``setRepsLine(_:)``.
private func nextUpLine(_ state: WorkoutActivityAttributes.ContentState) -> Text {
    guard !isSimpleStep(state) else { return Text("Next up · \(state.exerciseName)") }
    return Text("Next up · \(state.exerciseName) · Set \(state.setNumber) of \(state.totalSets)")
}

/// Crash-safe rest countdown. See the CRASH RULE at the top of this file.
///
/// Reused across the Lock Screen card and every Dynamic Island slot; it renders
/// `Text(timerInterval:)` only while `.resting` with a present, ordered window, and otherwise falls
/// back to a static "Rest" label — never a live `Date()` range.
private struct RestCountdownText: View {
    let state: WorkoutActivityAttributes.ContentState
    var font: Font
    var color: Color
    /// Minimal Dynamic Island slot only: clamp the timer to a tiny width and scale digits to fit. A
    /// timer `Text` reserves width for its widest possible value, so without this it overflows the
    /// minimal circle. Left `nil` everywhere the slot has room.
    var maxWidth: CGFloat? = nil

    var body: some View {
        if let maxWidth {
            content
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: maxWidth)
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if state.phase == .resting,
           let start = state.restStartedAt,
           let end = state.restEndsAt,
           start <= end {
            Text(timerInterval: start...end, countsDown: true)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(color)
                // The rest timer redraws every second but its accessibility value is only re-read
                // when the element is marked as changing on its own; without this VoiceOver reports
                // whatever the clock said when focus landed, for the whole rest.
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            // Never a live `Date()` range — a static label is the fail-safe fallback.
            Text("Rest")
                .font(font)
                .foregroundStyle(color)
        }
    }
}

/// Crash-safe hold countdown for a timed step, under the same rule as ``RestCountdownText``: a
/// `Text(timerInterval:)` only over a present, ordered window, else a static "Hold" label. Before the
/// hold starts (the lead-in) the timer shows the full hold, then counts it down.
private struct HoldCountdownText: View {
    let state: WorkoutActivityAttributes.ContentState
    var font: Font
    var color: Color
    var maxWidth: CGFloat? = nil

    var body: some View {
        if let maxWidth {
            content
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: maxWidth)
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let window = holdWindow(state) {
            Text(timerInterval: window, countsDown: true)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(color)
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            Text("Hold")
                .font(font)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Lock Screen card

/// The Lock Screen / banner presentation of the workout activity, inside ``LiveActivityCard``: the
/// header (pixel icon, workout title, and "Exercise 3 of 6" with its progress squares), the exercise
/// or "Rest" in Fraunces with its lines, the countdown or the set's weight on the right, and the
/// phase's framed controls.
///
/// Splits on `isStale` — the live card with the interactive control, or the dimmed "Paused / Open
/// Fernlet" resting-place for an activity that outlived its process. Used only from
/// ``WorkoutLiveActivity``'s `ActivityConfiguration` closure.
///
/// Larger Text: the countdown is a capped face that takes its width first and never truncates; the
/// text beside it shrinks or wraps instead, and at accessibility sizes the workout title gives way
/// (the Island still names it) so the card keeps room for the countdown and the buttons.
private struct WorkoutLockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    /// The activity outlived its process (jetsam / force-quit) and its snapshot is stale — render a
    /// dimmed, gentle "paused" card rather than a frozen live timer.
    var isStale: Bool = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.liveActivityLook) private var look

    var body: some View {
        if isStale {
            LiveActivityPausedCard(icon: workoutIcon(state), title: attributes.workoutTitle)
        } else {
            liveCard
        }
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                header
            }
            HStack(alignment: .center, spacing: 10) {
                leadingColumn
                Spacer(minLength: 8)
                trailingColumn
                    // The countdown is the card's point: it takes its width first and never truncates,
                    // however large the text beside it grows.
                    .layoutPriority(1)
            }
            guidedActionButton(state, onIsland: false)
        }
    }

    /// Whether the header row has anything to draw: the title (hidden at accessibility sizes), or the
    /// progress squares.
    private var showsHeader: Bool { !typeSize.isAccessibilitySize || showsProgress }

    /// "Exercise 3 of 6" and its squares sit in the header while a set or a cardio part is worked —
    /// not while resting or during a timed hold, whose countdown is the card's point.
    private var showsProgress: Bool {
        state.phase == .working && (holdWindow(state) == nil || state.paceRaw != nil)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if !typeSize.isAccessibilitySize {
                LiveActivityHeaderLabel(icon: workoutIcon(state), title: attributes.workoutTitle)
            }
            Spacer(minLength: 4)
            if showsProgress {
                LiveActivityProgressSquares(index: state.exerciseIndex, total: state.totalExercises)
            }
        }
    }

    /// The exercise or "Rest", the set or next-up line, and last time's numbers or the heart rate.
    private var leadingColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.phase == .resting {
                Text("Rest")
                    .font(LiveActivityFont.title)
                    .foregroundStyle(look.moss)
                nextUpLine(state)
                    .font(LiveActivityFont.line)
                    .foregroundStyle(look.ink)
                    .lineLimit(state.load == nil ? 2 : 1)
                    .minimumScaleFactor(0.8)
                if let load = state.load {
                    WorkoutRestLoadLine(load: load)
                }
            } else {
                Text(verbatim: state.exerciseName)
                    .font(LiveActivityFont.title)
                    .foregroundStyle(look.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                setRepsLine(state)
                    .font(LiveActivityFont.line)
                    .foregroundStyle(look.soft)
                    .lineLimit(1)
                if let load = state.load {
                    WorkoutLastTimeLine(load: load, color: look.soft)
                }
                if let zone = state.zone {
                    WorkoutZoneLine(zone: zone, color: look.soft)
                }
            }
        }
    }

    /// The rest or hold countdown in Fraunces, or the set's weight over its range.
    @ViewBuilder private var trailingColumn: some View {
        if state.phase == .resting {
            RestCountdownText(state: state, font: LiveActivityFont.countdown, color: look.ink)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .fixedSize(horizontal: true, vertical: false)
        } else if holdWindow(state) != nil {
            HoldCountdownText(state: state, font: LiveActivityFont.countdown, color: look.ink)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .fixedSize(horizontal: true, vertical: false)
        } else if let load = state.load, WorkoutActivityLoadText.drawsWeight(load) {
            WorkoutLoadStack(load: load, weightColor: look.ink, detailColor: look.soft)
        }
    }
}

/// The interactive controls shared by the Lock Screen card and the Dynamic Island: "Done set" (or
/// "Next" / "Finish workout") while working, "−15 s" · "Skip rest" · "+15 s" while resting. Each is a
/// `LiveActivityIntent` the system runs in the app's process, advancing the shared app-group run state
/// (see GuidedWorkoutLiveActivityIntents). Only ever rendered in a live (non-stale) state, so the run
/// always exists when a tap lands. The faces are the World's framed buttons (``LiveActivityButtonFace``
/// on the card with a pixel check, ``LiveActivityIslandButtonFace`` on the island's black).
@ViewBuilder
private func guidedActionButton(_ state: WorkoutActivityAttributes.ContentState, onIsland: Bool) -> some View {
    if state.phase == .resting {
        WorkoutRestControls(onIsland: onIsland)
    } else {
        Button(intent: GuidedWorkoutMarkSetDoneIntent()) {
            WorkoutButtonFace(title: doneButtonTitle(state), icon: LiveActivitySprites.check, onIsland: onIsland)
        }
        .buttonStyle(.plain)
    }
}

/// "Finish workout" on the last set of the last exercise (it finishes and logs the workout); "Next" for
/// a one-set timed step (a stretch: "Done set" would name a set it is not); else "Done set".
private func doneButtonTitle(_ state: WorkoutActivityAttributes.ContentState) -> Text {
    let finishing = state.setNumber >= state.totalSets && state.exerciseIndex >= state.totalExercises - 1
    guard !finishing else { return Text("Finish workout") }
    let singleHold = holdWindow(state) != nil && state.totalSets <= 1
    return singleHold ? Text("Next") : Text("Done set")
}

/// One framed button face, the card's or the island's.
private struct WorkoutButtonFace: View {
    let title: Text
    var icon: LiveActivitySprite? = nil
    var role: LiveActivityButtonRole = .primary
    var fillsWidth = true
    let onIsland: Bool

    var body: some View {
        if onIsland {
            LiveActivityIslandButtonFace(title: title, role: role, fillsWidth: fillsWidth)
        } else {
            LiveActivityButtonFace(title: title, icon: icon, role: role, fillsWidth: fillsWidth)
        }
    }
}

/// "−15 s" · "Skip rest" · "+15 s" — the rest's three controls, in one row so the card grows no taller.
///
/// The two adjusters move only the rest's end (``GuidedWorkoutShortenRestIntent`` /
/// ``GuidedWorkoutAddRestIntent``: never under five seconds left, never past ten minutes). Their drawn
/// words are terse; VoiceOver hears the whole action ("Add 15 seconds of rest") and Voice Control
/// answers to the drawn text spoken ("Plus 15 seconds") as well as plain words.
private struct WorkoutRestControls: View {
    let onIsland: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: GuidedWorkoutShortenRestIntent()) {
                WorkoutButtonFace(title: Text("−15 s"), role: .secondary, fillsWidth: false, onIsland: onIsland)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Take 15 seconds off the rest"))
            .accessibilityInputLabels([Text("Minus 15 seconds"), Text("Minus 15"), Text("Shorter rest")])

            Button(intent: GuidedWorkoutSkipRestIntent()) {
                WorkoutButtonFace(title: Text("Skip rest"), icon: LiveActivitySprites.forward, onIsland: onIsland)
            }
            .buttonStyle(.plain)

            Button(intent: GuidedWorkoutAddRestIntent()) {
                WorkoutButtonFace(title: Text("+15 s"), role: .secondary, fillsWidth: false, onIsland: onIsland)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Add 15 seconds of rest"))
            .accessibilityInputLabels([Text("Plus 15 seconds"), Text("Plus 15"), Text("Longer rest")])
        }
    }
}

// MARK: - Load (display only)

/// The set's weight over its range ("105 lb" / "95–110 lb"), optionally with last time's numbers
/// under them — beside the set on the card, beside the countdown in the island.
///
/// DISPLAY ONLY (see the LOAD RULE at the top of this file). One VoiceOver element that speaks the
/// whole load in words ("Suggested weight 105 pounds, range 95 to 110 pounds, last time 3 by 8 at 100
/// pounds"), so "×" and "@" are never read out, and last time is heard here even where its own line
/// is drawn elsewhere on the card.
private struct WorkoutLoadStack: View {
    let load: WorkoutActivityAttributes.ContentState.Load
    var alignment: HorizontalAlignment = .trailing
    /// Draw last time's numbers under the range — the expanded Island, which has no other line for them.
    var showsLastTime = false
    var weightColor: Color = .primary
    var detailColor: Color = .secondary

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            if let weight = WorkoutActivityLoadText.weightText(load) {
                Text(verbatim: weight)
                    .font(LiveActivityFont.weight)
                    .foregroundStyle(weightColor)
            }
            if let range = WorkoutActivityLoadText.rangeText(load) {
                Text(verbatim: range)
                    .font(LiveActivityFont.range)
                    .foregroundStyle(detailColor)
            }
            if showsLastTime, let last = WorkoutActivityLoadText.lastTimeLine(load) {
                Text(verbatim: last)
                    .font(LiveActivityFont.range)
                    .foregroundStyle(detailColor)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WorkoutActivityLoadText.spokenSummary(load) ?? ""))
    }
}

/// The rest card's weight line under "Next up" ("**25 lb** · 25–30 lb"), the weight in bold — or, for
/// a lift with no weight to draw, last time's numbers. One VoiceOver element speaking the whole load,
/// last time included, so nothing the card used to say is lost to VoiceOver.
private struct WorkoutRestLoadLine: View {
    let load: WorkoutActivityAttributes.ContentState.Load
    @Environment(\.liveActivityLook) private var look

    var body: some View {
        if WorkoutActivityLoadText.drawsWeight(load) {
            HStack(spacing: 4) {
                if let weight = WorkoutActivityLoadText.weightText(load) {
                    Text(verbatim: weight).fontWeight(.bold)
                }
                if WorkoutActivityLoadText.weightText(load) != nil, WorkoutActivityLoadText.rangeText(load) != nil {
                    Text(verbatim: "·")
                }
                if let range = WorkoutActivityLoadText.rangeText(load) {
                    Text(verbatim: range)
                }
            }
            .font(LiveActivityFont.detail)
            .foregroundStyle(look.soft)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WorkoutActivityLoadText.spokenSummary(load) ?? ""))
        } else {
            WorkoutLastTimeLine(load: load, color: look.soft)
        }
    }
}

/// "Last time: 3 × 8 @ 100 lb" on a line of its own. Silent to VoiceOver when a ``WorkoutLoadStack``
/// is drawn on the same card (that element already says it); otherwise it speaks the load in words.
private struct WorkoutLastTimeLine: View {
    let load: WorkoutActivityAttributes.ContentState.Load
    var color: Color = .secondary

    var body: some View {
        if let line = WorkoutActivityLoadText.lastTimeLine(load) {
            Text(verbatim: line)
                .font(LiveActivityFont.detail)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel(Text(verbatim: WorkoutActivityLoadText.spokenSummary(load) ?? line))
                .accessibilityHidden(WorkoutActivityLoadText.drawsWeight(load))
        }
    }
}

/// A cardio segment's heart-rate cue on one line (see the ZONE RULE at the top of this file): a pixel
/// heart and the live reading, its target and where it sits, or the short talk test without one.
/// VoiceOver hears the reading in full words ("Heart rate 118, aiming for 110 to 125, in range"); the
/// talk test speaks as drawn. Static — nothing animates, so Reduce Motion has nothing to stop.
private struct WorkoutZoneLine: View {
    let zone: WorkoutActivityAttributes.ContentState.Zone
    var color: Color = .secondary

    var body: some View {
        if let line = WorkoutActivityZoneText.line(zone) {
            HStack(spacing: 5) {
                if zone.isLive {
                    LiveActivitySpriteView(sprite: LiveActivitySprites.heart, scale: 2)
                }
                Text(verbatim: line)
                    .font(LiveActivityFont.detail)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WorkoutActivityZoneText.spoken(zone) ?? line))
        }
    }
}

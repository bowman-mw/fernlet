// WorkoutLiveActivity.swift
// FernletWidgets (widget target only — renders the activity the app requests).
//
// The Lock Screen card + Dynamic Island for the guided-workout rest timer. Registered in
// FernletWidgetsBundle. Gentle, zero-pressure copy ("Rest", "Next up", "Nicely done"), mirroring
// Fernlet/GuidedWorkout.swift.
//
// CRASH RULE (a prior in-app review caught this exact bug): the rest countdown is ALWAYS rendered
// from the FIXED `restStartedAt...restEndsAt` window — never `Date()...restEndsAt`, whose lower bound
// inverts and fatalErrors once the deadline passes. `Text(timerInterval:)` clamps a fixed window to
// 0:00 after expiry, so over-resting is safe. The window is only trusted when both ends are non-nil
// AND `restStartedAt <= restEndsAt`; otherwise a static "Rest" label stands in.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The guided-workout Live Activity widget: the Lock Screen card plus every Dynamic Island
/// presentation (expanded, compact, minimal).
///
/// Registered in ``FernletWidgetsBundle`` alongside ``CookingLiveActivity``. Renders the
/// ``WorkoutActivityAttributes`` content the app publishes; its interactive controls are the "Done
/// set" / "Skip rest" buttons (``GuidedWorkoutMarkSetDoneIntent`` / ``GuidedWorkoutSkipRestIntent``),
/// which the system executes in the app's process. Stale snapshots (jetsam / force-quit orphans)
/// degrade to a dimmed "Paused" register instead of a frozen timer or set count.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            // Lock Screen / banner: cream card + ink text, matching the app's identity.
            WorkoutLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(FernletWidgetPalette.card)
                .activitySystemActionForegroundColor(FernletWidgetPalette.buttonFill)
        } dynamicIsland: { context in
            let state = context.state
            // Orphaned (jetsammed / force-quit) activities go stale; render a gentle "paused" register
            // instead of a frozen live timer or a stale "Set X of Y".
            let isStale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WorkoutIslandLeading(title: context.attributes.workoutTitle, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutIslandTrailing(state: state, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    WorkoutIslandCenter(state: state, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutIslandBottom(state: state, isStale: isStale)
                }
            } compactLeading: {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(isStale ? FernletWidgetPalette.leaf.opacity(0.5) : FernletWidgetPalette.leaf)
                    // Compact slots carry no text, so an unlabelled glyph announces its SF Symbol
                    // name ("leaf fill") — this is the only word saying WHICH activity is running.
                    .accessibilityLabel(Text("Workout"))
            } compactTrailing: {
                WorkoutIslandCompactTrailing(state: state, isStale: isStale)
            } minimal: {
                WorkoutIslandMinimal(state: state, isStale: isStale)
            }
            .keylineTint(FernletWidgetPalette.leaf)
        }
    }
}

// MARK: - Dynamic Island regions
//
// One private view per Island slot (R4: `body` stays a wiring diagram). Each is a pure function of
// `state`/`isStale` and carries the exact modifiers it had while inlined.

/// Expanded-Island leading slot: the workout title with the leaf glyph, dimmed when stale.
private struct WorkoutIslandLeading: View {
    let title: String
    let isStale: Bool

    var body: some View {
        Label {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } icon: {
            Image(systemName: "leaf.fill")
                .foregroundStyle(isStale ? FernletWidgetPalette.leaf.opacity(0.5) : FernletWidgetPalette.leaf)
        }
    }
}

/// Expanded-Island trailing slot: "Set X of Y", omitted while stale or for a single-step entry.
private struct WorkoutIslandTrailing: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        // No live "Set X of Y" once the snapshot is stale — it would read as if still going.
        if !isStale && !isSimpleStep(state) {
            Text("Set \(state.setNumber) of \(state.totalSets)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Expanded-Island centre slot: "Rest" / the exercise name, or a dimmed "Paused" when stale.
private struct WorkoutIslandCenter: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("Paused")
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(state.phase == .resting ? "Rest" : state.exerciseName)
                .font(.headline)
                .foregroundStyle(state.phase == .resting ? FernletWidgetPalette.leaf : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Expanded-Island bottom slot: the countdown / set line plus the interactive control, or the
/// gentle "open Fernlet" line for a stale activity.
private struct WorkoutIslandBottom: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("Open Fernlet to pick it back up")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        } else {
            liveContent
        }
    }

    private var liveContent: some View {
        VStack(spacing: 8) {
            if state.phase == .resting {
                RestCountdownText(state: state,
                                  font: .system(size: 38, weight: .semibold, design: .rounded),
                                  color: .primary)
                nextUpLine(state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                setRepsLine(state)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            guidedActionButton(state)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Compact-Island trailing slot: pause glyph when stale, else the countdown, set count, or icon.
private struct WorkoutIslandCompactTrailing: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            // Degrade to a still pause glyph — never a frozen timer or set count.
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Paused"))
        } else if state.phase == .resting {
            // No label here on purpose: a label REPLACES a timer Text's content, which would trade
            // the live countdown for a fixed phrase. The countdown speaks itself; the compact
            // leading slot supplies the noun.
            RestCountdownText(state: state,
                              font: .caption2.monospacedDigit(),
                              color: .primary)
                .frame(maxWidth: 44)
        } else if !isSimpleStep(state) {
            Text("\(state.setNumber)/\(state.totalSets)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.primary)
                // "3/5" is read as "three slash five"; the expanded slot's own wording, spoken.
                .accessibilityLabel(Text("Set \(state.setNumber) of \(state.totalSets)"))
        } else {
            Image(systemName: "figure.strengthtraining.functional")
                .foregroundStyle(FernletWidgetPalette.leaf)
                .accessibilityLabel(Text("In progress"))
        }
    }
}

/// Minimal-Island slot: pause glyph when stale, the width-clamped countdown while resting, else leaf.
private struct WorkoutIslandMinimal: View {
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Image(systemName: "pause.fill")
                .foregroundStyle(FernletWidgetPalette.leaf.opacity(0.5))
                .accessibilityLabel(Text("Paused"))
        } else if state.phase == .resting {
            // The minimal slot is a tiny circle: clamp the timer's width and scale digits down,
            // or the Text reserves room for its widest possible value ("88:88") and overflows.
            RestCountdownText(state: state,
                              font: .caption2.monospacedDigit(),
                              color: FernletWidgetPalette.leaf,
                              maxWidth: 34)
        } else {
            Image(systemName: "leaf.fill")
                .foregroundStyle(FernletWidgetPalette.leaf)
                .accessibilityLabel(Text("Workout"))
        }
    }
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
    guard !isSimpleStep(state) else { return Text("Take it at your own pace") }
    guard !state.reps.isEmpty else { return Text("Set \(state.setNumber) of \(state.totalSets)") }
    return Text("Set \(state.setNumber) of \(state.totalSets) · \(state.reps) reps")
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

// MARK: - Lock Screen card

/// The Lock Screen / banner presentation of the workout activity: title, exercise or "Rest" line,
/// the countdown or progress dots, and the phase-appropriate action button.
///
/// Splits on `isStale` — a live cream card with the interactive control, or a dimmed "Paused / Open
/// Fernlet" resting-place for an activity that outlived its process. Used only from
/// ``WorkoutLiveActivity``'s `ActivityConfiguration` closure.
private struct WorkoutLockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    /// The activity outlived its process (jetsam / force-quit) and its snapshot is stale — render a
    /// dimmed, gentle "paused" card rather than a frozen live timer.
    var isStale: Bool = false

    var body: some View {
        if isStale {
            stalePausedCard
        } else {
            liveCard
        }
    }

    /// Dimmed, no-pressure resting-place for an orphaned activity. No timer, no "Set X of Y".
    private var stalePausedCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(attributes.workoutTitle)
                        .font(.caption)
                        .foregroundStyle(FernletWidgetPalette.inkSoft)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "leaf.fill")
                        .font(.caption)
                        .foregroundStyle(FernletWidgetPalette.buttonFill.opacity(0.5))
                }
                Text("Paused")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FernletWidgetPalette.inkSoft)
                Text("Open Fernlet to pick it back up")
                    .font(.subheadline)
                    .foregroundStyle(FernletWidgetPalette.inkSoft)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "pause.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(FernletWidgetPalette.buttonFill.opacity(0.45))
                // "Paused" is already written beside it — otherwise this reads "pause circle" into
                // the middle of the card, which Speak Screen takes as part of the sentence.
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var liveCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Label {
                        Text(attributes.workoutTitle)
                            .font(.caption)
                            .foregroundStyle(FernletWidgetPalette.inkSoft)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "leaf.fill")
                            .font(.caption)
                            .foregroundStyle(FernletWidgetPalette.buttonFill)
                    }

                    if state.phase == .resting {
                        Text("Rest")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(FernletWidgetPalette.buttonFill)
                        nextUpLine(state)
                            .font(.subheadline)
                            .foregroundStyle(FernletWidgetPalette.ink)
                            .lineLimit(2)
                    } else {
                        Text(state.exerciseName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(FernletWidgetPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        setRepsLine(state)
                            .font(.subheadline)
                            .foregroundStyle(FernletWidgetPalette.inkSoft)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if state.phase == .resting {
                    RestCountdownText(state: state,
                                      font: .system(size: 40, weight: .semibold, design: .rounded),
                                      color: FernletWidgetPalette.ink)
                } else {
                    ExerciseProgressDots(index: state.exerciseIndex, total: state.totalExercises)
                }
            }

            guidedActionButton(state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// The interactive "Done set" / "Skip rest" control shared by the Lock Screen card and the Dynamic
/// Island. Each is a `LiveActivityIntent` the system runs in the app's process, advancing the shared
/// app-group run state (see GuidedWorkoutLiveActivityIntents). Only ever rendered in a live (non-stale)
/// state, so the run always exists when a tap lands.
@ViewBuilder
private func guidedActionButton(_ state: WorkoutActivityAttributes.ContentState) -> some View {
    if state.phase == .resting {
        Button(intent: GuidedWorkoutSkipRestIntent()) {
            Label("Skip rest", systemImage: "forward.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(FernletWidgetPalette.leaf)
    } else {
        // Last set of the last exercise finishes (and logs) the workout.
        let finishing = state.setNumber >= state.totalSets && state.exerciseIndex >= state.totalExercises - 1
        Button(intent: GuidedWorkoutMarkSetDoneIntent()) {
            Label(finishing ? "Finish workout" : "Done set", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(FernletWidgetPalette.buttonFill)
    }
}

/// A gentle "where are we in the session" indicator for the working state (no numbers shouting).
///
/// Dots are capped at 8 so a long session can't overflow the card, while the label above reports the
/// true uncapped position ("Exercise 10 of 10"). Only shown on the Lock Screen card's working state.
private struct ExerciseProgressDots: View {
    let index: Int
    let total: Int

    // Dots are capped at 8 so a long session can't overflow the card…
    private var dotTotal: Int { max(1, min(total, 8)) }
    private var dotIndex: Int { max(0, min(index, dotTotal - 1)) }
    // …but the LABEL reports the true position, uncapped — a 10-exercise day reads "Exercise 10 of 10",
    // never a clamped "Exercise 8 of 8".
    private var labelTotal: Int { max(1, total) }
    private var labelIndex: Int { max(0, min(index, labelTotal - 1)) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Exercise \(labelIndex + 1) of \(labelTotal)")
                .font(.caption2)
                .foregroundStyle(FernletWidgetPalette.inkSoft)
                .lineLimit(1)
            HStack(spacing: 4) {
                ForEach(0..<dotTotal, id: \.self) { i in
                    Circle()
                        .fill(i <= dotIndex
                              ? FernletWidgetPalette.buttonFill
                              : FernletWidgetPalette.buttonFill.opacity(0.22))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

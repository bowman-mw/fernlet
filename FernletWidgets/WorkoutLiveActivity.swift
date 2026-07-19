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
import SwiftUI
import WidgetKit

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            // Lock Screen / banner: cream card + ink text, matching the app's identity.
            WorkoutLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(FernletWidgetPalette.card)
                .activitySystemActionForegroundColor(FernletWidgetPalette.buttonFill)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.workoutTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "leaf.fill")
                            .foregroundStyle(FernletWidgetPalette.leaf)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !isSimpleStep(state) {
                        Text("Set \(state.setNumber) of \(state.totalSets)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.phase == .resting ? "Rest" : state.exerciseName)
                        .font(.headline)
                        .foregroundStyle(state.phase == .resting ? FernletWidgetPalette.leaf : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.phase == .resting {
                        VStack(spacing: 2) {
                            RestCountdownText(state: state,
                                              font: .system(size: 40, weight: .semibold, design: .rounded),
                                              color: .primary)
                            Text(nextUpLine(state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(setRepsLine(state))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(FernletWidgetPalette.leaf)
            } compactTrailing: {
                if state.phase == .resting {
                    RestCountdownText(state: state,
                                      font: .caption2.monospacedDigit(),
                                      color: .primary)
                        .frame(maxWidth: 44)
                } else if !isSimpleStep(state) {
                    Text("\(state.setNumber)/\(state.totalSets)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "figure.strengthtraining.functional")
                        .foregroundStyle(FernletWidgetPalette.leaf)
                }
            } minimal: {
                if state.phase == .resting {
                    RestCountdownText(state: state,
                                      font: .caption2.monospacedDigit(),
                                      color: FernletWidgetPalette.leaf)
                } else {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(FernletWidgetPalette.leaf)
                }
            }
            .keylineTint(FernletWidgetPalette.leaf)
        }
    }
}

// MARK: - Shared helpers

/// A single-step entry (a cardio/mobility line the app clamps to one "set" with empty reps): show
/// the movement without an awkward "Set 1 of 1".
private func isSimpleStep(_ state: WorkoutActivityAttributes.ContentState) -> Bool {
    state.reps.isEmpty && state.totalSets <= 1
}

private func setRepsLine(_ state: WorkoutActivityAttributes.ContentState) -> String {
    guard !isSimpleStep(state) else { return "Take it at your own pace" }
    var parts = ["Set \(state.setNumber) of \(state.totalSets)"]
    if !state.reps.isEmpty { parts.append("\(state.reps) reps") }
    return parts.joined(separator: " · ")
}

private func nextUpLine(_ state: WorkoutActivityAttributes.ContentState) -> String {
    guard !isSimpleStep(state) else { return "Next up · \(state.exerciseName)" }
    return "Next up · \(state.exerciseName) · Set \(state.setNumber) of \(state.totalSets)"
}

/// Crash-safe rest countdown. See the CRASH RULE at the top of this file.
private struct RestCountdownText: View {
    let state: WorkoutActivityAttributes.ContentState
    var font: Font
    var color: Color

    var body: some View {
        if state.phase == .resting,
           let start = state.restStartedAt,
           let end = state.restEndsAt,
           start <= end {
            Text(timerInterval: start...end, countsDown: true)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(color)
        } else {
            // Never a live `Date()` range — a static label is the fail-safe fallback.
            Text("Rest")
                .font(font)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Lock Screen card

private struct WorkoutLockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
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
                    Text(nextUpLine(state))
                        .font(.subheadline)
                        .foregroundStyle(FernletWidgetPalette.ink)
                        .lineLimit(2)
                } else {
                    Text(state.exerciseName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(FernletWidgetPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(setRepsLine(state))
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
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// A gentle "where are we in the session" indicator for the working state (no numbers shouting).
private struct ExerciseProgressDots: View {
    let index: Int
    let total: Int

    private var clampedTotal: Int { max(1, min(total, 8)) }
    private var clampedIndex: Int { max(0, min(index, clampedTotal - 1)) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Exercise \(clampedIndex + 1) of \(clampedTotal)")
                .font(.caption2)
                .foregroundStyle(FernletWidgetPalette.inkSoft)
                .lineLimit(1)
            HStack(spacing: 4) {
                ForEach(0..<clampedTotal, id: \.self) { i in
                    Circle()
                        .fill(i <= clampedIndex
                              ? FernletWidgetPalette.buttonFill
                              : FernletWidgetPalette.buttonFill.opacity(0.22))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

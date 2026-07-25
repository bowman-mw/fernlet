// CookingLiveActivity.swift
// FernletWidgets (widget target only — renders the activity the app requests).
//
// The Lock Screen card + Dynamic Island for cooking mode (F5). Registered in FernletWidgetsBundle
// alongside WorkoutLiveActivity. Gentle, hands-on copy ("Step 3 of 8", "Timer's up — tap Next"),
// mirroring Fernlet/CookingMode.swift. The single interactive control is the "Next" button, which
// runs NextCookingStepIntent in the app process (advancing the shared app-group run state).
//
// CRASH RULE (inherited from WorkoutLiveActivity): the per-step countdown is ALWAYS rendered from the
// FIXED `timerStartedAt...timerEndsAt` window — never `Date()...timerEndsAt`, whose lower bound inverts
// and fatalErrors once the deadline passes. `Text(timerInterval:)` clamps a fixed window to 0:00 after
// expiry, so over-running a step is safe. The window is only trusted when both ends are non-nil AND
// `timerStartedAt <= timerEndsAt`; otherwise no timer is shown.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct CookingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookingActivityAttributes.self) { context in
            CookingLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(FernletWidgetPalette.card)
                .activitySystemActionForegroundColor(FernletWidgetPalette.buttonFill)
        } dynamicIsland: { context in
            let state = context.state
            let isStale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.recipeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(isStale ? FernletWidgetPalette.leaf.opacity(0.5) : FernletWidgetPalette.leaf)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !isStale {
                        Text("Step \(state.stepNumber) of \(state.stepCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if isStale {
                        Text("Paused")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(state.stepText)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if isStale {
                        Text("Open Fernlet to pick it back up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 8) {
                            if hasTimer(state) {
                                StepCountdownText(state: state,
                                                  font: .system(size: 34, weight: .semibold, design: .rounded),
                                                  color: .primary)
                            }
                            nextStepButton(state)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } compactLeading: {
                Image(systemName: "flame.fill")
                    .foregroundStyle(isStale ? FernletWidgetPalette.leaf.opacity(0.5) : FernletWidgetPalette.leaf)
            } compactTrailing: {
                if isStale {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                } else if hasTimer(state) {
                    StepCountdownText(state: state,
                                      font: .caption2.monospacedDigit(),
                                      color: .primary,
                                      maxWidth: 44)
                } else {
                    Text("\(state.stepNumber)/\(state.stepCount)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            } minimal: {
                if isStale {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(FernletWidgetPalette.leaf.opacity(0.5))
                } else if hasTimer(state) {
                    StepCountdownText(state: state,
                                      font: .caption2.monospacedDigit(),
                                      color: FernletWidgetPalette.leaf,
                                      maxWidth: 34)
                } else {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(FernletWidgetPalette.leaf)
                }
            }
            .keylineTint(FernletWidgetPalette.leaf)
        }
    }
}

// MARK: - Shared helpers

/// A step timer is shown only when the fixed window is present and ordered (see the CRASH RULE).
private func hasTimer(_ state: CookingActivityAttributes.ContentState) -> Bool {
    guard let start = state.timerStartedAt, let end = state.timerEndsAt else { return false }
    return start <= end
}

/// Crash-safe per-step countdown. See the CRASH RULE at the top of this file.
private struct StepCountdownText: View {
    let state: CookingActivityAttributes.ContentState
    var font: Font
    var color: Color
    /// Minimal / compact Dynamic Island slots only: clamp the timer to a small width and scale digits
    /// to fit. A timer `Text` reserves width for its widest possible value, so without this it overflows.
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
        if let start = state.timerStartedAt, let end = state.timerEndsAt, start <= end {
            Text(timerInterval: start...end, countsDown: true)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(color)
        } else {
            EmptyView()
        }
    }
}

/// The interactive "Next" / "Finish" control shared by the Lock Screen card and the Dynamic Island. A
/// `LiveActivityIntent` the system runs in the app's process, advancing the shared app-group run state
/// (see CookingLiveActivityIntents). Only ever rendered in a live (non-stale) state, so the run always
/// exists when a tap lands.
@ViewBuilder
private func nextStepButton(_ state: CookingActivityAttributes.ContentState) -> some View {
    Button(intent: NextCookingStepIntent()) {
        Label(state.isLastStep ? "Finish" : "Next",
              systemImage: state.isLastStep ? "checkmark" : "chevron.right")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .tint(FernletWidgetPalette.buttonFill)
}

// MARK: - Lock Screen card

private struct CookingLockScreenView: View {
    let attributes: CookingActivityAttributes
    let state: CookingActivityAttributes.ContentState
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

    private var stalePausedCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(attributes.recipeName)
                        .font(.caption)
                        .foregroundStyle(FernletWidgetPalette.inkSoft)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "flame.fill")
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
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var liveCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Label {
                        Text(attributes.recipeName)
                            .font(.caption)
                            .foregroundStyle(FernletWidgetPalette.inkSoft)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "flame.fill")
                            .font(.caption)
                            .foregroundStyle(FernletWidgetPalette.buttonFill)
                    }
                    Text("Step \(state.stepNumber) of \(state.stepCount)")
                        .font(.caption)
                        .foregroundStyle(FernletWidgetPalette.buttonFill)
                    Text(state.stepText)
                        .font(.subheadline)
                        .foregroundStyle(FernletWidgetPalette.ink)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                if hasTimer(state) {
                    StepCountdownText(state: state,
                                      font: .system(size: 36, weight: .semibold, design: .rounded),
                                      color: FernletWidgetPalette.ink)
                }
            }

            nextStepButton(state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

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

/// The cooking-mode Live Activity widget: the Lock Screen card plus every Dynamic Island
/// presentation (expanded, compact, minimal).
///
/// Registered in ``FernletWidgetsBundle`` alongside ``WorkoutLiveActivity``. Renders the
/// ``CookingActivityAttributes`` content the app publishes; its one interactive control is the
/// "Next" button (``NextCookingStepIntent``), which the system executes in the app's process. Stale
/// snapshots (jetsam / force-quit orphans) degrade to a dimmed "Paused" register instead of a frozen
/// timer or step count.
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
                    CookingIslandLeading(recipeName: context.attributes.recipeName, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CookingIslandTrailing(state: state, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    CookingIslandCenter(state: state, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CookingIslandBottom(state: state, isStale: isStale)
                }
            } compactLeading: {
                Image(systemName: "flame.fill")
                    .foregroundStyle(isStale ? FernletWidgetPalette.leaf.opacity(0.5) : FernletWidgetPalette.leaf)
                    // Compact slots carry no text, so an unlabelled glyph announces its SF Symbol
                    // name ("flame fill") — this is the only word saying WHICH activity is running,
                    // and the workout activity's compact leading slot looks identical to VoiceOver.
                    .accessibilityLabel(Text("Cooking"))
            } compactTrailing: {
                CookingIslandCompactTrailing(state: state, isStale: isStale)
            } minimal: {
                CookingIslandMinimal(state: state, isStale: isStale)
            }
            .keylineTint(FernletWidgetPalette.leaf)
        }
    }
}

// MARK: - Dynamic Island regions
//
// One private view per Island slot (R4: `body` stays a wiring diagram), mirroring the same split in
// WorkoutLiveActivity. Each is a pure function of `state`/`isStale` with its modifiers unchanged.

/// Expanded-Island leading slot: the recipe name with the flame glyph, dimmed when stale.
private struct CookingIslandLeading: View {
    let recipeName: String
    let isStale: Bool

    var body: some View {
        Label {
            Text(recipeName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } icon: {
            Image(systemName: "flame.fill")
                .foregroundStyle(isStale ? FernletWidgetPalette.leaf.opacity(0.5) : FernletWidgetPalette.leaf)
        }
    }
}

/// Expanded-Island trailing slot: "Step X of Y", omitted while stale.
private struct CookingIslandTrailing: View {
    let state: CookingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if !isStale {
            Text("Step \(state.stepNumber) of \(state.stepCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Expanded-Island centre slot: the step text, or a dimmed "Paused" when stale.
private struct CookingIslandCenter: View {
    let state: CookingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
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
}

/// Expanded-Island bottom slot: the step countdown plus the "Next" control, or the gentle
/// "open Fernlet" line for a stale activity.
private struct CookingIslandBottom: View {
    let state: CookingActivityAttributes.ContentState
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

/// Compact-Island trailing slot: pause glyph when stale, else the countdown or the step count.
private struct CookingIslandCompactTrailing: View {
    let state: CookingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Paused"))
        } else if hasTimer(state) {
            // No label here on purpose: a label REPLACES a timer Text's content, which would trade
            // the live countdown for a fixed phrase. The countdown speaks itself; the compact
            // leading slot supplies the noun.
            StepCountdownText(state: state,
                              font: .caption2.monospacedDigit(),
                              color: .primary,
                              maxWidth: 44)
        } else {
            Text("\(state.stepNumber)/\(state.stepCount)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.primary)
                // "3/8" is read as "three slash eight"; the expanded slot's own wording, spoken.
                .accessibilityLabel(Text("Step \(state.stepNumber) of \(state.stepCount)"))
        }
    }
}

/// Minimal-Island slot: pause glyph when stale, the width-clamped countdown while timing, else flame.
private struct CookingIslandMinimal: View {
    let state: CookingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Image(systemName: "pause.fill")
                .foregroundStyle(FernletWidgetPalette.leaf.opacity(0.5))
                .accessibilityLabel(Text("Paused"))
        } else if hasTimer(state) {
            StepCountdownText(state: state,
                              font: .caption2.monospacedDigit(),
                              color: FernletWidgetPalette.leaf,
                              maxWidth: 34)
        } else {
            Image(systemName: "flame.fill")
                .foregroundStyle(FernletWidgetPalette.leaf)
                .accessibilityLabel(Text("Cooking"))
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
///
/// Reused across the Lock Screen card and every Dynamic Island slot; it renders
/// `Text(timerInterval:)` only from a present, ordered `timerStartedAt...timerEndsAt` window and
/// disappears entirely otherwise (its callers already gate on `hasTimer`).
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
                // The step timer redraws every second but its accessibility value is only re-read
                // when the element is marked as changing on its own; without this VoiceOver reports
                // whatever the clock said when focus landed, for the whole step.
                .accessibilityAddTraits(.updatesFrequently)
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

/// The Lock Screen / banner presentation of the cooking activity: recipe name, "Step X of Y", the
/// step text, the countdown, and the "Next" button.
///
/// Splits on `isStale` — a live cream card with the interactive control, or a dimmed "Paused / Open
/// Fernlet" resting-place for an activity that outlived its process. Used only from
/// ``CookingLiveActivity``'s `ActivityConfiguration` closure.
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
                // "Paused" is already written beside it — otherwise this reads "pause circle" into
                // the middle of the card, which Speak Screen takes as part of the sentence.
                .accessibilityHidden(true)
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

// CookingLiveActivity.swift
// FernletWidgets (widget target only — renders the activity the app requests).
//
// The Lock Screen card + Dynamic Island for cooking mode (F5). Registered in FernletWidgetsBundle
// alongside WorkoutLiveActivity. Gentle, hands-on copy ("Step 3 of 8"), mirroring
// Fernlet/CookingMode.swift. The single interactive control is the "Next" button, which runs
// NextCookingStepIntent in the app process (advancing the shared app-group run state).
//
// WORLD LOOK (World Review Batch 4, b4-la-cook-* and b4-di-cook*, approved 2026-10-24): the Lock
// Screen card is paper in an ink frame, light or dark with the Lock Screen, with a pixel flame,
// "Step 3 of 8" in moss, the step timer in Fraunces and a framed Next with a pixel chevron (Finish with
// a pixel check). The Dynamic Island stays black, with the pixel flame, Fraunces numbers and a framed
// leaf-green button. Paused looks like the workout's, with the flame. Every value and control is the
// same as before.
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
            LiveActivityCard {
                CookingLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
            }
        } dynamicIsland: { context in
            let state = context.state
            let isStale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // Both header slots stand clear of the island's rounded corners, which clipped the
                    // flame's first column and the count's last digit.
                    CookingIslandLeading(recipeName: context.attributes.recipeName, isStale: isStale)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CookingIslandTrailing(state: state, isStale: isStale)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The step heads the bottom region, flush left under the header as the design
                    // draws it, rather than centred under the camera.
                    VStack(alignment: .leading, spacing: 6) {
                        CookingIslandCenter(state: state, isStale: isStale)
                        CookingIslandBottom(state: state, isStale: isStale)
                    }
                    // A paused island is short, so its last line meets the lower corner's curve.
                    .padding(.leading, isStale ? 10 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                // Compact slots carry no text, so the icon's label is the only word saying WHICH
                // activity is running — and the workout's compact slot sits in the same place.
                LiveActivitySpriteView(sprite: LiveActivitySprites.flame, scale: 2, label: Text("Cooking"))
                    .opacity(isStale ? 0.5 : 1)
            } compactTrailing: {
                CookingIslandCompactTrailing(state: state, isStale: isStale)
            } minimal: {
                CookingIslandMinimal(state: state, isStale: isStale)
            }
            .keylineTint(LiveActivityIslandLook.leaf)
        }
    }
}

// MARK: - Dynamic Island regions
//
// One private view per Island slot (R4: `body` stays a wiring diagram), mirroring the same split in
// WorkoutLiveActivity. Each is a pure function of `state`/`isStale`.

/// Expanded-Island leading slot: the recipe name with the pixel flame, dimmed when stale.
private struct CookingIslandLeading: View {
    let recipeName: String
    let isStale: Bool

    var body: some View {
        HStack(spacing: 6) {
            LiveActivitySpriteView(sprite: LiveActivitySprites.flame, scale: 2)
                .opacity(isStale ? 0.5 : 1)
            Text(verbatim: recipeName)
                .font(.footnote)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
                .font(.footnote)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
        }
    }
}

/// Expanded-Island step: the step's words, or a dimmed "Paused" when stale.
private struct CookingIslandCenter: View {
    let state: CookingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("Paused")
                .font(.headline)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
        } else {
            Text(verbatim: state.stepText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LiveActivityIslandLook.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Expanded-Island bottom slot: the step countdown in Fraunces plus the "Next" control, or the gentle
/// "open Fernlet" line for a stale activity.
private struct CookingIslandBottom: View {
    let state: CookingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            Text("Open Fernlet to pick it back up")
                .font(.footnote)
                .foregroundStyle(LiveActivityIslandLook.soft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            // The countdown sits beside Next rather than over it: the expanded island stops at 160
            // points, and three lines of step, a countdown and a button stacked would not fit.
            HStack(alignment: .center, spacing: 12) {
                if hasTimer(state) {
                    StepCountdownText(state: state, font: LiveActivityFont.islandCountdown,
                                      color: LiveActivityIslandLook.text)
                        .countdownSlot(width: 112, alignment: .leading)
                }
                nextStepButton(state, onIsland: true)
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Compact-Island trailing slot: pixel pause bars when stale, else the countdown or the step count.
private struct CookingIslandCompactTrailing: View {
    let state: CookingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            LiveActivitySpriteView(sprite: LiveActivitySprites.pause, scale: 2, tint: LiveActivityIslandLook.text,
                                   label: Text("Paused"))
        } else if hasTimer(state) {
            // No label here on purpose: a label REPLACES a timer Text's content, which would trade
            // the live countdown for a fixed phrase. The countdown speaks itself; the compact
            // leading slot supplies the noun.
            StepCountdownText(state: state, font: cookingCompactFont, color: LiveActivityIslandLook.text, maxWidth: 44)
        } else {
            Text("\(state.stepNumber)/\(state.stepCount)")
                .font(cookingCompactFont)
                .foregroundStyle(LiveActivityIslandLook.text)
                // "3/8" is read as "three slash eight"; the expanded slot's own wording, spoken.
                .accessibilityLabel(Text("Step \(state.stepNumber) of \(state.stepCount)"))
        }
    }
}

/// Minimal-Island slot: pause bars when stale, the width-clamped countdown while timing, else the flame.
private struct CookingIslandMinimal: View {
    let state: CookingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale {
            LiveActivitySpriteView(sprite: LiveActivitySprites.pause, scale: 2, tint: LiveActivityIslandLook.leaf,
                                   label: Text("Paused"))
                .opacity(0.5)
        } else if hasTimer(state) {
            StepCountdownText(state: state, font: cookingCompactFont, color: LiveActivityIslandLook.text, maxWidth: 34)
        } else {
            LiveActivitySpriteView(sprite: LiveActivitySprites.flame, scale: 2, label: Text("Cooking"))
        }
    }
}

// MARK: - Shared helpers

/// The compact and minimal slots' numbers: monospaced and semibold, as the design draws "3/8".
private let cookingCompactFont = Font.system(.footnote, design: .monospaced).weight(.semibold)

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
/// exists when a tap lands. The card's face carries a pixel chevron (a pixel check on the last step);
/// the island's is the framed leaf-green button.
@ViewBuilder
private func nextStepButton(_ state: CookingActivityAttributes.ContentState, onIsland: Bool) -> some View {
    let title = state.isLastStep ? Text("Finish") : Text("Next")
    Button(intent: NextCookingStepIntent()) {
        if onIsland {
            LiveActivityIslandButtonFace(title: title)
        } else {
            LiveActivityButtonFace(title: title,
                                   icon: state.isLastStep ? LiveActivitySprites.check : LiveActivitySprites.chevronRight)
        }
    }
    .buttonStyle(.plain)
}

// MARK: - Lock Screen card

/// The Lock Screen / banner presentation of the cooking activity, inside ``LiveActivityCard``: the
/// pixel flame and the recipe's name, "Step X of Y" in moss, the step's words, the step timer in
/// Fraunces while it runs, and the framed "Next" (or "Finish") button.
///
/// Splits on `isStale` — the live card with the interactive control, or the dimmed "Paused / Open
/// Fernlet" resting-place for an activity that outlived its process. Used only from
/// ``CookingLiveActivity``'s `ActivityConfiguration` closure.
private struct CookingLockScreenView: View {
    let attributes: CookingActivityAttributes
    let state: CookingActivityAttributes.ContentState
    /// The activity outlived its process (jetsam / force-quit) and its snapshot is stale — render a
    /// dimmed, gentle "paused" card rather than a frozen live timer.
    var isStale: Bool = false
    @Environment(\.liveActivityLook) private var look

    var body: some View {
        if isStale {
            LiveActivityPausedCard(icon: LiveActivitySprites.flame, title: attributes.recipeName)
        } else {
            liveCard
        }
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveActivityHeaderLabel(icon: LiveActivitySprites.flame, title: attributes.recipeName)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Step \(state.stepNumber) of \(state.stepCount)")
                        .font(LiveActivityFont.stepCount)
                        .foregroundStyle(look.moss)
                    Text(verbatim: state.stepText)
                        .font(LiveActivityFont.step)
                        .foregroundStyle(look.ink)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if hasTimer(state) {
                    StepCountdownText(state: state, font: LiveActivityFont.countdown, color: look.ink)
                        .countdownSlot(width: 112, alignment: .trailing)
                        .layoutPriority(1)
                }
            }
            nextStepButton(state, onIsland: false)
        }
    }
}

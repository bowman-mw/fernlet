//
//  BodybuildingDeloadSuggestionCard.swift
//  Fernlet
//
//  The suggested deload week (World round 7, `bb-deload-suggest`, approved 2026-10-29; spec §9, the
//  owner's "Suggest, I decide"): one card at the top of the Day calendar after six hard weeks in a row.
//  Nothing changes unless the person taps. No notification, no streak, nothing counted. VoiceOver reads
//  the card as one group holding its two buttons.
//

import FernletUI
import SwiftUI

/// "Time for a lighter week?" with Make next week a deload (primary) and Not now (secondary).
struct BodybuildingDeloadSuggestionCard: View {
    let onAccept: () -> Void
    let onDecline: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Time for a lighter week?", comment: "Day calendar: the deload suggestion card's title, shown after six hard training weeks in a row")
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
                    .accessibilityAddTraits(.isHeader)
                Text("Six hard weeks in a row. A deload week next week gives your body time to catch up. It's your call.",
                     comment: "Day calendar: the deload suggestion card's text. A deload week is a planned lighter training week; the person decides.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fernletWrappingText()
                AdaptiveStack(spacing: 10) {
                    Button(action: onAccept) {
                        Text("Make next week a deload", comment: "Day calendar: the deload suggestion's primary button, marks next week as a deload week")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .accessibilityIdentifier("bodybuilding.deloadSuggestion.accept")
                    Button(action: onDecline) {
                        Text("Not now", comment: "Day calendar: the deload suggestion's secondary button, hides the suggestion")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    .accessibilityIdentifier("bodybuilding.deloadSuggestion.decline")
                }
                Text("Not now hides it; Fernlet asks again only after two more hard weeks.",
                     comment: "Day calendar: under the deload suggestion's buttons, what Not now does")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fernletWrappingText()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bodybuilding.deloadSuggestion")
    }
}

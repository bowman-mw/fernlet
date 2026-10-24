import SwiftUI
import FernletUI

/// Where the guided run is, for the how-to sheet opened from the runner (`b3-howto` draft 2: "the
/// bottom keeps where you are … with Done set, so you can keep the how-to open"). The runner hands it
/// down through the environment while its how-to is open; any other presenter leaves it nil and the
/// sheet has no such bar.
struct HowToRunFooter {
    /// "Now · Set 2 of 2 · 10–12 reps", or the rest that is running.
    let now: Text
    /// What comes after this set ("Rest 20 s next"), or nil.
    let next: Text?
    /// The runner's own primary for this moment ("Done set", "Skip rest", "Finish workout").
    let actionLabel: LocalizedStringKey
    /// The runner's own transition for that primary, with its cue and spoken line.
    let action: () -> Void
}

extension EnvironmentValues {
    /// The guided run's place, for a how-to sheet opened from the runner; nil anywhere else.
    @Entry var exerciseHowToRunFooter: HowToRunFooter? = nil
}

/// The how-to sheet's bottom bar when it was opened from the runner: where the run is in one framed
/// line, then the runner's primary. Tapping it moves the run on and the sheet stays open.
struct HowToRunFooterBar: View {
    let footer: HowToRunFooter
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(spacing: 10) {
            AdaptiveStack(spacing: 6, horizontalAlignment: .leading) {
                footer.now
                    .font(FernletFramedFont.rowTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let next = footer.next {
                    next
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(MoveInsetCardFrame(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            Button(action: footer.action) {
                Text(footer.actionLabel).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .accessibilityIdentifier("workout.howTo.runAction")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

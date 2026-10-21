import UIKit

/// The extension's three haptics (sounds-and-haptics Tier B, 2026-10-20, report B23): a card picked,
/// a card placed in the message field, and a share or a hand-off to Fernlet that didn't happen.
///
/// This target links `FernletExchange` and nothing else from FernletKit
/// (`MessagesExtensionBoundaryTests`), so it cannot reach FernletUI's `FernletFeedback`. Rather than
/// widen the extension's link set for three calls, the three feels are copied from that seam's table,
/// and `Scripts/feedback-allowlist.json` names this file — and only this file — as the one place in
/// the target that may make a UIKit generator. Keep the feels in step with FernletUI's events:
///
/// | Case | FernletUI event | Feel |
/// |---|---|---|
/// | ``picked`` | `tick` | the selection tick |
/// | ``inserted`` | `logged` | a soft impact at half strength |
/// | ``failed`` | `failed` | the error notification |
///
/// Every case answers the person's own tap, and each has a visual twin: the picked card's moss
/// outline, and the status line under the title for the other two. Never a sound. The UIKit
/// generators play nothing when the system's Sounds & Haptics switch is off. Fernlet's own All /
/// Fewer / Off level lives in the app's defaults, which this process cannot read, so it does not
/// reach here: the system switch is the one that governs Messages.
enum FernletMessagesHaptic {
    /// A recipe or workout card was picked.
    case picked
    /// The card is in the message field, waiting for Messages' own send button.
    case inserted
    /// It didn't happen: nothing picked, too large for a card, Messages would not take the card, or
    /// a received card could not be handed to Fernlet for review.
    case failed

    /// Plays the feel. Main-actor, like the controller that calls it and the generators it drives.
    func play() {
        switch self {
        case .picked:
            UISelectionFeedbackGenerator().selectionChanged()
        case .inserted:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
        case .failed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

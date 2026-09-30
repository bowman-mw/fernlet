import MessageUI
import Messages
import SwiftUI
import UIKit

/// How a "Send in Messages" draft ended, as the recipe Share screen reports it.
///
/// `sent` means Messages accepted the message for sending — never that it was delivered or opened,
/// the same line ``RecipeShareConfirmation`` holds for the nearby share. A draft the person cancelled
/// is `cancelled` and shows nothing.
nonisolated enum RecipeMessagesSendOutcome: Equatable {
    case sent
    case cancelled
    case failed

    /// Maps MessageUI's result. An unknown future case reads as a failure, so nothing claims "sent"
    /// that Messages did not say.
    init(_ result: MessageComposeResult) {
        switch result {
        case .sent: self = .sent
        case .cancelled: self = .cancelled
        case .failed: self = .failed
        @unknown default: self = .failed
        }
    }
}

/// The Messages draft behind the recipe Share screen's "Send in Messages": an
/// `MFMessageComposeViewController` holding the Fernlet recipe card and nothing else — no body, no
/// recipients. The person picks who it goes to and presses Messages' own Send.
///
/// The card is `FernletMessagesCard.recipeMessage(for:)`, the same builder the iMessage app inserts
/// with, so both cards are the same bytes. Messages attributes a card composed here to Fernlet's own
/// iMessage extension (the app embeds it), which is what opens it on the recipient's iPhone.
///
/// **Gate before presenting, every time.** Where Messages is not set up — and on every simulator
/// (measured 2026-09-30, iOS 26.5) — `canSendText()` is false, `MFMessageComposeViewController()`
/// hands back a nil object Swift types as non-optional, and presenting it throws
/// `NSInvalidArgumentException`. ``canSendText`` is therefore read when the row is drawn AND again
/// in the tap action, and only a `true` ever presents this view.
///
/// Present it with `.sheet(item:)`; ``onFinish`` runs once, on the main actor, with the outcome, and
/// the caller dismisses the sheet.
struct RecipeMessageComposer: UIViewControllerRepresentable {
    /// The card to send.
    let message: MSMessage
    /// Runs when the person sends or cancels, or Messages fails.
    let onFinish: (RecipeMessagesSendOutcome) -> Void

    /// Whether this device can compose a message right now. Read live; never cached.
    static var canSendText: Bool {
        MFMessageComposeViewController.canSendText()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.message = message
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    /// The composer's delegate. MessageUI documents no queue for the callback, so it is received
    /// `nonisolated` and handed to the main actor explicitly rather than trusting whichever thread
    /// calls back — the shape `FernletMessagesViewController` uses for Messages' own completions.
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: (RecipeMessagesSendOutcome) -> Void

        init(onFinish: @escaping (RecipeMessagesSendOutcome) -> Void) {
            self.onFinish = onFinish
        }

        nonisolated func messageComposeViewController(
            _ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult
        ) {
            let outcome = RecipeMessagesSendOutcome(result)
            Task { @MainActor [weak self] in
                self?.onFinish(outcome)
            }
        }
    }
}

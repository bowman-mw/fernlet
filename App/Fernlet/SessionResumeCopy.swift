// SessionResumeCopy.swift
// Fernlet
//
// Network migration P7 item 5: the sentences the Friends surface shows for what the launch restore
// found. `MeshNetworkManager.sessionResumePresentation` carries a frozen four-case value; this
// file, in the APP target, forks it into copy — the app bundle *is* `Bundle.main`, so a bare
// `LocalizedStringKey` literal is the correct form and the catalog sync harvests it.
//
// `RoutedShareRefusalCopy` and `SessionHeartStatusCopy` are the pattern, deliberately: one place,
// so it can be tested (a view's private computed property cannot be), and an exhaustive `switch` so
// a new presentation case — or a new ending — is a build error here until it has a sentence.
//
// Every sentence says what is true and no more: an offer asks the person to keep the tab open (the
// restore arms no radio; discovery re-links into the same mesh when a member is nearby), an ending
// is named as ended and never as failed, and the set-aside file says that nothing already saved
// was lost. Wording is the owner's to change; the shape is not.

import SwiftUI
import ProximityKit

/// One card's worth of copy for a presented restore outcome.
struct SessionResumeCard: Equatable {

    /// The card's headline.
    let title: LocalizedStringKey

    /// The card's one explanatory sentence.
    let message: LocalizedStringKey

    /// The SF Symbol beside it. A name, never display text.
    let symbolName: String
}

/// The copy for `MeshNetworkManager.sessionResumePresentation`, one card per presented case.
enum SessionResumeCopy {

    /// The dismiss action's label, shared by every card.
    static let dismiss: LocalizedStringKey = "Got it"

    /// The card for a presentation, or nil for `.nothing` — the one case that shows no card.
    ///
    /// - Parameter presentation: What the manager says the restore found.
    /// - Returns: The card, or nil when there is nothing to present.
    static func card(for presentation: MeshSessionResumePresentation) -> SessionResumeCard? {
        switch presentation {
        case .nothing:
            return nil
        case .offerResume:
            return SessionResumeCard(
                title: "Pick up your last session",
                message: "Keep this tab open. When someone from that session is nearby again, you'll reconnect automatically, and anything still on its way will finish arriving.",
                symbolName: "arrow.clockwise.circle"
            )
        case .previousSessionEnded(let ending):
            return endedCard(ending)
        case .previousSessionCouldNotBeReopened:
            return SessionResumeCard(
                title: "Your last session couldn't be reopened",
                message: "Its saved state was set aside. Nothing that was already saved was lost.",
                symbolName: "doc.badge.ellipsis"
            )
        }
    }

    /// The card for an ending, one sentence per fold — ended, never failed.
    private static func endedCard(_ ending: MeshSessionEndingPresentation) -> SessionResumeCard {
        switch ending {
        case .ended:
            return SessionResumeCard(
                title: "Your last session ended",
                message: "That session is over, so it can't be reopened. Anything you kept is already saved.",
                symbolName: "checkmark.circle"
            )
        case .expired:
            return SessionResumeCard(
                title: "Your last session timed out",
                message: "Sessions last up to six hours. Anything you kept is already saved.",
                symbolName: "clock"
            )
        case .youLeft:
            return SessionResumeCard(
                title: "You left your last session",
                message: "It can't be reopened, but anything you kept is already saved.",
                symbolName: "figure.walk"
            )
        case .youWereRemoved:
            return SessionResumeCard(
                title: "Your last session ended for you",
                message: "You were removed from that session. Anything you kept is already saved.",
                symbolName: "person.crop.circle.badge.minus"
            )
        }
    }
}

// SessionHeartStatusCopy.swift
// Fernlet
//
// Network migration P6 item 6: the sentence an in-session heart's state shows.
// `MeshNetworkManager.SessionHeartState` carries a frozen `SessionHeartFailure` token; this file, in
// the APP target, forks it into copy — the app bundle *is* `Bundle.main`, so a bare
// `LocalizedStringKey` literal is the correct form and the catalog sync harvests it.
//
// It closes a LIVE hole rather than tidying one. Before item 6 the case was
// `failed(message: String)` and all six of its sentences were composed **inside ProximityKit**, so
// they rendered English in every language — the exact defect D-13.15 closed for the routed share
// refusal, in a seam D-13.15 did not reach, and invisible to both halves of
// `LocalizationBoundaryTests`: one half scans `String(localized:)` call sites and the other scans
// SwiftUI display-literal call heads and held `LocalizedStringKey` members, and a bare `String`
// associated value matches neither. Measured at the time: five of the six sentences were absent from
// `Localizable.xcstrings` altogether.
//
// `RoutedShareRefusalCopy` is the pattern, deliberately: one place, so it can be tested (a view's
// private computed property cannot be), and an exhaustive `switch` so a new
// `SessionHeartFailure` case is a build error here until it has a sentence.
//
// NOT here: the presence path's copy. `PresenceManager.heartSendState` has its own
// `failed(message: String)` — the same hole, in P9's scope — and this file must not be widened into
// it, because forking half of a seam is how the other half acquires a `LocalizedStringKey(runtime)`
// conversion and the hole moves rather than closing.

import SwiftUI
import ProximityKit

/// The copy for an in-session heart's state, one sentence per frozen cause.
///
/// Every failure sentence says the same two things — no heart was sent, and what the user can do
/// about it — and differs only where the user can act on the difference. The exhaustive `switch` is
/// the point: a new `MeshNetworkManager.SessionHeartFailure` case is a build error here until it has
/// a sentence. Wording is the owner's to change; the shape is not.
enum SessionHeartStatusCopy {

    /// The sentence for a heart that reached this device's routed store.
    ///
    /// "Sent", not "delivered", and the distinction is real: the routed stage is
    /// durable-before-acknowledged, so the sealed heart is on disk under a signed manifest and will
    /// be pushed, drained or custody-transferred until it is delivered or expires. The wording has
    /// never claimed a receipt.
    ///
    /// - Parameter recipientName: The friend's display name.
    /// - Returns: a `LocalizedStringKey`, never a `String` — `Text(String)` selects the
    ///   `StringProtocol` overload and renders verbatim.
    static func sent(recipientName: String) -> LocalizedStringKey {
        "Sent \(recipientName) some good vibes."
    }

    /// The sentence for one frozen failure cause.
    ///
    /// - Parameters:
    ///   - cause: The frozen token the manager published.
    ///   - recipientName: The friend's display name; the first name is used where the sentence
    ///     reads better for it, exactly as the pre-item-6 sentences did.
    /// - Returns: a `LocalizedStringKey`, never a `String`.
    static func message(
        _ cause: MeshNetworkManager.SessionHeartFailure, recipientName: String
    ) -> LocalizedStringKey {
        let firstName = PresenceManager.firstName(of: recipientName)
        switch cause {
        case .heartsOff:
            return "Turn on nearby hearts to send \(firstName) some warmth."
        case .ledgerUnavailable:
            return "Fernlet couldn't reach its own notes just now — unlock and reopen to send hearts."
        case .cooldown:
            return "You just sent \(firstName) some warmth — hearts settle for a few minutes."
        case .alreadySending:
            return "Already sending \(firstName) some warmth — one moment."
        case .recipientLeft:
            return "\(firstName) left the session — no heart was sent."
        case .notReachableYet:
            return "Fernlet can't reach \(firstName) yet, so no heart was sent. Try again in a moment."
        case .identityUnconfirmed:
            return "Fernlet couldn't confirm who it was sending to, so no heart was sent."
        case .couldNotSend:
            return "Could not send that heart just now."
        case .storageUnreachable:
            return "Fernlet is holding all it can, so no heart was sent."
        case .holdingAllItCan:
            return "Fernlet couldn't reach its heart storage, so no heart was sent."
        }
    }

    /// The whole mesh-path status line, or nil when the mesh path has nothing to say.
    ///
    /// **Two properties rather than one, and that is the fix for a hazard this commit created.**
    /// `DisposableCameraView` holds both transports in one status line, and the presence arm still
    /// carries a `String` (`PresenceManager.heartSendState.failed(message:)`, P9's). Typing the
    /// whole line `LocalizedStringKey?` would force `LocalizedStringKey(runtimeString)` on that arm
    /// — the same defect, newly created, and invisible to the app-target scanners too. So the mesh
    /// path answers a `LocalizedStringKey?` here, the presence path keeps its `String?`, and the
    /// view renders whichever is present.
    ///
    /// - Parameter state: The manager's published state.
    /// - Returns: a `LocalizedStringKey`, or nil for `.idle`.
    static func line(_ state: MeshNetworkManager.SessionHeartState) -> LocalizedStringKey? {
        switch state {
        case .idle:
            return nil
        case .sent(let name):
            return sent(recipientName: name)
        case .failed(let cause, let name):
            return message(cause, recipientName: name)
        }
    }
}

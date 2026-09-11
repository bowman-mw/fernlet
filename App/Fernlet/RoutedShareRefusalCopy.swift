// RoutedShareRefusalCopy.swift
// Fernlet
//
// Network migration P5 item 13 (plan §11), the P5 review's finding 5: the sentence a refused routed
// share shows. `MeshNetworkManager.routedShareRefusal` carries a frozen token; this file, in the
// APP target, forks it into copy — the app bundle *is* `Bundle.main`, so a bare `LocalizedStringKey`
// literal is the correct form and the catalog sync harvests it. The `String` the manager composed
// before rendered verbatim in every language, the live defect of the `meshError` seam.
//
// One place, so it can be tested — a view's private computed property cannot be.
//
// P6 item 4 added a SECOND fork for chat (`chatNotice` / `chatMessage`). Not a reworded first one:
// every photo sentence ends "stayed on your own wall", which for a message is both false and
// unactionable, and the photo path's `routedShareRefusal` alert lives on the view the chat panel
// covers. Both forks switch exhaustively over the same frozen cause, so a new case is a build error
// in each.

import SwiftUI
import ProximityKit

/// The copy for a refused routed share, one sentence per frozen cause.
///
/// Every sentence says the same two things — the share did not happen, and the photo is still on
/// the user's own wall (the local echo is unconditional, D-13.8) — and differs only where the user
/// can act on the difference. The exhaustive `switch` is the point: a new refusal case is a build
/// error here until it has a sentence. Wording is the owner's to change; the shape is not.
enum RoutedShareRefusalCopy {

    /// The alert's title — the session alert's existing key, so the two share one catalog row.
    static let title: LocalizedStringKey = "Session"

    /// The sentence for one cause.
    ///
    /// - Parameter refusal: The frozen cause the manager published.
    /// - Returns: a `LocalizedStringKey`, never a `String` — `Text(String)` selects the
    ///   `StringProtocol` overload and renders verbatim.
    static func message(_ refusal: MeshRoutedShareRefusal) -> LocalizedStringKey {
        switch refusal {
        case .sealFailed, .mintFailed:
            return "Couldn't share that photo with the mesh. It's saved on your own wall."
        case .destinationNotAddressable:
            return "Fernlet can't reach everyone here yet, so that photo stayed on your own wall."
        case .keyMismatch:
            return "Fernlet couldn't confirm who it was sending to, so that photo stayed on your own wall."
        case .storeRefused:
            return "Fernlet is holding all it can, so that photo stayed on your own wall."
        case .storeUnavailable:
            return "Fernlet couldn't reach its shared-photo storage, so that photo stayed on your own wall."
        }
    }

    /// The inline notice the chat panel shows at the top of its compose bar — above the text
    /// field, between it and the transcript — or nil when there is nothing to say (P6 item 4).
    ///
    /// **A second fork rather than a reworded first one.** Every sentence above says "that photo
    /// stayed on your own wall", which is both wrong and unactionable for a message — and the photo
    /// path publishes its refusal on `routedShareRefusal`, whose one consumer is a session `.alert`
    /// on `DisposableCameraView`, the view the chat panel is presented *over*. So chat neither
    /// shares the copy nor shares the surface: `sendTempMessage(_:)` returns its outcome and this
    /// turns it into one sentence, shown in place, with the draft kept so sending again is the retry.
    ///
    /// Two outcomes say nothing on purpose: `.staged`, because the row appearing in the transcript
    /// IS the feedback, and `.empty`, because the send control is already disabled for it.
    ///
    /// - Parameter outcome: What the send decided.
    /// - Returns: a `LocalizedStringKey`, or nil for the two silent outcomes.
    static func chatNotice(_ outcome: MeshTextSendOutcome) -> LocalizedStringKey? {
        switch outcome {
        case .staged, .empty:
            return nil
        case .noDestinations:
            return "Nobody has joined this session yet — that message wasn't sent. Try again in a moment."
        case .ageGated:
            return "Messages are turned off for this account."
        case .refused(let refusal):
            return chatMessage(refusal)
        }
    }

    /// The sentence for one refused chat send — the exhaustive twin of ``message(_:)``, so a new
    /// `MeshRoutedShareRefusal` case is a build error in both forks until it has copy in each.
    ///
    /// - Parameter refusal: The frozen cause the mint answered.
    /// - Returns: a `LocalizedStringKey`, never a `String`.
    static func chatMessage(_ refusal: MeshRoutedShareRefusal) -> LocalizedStringKey {
        switch refusal {
        case .sealFailed, .mintFailed:
            return "Couldn't send that message. Nothing left this phone."
        case .destinationNotAddressable:
            return "Fernlet can't reach everyone here yet, so that message wasn't sent."
        case .keyMismatch:
            return "Fernlet couldn't confirm who it was sending to, so that message wasn't sent."
        case .storeRefused:
            return "Fernlet is holding all it can, so that message wasn't sent."
        case .storeUnavailable:
            return "Fernlet couldn't reach its message storage, so that message wasn't sent."
        }
    }
}

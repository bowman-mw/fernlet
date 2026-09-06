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
        case .storeRefused:
            return "Fernlet is holding all it can, so that photo stayed on your own wall."
        case .storeUnavailable:
            return "Fernlet couldn't reach its shared-photo storage, so that photo stayed on your own wall."
        }
    }
}

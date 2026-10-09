// MeshMergedHeart.swift
// FernletSocial/HeartSharing
//
// P4 item 7 (plan §10.3): the heart as the content merge sees it — union by `(author, gift ID)` over
// ProximityKit's generic union (``MeshMergeableContent``, ``MeshContentSet``). Moved from ProximityKit's
// `MeshContentMerge.swift` at plan step A0.5.10, with the heart ledger and the heart commit; it was
// public there for plan step A0.5.9 alone, while FernletSocial's `MeshContentLedger` named it across
// the module line, and is internal again now that the ledger, the commit and the judge that build one
// are this module's. Moved verbatim otherwise.
//
// Nothing here is persisted and nothing here is wire: a heart's final receipt is still only the
// foreground decrypt + ``ProximityHeartLedger`` commit, which is why receipt state is deliberately NOT
// a field here.

import Foundation
import ProximityKit

// MARK: - MeshMergedHeart

/// One heart as the merge sees it — and deliberately **without** a receipt field.
///
/// §10.3: the final receipt is still only the foreground decrypt + ``ProximityHeartLedger`` commit.
/// A peer's "received" is that peer's receipt, not this member's, so merging one in would be a
/// receipt this device never issued. Receipt state is therefore local and derived
/// (`MeshContentLedger.heartReceipt(_:committed:)`), never merged.
///
/// The contract is the one ``MeshMergeableContent`` states: an item's identity is its gift id and its
/// transport-verified sender, its order the receiver's first-seen instant.
nonisolated struct MeshMergedHeart: MeshMergeableContent {

    /// The most hearts one member keeps: the heart ledger's own retention cap.
    static let setCapacity = ProximityHeartLedger.maxStoredHearts

    /// The gift id the union keys on — the wire payload's id, stable across a duplicate delivery.
    let giftID: UUID
    /// The transport-verified sender.
    let senderFingerprint: String
    /// The sender's display name, already sanitized at the wire boundary.
    let senderDisplayName: String
    /// The receiving member's clock when this heart first entered its view.
    let firstSeenAt: Date

    /// The gift id, the half of the union's key the author minted.
    var contentID: UUID { giftID }
    /// The receiver's first-seen instant: a heart carries no claimed instant of its own.
    var orderingInstant: Date { firstSeenAt }
    /// The sender's display name, the last resort between two copies of one gift.
    var mergeTiebreak: String { senderDisplayName }

    /// Builds a merged-heart projection. `firstSeenAt` must come from the receiver's clock.
    init(giftID: UUID, senderFingerprint: String, senderDisplayName: String, firstSeenAt: Date) {
        self.giftID = giftID
        self.senderFingerprint = senderFingerprint
        self.senderDisplayName = senderDisplayName
        self.firstSeenAt = firstSeenAt
    }
}

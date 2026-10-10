// MeshContentLedger.swift
// FernletSocial/Mesh
//
// P4 item 7 (plan §10.3): the content kinds a partition can split, and the ledger that holds them.
// ProximityKit holds the generic union every kind merges by (``MeshContentKey``, ``MeshMergeableContent``,
// ``MeshContentOrder``, ``MeshContentSet``, each public with its union laws); this file holds Fernlet's
// kinds over it and the one value that carries all three:
//
//   * **Photos** — ``MeshMergedPhoto``, union by `(author, manifest ID)`, hash-validated on reassembly
//     (``MeshPhotoReassembly``, in `MeshContentIngest.swift`), then the existing review flow.
//   * **Texts** — ``MeshMergedMessage``, union by `(author, message ID)`; the visible transcript is
//     re-derived in total order `(claimedSentAt clamped to ±10 min of first-seen, senderFingerprint,
//     messageID)` by ``SessionMessageStore``, this kind's one shipping holder.
//   * **Hearts** — ``MeshMergedHeart``, union by `(author, gift ID)`, in `HeartSharing/` beside the
//     heart ledger and the heart commit (`MeshHeartCommit`).
//
// Nothing here is persisted and nothing here is wire: these are in-memory projections
// built from payloads that already exist, and the gates that filter them are a view filter over an
// unmutated union (`MeshContentIngest.swift`).

import Foundation
import FernletDomainModel
import ProximityKit

// MARK: - MeshMergedPhoto

/// One shared photo as the merge sees it: manifest id, author, the epoch it was sealed at, when it
/// was added, and the digest its reassembled bytes must match.
///
/// A projection of ``FriendPhotoManifestEntry`` plus what the holder knows about the bytes — the
/// digest is a **local** value, not a wire field, so no manifest golden moves. `keyEpoch` is carried
/// because the legacy path gated on it and a photo created in the *other* branch of a split
/// necessarily names another epoch. Since P5 item 13 the LIVE photo path gates on no epoch at all
/// (see `MeshContentIngest.swift`'s note), and this value is untouched by that retirement: it is a
/// pure value with no manager call site, and P6 owns its wiring.
nonisolated struct MeshMergedPhoto: MeshMergeableContent {

    static let setCapacity = FriendPhotoLimits.maxManifestEntries

    /// The manifest id the union keys on.
    let manifestID: UUID
    /// The photo's author, as the manifest announced it.
    let senderFingerprint: String
    /// The group-key epoch the bytes were sealed at. `0` is the legacy unencrypted shape.
    let keyEpoch: Int
    /// When the author added the photo — the set's ordering instant.
    let addedAt: Date
    /// SHA-256 of the photo's reassembled bytes, as this holder computed them.
    let contentDigest: Data

    var contentID: UUID { manifestID }
    var orderingInstant: Date { addedAt }
    var mergeTiebreak: String { contentDigest.base64EncodedString() }

    /// Builds a merged-photo projection.
    init(manifestID: UUID, senderFingerprint: String, keyEpoch: Int, addedAt: Date, contentDigest: Data) {
        self.manifestID = manifestID
        self.senderFingerprint = senderFingerprint
        self.keyEpoch = keyEpoch
        self.addedAt = addedAt
        self.contentDigest = contentDigest
    }
}

// MARK: - MeshMergedMessage

/// One session message as the merge sees it, carrying **both** clocks §10.3's order needs.
///
/// `claimedSentAt` is the sender's own stamp and is never trusted alone; `firstSeenAt` is the
/// **receiver's** clock at the moment the message entered this device's view, and it is the anchor
/// the claim is clamped against. ``orderingInstant`` is the clamped value, so a peer claiming three
/// hours ago — or three hours hence — moves at most ``claimWindow`` from where it actually arrived.
///
/// **The clamp is a bound, not a coordination mechanism.** Two members assign their own first-seen
/// instants, so convergence on an identical transcript holds for every claim *inside* its window
/// (the ordering instant is then the claim itself, which every member agrees on). A forged claim
/// outside the window is bounded at each member's own clock, which is the security property; it is
/// not a promise that a forger sorts identically everywhere.
nonisolated struct MeshMergedMessage: MeshMergeableContent {

    static let setCapacity = SessionMessageStore.maxMessages

    /// How far from first-seen a claimed stamp may reach, in either direction (plan §10.3).
    static let claimWindow: TimeInterval = 10 * 60

    /// The message id the union keys on.
    let messageID: UUID
    /// The transport-verified sender.
    let senderFingerprint: String
    /// The already-sanitized text (`SessionMessageStore.sanitize` ran at the wire boundary).
    let text: String
    /// The sender's own stamp. Untrusted; clamped before it orders anything.
    let claimedSentAt: Date
    /// The receiving member's clock when this message first entered its view. Never a wire value.
    let firstSeenAt: Date

    var contentID: UUID { messageID }
    var orderingInstant: Date { Self.clamped(claimedSentAt, around: firstSeenAt) }
    var mergeTiebreak: String { text }

    /// Builds a merged-message projection. `firstSeenAt` must come from the receiver's clock.
    init(messageID: UUID, senderFingerprint: String, text: String, claimedSentAt: Date, firstSeenAt: Date) {
        self.messageID = messageID
        self.senderFingerprint = senderFingerprint
        self.text = text
        self.claimedSentAt = claimedSentAt
        self.firstSeenAt = firstSeenAt
    }

    /// `claim` pulled into ±``claimWindow`` of `firstSeen`. A claim already inside the window is
    /// returned unchanged, which is why honest traffic sorts identically at every member.
    static func clamped(_ claim: Date, around firstSeen: Date) -> Date {
        let earliest = firstSeen.addingTimeInterval(-claimWindow)
        let latest = firstSeen.addingTimeInterval(claimWindow)
        return min(max(claim, earliest), latest)
    }
}

// MARK: - MeshContentLedger

/// Everything a member holds of a split's *content*: three ``MeshContentKey``-keyed sets, and
/// nothing else.
///
/// The content-side twin of ``MeshMembershipLedger`` — pure value data with a pure union, so
/// §16.2's convergence property needs no store and no transport. Merging is the only way two views
/// combine; there is no "apply an item to a transcript" path, which is what makes reconnect, merge
/// and reload one code path.
///
/// The gates that decide what a member *shows* are a separate, read-time filter
/// (`MeshContentIngest.swift`): a blocked sender's message still unions, it simply does not render
/// at the member that blocked them. Same shape as termination-derived-at-read, and for the same
/// reason — a merge that mutated records would break the union laws.
nonisolated struct MeshContentLedger: Equatable, Sendable {

    /// Photos held, by manifest id.
    var photos: MeshContentSet<MeshMergedPhoto>
    /// Messages held, by message id.
    var messages: MeshContentSet<MeshMergedMessage>
    /// Hearts held, by gift id.
    var hearts: MeshContentSet<MeshMergedHeart>

    /// A ledger holding no content.
    static var empty: MeshContentLedger { MeshContentLedger() }

    /// Builds a content ledger from any combination of sets.
    init(
        photos: MeshContentSet<MeshMergedPhoto> = .empty,
        messages: MeshContentSet<MeshMergedMessage> = .empty,
        hearts: MeshContentSet<MeshMergedHeart> = .empty
    ) {
        self.photos = photos
        self.messages = messages
        self.hearts = hearts
    }

    /// The union of two content ledgers: set union in all three kinds. Commutative, associative,
    /// idempotent — N-way merges need no special case because pairwise union already converges.
    func merging(_ other: MeshContentLedger) -> MeshContentLedger {
        MeshContentLedger(
            photos: photos.merging(other.photos),
            messages: messages.merging(other.messages),
            hearts: hearts.merging(other.hearts)
        )
    }
}

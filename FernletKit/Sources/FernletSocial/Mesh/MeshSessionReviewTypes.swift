// MeshSessionReviewTypes.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.11: the session-end review's three values, moved from ProximityKit's
// `MeshSessionTypes.swift` with the photos, verbatim but for the docs that named their producer: the
// review batch (the ended session's keep-as-friend candidates and the photos still awaiting the
// person's choice), why an answer could not be applied in full, and what an answer did, photo by
// photo. FernletSocial's photo object (`MeshSessionPhotos`) is their one producer; the app and
// FernletProximityUI's review sheet read them. A batch's candidates are ProximityKit's
// `MeshSessionRosterEntry`, which stays with the session roster the engine records them in.

import FernletDomainModel
import Foundation
import ProximityKit

/// A promoted, unconsumed session-end review (Phase 2, "Session-end review is model-state, not
/// view-events" — Docs/Proximity-Mesh-Redesign-2026-07-10.md): the ended session's keep-as-friend
/// candidates **and the photos the user has not yet chosen between**.
///
/// The photo object (``MeshSessionPhotos``) merges the session roster the mesh drains AND moves the
/// live `sessionPhotos` into one of these at the session-end moment (`MeshNetworkManager.isSessionLive`
/// going false — every ending, including this device being the last member left when the others end
/// the mesh), told by the mesh's session observer; views present off this
/// observable state instead of `isInSession` view-events (the Social-tab layout swap destroys the
/// presenting view in the same transaction as the `isInSession` flip).
///
/// **Nothing in `photos` is on the friend wall** (2026-09-30, the owner's rule: "None of the photos
/// should be saved ... until this selection has been made"). Every session photo, taken here or
/// received from a peer, is HELD in the sealed pending corpus (`PendingSessionPhotoStore`, its own
/// device-bound key, excluded from backup) from the moment it exists; `photos` and `sessionPhotos`
/// are two memory projections of that corpus's index, metadata only. A photo reaches the wall only
/// through the person's answer (``MeshSessionPhotos/finishReviewedPhotos(_:keeping:in:)`` here,
/// ``MeshSessionPhotos/finishSessionPhotos(keeping:of:)`` in the camera), and an unkept one is deleted for good and
/// tombstoned by its origin and item id so the mesh cannot deliver it again.
///
/// Not Codable, and it needs no persistence of its own: the pending index IS the durable truth, and
/// a photo object built after a process kill rebuilds a photos-only batch of this type from it (every
/// held photo is awaiting by definition at launch — no session is live until a commit). The
/// CANDIDATES are memory-only key material like the roster entries they are, so a kill loses the
/// keep-as-friend offer (Q5) and never the photo choice. It survives `startJoin` / `startNewMesh`
/// so an unreviewed batch from the previous session re-presents (merged) after the next teardown.
public nonisolated struct MeshFriendReviewBatch: Identifiable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var entries: [MeshSessionRosterEntry]
    /// The ended session's photos still awaiting the user's keep/discard choice, newest first,
    /// metadata-only, each id the photo's LOCAL id in the pending corpus. None is on the friend wall:
    /// the review is the admission, never a prune.
    public internal(set) var photos: [FriendPhotoPayload]

    public init(id: UUID = UUID(), entries: [MeshSessionRosterEntry], photos: [FriendPhotoPayload] = []) {
        self.id = id
        self.entries = entries
        self.photos = photos
    }

    /// Whether nothing is left for the user to answer — no candidate and no photo.
    public var isEmpty: Bool { entries.isEmpty && photos.isEmpty }
}

/// Why a session-photo answer could not be applied in full (the 2026-09-30 held-photo review).
///
/// A frozen reason, never copy: the review surfaces fork it into their own localized lines.
///
/// Concurrency: an immutable `Sendable` value.
public nonisolated enum SessionPhotoAnswerFailure: Equatable, Sendable {
    /// Nothing could be applied: the device is locked or the app backgrounded, a duress session is
    /// in force (the answer reads plaintext, so it runs only where the routed gate is open), or the
    /// pending index cannot be read right now. Also a KEEP whose held bytes could not be read right
    /// now (no key, or a file read that failed): those photos stay held for a retry, while the rest
    /// of the answer applied.
    case unavailable
    /// The friend wall's index cannot be read, so no photo can be KEPT; the discards were applied,
    /// because they need only the pending index.
    case keepUnavailable
    /// The wall did not take some kept photos (a disk or key failure). They stay held, untouched,
    /// and nothing of theirs was swept.
    case wallWriteFailed
}

/// What one answer to a session-photo review actually did, photo by photo (local ids).
///
/// The hosts read it rather than assume: the camera-roll export runs over ``keptOnWall`` ONLY
/// (those are the photos whose sealed bytes landed on the wall and whose index names them), and a
/// non-empty ``notApplied`` keeps the review up with an inline failure instead of hiding it. Ids the
/// answer was given that are no longer held (already answered elsewhere) appear in no set: the first
/// answer wins.
///
/// Concurrency: an immutable `Sendable` value.
public nonisolated struct SessionPhotoAnswer: Equatable, Sendable {
    /// Kept and landed on the wall — the ONLY ids a Photos-library export may use.
    public let keptOnWall: Set<UUID>
    /// Not kept: deleted for good and tombstoned.
    public let discarded: Set<UUID>
    /// Kept, but their held bytes could not be opened: removed like a discard, and the review says so.
    public let unreadable: Set<UUID>
    /// Still held and still offered, untouched by this answer.
    public let notApplied: Set<UUID>
    /// Why ``notApplied`` is not empty (or why the keeps were refused), when it is.
    public let failure: SessionPhotoAnswerFailure?

    /// An answer that did nothing and owes nothing — nothing it named was still held.
    public static let nothing = SessionPhotoAnswer(
        keptOnWall: [], discarded: [], unreadable: [], notApplied: [], failure: nil
    )

    /// Creates an answer report; ``MeshSessionPhotos`` is the only producer outside tests.
    public init(
        keptOnWall: Set<UUID>,
        discarded: Set<UUID>,
        unreadable: Set<UUID>,
        notApplied: Set<UUID>,
        failure: SessionPhotoAnswerFailure?
    ) {
        self.keptOnWall = keptOnWall
        self.discarded = discarded
        self.unreadable = unreadable
        self.notApplied = notApplied
        self.failure = failure
    }
}

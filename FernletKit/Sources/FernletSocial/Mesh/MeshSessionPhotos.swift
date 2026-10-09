// MeshSessionPhotos.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.11: the session's photos, moved from the mesh manager with no byte,
// golden or audit change — the friend-photo wall with its preferences and favourites, the sealed
// pending corpus every session photo is held in until the person answers and the answers that empty
// it, the film and its quota, the session-end review batch, `addPhoto(_:)` and the routed photo sender,
// which mints through the engine's public origination door, and the photo row's projection handler, a
// private adapter nested here that the composition (`FernletMeshFeatures`) registers under the host's
// photo row: the tombstone settlement before the engine opens an item, then the per-origin quota, the
// sanitised hold and the closeness hook, in that order. One file, so the moved code's `private`
// members stay private.
//
// The engine keeps what it always decided: the session roster and its custody (it drains the roster
// into each session's ending, and this object merges what it is handed), the routed access gate (it
// tells the observer each change, which this object mirrors), whether a session is live, the mesh the
// session counts against, and the whole guard chain above a handler. Every leg this object runs at a
// session's moment — the review merge and the photo move first at its end, the film's reset, the
// leftover photos' move and the new photo session at a new search, the photo session forgotten when
// it is left, the film's mesh pin at each scope change, a removed member's purge from the review, and
// the photo indexes' re-read on a rising access edge — is run by the composition's session observer,
// at the engine position the manager ran it at.

import Foundation
import Observation
import UIKit
import FernletDomainModel
import FernletFoundation
import PrivateMediaStore
import ProximityKit

// MARK: - Supporting types

/// One tile on the home photo wall: a single photo, or an aggregated session carousel with its
/// chosen cover.
///
/// Derived on demand by ``MeshSessionPhotos/photoWallPosts`` from the cached photo metadata plus
/// the wall preferences (aggregation, covers, favorites); never persisted itself.
public struct FriendPhotoWallPost: Identifiable {
    public let id: UUID
    public let session: FriendPhotoSessionMetadata?
    public let photos: [FriendPhotoPayload]
    public let coverPhoto: FriendPhotoPayload

    public init(
        id: UUID,
        session: FriendPhotoSessionMetadata?,
        photos: [FriendPhotoPayload],
        coverPhoto: FriendPhotoPayload
    ) {
        self.id = id
        self.session = session
        self.photos = photos
        self.coverPhoto = coverPhoto
    }

    public var isCarousel: Bool { photos.count > 1 }
}

/// Persisted photo-wall preferences: which sessions are aggregated into carousels, their cover
/// photos, and the per-session favorite.
///
/// Loaded/saved through the shared ``JSONSidecarFile`` helper (`MeshPhotoWallPreferences.json`,
/// `.completeFileProtection`); lives beside the photo cache, never in the synced snapshot. A
/// failed load falls back to empty preferences; a failed save is silently dropped — wall
/// cosmetics, not data of record.
private struct FriendPhotoWallPreferences: Codable, Equatable {
    var aggregatedSessionIDs: Set<UUID> = []
    var coverPhotoIDsBySession: [UUID: UUID] = [:]
    var favoritePhotoIDsBySession: [UUID: UUID] = [:]
}

// MARK: - MeshSessionPhotos

/// Fernlet's session photos: the friend-photo wall with its preferences and favourites, the sealed
/// pending corpus every session photo is held in until the person answers, the film and its quota, the
/// session-end review batch, the capture (``addPhoto(_:)``) and its routed share, and, through a private
/// adapter, the photo row's projection handler.
///
/// Built by the composition (``FernletMeshFeatures``) right after the activity manager, the order the
/// mesh manager's initializer built them in, over its mesh, held weakly, the features' host holder,
/// under whose proximity root both corpora live and under whose namespace a peer's names are
/// re-moderated, the token of the host's photo row (FernletSocial's ``FernletRoutedTypes``), which the
/// sender mints under and the composition registers the adapter under, and the pending corpus's key
/// provider (nil in every shipping path: the device-bound keychain row). Its construction loads both
/// corpora — the wall, then the pending corpus, then the reconcile — as the manager's did.
///
/// Session photos are never on the wall before the person chooses (2026-09-30): each one — taken here
/// or received — is HELD in the sealed pending corpus (`PendingSessionPhotoStore`) from the moment it
/// exists, the ending moves it in memory only, a relaunch rebuilds the review from that corpus, and
/// only the answer copies kept photos to the wall. Chosen photos persist metadata-only in the
/// `PrivateMediaStore`-backed wall (bytes on disk, rehydrated on demand) with per-sender send and
/// receive quotas; unchosen ones only in the pending corpus, whose answered tombstones (origin + item
/// id) refuse a routed re-delivery before decrypt. Memory-only session state everywhere except the
/// wall, the pending corpus and the wall preferences — none of it synced. `purgeHeldSessionPhotosForDeleteAll()`
/// is the pending corpus's leg of the delete-all seam, and ``invalidateEncryptionKeyCaches()`` the
/// two stores' key caches'.
///
/// The session's moments reach it from the mesh through the composition's session observer, each at
/// the engine position the manager ran its photo leg at: a new search (``beginNewPhotoSession()``),
/// the session's end with the roster the mesh drained (``promoteEndedSessionIntoPendingReview(drainedRoster:)``),
/// the session left (``forgetPhotoSession()``), the three scope changes (``noteScopeChange(_:)``), a
/// removed member (``dropRemovedMemberFromReview(fingerprint:)``) and each change of the routed access
/// gate (``applyAccessGate(_:isRising:now:)``).
///
/// `@MainActor` and `@Observable`, like the mesh manager that held all of this until plan step A0.5.11,
/// with its `@ObservationIgnored` annotations kept: views observe the wall, the live roll, the review
/// batch, ``heldPhotosCanBeShown``, the film and the favourites through this object
/// (`store.meshFeatures.photos`).
@MainActor
@Observable
public final class MeshSessionPhotos {

    // MARK: - Published state

    /// The friend-photo wall: the photos the person KEPT, newest first, metadata-only — their bytes are
    /// sealed on disk in the wall's store and read through ``imageData(for:)``, ``thumbnailData(for:)``
    /// and ``hydratedPhotos(_:)``. A session photo reaches it only through the person's answer
    /// (2026-09-30).
    public var meshPhotos: [FriendPhotoPayload] = []
    /// Photos taken/received during the current (LIVE) proximity-join session, metadata-only — the
    /// list the in-camera Develop review snapshots its ids from (and renders through
    /// ``photosAwaitingAnswer(among:)``, so a photo moved out from under it is still offered).
    ///
    /// A memory projection of the sealed pending corpus (2026-09-30): every entry is HELD there
    /// (``holdSessionPhoto(_:key:live:)``), never on the wall, and its id is the photo's local id.
    /// It is emptied only by the person's choice (``finishSessionPhotos(keeping:of:)``), by the
    /// session-end promotion, which MOVES what is left into `pendingFriendReview.photos` without a
    /// disk write (``promoteEndedSessionIntoPendingReview(drainedRoster:)``; a new search runs the
    /// photo half unconditionally, ``beginNewPhotoSession()``), and by delete-all
    /// (``purgeHeldSessionPhotosForDeleteAll()``).
    public private(set) var sessionPhotos: [FriendPhotoPayload] = []
    /// The promoted, unconsumed session-end review: keep-as-friend candidates plus the ended
    /// session's photos still awaiting the keep/discard choice. Set by
    /// ``promoteEndedSessionIntoPendingReview(drainedRoster:)`` at the session-end moment, by a held photo
    /// arriving while no session is live, and — photos only — by the launch rebuild from the
    /// pending corpus (a process kill loses the candidates, never the photos). Cleared only once
    /// BOTH halves are answered — the candidates by `completeFriendReview(_:)`, the photos by
    /// ``finishReviewedPhotos(_:keeping:in:)`` — or by delete-all. Views present off this
    /// observable state (`onChange` + `onAppear` + scene activation) — never off `isInSession`
    /// view-events. Survives startJoin/startNewMesh by design.
    public private(set) var pendingFriendReview: MeshFriendReviewBatch?
    /// Whether a held photo may be drawn and answered right now: the routed access gate is open
    /// (unlocked, foreground, no duress — the decrypt seam ``reviewThumbnailData(for:)`` obeys), the
    /// pending index is readable, and the launch reconcile has run (so no photo already kept on the
    /// wall can be offered again) — or the wall is unreadable with protected data available, the
    /// persistent case in which the photos are offered with Keep refused rather than never.
    ///
    /// A stored, OBSERVED mirror rather than a computed property: two of its three inputs are
    /// `@ObservationIgnored`, so a view reading a computed form would never re-render on the unlock
    /// that opens it. Refreshed at every change of those inputs (``refreshHeldPhotosCanBeShown()``).
    public private(set) var heldPhotosCanBeShown = false
    /// A photo was exchanged with this friend in the current session (feeds the closeness photo signal).
    @ObservationIgnored public var onFriendPhotoSession: ((String) -> Void)?
    /// How many photos this device added to the current mesh session's film: what ``filmRemaining``
    /// and the capture's quota read. Reset at a new search, when this device leaves its mesh, and when
    /// a capture finds the session's mesh changed.
    public private(set) var photosAddedThisSession = 0

    /// How many of this session's captures reached nobody: the routed door answered
    /// `.skipped(.noDestinations)` — no mesh, no ledger, or a derived roster of just this device —
    /// so the photo is on this device alone (held for its review, 2026-09-30) and never will be anywhere
    /// else: destinations are frozen at the mint and there is no offline queue (P8 item 0, device
    /// finding (c)). A count rather than a refusal: the solo first minute of every session is
    /// ordinary and an alert per shot would be hostile, but a session that ends with photos the
    /// user believes were shared and were not is a silent loss. The app forks it into one sentence
    /// (`RoutedShareRefusalCopy.photoKeptNotice(count:)`). Reset with ``photosAddedThisSession``.
    public private(set) var photosKeptOnThisPhone = 0
    @ObservationIgnored private var sessionQuotaMeshID: UUID?
    @ObservationIgnored private var photoSessionStartedAt: Date?
    @ObservationIgnored private var activePhotoSessionID: UUID?

    // MARK: - Stores and quotas

    @ObservationIgnored private let photoCacheStore: PrivateMediaStore
    @ObservationIgnored private let photoWallPreferencesStore: JSONSidecarFile<FriendPhotoWallPreferences>
    @ObservationIgnored private var photoWallPreferences: FriendPhotoWallPreferences
    /// True when the sealed photo index existed at init but could not be opened yet (a locked
    /// keychain before the first post-boot unlock). While set, `persistPhotoIndex` refuses to write:
    /// `meshPhotos` is empty for a reason that is NOT "the wall is empty", and the index is also the
    /// file manifest the store sweeps against, so saving it would delete every kept photo's bytes.
    /// Cleared by the first re-read that succeeds — inside `persistPhotoIndex`, or at the unlock or
    /// foreground edge that makes the file readable again (``retryDeferredPhotoIndexes(now:)``),
    /// so a wall deferred at a locked background launch is not an empty album for the whole process.
    @ObservationIgnored private var photoIndexDeferred = false
    /// The sealed pending corpus (2026-09-30): every session photo, taken here or received, from
    /// the moment it exists until the person answers the review — never the wall. Its own
    /// `PendingSessionPhotos/` directory under the host's proximity root (excluded from backup) and
    /// its own device-bound key (`KeychainPrivateMediaKeyProvider.Role.pendingSessionPhotos`).
    @ObservationIgnored private let heldPhotoStore: PendingSessionPhotoStore
    /// The durable mirror of the pending index: exactly what the last committed write (or a clean
    /// load) left on disk, and what every write is handed. `sessionPhotos` and
    /// `pendingFriendReview.photos` are memory projections of its `photos`; a held local id is in
    /// exactly one of them once the index has been reconciled.
    ///
    /// The one sanctioned divergence: an answer whose write fails still takes its photos out of the
    /// mirror (``PendingSessionPhotoStore/answering(_:in:now:)``), so the review stops offering them
    /// and the next write that lands persists the answer.
    @ObservationIgnored private var heldPhotoIndex = PendingSessionPhotoIndex.empty
    /// Why the pending index could not be read, while it cannot. Nothing writes the corpus while
    /// this is set (every hold is refused), because the mirror is empty for a reason that is not
    /// "nothing is held". Re-read at the unlock/foreground edge and at the top of every hold and
    /// answer.
    @ObservationIgnored private var heldPhotoIndexDeferral: PendingSessionPhotoStore.Deferral?
    /// Whether the launch reconcile has run: the held entries a kill left behind on the wall (the
    /// crash window between an answer's wall commit and its pending write) are dropped, and the
    /// rest offered. It runs only once BOTH indexes are readable — over an unreadable wall it would
    /// re-offer a kept photo — so until then no held photo is offered at all.
    @ObservationIgnored private var heldPhotosReconciled = false
    /// Whether the held photos were offered over a wall that is still unreadable with protected data
    /// AVAILABLE — a persistent failure, not a locked launch. Waiting for the reconcile then would
    /// never end (and in the app it would hold the review, and so the discovery block, for good),
    /// so they are offered with Keep refused (`keepUnavailable`) and Delete all working. The stated
    /// cost: a photo kept just before a kill inside an answer is offered again, and discarding it
    /// leaves the earlier wall copy. The real reconcile still runs the moment the wall reads.
    @ObservationIgnored private var heldPhotosOfferedOverUnreadableWall = false
    /// Observed proxy for favorite changes. `photoWallPreferences` itself is `@ObservationIgnored`
    /// because its `photoWallPosts` getter mutates it during view-body evaluation (plainly observing
    /// it would risk update loops). This counter is bumped ONLY from `toggleFavorite` (a tap handler,
    /// never during body eval), and touch-read in `favoritePhotoID(for:)` and the `photoWallPosts`
    /// getter so the viewer heart and the wall cover both re-render when a favorite toggles.
    private var favoritesRevision = 0
    /// The incoming per-origin photo budget, keyed on the ITEM's mesh (D-13.23).
    ///
    /// The legacy counter keyed on `currentMesh?.meshID` and reset whenever the live mesh changed —
    /// sound while the check always ran inside the session that produced the photo, and wrong on a
    /// routed path whose hand-off runs at any later access-gate edge. Keying on the origin's signed
    /// `manifest.meshID` means a deferred hand-off cannot buy a fresh ten-slot budget.
    ///
    /// Memory-only, bounded on both axes (``MeshRoutedStoreFormat/maxItems`` keys, the per-sender
    /// cap of ids in each) and **not cleared by a mesh change** — see the mesh's `clearRoutedDrainState()`,
    /// which every production mesh change goes through and whose clear would otherwise refund the budget
    /// for items minted in the mesh that is being left (D-13.23a); no scope change this object hears
    /// clears it either (``noteScopeChange(_:)``). It is therefore owed no
    /// `Docs/PrivacyWipeCoverage.md` row for the same reason the drain state is not: nothing here
    /// reaches disk, and the ciphertext it accounts for has its own row.
    @ObservationIgnored private var routedOriginPhotoQuota: [MeshRoutedOriginQuotaKey: Set<UUID>] = [:]

    /// Wall-post count at which older multi-photo sessions start collapsing into one aggregated
    /// post — the bound of the aggregation loop in `progressivelyAggregatePhotoSessions`.
    private static let maxUnaggregatedWallPosts = 24
    /// The film: how many photos one sender may add to one mesh session (``addPhoto(_:)``), and how many
    /// one origin may project into one mesh here (`allowIncomingRoutedPhoto(_:from:)`).
    static let maxPhotosPerSenderPerSession = 10
    /// Hard cap on the in-session photo list, defending against memory growth even if the
    /// per-sender receive quota is bypassed by a future code path. With the per-sender cap
    /// this is reached only by an implausible number of peers.
    private static let maxSessionPhotos = 200

    /// The routed access gate as the mesh last reported it (``applyAccessGate(_:isRising:now:)``, which
    /// the composition's session observer calls at each change the host pushes), `.closed` until the
    /// first: the mesh's own value, mirrored, never a second gate. Every held-photo decision reads it as
    /// it read the manager's own gate — the decrypt seam (``reviewImageData(for:)``), the answers, a
    /// hold's duress refusal, the persistent unreadable-wall offer and ``heldPhotosCanBeShown``.
    @ObservationIgnored private var routedAccessGate: MeshRoutedAccessGate = .closed

    /// The mesh the sender mints through and whose session facts the photos read. Weak: the composition
    /// owns the mesh, and the mesh retains this object's projection adapter, which holds this object.
    @ObservationIgnored private weak var mesh: MeshNetworkManager?

    /// The host whose proximity root the corpora live under, whose display name a capture is sent under,
    /// and whose namespace a peer's names are re-moderated under.
    @ObservationIgnored private let meshHost: FernletMeshHost

    /// The token of the host's photo row (``FernletRoutedTypes/photo``), which the sender mints under,
    /// behind the mesh's `isRoutedTypeRegistered(_:)`.
    @ObservationIgnored private let photoToken: String

    /// The session photos over `mesh` and `meshHost`, minting under `photoToken`: builds both corpora's
    /// stores under the host's proximity root, loads the wall's preferences, then the wall, the pending
    /// corpus and the reconcile (``loadPhotoCorpora(now:)``), logging where the manager's initializer
    /// logged.
    ///
    /// - Parameters:
    ///   - mesh: The composition's mesh, held weakly.
    ///   - meshHost: The features' host holder.
    ///   - photoToken: The token of the host's photo row.
    ///   - heldPhotoKeys: The pending corpus's key provider, or nil (every shipping path) for the
    ///     device-bound keychain row; a test passes an in-memory or wrong key to reach the corpus's
    ///     deferral and purge branches without touching the process-wide row.
    init(
        mesh: MeshNetworkManager,
        meshHost: FernletMeshHost,
        photoToken: String,
        heldPhotoKeys: (any PrivateMediaKeyProviding)?
    ) {
        self.mesh = mesh
        self.meshHost = meshHost
        self.photoToken = photoToken
        // Per-HOST root, not a process-wide constant — see `ProximityHost.proximitySupportDirectory`
        // for why the wall's index cannot be shared across concurrently-live managers.
        let cacheURL = meshHost.host.proximitySupportDirectory
            .appendingPathComponent("MeshPhotoCache.json")
        // Phase-5 media-key split: the wall stays on the ORIGINAL, backup-restorable row
        // (`Role.friendWall`) — stated explicitly rather than left to the default so a future
        // reader can see which side of the split this store is on. Nothing about the wall changed:
        // no re-encryption, no dual-open fallback, and delete-all still keeps both the photos and
        // the key. The user's OWN photos moved to `Role.ownPhotos` in `FernletStore`.
        self.photoCacheStore = PrivateMediaStore(
            indexURL: cacheURL,
            keyProvider: KeychainPrivateMediaKeyProvider(role: .friendWall)
        )
        // Per-host like the wall, and a SUBDIRECTORY of the same root: each corpus sweeps orphans
        // by directory, so siblings would sweep each other.
        self.heldPhotoStore = PendingSessionPhotoStore(
            directory: meshHost.host.proximitySupportDirectory
                .appendingPathComponent(PendingSessionPhotoStore.directoryName, isDirectory: true),
            keyProvider: heldPhotoKeys ?? KeychainPrivateMediaKeyProvider(role: .pendingSessionPhotos)
        )
        let preferencesURL = cacheURL.deletingLastPathComponent().appendingPathComponent("MeshPhotoWallPreferences.json")
        let preferencesStore = JSONSidecarFile<FriendPhotoWallPreferences>(fileURL: preferencesURL)
        self.photoWallPreferencesStore = preferencesStore
        self.photoWallPreferences = preferencesStore.load() ?? FriendPhotoWallPreferences()
        loadPhotoCorpora(now: Date())
    }

    /// The display name a photo is sent under, resolved from the host at each read.
    private var displayName: String { meshHost.host.resolvedProximityDisplayName }

    /// `base` with the mesh this device holds as its `held` key, when it holds one: the mesh's own
    /// audit door (its private `heldMeshAuditContext(_:)`), restated over its public
    /// ``MeshNetworkManager/currentMesh`` for the two lines this object writes that carried it there —
    /// `mesh.routedShare.skipped` and `mesh.routedProjection.photoAlreadyAnswered` — so each keeps its
    /// context, key for key.
    ///
    /// - Parameter base: The line's own context, empty for the line that had none.
    /// - Returns: `base` with `held` added, when this device holds a mesh.
    private func heldMeshAuditContext(_ base: [String: String] = [:]) -> [String: String] {
        guard let meshID = mesh?.currentMesh?.meshID else { return base }
        var context = base
        context["held"] = meshID.uuidString
        return context
    }

    /// The init's two photo loads: the wall first, then the pending corpus, then the reconcile that
    /// rebuilds the awaiting review from it (a process kill before the answer lands here).
    ///
    /// `loadIndex`, not `load`: a DEFERRED wall read must not look like an empty wall (see
    /// `photoIndexDeferred` — the index is also the store's file manifest). An `.unrecoverable`
    /// index is different: nothing can bring those entries back, so the wall starts empty and
    /// saves proceed, letting the next one replace the dead file and sweep its orphans.
    ///
    /// - Parameter now: The launch instant, for dropping expired tombstones — never for removing a
    ///   held photo, which no timer touches.
    private func loadPhotoCorpora(now: Date) {
        switch photoCacheStore.loadIndex() {
        case .entries(let photos):
            meshPhotos = photos
        case .deferred:
            photoIndexDeferred = true
        case .unrecoverable:
            FernletAuditLog.log("mesh.photoIndex.unrecoverable")
        }
        prunePhotoWallPreferences()
        loadHeldPhotoIndex(now: now)
        reconcileHeldPhotosIfReady(now: now)
    }

    /// Shots remaining for this session (10 minus sent count, clamped to ≥ 0).
    public var filmRemaining: Int { max(0, Self.maxPhotosPerSenderPerSession - photosAddedThisSession) }

    // MARK: - The session's moments (called by the composition's session observer)

    /// A new search began (the mesh's `startJoin()`, before it resets its roster and removal tallies):
    /// the film is reset and its mesh pin dropped, a photo still listed joins the pending review, and only
    /// then is the new photo session's id and start minted — in the manager's order, where the move read
    /// the old ids before they were re-minted.
    func beginNewPhotoSession() {
        photosAddedThisSession = 0
        photosKeptOnThisPhone = 0
        sessionQuotaMeshID = nil
        // A new search is a new session: a photo still listed belongs to one that ended without an
        // answer, so it joins the pending review rather than being dropped (a drop keeps it
        // silently — the wall already holds it). Before the ids below are re-minted.
        movePhotosIntoPendingReview()
        photoSessionStartedAt = Date()
        activePhotoSessionID = UUID()
    }

    /// This device left its session (the mesh's `leaveSession()`, after its teardown and the ending it
    /// ran): the photo session's ids are forgotten — only now, because the ending stamped the ended
    /// session's photos with them.
    func forgetPhotoSession() {
        photoSessionStartedAt = nil
        activePhotoSessionID = nil
    }

    /// The mesh this device's session counts against changed: the film's mesh pin follows it.
    ///
    /// - A founding at the session's first commit pins the new mesh's id, so the capture's
    ///   "the mesh changed" reset does not fire and grant a free extra 27 shots.
    /// - A founding given up drops the pin.
    /// - Leaving the mesh resets the film's two counts and drops the pin.
    ///
    /// - Parameter change: The scope change the mesh reported.
    func noteScopeChange(_ change: MeshScopeChange) {
        switch change {
        case .foundedAtFirstCommit(let meshID):
            // Keep the quota counter across the founding: pin the new meshID so the addPhoto reset
            // guard doesn't fire and grant a free extra 27 shots. (Pre-item-2 this was the
            // pairwise→mesh promotion at the second commit; it is now the first commit's founding, and
            // the guard it protects is the same one.)
            sessionQuotaMeshID = meshID
        case .foundingAbandoned:
            sessionQuotaMeshID = nil
        case .left:
            photosAddedThisSession = 0
            photosKeptOnThisPhone = 0
            sessionQuotaMeshID = nil
        }
    }

    /// A signed removal this device approved took effect: the member it names leaves the keep-as-friend
    /// candidates of any unconsumed promoted batch (the mesh purged its own live roster just before), so
    /// a voted-out peer is never offered.
    ///
    /// - Parameter fingerprint: The removed member's fingerprint.
    func dropRemovedMemberFromReview(fingerprint: String) {
        if var batch = pendingFriendReview {
            batch.entries.removeAll { $0.fingerprint == fingerprint }
            // Never on entries alone: a batch still carrying unanswered photos stays up.
            pendingFriendReview = batch.isEmpty ? nil : batch
        }
    }

    /// The host pushed a changed routed access gate, which the mesh stored and logged: this object's
    /// mirror takes it, a rising ciphertext leg re-reads whichever photo index could not be read
    /// (2026-09-30: a rising leg is also the moment a wall or pending index unreadable at a locked
    /// launch becomes readable, and the mesh's re-entry pass that follows may project a routed photo
    /// into the pending corpus, which must find its real index there), and whether the held photos can
    /// be shown is recomputed — so an edge that owes the routed store nothing still re-reads them.
    ///
    /// - Parameters:
    ///   - gate: The gate as the host now knows it.
    ///   - isRising: Whether a ciphertext leg rose.
    ///   - now: The instant the host pushed it.
    func applyAccessGate(_ gate: MeshRoutedAccessGate, isRising: Bool, now: Date) {
        routedAccessGate = gate
        if isRising { retryDeferredPhotoIndexes(now: now) }
        refreshHeldPhotosCanBeShown()
    }

    // MARK: - The session-end review

    /// Answers the promoted batch's CANDIDATE half iff `id` matches the outstanding one. The UI
    /// calls this once its keep-as-friend flow completes (kept, skipped, dismissed = skip all, or
    /// auto-consumed when nothing was eligible).
    ///
    /// **It never answers the photo half** (2026-09-30). A batch still carrying photos the user has
    /// not chosen between keeps them and stays up — the keep-friends prompt, or the `.none`
    /// auto-consume, must never be what throws a pending photo choice away — and is cleared only
    /// once they are answered too (``finishReviewedPhotos(_:keeping:in:)``). A photo no longer held
    /// (answered elsewhere, or purged) is no longer a choice, so it goes here.
    public func completeFriendReview(_ id: UUID) {
        guard var batch = pendingFriendReview, batch.id == id else { return }
        batch.entries.removeAll()
        batch.photos = reviewablePhotos(of: batch)
        pendingFriendReview = batch.isEmpty ? nil : batch
    }

    /// The pending batch's photos that are still held — exactly what the session-end review can
    /// offer, newest first. Empty when no batch is pending.
    public var pendingReviewPhotos: [FriendPhotoPayload] {
        guard let batch = pendingFriendReview else { return [] }
        return reviewablePhotos(of: batch)
    }

    /// The photos among `ids` that still await the user's keep/discard answer, wherever each one is
    /// listed right now: live in `sessionPhotos`, or moved into the pending batch — and still held
    /// in the pending corpus either way. Live ones first, each list in its own order.
    ///
    /// **What the in-camera Develop review renders** (2026-09-30 fix round, findings C-F1/L-F1). That
    /// review snapshots the ids it offers at Develop and must keep offering them if the session ends
    /// under it: door 3's five-minute give-up raises ``MeshNetworkManager/isSessionLive`` false while the mesh is still
    /// held, so the camera — and its open review — stays on screen while the ending MOVES the live
    /// list into `pendingFriendReview`. Reading `sessionPhotos` alone, the grid went empty and the
    /// person's answer acted on nothing.
    ///
    /// - Parameter ids: The photo ids the review snapshotted.
    /// - Returns: The ones still unanswered, as metadata-only payloads.
    public func photosAwaitingAnswer(among ids: Set<UUID>) -> [FriendPhotoPayload] {
        guard !ids.isEmpty else { return [] }
        let live = stillHeld(sessionPhotos).filter { ids.contains($0.id) }
        let liveIDs = Set(live.map(\.id))
        return live + pendingReviewPhotos.filter { ids.contains($0.id) && !liveIDs.contains($0.id) }
    }

    /// `batch`'s photos filtered to the ones still held.
    private func reviewablePhotos(of batch: MeshFriendReviewBatch) -> [FriendPhotoPayload] {
        stillHeld(batch.photos)
    }

    /// `photos` filtered to the local ids the pending mirror still holds. The two memory lists are
    /// projections of that mirror, so this drops nothing in a consistent state; it is the backstop
    /// that keeps a photo already answered — or purged — from ever being offered again.
    private func stillHeld(_ photos: [FriendPhotoPayload]) -> [FriendPhotoPayload] {
        let held = heldPhotoIndex.heldLocalIDs
        return photos.filter { held.contains($0.id) }
    }

    /// Answers the promoted batch's PHOTO half: of the `reviewed` photos — the ones the session-end
    /// review actually showed — the ones in `kept` are copied to the wall and the rest are deleted
    /// for good, all through ``applyPhotoAnswers(kept:discarded:now:)``. The post-session twin of
    /// ``finishSessionPhotos(keeping:of:)``.
    ///
    /// **Scoped to what was shown, never to the whole batch.** A photo promoted while the sheet was
    /// up — a late arrival, a second ending merged into the same batch — was never offered, so it is
    /// neither discarded nor kept: it stays held and the review re-presents for it. A stale
    /// `batchID` changes nothing and reports ``SessionPhotoAnswer/nothing`` — the conservative side
    /// of an answer that can no longer be matched to its question. The batch clears once neither
    /// half has anything left.
    ///
    /// - Parameters:
    ///   - reviewed: The photo ids the review presented.
    ///   - kept: The ids the user chose to keep; ids outside `reviewed` are ignored.
    ///   - batchID: The batch the review was presented from.
    /// - Returns: What landed, what was deleted, and what is still held — the review stays up while
    ///   ``SessionPhotoAnswer/notApplied`` is not empty, and a camera-roll export may read only
    ///   ``SessionPhotoAnswer/keptOnWall``.
    public func finishReviewedPhotos(
        _ reviewed: Set<UUID>, keeping kept: Set<UUID>, in batchID: UUID
    ) -> SessionPhotoAnswer {
        guard let batch = pendingFriendReview, batch.id == batchID else { return .nothing }
        let answered = Set(stillHeld(batch.photos).map(\.id)).intersection(reviewed)
        let answer = applyPhotoAnswers(
            kept: answered.intersection(kept), discarded: answered.subtracting(kept), now: Date()
        )
        FernletAuditLog.log(
            "mesh.session.photoReviewAnswered",
            context: ["kept": String(answer.keptOnWall.count), "discarded": String(answer.discarded.count),
                      "unreadable": String(answer.unreadable.count), "notApplied": String(answer.notApplied.count),
                      "stillPending": String(pendingFriendReview?.photos.count ?? 0)]
        )
        return answer
    }

    /// Phase 2 ("Session-end review is model-state, not view-events"): when the session has ENDED
    /// (``MeshNetworkManager/isSessionLive``), merge the roster the mesh drained AND move the live
    /// session photos into `pendingFriendReview`, merging into any existing unconsumed batch — neither
    /// candidates nor photos are ever dropped. Idempotent and cheap; the composition's session observer
    /// calls it first at every ending the mesh reports (``MeshSessionObserver/meshSessionDidEnd(_:)``),
    /// which the mesh reports after every slot-removal path (removeSlot, disconnectSlot — which the
    /// checkCoordinatorStates stale eviction funnels through) and on leaveSession/stopSearching
    /// teardown. The mesh ran this promotion itself until plan step A0.5.11; since then it keeps the
    /// roster, drains it into the ending (``MeshSessionEnd/drainedRoster``), and this object merges what
    /// it is handed.
    ///
    /// **The photo half is the 2026-09-30 fix.** The last device left in a mesh ends through a
    /// verified termination (`applyVerifiedTermination()` → `leaveSession()`), with no Develop tap
    /// and so no review of its own; `leaveSession()` used to empty `sessionPhotos` in the same
    /// synchronous turn, so by the time the app's presenter ran it saw no photos and offered at most
    /// the keep-friends prompt — and every photo, then already on the wall since capture, was kept
    /// without asking. Every other ending the user did not choose (a removal, the ceiling, epoch
    /// exhaustion, "Ask to remove" on the only other person, a hard stop) took the same shortcut.
    /// Moving the photos here covers them all at once, because each reaches this funnel — and since
    /// the photos are held in the pending corpus rather than the wall, the move is memory-only.
    ///
    /// The predicate is ``MeshNetworkManager/isSessionLive`` — neither `isInSession` nor
    /// ``MeshNetworkManager/hasCommittedPeer``, and the P6 item 2 fix is where the last of those three
    /// stopped being right. On `isInSession` this ceremony (the product's core loop, and item 6's
    /// tier-2 precondition) would never fire again once a pair founds a mesh at its first commit; on
    /// `hasCommittedPeer` a two-second link blip promoted the batch mid-session and the sheet that
    /// presents it terminates the live mesh. The call sites are unchanged: they are still every
    /// slot-removal path, and slot loss still ends the session when there is no mesh to outlive it.
    ///
    /// - Parameter drainedRoster: The ending's ``MeshSessionEnd/drainedRoster``: every peer the mesh's
    ///   live roster held, which the mesh emptied in the same synchronous step.
    func promoteEndedSessionIntoPendingReview(drainedRoster: [MeshSessionRosterEntry]) {
        promoteRosterIntoPendingReview(drainedRoster)
        movePhotosIntoPendingReview()
    }

    /// The roster half of the promotion: merges the roster the mesh drained into the pending batch by
    /// fingerprint (last write wins, capped at the roster's own bound,
    /// ``MeshNetworkManager/maxSessionRosterEntries``). The mesh emptied its roster as it drained it
    /// (plan step A0.5.11; this half emptied it until then).
    ///
    /// - Parameter drainedRoster: The roster the mesh drained at the ending, in its own order.
    private func promoteRosterIntoPendingReview(_ drainedRoster: [MeshSessionRosterEntry]) {
        guard !drainedRoster.isEmpty else { return }
        if var batch = pendingFriendReview {
            for entry in drainedRoster {
                if let index = batch.entries.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
                    batch.entries[index] = entry   // last-write-wins, matching the roster's dedupe rule
                } else if batch.entries.count < MeshNetworkManager.maxSessionRosterEntries {
                    batch.entries.append(entry)
                }   // R3: an unreviewed batch survives sessions, so the merge honors the roster cap
            }
            pendingFriendReview = batch
        } else {
            pendingFriendReview = MeshFriendReviewBatch(entries: drainedRoster)
        }
    }

    /// The photo half of the promotion: MOVES whatever is still in `sessionPhotos` into the
    /// pending batch, newest first, and empties the live list — never a drop.
    ///
    /// Not gated on ``MeshNetworkManager/isSessionLive`` itself: the ending caller gates it, and a new
    /// search (``beginNewPhotoSession()``) runs it bare, because a new search is a new session by
    /// definition and a photo still listed then belongs to one that ended without an answer. The
    /// ended session's final metadata is stamped first, while its photo-session id is still set —
    /// what the Develop flow's ``finishSessionPhotos(keeping:)`` does before it answers. R3: the
    /// merged list is capped at the pending corpus's own bound, which already bounds every photo that
    /// can be held.
    ///
    /// **It writes nothing** (invariant I6). Both lists are memory projections of the pending index,
    /// which does not record "live" or "awaiting" at all — at a launch every held photo is awaiting
    /// by definition — so an ending that runs while the device is locked (a continued-processing
    /// task, a termination read in the background) cannot fail here and loses nothing. The
    /// finalized session metadata rides only the memory lists; a kept photo carries it to the wall.
    ///
    /// **It can run under an open Develop review.** Door 3's give-up ends the session while the mesh
    /// is held, so the camera and any review it has up stay on screen through this move. That
    /// review renders and answers by the ids it snapshotted (``photosAwaitingAnswer(among:)``,
    /// ``finishSessionPhotos(keeping:of:)``), so the move changes where its photos are held and
    /// nothing about the person's answer (2026-09-30 fix round, findings C-F1/L-F1).
    private func movePhotosIntoPendingReview() {
        guard !sessionPhotos.isEmpty else { return }
        finalizeCurrentPhotoSessionMetadata()
        var batch = pendingFriendReview ?? MeshFriendReviewBatch(entries: [])
        let alreadyPending = Set(batch.photos.map(\.id))
        let arriving = sessionPhotos.filter { !alreadyPending.contains($0.id) }
        batch.photos = Array((arriving + batch.photos).prefix(PendingSessionPhotoStore.maxHeldPhotos))
        pendingFriendReview = batch
        sessionPhotos.removeAll()
        FernletAuditLog.log(
            "mesh.session.photosPendingReview",
            context: ["moved": String(arriving.count), "pending": String(batch.photos.count)]
        )
    }

    // MARK: - The live roll's answers, and the wall

    /// The answer for the whole LIVE roll: every listed photo not in `keptPhotoIDs` is deleted and
    /// the kept ones are copied to the wall, so the teardown that follows has nothing left to
    /// promote. ``finishSessionPhotos(keeping:of:)`` over every listed id. A photo the session ended
    /// without an answer for is answered by the post-session review through
    /// ``finishReviewedPhotos(_:keeping:in:)``.
    ///
    /// - Returns: What the answer did (``SessionPhotoAnswer``).
    public func finishSessionPhotos(keeping keptPhotoIDs: Set<UUID>) -> SessionPhotoAnswer {
        finishSessionPhotos(keeping: keptPhotoIDs, of: Set(sessionPhotos.map(\.id)))
    }

    /// The in-camera Develop review's answer, scoped to the photos it SHOWED (`reviewed`, snapshotted
    /// at Develop) and applied wherever each one is listed now: of those still held, the ones in
    /// `kept` are copied to the wall, the rest are deleted for good, and all of them leave the live
    /// list AND the pending batch (``applyPhotoAnswers(kept:discarded:now:)``).
    ///
    /// **Held anywhere, not just live** (2026-09-30 fix round, findings C-F1/L-F1). Door 3's
    /// five-minute give-up ends the session while the mesh is still held, so the camera and its open
    /// review stay up while the ending moves the live list into `pendingFriendReview`. Answering
    /// only `sessionPhotos` then answered nothing. The ids make the answer independent of where the
    /// photo is listed.
    ///
    /// **First answer wins.** An id already answered — by the post-session review or an earlier
    /// call — is no longer held, so it is ignored rather than answered again. A photo listed after
    /// the snapshot (a late arrival while the sheet was up) was never shown, so it stays listed and
    /// reaches the post-session review at the teardown.
    ///
    /// - Parameters:
    ///   - kept: The ids the user chose to keep; ids outside `reviewed` are ignored.
    ///   - reviewed: The ids the review presented.
    /// - Returns: What the answer did (``SessionPhotoAnswer``); the review stays up while its
    ///   ``SessionPhotoAnswer/notApplied`` is not empty.
    public func finishSessionPhotos(keeping kept: Set<UUID>, of reviewed: Set<UUID>) -> SessionPhotoAnswer {
        finalizeCurrentPhotoSessionMetadata()
        let pendingIDs = Set(stillHeld(pendingFriendReview?.photos ?? []).map(\.id))
        let answered = reviewed.intersection(Set(stillHeld(sessionPhotos).map(\.id)).union(pendingIDs))
        let answer = applyPhotoAnswers(
            kept: answered.intersection(kept), discarded: answered.subtracting(kept), now: Date()
        )
        if !pendingIDs.isDisjoint(with: answered) {
            FernletAuditLog.log(
                "mesh.session.developAnsweredPendingPhotos",
                context: ["answered": String(answered.intersection(pendingIDs).count)]
            )
        }
        return answer
    }

    /// Deletes every photo on the live roll: ``finishSessionPhotos(keeping:)`` with nothing kept.
    ///
    /// - Returns: What the answer did (``SessionPhotoAnswer``).
    public func deleteAllSessionPhotos() -> SessionPhotoAnswer {
        finishSessionPhotos(keeping: [])
    }

    /// Permanently removes one KEPT photo from the wall: drops it from `meshPhotos`, clears any wall
    /// preference that pointed at it (favorite / aggregated cover), re-saves the index so the
    /// store's orphan sweep deletes its image and thumbnail files, and tombstones its identity
    /// (sender fingerprint + id) for 24 hours so a routed copy still in custody cannot come back.
    ///
    /// **A held photo is refused** (2026-09-30): held photos leave only through an answer. A delete
    /// that dropped one from the memory batch while the pending index kept it would bring it back at
    /// the next launch — an answer that did not persist, which is worse than no answer at all.
    public func deletePhoto(_ photoID: UUID) {
        guard heldPhotoIndex.heldPhoto(localID: photoID) == nil else {
            FernletAuditLog.log("mesh.heldPhotos.deleteRefused")
            return
        }
        let removed = meshPhotos.first { $0.id == photoID }
        meshPhotos.removeAll { $0.id == photoID }
        // Drops the favorite / aggregated-cover entries that pointed at the photo (and any other
        // entry the cache no longer backs).
        prunePhotoWallPreferences()
        guard let removed else { return }
        persistPhotoIndex(meshPhotos)
        tombstoneDeletedWallPhoto(removed)
    }

    /// The tombstone half of ``deletePhoto(_:)``: a wall photo from an older build, deleted inside a
    /// routed window after the upgrade, must not be re-projected as a NEW held photo. Skipped while
    /// the pending index cannot be read (nothing writes it then) and for a photo with no sender.
    private func tombstoneDeletedWallPhoto(_ photo: FriendPhotoPayload) {
        guard let sender = photo.senderFingerprint, heldPhotoIndexDeferral == nil else { return }
        commitHeldPhotoAnswers([HeldPhotoKey(origin: sender, itemID: photo.id)], now: Date())
    }

    /// The one seam every wall save goes through, so the deferred-index rule is enforced in a
    /// single place.
    ///
    /// While `photoIndexDeferred` holds, `meshPhotos` is empty because the index could not be READ
    /// — and ``PrivateMediaStore/save(_:)`` is a full-index rewrite that deletes every photo file
    /// the set omits, so writing it would destroy the wall this funnel deliberately keeps. Re-read
    /// first: only a successful read clears the flag, and it brings the disk entries back into
    /// `meshPhotos` (this session's arrivals win by id — they carry the bytes still to be written).
    /// Nothing was deletable while the flag was set, so nothing can be resurrected by that merge.
    /// The unlock/foreground edge re-reads it too (``retryDeferredPhotoIndexes(now:)``), so a wall
    /// deferred at launch recovers without waiting for a save — which, since the wall stopped
    /// receiving captures (2026-09-30), might otherwise never come.
    private func persistPhotoIndex(_ photos: [FriendPhotoPayload]) {
        guard photoIndexDeferred else {
            photoCacheStore.save(photos)
            return
        }
        guard case .entries(let recovered) = photoCacheStore.loadIndex() else {
            FernletAuditLog.log("mesh.photoIndex.saveSkippedWhileDeferred")
            return
        }
        photoIndexDeferred = false
        let merged = Self.mergedPhotoIndex(session: photos, recovered: recovered)
        meshPhotos = merged.map { $0.withoutImageData() }
        photoCacheStore.save(merged)
    }

    /// Union of this session's index and the copy just recovered from disk: newest first, capped
    /// like the store, session entries winning by id so a payload still carrying its bytes is not
    /// replaced by the byte-less recovered row.
    private static func mergedPhotoIndex(
        session: [FriendPhotoPayload],
        recovered: [FriendPhotoPayload]
    ) -> [FriendPhotoPayload] {
        let sessionIDs = Set(session.map(\.id))
        let merged = session + recovered.filter { !sessionIDs.contains($0.id) }
        return Array(merged.sorted { $0.addedAt > $1.addedAt }.prefix(PrivateMediaStore.maxCachedPhotos))
    }

    /// Drops wall-preference entries whose session or photo no longer exists in `meshPhotos`
    /// (FIFO eviction past the 1000-photo cap, session discard, single-photo delete, or a favorite
    /// on a photo that was never kept). The sidecar is install-lifetime and survives delete-all
    /// (the wall is deliberately kept), so without this it accumulated one `aggregatedSessionIDs`
    /// + cover entry per aggregated session forever while the photos themselves rolled off (R3).
    /// Three filters over finite collections; persists only when something actually changed. Never
    /// called from `photoWallPosts` — that getter must stay mutation-free.
    private func prunePhotoWallPreferences() {
        // A deferred index means `meshPhotos` is empty because nothing could be READ, not because
        // the wall is empty; pruning against it would drop the favorite and cover of every photo
        // still on disk. Same fail-closed rule as `persistPhotoIndex`.
        guard !photoIndexDeferred else { return }
        let liveSessionIDs = Set(meshPhotos.compactMap { $0.session?.id })
        let livePhotoIDs = Set(meshPhotos.map(\.id))
        var pruned = photoWallPreferences
        pruned.aggregatedSessionIDs = pruned.aggregatedSessionIDs.filter { liveSessionIDs.contains($0) }
        pruned.coverPhotoIDsBySession = pruned.coverPhotoIDsBySession
            .filter { liveSessionIDs.contains($0.key) && livePhotoIDs.contains($0.value) }
        pruned.favoritePhotoIDsBySession = pruned.favoritePhotoIDsBySession
            .filter { liveSessionIDs.contains($0.key) && livePhotoIDs.contains($0.value) }
        guard pruned != photoWallPreferences else { return }
        photoWallPreferences = pruned
        persistPhotoWallPreferences()
    }

    // MARK: - Held session photos (2026-09-30)

    /// Holds one session photo in the sealed pending corpus — the ONLY way a session photo enters
    /// this device, for BOTH producers (``addPhoto(_:)`` and the routed projection). It never
    /// touches `meshPhotos`: nothing reaches the wall before the person's answer.
    ///
    /// Refused, by identity (origin + item id, never the id alone): a tombstoned key is
    /// ``PendingSessionPhotoStore/Hold/answered`` (it was answered and must not come back), and a
    /// key already held, or a wall photo with the same sender and id, is
    /// ``PendingSessionPhotoStore/Hold/alreadyHeld``. Also refused, as `notPersisted`, while a
    /// duress session is in force and while the pending index cannot be read — a write over an
    /// unread index would replace every photo it holds.
    ///
    /// The local id is the item id unless another held photo or a wall photo already uses it (a
    /// member reusing someone else's id), in which case a fresh one is minted so neither overwrites
    /// the other's files. A live photo is stamped with the current session's metadata and listed
    /// in `sessionPhotos`; an awaiting one keeps its own and joins the pending batch (a photos-only
    /// batch is created if none exists), which re-triggers the review.
    ///
    /// - Parameters:
    ///   - photo: The photo, carrying its plaintext bytes.
    ///   - key: Who minted it and the id they chose: this device's own fingerprint for a capture,
    ///     the signed manifest's origin and item id for a routed photo.
    ///   - live: Whether it belongs to the session that is live right now.
    /// - Returns: The store's outcome; only ``PendingSessionPhotoStore/Hold/held`` changed anything.
    func holdSessionPhoto(
        _ photo: FriendPhotoPayload, key: MeshContentKey, live: Bool
    ) -> PendingSessionPhotoStore.Hold {
        let now = Date()
        retryDeferredPhotoIndexes(now: now)
        guard !routedAccessGate.duressActive, heldPhotoIndexDeferral == nil else {
            FernletAuditLog.log(
                "mesh.heldPhotos.holdRefused",
                context: ["reason": routedAccessGate.duressActive ? "duress" : "pendingIndexDeferred"]
            )
            return .notPersisted
        }
        let heldKey = HeldPhotoKey(origin: key.senderFingerprint, itemID: key.contentID)
        if let settled = heldPhotoSettlement(heldKey) { return settled }
        guard let imageData = photo.imageData else { return .notPersisted }
        let stamped = live ? photo.withSession(currentPhotoSessionMetadata()) : photo
        let local = withHeldLocalID(stamped, imageData: imageData)
        let entry = HeldSessionPhoto(key: heldKey, heldAt: now, payload: local)
        let (outcome, next) = heldPhotoStore.hold(entry, imageData: imageData, into: heldPhotoIndex)
        guard outcome == .held else {
            FernletAuditLog.log("mesh.heldPhotos.holdRefused", context: ["reason": Self.holdToken(outcome)])
            return outcome
        }
        heldPhotoIndex = next
        listHeldPhoto(local.withoutImageData(), live: live)
        return .held
    }

    /// A frozen English audit token for a hold outcome — never copy, never localized.
    private static func holdToken(_ outcome: PendingSessionPhotoStore.Hold) -> String {
        switch outcome {
        case .held: return "held"
        case .alreadyHeld: return "alreadyHeld"
        case .answered: return "answered"
        case .full: return "full"
        case .unsafeImage: return "unsafeImage"
        case .notPersisted: return "notPersisted"
        }
    }

    /// Whether this identity is already settled — answered (tombstoned), held, or on the wall with
    /// the same sender and id — or nil when it may be held. Read from the mirror and the wall only;
    /// nothing is decrypted to answer it, which is what lets the routed projection ask it before
    /// the body is opened.
    private func heldPhotoSettlement(_ key: HeldPhotoKey) -> PendingSessionPhotoStore.Hold? {
        if heldPhotoIndex.isAnswered(key) { return .answered }
        if heldPhotoIndex.holds(key) || wallHolds(key) { return .alreadyHeld }
        return nil
    }

    /// Whether the wall holds a photo with this identity: the same sender fingerprint and id.
    private func wallHolds(_ key: HeldPhotoKey) -> Bool {
        meshPhotos.contains { $0.id == key.itemID && $0.senderFingerprint == key.origin }
    }

    /// `photo` under the local id it will be held by: its own id, or a fresh one when another held
    /// photo or a wall photo already uses that id (audited — only a routed photo whose origin reused
    /// someone else's item id can collide; an own capture's id is minted here).
    private func withHeldLocalID(_ photo: FriendPhotoPayload, imageData: Data) -> FriendPhotoPayload {
        let taken = heldPhotoIndex.heldLocalIDs.contains(photo.id) || meshPhotos.contains { $0.id == photo.id }
        guard taken else { return photo }
        FernletAuditLog.log("mesh.heldPhotos.idCollision")
        return FriendPhotoPayload(
            id: UUID(),
            imageData: imageData,
            addedAt: photo.addedAt,
            senderName: photo.senderName,
            senderFingerprint: photo.senderFingerprint,
            senderSigningPublicKey: photo.senderSigningPublicKey,
            session: photo.session
        )
    }

    /// Lists a just-held photo in its memory projection: the live roll, or the awaiting batch.
    private func listHeldPhoto(_ metadata: FriendPhotoPayload, live: Bool) {
        if live {
            // R3: every listed photo is held, and the corpus refuses a hold past the same bound.
            sessionPhotos.insert(metadata, at: 0)
            sessionPhotos = Array(sessionPhotos.prefix(Self.maxSessionPhotos))
            return
        }
        var batch = pendingFriendReview ?? MeshFriendReviewBatch(entries: [])
        batch.photos.insert(metadata, at: 0)
        batch.photos = Array(batch.photos.prefix(PendingSessionPhotoStore.maxHeldPhotos))
        pendingFriendReview = batch
        FernletAuditLog.log("mesh.heldPhotos.heldAwaiting", context: ["pending": String(batch.photos.count)])
    }

    /// Re-reads whichever photo index could not be read before — the wall's, the pending corpus's,
    /// or both — and then runs the reconcile if both are now readable.
    ///
    /// Callers: a rising ciphertext leg of the routed access gate, as the mesh reports it
    /// (``applyAccessGate(_:isRising:now:)``: the unlock or foreground that makes the
    /// `.completeFileProtection` files readable again), and the top of every hold and answer.
    /// Nothing re-read the wall before this existed: a wall deferred at a locked background launch
    /// was an empty album for the rest of the process.
    ///
    /// - Parameter now: The instant for the pending load's tombstone pruning.
    private func retryDeferredPhotoIndexes(now: Date) {
        guard photoIndexDeferred || heldPhotoIndexDeferral != nil else { return }
        if photoIndexDeferred { retryDeferredWallIndex() }
        if heldPhotoIndexDeferral != nil { loadHeldPhotoIndex(now: now) }
        reconcileHeldPhotosIfReady(now: now)
    }

    /// The wall half of ``retryDeferredPhotoIndexes(now:)``: one re-read, merged exactly as
    /// `persistPhotoIndex` merges. While the wall was deferred nothing could be added to
    /// `meshPhotos` (a keep is refused then, and a hold never touches it), so the merge is the
    /// recovered index; it is written back only if that ever stops being true.
    private func retryDeferredWallIndex() {
        guard case .entries(let recovered) = photoCacheStore.loadIndex() else { return }
        photoIndexDeferred = false
        let unsaved = meshPhotos
        let merged = Self.mergedPhotoIndex(session: unsaved, recovered: recovered)
        meshPhotos = merged.map { $0.withoutImageData() }
        if !unsaved.isEmpty { photoCacheStore.save(merged) }
        prunePhotoWallPreferences()
        FernletAuditLog.log("mesh.photoIndex.recoveredAfterDeferral", context: ["photos": String(meshPhotos.count)])
    }

    /// Loads the pending index into the mirror, or records why it cannot be read.
    ///
    /// An `.unrecoverable` index (a present key that fails to open it: corruption, or a duress
    /// crypto-erase) has already been purged by the store; the mirror starts empty and holds may
    /// proceed.
    private func loadHeldPhotoIndex(now: Date) {
        switch heldPhotoStore.load(now: now) {
        case .loaded(let index):
            heldPhotoIndex = index
            heldPhotoIndexDeferral = nil
        case .deferred(let deferral):
            heldPhotoIndexDeferral = deferral
        case .unrecoverable(let purged):
            FernletAuditLog.log("mesh.heldPhotos.indexUnrecoverable", context: ["purged": String(purged)])
            heldPhotoIndex = .empty
            heldPhotoIndexDeferral = nil
        }
        refreshHeldPhotosCanBeShown()
    }

    /// The launch reconcile, once BOTH indexes are readable: a held entry whose local id is on the
    /// wall, whose key names a wall photo (same sender, same id), or that is tombstoned was already
    /// answered — the kill landed between an answer's wall commit and its pending write — so it is
    /// dropped and tombstoned, never offered. Everything else still held is offered as awaiting.
    ///
    /// Over a wall that could not be read it would re-offer a kept photo, and a discard of it would
    /// then leave the wall copy — so it does not run until the wall is readable. While the wall is
    /// deferred at a LOCKED launch nothing held is offered; once protected data is available and the
    /// wall still cannot be read, the failure is persistent and waiting would deadlock the review,
    /// so ``offerHeldPhotosOverUnreadableWallIfPersistent()`` offers them with Keep refused.
    ///
    /// - Parameter now: The instant the tombstones are stamped with.
    private func reconcileHeldPhotosIfReady(now: Date) {
        defer { refreshHeldPhotosCanBeShown() }
        guard !heldPhotosReconciled, heldPhotoIndexDeferral == nil else { return }
        guard !photoIndexDeferred else {
            offerHeldPhotosOverUnreadableWallIfPersistent()
            return
        }
        let wallIDs = Set(meshPhotos.map(\.id))
        let stale = heldPhotoIndex.photos.filter {
            wallIDs.contains($0.localID) || wallHolds($0.key) || heldPhotoIndex.isAnswered($0.key)
        }
        if !stale.isEmpty {
            FernletAuditLog.log("mesh.heldPhotos.reconciled", context: ["dropped": String(stale.count)])
            commitHeldPhotoAnswers(Set(stale.map(\.key)), now: now)
            // Already offered over an unreadable wall: take the ones that turned out to be kept back
            // out of the review.
            forgetAnsweredHeldPhotos(Set(stale.map(\.localID)))
        }
        heldPhotosReconciled = true
        offerHeldPhotosAwaitingAnswer()
    }

    /// The persistent-failure half of the reconcile's precondition: with protected data available
    /// (the device is unlocked, so the `.completeFileProtection` file SHOULD read) the wall still
    /// cannot be read, so the held photos are offered now — Keep refused with its reason, Delete
    /// all working — rather than never. See ``heldPhotosOfferedOverUnreadableWall`` for the cost.
    private func offerHeldPhotosOverUnreadableWallIfPersistent() {
        guard routedAccessGate.protectedDataAvailable, !heldPhotosOfferedOverUnreadableWall else { return }
        FernletAuditLog.log("mesh.heldPhotos.offeredOverUnreadableWall")
        heldPhotosOfferedOverUnreadableWall = true
        offerHeldPhotosAwaitingAnswer()
    }

    /// Lists every held photo not already listed as awaiting, in a photos-only batch if none exists:
    /// the rebuild that makes the review survive a process kill. Newest first, as the index keeps
    /// them. At a launch nothing is listed yet and no session is live, so every held photo lands
    /// here.
    private func offerHeldPhotosAwaitingAnswer() {
        var listed = Set(sessionPhotos.map(\.id))
        listed.formUnion(pendingFriendReview?.photos.map(\.id) ?? [])
        let unlisted = heldPhotoIndex.photos.filter { !listed.contains($0.localID) }.map(\.payload)
        guard !unlisted.isEmpty else { return }
        var batch = pendingFriendReview ?? MeshFriendReviewBatch(entries: [])
        batch.photos = Array((unlisted + batch.photos).prefix(PendingSessionPhotoStore.maxHeldPhotos))
        pendingFriendReview = batch
        FernletAuditLog.log("mesh.heldPhotos.offeredFromIndex", context: ["photos": String(unlisted.count)])
    }

    /// Recomputes ``heldPhotosCanBeShown`` from its three inputs, writing only on a change so an
    /// unchanged push does not wake every observer.
    private func refreshHeldPhotosCanBeShown() {
        let offered = heldPhotosReconciled || heldPhotosOfferedOverUnreadableWall
        let next = routedAccessGate.isOpen && heldPhotoIndexDeferral == nil && offered
        if next != heldPhotosCanBeShown { heldPhotosCanBeShown = next }
    }

    /// Whether the wall's index is readable, so a review may offer Keep. A review presented while it
    /// is not says why and still offers Delete all, which needs only the pending index.
    public var wallCanTakeKeeps: Bool { !photoIndexDeferred }

    /// Whether ended-session photos are waiting for the person's answer.
    public var hasOutstandingPhotoReview: Bool {
        !(pendingFriendReview?.photos.isEmpty ?? true)
    }

    /// A held photo's full-size plaintext for the review, or nil. **The decrypt seam for pending
    /// bytes** (invariant I13): it answers only while the routed access gate is open — unlocked,
    /// foreground, and NOT under duress — so a duress decoy can never draw a held photo. The wall's
    /// ``imageData(for:)`` never reads the pending corpus, and this never reads the wall.
    public func reviewImageData(for photo: FriendPhotoPayload) -> Data? {
        guard routedAccessGate.isOpen, let held = heldPhotoIndex.heldPhoto(localID: photo.id) else { return nil }
        return heldPhotoStore.imageData(for: held)
    }

    /// A held photo's thumbnail plaintext for the review's tiles, or nil — under the same gate as
    /// ``reviewImageData(for:)``.
    public func reviewThumbnailData(for photo: FriendPhotoPayload) -> Data? {
        guard routedAccessGate.isOpen, let held = heldPhotoIndex.heldPhoto(localID: photo.id) else { return nil }
        return heldPhotoStore.thumbnailData(for: held)
    }

    /// Delete-all's leg for the photos nobody chose yet (wipe leg 4d): empties the live roll, the
    /// mesh's live roster (``MeshNetworkManager/clearSessionRoster()``, in the same synchronous step,
    /// where the manager emptied its own) and the WHOLE pending batch — candidates too, because a
    /// keep-as-friend offer from a session the person just asked to erase would write new trust rows
    /// about it — and the mirror (tombstones included: after delete-all the routed store is wiped and
    /// the identity rotated, so nothing can be re-projected), then removes the `PendingSessionPhotos/`
    /// directory.
    ///
    /// Clearing the live roster here means a hard-stop leave that runs after the purge promotes
    /// nothing. The key row survives (an emptied store's key protects nothing), exactly like the
    /// own-photo row.
    ///
    /// - Returns: Whether the corpus directory is gone; false is an incomplete-wipe line.
    public func purgeHeldSessionPhotosForDeleteAll() -> Bool {
        sessionPhotos = []
        mesh?.clearSessionRoster()
        pendingFriendReview = nil
        heldPhotoIndex = .empty
        let purged = heldPhotoStore.purgeAll()
        if purged { heldPhotoIndexDeferral = nil }
        refreshHeldPhotosCanBeShown()
        FernletAuditLog.log("mesh.heldPhotos.purgedForDeleteAll", context: ["purged": String(purged)])
        return purged
    }

    // MARK: - The held-photo answer (2026-09-30)

    /// The one engine every session-photo answer runs through (ids are LOCAL ids).
    ///
    /// Order, and why:
    /// 1. The routed access gate must be open — a keep reads plaintext, and no answer may run under
    ///    duress or in the background. Otherwise nothing is applied (`unavailable`).
    /// 2. The deferred indexes are re-read. A pending index still unreadable applies nothing; a wall
    ///    still unreadable refuses the keeps (`keepUnavailable`) while the DISCARDS proceed.
    /// 3. Kept photos are hydrated from the pending corpus and committed to the wall with
    ///    `PrivateMediaStore.commitKept(_:onto:)`, which reports exactly which ones landed; the
    ///    wall mirror is REPLACED with the committed wall. A kept photo whose bytes are gone for
    ///    good (missing, or not opening under a present key) is `unreadable` and treated as
    ///    discarded; one whose bytes cannot be read RIGHT NOW (no key, a file read that failed)
    ///    stays held (`unavailable`), as does one the wall did not take (`wallWriteFailed`) —
    ///    nothing of theirs is swept.
    /// 4. ONE pending index write removes and tombstones every answered photo — only after the wall
    ///    commit, so a kill in between leaves a photo both kept and held, which the launch
    ///    reconcile repairs; never the reverse.
    /// 5. The memory lists and the wall preferences follow.
    ///
    /// - Parameters:
    ///   - kept: The ids to keep.
    ///   - discarded: The ids to delete (an id in both is kept).
    ///   - now: The instant the tombstones are stamped with.
    /// - Returns: The per-photo report. Ids not held are in no set.
    func applyPhotoAnswers(kept: Set<UUID>, discarded: Set<UUID>, now: Date) -> SessionPhotoAnswer {
        let asked = kept.union(discarded)
        guard !asked.isEmpty else { return .nothing }
        guard routedAccessGate.isOpen else {
            FernletAuditLog.log("mesh.heldPhotos.answerRefused", context: ["reason": "gateClosed"])
            return Self.answerNotApplied(asked.intersection(heldPhotoIndex.heldLocalIDs))
        }
        retryDeferredPhotoIndexes(now: now)
        guard heldPhotoIndexDeferral == nil else {
            FernletAuditLog.log("mesh.heldPhotos.answerRefused", context: ["reason": "pendingIndexDeferred"])
            return Self.answerNotApplied(asked.intersection(heldPhotoIndex.heldLocalIDs))
        }
        let heldKept = heldPhotoIndex.photos.filter { kept.contains($0.localID) }
        let heldDiscarded = heldPhotoIndex.photos.filter {
            discarded.contains($0.localID) && !kept.contains($0.localID)
        }
        let keep = keepHeldPhotosOnWall(heldKept)
        let answered = keep.landed + keep.unreadable + heldDiscarded
        commitHeldPhotoAnswers(Set(answered.map(\.key)), now: now)
        forgetAnsweredHeldPhotos(Set(answered.map(\.localID)))
        if keep.wallChanged { prunePhotoWallPreferences() }
        return SessionPhotoAnswer(
            keptOnWall: Set(keep.landed.map(\.localID)),
            discarded: Set(heldDiscarded.map(\.localID)),
            unreadable: Set(keep.unreadable.map(\.localID)),
            notApplied: Set(keep.notLanded.map(\.localID)),
            failure: keep.failure
        )
    }

    /// An answer that applied nothing: every held id it named is still held, for the stated reason.
    private static func answerNotApplied(_ held: Set<UUID>) -> SessionPhotoAnswer {
        SessionPhotoAnswer(keptOnWall: [], discarded: [], unreadable: [], notApplied: held, failure: .unavailable)
    }

    /// What step 3 of ``applyPhotoAnswers(kept:discarded:now:)`` did with the kept photos.
    ///
    /// Concurrency: a plain value, built and read on the photo object's actor (the main actor).
    private struct HeldKeepOutcome {
        /// On the wall: their sealed bytes landed and the committed index names them.
        var landed: [HeldSessionPhoto] = []
        /// Their held bytes could not be opened; answered like a discard.
        var unreadable: [HeldSessionPhoto] = []
        /// Still held, untouched: the wall could not take them, or cannot be read at all.
        var notLanded: [HeldSessionPhoto] = []
        /// Why ``notLanded`` is not empty.
        var failure: SessionPhotoAnswerFailure?
        /// Whether the wall index was rewritten (its preferences are then re-pruned).
        var wallChanged = false
    }

    /// Step 3: copies the kept photos to the wall through the per-photo keep commit, re-sealing
    /// them under the wall key (no file ever moves between corpora). Each carries the finalized
    /// session metadata its memory list holds, falling back to what was stamped at hold.
    ///
    /// A ticked photo is removed as `unreadable` ONLY when its held bytes are gone for good (the
    /// file is missing, or they do not open under a present key). A read that may succeed later —
    /// no key right now, or a file that exists and could not be read — leaves it held and the answer
    /// `unavailable` (fix round 1, U2-C-U2-R1 / U2-L-U2-R3): "a photo the person ticked is never
    /// lost" (§0 item 2, I22).
    private func keepHeldPhotosOnWall(_ held: [HeldSessionPhoto]) -> HeldKeepOutcome {
        guard !held.isEmpty else { return HeldKeepOutcome() }
        guard !photoIndexDeferred else {
            FernletAuditLog.log("mesh.heldPhotos.keepRefused", context: ["reason": "wallDeferred"])
            return HeldKeepOutcome(notLanded: held, failure: .keepUnavailable)
        }
        let read = readHeldPhotosForKeep(held)
        let result = photoCacheStore.commitKept(read.hydrated, onto: meshPhotos)
        if result.indexCommitted { meshPhotos = result.committedWall }
        let unreadableIDs = Set(read.gone.map(\.localID))
        let landed = held.filter { result.keptOnWall.contains($0.localID) }
        let notLanded = held.filter { !result.keptOnWall.contains($0.localID) && !unreadableIDs.contains($0.localID) }
        if !read.gone.isEmpty {
            FernletAuditLog.log("mesh.heldPhotos.unreadableAtKeep", context: ["count": String(read.gone.count)])
        }
        if !notLanded.isEmpty {
            FernletAuditLog.log("mesh.heldPhotos.keepNotLanded", context: [
                "count": String(notLanded.count), "unavailable": String(read.unavailableCount)
            ])
        }
        return HeldKeepOutcome(
            landed: landed, unreadable: read.gone, notLanded: notLanded,
            failure: Self.keepFailure(notLanded: notLanded.count, unavailable: read.unavailableCount),
            wallChanged: result.indexCommitted
        )
    }

    /// The first half of step 3: each kept photo's held bytes, read with the reason when there are
    /// none. Bounded by the held-photo cap (R2).
    private func readHeldPhotosForKeep(
        _ held: [HeldSessionPhoto]
    ) -> (hydrated: [FriendPhotoPayload], gone: [HeldSessionPhoto], unavailableCount: Int) {
        var hydrated: [FriendPhotoPayload] = []
        var gone: [HeldSessionPhoto] = []
        var unavailableCount = 0
        for photo in held {
            switch heldPhotoStore.readImage(for: photo) {
            case .opened(let data):
                hydrated.append(listedPayload(for: photo).withDecryptedImageData(data))
            case .gone:
                gone.append(photo)
            case .unavailable:
                unavailableCount += 1
            }
        }
        return (hydrated, gone, unavailableCount)
    }

    /// Why a keep left photos held: a read that may succeed later says `unavailable` (retry once the
    /// device can read them); otherwise the wall did not take them.
    private static func keepFailure(notLanded: Int, unavailable: Int) -> SessionPhotoAnswerFailure? {
        guard notLanded > 0 else { return nil }
        return unavailable > 0 ? .unavailable : .wallWriteFailed
    }

    /// The payload a kept photo goes to the wall with: the memory list's copy (it carries the
    /// session metadata finalized at the ending), else the one stamped at hold (after a kill).
    private func listedPayload(for held: HeldSessionPhoto) -> FriendPhotoPayload {
        sessionPhotos.first { $0.id == held.localID }
            ?? pendingFriendReview?.photos.first { $0.id == held.localID }
            ?? held.payload
    }

    /// Step 4: ONE pending index write that removes and tombstones `keys`. A write that fails after
    /// the person answered still takes them out of the mirror (audited): the review stops offering
    /// them and the next write that lands persists the answer; a kill first re-offers a discarded
    /// photo (never keeps it) and the reconcile repairs a kept one.
    private func commitHeldPhotoAnswers(_ keys: Set<HeldPhotoKey>, now: Date) {
        guard !keys.isEmpty else { return }
        let (committed, next) = heldPhotoStore.commitAnswers(keys, in: heldPhotoIndex, now: now)
        guard !committed else {
            heldPhotoIndex = next
            return
        }
        FernletAuditLog.log("mesh.heldPhotos.answerNotPersisted", context: ["count": String(keys.count)])
        heldPhotoIndex = PendingSessionPhotoStore.answering(keys, in: heldPhotoIndex, now: now)
    }

    /// Step 5: answered photos leave both memory projections, and a batch left with nothing clears.
    private func forgetAnsweredHeldPhotos(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        sessionPhotos.removeAll { ids.contains($0.id) }
        guard var batch = pendingFriendReview, batch.photos.contains(where: { ids.contains($0.id) }) else { return }
        batch.photos.removeAll { ids.contains($0.id) }
        pendingFriendReview = batch.isEmpty ? nil : batch
    }

    /// Drops both corpora's cached encryption keys — the wall's (`Role.friendWall`) and the pending
    /// corpus's (`Role.pendingSessionPhotos`) — so a post-wipe write cannot use an orphaned key: the
    /// half of the mesh manager's identity wipe that left with the two stores (plan step A0.5.11). The
    /// app's delete-all funnel calls it immediately after the mesh's `wipeIdentityForDeleteAll()` and
    /// before presence's identity wipe, in the same `do`, so a throwing identity wipe skips it, as it
    /// skipped the manager's two drops, and a throwing presence or recipe-share wipe does not. The key
    /// rows themselves survive, like the wall and the emptied corpus they protect.
    public func invalidateEncryptionKeyCaches() {
        photoCacheStore.invalidateEncryptionKeyCache()
        heldPhotoStore.invalidateEncryptionKeyCache()
    }

    // MARK: - Capture and the routed share

    /// Captures one photo, HOLDS it in the sealed pending corpus, and shares it as a routed item
    /// (P5 item 13).
    ///
    /// **The local copy is held, never put on the wall** (2026-09-30): it waits for the person's
    /// review like every other session photo, live if the session is, awaiting if it is not. The
    /// share is unconditional on the transport side as before — the routed door answers `.skipped`
    /// where there is nobody to send to, `.staged` where the item is minted, and `.refused` only
    /// for a mint that was attempted and failed — but **only a held photo is shared**: if this
    /// phone cannot seal its own copy, it spends no film and sends nothing, and says "Couldn't keep
    /// that photo" (the routed store's rule, "if you cannot seal, you must not acknowledge").
    ///
    /// What replaced what: the group-key seal and the epoch-0 plaintext broadcast are both gone,
    /// with the per-recipient content-key wrap in their place. An open-mesh photo used to travel in
    /// the clear at epoch 0 and is now encrypted per recipient, which is a confidentiality
    /// improvement (D-13.9); and the destination set is the full roster at creation rather than
    /// whichever slots happened to be active, so a temporarily disconnected member is delivered at
    /// reunion instead of never.
    ///
    /// A mesh that is gone (only after the composition that owns it is) takes no photo.
    public func addPhoto(_ data: Data) {
        guard let mesh else { return }
        // Reset counter when the mesh changes between calls.
        if mesh.currentMesh?.meshID != sessionQuotaMeshID {
            sessionQuotaMeshID = mesh.currentMesh?.meshID
            photosAddedThisSession = 0
            photosKeptOnThisPhone = 0
        }
        guard photosAddedThisSession < Self.maxPhotosPerSenderPerSession else {
            mesh.meshError = "You've shared the maximum of \(Self.maxPhotosPerSenderPerSession) photos in this mesh session."
            return
        }
        guard let image = UIImage(data: data),
              let normalized = image.resizedForFriendSharing().jpegData(compressionQuality: 0.82) else { return }
        let itemID = UUID()
        let addedAt = Date()
        let live = mesh.isSessionLive
        let session = currentPhotoSessionMetadata()
        let photo = FriendPhotoPayload(
            id: itemID,
            imageData: normalized,
            addedAt: addedAt,
            senderName: displayName,
            senderFingerprint: mesh.localFingerprint,
            senderSigningPublicKey: mesh.localSigningPublicKey,
            session: session
        )
        let key = MeshContentKey(senderFingerprint: mesh.localFingerprint, contentID: itemID)
        guard holdSessionPhoto(photo, key: key, live: live) == .held else {
            mesh.meshError = FernletSocialCopy.Camera.holdFailed
            return
        }
        photosAddedThisSession += 1
        shareRoutedPhoto(itemID: itemID, addedAt: addedAt, imageData: normalized, session: session)
    }

    /// Frames one captured photo as a routed item body and puts it through the routed sender door.
    ///
    /// The body carries **no identity claim**: who sent it is the manifest's signed
    /// `originFingerprint`, and the signing key is the receiver's own admission ledger. A refusal
    /// reaches the user as a frozen token on the mesh's ``MeshNetworkManager/routedShareRefusal``
    /// (``MeshNetworkManager/noteRoutedShareRefusal(_:error:)``); a skip — nobody to send to —
    /// reaches them as a count on ``photosKeptOnThisPhone``; a staged item says nothing, because
    /// the held copy in the camera's roll is the feedback. The type token is the host's photo row's,
    /// behind the mesh's `isRoutedTypeRegistered(_:)`, so a test's narrowed registry still refuses the
    /// mint.
    private func shareRoutedPhoto(
        itemID: UUID, addedAt: Date, imageData: Data, session: FriendPhotoSessionMetadata
    ) {
        guard let mesh else { return }
        let header = MeshRoutedPhotoHeader(
            id: itemID, addedAt: addedAt, senderName: displayName, session: session
        )
        let body: Data
        do {
            body = try MeshRoutedPhotoBody(header: header, imageData: imageData).encoded()
        } catch {
            mesh.noteRoutedShareRefusal(.sealFailed, error: error)
            return
        }
        let typeToken = photoToken
        guard mesh.isRoutedTypeRegistered(typeToken) else {
            mesh.noteRoutedShareRefusal(.mintFailed, error: nil)
            return
        }
        let outcome = mesh.originateRoutedItem(
            body: body, typeToken: typeToken, itemID: itemID, audience: .fullRoster, now: Date()
        )
        switch outcome {
        case .staged:
            return
        case .skipped(let skip):
            noteRoutedPhotoSkip(skip)
        case .refused(let refusal):
            mesh.noteRoutedShareRefusal(refusal, error: nil)
        }
    }

    /// The skip's one observable half (P8 item 0, device finding (c)): the capture is held on this
    /// device and on no other, and never will be, so it is counted on
    /// ``photosKeptOnThisPhone`` — which the app says as one sentence — and audited once, on the
    /// same terms as a refusal but under its own token, because nothing failed.
    private func noteRoutedPhotoSkip(_ skip: MeshRoutedShareSkip) {
        // Bounded by the session quota: every skip is one of at most `maxPhotosPerSenderPerSession`
        // captures, and the count leaves with the session.
        photosKeptOnThisPhone += 1
        FernletAuditLog.log(
            "mesh.routedShare.skipped",
            context: heldMeshAuditContext(["reason": skip.rawValue, "type": "friendPhoto"])
        )
    }

    // MARK: - Receiving (the photo row's projection)

    /// Whether a routed photo's identity is already settled on this phone, asked before its body is
    /// opened: tombstoned → `refusedForGood` (it was answered — kept, discarded or deleted — and must
    /// never come back; the verdict takes it off the retry list), already held or on the wall →
    /// `handedOn` with nothing written, otherwise nil. The photo row's pre-open verdict, through its
    /// projection adapter (the mesh manager's built-in handler from plan step A0.5.2 until the photos
    /// left it at A0.5.11).
    ///
    /// Keyed on the SIGNED origin and item id the delivery carries (``MeshContentKey``), never the
    /// id alone: a member who copies another member's item id can neither make the genuine photo
    /// look settled nor get it tombstoned.
    private func routedPhotoSettlement(_ delivery: MeshRoutedDelivery) -> MeshRoutedProjectionVerdict? {
        let key = HeldPhotoKey(origin: delivery.originFingerprint, itemID: delivery.itemID)
        switch heldPhotoSettlement(key) {
        case .answered?:
            FernletAuditLog.log("mesh.routedProjection.photoAlreadyAnswered", context: heldMeshAuditContext())
            return .refusedForGood
        case .alreadyHeld?:
            return .handedOn
        default:
            return nil
        }
    }

    /// The canonical-store write for a routed photo: it is HELD for the person's review
    /// (``holdSessionPhoto(_:key:live:)``), never put on the wall (2026-09-30).
    ///
    /// The per-origin quota, the display-field sanitisation and the closeness hook are unchanged;
    /// the attribution comes from the origin's signed fingerprint and the ledger's key for it, and
    /// the closeness hook is called with the **origin** rather than the courier.
    ///
    /// **Live is the SIGNED mesh id's call**: the photo belongs to the live session when a session
    /// is live and the delivery's signed `meshID` is the current mesh — never the optional,
    /// peer-supplied `header.session`, so a session-less photo from the live mesh joins the live roll
    /// (and is stamped with its metadata) instead of disturbing it as an awaiting one. A late arrival
    /// — the session ended, a reunion delivery, another mesh — is held awaiting and re-triggers the
    /// review.
    ///
    /// A hold that cannot be persisted (the corpus is full, or no key) is `refusedForNow`: the item
    /// stays in routed custody and is retried after the review frees room. An unsafe image is
    /// refused for good, as no retry can change it.
    ///
    /// The one call site is the photo row's projection adapter's `projectRoutedItem(_:delivery:)`,
    /// which the engine calls only from its dispatch, behind its canonical-mutation predicate; the
    /// pins in `MeshRoutedLockedDeviceTests` (W2's FernletSocial half) are what make a second, ungated
    /// one a build failure. A mesh that is gone cannot be the engine calling it, so that unreachable
    /// case answers the retryable refusal rather than guess a final one. It reads the delivery the engine built
    /// (plan step A0.5.2) where it read the manifest and the ledger's author, field for field. It
    /// takes **no clock**: the one instant it stores is the origin's signed `addedAt`, and the
    /// hold's own `heldAt` is this phone's clock at the write, read there.
    private func routedCanonicalDispatch(
        _ body: MeshRoutedPhotoBody,
        delivery: MeshRoutedDelivery
    ) -> MeshRoutedProjectionVerdict {
        guard let mesh else { return .refusedForNow }
        guard allowIncomingRoutedPhoto(body.header.id, from: delivery.quotaKey) else {
            return .refusedForGood
        }
        let photo = Self.sanitizedIncomingPhoto(FriendPhotoPayload(
            id: body.header.id,
            imageData: body.imageData,
            addedAt: body.header.addedAt,
            senderName: body.header.senderName,
            senderFingerprint: delivery.author.fingerprint,
            senderSigningPublicKey: delivery.author.signingPublicKey,
            session: body.header.session
        ), in: meshHost.namespace)
        let live = mesh.isSessionLive && delivery.meshID == mesh.currentMesh?.meshID
        let key = MeshContentKey(senderFingerprint: delivery.originFingerprint, contentID: delivery.itemID)
        switch holdSessionPhoto(photo, key: key, live: live) {
        case .held:
            if live { onFriendPhotoSession?(delivery.author.fingerprint) }
            return .handedOn
        case .alreadyHeld:
            return .handedOn
        case .answered, .unsafeImage:
            return .refusedForGood
        case .full, .notPersisted:
            return .refusedForNow
        }
    }

    /// The incoming per-origin photo budget, keyed on the ITEM's mesh (D-13.23) — the routed twin of
    /// the legacy per-sender quota, which keyed on the live one.
    ///
    /// Re-sends of an already-accepted id are free, exactly as the legacy counter allowed, so a
    /// re-projection after a restart cannot cost a slot it already spent.
    ///
    /// Counted against `budget`, the delivery's ``MeshRoutedDelivery/quotaKey`` — the item's signed
    /// `(mesh, origin)` — since plan step A0.5.2, where it built the same key from the manifest.
    private func allowIncomingRoutedPhoto(_ photoID: UUID, from budget: MeshRoutedOriginQuotaKey) -> Bool {
        var accepted = routedOriginPhotoQuota[budget] ?? []
        if accepted.contains(photoID) { return true }
        guard accepted.count < Self.maxPhotosPerSenderPerSession else {
            FernletAuditLog.log("mesh.routedProjection.quotaSpent")
            return false
        }
        guard routedOriginPhotoQuota[budget] != nil
                || routedOriginPhotoQuota.count < MeshRoutedStoreFormat.maxItems else {
            FernletAuditLog.log("mesh.routedProjection.quotaMapFull")
            return false
        }
        accepted.insert(photoID)
        routedOriginPhotoQuota[budget] = accepted                     // R3: bounded map
        return true
    }

    // MARK: - Photo handling

    /// Coerces a peer-supplied photo payload before it is held in the sealed pending corpus (and so
    /// before it can ever reach the persistent wall) (R3/R5): moderated sender name, moderated +
    /// capped session participants, capped mesh name.
    ///
    /// Its one caller is now the photo arm, `routedCanonicalDispatch(_: MeshRoutedPhotoBody,
    /// delivery:)`, which hands it a payload built from an opened routed body — so the encrypted
    /// branch below is unreachable for routed input. It stays: the
    /// `guard let imageData else { return payload }` fallback would
    /// otherwise return an UNSANITIZED payload for a legacy-shaped one, which is the wrong direction
    /// for a function whose whole job is coercion. The names are coerced under `namespace`'s
    /// peer-name policy, the mesh name under its cap.
    private static func sanitizedIncomingPhoto(_ payload: FriendPhotoPayload, in namespace: ProximityNamespace) -> FriendPhotoPayload {
        let nameCap = namespace.installation.peerNames.maxLength
        let session = payload.session.map { metadata in
            FriendPhotoSessionMetadata(
                id: metadata.id,
                meshID: metadata.meshID,
                meshName: metadata.meshName.map {
                    String(ProximityDisplayName.sanitized($0, maxLength: nameCap).prefix(MeshNetworkManager.maxMeshNameLength))
                },
                startedAt: metadata.startedAt,
                participants: metadata.participants.prefix(MeshNetworkManager.maxMeshMembers).map {
                    FriendPhotoSessionParticipant(
                        fingerprint: $0.fingerprint,
                        displayName: ProximityDisplayName.peerDisplayName($0.displayName, in: namespace)
                    )
                }
            )
        }
        let senderName = ProximityDisplayName.peerDisplayName(payload.senderName, in: namespace)
        if let encryptedImageData = payload.encryptedImageData, let nonce = payload.nonce,
           payload.keyEpoch > 0 {
            return FriendPhotoPayload(
                id: payload.id,
                encryptedImageData: encryptedImageData,
                nonce: nonce,
                keyEpoch: payload.keyEpoch,
                addedAt: payload.addedAt,
                senderName: senderName,
                senderFingerprint: payload.senderFingerprint,
                senderSigningPublicKey: payload.senderSigningPublicKey,
                session: session
            )
        }
        guard let imageData = payload.imageData else { return payload }
        return FriendPhotoPayload(
            id: payload.id,
            imageData: imageData,
            addedAt: payload.addedAt,
            senderName: senderName,
            senderFingerprint: payload.senderFingerprint,
            senderSigningPublicKey: payload.senderSigningPublicKey,
            session: session
        )
    }

    public func imageData(for photo: FriendPhotoPayload) -> Data? {
        photoCacheStore.imageData(for: photo)
    }

    public func thumbnailData(for photo: FriendPhotoPayload) -> Data? {
        photoCacheStore.thumbnailData(for: photo)
    }

    public func thumbnailData(forPhotoID photoID: UUID) -> Data? {
        guard let photo = meshPhotos.first(where: { $0.id == photoID }) else { return nil }
        return thumbnailData(for: photo)
    }

    public func hydratedPhotos(_ photos: [FriendPhotoPayload]) -> [FriendPhotoPayload] {
        photos.compactMap { photoCacheStore.hydrated($0) }
    }

    public func favoritePhotoID(for post: FriendPhotoWallPost) -> UUID? {
        _ = favoritesRevision  // observe favorite toggles so the heart re-renders (see favoritesRevision)
        guard let sessionID = post.session?.id else { return nil }
        return photoWallPreferences.favoritePhotoIDsBySession[sessionID]
    }

    /// Every photo the user has hearted (favorited), flattened from the per-session favorite map into one
    /// global id set. Read-only: the home photowall reads this to weight hearted photos higher in its
    /// rotation. Touches `favoritesRevision` so an observing surface re-picks when a favorite toggles, but
    /// NEVER mutates preferences — the `@ObservationIgnored` constraint on `photoWallPreferences` holds.
    public var allFavoritePhotoIDs: Set<UUID> {
        _ = favoritesRevision
        return Set(photoWallPreferences.favoritePhotoIDsBySession.values)
    }

    public func toggleFavorite(photoID: UUID, in post: FriendPhotoWallPost) {
        guard let sessionID = post.session?.id else { return }
        if photoWallPreferences.favoritePhotoIDsBySession[sessionID] == photoID {
            photoWallPreferences.favoritePhotoIDsBySession.removeValue(forKey: sessionID)
        } else {
            photoWallPreferences.favoritePhotoIDsBySession[sessionID] = photoID
        }
        favoritesRevision &+= 1  // notify observers of favoritePhotoID(for:) / photoWallPosts
        persistPhotoWallPreferences()
    }

    public var photoWallPosts: [FriendPhotoWallPost] {
        _ = favoritesRevision  // read-only: re-render the wall cover when a favorite toggles; NEVER bump here
        progressivelyAggregatePhotoSessions()
        return makePhotoWallPosts()
    }

    public var savedPhotoSessions: [FriendPhotoSessionMetadata] {
        Dictionary(grouping: meshPhotos.compactMap(\.session), by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func currentPhotoSessionMetadata() -> FriendPhotoSessionMetadata {
        let sessionID = activePhotoSessionID ?? UUID()
        let startedAt = photoSessionStartedAt ?? Date()
        let previousMetadata = sessionPhotos.first(where: { $0.session?.id == sessionID })?.session
        activePhotoSessionID = sessionID
        photoSessionStartedAt = startedAt
        let participants = (previousMetadata?.participants ?? []) + (mesh?.sessionParticipants ?? []).map {
            FriendPhotoSessionParticipant(fingerprint: $0.fingerprint, displayName: $0.displayName)
        }
        return FriendPhotoSessionMetadata(
            id: sessionID,
            meshID: mesh?.currentMesh?.meshID ?? previousMetadata?.meshID,
            meshName: mesh?.currentMesh?.name ?? previousMetadata?.meshName,
            startedAt: startedAt,
            participants: participants.reduce(into: []) { result, participant in
                if !result.contains(where: { $0.fingerprint == participant.fingerprint }) {
                    result.append(participant)
                }
            }
        )
    }

    private func finalizeCurrentPhotoSessionMetadata() {
        guard activePhotoSessionID != nil, !sessionPhotos.isEmpty else { return }
        let metadata = currentPhotoSessionMetadata()
        meshPhotos = meshPhotos.map { photo in
            photo.session?.id == metadata.id ? photo.withSession(metadata) : photo
        }
        sessionPhotos = sessionPhotos.map { $0.withSession(metadata) }
    }

    private func progressivelyAggregatePhotoSessions() {
        var posts = makePhotoWallPosts()
        var didChange = false
        // R2: both terminators are in the condition — the wall is below the post cap, or there is
        // no unaggregated session left (each iteration aggregates exactly one of a finite set).
        while posts.count >= Self.maxUnaggregatedWallPosts, let candidate = newestUnaggregatedSession() {
            photoWallPreferences.aggregatedSessionIDs.insert(candidate.id)
            if photoWallPreferences.coverPhotoIDsBySession[candidate.id] == nil,
               let coverID = photos(in: candidate.id).randomElement()?.id {
                photoWallPreferences.coverPhotoIDsBySession[candidate.id] = coverID
            }
            didChange = true
            posts = makePhotoWallPosts()
        }
        if didChange {
            persistPhotoWallPreferences()
        }
    }

    private func makePhotoWallPosts() -> [FriendPhotoWallPost] {
        var posts: [FriendPhotoWallPost] = []
        var emittedSessionIDs: Set<UUID> = []
        for photo in meshPhotos.sorted(by: { $0.addedAt > $1.addedAt }) {
            guard let session = photo.session,
                  photoWallPreferences.aggregatedSessionIDs.contains(session.id) else {
                posts.append(FriendPhotoWallPost(id: photo.id, session: photo.session, photos: [photo], coverPhoto: photo))
                continue
            }
            guard emittedSessionIDs.insert(session.id).inserted else { continue }
            let sessionPhotos = photos(in: session.id)
            let coverID = photoWallPreferences.favoritePhotoIDsBySession[session.id]
                ?? photoWallPreferences.coverPhotoIDsBySession[session.id]
            // `sessionPhotos.first` rather than `[0]` (R5: no trapping subscript) — `photo` is the
            // element being iterated and always belongs to this session, so it is a valid cover.
            let coverPhoto = sessionPhotos.first(where: { $0.id == coverID }) ?? sessionPhotos.first ?? photo
            posts.append(FriendPhotoWallPost(id: session.id, session: session, photos: sessionPhotos, coverPhoto: coverPhoto))
        }
        return posts
    }

    private func newestUnaggregatedSession() -> FriendPhotoSessionMetadata? {
        savedPhotoSessions
            .filter { !photoWallPreferences.aggregatedSessionIDs.contains($0.id) }
            .filter { photos(in: $0.id).count > 1 }
            .max { $0.startedAt < $1.startedAt }
    }

    private func photos(in sessionID: UUID) -> [FriendPhotoPayload] {
        meshPhotos
            .filter { $0.session?.id == sessionID }
            .sorted { $0.addedAt < $1.addedAt }
    }

    private func persistPhotoWallPreferences() {
        photoWallPreferencesStore.save(photoWallPreferences)
    }

    /// Total wall-preference entries (aggregated sessions + covers + favorites) — the number the
    /// prune must drive back to zero once the photos they describe have left the cache.
    var photoWallPreferenceEntryCountForTesting: Int {
        photoWallPreferences.aggregatedSessionIDs.count
            + photoWallPreferences.coverPhotoIDsBySession.count
            + photoWallPreferences.favoritePhotoIDsBySession.count
    }

    // MARK: - The photo row's projection handler

    /// The photo row's projection handler, for the composition to register under the host's photo
    /// row's token (plan step A0.5.11, S9). Opaque, so its private type and its engine entry points
    /// stay off this object's API (design rule 6).
    ///
    /// - Returns: A new adapter over these photos.
    func makeProjector() -> some MeshRoutedProjectionHandler {
        PhotoProjector(photos: self)
    }

    /// The photo row's projection handler (plan step A0.5.11, S9; the mesh manager's built-in handler
    /// from plan step A0.5.2 until then): the settlement before the open, then the photo arm, each
    /// called as it is. Private and nested (design rule 6), so the engine's entry points stay off the
    /// photo object's public API, and so it reaches the object's private settlement and arm.
    ///
    /// Holds its photo object strongly: the mesh retains this adapter through its projector map, and
    /// the photo object holds the mesh weakly, so nothing the mesh retains retains the mesh.
    private final class PhotoProjector: MeshRoutedProjectionHandler {

        /// The routed photo body this row decodes to.
        typealias Body = MeshRoutedPhotoBody

        /// The photo object whose settlement and photo arm this calls.
        let photos: MeshSessionPhotos

        /// An adapter over `photos`.
        ///
        /// - Parameter photos: The photo object that makes it.
        init(photos: MeshSessionPhotos) {
            self.photos = photos
        }

        /// Always: the photo row is never gated off the enumeration.
        var isProjectable: Bool { true }

        /// FIRST, before the body is opened and before the quota (invariant I5): a photo this phone
        /// already answered is refused for good by its (origin, item id) tombstone, so a custody copy
        /// still live in the mesh can never become a photo here again; one already held or on the
        /// wall is handed on without a second write.
        ///
        /// - Parameter delivery: The item's signed facts.
        /// - Returns: the settlement's verdict, or nil to open the item.
        func verdictBeforeOpen(_ delivery: MeshRoutedDelivery) -> MeshRoutedProjectionVerdict? {
            photos.routedPhotoSettlement(delivery)
        }

        /// The photo arm: the per-origin quota, the sanitised hold and the closeness hook.
        ///
        /// - Parameters:
        ///   - body: The opened photo body.
        ///   - delivery: The item's signed facts.
        /// - Returns: the arm's verdict.
        func projectRoutedItem(
            _ body: MeshRoutedPhotoBody, delivery: MeshRoutedDelivery
        ) -> MeshRoutedProjectionVerdict {
            photos.routedCanonicalDispatch(body, delivery: delivery)
        }
    }
}

# Mesh session photos: review first, nothing saved until chosen

Design for the 2026-09-30 owner decision, revision 2 (after two adversarial reviews; §9 records
what each finding changed). Read-only survey of `main` at `3c8c9313`; every `file:line` below is
from that tree. Paths are repo-relative.

## 0. The owner's words and what "done" means

The owner, answering "should the review survive a process kill?":

> "Yes; the pop up screen for selecting photos should be the first thing shown. None of the photos
> should be saved to the camera roll until this selection has been made."

Done means all of these hold on a build:

1. Until the person completes the selection, no session photo (taken here or received from a peer)
   is in the system Photos library, and none is on the persisted friend wall or anywhere the wall
   is read (Friends album, carousel, Home photowall). Pending photos are sealed at rest, never in a
   synced blob, never in a device backup, never in the app-switcher snapshot, and visible only
   inside the review.
2. When the selection is made, kept photos go to the wall (and to the camera roll only if the
   person asked for that in the same review); unkept photos are deleted for good and can never be
   re-delivered into the phone from the mesh's custody copy. A photo the person ticked is never
   lost: it counts as kept only once its bytes and the wall index are both on disk.
3. The review is the first thing shown: at the moment a session ends, on whatever tab or sheet the
   person is on, above every other sheet and before the keep-as-friend prompt; and after a kill, at
   the next launch or foreground. One deliberate exception: it waits while First Aid is open (§4.5,
   Q8). Cancelling never keeps or discards anything, and held photos never expire on a timer.
4. The review survives a process kill (photos half; see §4.8 for the friend half and for a kill in
   the middle of a session).
5. Delete-all, the duress wipe/decoy/recovery-lock, app lock, the 13+ age gate, give-up/heal, a
   second session, the continued-processing task and peer-received photos each have a stated,
   tested behaviour (§4.7).

Scope boundary, stated rather than asked: the rule governs what THIS phone keeps. A photo you take
is still shared to the session's members at capture (the disposable-camera model,
`MeshNetworkManager.addPhoto` -> `shareRoutedPhoto`, `MeshNetworkManager.swift:2789`/`2825`); each
friend's phone then applies its own review (on builds carrying this change).

## 1. Today's behaviour, traced

### 1.1 A photo reaches the persisted wall the moment it exists

- Capture: `DisposableCameraView.takePhoto` (`App/Fernlet/DisposableCameraView.swift:1313`) ->
  `MeshNetworkManager.addPhoto` (`MeshNetworkManager.swift:2789`) -> `cachePhoto(_:includeInSession: true)`
  (`:13325`) -> `meshPhotos.insert` + `persistPhotoIndex` (`:2106`) -> `PrivateMediaStore.save`
  (`FernletKit/Sources/PrivateMediaStore/PrivateMediaStore.swift:161`), which seals the bytes into
  `MeshPhotos/` and rewrites `MeshPhotoCache.sealed`. The same payload (metadata only) goes into
  `sessionPhotos` (`:13340`).
- Receipt: the routed projection (`projectRoutedItemIfPermitted` `:8465` -> `routedProjectionVerdict`
  `:8506` -> `dispatchRoutedPlaintext` `:8576` -> `routedCanonicalDispatch(_:author:manifest:)`
  `:8768`) calls the same `cachePhoto`. `includeInSession` is `isPhotoFromCurrentSession` (`:13488`,
  `photoSessionStartedAt != nil && photo.session != nil`), which keys on the peer-supplied optional
  `MeshRoutedPhotoHeader.session` (`MeshRoutedItemBody.swift:153-154`), not on the signed
  `manifest.meshID` (`MeshRoutedManifest.swift:143`). After `leaveSession()` nils
  `photoSessionStartedAt` (`:1666`), a late arrival goes straight to the wall with NO review.
- `addedAt` is the origin's signed claim and is never clamped (`:8776-8784`; `sanitizedIncomingPhoto`
  `:13281` does not touch it).
- Every wall reader therefore sees session photos at once: `photoWallPosts` (`:13388`),
  `savedPhotoSessions` (`:13394`), `thumbnailData(forPhotoID:)` (`:13353`), the Friends album
  (`App/Fernlet/ConnectView.swift:434`, `:888`), the carousel (`ConnectView.swift:1310`), the Home
  photowall seeds (`App/Fernlet/LaunchPreparationService.swift:313`) and tiles
  (`App/Fernlet/HomeView.swift:440`), the cache-warning count (`ConnectView.swift:783`).

### 1.2 The review is a prune, held in memory

- Every ending funnels through `promoteSessionToPendingReviewIfSessionEnded` (`:1561`; call sites
  `:11655` in `stopSearching`, `:11951`, `:11984`), gated on `isSessionLive` (`:1309`), which MOVES
  `sessionPhotos` into `pendingFriendReview.photos` (`movePhotosIntoPendingReview`, `:1601`).
  `startJoin` runs the move bare (`:2344`).
- `MeshFriendReviewBatch` is deliberately not Codable (`FernletKit/Sources/ProximityKit/Mesh/MeshSessionTypes.swift:207-212`):
  a kill before the answer leaves every photo on the wall and the candidates unoffered.
- Answers REMOVE from the wall: `finishReviewedPhotos` (`:1522`), `finishSessionPhotos(keeping:of:)`
  (`:2054`), `deletePhoto` (`:2080`). `reviewablePhotos(of:)` (`:1501`) filters the batch to ids
  "still on the wall". `completeFriendReview` (`:1464`) answers only the candidate half.

### 1.3 Who presents it, and when

- `FriendsView.presentDisconnectReviewIfNeeded` (`ConnectView.swift:992`) presents the photo review
  sheet (`disconnectReviewSheet`, `:312`) or the compact keep-friends prompt, from a deferred check
  (`scheduleReviewCheck`/`runDeferredReviewCheck`, 700 ms) and a landing watchdog. It refuses while
  a session is live (`:993`) and while the root sheet or the camera's own sheets are up
  (`:996-1000`), and it lives on the Friends tab: a review due while the person is on Home, Food or
  Move, or inside a root sheet, waits until they come back to Friends. It is not "the first thing
  shown".
- The keep-friends prompt mints from its own presentation-time snapshot on dismiss
  (`finalizeFriendKeeps`, `:1031-1041`, wired at `:191-192`).
- The Friends tab draws the camera, not the album, while `isInSession` (`ConnectView.swift:130-138`);
  the camera leaving the hierarchy takes its sheets with it (`:236-237`), and the camera already
  resets its "own sheet up" flag in `.onDisappear` for exactly that reason
  (`DisposableCameraView.swift:640-644`).
- The camera's Develop review (`DisposableCameraView.beginDevelop` `:1334`, `reviewSheet` `:1392`) is
  user-initiated during a live session; swipe-down cancels back to the camera
  (`resumeCameraAfterCancelledReview`). A termination tears it down (`:1346-1350`).

### 1.4 When a photo reaches the camera roll today

- The only Photos-library writer is `FriendPhotoLibrarySaver.save`
  (`FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift:297-324`, add-only authorization
  at `:299`, `performChanges` at `:308`).
- Its review callers are the "Also save to Photos" button (`FriendPhotoReviewSheet.swift:180-187`),
  wired to `FriendsView.exportSelectedPhotosToLibrary` (`ConnectView.swift:352-365`) and
  `DisposableCameraView.exportSelectedPhotosToLibrary` (`DisposableCameraView.swift:1430-1444`).
  **The button is enabled while the review is open, before Keep or Delete all** (it is gated only on
  a non-empty selection, `:185`). So today a person can export the ticked photos to the camera roll
  and then tap "Delete all": the camera roll keeps what Fernlet discarded. This is the concrete
  violation of the owner's rule.
- The album carousel's per-photo save (`ConnectView.swift:1371-1395`) acts on wall photos only,
  which after this change means chosen photos only. It stays.

### 1.5 Custody and the resurrection path (pre-existing)

- `routedProjectedItems` is memory-only (`:3428`, cleared by `clearRoutedDrainState` `:5481`); its
  doc says "across a restart the friend-photo wall's own `photo.id` dedup absorbs a re-hand". That
  dedup (`cachePhoto`'s `guard !meshPhotos.contains`, `:13326`) only works while the photo is on
  the wall, and it keys on the id alone.
- The id alone is not an identity: a manifest publishes its item id to the whole roster before
  delivery, and neither `MeshRoutedManifestVerifier` nor `MeshRoutedIndex` refuses a duplicate id
  from a second origin (`MeshContentMerge.swift:18-24`; `MeshContentKey`, `:72`). A member can mint
  an item carrying another member's photo id.
- The routed ciphertext outlives the answer: `MeshRoutedManifest.expiresAt` = `hardDeadline + 20 min`
  (`MeshRoutedManifest.swift:178`; ceiling 6 h, `MeshSessionCeiling.swift:80`). A launch restore of a
  resumable context rebuilds the ledger (`restoreSessionContextAtLaunch` `:10508`), so the origin
  resolves again. Result today: a photo the person deleted from the wall (or discarded in the
  review) can be re-projected onto the wall after a restart inside that window. The design closes
  this with durable answered tombstones keyed by origin and item id (§4.1).

### 1.6 Wipes, locks, gates

- Delete-all keeps the wall by product decision (`App/Fernlet/FernletStore.swift:5560-5566`;
  `Docs/PrivacyWipeCoverage.md:228-231`). Neither private-media key row is deleted
  (`FernletStore.swift:6070-6088`). Delete-all does not touch `pendingFriendReview` today
  (`wipeIdentityForDeleteAll`, `:13960-13963`).
- The duress silent wipe sweeps the whole `com.fernlet.private-media` keychain service
  (`FernletKit/Sources/FernletLock/FernletLockService.swift:1057-1071`, default at `:1111`), then
  runs `deleteAllData` through the set-once purge hook (`App/Fernlet/ContentView.swift:1534`).
- App lock scopes are `privateHub`, `progressPhotos`, `appLockSettings` only
  (`FernletLockService.swift:98-110`). `MeshRoutedAccessGate`'s doc says it outright: "no
  `FernletLockScope` covers Friends and ProximityKit cannot import `FernletLock`"
  (`FernletKit/Sources/ProximityKit/Mesh/MeshRoutedAccessGate.swift:65-68`). The only lock fact the
  mesh sees is `duressActive`; routed plaintext needs `protectedDataAvailable && appIsForeground &&
  !duressActive` (`isOpen`, `:110`).
- The age ruling is a run-policy hard stop for every radio (`App/Fernlet/ProximityRunPolicy.swift:52-55`,
  `:398`); photos themselves are not age-gated (only chat, `isChatAllowed` `:11422`).
- Capture friction (`FernletKit/Sources/FernletUI/CaptureProtection.swift`) covers six Private-tab
  surfaces only. The progress-photo timeline puts its own opaque cover up whenever
  `scenePhase != .active` so the app-switcher snapshot cannot hold body photos
  (`App/Fernlet/ProgressPhotoTimeline.swift:74-75`, `:205-209`). Nothing covers Friends.

### 1.7 Two pre-existing wall read hazards this design depends on fixing

1. `PrivateMediaStore.readIndex` (`PrivateMediaStore.swift:380-393`) reads the sealed index with
   `try? Data(contentsOf:)`. A file that EXISTS but cannot be read (Data Protection: the device is
   locked and the file is `.completeFileProtection`; any I/O error) falls through to the legacy
   branch and returns `.absent` -> `.entries([])`, not `.deferred`. The keychain row is
   `AfterFirstUnlock`, so the key IS available in that state. A manager constructed then (a
   background launch while locked; `meshNetworkManager` is a lazy var, `FernletStore.swift:243`)
   starts with an empty `meshPhotos` and `photoIndexDeferred == false`; the next wall save writes an
   index without the kept wall and the orphan sweep (`PrivateMediaStore.swift:205`, `:500`) deletes
   every kept photo's bytes. `MeshRoutedStore` already treats this case as a deferral
   (`MeshRoutedStore.swift` "fileUnreadable"). (Found by reading, not reproduced on a device.)
2. A deferred wall is re-read only inside a save: `photoIndexDeferred` is set only at init (`:638`)
   and cleared only in `persistPhotoIndex` (`:2106-2119`). Nothing re-reads it on unlock, so the
   album and Home photowall show an empty wall for the rest of the process. Fixing hazard 1 makes a
   deferred wall more common, so this design adds the retry (§4.4).

### 1.8 The wall's save can report success for a photo it did not keep

`PrivateMediaStore.save` (`:161-206`) only audits a failed image write and carries on to write the
index (`:180-193`), skips the bytes on a nil seal or a failed bound check (`:166-178`), and trims to
the 1000 newest by `addedAt` (`cappedNewestFirst`, `:211`), which is peer-signed and unclamped
(§1.1). An index-write result alone therefore cannot say whether a given photo is on the wall.

## 2. Re-evaluating yesterday's shape

Yesterday's recommendation: an optional sealed `reviewPending` flag on `FriendPhotoSessionMetadata`
inside the existing wall index, and a photos-only batch rebuilt at launch. Rejected now:

1. `FriendPhotoSessionMetadata` is a WIRE type: it rides inside every routed photo body
   (`MeshRoutedPhotoHeader.session`, `MeshRoutedItemBody.swift:154`) and is decoded from untrusted
   peer plaintext (`FernletDomainModel/FriendPhotoPayloads.swift:151-177`). A local review flag there
   is a field a peer can set.
2. With pending photos inside the wall index, every wall reader in §1.1 would need a filter. That is
   a view-level `if` repeated at eight sites, the shape the standing rule forbids; one missed reader
   (the Home photowall seed) shows an unchosen photo.
3. The wall index is also the wall's file manifest with a FIFO cap of 1000
   (`PrivateMediaStore.swift:72`, `:161-206`): a pending photo could evict a kept one, or be evicted
   unseen (a silent discard).
4. The wall key is backup-restorable by permanent product decision
   (`PrivateMediaKeyStore.swift:112-135`, pinned by
   `KeyCustodyBoundaryTests.mediaKeyIsTheSanctionedBackupRestorableException`) and the wall files
   ride the device backup. Unchosen photos would travel to a restored phone.
5. Delete-all keeps the wall; pending photos mixed into it could not be purged without a bulk filter
   over the kept wall.

Chosen instead: a separate sealed **pending corpus** that is never the wall, with its own
device-bound key, excluded from backup, holding the photos from the moment they exist until the
answer, plus durable answered tombstones. Its index is the durable truth; the batch is rebuilt
from it at launch.

## 3. Design summary (one screen)

- New sealed store `PendingSessionPhotoStore` (PrivateMediaStore module) under
  `<proximitySupportDirectory>/PendingSessionPhotos/`, excluded from backup, sealed under a new
  device-bound media key role, with three new AEAD purposes. It holds bytes, thumbnails, and an
  index `{ photos, answered }` keyed by origin + item id, with a local id per held photo.
- `MeshNetworkManager` stops writing session photos to the wall. `holdSessionPhoto` replaces
  `cachePhoto` for captures and routed arrivals. `sessionPhotos` (live) and
  `pendingFriendReview.photos` (awaiting review) are memory projections of the pending index.
- The answer (`applyPhotoAnswers`) copies kept photos into the wall through a new per-photo wall
  commit that reports exactly which photos landed, then removes the answered photos from the
  pending corpus with a tombstone, in one pending index write. Tombstones refuse re-projection
  before decrypt.
- Launch rebuilds an awaiting, photos-only batch from the pending index, reconciled against the
  wall only once both indexes are readable; an unlock re-reads whichever index was deferred.
- A root-level `SessionPhotoReviewCoordinator` presents the review in a dedicated overlay
  `UIWindow` above the main window (and so above every sheet in it), driven by a pure gate. It
  never presents over a live session or over First Aid. When it presents over a given-up held mesh
  it leaves that mesh, so the Friends tab lands on the album. "Not now" hides it without answering;
  it re-presents on the next foreground and from a Friends card.
- Held photos are never drawn while the scene is not active (an opaque cover inside the review
  sheet), so the app-switcher snapshot never holds them.
- The Photos-library export happens only after the answer commits, only over the photos that
  landed on the wall, as an opt-in toggle inside the review.
- A run-policy input stops Friends discovery while an ended session's review is outstanding, and
  keeps it stopped until any leave the review started has returned, so no second session forms and
  no answered session is resumed.
- Delete-all purges the pending corpus and the whole pending batch (new leg); the duress wipe
  crypto-erases the corpus (same keychain service, pinned by test).

## 4. The design

### 4.1 Data model: the pending corpus

**On-disk layout** (all names are frozen tokens; never localized, never renamed):

```
<proximitySupportDirectory>/PendingSessionPhotos/          isExcludedFromBackup = true
    Photos/<localID>.jpg                FMA2 box, purpose privatePendingSessionPhotoImageV1
    Thumbnails/<localID>.jpg            FMA2 box, purpose privatePendingSessionPhotoThumbnailV1
    PendingSessionPhotoIndex.sealed     FMA2 box, purpose privatePendingSessionPhotoIndexV1
```

A subdirectory, never siblings of `MeshPhotos/`: `PrivateMediaStore` derives its directories from
the index's parent (`PrivateMediaStore.swift:94-96`) and sweeps orphans by directory, so a sibling
corpus would be swept by the wall's save and vice versa.

**Index schema** (sealed JSON, `schemaVersion` 1; every field name is an at-rest schema, frozen):

```swift
public nonisolated struct PendingSessionPhotoIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    /// Held photos, newest first by `heldAt`. <= maxHeldPhotos.
    public var photos: [HeldSessionPhoto]
    /// Answered photos (kept, discarded, or deleted from the wall). <= maxAnsweredIDs.
    public var answered: [AnsweredSessionPhoto]
}
/// Who minted a photo and the id they chose: the transport-verified origin fingerprint (this
/// device's own for a capture, the signed `manifest.originFingerprint` for a routed photo) and the
/// origin's item id (`manifest.itemID`). The store-side twin of ProximityKit's `MeshContentKey`,
/// which this module cannot import (the DAG runs ProximityKit -> PrivateMediaStore).
public nonisolated struct HeldPhotoKey: Codable, Hashable, Sendable {
    public let origin: String
    public let itemID: UUID
}
public nonisolated struct HeldSessionPhoto: Codable, Equatable, Sendable {
    public let key: HeldPhotoKey
    /// This phone's clock when the photo was held. Orders the review; never an expiry (I19).
    public let heldAt: Date
    /// Metadata only (`imageData == nil`). `payload.id` is the LOCAL id: equal to `key.itemID`
    /// unless that id was already used by another held photo or a wall photo of a different
    /// origin, in which case a fresh UUID was minted at hold. Files are named by it; the review,
    /// the answer and the wall use it.
    public let payload: FriendPhotoPayload
}
public nonisolated struct AnsweredSessionPhoto: Codable, Equatable, Sendable {
    public let key: HeldPhotoKey
    public let expiresAt: Date
}
```

- Identity is split on purpose. The **key** (origin + item id) is what dedup, tombstones and the
  routed refusal use, so a member who copies another member's item id cannot make the genuine photo
  look "already held" or get it tombstoned (`MeshContentMerge.swift:18-24`). The **local id** is
  what files, the review selection and the wall use, so two origins' same-id photos can both be
  held and offered without one overwriting the other's file. Own captures never collide (the id is
  minted here); routed collisions are audited `mesh.heldPhotos.idCollision`.
- The answer kind (kept vs discarded) is deliberately NOT stored: the tombstone only has to say
  "never hold this again", and storing "discarded" would record a judgement for no reader.
- Per-photo "live vs awaiting" is NOT stored. At launch no session is live (`isSessionLive` is false
  until a commit: `currentMesh` is nil and a restored context is only an offer,
  `restoreSessionContextAtLaunch` `:10489-10517`), so every held photo is awaiting by definition
  (§4.8 states what this means for a kill mid-session). This is what makes the session-end
  promotion a memory-only move with no disk write (I6).
- `FriendPhotoPayload` metadata (sender name, fingerprint, signing key, session) is sealed with the
  rest of the index, exactly like the wall's (`PrivateMediaStore.swift:18-21`).

**Bounds** (Power of 10 R2/R3):

- `maxHeldPhotos = 200` (equal to `MeshNetworkManager.maxSessionPhotos`, `:553`). A hold past the
  cap is REFUSED, never an eviction: evicting a held photo would be a discard nobody chose. Own
  capture: unreachable with the 10-shot film (`:549`); a received photo past the cap answers
  `.refusedForNow`, stays in routed custody and is retried after the review frees room.
- `maxAnsweredIDs = 1024` (equal to `MeshRoutedStoreFormat.maxItems`, `MeshRoutedIndex.swift:65`, the
  most items custody can hold). `answeredRetention = 24 h`. An item is projected after its creation
  and answered after projection, so `answeredAt + 6 h 22 min >= expiresAt` for any routed item
  (6 h ceiling + 20 min grace + 120 s skew); 24 h leaves wide margin. Expired tombstones are dropped
  on load and on every write. Past the cap the soonest-expiring tombstone goes (audited
  `mesh.heldPhotos.answeredCapReached`); the worst case of losing one is a re-OFFER in the review,
  never a silent keep.

**Retention: held photos never expire on a timer.** Any timer is either a silent keep or a silent
discard, and the owner ruled both out. A held photo leaves only through an answer, delete-all, the
duress crypto-erase, or an index whose AEAD open fails under a present key. The exposure while the
person does not answer is bounded by the device-bound key, the backup exclusion, the snapshot cover,
the 200 cap, and the discovery block (which forces an answer before more photos can arrive).
`heldAt` is stored for ordering and for a possible later reminder (Q6), never for removal. Pinned by
I19.

**Store API** (new public struct in `FernletKit/Sources/PrivateMediaStore/PendingSessionPhotoStore.swift`;
stateless like `PrivateMediaStore`, the owner holds the mirror):

```swift
public struct PendingSessionPhotoStore {
    public static let maxHeldPhotos = 200
    public static let maxAnsweredIDs = 1024
    public static let answeredRetention: TimeInterval = 24 * 60 * 60
    public init(directory: URL,
                keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider(role: .pendingSessionPhotos))

    public enum Deferral: Equatable { case noKey, fileUnreadable, unsupportedFormat }
    public enum Load: Equatable {
        case loaded(PendingSessionPhotoIndex)   // absent file == empty index; orphans swept
        case deferred(Deferral)                 // never written over, never purged
        case unrecoverable(purged: Bool)        // key present, AEAD open failed: corpus removed
    }
    public func load(now: Date) -> Load

    public enum Hold: Equatable { case held, alreadyHeld, answered, full, notPersisted }
    /// Seals bytes + thumbnail FIRST, then writes `index` with the entry added. On an index write
    /// failure the two just-written files are removed and `.notPersisted` comes back. A kill
    /// between the two writes leaves unindexed files, swept by the next clean `load`.
    public func hold(_ photo: HeldSessionPhoto, imageData: Data, into index: PendingSessionPhotoIndex)
        -> (Hold, PendingSessionPhotoIndex)
    /// ONE sealed index write: removes `keys` from `photos`, tombstones them, drops expired
    /// tombstones; only after the write commits, sweeps the orphaned files.
    public func commitAnswers(_ keys: Set<HeldPhotoKey>, in index: PendingSessionPhotoIndex, now: Date)
        -> (committed: Bool, PendingSessionPhotoIndex)
    public func imageData(for photo: HeldSessionPhoto) -> Data?
    public func thumbnailData(for photo: HeldSessionPhoto) -> Data?
    public func hydrated(_ photo: HeldSessionPhoto) -> FriendPhotoPayload?
    /// Delete-all: removes the whole `PendingSessionPhotos/` directory. Keyless.
    public func purgeAll() -> Bool
    public func invalidateEncryptionKeyCache()
}
```

Fail-closed rules the store must keep (mirroring `PrivateMediaStore` where it is right and
diverging where the wall's rule is wrong for an ephemeral corpus):

- No key: nothing written (`gcmSeal` returns nil, `MediaAtRestCrypto.swift:54-62`).
- An index that exists but cannot be read (no key, or a file read error) is `.deferred` and is
  never written over.
- **Purge only on an AEAD failure.** An index that is read, whose key is present, and whose bytes do
  not OPEN (GCM authentication fails) is `.unrecoverable`: unlike the wall
  (`PrivateMediaStore.swift:361-364`) the pending corpus is removed at once, because an unopenable
  file is corruption or a duress-swept key and has nothing to preserve. Audited
  `privateMedia.pendingIndexUnrecoverable`.
- **A file that opens but does not decode is never purged.** The store first decodes only
  `schemaVersion`; a version above `PendingSessionPhotoIndex.schemaVersion`, or a same-version body
  that fails to decode, is `.deferred(.unsupportedFormat)`: never written, never purged, audited
  `privateMedia.pendingIndexUnsupportedFormat`. GCM authenticates, so an opened file was written by
  a Fernlet build; the likely cause is an older TestFlight build installed over a newer one. While
  it is deferred, holds are refused (a capture shows "Couldn't keep that photo"), and the newer
  build reads the photos again.
- **Orphan sweep on every clean `.loaded`** (after reconcile, when one runs): files under `Photos/`
  and `Thumbnails/` whose local id is not in the index are removed, through the extracted
  `removeOrphanedFiles(keeping:)`.
- Born sealed: no legacy-plaintext upgrade branch; planted plaintext reads as missing (like the
  recipe/progress stores, `PrivateMediaStore.md` "Legacy plaintext is upgraded only where it can
  legitimately exist").
- Bomb defenses on every hold: `maxIncomingPhotoBytes` and `isWithinSafePixelBounds`
  (`PrivateMediaStore.swift:61`, `:436`), because received photos are peer-supplied.
- `createDirectories` sets `isExcludedFromBackup` on `PendingSessionPhotos/` every time it creates it
  (the `ProtectedSidecar.swift:74` / `MeshRoutedStore.swift:509` idiom), and fails the hold if the
  flag cannot be set (a pending photo must never be written into a backed-up directory).

**Sharing code with the wall store.** Extract an internal `FriendPhotoCorpusFiles` from
`PrivateMediaStore` (directories, image/thumbnail purposes, `allowsLegacyPlaintext`, key provider;
`writeSealedImage` returning whether the write landed, `imageData(for:)`, `thumbnailData(for:)`,
`removeOrphanedFiles(keeping:)`) and use it from both stores, so the bomb checks, the thumbnail path
and the orphan sweep exist once. The wall passes its existing names and purposes and
`allowsLegacyPlaintext: true`; nothing about the wall's files or format changes.

**Wall store changes (Unit 1):**

- `readIndex` distinguishes "file exists but unreadable" and returns `.deferred` (fixes §1.7 item 1).
- New per-photo keep commit, the ONLY wall write the answer uses:

  ```swift
  public struct WallKeepResult: Equatable, Sendable {
      /// Ids whose sealed image write landed AND that are named by the committed index.
      public let keptOnWall: Set<UUID>
      public let indexCommitted: Bool
  }
  /// Adds `kept` (hydrated) to `wall` (the complete current wall, metadata only).
  public func commitKept(_ kept: [FriendPhotoPayload], onto wall: [FriendPhotoPayload]) -> WallKeepResult
  ```

  Order: (1) for each kept photo, the bound checks, the seal and the image write; only a photo
  whose image write returned without error joins `written` (the thumbnail stays best-effort, as
  today); a kept id already on `wall` is refused (unreachable by the local-id rule, defended
  anyway); (2) room is made by evicting only photos ALREADY on the wall, oldest `addedAt` first, so
  the index is `written + wall.prefix(maxCachedPhotos - written.count)` and `cappedNewestFirst`
  drops nothing; a kept photo is never evicted by its own keep, whatever its peer-signed `addedAt`;
  (3) the index write; on failure the files just written for `written` are removed (the old index
  never named them) and `keptOnWall` is empty; (4) only after a committed index, the orphan sweep
  (which takes the evicted wall photos, today's FIFO rule). `save(_:)` is untouched, so the
  existing call sites and tests are unchanged.

### 4.2 Key custody

- New `KeychainPrivateMediaKeyProvider.Role.pendingSessionPhotos` (`PrivateMediaKeyStore.swift:91-107`),
  account `com.fernlet.private-media.pendingContentKey`, same service `com.fernlet.private-media`
  (`KeychainPrivateMediaKeyProvider.service`, `:108`), which is the service the duress silent wipe
  sweeps (`FernletLockService.privateMediaKeychainService`, `FernletLockService.swift:2130`, the default of `mediaKeychainServices`,
  `FernletLockService.swift:1111`). Pinned twice (I24): a `KeyCustodyBoundaryTests` assertion that
  the role's service equals the swept service, and a `DuressDecoyAndWipeTests` cell.
- `defaultDeviceBinding(for: .pendingSessionPhotos) == true`: minted
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable. Unlike the own-photo row
  there is no escrow route to protect (nothing pending is ever meant to leave the phone), so it is
  born bound; unlike the wall it is never backup-restorable. Pinned by a new
  `KeyCustodyBoundaryTests` cell.
- Why a separate key and not the wall key: defence in depth behind the backup exclusion (a lost
  exclusion flag still yields nothing off-device), domain separation (pending bytes do not open
  under the wall key, so a file moved into `MeshPhotos/` cannot enter the wall), and keep-time
  re-sealing under the wall key runs the wall's own write path.
- Keep = hydrate from pending (decrypt under the pending key), then `commitKept` to the wall (seal
  under the wall key and wall purposes). No file is ever renamed between corpora.
- Delete-all keeps the row (the store is emptied; an empty store's key protects nothing, the same
  reasoning as the own-photo row, `FernletStore.swift:6077-6081`). The duress silent wipe deletes it
  with the whole service (crypto-erase). `mediaKey()`'s absent-vs-unreadable rule
  (`PrivateMediaKeyStore.swift:176-212`, `mediaKey()` at `:194`) already prevents a re-mint over a
  transiently unreadable row.
- New AEAD purposes in `FernletKit/Sources/FernletCrypto/CryptographicPurpose.swift` beside
  `privateFriendPhotoIndexV2` (`:368`):
  `privatePendingSessionPhotoImageV1 = "fernlet.private-media.pending-session-photo.image.aead.v1"`,
  `privatePendingSessionPhotoThumbnailV1 = "...pending-session-photo.thumbnail.aead.v1"`,
  `privatePendingSessionPhotoIndexV1 = "...pending-session-photo.index.aead.v1"`.

### 4.3 State machine (per photo)

States (the pending index is durable truth; the two lists are memory projections of it):

| State | Where the bytes are | Memory list | Visible in |
| --- | --- | --- | --- |
| `heldLive` | pending corpus | `sessionPhotos` | the camera Develop review only |
| `heldAwaiting` | pending corpus | `pendingFriendReview.photos` | the session-end review only |
| `kept` | wall (`MeshPhotos/`), tombstoned in pending | `meshPhotos` | the wall and everything that reads it |
| `discarded` | nowhere, tombstoned in pending | none | nothing |

Transitions:

| From | Event | To | Disk writes |
| --- | --- | --- | --- |
| (none) | own capture while `isSessionLive` | `heldLive` | pending: bytes, thumb, index |
| (none) | routed arrival, `isSessionLive && manifest.meshID == currentMesh?.id` | `heldLive` | pending: bytes, thumb, index |
| (none) | own capture or routed arrival while NOT live, or from another mesh | `heldAwaiting` | pending: bytes, thumb, index |
| (none) | arrival whose key is tombstoned, already held, or on the wall (same sender, same id) | unchanged; routed verdict leaves the retry list | none |
| `heldLive` | session ends (any door; `startJoin`) | `heldAwaiting` | **none** (memory move) |
| `heldLive`/`heldAwaiting` | answer: keep, and the wall commit reports it landed | `kept` | wall `commitKept`, then ONE pending index write (remove + tombstone), then sweep |
| `heldLive`/`heldAwaiting` | answer: keep, but the wall commit did not land it | unchanged (`notApplied`) | wall files for it removed; no pending write for it |
| `heldLive`/`heldAwaiting` | answer: not kept (shown, unticked, or Delete all) | `discarded` | ONE pending index write (remove + tombstone), then sweep |
| `heldLive`/`heldAwaiting` | "Not now", swipe-down on the Develop sheet, landing failure, backgrounding, process kill, any amount of time passing | unchanged | none |
| any held | process launch | `heldAwaiting` (all of them) | reconcile (below), orphan sweep |
| any held | `deletePhoto(localID)` | unchanged: refused, audited `mesh.heldPhotos.deleteRefused` | none |
| `kept` | per-photo delete on the wall | removed from wall, tombstone refreshed | wall save + pending index write |
| any held | delete-all | gone (corpus removed) | pending directory removed |

Answer crash safety: the wall commit comes before the pending write. A kill between them leaves a
photo both on the wall and held. **Reconcile** runs only when BOTH indexes are loaded (at init, or
the moment the second of them leaves `.deferred`, §4.4), and drops from `photos` every held entry
whose local id is on the wall or whose key names a wall photo (same sender fingerprint, same id),
tombstones them, drops tombstoned entries, and commits. Run over a deferred (empty-looking) wall it
would re-offer a kept photo, and a discard of it would then leave it on the wall; the precondition
closes that. A pending write that fails after a landed wall commit is audited
(`mesh.heldPhotos.answerNotPersisted`); the memory mirror reflects the answer; the next reconcile
repairs a kept photo, and a discarded one whose removal did not persist is re-OFFERED (never kept).

"First answer wins" (kept from `finishSessionPhotos(keeping:of:)`, `:2037-2053`): a local id no
longer held is ignored by every later answer.

### 4.4 MeshNetworkManager changes (ProximityKit)

State (next to `photoCacheStore`, `:339-347`):

```swift
@ObservationIgnored private let heldPhotoStore: PendingSessionPhotoStore
@ObservationIgnored private var heldPhotoIndex = PendingSessionPhotoIndex.empty   // durable mirror
@ObservationIgnored private var heldPhotoIndexDeferral: PendingSessionPhotoStore.Deferral?
@ObservationIgnored private var heldPhotosReconciled = false
```

Constructed in `init` beside the wall (`:615-641`) at
`store.proximitySupportDirectory/PendingSessionPhotos` (per-host, so the test isolation of
`ProximityHost.proximitySupportDirectory`, `ProximityHost.swift:32-51`, carries over). Loaded after
the wall. `.loaded` -> mirror; `.deferred` -> record the deferral; `.unrecoverable` -> audit, empty.
Then `reconcileHeldPhotosIfReady()`: only when the wall is not deferred and the pending index is
loaded, reconcile (§4.3), then `pendingFriendReview = MeshFriendReviewBatch(entries: [], photos: …)`
when anything is held.

**The deferred-index retry (fixes §1.7 item 2).** New `retryDeferredPhotoIndexes()`: if the wall is
deferred, `loadIndex()`; on `.entries`, merge exactly as `persistPhotoIndex` does today
(`mergedPhotoIndex`, `:2124`), clear `photoIndexDeferred`; if the pending index is deferred, load it;
then `reconcileHeldPhotosIfReady()`. Called (a) inside `applyRoutedAccessGate` (`:1635`) after its
equality guard and BEFORE `guard edge.runsPass`, whenever `protectedDataAvailable` or
`appIsForeground` rose, so the unlock that makes the files readable re-reads them before the
re-entry's projection pass; (b) at the top of `holdSessionPhoto` and `applyPhotoAnswers`. Nothing
writes the pending index while it is deferred; holds are refused then (`.notPersisted`).

Public read for the presenter: `public var heldPhotosCanBeShown: Bool` = `routedAccessGate.isOpen &&
heldPhotoIndexDeferral == nil && heldPhotosReconciled` (observable through a stored mirror updated
at each change), and `public var wallCanTakeKeeps: Bool` = `!photoIndexDeferred`.

Functions (bodies <= 60 lines each; split helpers where needed):

- `holdSessionPhoto(_ photo: FriendPhotoPayload, key: MeshContentKey, live: Bool) -> PendingSessionPhotoStore.Hold`
  replaces `cachePhoto` (`:13325`) for BOTH producers. It refuses by key (tombstoned -> `.answered`,
  held -> `.alreadyHeld`, a wall photo with the same sender and id -> `.alreadyHeld`), assigns the
  local id (the item id, or a fresh UUID on a collision with a held or wall local id), stamps live
  photos with `currentPhotoSessionMetadata()` (as `cachePhoto` does, `:13327`), and writes. On
  `.held`: append to `sessionPhotos` (live) or to the batch's photos (awaiting; creates a
  photos-only batch if none). `meshPhotos` is never touched. `cachePhoto` is deleted; the wall's
  only writers become `applyPhotoAnswers`, `deletePhoto` and the deferred-index merge.
- `addPhoto` (`:2789`): `live = isSessionLive`, key = (local fingerprint, photo id). If the hold is
  not `.held`, set `meshError` (localized "Couldn't keep that photo. Try again.") and do NOT spend
  film and do NOT share: if this phone cannot seal its copy, it does not send it (the routed store's
  "if you cannot seal, you must not acknowledge" rule, `MeshRoutedStore.swift:14-18`).
- `routedCanonicalDispatch(_:author:manifest:)` (`:8768`): the tombstone refusal comes first, BEFORE
  the quota and before the body is opened, in `dispatchRoutedPlaintext`'s `.friendPhotoWall` arm
  (`:8584`), keyed on `MeshContentKey(senderFingerprint: manifest.originFingerprint, contentID:
  manifest.itemID)`: tombstoned -> `.refusedForGood` (leaves the retry list; audit
  `mesh.routedProjection.photoAlreadyAnswered`). Already held or on the wall by key -> `.handedOn`
  without writing. Otherwise `live = isSessionLive && manifest.meshID == currentMesh?.id`: the
  SIGNED mesh id, never the optional peer-supplied `header.session` (`MeshRoutedItemBody.swift:153-154`),
  so a session-less photo from the current mesh is live (and stamped with the current metadata)
  rather than an awaiting photo that would disturb a live session. `.full`/`.notPersisted` ->
  `.refusedForNow` (stays in custody). The closeness hook (`onFriendPhotoSession`, `:8787`) fires for
  live arrivals. `isPhotoFromCurrentSession` (`:13488`) is deleted with its last caller.
- `movePhotosIntoPendingReview` (`:1601`): unchanged in shape; it now moves between two memory
  projections of the pending index and **writes nothing** (so it is correct while the device is
  locked in a continued-processing task).
- `applyPhotoAnswers(kept: Set<UUID>, discarded: Set<UUID>, now: Date) -> SessionPhotoAnswer` (new,
  internal engine; ids are local ids). Order:
  1. `guard routedAccessGate.isOpen` (a keep reads plaintext, and no answer may run under duress or
     in the background); else everything `notApplied`, `failure = .unavailable`. Tests that answer
     push an open gate first, as the routed suites already do (the default is `.closed`, `:324`).
  2. `retryDeferredPhotoIndexes()`. Pending index still deferred -> everything `notApplied`,
     `.unavailable`. Wall still deferred -> every KEPT id `notApplied` with `.keepUnavailable`;
     **discards proceed**, because they need only the pending index.
  3. Hydrate kept from pending; a kept photo whose bytes do not open while the gate is open and a
     key exists goes to `unreadable` and is treated as discarded (the tile showed a placeholder).
  4. `photoCacheStore.commitKept(hydrated, onto: meshPhotos)`; kept ids outside
     `result.keptOnWall` (and outside `unreadable`) are `notApplied` with `.wallWriteFailed`, stay
     held, and nothing of theirs is swept.
  5. ONE `heldPhotoStore.commitAnswers(keys of keptOnWall ∪ discarded ∪ unreadable)`.
  6. Update the memory lists, insert the `keptOnWall` metadata into `meshPhotos`,
     `prunePhotoWallPreferences`, audit `mesh.session.photoReviewAnswered` (counts only).

```swift
public nonisolated enum SessionPhotoAnswerFailure: Equatable, Sendable {
    case unavailable        // locked, backgrounded, duress, or the pending index unreadable
    case keepUnavailable    // the wall index cannot be read; discards still applied
    case wallWriteFailed    // the wall did not take some kept photos (disk full, no key)
}
public nonisolated struct SessionPhotoAnswer: Equatable, Sendable {
    public let keptOnWall: Set<UUID>    // landed on the wall; the ONLY ids an export may use
    public let discarded: Set<UUID>
    public let unreadable: Set<UUID>    // could not be opened; removed, and the UI says so
    public let notApplied: Set<UUID>    // still held, untouched
    public let failure: SessionPhotoAnswerFailure?
}
```

- `finishSessionPhotos(keeping:of:)` (`:2054`) and `finishReviewedPhotos(_:keeping:in:)` (`:1522`)
  keep their scoping logic ("answered = shown intersect still held") and call `applyPhotoAnswers`;
  both now return `SessionPhotoAnswer` (not `@discardableResult`; R7). `finishSessionPhotos(keeping:)`
  (`:2032`) and `deleteAllSessionPhotos` (`:2073`) forward.
- `reviewablePhotos(of:)` (`:1501`), `pendingReviewPhotos` (`:1473`), `photosAwaitingAnswer(among:)`
  (`:1491`) and `completeFriendReview` (`:1464`) filter by "still held" (the mirror's local ids)
  instead of "still on the wall".
- `deletePhoto` (`:2080`) acts on the wall only. A held local id is refused (no-op, audited): held
  photos leave only through an answer, so a delete cannot drop a photo from the memory batch while
  the pending index keeps it (it would come back after a relaunch). After a wall removal it
  tombstones the key (payload sender fingerprint + id, when the sender is known), refreshing 24 h,
  which covers a wall photo from an older build deleted inside a routed window after the upgrade.
- `public func reviewImageData(for:) -> Data?` / `reviewThumbnailData(for:)`: the ONLY door to
  pending bytes. `guard routedAccessGate.isOpen` first (unlocked, foreground, not duress), then the
  pending store. This is the decrypt seam that fails closed under duress (I13). `imageData(for:)`
  (`:13345`) and `hydratedPhotos` (`:13358`) stay wall-only.
- `public var hasOutstandingPhotoReview: Bool` = `!(pendingFriendReview?.photos.isEmpty ?? true)`
  (observable through `pendingFriendReview`).
- `public func purgeHeldSessionPhotosForDeleteAll() -> Bool`: empties `sessionPhotos`,
  `sessionRoster`, the WHOLE `pendingFriendReview` (photos and candidates), the mirror (tombstones
  included: after delete-all the routed store is wiped and the identity rotated, so nothing can be
  re-projected), and calls `heldPhotoStore.purgeAll()`. Candidates go too: a keep-friends offer from
  a session the person just asked to erase would write new trust rows about it (§9, R2-F12).
  Clearing the live roster here means a hard-stop leave that runs after the purge promotes nothing.
  `wipeIdentityForDeleteAll` (`:13960`) also invalidates the pending store's cached key.
- `finalizeCurrentPhotoSessionMetadata` (`:13422`): updates the memory lists as today; it does not
  rewrite the pending index (no write at session end). A kept photo carries the finalized metadata
  to the wall; after a kill, the capture-time participant list is what survives (stated limit).
- Doc comments to rewrite: `sessionPhotos` (`:102-112`), `pendingFriendReview` (`:120-129`),
  `leaveSession` (`:1654-1665`), the type doc (`:69-89`), `MeshFriendReviewBatch`
  (`MeshSessionTypes.swift:189-228`), `routedProjectedItems` (`:3416-3427`, the "wall dedup absorbs a
  re-hand" sentence becomes "the held/answered/wall dedup, keyed by origin and item id"),
  `persistPhotoIndex` (the new unlock retry).

### 4.5 Presentation: first thing shown

**Who presents.** One app-level presenter for every session-end photo review:
`SessionPhotoReviewCoordinator` (new, `App/Fernlet/SessionPhotoReviewCoordinator.swift`,
`@MainActor @Observable final class`, owned by `FernletStore` as an `@ObservationIgnored lazy var`
beside `meshNetworkManager`, `FernletStore.swift:243`). FriendsView stops presenting photo reviews;
it keeps the candidates-only keep-friends prompt.

**Where it draws.** A dedicated overlay window, `SessionPhotoReviewOverlayPresenter`
(`App/Fernlet/SessionPhotoReviewOverlayPresenter.swift`) behind a
`SessionPhotoReviewPresenting` protocol (`show(_:)`, `hide()`, `isShowing`) so tests inject a
recorder:

- `UIWindow(windowScene:)` on the scene ContentView lives in (captured by a zero-size
  `WindowSceneReader` `UIViewRepresentable` in `ContentView.rootSheetHost`'s background,
  `ContentView.swift:241`), `windowLevel = .normal + 1`, root = `UIHostingController` hosting
  `SessionPhotoReviewScreen`. Every SwiftUI sheet, cover and alert of the app lives in the main
  window, so this is above all of them without dismissing any: a half-typed meal or journal sheet
  underneath survives intact.
- Before `makeKeyAndVisible()`: `mainWindow.endEditing(true)` (the keyboard window is above ours),
  `mainWindow.accessibilityElementsHidden = true`. On hide: restore both, `mainWindow.makeKey()`,
  drop the window (`isHidden = true`, `windowScene = nil`, release it).
- Appearance: `overrideUserInterfaceStyle` from the same `FernletAppearanceMode` the app root
  applies (`FernletApp.swift:53-56`), so the overlay matches Light/Dark/System.
- **Scene phase is injected, not inherited.** A `UIHostingController` in a window this code creates
  sits outside the SwiftUI `App` scene that supplies `\.scenePhase`, so the screen does not rely on
  it: the coordinator holds `scenePhase` (fed by ContentView's existing `.onChange(of: scenePhase)`)
  and `SessionPhotoReviewScreen` applies `.environment(\.scenePhase, coordinator.scenePhase)`, which
  the review sheet's snapshot cover reads (below).
- Why not a SwiftUI sheet: `ConnectView.swift:1050-1058` records that a request from one presenter
  REPLACES a standing sheet of a view above it and QUEUES behind a sheet below it. Neither is "first,
  above everything, without losing what is underneath". Why not UIKit `present` on the top-most
  controller: SwiftUI dismissing its own sheet underneath dismisses everything presented on top of it.

**When it draws.** A pure gate, `SessionPhotoReviewGate` (`nonisolated enum`, exhaustively tested
like `ProximityRunPolicyTests`):

```swift
struct Input: Equatable, Hashable, Sendable {
    let outstandingPhotoCount: Int     // manager.pendingReviewPhotos.count
    let sessionIsLive: Bool            // manager.isSessionLive: never over a live session
    let heldPhotosCanBeShown: Bool     // manager.heldPhotosCanBeShown: seam open, index loaded, reconciled
    let sceneIsActive: Bool            // scenePhase == .active
    let launchComplete: Bool           // ContentView's launcher.isDone (ContentView mounts after onboarding)
    let duressSessionActive: Bool      // lockService.isDuressSessionActive
    let deleteAllInProgress: Bool      // store.deleteAllInProgress
    let crisisSurfaceUp: Bool          // activeSheet is .firstAid or .stressExplainer
    let cameraDevelopReviewUp: Bool    // coordinator.cameraDevelopReviewUp && manager.isInSession
    let deferredByUser: Bool           // "Not now" this activation
    let isShowing: Bool
}
enum Verdict: Equatable { case present, stayUp, hideWithoutAnswer, wait }
```

- `present`: count > 0, not live, photos can be shown, active, launch complete, not duress, not
  deleting, no crisis surface, no Develop sheet, not deferred, not showing.
- `hideWithoutAnswer`: showing, and duress became active, delete-all began, or a crisis surface
  came up underneath (a First Aid route from a notification or quick action while the review is
  up). Nothing is answered; it re-presents once the input clears.
- `stayUp`: showing otherwise. Backgrounding does not hide it; the snapshot cover does its job.
- Triggers (`ContentView` `.onChange`, each calls `coordinator.scheduleEvaluation()`, a 500 ms
  cancellable settle so a burst of promotions and the synchronous foreground re-entry pass land in
  one snapshot): `manager.pendingFriendReview`, `manager.isSessionLive`,
  `manager.heldPhotosCanBeShown`, `scenePhase`, `launcher.isDone`,
  `lockService.isDuressSessionActive`, `store.deleteAllInProgress`, `activeSheet`,
  `coordinator.cameraDevelopReviewUp`, `manager.isInSession`.
- Launch after a kill: the manager rebuilds the awaiting batch in its init (or at the unlock that
  makes its indexes readable), so the first evaluation after `launcher.isDone` on an active scene
  presents it before anything else is interacted with.

**Why each wait input exists.** `sessionIsLive`: today's presenter refuses over a live session
(`ConnectView.swift:993`); without it an awaiting photo arriving mid-session would pop the overlay
over the live camera. `heldPhotosCanBeShown`: the review must never present when its tiles cannot
load (the routed gate's foreground fact can lag `scenePhase`) or when a deferred wall means a
reconcile has not run (a kept photo could be re-offered). `crisisSurfaceUp`: the one deliberate
exception to "first thing shown" (Q8): a photo review must not cover the crisis line, and the
overlay would also hide First Aid from VoiceOver (`mainWindow.accessibilityElementsHidden`).

**App lock, stated.** No app-lock scope covers Friends (§1.6), so the review needs no unlock and does
not wait for one; the gate has no lock input except duress. It never reveals a locked surface: if
the Private tab's lock overlay is up, the review covers it and the gate stays locked underneath.
The duress leg is the one lock fact it obeys (never presents during a duress session, and the
pending bytes' decrypt seam refuses then). If a whole-app launch lock is ever added, it becomes one
more gate input and the review waits behind it, because the unlock must come first.

**The snapshot cover (I18).** `FriendPhotoReviewSheet` itself (so both the overlay and the camera's
Develop sheet get it) reads `@Environment(\.scenePhase)` and, while it is not `.active`, renders an
opaque cover (`Color.parchment`, the app glyph, accessibility label "Photos hidden", identifier
`friends.review.snapshotCover`) INSTEAD of the grid: no tile image is in the view tree, so the
app-switcher snapshot iOS writes into the container cannot hold a pending photo. The
`!= .active` form deliberately, as the progress timeline (`ProgressPhotoTimeline.swift:74-75`) and
the Tier-2 cover (`CaptureProtection.swift:11-13`, `:424`) use it, because the switcher can be
entered without a background transition. The cover is not the capture-friction modifier: that
modifier also reacts to screenshots with a nudge whose copy is written for the Private tab, and its
scope is a product decision (`Docs/Design-Capture-Protection-2026-08-10.md`); recording and
mirroring of the review are a stated limit (§8).

**The snapshot and the answer.** On `present`, the coordinator snapshots `batchID`,
`photos = manager.pendingReviewPhotos`,
`candidates = FriendMintingReview.eligibleCandidates(roster: batch.entries, trustedPeers: store.trustedProximityPeers)`,
`selectedIDs = all photo ids` (ticked, as today), `alsoSaveToPhotos = false`,
`canKeep = manager.wallCanTakeKeeps`. The screen renders the snapshot; tiles load through
`manager.reviewThumbnailData`/`reviewImageData`, keyed on `(photo.id, coordinator.tileReloadToken)`
so a tile that failed while the seam was briefly closed reloads when it reopens.

**Leaving an ended mesh at present.** If `manager.currentMesh != nil` at present (the gate already
guarantees the session is not live, so this is door 3's given-up held mesh or an ended mesh not yet
left), the coordinator raises `leaveInFlight` and starts `manager.leaveSessionAfterNotifyingPeers()`
(bounded: at most a 15 s handoff, `MeshNetworkManager.swift:1690`), lowering the flag when it
returns. This is today's answer-time leave (`ConnectView.swift:339-343`) moved to presentation. It
loses nothing: while the review is outstanding discovery is blocked, so the held mesh could not heal
anyway. What it buys: the Friends tab swaps from the camera to the album under the overlay
(`ConnectView.swift:130`), so "Not now" lands on the album and its card rather than on a stopped
full-bleed camera with no tab bar (§9, R2-F3), and no answer can ever run over a held mesh that the
policy might resume (§9, R2-F2).

**The discovery block.** The coordinator exposes

```swift
var blocksDiscovery: Bool {
    (manager.hasOutstandingPhotoReview && !manager.isSessionLive) || answerInFlight || leaveInFlight
}
```

and ContentView pushes it into the new run-policy input (below). `answerInFlight` is raised by
whichever surface answers (the overlay, or the camera's Develop sheet through
`coordinator.beginAnswer()`/`endAnswer()` with `defer`) before the manager is touched, and lowered
after that surface's leave has returned. So the block cannot fall while a leave is running: a
`stop -> foregroundOnly` edge over a held mesh answers `.resumeSearch` (`ProximityRunSeams.swift:206-252`),
`resumeSearchingForPartitionedMesh` does not refuse a given-up session and `startSearching` clears
`sessionSearchGaveUp` (`MeshNetworkManager.swift:2485-2494`, `:11605`), which would revive the
session the person just closed. When the block falls, no mesh is held, so the Friends tab's edge is
today's fresh search.

**Answering.**

- Keep selected: `answerInFlight = true`; `answer = manager.finishReviewedPhotos(shown, keeping:
  selected, in: batchID)`; `store.keepProximityFriends(...)` + `manager.completeFriendReview(batchID)`
  (the logic of `FriendsView.finalizeFriendKeeps`, `ConnectView.swift:1033-1041`, moves here); the
  export if asked, over `answer.keptOnWall` only (§4.6); then wait for any `leaveInFlight` (the screen
  shows "Ending the session..." with its buttons disabled); then either hide, or, if
  `answer.notApplied` is non-empty, **stay up**: the snapshot is refreshed to the still-held shown
  photos, an inline message names the failure ("Couldn't save your choice. Nothing was lost. Try
  again."), and the buttons re-enable. No hide-and-re-present loop (I25). If `answer.unreadable` is
  non-empty, a one-line notice before hiding. `answerInFlight = false` last.
- Delete all: the existing confirmation (`FriendPhotoReviewSheet.swift:242-251`), then
  `finishReviewedPhotos(shown, keeping: [], in:)`, the same friend finalize, the same leave wait and
  the same failure rule. Discards need only the pending index, so Delete all works even while the
  wall cannot be read.
- Keep while `canKeep == false` (a wall index that stays unreadable with protected data available,
  §1.7): the Keep button is disabled with the line "Keeping isn't possible right now because your
  saved photos can't be read. You can delete these, or choose later." Delete all and Not now work.
  So a broken wall never deadlocks the review.
- Not now: waits for any `leaveInFlight` (same working state), then hides; `deferredByUser = true`
  until the next background-to-active edge or a tap on the Friends card; nothing written, nothing
  answered, candidates stay in the batch (memory). VoiceOver's escape gesture performs Not now.
- Photos promoted while the review is up are not in the snapshot: they are neither kept nor
  discarded, and the review re-presents for them after the answer (today's scoping rule).

**Ordering with the other presenters.**

- Camera Develop review (session still live, user-initiated): stays the camera's own `.sheet`
  (`DisposableCameraView.swift:658`). **The flag cannot latch.** The camera writes
  `coordinator.cameraDevelopReviewUp` from `reviewPresented` (`.onChange(initial: true)`), AND clears
  it in the camera's `.onDisappear` beside `presentsOwnSheet.wrappedValue = false`
  (`DisposableCameraView.swift:640-644`, which exists for exactly this teardown), AND in the review
  sheet's `.onDisappear`. The gate reads it ANDed with `manager.isInSession`, the camera's own mount
  condition (`ConnectView.swift:130`), so even a missed write cannot outlive the camera surface
  (I20). A termination that tears the camera down with its Develop sheet up therefore presents the
  overlay at once. Its swipe-down still cancels back to the camera with nothing answered. If the
  session ends under it (door 3), it keeps answering its snapshotted ids (`photosAwaitingAnswer`,
  unchanged logic) and raises `answerInFlight` around its finish-and-leave; anything left after it
  closes is presented by the overlay at once.
- While the overlay is showing, the camera stops its `AVCaptureSession` (a hidden live camera is a
  privacy defect). Because the overlay never presents over a live session and leaves an ended held
  mesh at present, the camera does not restart on hide unless `manager.isSessionLive`.
- Keep-friends prompt (candidates-only batch): `FriendsView.presentDisconnectReviewIfNeeded` returns
  early while `manager.hasOutstandingPhotoReview || coordinator.isShowing || coordinator.blocksDiscovery`;
  `FriendMintingReview.sessionEndReview` is called with `hasPhotos: false` only. **A prompt already
  up is withdrawn unconsumed when the overlay shows** (a late photo can turn a candidates-only batch
  into a photos batch under it): FriendsView's `.onChange(of: coordinator.isShowing)` rising edge
  clears `reviewBatch`, `friendCandidates` and `keptFriendFingerprints` and THEN sets
  `keepFriendsPromptPresented = false`, the heal arm's pattern (`ConnectView.swift:282-293`), so its
  `onDismiss` finalize is a no-op and the candidates are answered once, by the overlay (I17). The
  prompt is covered by the overlay from the moment it shows, so no tap can land on it in between.
- The celebration cover cannot fire under an outstanding review (no discovery, §4.7).

**Friends album while a review is outstanding.** A `PendingPhotoReviewCard` takes the
`nearbyStatusBanner` slot (`ConnectView.swift:426-428`, empty while discovery is off because it
renders only while `isSearching`, `:597`): "Photos waiting for you", "N photos from your last
session are waiting. Nothing is saved until you choose.", button "Choose photos"
(`coordinator.reopen()`, which clears `deferredByUser` and evaluates). It renders only when
`manager.hasOutstandingPhotoReview && !manager.isSessionLive && !store.duressSessionActive`: under
a duress decoy there is no card (hide, never delete; the corpus is untouched), because a dead
"Choose photos" button would make the decoy distinguishable (`Docs/FernletSpecificationV3.md:184`).
While `coordinator.blocksDiscovery`, `sessionResumeBanner`'s `.offerResume` arm renders nothing: its
promise ("Keep this tab open ... you'll reconnect automatically", `SessionResumeCopy.swift:48-52`)
is false while discovery is blocked; the continuation and ended cards are unaffected.

**The review screen.** `FriendPhotoReviewSheet` (ProximityKit UI) is reshaped for both hosts:

```swift
public init(
    photos: [FriendPhotoPayload],
    selectedIDs: Binding<Set<UUID>>,
    friendCandidates: [MeshSessionRosterEntry] = [],
    keptFriendFingerprints: Binding<Set<String>> = .constant([]),
    alsoSaveToPhotos: Binding<Bool>,
    canKeep: Bool = true,
    workingMessage: LocalizedStringResource? = nil,   // "Saving to Photos..." / "Ending the session..."
    answerFailure: SessionPhotoAnswerFailure? = nil,
    tileReloadToken: Int = 0,
    keepSelected: @escaping @MainActor () async -> Void,
    discardAll: @escaping @MainActor () async -> Void,
    notNow: (@MainActor () -> Void)? = nil,          // nil in the camera sheet (swipe-down cancels)
    loadImageData: ((FriendPhotoPayload) -> Data?)? = nil
)
```

The `saveToPhotos` closure, the "Also save to Photos" button and the legacy single-action bar
(`saveSelected`/`explainerSave`) are removed. Pinned bar: the toggle row "Also save kept photos to
Photos" (off by default), then `[Delete all N] [Keep selected]`, with a "Not now" text button in the
header when `notNow != nil`. `SessionPhotoReviewScreen` (App) wraps it full-screen for the overlay.

### 4.6 Camera roll: only after the selection is committed

- The export runs only from the coordinator (overlay) or the camera (Develop sheet), only after
  `applyPhotoAnswers` returned, and only over `answer.keptOnWall`:
  `let toSave = manager.hydratedPhotos(manager.meshPhotos.filter { answer.keptOnWall.contains($0.id) })`
  (wall bytes, hydrated from the WALL store). Because `keptOnWall` names only photos whose sealed
  bytes landed (§4.1), the export never silently skips a photo it was told was kept. Pending bytes
  can never reach `FriendPhotoLibrarySaver`.
- Sequence: commit, then export while the screen shows "Saving to Photos..." with its buttons
  disabled, then a failure alert (the existing `photoSaveFailureAlert`, `FriendPhotoReviewSheet.swift:387`)
  inside the review, then the leave wait, then hide. A Photos denial therefore never costs the keep
  (FRND-12's guarantee survives: the keep is already committed when authorization is asked).
- The toggle is memory-only per review. No new `UserDefaults` key (so no new
  `PersistedSurfaceWipeBoundaryTests` row).
- The album carousel's per-photo save (`ConnectView.swift:1371`) is unchanged: it only ever sees
  chosen photos now.

### 4.7 Seam-by-seam coverage

| Seam | Behaviour after this change |
| --- | --- |
| Own capture (`addPhoto` `:2789`) | held (live, or awaiting if the session is not live); refused capture when the hold cannot be sealed (no film spent, not shared) |
| Received photo, in session | held live when `manifest.meshID` is the live mesh, whatever the optional header says; closeness hook unchanged |
| Received photo, late (session ended, reunion delivery, deferred projection, another mesh) | held awaiting; triggers the review once no session is live (the same rule as own photos) |
| Received photo, already answered | refused by `(origin, itemID)` tombstone before decrypt and before quota |
| Received photo reusing another origin's item id | held separately under its own key and a fresh local id; neither suppresses nor tombstones the other |
| Routed custody copy of a discarded photo | not deleted early: it is sealed ciphertext held for the other destinations, at rest under the routed store's device-bound key, and swept by the re-entry pass's expiry job at `hardDeadline + 20 min` (<= 6 h 22 min after the mesh began). The tombstone guarantees it never becomes a photo on this phone again. Stated limit |
| Wall readers (album, carousel, Home photowall, thumbnails, cache warning, wall posts) | never see held photos; no filter needed because held photos are not in `meshPhotos` |
| App-switcher snapshot | the review sheet renders an opaque cover instead of the grid whenever the scene is not active (both hosts) |
| Session end, every door (End Session, termination, departure, removal, ceiling, epoch exhaustion, pairwise "Ask to remove", hard stop, door 3 give-up) | memory move to awaiting, no disk write; review presents (after First Aid closes, if it is open) |
| Develop sheet up when the session is torn down | the flag clears on the camera's disappear and is ignored once `isInSession` is false; the overlay presents at once |
| Give-up with the mesh held (door 3) | as above; the overlay leaves the held mesh when it presents, so the tab lands on the album; the block holds until that leave returns |
| Heal / resume (`resumeSearchingForPartitionedMesh`) | never reached while a review blocks discovery; when the block falls no mesh is held, so the edge is a fresh search |
| Second session before the first is reviewed | new `ProximityRunPolicy.Input.sessionPhotoReviewBlocksDiscovery` (= `coordinator.blocksDiscovery`); `discoveryState` returns `heldForACommittedPeer(input.session)` when it is true (`ProximityRunPolicy.swift:429-441`), so neither `startJoin` nor the resume arm runs. It is false while a session is live, so a live session's discovery is never changed by it. The Friends card explains. Defence in depth: `startJoin` still moves any live leftovers to awaiting (`:2344`) |
| Kill mid-session, relaunch with a resumable context | photos rebuilt as awaiting and reviewed first (Q7); the resume offer card is suppressed while blocked; after the answer the Friends tab's discovery picks the session back up as today (§4.8) |
| Continued-processing task (`MeshContinuation*`) | a session ending in the background performs no disk write (I6) and cannot fail while locked; received photos are not projected in the background (the routed gate's foreground leg, `MeshRoutedAccessGate.swift:110`), so no pending write happens there; the review presents at the first `.active` scene; a kill in the background is covered by the launch rebuild |
| Process kill | launch rebuilds a photos-only awaiting batch; review presents first after launch (and after an unlock, if its indexes were unreadable) |
| Index unreadable at launch (locked) | both loads defer; the unlock edge re-reads them before the projection pass; reconcile runs once both are loaded; the gate waits until then |
| Wall index persistently unreadable | the review presents with Keep disabled and a line saying why; Delete all and Not now work; nothing deadlocks |
| Pending index from a newer build | deferred, never written, never purged; holds refused until a build that reads it returns |
| Never answered | held indefinitely; no timer removes anything (I19, Q6) |
| App lock (non-duress) | no scope covers Friends; the review neither waits for nor reveals a locked surface |
| Duress decoy | projection refused (gate); review never presents; `reviewImageData` returns nil; no Friends card; nothing deleted (hide never delete) |
| Duress silent wipe | service sweep crypto-erases the pending key (pinned, I24), then `deleteAllData` removes the corpus; a kill between them leaves unopenable files that the next load finds `.unrecoverable` (AEAD failure under the freshly minted key) and removes |
| Duress recovery-lock | media keys survive by design (`Docs/FernletSpecificationV3.md:188`); pending survives and is reviewed after recovery |
| Delete-all | new leg 4d `purgeHeldSessionPhotosForDeleteAll` inside `deletePhotoCorpora` (`FernletStore.swift:5842`), during `privacyWipeInProgress` so no projection races it; the whole batch (photos AND candidates) and the live roster go; incomplete label "session photos you hadn't chosen yet"; the overlay hides without answering; the pending key row survives |
| 13+ age gate | a final below-the-line ruling is a hard stop, so the session ends and the review presents like any ending; photos are not age-gated, and the review is a local keep/discard, so it is not suppressed |
| First Aid / stress explainer open | the review waits; if one opens under a showing review, the review hides without answering and returns when it closes (Q8) |
| iCloud device backup | pending directory excluded, pending key ThisDeviceOnly; the wall is unchanged (backup-restorable) |
| Sealed CloudKit backups | none touch friend photos (unchanged) |
| Data export (`DataExportBuilder`) | excludes photo bytes by construction (`DataExportBuilder.swift:15`, `:275`); unchanged |
| Format census / migration (`MediaAtRestFormatCensus`, `MediaAtRestFormatMigrator`) | the pending corpus is NOT added: it is born sealed in the current `FMA2` format by its only writer, is ephemeral, and holds nothing that predates the format. Documented in `PrivateMediaStore.md`, so a reader does not mistake it for an unswept location |
| Feasibility harness (`MeshFlowDriver.swift:318-326`, `:574`) | auto-keep goes through the new return value (logged); the "photos received" line counts held + wall |
| Block / removal mid-review | held photos from that person stay offered (the person chooses); the removal purge of candidates (`:12996`) is unchanged |

### 4.8 After a kill: the friend half, and a kill in the middle of a session

Roster candidates are memory-only key material by design (`MeshSessionTypes.swift:161-166`) and stay
that way. After a kill the rebuilt batch has photos and no candidates: the review shows photos
only, and the people from that session are not offered as friends. They can be kept at the next
in-person session (Q5).

A kill in the MIDDLE of a session (iOS reclaims Fernlet while it is locked in a pocket) is, by
default, the end of this phone's roll: at relaunch its photos are reviewed first, like any ended
session's. The session itself is not over for the others, and a `.resumable` context still offers
to pick it up (`MeshSessionResumePresentation.swift:131`). The default keeps that working in order:
answer first, then the Friends tab's discovery re-links as today. The consequences, stated: the
resume offer card is hidden while the review blocks discovery; items this phone carries in custody
for the others cannot drain until the person answers (they expire at `hardDeadline + 20 min`); and
the resumed session's Develop does not show the pre-kill photos (they were already answered). The
alternative (keep them as the resumed session's live roll) is Q7; §9 R2-F4 records why it is not
the default.

### 4.9 Migration of existing data

- The wall's files, index, key and format are untouched. No schema migration.
- The pending corpus starts absent (`.loaded(empty)`); the key row is minted on the first hold.
- Photos that reached the wall under older builds cannot be told apart from reviewed ones and are
  not retroactively offered. A build update kills the process, so an in-flight session's photos
  under the old build are already on the wall. (Only the owner's own phone holds data today.)
- Mixed builds in one mesh need no negotiation: the wire is unchanged. A friend on an older
  TestFlight build still puts photos on their wall at once; this phone holds its copies.
- Installing an older build over a newer one while photos are held: the older build reads the
  index as `.unsupportedFormat` only if the schema moved; it never purges it (§4.1).

### 4.10 Localization

ProximityKit catalog (`FernletKit/Sources/ProximityKit/Localizable.xcstrings`), in
`ProximityUICopy.Review` (`FernletKit/Sources/ProximityKit/UI/ProximityUICopy.swift:33-93`), every
lookup `bundle: .module`, rendered with `Text(verbatim:)` as the sheet does today:

| Key | Default value | Unit |
| --- | --- | --- |
| `proximity.review.explainer.pending` | "Nothing from this session is saved until you choose. Photos you don't keep are deleted from this phone." | 2 |
| `proximity.review.alsoSaveToPhotos.toggle` | "Also save kept photos to Photos" | 2 |
| `proximity.review.savingToPhotos` | "Saving to Photos..." | 2 |
| `proximity.review.unreadable` (plural `one`/`other`) | "%lld photos couldn't be opened and were removed." | 2 |
| `proximity.review.answerFailed` | "Couldn't save your choice. Nothing was lost. Try again." | 2 |
| `proximity.review.keepUnavailable` | "Keeping isn't possible right now because your saved photos can't be read. You can delete these, or choose later." | 2 |
| `proximity.review.snapshotCover` | "Photos hidden" (the cover's accessibility label) | 2 |
| `proximity.camera.holdFailed` | "Couldn't keep that photo. Try again." | 2 |
| `proximity.review.notNow` | "Not now" | 3 |
| `proximity.review.endingSession` | "Ending the session..." | 3 |
| `proximity.review.tile.label` | "Photo from %@" (the name through `PeerNameDisplay`) | 3 |
| `proximity.review.tile.hint` | "Double-tap to keep or not keep." | 3 |

Retired (the sync script prunes them): `proximity.review.alsoSaveToPhotos`,
`proximity.review.saveSelected`, `proximity.review.explainer.save`, and
`proximity.review.explainer.keep` (replaced by `.pending`, whose meaning differs: a new key, so a
translated old sentence is not shown for the new promise).

App catalog (`App/Fernlet/Localizable.xcstrings`), Unit 3 except the delete-all sentence (Unit 2):
`friends.pendingReview.title` "Photos waiting for you", `friends.pendingReview.body` (plural) "%lld photos from your last session are waiting. Nothing
is saved until you choose.", `friends.pendingReview.button` "Choose photos"; the delete-all first
sentence (`DeleteAllDataConfirmation.swift:125-129`) gains "photos from a Friends session you
haven't chosen yet" under a NEW key for the same reason. App strings go through
`LocalizedStringKey`, never a `String` parameter.

Frozen tokens (English forever): the directory and file names in §4.1, the index and key field
names (`schemaVersion`, `photos`, `answered`, `key`, `origin`, `itemID`, `heldAt`, `payload`,
`expiresAt`), the keychain account, the three purpose strings, audit tokens (`mesh.heldPhotos.*`,
`privateMedia.pendingIndex*`), accessibility identifiers `friends.review.overlay`,
`friends.review.notNow`, `friends.review.alsoSaveToPhotosToggle`, `friends.review.snapshotCover`,
`friends.review.answerFailed`, `friends.review.saveSelected` (kept), `friends.review.deleteAll`
(kept), `friends.pendingReview.card`, `friends.pendingReview.open`.

Catalog work lands LAST in each unit as its own commit (the primary tree's
`App/Fernlet/Localizable.xcstrings` is held uncommitted by another session: index-only catalog
commit, per the fan-out practice).

### 4.11 Accessibility

- Overlay: root `.accessibilityAddTraits(.isModal)`, the main window's elements hidden while it
  shows, `UIAccessibility.post(notification: .screenChanged, argument:)` on show and on hide; the
  title carries `.isHeader`; VoiceOver's escape gesture = Not now (`.accessibilityAction(.escape)`);
  in the camera sheet escape keeps its default (dismiss = cancel back to camera).
- Tiles (`FriendPhotoTile`, `FriendPhotoReviewSheet.swift:14-68`): keep `.isSelected`; add a label
  from the sender name ("Photo from Sam", via `PeerNameDisplay` so a withheld name reads as the
  placeholder, never a fingerprint) and a hint ("Double-tap to keep or not keep").
- The toggle is a real `Toggle` with its label; the working messages and the inline failure are
  announced (`.accessibilityLabel` + a status announcement).
- The snapshot cover is one element with its label; the hidden grid is `accessibilityHidden` while
  it is up.
- Dynamic Type: the existing `@ScaledMetric` tile and grid metrics stay; the pinned bar uses the
  existing `AdaptiveStack`. Reduce Motion: the overlay fades rather than slides.
- The Friends card is one accessibility element with a button; the count is in the label.

## 5. Invariants (each testable)

- **I1 Nothing on the wall before the answer.** After any sequence of captures and routed arrivals
  with no answer: no held id is in `meshPhotos`, in the wall's sealed index on disk, in
  `photoWallPosts` or `savedPhotoSessions`, in what the Home photowall selector is fed
  (`LaunchPreparationService.swift:313` reads `meshPhotos`), or readable through
  `imageData(for:)`/`thumbnailData(forPhotoID:)`.
- **I2 Camera roll only after the answer.** `FriendPhotoLibrarySaver.save` is called only with
  payloads whose ids are in `answer.keptOnWall` and on the wall at that moment. Behavioural cell
  with a recording saver seam, plus a source wall: in `SessionPhotoReviewCoordinator.swift` and
  `DisposableCameraView.swift` the only function that names `FriendPhotoLibrarySaver` takes a
  `SessionPhotoAnswer`.
- **I3 Sealed, device-bound, not backed up.** Every file under `PendingSessionPhotos/` begins with
  `FMA2`; its index and bytes do not open under the wall key and wall files do not open under the
  pending key; the directory carries `isExcludedFromBackup`; the key row is
  `AfterFirstUnlockThisDeviceOnly` and non-synchronizable.
- **I4 An answer is exact.** Kept = shown ∩ held ∩ ticked, and landed -> wall (bytes re-sealed under
  the wall key); discarded = shown ∩ held − ticked -> files gone; both tombstoned by key; ids not
  shown stay held; a local id answered once is ignored by any later answer.
- **I5 No resurrection.** A tombstoned `(origin, itemID)` is refused by the routed projection before
  decrypt and before quota, across a manager rebuild with the ledger restored, and the verdict
  leaves the retry list.
- **I6 The ending writes nothing.** `movePhotosIntoPendingReview` performs no store write (a pending
  store whose writes fail still moves; a rebuilt manager sees every photo awaiting).
- **I7 Survives a kill.** A second manager on the same directory rebuilds `pendingFriendReview` with
  every held photo and no candidates; `hasOutstandingPhotoReview` is true.
- **I8 Crash-safe answer.** Reconcile runs only with both indexes loaded; a held entry whose local
  id is on the wall, or whose key names a wall photo, or that is tombstoned, is purged from the
  pending index and never offered. With the wall deferred, reconcile does not run and the gate
  waits.
- **I9 The gate.** `SessionPhotoReviewGate` answers `present` exactly for the product in §4.5, and a
  shown overlay window is above a presented sheet of the main window without dismissing it
  (hosted-window cell: the sheet's `presentedViewController` is still non-nil).
- **I10 Cancel is not an answer.** "Not now", the camera sheet's swipe-down, a backgrounding and a
  `hideWithoutAnswer` leave the pending index byte-identical and `meshPhotos` unchanged.
- **I11 No second session, no deadlock (outside duress).** With `sessionPhotoReviewBlocksDiscovery`
  true, discovery is never `run`/`foregroundOnly`; the block is false whenever a session is live;
  and whenever it is what stops discovery outside a duress session, the Friends tab shows the album
  (never a camera for an ended session) with the card, and the card's reopen presents unless a
  named wait input holds.
- **I12 Delete-all.** After the funnel: no `PendingSessionPhotos/` directory, empty live list, no
  pending batch at all (no photos, no candidates), empty live roster, empty mirror; the wall and the
  pending key row survive; the keep-friends prompt does not present afterwards; the purge call is in
  the funnel body, its token in `PrivacyWipeCoverageTests`' manifest, and its row in
  `Docs/PrivacyWipeCoverage.md`.
- **I13 Duress decoy.** With the routed gate's `duressActive` true: `reviewImageData`/`reviewThumbnailData`
  return nil, the gate never answers `present`, no hold or answer runs, and the Friends card is not
  rendered.
- **I14 Bounded.** Held photos <= 200 (a 201st hold is `.full`, nothing evicted); tombstones <= 1024,
  none older than 24 h after any write.
- **I15 An unreadable index is deferred; only an AEAD failure purges.** A wall or pending index file
  that exists but cannot be read loads as `.deferred`, and no save runs over it; a pending index
  that opens but has a newer `schemaVersion` or does not decode is `.deferred(.unsupportedFormat)`
  and is neither written nor purged; only a present key that fails to open it purges.
- **I16 Peers follow the same rule.** A routed arrival is held (live or awaiting), never written to
  the wall; live means the signed manifest mesh id is the live mesh; a late arrival re-triggers the
  review.
- **I17 Photos first.** The keep-friends prompt never presents while `hasOutstandingPhotoReview`, the
  block, or the overlay is showing; a prompt that is up when the overlay shows is withdrawn without
  minting or consuming; candidates of a batch with photos are answered only inside the photo review.
- **I18 No held photo is drawn while the scene is not active.** With `scenePhase` `.inactive` or
  `.background` (injected, in both hosts), `FriendPhotoReviewSheet` renders the cover and no tile
  image.
- **I19 Held photos have no time-based removal.** A held photo loaded a year after it was held (an
  injected clock) is still held and offered.
- **I20 The Develop flag cannot outlive the camera.** With the Develop sheet up, a termination that
  removes the camera leaves the gate answering `present`.
- **I21 The discovery block holds until the leave returns.** For every answer and Not now over a
  held mesh, `blocksDiscovery` stays true until `leaveSessionAfterNotifyingPeers` has returned; the
  run-policy transition therefore never sees `outstanding -> cleared` over `.meshHeld`.
- **I22 A keep never loses a photo.** An id is in `keptOnWall` only if its sealed image write
  landed and the committed wall index names it; every other kept id stays held with its pending
  bytes; a kept photo is never evicted by its own keep, whatever its `addedAt`.
- **I23 Content-key identity.** Two origins' photos with the same item id are held as two photos;
  a tombstone for one never refuses the other; neither is "already held" because of the other.
- **I24 The duress silent wipe covers the pending corpus.** After a silent wipe (injected service),
  a pending index loads `.unrecoverable` and is purged; `Role.pendingSessionPhotos` uses the swept
  service.
- **I25 A failed answer does not loop.** When `notApplied` is non-empty the review stays up with the
  inline failure; it never hides and re-presents on its own; discards need only the pending index.

## 6. Staged implementation plan

Work in a worktree off `main` (never the primary checkout: another session holds uncommitted
edits there). Per the fan-out practice: own DerivedData (`fernlet-agent-<TAG>`), own simulator,
`-jobs 4`, `-parallel-testing-enabled NO`, suites named with `-only-testing:FernletTests/<Suite>`
(count the `passed on 'Clone` lines, never trust the banner), no full-suite runs. **A file can hold
several suites** (`MeshLastMemberPhotoReviewTests.swift` holds six), and `-only-testing` takes suite
names, so each gate below names suites, not files. Every unit ends with
`Scripts/power-of-10-scan.py`, `Scripts/doc-coverage-scan.py`, `Scripts/spm-wall-check.sh`, and
`Scripts/sync-string-catalogs.sh --check` after its catalog commit. Do not edit
`Docs/FernletSpecificationV3.md` or `Docs/ImplementationPlan.md` in this round (held uncommitted by
another session); record the spec delta in the unit's commit message and the DocC pages instead.

### Unit 1: the sealed pending corpus (storage only; no behaviour change)

Files:
- `FernletKit/Sources/FernletCrypto/CryptographicPurpose.swift` (3 purposes).
- `FernletKit/Sources/PrivateMediaStore/PrivateMediaKeyStore.swift` (role `.pendingSessionPhotos`,
  account, `defaultDeviceBinding == true`).
- `FernletKit/Sources/PrivateMediaStore/FriendPhotoCorpusFiles.swift` (new, internal, extracted).
- `FernletKit/Sources/PrivateMediaStore/PrivateMediaStore.swift` (delegate to the extraction;
  `readIndex` deferral fix; `commitKept(_:onto:) -> WallKeepResult`; `save` untouched).
- `FernletKit/Sources/PrivateMediaStore/PendingSessionPhotoStore.swift` (new: store, index, key and
  tombstone types, backup exclusion, caps, orphan sweep on load, format deferral).
- Docs: `PrivateMediaStore/Documentation.docc/PrivateMediaStore.md` (third key row, the pending
  corpus, identity by key + local id, no timer, why it is outside the census, delete-all and duress
  coverage), `Docs/Verifiability.md` §6.3 key table, `Docs/FileIndex.md`.

Tests (run): new `PendingSessionPhotoStoreTests` (round trip; FMA2 on every file; wall key cannot
open pending and vice versa; planted plaintext reads as missing; no key -> `.deferred(.noKey)` and
never overwritten; an index path that exists but is unreadable (a directory or a mode-000 file at
the path) -> `.deferred(.fileUnreadable)`; wrong key -> `.unrecoverable` and the corpus is gone; a
file sealed under the right key with `schemaVersion` 2, and one with an undecodable body ->
`.deferred(.unsupportedFormat)`, not written, not purged; planted unindexed files swept on a clean
load; two keys with the same `itemID` and different origins held side by side; 201st hold `.full`
with nothing evicted; `commitAnswers` is one index write and sweeps the files; expired and over-cap
tombstones pruned; a year-later load keeps every held photo; `purgeAll`; the directory's
`isExcludedFromBackup`); `MeshPhotoCacheSealingTests` +
`aSealedIndexThatCannotBeReadDefersInsteadOfReadingAsEmpty`,
`commitKeptReportsOnlyPhotosWhoseBytesLanded` (an injected image-write failure: the id is not in
`keptOnWall` and not in the index), `commitKeptNeverEvictsAPhotoBeingKept` (a full wall of 1000 and a
kept photo with an `addedAt` older than all of them: it is kept and the oldest wall photo goes),
`commitKeptRemovesItsFilesWhenTheIndexWriteFails`; `PrivateMediaStoreTests`;
`KeyCustodyBoundaryTests` + `pendingSessionPhotoKeyIsDeviceBoundAtMint` and
`pendingSessionPhotoKeyLivesUnderTheServiceTheDuressWipeSweeps`;
`CryptographicDomainSeparationTests` (3 domains); `MeshRoutedItemSealTests` (its purpose-registry
size pin moves by 3); `MediaAtRestFormatCensusTests`, `MediaAtRestFormatMigrationTests` (unchanged
expectations, proving the census is untouched); `MeshNetworkManagerTests` (the wall still works).

Why it lands green alone: the pending store has no production caller yet, so no persisted surface
exists yet and no wipe row is owed until Unit 2 (the row lands in the commit that starts writing).
`commitKept` has no production caller yet either. The only behaviour change is the deferral fix,
which only turns a data-loss path into a wait.

Risks: the extraction touches the wall's write path (mitigated by the unchanged wall suites and the
census/migration suites, which read the same files); the purpose-registry pin in the mesh suites
(run the mesh line); the new keychain account is process-global in the simulator like the wall's,
so a test never deletes it (the duress cell injects its own service).

### Unit 2: hold, answer, rebuild, tombstone, delete-all (the model)

Files:
- `FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift` (§4.4 in full, including
  `retryDeferredPhotoIndexes` in `applyRoutedAccessGate`, reconcile precondition, content-key dedup
  and local ids, signed-mesh-id live classification, `deletePhoto` refusal on held ids).
- `FernletKit/Sources/ProximityKit/Mesh/MeshSessionTypes.swift` (`SessionPhotoAnswer`,
  `SessionPhotoAnswerFailure`; batch doc).
- `App/Fernlet/FernletStore.swift` (leg 4d in `deletePhotoCorpora`; the survivors doc at
  `:5560-5566` and the key-row comment at `:6070-6081` name the pending corpus and row).
- `App/Fernlet/DeleteAllDataConfirmation.swift` (new-key first sentence).
- `FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift` and `ProximityUICopy.swift`:
  the post-commit half of §4.5's API lands here (`alsoSaveToPhotos: Binding<Bool>`, `canKeep`,
  `workingMessage`, `answerFailure`, `tileReloadToken`, async `discardAll`; the "Also save to
  Photos" button, the `saveToPhotos` closure and the legacy single-action bar go) AND the snapshot
  cover (both existing hosts are SwiftUI, so `scenePhase` reaches them without injection here); the
  `notNow` parameter and the overlay wrapper are Unit 3.
- `App/Fernlet/ConnectView.swift`, `App/Fernlet/DisposableCameraView.swift` (the two EXISTING hosts,
  still presenting as today: tiles load through `reviewImageData`; Keep = answer, then, only if the
  toggle is on, export `answer.keptOnWall` hydrated from the wall (§4.6); on `notApplied` the sheet
  stays up with the inline failure instead of dismissing (FriendsView's deferred check would
  otherwise re-present it in a loop); the old pre-answer `exportSelectedPhotosToLibrary` functions
  are deleted). This is what makes the camera-roll rule hold from this unit on, rather than waiting
  for the presenter. The leave stays at answer time in this unit (no discovery block exists yet, so
  there is no resume race to close).
- `App/Fernlet/Proximity/Feasibility/MeshFlowDriver.swift` (return value; counts).
- `Docs/PrivacyWipeCoverage.md` (cleared-table row for `PendingSessionPhotos/` with token
  `purgeHeldSessionPhotosForDeleteAll`, naming the batch candidates and live roster; exceptions-table
  row for the `…pendingContentKey` account: kept by delete-all, swept by the duress wipe),
  `Tests/FernletTests/PrivacyWipeCoverageTests.swift` (manifest token).
- DocC `ProximityKit.md` (the "Photos are never dropped at an ending" paragraph rewritten: held
  from capture, never on the wall until chosen, tombstones by origin and item id, no timer),
  `Docs/ProximityFunctionIndex.md`, `Docs/FileIndex.md`.

Tests (add): `MeshHeldSessionPhotoTests` covering I1, I4, I5 (including a rebuilt manager with the
ledger restored), I6, I7, I8 (wall deferred at launch: reconcile does not run and
`heldPhotosCanBeShown` is false; the unlock edge re-reads the wall and then reconciles), I13, I14,
I16 (a session-less routed photo from the live mesh is held live and does not touch the batch),
I19, I22 (through the manager: an injected wall image-write failure leaves the photo held and
offered, and the export set excludes it), I23 (an impostor with a copied item id arrives first; the
genuine photo is held too; discarding the impostor does not refuse the genuine one) and I25's model
half (a deferred wall index: Keep is `notApplied` with `.keepUnavailable` while Delete all
applies); `DuressDecoyAndWipeTests` + `silentWipeLeavesThePendingCorpusUnopenable` (I24).

Update, by suite name (each named in the gate):
- The six suites in `MeshLastMemberPhotoReviewTests.swift`: `MeshLastMemberPhotoReviewTests`,
  `MeshInvoluntaryEndingPhotoReviewTests`, `MeshDevelopReviewUnderGiveUpTests`,
  `PendingPhotoReviewScopingTests`, `FriendsViewLastMemberReviewPresentationTests`,
  `LastMemberPhotoReviewSourceWallTests`. The assertions that held photos ARE on the wall invert
  (`assertOffered` `:182-185`; `MeshInvoluntaryEnding` `:233`, `:257`; Scoping `:417`, `:424`, `:457`);
  every cell that answers pushes an open routed gate first; Scoping's
  `deletingAPendingPhotoRemovesItFromTheReview` (`:461-471`) becomes "deleting a held photo is
  refused and the batch keeps it"; the source wall's "exactly one `sessionPhotos.removeAll()`"
  (`:811`) is re-pointed to name the delete-all purge (written as `sessionPhotos = []` inside
  `purgeHeldSessionPhotosForDeleteAll`, and the wall asserts that function is the only other
  emptier). The FriendsView hosted cells stay valid in this unit (FriendsView still presents).
- `ConnectReviewKeepTests` and `DisposableCameraSaveTests` (source walls: the export follows the
  answer and reads only `answer.keptOnWall`, I2; the keep never names the saver).
- `MeshRoutedPhotoDeliveryTests` ("reaches the wall" -> "is held for review";
  `aPhotoIsHandedToTheWallOnce` -> held once; the eleventh-photo quota cell; a new tombstone refusal
  cell keyed by origin), `MeshNetworkManagerTests`, `LocalizationBoundaryTests` (the Unit 2 keys of
  §4.10; catalog commit last), `FriendMintingTests`, `MeshPairwiseFoundingTests`,
  `MeshRoutedDrainConvergenceTests`, `MeshRoutedRetryAllowanceTests`, `MeshRoutedHeartTests`,
  `MeshP5AcceptanceTests`, `MeshP6AcceptanceTests`, `MeshClothingShopTests`, `MemoryLifecycleTests`
  (grep for `meshPhotos`, `addPhoto(`, `sessionPhotos`, `pendingFriendReview`, `finish*Photos`,
  `isPhotoFromCurrentSession`), `DeleteAllDataTests` (+ the pending corpus, the batch candidates and
  the live roster are gone and the wall is not), `PrivacyWipeCoverageTests`,
  `PersistedSurfaceWipeBoundaryTests` (must stay green with no new row: no defaults key added),
  `MeshRoutedLockedDeviceTests` (the projection's gate pins; the new retry sits before
  `runsPass`), `PhotowallPhotoSelectorTests`, `KeyCustodyBoundaryTests`. A shared test helper
  `heldPhotoIDs(_:)` keeps the churn mechanical.

Why it lands green alone: the old presenters still present (FriendsView reads the batch, the camera
its snapshot); they now answer through `applyPhotoAnswers`, read tiles through the pending seam,
cover the grid when the scene is not active, and export only after the answer, so the owner's two
storage rules (nothing on the wall, nothing in the camera roll before the answer) and the kill
survival hold after this unit. A batch rebuilt at launch is presented by FriendsView's existing
check the first time the Friends surface appears (today's behaviour); "first thing shown,
anywhere" is Unit 3.

Risks: the largest test churn of the round; the 60-line rule on `routedCanonicalDispatch` and the
answer engine (split helpers); FIFO interplay (a keep into a full wall evicts the oldest wall photo,
today's rule, never the kept one); `MeshMembershipRecords`-style clean-build hazard for
`FernletDomainModel` if any shared type moves (none should; do a clean build if one does).

### Unit 3: review first (presenter, gate, Not now, second-session block)

Files:
- New `App/Fernlet/SessionPhotoReviewCoordinator.swift` (coordinator, `blocksDiscovery`,
  `answerInFlight`/`leaveInFlight`, + `SessionPhotoReviewGate`),
  `App/Fernlet/SessionPhotoReviewOverlayPresenter.swift` (window host + `WindowSceneReader`),
  `App/Fernlet/SessionPhotoReviewScreen.swift` (injects `scenePhase`),
  `App/Fernlet/PendingPhotoReviewCard.swift`.
- `App/Fernlet/FernletStore.swift` (owns the coordinator), `App/Fernlet/ContentView.swift` (reader,
  triggers incl. `activeSheet` and `scenePhase` forwarding, run-policy input push of
  `coordinator.blocksDiscovery`), `App/Fernlet/ProximityRunPolicy.swift`
  (+ `sessionPhotoReviewBlocksDiscovery`, `discoveryState`), its producer in `FernletStore`'s
  run-policy funnel.
- `App/Fernlet/ConnectView.swift` (remove `disconnectReviewSheet` and its photo paths; keep-friends
  prompt waits and is withdrawn per I17; the card with its duress rule; the resume-offer
  suppression), `App/Fernlet/DisposableCameraView.swift` (report the Develop sheet with the three
  clears; raise `answerInFlight` around its finish-and-leave; stop the camera under the overlay).
- `FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift` (the `notNow` parameter, the
  header trait, the escape action, tile labels),
  `FernletKit/Sources/ProximityKit/UI/ProximityUICopy.swift` (the Unit 3 keys of §4.10).
- `App/Fernlet/UITestSupport.swift` (DEBUG launch argument `-uitestSeedHeldSessionPhotos <n>` that
  holds n generated JPEGs as awaiting before the first evaluation).
- DocC `App/Fernlet/Documentation.docc/Fernlet.md` (the presenter, its gate and the block),
  `ProximityKit.md` (the sheet's API), `Docs/FileIndex.md`.

Tests:
- New `SessionPhotoReviewGateTests` (exhaustive product over the 10 Boolean inputs and a zero/non-zero
  count; I9, I10, I13, the `sessionIsLive`, `heldPhotosCanBeShown` and `crisisSurfaceUp` rows).
- A hosted-window cell that presents a SwiftUI sheet in a main window, shows the overlay, and
  asserts the overlay is key, above, and the sheet is still presented, then hides and asserts the
  main window is key and its accessibility restored; a second hosted cell that drives the injected
  `scenePhase` to `.inactive` and asserts `friends.review.snapshotCover` is present and no tile
  image is (I18).
- New `SessionPhotoReviewCoordinatorTests` with a recording presenter, a recording saver seam and a
  recording run-policy sink: I2; I10; re-present for late arrivals; I20 (Develop sheet up, then
  `leaveSession()` on the termination road removes the camera: the gate answers `present`; and the
  own-Keep road with a late arrival); I21 (door 3, present: the leave starts at present and the
  block holds until it returns; Keep with the Photos toggle on: the block is still up during the
  export and falls only after the leave; the camera's Develop answer under door 3 likewise); door 3
  then Not now: the mesh is gone, the album and the card are the Friends surface, the camera is
  stopped; I17 (the keep-friends prompt up, a late photo held: the prompt is withdrawn with no mint
  and the overlay offers the candidates once); I25 (an unreadable wall index: Keep disabled with
  its line, Delete all applies, no hide-and-re-present); First Aid: waits, and a First Aid route
  while showing hides without answering and re-presents on close; duress: no present and no card
  (I13); the resume-offer card is suppressed while blocked.
- `ProximityRunPolicyTests` (the new input; I11: never `run`/`foregroundOnly` while blocked; false
  while live), `ProximityRunSeamsTests` (+ a cell documenting that `blocked -> cleared` over
  `.meshHeld` answers `.resumeSearch`, the edge I21 exists to prevent, and that over `.absent` it is
  the fresh search).
- `MeshSessionResumePresentationTests`, `SessionResumeCopyTests` (unchanged expectations; the
  suppression is the view's).
- The six suites in `MeshLastMemberPhotoReviewTests.swift` again: the four
  `FriendsViewLastMemberReviewPresentationTests` hosted cells are re-pointed to the coordinator
  (the cell at `:669-714` asserts the opposite of the overlay rule and is rewritten, not deleted);
  `LastMemberPhotoReviewSourceWallTests`' presenter walls (`:836-842`, `:857-860`) are re-pointed:
  the answers live in the coordinator, and FriendsView's `noteSessionEndSheetRequested()` count
  drops to one (the prompt only).
- `ConnectReviewKeepTests`/`DisposableCameraSaveTests` source walls (I2); `LocalizationBoundaryTests`;
  `CaptureProtectionTests` (unchanged: the cover is not the modifier).
- One UI test `SessionPhotoReviewFirstUITests` (launch with the seed: the overlay is the first
  element before any tab interaction; Not now hides it; a background/foreground cycle re-presents
  it; Keep puts the photos in the album grid). Run it on a fresh simulator, serially.

Why it lands green alone: it is presentation over the Unit 2 model.

Risks: the overlay window is new infrastructure (keyboard, VoiceOver focus, appearance, a stray
retained window; the memory-lifecycle wall's rule that no window or task outlives its owner, which
also covers the leave task the coordinator starts); the exhaustive run-policy table doubles;
SwiftUI `.onChange` storms (the 500 ms settle bounds them); the leave at present changes when a
door-3 pair's termination is sent (from answer time to review time), which the two-phone closing
check covers.

### Closing verification (not a unit)

On both phones running the latest TestFlight build that carries Unit 3: a two-phone session with
photos from each side, ended from each side in turn, with the other phone on another tab and with a
root sheet open; the Develop sheet open on one phone when the other ends; force-quit before
answering and relaunch; force-quit mid-session and relaunch (review first, then the session picks
back up); Not now then background/foreground, and check the app switcher shows the cover; "Also save
kept photos to Photos" with Photos access denied, then allowed; delete-all with a review
outstanding. Check the camera roll after every step.

## 7. Owner questions (implementation proceeds on the default)

- **Q1 Delete-all and unchosen photos.** Default: delete-all deletes photos you haven't chosen yet,
  and the "keep as friends" offer from that session (the kept wall still survives, as today), and
  the dialog says so. Alternative: keep them pending like the wall.
- **Q2 A "Not now" button on the review.** Default: yes. It hides the review with nothing saved; it
  comes back the next time Fernlet opens, the Friends tab shows "Photos waiting for you", and no
  new session can start until you choose. Alternative: no escape; the review stays up until you
  choose.
- **Q3 Saving to the camera roll from the review.** Default: a switch "Also save kept photos to
  Photos", off each time, applied only after you tap Keep. Alternative: no camera-roll option in
  the review at all (save single photos from the album afterwards).
- **Q4 Starting a new session with photos still waiting.** Default: not allowed; Friends asks you to
  choose first. This also means photos your phone is carrying for friends in that session wait
  until you choose. Alternative: allow it and keep the older session's photos waiting separately.
- **Q5 After a force-quit, the "keep as friends" part of that session is lost.** Default: accept it
  (the photos review still comes back; the people can be kept next time you meet). Alternative: a
  later round rebuilds the offer from the session's sealed membership record.
- **Q6 Photos you never choose.** Default: they wait on the phone, sealed, for as long as it takes;
  nothing deletes or keeps them on a timer. Alternative: after N days, ask once "Delete these
  photos?" (still your choice, never automatic).
- **Q7 If the phone closes Fernlet in the middle of a session.** Default: when you open Fernlet
  again, you choose that session's photos first; after that, Friends picks the session back up as
  it does today. Alternative: treat the photos as still part of the session and ask only when it
  really ends (a larger change; see §9 R2-F4).
- **Q8 First Aid comes first.** Default: if First Aid is open when a session ends, the photo review
  waits until you close it, and it steps aside if First Aid is opened on top of it. Alternative: the
  photo review always comes first, even over First Aid.

## 8. Honest limits

- A discarded photo's routed ciphertext can stay on this phone, sealed and unreachable, until its
  mesh item expires (at most about 6 h 20 min after the session began). It is custody for the other
  members, not a copy this phone can show.
- Friends on builds without this change still save your photos to their wall at once.
- After a kill, a held photo's participant list is the one stamped at capture, and the friend offer
  is gone (Q5).
- No retroactive review of photos that reached the wall before this change.
- Screen recording, AirPlay mirroring and screenshots of an open review are not covered: the
  snapshot cover handles the app-switcher image only, and the capture-friction layer is scoped to
  the Private tab by an earlier product decision.
- Food-logging cameras (barcode, nutrition label) are pushed or nested inside Food, not root
  sheets, so the gate cannot see them: a review that presents over one covers it while its capture
  session keeps running underneath (nothing is stored; the scan is intact after the answer).
- While a review blocks discovery, custody items this phone carries for others cannot drain; items
  that outlive `hardDeadline + 20 min` expire undelivered (Q4, Q7).
- A wall index that stays unreadable with protected data available means Keep is disabled until it
  reads again; in the rare case that coincides with a kill inside an answer, a photo kept just
  before the kill is offered again, and discarding it then leaves the earlier wall copy.
- The eviction order on a full wall is still the peer-signed `addedAt` (today's rule): a future-dated
  photo you keep sits at the top of the wall. The design only guarantees a keep never evicts itself.

## 9. Review resolution

Every finding was checked against `main` at `3c8c9313`; all twenty-two describe real behaviour.
Twenty are accepted as written or with a narrower fix; two are partially accepted with the
disagreement recorded and put to the owner.

**Accepted.**

- **R1-P1 / R2-F10 (snapshot).** Confirmed: `FriendPhotoTile` draws full-resolution bytes
  (`FriendPhotoReviewSheet.swift:32-64`) and the timeline covers itself (`ProgressPhotoTimeline.swift:74-75`,
  `:205-209`). Added the cover inside the sheet (both hosts), explicit `scenePhase` injection for the
  overlay window, I18, a hosted cell, §0 item 1, the §4.7 row. R2-F10's `isCaptured` leg is stated as
  a limit (§8) rather than adopted: the friction modifier's nudge copy and scope are a Private-tab
  product decision.
- **R1-P2 (keep can lose a photo).** Confirmed at `PrivateMediaStore.swift:166-193`, `:211`, and the
  unclamped `addedAt` at `MeshNetworkManager.swift:8776-8784`. Replaced `commit(_:) -> Bool` with
  `commitKept(_:onto:) -> WallKeepResult` (per-photo, bytes-landed, never evicts what it keeps,
  removes its files on an index failure), I22, three store cells and a manager cell.
- **R1-P3 (retention).** Policy stated in §4.1: no timer, ever; I19 with a year-later test; Q6.
- **R1-P4 / R2-F1 (Develop flag latch).** Confirmed: the camera already clears `presentsOwnSheet` in
  `.onDisappear` for this teardown (`DisposableCameraView.swift:640-644`) and a termination removes
  it (`ConnectView.swift:130`). The flag is now cleared in three places and read ANDed with
  `isInSession`; I20; coordinator cells for both roads.
- **R1-P5 (no wall retry; reconcile precondition).** Confirmed: `photoIndexDeferred` is set only at
  `:638` and cleared only at `:2115`. Added `retryDeferredPhotoIndexes()` before `runsPass`, the
  both-loaded precondition, `heldPhotosCanBeShown` as a gate input, tile reload on reopen, I8 cells.
- **R1-P6 / R2-F11 (duress card).** Card hidden under duress; I11 scoped outside duress; I13 extended.
- **R1-P7 (orphans after a kill mid-hold).** Orphan sweep on every clean load; store cell.
- **R1-P8 (older build purges newer index).** Purge only on an AEAD open failure; a newer or
  undecodable schema is `.deferred(.unsupportedFormat)`; I15; store cells.
- **R1-P9 (id-only identity).** Confirmed at `MeshContentMerge.swift:18-24`. Held, answered and
  tombstone state is keyed by `(origin, itemID)`, with a local id for files and the UI so two
  origins' same-id photos coexist; I23. The store defines its own `HeldPhotoKey` because
  PrivateMediaStore cannot import ProximityKit's `MeshContentKey`.
- **R1-P10 / R2-F12 (duress pin; delete-all candidates).** I24 with a `DuressDecoyAndWipeTests` cell
  and a `KeyCustodyBoundaryTests` service assertion; delete-all now drops the whole batch and the
  live roster (Q1 wording updated).
- **R2-F2 (resume after the answer).** Confirmed: the resume arm does not refuse a given-up session
  and `startSearching` clears `sessionSearchGaveUp` (`:2485-2494`, `:11605`). Two changes close it:
  the overlay leaves an ended held mesh at PRESENT, and `blocksDiscovery` includes
  `answerInFlight || leaveInFlight` so it cannot fall before a leave returns (I21, run-seam and
  coordinator cells). The design's old sentence "after the answer the held mesh is left, so no
  resume" was false and is gone.
- **R2-F3 (Not now lands on a camera).** Confirmed (`ConnectView.swift:130-138`). Fixed by the same
  leave at present: the surface swaps to the album under the overlay, and every hide waits for the
  bounded leave. Cell: door 3, Not now, album and card visible, camera stopped.
- **R2-F5 (First Aid).** `crisisSurfaceUp` input (`.firstAid`, `.stressExplainer`): wait, and hide
  without answering if one opens underneath; Q8. The food cameras are a stated limit (§8): they are
  navigation destinations and nested sheets (`FoodView.swift:1543`, `:1538`), not root sheets the
  gate can see.
- **R2-F6 (keep-friends prompt already up).** The prompt is withdrawn unconsumed on the overlay's
  rising edge (the heal-arm pattern, `ConnectView.swift:282-293`); I17 extended; coordinator cell.
- **R2-F8 (liveness dropped).** `sessionIsLive` gate input; the block is false while live; routed
  arrivals are classified live by the signed `manifest.meshID`, not the optional header.
- **R2-F9 (test gates).** Each unit's gate now names all six suites in
  `MeshLastMemberPhotoReviewTests.swift`, plus `ConnectReviewKeepTests`, `DisposableCameraSaveTests`,
  `DuressDecoyAndWipeTests`, `KeyCustodyBoundaryTests`, `ProximityRunSeamsTests`, with the specific
  inversions listed; `deletePhoto` on a held id is defined (refused).

**Partially accepted.**

- **R2-F7 (notApplied loop; persistent wall deferral).** Accepted: discards now need only the pending
  index; a failed answer keeps the review up with an inline message (I25); the gate has a
  can-be-shown input. Not adopted: releasing the discovery block after N failed attempts. Keep is
  disabled with a reason when the wall cannot be read, and Delete all and Not now always work, so
  there is no deadlock to escape; releasing the block would let a second session's photos pile
  into a review whose wall is known to be broken.
- **R2-F4 (kill mid-session forces a review of an ongoing session).** Accepted: the resume offer
  card is suppressed while the review blocks discovery, the custody-drain cost is stated (§4.8, §8,
  Q4), and the choice goes to the owner as Q7. Not adopted as the default: parking the photos as the
  resumed session's live roll. Evidence: the resume is not a separate path. The Friends visit runs
  the policy's fresh-search entry, whose `startJoin()` resets the session and nils
  `restoredSessionContext` (`MeshNetworkManager.swift:10546-10549`), and `startJoin` moves every
  live photo to the review bare (`:2344`); the re-link into the same mesh happens later, through the
  merge (`MeshSessionResumePresentation.swift` header). So a parked roll would be promoted at the
  first Friends visit anyway, unless `startJoin` learned which mesh a later merge will land in,
  which this design cannot verify. The default also matches the owner's words literally ("first on
  the next launch"), and today the same photos land on the wall with no choice at all.

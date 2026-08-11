# ``PrivateMediaStore``

At-rest AES-256-GCM-sealed photo storage for Fernlet's most personal images — friends' shared photos, meal photos, and gym progress (body) photos.

## Overview

PrivateMediaStore is one of Fernlet's sealed Layer-3 "S3" stores: the on-device home for photo
bytes that must never sit on disk in the clear and must never be reachable by the walled modules.
It holds three kinds of media, each with its own store type but one shared at-rest scheme:

- ``PrivateMediaStore`` — the friend **photowall cache**: photos peers share over the proximity
  mesh, owned by `MeshNetworkManager` in `ProximityKit`. Because its input is peer-supplied, this
  store carries the decompression-bomb defenses (a byte cap plus an ImageIO pixel-bounds check,
  ``PrivateMediaStore/isWithinSafePixelBounds(_:)``, that never decodes the full bitmap).
- ``MealPhotoStore`` — the user's **own photos**, keyed by caller-owned ids: meal photos
  (referenced from `Meal.photoID`) and, in a second instance, recipe photos keyed by recipe id.
  Photos are normalized on the way in (ImageIO thumbnail-path downscale to a bounded JPEG, so a
  48 MP camera original is bounded rather than rejected) and sealed before they touch disk.
- ``ProgressPhotoStore`` — the **gym progress-photo timeline** (Move tab). Composition, not
  duplication: bytes go through an inner ``MealPhotoStore``; this store adds the one thing
  progress photos otherwise lack — a dated, captioned index (``ProgressPhotoRecord`` entries) —
  and seals that index too, because a body-photo timeline's dates and notes are as personal as
  the pictures.

All three seal under a symmetric key supplied by ``PrivateMediaKeyProviding``, whose production
conformer ``KeychainPrivateMediaKeyProvider`` mints a random 256-bit key per
``KeychainPrivateMediaKeyProvider/Role`` and stores it in a fixed keychain row. The seal /
open / seal-then-write mechanics are one internal extension on that protocol (`gcmSeal`,
`gcmOpen`, `sealAndWrite` in `MediaAtRestCrypto.swift`) which all three stores call, replacing a
hand-rolled copy per store; the helpers are deliberately policy-free, so each store's fail-closed
decision stays at its own call site. Note this module does NOT use `FernletCrypto`/ColumnCrypto:
it seals via CryptoKit directly with its own keychain key. `UIImage` helpers for outbound
friend-photo sizing round out the module.

### Two media keys, not one (security-hardening Phase 5)

There used to be exactly one media key behind all four corpora, deliberately backup-restorable, so
the user's own meal and body photos were readable by anyone who could restore the device backup.
Phase 5 splits custody in two while leaving the friend wall byte-for-byte alone:

| Role | Keychain account | Custody | Corpora |
| --- | --- | --- | --- |
| ``KeychainPrivateMediaKeyProvider/Role/friendWall`` | `…private-media.contentKey` (original) | `AfterFirstUnlock`, non-sync — **backup-restorable, permanently** | the friend photowall cache |
| ``KeychainPrivateMediaKeyProvider/Role/ownPhotos`` | `…private-media.ownContentKey` (new) | `AfterFirstUnlock` today, **flips to `…ThisDeviceOnly` in step 5c** | meal, recipe, progress bytes + the progress index |

The wall keeps the original row precisely so nothing about it changes: no re-encryption, no
migration, and the survives-delete-all / never-deleted-by-wipe properties hold verbatim. The
`ownPhotos` row is the one that becomes device-bound, which is what makes bulk file + keychain
theft of the user's own photos worthless off-device.

Three pieces carry own photos across that split, all in `OwnPhotoKeyMigration.swift`:

- ``OwnPhotoCorpusLayout`` — the on-disk names of the own corpora, in one place, because a name
  that drifted would silently leave a corpus un-migrated (and therefore still backup-restorable)
  without failing any build.
- ``OwnPhotoKeyMigrator`` — the **eager, idempotent, crash-safe** re-seal pass, run once per launch
  off the main path. Eager is not an optimization: a lazily-migrated corpus leaves every photo the
  user never reopens under the backup-restorable key forever.
- ``OwnPhotoMigrationLatch`` — the persisted, one-way, fail-closed proof that nothing is left under
  the old key. Both the 5c binding flip and the removal of the dual-open fallback are gated on it.

Until the latch is set, the own read paths (``MealPhotoStore`` and ``ProgressPhotoStore``, via an
injected `legacyKeyProvider`) **dual-open**: own key first, then the pre-split key, re-sealing under
the own key on access. That fallback only ever trusts bytes that GCM-open under a key this app
owns, so it is not a widening of the legacy-plaintext rule below — plaintext is still refused
exactly where it was before.

### The escrow seam (what makes device-binding survivable)

Device-binding the own key would otherwise mean "your photos die with the phone", so step 5b added
an opt-in **own-photo escrow backup** in the app target (`SealedPhotoBackupService` +
`OwnPhotoBackupCoordinator`): one AES-GCM-sealed CloudKit record per photo id under the user's
backup-escrow key, plus a sealed per-corpus manifest written last as the commit marker. This module
supplies only the local seam it needs, and each piece is shaped by a hazard:

- ``MealPhotoStore/storedPhotoIDs()`` — the corpus has no index of its own (ownership lives in
  `Meal.photoID` / the recipe id), so the directory IS the id set an upload must enumerate.
- ``MealPhotoStore/restoreSealedPhoto(_:forID:)`` (and ``ProgressPhotoStore/restoreSealedPhoto(_:forID:)``)
  — seals restored bytes **as-is**, skipping normalization. A second lossy re-encode would change
  the SHA-256 the manifest committed, and every later backup would then see the whole restored
  corpus as changed and re-upload it forever. Only ever hand it bytes that already authenticated
  under an escrow-sealed record.
- ``MealPhotoStore/isEmptyForRestore()`` / ``ProgressPhotoStore/isEmptyForRestore()`` — the
  per-corpus no-clobber gate, deliberately **file presence**, not "no ids I can parse": a corpus
  holding bytes this build cannot name is still in use. An unlistable directory reads as NOT empty
  (fail closed → no restore). The progress corpus additionally requires its index to be absent.
- ``ProgressPhotoStore/backupIndexPayload()`` / ``ProgressPhotoStore/restoreIndexPayload(_:)`` — the
  timeline index travels with the bytes (inside the manifest), because body photos restored without
  their dates and captions render as an invisible timeline. Export answers **nil** for a
  present-but-unreadable index so the caller skips the corpus rather than uploading "you have no
  photos" over a good copy; import refuses when an index already exists.

### Position relative to the S3 wall

In `FernletKit/Package.swift` this target depends only on `FernletFoundation` and
`FernletDomainModel` (which supplies the `FriendPhotoPayload` wire DTO). It sits on the
**protected side** of the wall: the walled consumers `AIProviders` and `CloudKitSync` omit every `Private*` store from
their dependency lists by construction, so `import PrivateMediaStore` there is a hard build
error under `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` (see `Scripts/spm-wall-check.sh`
and `FernletTests/S3BoundaryTests`). Its own dependents are `ProximityKit` (the mesh manager's
photowall cache) and the app target (`FernletStore` owns the meal/recipe/progress stores).

### Fail-closed invariants

Every store here fails **closed**, and changes must preserve that:

- **No key ⇒ no plaintext write.** When ``PrivateMediaKeyProviding/mediaKey()`` returns nil,
  bytes are dropped (or the whole save refused) rather than written unsealed.
- **Unopenable bytes read as missing.** Bytes that neither GCM-open nor qualify as trusted
  legacy plaintext resolve to nil — never ciphertext or garbage handed to the UI.
- **Legacy plaintext is upgraded only where it can legitimately exist.** The original meal-photo
  store and the photowall predate sealing, so a plaintext file that passes the image-bounds gate
  is re-sealed in place on first read. Stores born sealed (recipe photos, body photos, the
  progress index) disable that path: an unsealed file dropped at a valid path (tampered restore,
  shared-container write) is refused, not laundered into authentic ciphertext.
- **A present-but-unreadable index is never clobbered.** ``ProgressPhotoStore`` mutations refuse
  to rewrite an index they cannot decode, since overwriting would silently drop a still-sealed
  timeline and permanently orphan its photo files.
- **Restored bytes are authenticated bytes.** ``MealPhotoStore/restoreSealedPhoto(_:forID:)`` is a
  restore seam, not a general write path: it skips normalization, so the only thing standing between
  it and laundering is the caller's obligation to pass bytes that opened from an escrow-sealed
  record whose manifest content hash matched. The image-bounds check it makes is a backstop.
- **Delete-all coverage.** Meal, recipe, and progress photos are wiped by "delete everything";
  the friend photowall deliberately survives it (friends' photos are the friends' gift, removed
  one at a time) — which is why
  ``KeychainPrivateMediaKeyProvider/deleteKeychainRowForWipe()`` intentionally has no callers.
  **Neither** keychain row is deleted by the wipe: the friend key because the wall it protects
  survives, the own key because its stores are emptied instead (an empty store's key protects
  nothing, and deleting the row would strand anything captured between the wipe and relaunch).
  The `invalidateEncryptionKeyCache()` seams drop provider-cached keys after a wipe so RAM
  matches the keychain (see `Docs/PrivacyWipeCoverage.md`).

### Concurrency

Everything here is nonisolated: plain structs plus one non-`Sendable` class
(``KeychainPrivateMediaKeyProvider``, whose cached key is unsynchronized). Safety is by
confinement — each store and its key provider live inside one isolation domain, in practice the
main actor of the owner (`MeshNetworkManager` or the app's `FernletStore`). Do not share a
provider instance across isolation domains.

## Topics

### Sealed photo stores

- ``PrivateMediaStore/PrivateMediaStore``
- ``MealPhotoStore``
- ``ProgressPhotoStore``
- ``ProgressPhotoRecord``

### At-rest key management

- ``PrivateMediaKeyProviding``
- ``KeychainPrivateMediaKeyProvider``

### Own-photo key migration

- ``OwnPhotoCorpusLayout``
- ``OwnPhotoSealedLocations``
- ``OwnPhotoKeyMigrator``
- ``OwnPhotoKeyMigrationResult``
- ``OwnPhotoMigrationLatch``

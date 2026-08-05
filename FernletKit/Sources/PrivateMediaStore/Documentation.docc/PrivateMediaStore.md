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

All three seal under a single symmetric key supplied by ``PrivateMediaKeyProviding``, whose
production conformer ``KeychainPrivateMediaKeyProvider`` mints one random 256-bit key and stores
it in a fixed keychain row — backup-restorable (`kSecAttrAccessibleAfterFirstUnlock`) so an
iCloud device backup restored onto a new phone can still open the cache it carried. The seal /
open / seal-then-write mechanics are one internal extension on that protocol (`gcmSeal`,
`gcmOpen`, `sealAndWrite` in `MediaAtRestCrypto.swift`) which all three stores call, replacing a
hand-rolled copy per store; the helpers are deliberately policy-free, so each store's fail-closed
decision stays at its own call site. Note this module does NOT use `FernletCrypto`/ColumnCrypto:
it seals via CryptoKit directly with its own keychain key. `UIImage` helpers for outbound
friend-photo sizing round out the module.

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
- **Delete-all coverage.** Meal, recipe, and progress photos are wiped by "delete everything";
  the friend photowall deliberately survives it (friends' photos are the friends' gift, removed
  one at a time) — which is why
  ``KeychainPrivateMediaKeyProvider/deleteKeychainRowForWipe()`` intentionally has no callers.
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

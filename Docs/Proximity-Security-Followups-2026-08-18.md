# Proximity security follow-ups — deferred from the 2026-08-18 mesh commit/authorization round

Two items were deliberately kept OUT of the guard commits because they change wire or key-exchange
surface. Both are recorded here with their deadline so they are not lost.

**Status 2026-09-05: item 1 is CLOSED** — discharged by P5 item 13's routed friend-photo path, not by
the field it proposed (see below). **Item 2 is still open.**

The referenced tracker `Docs/Proximity-Mesh-Redesign-2026-07-10.md` does not exist in this tree;
this file is its replacement for these two items.

## 1. Friend-photo author signature (from M6) — **CLOSED by P5 item 13 (2026-09-05)**

**The problem, as it stood.** `FriendPhotoPayload.senderName` / `senderFingerprint` /
`senderSigningPublicKey` were an **unsigned claim about a third party**: `sendRequestedPhotos`
relayed other peers' cached photos by design, so the envelope signature authenticated only the
relayer. The 2026-08-18 fix (`MeshNetworkManager.photoAuthorIsAcceptable`) made the claim *usable* —
block checks on both parties, fingerprint ↔ key self-consistency, a "known to this session" clause —
but it could not make it *provable*.

**What discharged it.** P5 item 13 moved friend photos onto the routed store, which answers the
question at a different layer than the proposed `authorSignature` field did:

- **`MeshRoutedManifest` is signed by the ORIGIN** over the item id, type token, content hash, size,
  destination set and expiry (`FernletCryptoPurpose.Signature.meshRoutedManifestV1`), and a courier
  forwards the origin's exact signed object rather than re-signing it. Attribution is therefore
  provable end to end, not one hop.
- **`MeshNetworkManager.routedProjectionAuthor(for:)`** resolves the wall entry's fingerprint and
  signing key from the **admission ledger** (`admissions − removals`), never from anything the
  payload carried — the routed photo body carries no identity claim at all. `MeshRoutedItemDelivery`
  refuses a body whose id is not the item id the origin signed.
- The three functions this item named are **gone**: `sendRequestedPhotos`, `photoAuthorIsAcceptable`
  and `handlePhotoManifest` (with its `manifestAnnouncedPhotoAuthors` relaxation) were deleted with
  the transport they served, and `PayloadType.friendPhoto` / `.friendPhotoManifest` /
  `.friendPhotoRequest` are frozen and parked. `FriendPhotoPayload` itself is alive — it is what the
  wall and the projection speak — but it is no longer a wire type on the mesh path.

**Therefore: no `authorSignature` field, and no wire-compat flip is owed.** The additive-optional
plan above is superseded rather than deferred; adding it now would be a second attribution source
beside the manifest's signature, which is exactly the drift this file was written to prevent. The
cells are `theWallEntryCarriesTheOriginsAttributionNotTheCouriers` and
`aProjectionWithNoResolvableOriginRefusesAndKeepsCustody` in `MeshRoutedPhotoDeliveryTests`.

**What remains open, and is P6's, not this file's:** `HeartDropService` and the recipe/clothing
share paths still carry their own author claims and are untouched by item 13.

## 2. Sealed-introduction key exchange: 3DH / static-static (from H3) — NO DEADLINE, DESIGN ITEM

`IdentityService.seal`/`open` is **ephemeral-static ECIES**. A successful `open` proves only that
the sealer knew the RECIPIENT's public KA key; the sender's static key enters as a public HKDF
`sharedInfo`/AAD input, never as a key-agreement input. Anyone holding our published KA key can mint
a wrapper that opens.

The 2026-08-18 fix binds the inner envelope's `senderKeyAgreementPublicKey` to
`sealedIntroductionPeerKey` (`ProximityCoordinator.sealedIntroductionSenderMatches`), which closes
the same door at **zero wire cost**.

Reworking `seal`/`open` to static-static or 3DH would make sender authentication cryptographic
rather than checked, but it is a wire-format change across **every** sealed payload type. Do it only
as part of a deliberate, schema-versioned wire break — not as a follow-up patch.

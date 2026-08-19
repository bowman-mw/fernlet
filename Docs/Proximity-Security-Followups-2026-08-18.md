# Proximity security follow-ups — deferred from the 2026-08-18 mesh commit/authorization round

Two items were deliberately kept OUT of the guard commits because they change wire or key-exchange
surface. Both are recorded here with their deadline so they are not lost.

The referenced tracker `Docs/Proximity-Mesh-Redesign-2026-07-10.md` does not exist in this tree;
this file is its replacement for these two items.

## 1. Friend-photo author signature (from M6) — NEXT RELEASE

`FriendPhotoPayload.senderName` / `senderFingerprint` / `senderSigningPublicKey` are an **unsigned
claim about a third party**: `sendRequestedPhotos` relays other peers' cached photos by design, so
the envelope signature authenticates only the relayer.

The 2026-08-18 fix (`MeshNetworkManager.photoAuthorIsAcceptable`) makes the claim *usable* —
block checks on both parties, fingerprint ↔ key self-consistency, and a "known to this session"
clause — but it cannot make it *provable*.

**The durable fix:** add `authorSignature: Data?` to `FriendPhotoPayload`, signed by the author over
the canonical bytes of `(id ‖ SHA256(imageData or encryptedImageData) ‖ senderSigningPublicKey ‖
addedAt)`, produced in `addPhoto` and verified inside `photoAuthorIsAcceptable`. Follow the one-hop
verification pattern `ModerationReportRelay.verifiedRows` already uses.

**Wire-compat rules (non-negotiable):**
- Additive-**optional** field, no format-version bump — the same rule as `SharedRecipePayload.steps`.
- Optional-for-compat in this release, **required in the next**. Record that flip when it happens.
- Must be covered by the existing decode-compat pattern (`ProximityRecordDecodeCompatTests`) or it
  is a hard interop break.

Once required, the `manifestAnnouncedPhotoAuthors` relaxation in `handlePhotoManifest` can be
dropped — the signature subsumes it.

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

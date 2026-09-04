# Cryptographic Domain Separation

**Status:** Enforced. The registry is
[`FernletKit/Sources/FernletCrypto/CryptographicPurpose.swift`](../FernletKit/Sources/FernletCrypto/CryptographicPurpose.swift).
Mechanical enforcement is split across two suites that check different things and are easy to
confuse:
[`CryptographicPurposeBoundaryTests`](../Tests/FernletTests/CryptographicPurposeBoundaryTests.swift)
proves every purpose is **used** (a raw primitive call names one, and the named one matches the bytes
its serializer produces), and
[`CryptographicDomainSeparationTests`](../Tests/FernletTests/CryptographicDomainSeparationTests.swift)
proves the registry's values are **usable** for separation (distinct spellings, distinct derived
keys, non-interchangeable authenticated data). This document is the human half.

**Sibling walls:** the [S3 privacy wall](SPM-Module-Carveup-Plan.md) answers *"which code may touch
sealed data?"*; the [no-tracking wall](No-Tracking-Wall.md) answers *"where may bytes go at all?"*
This one answers a third, narrower question: *"once bytes are encrypted, signed, or hashed, what
stops one context's output being accepted by another?"*

**History.** Domain separation landed in `91c3956` (2026-08-26) and was repaired by `216f1ba` and
`500bee3` the following day. This document was written on 2026-08-27; the round shipped without one,
which is why several of the notes below read as archaeology rather than design.

---

## 1. What a purpose is

A `CryptographicPurpose` is an opaque, immutable string used as a **domain tag**: an extra input,
distinct per context, mixed into a key derivation, an authenticated-data blob, a MAC message, a hash
preimage, or a signature transcript. Its job is to make an output from one context useless in
another.

Concretely, without it:

- The journal, worry-box, menstrual and intimacy columns all derive their encryption key from the
  **same** unlocked content key. Nothing but the HKDF `info` separates them, so a shared domain makes
  every intimacy row readable by the journal's key.
- The heart-drop day tag and the presence epoch tag are both HMACs over time-derived values under a
  shared pair key. A shared domain makes one replayable as the other.
- Every `fernlet.canonical.*` signature is Ed25519 over a serialized struct under the same identity
  key. A shared domain lets a signature collected in one protocol be presented in another.

The type is deliberately hard to misuse:

- **The initializer is `fileprivate`.** No call site can construct a purpose. Production code selects
  a reviewed constant from `FernletCryptoPurpose`, which is the point — a domain assembled at a call
  site is a domain nobody reviewed, and one assembled from *peer or user input* is an attacker
  choosing where their bytes are accepted.
- **It carries its transcript framing.** See §4.
- **It exposes only `rawValue` and `data`.** There is no `init(rawValue:)`, no `Codable`
  conformance, and no decoding path — a purpose can never arrive over the wire.

## 2. The rule: purpose values are frozen protocol data

> **A purpose spelling is an input to a shipped key, digest, or signature. Changing one changes what
> it protects. Treat every spelling in the registry as immutable.**

Three specific prohibitions follow, and each has a different failure mode:

**Never localize a purpose.** This is the token half of the token/display separation the
[localization wall](../Tests/FernletTests/LocalizationBoundaryTests.swift) enforces. A localized
domain derives a different key in every language, so a user who changes their device language loses
every sealed column — silently, because a failed open is indistinguishable from a row that was never
written. No purpose is a display string and none ever will be; they are ASCII protocol tokens and
never reach a screen.

**Never assemble a purpose from input.** Not from a peer's advertised name, not from a user's text,
not from a filename. A domain the other side chooses is not a domain. The `fileprivate` initializer
makes this structural rather than a convention.

**Never rename a purpose casually.** "Casually" is doing real work in that sentence: a rename is a
FORMAT CHANGE, and it needs the same care as any other. The registry's own comment is the short
version — *"A new spelling therefore needs an explicit versioned write format and a legacy read path
at its consumer."*

The tell that a rename is wrong is usually that it looks like an improvement.
`com.fernlet.sealed-backup` is not spelled like its neighbours; `journal-narrative`, `worry-box`,
`menstrual-narrative` and `intimacy-log` carry no namespace or version at all. Every one of those is
load-bearing: they are the exact strings that derive the keys for sealed data already on users'
devices. Tidying them orphans that data permanently — there is no migration, because the old key
cannot be re-derived from the new name.

## 3. The domain inventory

47 purposes across five families, generated from the registry on 2026-08-27. "Consumer" lists the
files that name each constant, so an unused entry is visible as an empty cell.

`CryptographicDomainSeparationTests.theInventoryCoversEveryDeclaredPurpose()` reads the registry off
disk and requires its own pinned list to match, so a purpose added without a test line fails loudly.
This table is not machine-checked and can drift; the test is the authority on the SET, this document
on the reasoning.

#### Signature

| Constant | Spelling | Framing | Consumer |
|---|---|---|---|
| `identityEnvelopeV2` | `fernlet.canonical.identity-envelope.v2` | `.lengthPrefixed` | `CanonicalSignatureSerializer`, `FernletIdentityEnvelope` |
| `identityEnvelopeLegacyV1` | `fernlet.canonical.identity-envelope.v1` | `.absent` | `FernletIdentityEnvelope` |
| `meshAdmissionTokenV2` | `fernlet.canonical.mesh-admission-token.v2` | `.lengthPrefixed` | `CanonicalSignatureSerializer`, `MeshPayloads` |
| `meshAdmissionTokenLegacyV1` | `fernlet.canonical.mesh-admission-token.v1` | `.absent` | `MeshPayloads` |
| `activityDescriptorV2` | `fernlet.canonical.activity-descriptor.v2` | `.lengthPrefixed` | `CanonicalSignatureSerializer` |
| `activityJoinTokenV2` | `fernlet.canonical.activity-join-token.v2` | `.lengthPrefixed` | `ActivityPayloads`, `CanonicalSignatureSerializer` |
| `activityRosterSnapshotV2` | `fernlet.canonical.activity-roster-snapshot.v2` | `.lengthPrefixed` | `ActivityPayloads`, `CanonicalSignatureSerializer` |
| `moderationReportV2` | `fernlet.canonical.moderation-report.v2` | `.lengthPrefixed` | `CanonicalSignatureSerializer`, `ModerationReportRelay` |
| `meshProbeChannelIntroductionV1` | `fernlet.mesh.probe.channel-introduction.v1` | `.rawPrefix` | `NetworkMeshFeasibilityProbe` |
| `proximityQRIdentityV1` | `fernlet.verify.qr.v1` | `.rawPrefix` | `ProximityVerification` |
| `proximityQRResponseV1` | `fernlet.verify.response.v1` | `.rawPrefix` | `CoachVerificationCeremony`, `DuressRecoveryCoordinator`, `MeshNetworkManager`, `ProximityVerification` |
| `duressRecoveryRequestV1` | `fernlet.duress.recovery.request.v1` | `.rawPrefix` | `DuressRecoveryCoordinator` |
| `duressRecoveryReplyV1` | `fernlet.duress.recovery.reply.v1` | `.rawPrefix` | `DuressRecoveryCoordinator` |
| `meshRoutedManifestV1` | `fernlet.mesh.routed-manifest.v1` | `.lengthPrefixed` | `CanonicalSignatureSerializer`, `MeshRoutedManifest`, `MeshRoutedManifestVerifier` |
| `meshRoutedChunkV1` | `fernlet.mesh.routed-chunk.v1` | `.lengthPrefixed` | `CanonicalSignatureSerializer`, `MeshChunker`, `MeshChunkVerifier` |
| `meshCustodyReceiptV1` | `fernlet.mesh.custody-receipt.v1` | `.lengthPrefixed` | `CanonicalSignatureSerializer`, `MeshCustodyReceipt`, `MeshCustodyReceiptVerifier` |

#### KeyDerivation

| Constant | Spelling | Consumer |
|---|---|---|
| `sealedBackupLegacyV1` | `com.fernlet.sealed-backup` | `IdentityService` |
| `sealedBackupV2` | `com.fernlet.sealed-backup.v2` | `IdentityService` |
| `proximityTransportV1` | `fernlet.proximity.v1` | `IdentityService` |
| `heartDropPairV1` | `fernlet.heartdrop.v1` | `IdentityService` |
| `presencePairV1` | `fernlet.presence.tag.v1` | `IdentityService` |
| `meshGroupKeyWrapV1` | `fernlet.mesh.groupkey.v1` | `IdentityService` |
| `meshRoutedContentKeyWrapV1` | `fernlet.mesh.routed.content-key.v1` | `MeshRoutedContentKeyWrapper` |
| `meshRoutedStoreV1` | `fernlet.mesh.routed-store.v1` | `MeshRoutedStore` (the at-rest seal for `MeshRoutedIndex.sealed` and every `MeshRoutedChunks/<uuid>.chunk` file) |
| `heartDropOuterSealV1` | `fernlet.heartdrop.seal.v1` | `HeartDropSealer` |
| `lockScryptWrappingV1` | `fernlet.lock.scrypt.wrapping.v1` | — |
| `journalNarrativeLegacyV1` | `journal-narrative` | `ColumnCrypto`, `JournalNarrativeRepository` |
| `worryNarrativeLegacyV1` | `worry-box` | `ColumnCrypto`, `WorryNarrativeRepository` |
| `menstrualNarrativeLegacyV1` | `menstrual-narrative` | `ColumnCrypto`, `MenstrualNarrativeRepository` |
| `intimacyLogLegacyV1` | `intimacy-log` | `ColumnCrypto`, `IntimacyLogRepository` |

#### HMAC

| Constant | Spelling | Consumer |
|---|---|---|
| `heartDropDayTagV1` | `fernlet.heartdrop.day.v1` | `IdentityService` |
| `presenceEpochTagV1` | `fernlet.presence.epoch.v1` | `IdentityService` |

#### AEAD

| Constant | Spelling | Consumer |
|---|---|---|
| `sealedBackupV2` | `fernlet.sealed-backup.aad.v2` | `SealedBackupService` |
| `sealedPhotoBackupV3` | `fernlet.sealed-photo.aad.v3` | `SealedPhotoBackupService` |
| `proximityTransportV2` | `fernlet.proximity.transport.aead.v2` | `IdentityService` |
| `meshGroupKeyWrapV2` | `fernlet.mesh.groupkey.wrap.aead.v2` | `IdentityService` |
| `meshGroupPhotoV2` | `fernlet.mesh.group-photo.aead.v2` | `MeshNetworkManager` |
| `meshEncryptedMetadataV2` | `fernlet.mesh.encrypted-metadata.aead.v2` | `MeshNetworkManager` |
| `meshRoutedContentKeyWrapV1` | `fernlet.mesh.routed.content-key.wrap.aead.v1` | `MeshRoutedContentKeyWrapper` |
| `meshRoutedItemV1` | `fernlet.mesh.routed.item.aead.v1` | — (reserved; P5 item 6 / P6 — item 2 chunks an opaque blob and deliberately does not seal, because an AEAD seal mints a random nonce and a sealing chunker could not be goldened) |
| `heartDropSidecarV2` | `fernlet.heartdrop.sidecar.aead.v2` | `HeartDropSidecarKey` |
| `pendingNarrativeBufferV2` | `fernlet.pending-narrative-buffer.aead.v2` | `PendingNarrativeBuffer` |
| `lockContentKeyWrapV2` | `fernlet.lock.content-key-wrap.aead.v2` | `FernletLockService` |
| `columnDeviceBoundV3` | `fernlet.private-column.device-bound.aead.v3` | — |
| `privateFriendPhotoImageV2` | `fernlet.private-media.friend-photo.image.aead.v2` | `PrivateMediaStore`, `MediaAtRestFormatMigration` |
| `privateFriendPhotoThumbnailV2` | `fernlet.private-media.friend-photo.thumbnail.aead.v2` | `PrivateMediaStore`, `MediaAtRestFormatMigration` |
| `privateFriendPhotoIndexV2` | `fernlet.private-media.friend-photo.index.aead.v2` | `PrivateMediaStore`, `MediaAtRestFormatMigration` |
| `mealPhotoV2` | `fernlet.private-media.meal-photo.aead.v2` | `MealPhotoStore`, `OwnPhotoBackupCoordinator`, `OwnPhotoKeyMigration`, `MediaAtRestFormatMigration` |
| `recipePhotoV2` | `fernlet.private-media.recipe-photo.aead.v2` | `FernletStore`, `OwnPhotoBackupCoordinator`, `OwnPhotoKeyMigration`, `MediaAtRestFormatMigration` |
| `progressPhotoV2` | `fernlet.private-media.progress-photo.aead.v2` | `OwnPhotoKeyMigration`, `ProgressPhotoStore`, `MediaAtRestFormatMigration` |
| `progressPhotoIndexV2` | `fernlet.private-media.progress-photo.index.aead.v2` | `OwnPhotoKeyMigration`, `ProgressPhotoStore`, `MediaAtRestFormatMigration` |

#### Hash

| Constant | Spelling | Consumer |
|---|---|---|
| `sealedPhotoContentV2` | `fernlet.sealed-photo.content-hash.v2` | `SealedPhotoBackupService` |
| `lockVerifierV2` | `fernlet.lock.verifier.v2` | `FernletLockService` |
| `meshRoutedContentV1` | `fernlet.mesh.routed-content.hash.v1` | `MeshRoutedContentDigest` (the whole sealed blob a manifest's `contentHash` measures) |
| `meshRoutedChunkV1` | `fernlet.mesh.routed-chunk.hash.v1` | `MeshRoutedContentDigest` (one chunk's payload — its own domain so a one-chunk item's two digests are not interchangeable) |
| `meshRoutedChunkIDV1` | `fernlet.mesh.routed-chunk-id.hash.v1` | `MeshRoutedContentDigest` (the derived replay-window id item 12 keys on) |
| `meshCustodyReceiptIDV1` | `fernlet.mesh.custody-receipt-id.hash.v1` | `MeshCustodyReceipt` (the derived dedup id — `(itemID, origin, custodian)`, excluding both the hedged signature and `custodiedAt`, so a re-mint of the same claim is the same id) |
| `recoveryContentKeyV1` | `fernlet.lock.recovery.contentkey.v1` | `FernletLockService` |

### A drift note, 2026-09-03 (P5 item 3)

Three purposes were added together and are stated here because each sits one character from a
neighbour:

- `fernlet.mesh.custody-receipt.v1` (Signature) vs `fernlet.mesh.custody-receipt-id.hash.v1` (Hash):
  they diverge at `.` vs `-`, so neither prefixes the other. One tags the bytes that are SIGNED, the
  other the bytes that are hashed into a derived dedup id.
- `fernlet.mesh.routed-store.v1` (KeyDerivation) vs `fernlet.mesh.routed-manifest.v1`,
  `fernlet.mesh.routed-chunk.v1`, `fernlet.mesh.routed-content.hash.v1` and
  `fernlet.mesh.routed.content-key.v1`: they diverge at `-s` vs `-m`/`-c`/`.`. It is the at-rest seal
  for a whole surface, and **changing its spelling orphans every sealed routed file already on disk**
  — a routed chunk file is other people's ciphertext this device promised to hold.
- The routed store's AAD is purpose ‖ install binding with **no file name in it**, so under one key
  and one install every `MeshRoutedChunks/<uuid>.chunk` blob authenticates in any slot. The binding of
  a file to a slot is restored by comparing the opened chunk's descriptor and payload length to the
  index's, on every read — a comparison that is not redundant and must not be removed as such.

### Two notes on the inventory

**`meshProbeChannelIntroductionV1` is deliberately not a production domain.** It belongs to the
Network.framework feasibility spike. Keeping it distinct is what stops the device probe becoming a
signing oracle for a shipping protocol: the identity key signs both, so a shared domain would let a
transcript collected from the probe be replayed as a real mesh admission.

**The four un-namespaced KDF spellings** — `journal-narrative`, `worry-box`, `menstrual-narrative`,
`intimacy-log` — predate the registry. `ColumnCrypto.init(label:)` exists solely to map those four
strings back to their typed constants for fixtures, and it fails closed on anything else: an unknown
label hits `assertionFailure` rather than deriving a silently orphaned key.

**The table predates P2–P4's mesh signature purposes (note added 2026-09-03).** Eight spellings
the test inventories are not in the Signature table above — `channel-introduction`, the three
signed membership records (`member-departure`, `member-removal`, `terminated`; the admission frame
reuses `meshAdmissionTokenV2`, which is listed), `inventory-digest`, `epoch-heads`,
`removal-proposal` and `removal-vote` — because those frame commits added registry constants and
`allDomains` rows without a row here.
P5 item 1 added only its own four routed rows (one signature, one derivation, two AEAD) and P5 item
2 only its own four (one signature, three hash); both record the drift rather than backfilling it,
and the test remains the authority on the SET.

**`meshInventoryDigestV1` is absent from the Hash table for the same reason** (note added
2026-09-03, P5 item 2): P3 item 3 added the constant and its `allDomains` row without a row here.
Item 2's three routed hash rows above are listed; the inventory's is still owed.

## 4. Transcript framing

Signature purposes carry a `TranscriptFraming` because Fernlet's transcript builders do not agree on
one byte layout, and **they must not be forced to** — the layouts are already signed by shipped
peers, so the check adapts to the format rather than the format to the check.

| Framing | Layout | Used by |
|---|---|---|
| `.rawPrefix` | `domain ‖ payload` — the domain's bytes verbatim, first | The `fernlet.verify.*`, `fernlet.duress.*` and probe transcripts, which concatenate directly |
| `.lengthPrefixed` | `<8-byte big-endian count> ‖ domain ‖ payload` | Every `fernlet.canonical.*` purpose. `CanonicalByteWriter` length-prefixes **every** variable-length field, and the domain is one of them |
| `.absent` | no domain at all | The two legacy signature read paths only. Never a write format |

`signingBytes(_:)` checks this **positionally**, not by substring, and that distinction is the whole
guard: a substring search would accept a transcript carrying the domain in an attacker-chosen field
and still reach the identity key. A length-prefixed purpose therefore rejects its own raw spelling,
which is exactly what `CryptographicPurposeBoundaryTests` asserts.

**This is what `91c3956` got wrong, and it is worth recording.** The registry declared `.rawPrefix`
for the canonical purposes while `CanonicalByteWriter` was writing them length-prefixed. Every
canonical signature then threw at the signing boundary and every canonical verify returned false —
which reached the suite as well over a hundred unexplained failures rather than one named cause, and
looked enough like stale fixtures to be nearly dismissed as such. `216f1ba` fixed the framing;
`canonicalSerializerTranscriptsMatchTheirDeclaredFraming()` is the test that would have named it in
one line.

The related trap: `.absent` accepts **everything**, including an empty transcript. That is correct
for reading signatures shipped peers made before any domain existed, and catastrophic for a write
format. `absentFramingAcceptsAnythingByDesign()` pins the set at exactly the two known entries, so a
third one cannot appear quietly.

## 5. Versioned formats, and what still reads older bytes

Every read path below is compatibility, not choice. Nothing writes a legacy format — and after the
crypto standardization round, the at-rest surfaces no longer READ one either: what remains here is
the wire and the sealed-backup key, where the bytes come from a peer or from a cloud copy rather
than from this device's disk.

| Format | Current write | Older readers still live | Where |
|---|---|---|---|
| Sealed column blob | **v3**: `0x03 ‖ ChaChaPoly(nonce‖ct‖tag)` with `purpose ‖ deviceBindingID` as AAD | **None.** v2 (`0x02`, binding-only AAD) and legacy (bare `combined`, no version byte) are CLASSIFIED and refused, never opened | `ColumnCrypto.openBlob` requires `0x03`; anything else throws `SealedColumnOpenError.retiredFormat(_:)` |
| Identity envelope signature | `identityEnvelopeV2` over the binary canonical serializer | `identityEnvelopeLegacyV1` over the old `.sortedKeys`/`.iso8601` JSON, selected by `schemaVersion` | `FernletIdentityEnvelope.verify` |
| Mesh admission token | `meshAdmissionTokenV2` | `meshAdmissionTokenLegacyV1`, tried as a **fallback** after v2 fails | `MeshPayloads` |
| Sealed backup key | `sealedBackupV2` info + a real salt | `sealedBackupLegacyV1` info + an empty salt, selected by `formatVersion` | `IdentityService.deriveSealedBackupKey` |

Three things about the sealed-column table row are easy to miss, and the first two were true in the
opposite direction until the crypto standardization round:

- **There is no fallback left.** Phase 3 deleted both lower rungs (owner decision D2 took v2), and
  the migrator that converted through them went in the same change — a healer that can no longer
  heal is worse than either alone. The classifier `ColumnCryptoStoredFormat` outlives them so the
  refusal can name what it refused.
- **`ColumnCrypto` now fails CLOSED on the write side too.** It used to write the legacy unbound
  format when no device binding was available, on the argument that binding is defense-in-depth and
  never a gate. `DeviceBindingID.current()` returns nil on any keychain read/add failure and the
  binding row is `AfterFirstUnlockThisDeviceOnly`, so the pre-first-unlock window alone could mint a
  fresh legacy blob at any time — which is why every format-census zero was "a moment, not a latch".
  Owner decision D4 closed it: `sealPlaintextV3Strict` throws
  `SealedColumnStrictSealError.bindingUnavailable`, and a sealed save can now FAIL where it used to
  succeed in the wrong format. That is the accepted cost.
- **The retryable case survives, and the distinction is load-bearing.** A transient keychain read
  *error* is not an authoritative absence: it surfaces as `DeviceBindingID.ReadError` rather than an
  authentication failure or a terminal `SealedColumnOpenError`, so a keychain hiccup reads as "try
  again" and never as corruption. `currentForOpen()` exists for exactly that split.

**One resolution was lost with the rungs, and it is stated rather than glossed.** The unconditional
legacy fallback used to disambiguate the ~1-in-256 legacy blob whose first ciphertext byte happens
to equal `0x02` or `0x03` — by *attempting* the open, which is something no byte-only classifier can
do. The keyed migrator pass resolved the remainder. With both gone, a `0x02` collision is reported
as a retired v2 row (true enough — it is unopenable either way) and a `0x03` collision is tried as
V3 and fails AUTHENTICATION, unable to name itself. It is the one refusal in the tree that cannot
say what it found, and it is pinned as such in `ColumnCryptoDeviceBindingTests`.

## 6. Adding a new domain

1. **Add the constant to `FernletCryptoPurpose`**, in the family that matches how it is consumed
   (`Signature`, `KeyDerivation`, `HMAC`, `AEAD`, `Hash`). The family is documentation, not
   behaviour — but a purpose filed under the wrong one is a purpose nobody will find.
2. **Choose a spelling that prefixes nothing and that nothing prefixes.** `signingBytes` matches by
   `starts(with:)`, and several call sites build AAD by bare concatenation (`purpose.data +
   binding`), which is ambiguous exactly when one domain prefixes another. Follow the
   `fernlet.<area>.<thing>.v<N>` convention and end with the version; that makes a prefix relation
   nearly impossible by construction.
3. **Give it a version suffix even for a first version.** `…v1` costs nothing now and is the
   difference between adding a v2 later and inventing a naming scheme under pressure.
4. **If it is a signature purpose, set its framing to match the serializer you will actually use** —
   `.lengthPrefixed` for anything going through `CanonicalByteWriter`, `.rawPrefix` for a direct
   concatenation. Never `.absent`: that is a read-compatibility marker, and a new format has nothing
   to be compatible with.
5. **Add a `Domain(…)` line to `CryptographicDomainSeparationTests.allDomains`.** The suite will
   tell you if you forget — `theInventoryCoversEveryDeclaredPurpose()` fails with the missing
   spelling — but adding it in the same commit is what makes the all-pairs separation checks cover
   the new entry from its first day.
6. **Add a row to §3 of this document**, including its consumer.
7. **Get it reviewed as a format change, not as a constant.** The reviewer's checklist:
   - Is the spelling frozen from this commit forward? (Yes, once anything is written under it.)
   - Does anything already persisted, signed, or sent use a spelling this one prefixes?
   - Is it reachable from user or peer input anywhere? (It must not be.)
   - If it replaces an existing domain, where is the legacy read path, and what version marker
     selects between them?
   - Does the primitive call actually pass it — as `info`, as `authenticating:`, or into the
     transcript — rather than merely mentioning it nearby? See §7 for why that question needs
     asking.

## 7. What the boundary tests catch, and what they cannot

### `CryptographicPurposeBoundaryTests` — a grep wall

It scans the five shipping roots (see below) for nine primitive markers (`signature(for:`,
`isValidSignature(`, `hkdfDerivedSymmetricKey`, `HKDF<`, `HMAC<`, `ChaChaPoly.seal/open`,
`AES.GCM.seal/open`) and requires a purpose to be named within an asymmetric window: three lines
above the call, six below (a multi-line call names its purpose inside its own argument list, which
sits below the opening line).

**What it catches:** a newly added primitive call that names no purpose at all — the case where a
reviewer would have to remember the policy.

**What it cannot catch, and never will:**

- **Whether the purpose is actually PASSED.** "Named within the window" is a text match. A call with
  `FernletCryptoPurpose` on a nearby line, or the bare word `purpose` in a comment, satisfies it. The
  matcher accepts `purpose`, `authenticated`, and the escape-hatch marker
  `// cryptographic-domain:` — deliberately broad, because the alternative was a wall so noisy
  nobody would keep it. **This is the gap `CryptographicDomainSeparationTests` was written to cover
  for the one path it can reach** (`theProductionSealBindsThePurposeIntoTheAuthenticatedData`), and
  it remains open for every other call site.
- **Whether the purpose is the RIGHT one.** Journal copy sealed under the worry-box purpose separates
  perfectly from everything and is still wrong. No test can see this; review is the only control.
- **A primitive whose marker is not on the list.** The nine markers are an enumeration. A different
  CryptoKit entry point, a helper that wraps one, or a future primitive is invisible until someone
  adds it.
- **Anything outside the five scanned roots.** The roots are `FernletKit/Sources`, `App/Fernlet`,
  `App/FernletWidgets`, `App/FernletShareExtension` and `App/FernletMessagesExtension` — every
  directory whose Swift reaches a device, and the same list `Scripts/power-of-10-scan.py` calls
  `SHIPPING_ROOTS`. The three extension roots were added in the crypto standardization round's
  Phase 5; before that the wall scanned two roots and the other three were clean only by inspection
  (verified 2026-08-27, checked by nothing), which is what happened to the Messages extension under
  the localization wall (see
  [MessagesExtensionReleaseChecklist.md](MessagesExtensionReleaseChecklist.md) §Localization).
  A root that stops resolving to Swift now throws `CryptographicWallScan.MissingRoot` rather than
  scanning an empty directory and reporting green — the one failure a grep-wall cannot survive. A
  sixth shipping target is still invisible until someone adds it to `CryptographicWallScan.roots`.
- **Escape-hatch abuse — now counted, and no longer any debt.** `// cryptographic-domain: …`
  silences the wall by design, for the paths that genuinely have no domain to name. **There are 7
  of them, across 4 files.** This document used to add that "nothing tracks the number, so a
  nineteenth passes unremarked"; `CryptographicEscapeHatchCensusTests` now does, and the next one
  added fails CI. It pins four things, not one: the total, the count **per label**, the number of
  files, and the set of labels that exist at all — so a hatch added while another is removed, a
  hatch relabelled into a more benign category, and a brand-new category of exemption each fail
  separately. The table below and the pins are one fact in two places, and move in the same commit.

  By the label each one gives itself:

  | Label | Count | What it means |
  |---|---:|---|
  | `purpose-derived salt` | 2 | The domain reached the primitive through the KDF salt, not as a visible argument |
  | `key-derived` | 2 | The domain is bound in the key rather than at this call |
  | `authenticatedData-bound aad` | 2 | The domain is inside the `aad` local, built above the window |
  | `x509-self-signature` | 1 | The transcript is a DER TBSCertificate, whose bytes X.509 fixes — a Fernlet prefix would make the certificate unparseable |

  **Six of the seven are annotations, and none of them is debt.** The domain IS bound at all six of
  those; the marker only silences a grep that cannot see three lines up, and re-reading them is the
  only way to tell an annotation from an exemption. There is no reader hatch left in the tree and
  no write-side one either.

  **The seventh is a different kind, which is why it has its own label.** `x509-self-signature`
  (`FernletKit/Sources/ProximityKit/Transport/EphemeralMeshTLSIdentity.swift`, added with the QUIC
  mesh transport — [Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md)
  §7.2) is not an annotation over a domain bound elsewhere: there is genuinely no Fernlet domain to
  bind, because the signature is over a format Fernlet does not own. QUIC's listener must present a
  certificate, X.509 defines exactly what a certificate's self-signature covers, and prefixing that
  transcript would produce bytes no TLS stack can parse.

  What makes it safe is not a domain but a scope: the key is a P-256 pair minted at session start,
  used for this one signature and nothing else, never persisted, and thrown away with the session —
  so there is no second use for the first to be confused with, which is what domain separation buys.
  It is also not a trust decision. Nothing in Fernlet verifies this signature; the certificate
  validator accepts anything, and peer authentication is the signed identity introduction exchanged
  over the connection (and, from P2 item 7, the TLS-exporter-bound channel introduction on top of
  it). A future hatch claiming this label would have to be another foreign signature format, not
  another Fernlet transcript that skipped its purpose.

  **How the count got here, and why `legacy-read` is not a row at 0.**

  The crypto standardization round
  ([Plan-Crypto-Standardization-2026-08-27.md](Plan-Crypto-Standardization-2026-08-27.md)) took the
  total from 18 to 6 and `legacy-read` from 10 to **0**. Rows that reached zero were **removed**
  from the table and from `pinnedByLabel` rather than left at 0: a label pinned at zero reads as a
  category that still exists and happens to be empty, when what actually happened is that the
  category was retired. A re-introduced legacy reader now fails the per-label pin as "1 found, 0
  pinned" — the absence IS the wall.

  Four steps, each landing with its deletion in one commit:

  - **18 → 17** when Phase 3 closed `ColumnCrypto.sealPlaintext`'s legacy WRITE (owner decision D4,
    fail close). That deleted the single `purpose-derived legacy-write` hatch, and with it the last
    line in the tree that could *mint* an un-domained blob — which is what turns a format-census
    zero from a moment into a latch. The file count was unmoved.
  - **17 → 13, 10 files → 8** when Phase 4 deleted the four Class-B WIRE readers (owner decision
    D1(a), hard cutover on the no-peers premise). Nothing was migrated because nothing is stored in
    those formats: the bytes arrive from a peer, so the readers existed solely for a peer on an
    older build. `MeshNetworkManager.swift` and `IdentityService.swift` held *only* those four and
    dropped out of the set.
  - **13 → 10, 8 files → 6** when Phase 3 deleted three of the six Class-A AT-REST readers:
    `PendingNarrativeBuffer`'s unmarked buffer-file open, `MediaAtRestCrypto.gcmOpen`'s unprefixed
    no-AAD branch, and `SealedPhotoBackupService`'s v1 digest comparison.
  - **10 → 6, 6 files → 3** when Phase 3 deleted the last three — the DELICATE ones, whose failure
    mode is "the user's sealed data becomes unopenable": `ColumnCrypto`'s sealed corpora (journal,
    cycle, intimacy, worry), `FernletLockService`'s content-key wrap, and `HeartDropSidecarKey`.
    The same change removed the last `v2 device-bound read` — `ColumnCrypto`'s `0x02` rung, owner
    decision D2 — so V3 is the only sealed-column format on the read side and the write side alike,
    and that label left the pin too.

  These deletions proceed on the owner's RISK judgement under §0 of the plan — one install, test
  data only — not on a discharged gate. The distinction is recorded because the two are easy to
  conflate later.

  **Every refusal is NAMED.** That is the through-line, and it is worth more than the count:
  `PendingNarrativeBufferError.legacyUnprefixedFormat`; a `privateMedia.legacyFormatRefused` audit
  line; `SealedPhotoRestoreSummary.unverifiableLegacyDigest` (deliberately a TERMINAL list rather
  than the retryable one, because a permanently unverifiable entry in the repair ledger would re-run
  a doomed restore on every launch); `MeshEncryptionError.legacyWireFormat`,
  `IdentityError.legacyWireFormat` and `FernletIdentityEnvelope.VerifyError.payloadLegacyWireFormat`
  on the wire; `ColumnCrypto.SealedColumnOpenError.retiredFormat(_:)`, which says *which* generation
  the marker reports, beside `emptyBlob` and `installBindingMissing` so a store fault and a lost
  binding row can never be filed as a legacy row; `FernletLockError.contentKeyWrapFormatRetired`,
  which is neither `invalidPasscode` (the entry was right) nor `contentKeyUnrecoverable` (no enclave
  key was destroyed); and `SidecarSeal.SealError.legacyFormatRetired`. "Decryption failed" is not
  actionable; "the bytes are V2 and this build only reads V3" is.

  **The classifiers OUTLIVE the readers, and that is load-bearing rather than tidy.** Every format
  census, and every marker constant they classify by — `legacyHashVersion`, `FMA2`, `FNB2`, `FGK2`,
  `FSC1`, `FLW2`, `ColumnCrypto`'s `0x02` — is KEPT. Counting bytes nothing can open is still the
  only way to know they are there, and a refusal that cannot recognize what it is refusing cannot
  explain itself. `HeartDropSidecarSeal` is the sharpest case: `isSealed` must keep answering true
  for `FSC1`, because `ProtectedSidecar` splits on that predicate into "sealed" and "legacy
  PLAINTEXT v0 — read it as JSON and re-seal it", so a marker that stopped classifying would send
  ciphertext down the plaintext branch, fail to decode, and take the *corrupt* path — destroyed
  rather than quarantined. Deleting a reader is not deleting its classifier.

  **What was lost, stated rather than glossed.** Each deletion took its HEALER with it wherever the
  healer converted *through* the deleted branch — a migrator left standing that can no longer heal
  is worse than either alone — so the `PendingNarrativeBuffer`, `ColumnCrypto`, `FernletLockService`
  and `HeartDropSidecarKey` migrators are gone, `MediaAtRestFormatMigration` was cut back to the
  plaintext-JPEG generation it still converts, and `SealedPhotoBackupService`'s was left untouched
  (its heal is a re-upload triggered by a digest MISMATCH and never used the deleted comparison).
  One resolution went with them: the ~1-in-256 sealed-column blob whose first nonce byte collides
  with a marker used to be resolved *by open* by the keyed migrator pass, and nothing can resolve it
  now — a `0x02` collision reports as a retired v2 row, and a `0x03` collision fails authentication
  without being able to name itself. That is the one refusal in the tree that cannot say what it
  found.

  (The file count was **11** here until 2026-08-28. It was wrong when it was written, not stale:
  the tree held 18 hatches across 10 files at the commit that wrote the sentence. An uncounted
  number drifts in both directions.)

  One shape the pin has to defend against by itself: the wall reads a raw context window, so a
  `///` line that merely *mentions* the marker near a primitive call silences it exactly as a real
  hatch would while reading as documentation to a human. The census classifies documentation
  mentions separately, pins where they are (**none** today — the single entry was
  `PendingNarrativeBufferFormatCensus`'s sentence about the buffer's legacy branch, rewritten in
  the commit that deleted that branch), and asserts none of them sits within reach of a primitive
  call.

### `CryptographicDomainSeparationTests` — a property suite

Every test is a negative: it performs a cross-domain operation and requires it to fail. Coverage is
all-pairs over the 47 entries rather than sampled, because what is at risk is one entry — the new or
copy-pasted one — not the primitive.

**What it catches:** two purposes sharing a spelling; a purpose whose bytes no longer separate a
derived key, an HMAC tag, or a digest; an AEAD ciphertext that opens under a foreign domain with the
key held constant; the production v3 seal dropping the domain from its AAD; a signature purpose that
accepts a foreign transcript; and a prefix relation between two spellings.

**What it cannot catch:**

- **Whether production passes these values at all**, except for the single `ColumnCrypto` path it
  drives end to end. Every other test seals its own ciphertext, so it proves the registry's values
  work as domains, not that any call site uses them that way.
- **Whether a purpose is the right one for its data.** Same limit as above, same answer: review.
- **A framing that is wrong in a way both sides share.** If a serializer and its purpose are changed
  together, the round trip and the framing check both pass. That is exactly what a deliberate format
  change looks like, which is why step 7 of §6 asks about the legacy read path.

### The one live allowlist

`prefixExceptions` holds a single entry: `com.fernlet.sealed-backup` is a proper prefix of
`com.fernlet.sealed-backup.v2`. It is not exploitable — both are HKDF `info` inputs at one call site,
never reaching `signingBytes` and never concatenated, and HKDF commits to the info's length — and it
is not fixable, because the v1 spelling derives the key for every sealed backup written before the v2
format. The entry carries an explicit expiry: it dies the moment either value reaches a signature
transcript or an AAD blob, at which point the fix is a new, non-prefixing v3 spelling with a
migration.

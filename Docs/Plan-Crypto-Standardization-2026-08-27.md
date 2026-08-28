# Plan — Cryptographic format standardization (no legacy paths)

**Status:** Phase 0 (the census) is BUILT — see §4. Phases 1–5 are still plan only.
**Goal (owner, 2026-08-27):** review the domain-separation work and update everything so there is no
"legacy" code — one standardized format per cryptographic surface.
**Baseline:** main `def4726`. Prerequisite work already landed: `91c3956` (domain separation),
`216f1ba` (the framing-regression repair), `2fa6f24` (the property suite), `e749adb`
([Crypto-Domain-Separation.md](Crypto-Domain-Separation.md)).

---

## 1. Why this is not a delete

Ten call sites carry `// cryptographic-domain: legacy-read`. Each one exists because **bytes already
written under the old format are still on a device**. Deleting the reader does not standardize those
bytes; it makes them unopenable. For six of the ten that means a tester's sealed journal, worry
entries, cycle notes, intimacy log, private media or lock content-key becomes permanently
unreadable — the worst outcome this app has.

So the shape is **migrate, prove, then delete** — never delete first. The good news, established by
survey: *every one of the ten has a detectable format marker*, so legacy blobs can be counted,
converted, and proven absent. Standardization is reachable; it is a migration project, not an edit.

A second, unrelated blocker applies to four of the ten: they read bytes a **peer** sends, so removal
is a peer-version decision, not a migration. See §5.

## 2. The ten sites, classified

### Class A — at rest, on this device (6). Migratable.

| Site | Marker that distinguishes new from legacy | Target |
|---|---|---|
| `FernletCrypto/ColumnCrypto.swift:196,204` | first byte `0x03` (V3) / `0x02` (V2) / unprefixed | V3 |
| `PrivateStoreCore/PendingNarrativeBuffer.swift:193` | `isV2` flag | V2 |
| `PrivateMediaStore/MediaAtRestCrypto.swift:47` | `atRestFormatV2` prefix | V2 |
| `FernletLock/FernletLockService.swift:410` | `wrappedContentKeyFormatV2` prefix | V2 |
| `App/Fernlet/SealedPhotoBackupService.swift:692` | digest equality against the v2 pre-image | V2 |
| `ProximityKit/HeartSharing/HeartDropSidecarKey.swift:61` | `magic` vs `legacyMagic` | V2 |

`ColumnCrypto` is the only three-rung ladder (legacy → V2 → V3) and the only one holding the sealed
corpora, so it is both the highest-risk and the highest-value.

### Class B — wire, from a peer (4). NOT migratable.

| Site | Purpose | Why migration cannot help |
|---|---|---|
| `ProximityKit/Mesh/MeshNetworkManager.swift:3582` | `meshGroupPhotoV2` | The bytes arrive from another device at open time |
| `ProximityKit/Mesh/MeshNetworkManager.swift:3616` | mesh group payload | ” |
| `ProximityKit/Identity/IdentityService.swift:271` | `proximityTransportV2` AAD | ” |
| `ProximityKit/Identity/IdentityService.swift:466` | `meshGroupKeyWrapV2` | ” |

There is nothing stored to convert. The legacy branch fires only when a peer running an older build
sends old-format bytes, so removal is governed by *which builds are still in the field*.

### Not legacy at all (8 more markers, listed for completeness)

`purpose-derived salt` ×2, `key-derived` ×2, `authenticatedData-bound aad` ×2, `v2 device-bound read`
×1, `purpose-derived legacy-write` ×1. The domain IS bound at these; the marker only silences a grep
that cannot see three lines up. They are annotations, not debt — except the `legacy-write` fail-open
in `ColumnCrypto.sealPlaintext`, which §4 Phase 3 addresses.

## 3. The missing precondition: nobody can count legacy blobs

[Crypto-Domain-Separation.md](Crypto-Domain-Separation.md) §Escape-hatch abuse states it plainly:
"there is no inventory anywhere of how many such rows remain." **Nothing can be deleted safely until
that number is known and observed to reach zero.** This is Phase 0 and it gates everything after it.

## 4. Phases

### Phase 0 — Census (read-only, no behavior change) — **BUILT**

Five per-surface censuses plus the app-target aggregator (`App/Fernlet/CryptoFormatCensus.swift`),
rendered as six rows in Settings → Debug (DEBUG builds only). Every one classifies by **marker bytes
only**: nothing decrypts, nothing fetches a key (asking would mint one), nothing writes. The
aggregator persists nothing either — no latch, deliberately: a stored "clean" reading has a shelf
life nobody can see (below), and a new key would owe `Docs/PrivacyWipeCoverage.md` a disposition row.

| Surface | How the count is produced | What the number is worth |
|---|---|---|
| `ColumnCrypto` (`SealedColumnFormatCensus`) | paged fetch over the four sealed entities' seven ciphertext columns, classifying `data.first`, refaulting each row (external blobs fault whole) | `definitelyLegacy` (unprefixed) is **exact**; `v3Marked`/`v2Marked` are **upper bounds** — a legacy nonce's first byte hits a marker ~1/256 each, and only a keyed pass that opens each blob can resolve that sliver. Truncation at the row cap is reported, not absorbed. |
| `PendingNarrativeBuffer` | first four bytes of the one `pending-narratives.bin` per scope vs `FNB2` | 0 or 1, exactly as the reader would decide. `absent`/`empty` are earned zeros; `unreadable` (data protection, device locked) counts `nil`, never 0. Corrupt bytes land in legacy — the safe direction. |
| `MediaAtRestCrypto` | first four bytes of every file across the two roots' eight locations (own meal/recipe/progress + progress index; wall photos/thumbnails + sealed index + the pre-sealing plaintext index) vs `FMA2`, plus a JPEG sniff | the unprefixed bucket is legacy **or** unrecognised — an upper bound on true legacy, since bytes alone cannot separate them. Unreadable files, unlistable directories and a capped sweep are reported as blind spots that make the count a lower bound. |
| `FernletLockService` wrap | one `SecItemCopyMatching` on `wrappedContentKey`, prefix vs `FLW2` | 0 or 1. `absent` is an earned zero with three readings (no lock, enclave-bound, or a missing wrap); `malformedEmpty` and `unreadable(OSStatus)` count `nil` — collapsing "could not read" into "not there" is what would license Phase 3 to lock a user out of every corpus. |
| `HeartDropSidecarKey` | the four known sidecar names, prefix vs `FSC2`/`FSC1` | exact for those names; `unreadable` makes it a lower bound, and unmarked files (v0 plaintext or garbage) are reported beside the count because they too block a clean verdict. |
| `SealedPhotoBackupService` | — | **no count exists.** See the exception below. |

Two caveats belong beside every reading. **The number can go up:** `ColumnCrypto.sealPlaintext`
still fails open, writing an unprefixed legacy blob whenever `DeviceBindingID.current()` is `nil`, so
shipping builds still create legacy rows — a zero is a moment, not a latch, until Phase 3 closes that
branch. And **`definitelyLegacy == 0` is necessary, not sufficient**: the collided sliver in the
marked buckets is invisible to any byte-only classifier.

**Exception — `SealedPhotoBackupService` STOPs at Phase 0.** Its count cannot be produced:
`contentHash` is an unversioned digest, distinguishing pre-images requires the plaintext (so
classifying one entry means decrypting the sealed manifest *and* pulling that photo's body from
iCloud), entries whose body record has vanished are unclassifiable at any price, and no completed-pass
latch exists — nor would one prove zero: a full pass skips unreadable local photos and never heals
another device's carried-forward entries. Phase 2 item 1's "already self-heals on reconcile; likely
the cheapest" is right about the mechanism and wrong about the consequence: Phase 3's delete here is
blocked on the **`hashVersion` marker Phase 1 has now added to manifest entries** (default 1 on
decode; manifest-level minimum computed, not stored; self-propagating, since the manifest is
re-encoded wholesale each pass) — not on a census, which is why the census row for this surface stays
static text saying so even now that the marker exists. The proof is
`SealedPhotoManifest.minimumEntryHashVersion >= 2` across the three corpora after full-verification
passes, read on a device; see Phase 1 below.

**Phase 3 cascade hazard on that surface.** Deleting the legacy digest branch while one legacy entry
remains does not merely fail that entry: it sends it to `summary.failed` → `.deferredTransient`, the
repair ledger never clears, and that corpus re-runs the doomed repair on every launch with
`routeCommitted` pinned false — on any device that ever entered a restore. The delete is not a
one-entry loss, it is a permanent failing loop.

Exit: the census reports for all six surfaces on a device that has upgraded from a pre-`91c3956`
build — every row renders something explicit, and a row that could not look says so
(`CryptoFormatCensusReport.allSurfacesReported`, with `rowsWithoutACount` naming the gaps; `nil` is
never rendered as `0`). **If any count cannot be produced, stop** — a surface whose legacy rows
cannot be counted cannot be proven migrated. Still owed: a reading from a real tester device with
real upgraded data. Simulator numbers do not discharge this.

### Phase 1 — Generalize the migrator that already works — **BUILT**

Two halves, both preparatory: one shared contract for the migrations Phase 2 will write, and the one
format marker Phase 0 proved was missing. **No migration ran, no legacy reader was deleted, no blob
was converted, no wire format and no Class-B site was touched.** The AES-GCM envelope's
`formatVersion` stays 2 and `contentHash` is computed exactly as before.

**Half A — the `FormatMigrator` lift.** `FernletKit/Sources/FernletCrypto/FormatMigrator.swift`
holds a new `public nonisolated protocol FormatMigrator` plus the two contracts it reads through —
`FormatMigrationPassResult` (`isClean`, `madeForwardProgress`) and `FormatMigrationLatching`
(`isComplete`, `markComplete()`, `reset()`). The shared `run(maxPasses:)` and `isComplete` live in a
protocol extension: scan → convert → latch, bounded passes, resumable, idempotent, latch set only by
a pass that converted nothing, failed nothing and could classify everything. `OwnPhotoKeyMigrator`,
`OwnPhotoMigrationLatch` and `OwnPhotoKeyMigrationResult` are the first conformers, and the migrator's
own `run`/`isComplete` were **deleted** in favour of the shared pair — the loop is line-for-line the
one that shipped there, and the untouched `OwnPhotoKeyMigrationTests` are what make the conformance a
proof rather than a claim.

It lives in `FernletCrypto` and not `FernletFoundation`, the other reachable Layer-0 home, for wall
reasons: `CloudKitSync` imports `FernletFoundation`, and machinery whose purpose is to touch sealed
corpora must stay unnameable by walled code, while every module that will conform in Phase 2
(`PrivateMediaStore`, `PrivateStoreCore`, `FernletLock`, `ProximityKit`, the app target) already
depends on this zero-dependency target for its sealing primitives — so no conformer needs a new
dependency edge, and none of them gains one.

**Half B — the sealed-photo-backup marker.** `SealedPhotoManifest.Entry` gained
`hashVersion: Int` (`CloudKitSync/SealedPhotoRecord.swift`), governed by three rules:

- **Decode-default 1.** A missing field decodes as `legacyHashVersion` = 1, meaning legacy *or
  simply unproven*. Old manifests keep decoding, and no pre-marker entry is ever silently promoted.
  The default is the fail-closed direction — an undercount of proven-v2, never an overcount of clean.
- **Stamp only on proof.** `SealedPhotoBackupService` writes `currentHashVersion` = 2 only on the
  rungs that read the plaintext and computed the v2 digest from it: matched-unchanged (which upgrades
  a pre-marker entry's stamp without re-uploading a byte) and sealed-and-uploaded. The init parameter
  is deliberately not defaulted, so every construction site has to say which it is.
- **Carry-forward propagates.** The two rungs that read no bytes — the cheap skip, and the
  unreadable-local-file rung that keeps a good cloud copy — now carry the whole existing entry
  forward verbatim, recorded version included, as does the union that carries another device's
  entries. This device did not read those bytes and has no standing to promote their digest claim.

The per-corpus proof is `SealedPhotoManifest.minimumEntryHashVersion` — the minimum over entries,
**computed and never stored** (`entries` is mutable, and a stored copy could drift from what it
summarizes), reading as 2 for an empty manifest. `>= 2` means no entry in that corpus carries, or
might carry, the legacy bare-SHA256 digest; it is self-propagating because every reconcile re-encodes
the manifest wholesale.

Half B also stopped `OwnPhotoBackupCoordinator` discarding the reconcile summary. A full-verification
pass's `unreadable` count now flows through `CorpusResult` and `PassResult.verifiedUnreadable` into
`OwnPhotoBackupContext.recordOwnPhotoBackupVerifiedUnreadable(_:)` →
`FernletStore.ownPhotoBackupVerifiedUnreadable` (session state; **no new `UserDefaults` key**, so the
wipe wall is untouched) → a Privacy & Data banner line and Retry eligibility. Only a full pass records
a verdict — an ambient pass reads almost nothing, and letting it write its near-zero would erase the
last real reading. This matters to the marker: a committed-but-unread photo is exactly an entry whose
version stays 1, so the count is the user-visible half of "this corpus is not proven yet".

**What this means for the §4 exception.** The zero-proof for this surface will come from
`minimumEntryHashVersion >= 2` across the three corpora after full-verification passes on a real
device — not from a census count, which is why `CryptoFormatCensus.sealedPhotoBackupRow` stays
`.uncountable`: pre-marker entries decode as 1 whatever their digest is, so the only number available
today is "not yet proven", and producing even that would mean fetching and decrypting each manifest
from iCloud. Phase 3's cascade hazard on this surface is unchanged and still gates the delete.

**Pinned.** Six new tests in `SealedPhotoBackupTests` hold Half B's rules against a hand-built
pre-marker manifest (no `hashVersion` key at all, committing the legacy bare-SHA256 digest — no build
that still exists can produce one, and the field's absence is the fixture): a full pass heals such an
entry to the v2 digest *and* stamps it; an ambient pass carries it forward without touching the
stamp; a verifying pass that never read that plaintext — the union leg, where it bites hardest —
does not promote it either; a verifying pass whose LOCAL read fails keeps that entry verbatim (the
"we're verifying, so stamp it" edit that must never slip in); a pre-marker manifest decodes as
legacy throughout, floor included; and the coordinator publishes a full pass's unreadable count to
the host — commit succeeded, banner still not clean — with an ambient pass unable to overwrite it.
`OwnPhotoKeyMigrationTests` was deliberately not touched: unchanged tests over a deleted-and-replaced
loop are the proof Half A is behavior-preserving.

Note `ColumnCrypto` already self-migrates opportunistically — "every routine re-seal — edits, the …"
rebinds a row. That covers rows the user touches and *never* covers the rest, which is exactly why a
sweep is required rather than relying on organic re-seal.

### Phase 2 — One migrator per Class-A surface (6)

Order by risk, lowest first, each landing independently with its own census proof:

1. `SealedPhotoBackupService` — already self-heals on reconcile; likely the cheapest.
2. `HeartDropSidecarKey`
3. `MediaAtRestCrypto`
4. `PendingNarrativeBuffer`
5. `FernletLockService` content-key wrap — **re-wrapping the content key; a failure here locks the
   user out of every sealed corpus.** Must be atomic with a verified read-back before the old wrap is
   discarded (cf. [Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md](Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md);
   the house lesson is that restore-before-reupload is a data-loss ordering).
6. `ColumnCrypto` legacy → V3 and V2 → V3, the sealed corpora. Largest, last, and the one that most
   needs the census to show zero before Phase 3.

Every migrator: runs behind the app lock (these are sealed corpora), never deletes the source blob
until the re-sealed blob has been read back successfully, and reports incomplete rather than
claiming success.

### Phase 3 — Delete the Class-A legacy readers

Gated on census = 0 for that surface, on real tester devices, not just simulators. Also close
`ColumnCrypto.sealPlaintext`'s `purpose-derived legacy-write` fail-open: once no device can produce
an unbound write, the branch that seals without a binding should refuse rather than silently write an
un-domained blob a future census would count.

### Phase 4 — Class B: the peer-version decision (§5), then delete those four.

### Phase 5 — Wall the end state

- A test asserting **zero** `// cryptographic-domain: legacy-read` markers remain in the two scanned
  roots — the whole point of the round, and the only thing that stops a legacy path being
  reintroduced.
- Pin the total escape-hatch count. The doc notes 18 across 11 files and that "nothing tracks the
  number, so a nineteenth passes unremarked." A pinned count fixes that regardless of this round.
- Extend the purpose wall's roots to `App/FernletWidgets`, `App/FernletShareExtension`,
  `App/FernletMessagesExtension`. All three are clean today (verified 2026-08-27) and nothing checks
  that they stay clean — the Messages extension is the worked example of what happens to a shipping
  target no wall enumerates.
- Rewrite [Crypto-Domain-Separation.md](Crypto-Domain-Separation.md) §Escape-hatch abuse to the new
  reality.

## 5. Open decisions — owner only

**D1 — Minimum peer build (blocks Phase 4).** The four Class-B readers can be deleted only when no
peer in the field still speaks the old wire format. Options:
  - **(a) Hard cutover.** Confirm every tester has updated past the domain-separation build, then
    delete. Cheapest, and viable *because the tester group is small and known* — but a peer on an old
    build then fails to connect with no explanation.
  - **(b) Negotiated refusal.** Add a wire-version field to the handshake and refuse older peers with
    a clear message ("update Fernlet to share with this person"). More work; degrades honestly, and
    is the only option that stays correct once the group is not hand-countable.
  - Recommendation: **(b)** if App Store release is in view, **(a)** only while the tester list is
    still enumerable by hand.

**D2 — Does the ColumnCrypto V2 rung go too?** V2 is post-domain-separation and is not `legacy-read`
— it is a `v2 device-bound read`. Standardizing to V3 alone is more thorough and costs one more
migration rung. Assumed **yes** in Phase 2 item 6; say so if not.

**D3 — Migration UX.** These sweeps run behind the app lock and touch every sealed row. Silent
background pass, or a visible one-time "finishing up" state? The house principle is
nothing-silent, which argues for visible when the corpus is large.

## 6. Risks

| Risk | Control |
|---|---|
| A legacy reader is deleted before the last blob is converted → permanent data loss | Phase 0 census gates Phase 3; census must read 0 on a real upgraded device |
| The lock content-key re-wrap fails mid-flight → total lockout | Atomic write with verified read-back before discarding the old wrap |
| A migration pass is unbounded on a large corpus → jetsam (the failure `269003c` was chasing) | Bounded passes + resumable latch, the `OwnPhotoKeyMigrator` contract |
| Class-B cutover strands a tester mid-round | D1(b) refuses honestly instead of failing opaquely |
| Format census itself decrypts to count | Count by MARKER BYTES only — never open a blob to classify it |

## 7. Sequencing note

Phase 0 is small and unblocks the estimate for everything else; it is worth landing on its own before
committing to the rest. Phases 2.1–2.4 are independent and parallelizable; 2.5 and 2.6 are not.

## 8. Related, not in scope

The web-imported-recipe Messages defect (owner decision 2026-08-27: web recipes *should* be
shareable) is tracked separately — it is a wire change to `SharedRecipePayload`, unrelated to crypto.
Note for whoever takes it: `RecipeExchangePacketHashInput` is a **frozen** hash pre-image, so adding
fields to the shared payload interacts with `contentHash` and needs a version story of its own.

## Progress

Single source of truth for the standardization loop (owner-approved 2026-08-28). Every loop
iteration re-reads §4 and this checklist before acting; every phase boundary checks its item off
with the landing commit SHA and records the phase's token spend below. Anything discovered
mid-phase that is new work gets ADDED here, never done silently or dropped.

- [x] Phase 0 — format census (main `27a780b`)
- [x] Phase 1 — `FormatMigrator` lift + sealed-photo `hashVersion` marker (`94a8bc4`, merged to
      main 2026-08-28; boundary gate: full unit phase 3143 tests / 285 suites green from a private
      DerivedData, power-of-10 and doc-coverage scans clean)
- [ ] Phase 2.1 — `SealedPhotoBackupService` migrator
- [ ] Phase 2.2 — `HeartDropSidecarKey` migrator
- [ ] Phase 2.3 — `MediaAtRestCrypto` migrator
- [ ] Phase 2.4 — `PendingNarrativeBuffer` migrator (runs on the buffer key, NOT behind the app
      lock — the buffer exists to work while locked)
- [ ] Phase 2.5 — `FernletLockService` content-key re-wrap (atomic, verified read-back before the
      old wrap is discarded; complete + verify in one funded stretch)
- [ ] Phase 2.6 — `ColumnCrypto` legacy→V3 and V2→V3 (D2 assumed yes; one funded stretch)
- [ ] Phase 3 — delete the Class-A legacy readers + close `sealPlaintext`'s legacy-write fail-open
      — HARD GATE per surface: census reads zero on a REAL upgraded tester device (simulator zeros
      do not discharge it; for `ColumnCrypto`, `definitelyLegacy == 0` is necessary-not-sufficient
      and the keyed migrator's clean pass is the second witness). Deletion diffs may be drafted on
      a parked branch; the gate itself cannot be self-satisfied by the loop.
- [ ] Phase 4 — Class B wire readers — BLOCKED: owner decision D1 (§5). No Class-B site is touched
      until it lands.
- [ ] Phase 5 — wall the end state (§4). The parts independent of Phases 3/4 — the pinned
      escape-hatch count and the three extension roots — may land early.
- [ ] Final pass — docs-vs-code reconciliation sweep + purpose-statement sweep, then stop the loop
      with the gate report (real-device census readings owed, D1, anything parked).

Token log (per phase: spent / big consumers / remaining):
- Phase 1: ~1.0M output tokens. Big consumers: three Opus agents — the verifier's three gate runs
  (~424k; the full suite ran three times because two review findings landed after the first full
  run — next phases should batch review fixes BEFORE the first full gate), the pin-test writer's
  three rounds (~386k), the docs pass (~132k); main loop the remainder. Remaining budget at the
  boundary: ~15.0M. (Numbers from the harness's per-agent usage blocks; the explain-usage chart is
  deferred to a boundary the owner is watching.)

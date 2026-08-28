# Plan — Cryptographic format standardization (no legacy paths)

**Status:** Phases 0, 1 and 2.1–2.5 are BUILT — see §4 and the Progress checklist. Phase 2.6 and
Phases 3–5 are still plan only.
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

### Phase 2.1 — `SealedPhotoBackupService` migrator — **BUILT**

Source landed in `db40984`; the tests/docs commit follows. **Policy only.** The heal itself shipped
with Phase 1 and is pinned by `SealedPhotoBackupTests` §8 — a full-verification reconcile rewrites a
legacy entry with the v2 digest and stamps its `hashVersion`. What 2.1 adds is the loop, the latch,
the invalidation rules and the user-visible trigger, at **zero new cryptographic calls**: no
seal/open/digest/derivation site, no change to the AAD, the record `formatVersion`, or the manifest
JSON schema. Every write still goes through the reconcile whose ordering, union, carry-forward and
prune scope the §8 pins already hold. (The Phase 2 preamble's "runs behind the app lock" targets the
sealed Core Data corpora; this surface's passes already run outside the lock by shipped design —
launch-ambient passes, keys at `AfterFirstUnlock` — and the migrator rides those same seams without
changing their custody model.)

**The async sibling.** The pass is `async` and main-actor over CloudKit, which the Phase 1 protocol
cannot express; bridging it into a synchronous `performPass()` would park a thread on main-actor
work — the starvation family bounded passes exist to prevent. So `FernletCrypto` gained
`AsyncFormatMigrator` beside `FormatMigrator`, sharing `FormatMigrationPassResult` and
`FormatMigrationLatching` verbatim so the latch and verdict vocabulary stay single-sourced.
`FormatMigrator.swift` and `OwnPhotoKeyMigration.swift` are **not in the diff** — Phase 1's
"unchanged tests over a replaced loop" proof is undisturbed. The run loop is duplicated
deliberately, the duplication is named in a doc comment on both sides ("a change to either loop's
policy must land in both"), and each copy is now pinned from its own side against a scripted
conformer (`FormatMigratorTests`, `AsyncFormatMigratorTests`).

**Verdict semantics — absence of evidence blocks.** A full pass now returns one
`SealedPhotoCorpusFormatVerdict` per corpus, built from what the two legs already held: `examined`
(some leg opened the manifest slot and got an answer — a manifest, or the restore leg's proof that
none exists), `observedMinima` (every `minimumEntryHashVersion` the pass saw — opened at restore,
opened at reconcile start, and the outgoing value of the manifest it committed), `unreadable`, and
`healedEntries`. `isClean` has **no nil-coalescing and no unexamined escape**: an unexamined corpus,
an unreadable manifest, an unlistable directory, any unreadable photo, anything still to heal, or
any observed minimum of 1 blocks the latch. Forward progress is `healedEntries > 0` — an entry whose
recorded version rose 1 → 2, counting both heal shapes (the re-upload and the matched-unchanged
stamp upgrade) and deliberately not plain new-photo uploads, so a pass that backs up new photos
while a foreign legacy entry stays stuck cannot spin. Two coordinator policy changes sit above the
service and are named as changes rather than smuggled in: full passes now reconcile an
emptied-after-upload corpus (provably inert — `ids = []`, empty prune set, carry-forward verbatim)
so its manifest is examined instead of permanently unobserved, and a corpus whose id enumeration
fails — a directory that exists but will not list — is skipped as indeterminate instead of feeding
the reconcile an empty id view.

**The latch, and what it deliberately does not gate.** `fernlet.sealedPhoto.hashVersionMigrationComplete`
attests exactly one sentence: on *this* device, a full pass completed in which every photo it holds
was read and proven, every corpus was examined and committed, and every observed manifest minimum
was `>= 2`. It does **not** attest fleet convergence, and **it is not the Phase-3 gate** — that gate
reads `minimumEntryHashVersion` from the manifests at gate time on a real device, never this bit.
This is a documented deviation from the `FormatMigrationLatching` family norm ("every latch gates an
irreversible step"): here the irreversible step's gate is the manifests themselves, the only
artifact every device shares, and the latch's whole job is to stop re-funding whole-library passes
and to drive the nudge off. It is invalidated by delete-all teardown, by adopting another device's
escrow key, and by any pass — ambient included — that observes a manifest minimum of 1, which is how
a foreign or pre-marker write reaches this device.

**Trigger (D3: nothing silent).** No ambient pass of any kind. The migrator runs at exactly the two
seams that were already full, user-visible passes — enable, and the banner's Retry — both routed
through one coordinator wrapper, with an in-flight guard so the device never races itself in the
manifest's last-writer-wins ordering, and a teardown-epoch guard so a delete-all landing between
funded passes turns every remaining pass into a no-op rather than resurrecting the backup the user
just destroyed. A latched route still gets the plain full pass: the latch never eats the user's
verification. While the backup is on and the check is owed, Privacy & Data shows one pending status
line beside the existing Retry button — and **both** banner predicates were extended, without which
the healthy pre-marker user (the nudge's entire target population) would see neither the line nor
the button. When the only blocker is a foreign entry this device cannot heal, the copy swaps to say
so and withdraws the Retry invitation, because Retry structurally cannot clear that state.

**Wipe wall.** The one new `UserDefaults` key landed with both rows in the same commit: the
`PersistedSurfaceWipeBoundaryTests` `.cleared(token: "deleteOwnPhotoEscrowBackups")` row and the
extended `Docs/PrivacyWipeCoverage.md` row. Cleared, not kept — the deliberate mirror-image of
`ownPhotoKeyMigrationComplete`'s kept row: that latch's subject (re-sealed local files) survives the
wipe, this one's subject (the manifests) is destroyed by the same call, so keeping it would preserve
a falsehood.

**Implementer deviations from the reviewed design (four, all deliberate).** (1) The wrapper's merge
is scoped to passes that actually RAN — a no-op pass carries `PassResult()`'s defaults, including
`routeCommitted == true`, so admitting it would re-record a committed route off a pass that did
nothing, and the binding gate consults that ledger. (2) The foreign-write audit line fires only when
a *set* latch was actually invalidated; the reset itself stays unconditional, so the trail never
claims an invalidation that did not happen. (3) The census edit extended to the doc comment above
`sealedPhotoBackupRow`, not only the `.uncountable` string the design named — the same stale premise
appeared in both, and the row's status and no-fetch behavior are untouched either way. (4) The
Progress tick moved to this docs commit rather than riding the source commit.

**Residuals — recorded work, not dropped work.** Three planned pins could not be written against the
landed API and are owed. P10 (escrow adoption resets the latch) and the store-side latch re-reads:
`FernletStore` constructs `SealedPhotoBackupMigrationLatch()` on `.standard` at all three seams,
which matches the `ownPhotoKeyMigrationComplete` precedent exactly but leaves no injection point, so
a test cannot observe the reset without touching the device's real defaults. P17 (teardown between
funded passes) needs `teardownEpoch`, which is private to the coordinator. P19 (the healthy
pre-marker user sees the pending line and a tappable Retry) needs the two banner predicates, which
are private to the view. Each is a testability gap, not a behavior gap — the behavior is implemented
and reviewed — and closing them means widening a seam, which belongs in its own change rather than
riding this one. One known behavior residual: after an invalidation the first render shows the
generic pending copy even when the blocker is another device, because the foreign-only verdict is
session state derived from a wrapper run; one tap re-derives the honest copy.

### Phase 2.2 — `HeartDropSidecarKey` migrator — **BUILT**

Landed in `5ca478e`. **The scan IS the census**: `performPass()` calls
`HeartDropSidecarFormatCensus.survey` and buckets what it returns, so the counter and the converter
can never disagree about the number Phase 3 is gated on. Convert re-seals an `FSC1` row through
`HeartDropSidecarSeal.make`'s existing open/seal closures — binding the already-registered
`heartDropSidecarV2` purpose without ever naming a purpose, touching key bytes, or adding a crypto
call shape of its own — verified round-trip in memory *before* an atomic, fully-protected,
backup-excluded write through the shipping sidecar writer, and read back after. Source bytes are
never deleted.

The bucket arithmetic is exact: every examined row lands in exactly one bucket, so the counts sum to
`examined` and a diagnostic read is never off by a phantom row. `keyUnavailable` absorbs both the row
whose open threw a key error *and* every legacy row left unattempted after the one-key early stop —
one key serves all these files, so those rows are indeterminate for the identical reason, and a
two-legacy keyless corpus reads 2, never 1. Unmarked bytes stay fail-closed, pending the store's own
seal-on-load rather than being converted here. The quarantine tombstone is **reported, never
converted, and never blocking**: no reader ever opens that path again, so its marker bytes prove
nothing about live data.

Launch revalidation is this phase's own contribution to the family: a set latch is re-checked on
every launch with one marker-only survey (four `stat`s, key-free), and **the reset predicate equals
the latch predicate** — the blocking classes it resets on are exactly the set `isClean` refuses to
latch over — so a restore that re-introduces any blocking row un-latches instead of being silently
outlived. Observation beats memory. The latch key landed with both wipe rows in the same commit and
is cleared on delete-all, beside the wipe leg that destroys its entire subject (the sidecar files
**and** the seal key).

**Deviation from the reviewed design.** The design specified a `nonisolated` stored latch property;
Swift 6 allows `nonisolated` on a stored property only for `Sendable` types, and `UserDefaults` is
not `Sendable` in this SDK, so the property is main-actor isolated under the plan-A isolated
conformance — the latch *type* is still the nonisolated value type the family expects. Documented at
the declaration.

### Phase 2.3 — `MediaAtRestCrypto` migrator — **BUILT**

Landed in `810c45f`. It converts only the **complement of `OwnPhotoKeyMigrator`'s sweep**, which
stays byte-for-byte untouched: own-corpus files that already open under the own key but carry no
marker, the whole friend-wall root (whose key never changed, so the key pass never sweeps it), and
the pre-sealing plaintext JPEG generations exactly where the read paths' upgrade branches exist.
Disjoint convert sets, one launch task, strict order — key pass, binder, format pass — so the two
sweeps compose instead of fighting. Classification goes through the census's **shared classifier**
(extracted for this, behavior-pinned by the untouched census suite), and every re-seal goes through
the existing `sealAndWrite` path binding the existing seven AEAD purposes.

Convert is seal → in-memory verify → **index compare-before-write guard** → atomic write → disk
read-back, and nothing is ever deleted. That guard is the phase's sharpest fix: the two mutable index
manifests are re-read immediately before the write and proceed only on byte-equality, else
`skippedConcurrentlyModified`, which blocks the latch — closing the `loadIndex` → save →
orphan-sweep race in which a stale index write could permanently delete a raced-in friend photo's
files. An own-root file that fails to open is **probed against the wall key**: it opens ⇒ blocking
`legacyKeySealedOwnFile` (a state the key latch claims cannot exist, checked rather than assumed,
because that proof has a real hole); the wall key is unavailable ⇒ indeterminate. Two non-blocking
buckets are deliberately **split so the Phase-3 gate reads the right one**: `unopenableUnprefixed`
(bytes read, every key the legacy branch could ever pair them with tried, nothing opens — so
deleting the branch cannot change what any reader gets) versus `refusedPlaintext` (parseable
plaintext the pass refuses to launder into a born-sealed corpus, which never reaches that branch at
all).

The latch is deliberately **KEPT across delete-all**, on the revised rationale: the wipe empties the
own corpora, the surviving wall was proven all-current-or-named-residue before the latch could set,
and every post-wipe writer emits the current format — so the claim stays true of everything the wipe
leaves behind, and clearing it would only force a pointless re-scan. Both wipe rows landed in the
same commit.

Named limitations and residues, recorded rather than smoothed over. **Objection 2's limitation:** a
pre-sealing **non-JPEG** plaintext image (HEIC/PNG) in the meal corpus is an expected residue —
convert eligibility must not exceed the shared census's JPEG-magic sniff — and it is Phase-3-immune,
because `MealPhotoStore.imageData`'s plaintext branch serves and organically re-seals it without ever
touching the legacy open. Other named residues: the undrained `MeshPhotoCache.json`, and
`abortedNoWallKey` as a benign-pending state on a wall root holding only pre-sealing plaintext whose
`friendWall` keychain row was never minted — it holds the latch open, fail-closed and lossless, until
the organic exit at the first wall use. **Objection 4's compensating control:** iOS container
restores are progressive, so a pass running mid-restore can latch before the remaining legacy files
land; there is no guard for that, and instead the control is the census-vs-latch cross-check on a
real device — latch true while the census shows unprefixed counts beyond the named residues is that
scenario's signature — with the documented remediation being a `reset()` to force a re-scan.

### Phase 2.4 — `PendingNarrativeBuffer` migrator — **BUILT**

Landed in `81d65d9`. It runs at deferred launch on the **buffer key**, gated on nothing but "device
unlocked once since boot", and **never behind the app lock** — the second surface exempt from the
Phase 2 preamble's behind-the-lock sentence, after 2.1, and for a sharper reason than 2.1's: the
buffer exists to accept writes while both the app lock and the period-visibility gate are closed, so
a migrator gated on either would structurally never run for exactly the population still holding
legacy bytes. The scan is the census's own `take(of:)`; convert pins **one non-minting buffer-key
value end to end** through the existing v2 seal path, with read-back verification.

Bytes that are read with the key in hand and still will not open block as unconvertible and are never
deleted — consistent with the drain, which logs and keeps the file — because the census counts those
same bytes as legacy, and a latch over them would report "complete" while the actual Phase-3 gate
still reads 1. An absent file is an **earned** zero, not a vacuous one: the surface is transient (the
drain deletes it after a successful unlock-and-drain), the census makes the identical call, and only
`saveEntries` — which always writes v2 — can re-create it. The delete-all purge hook resets the latch
**first**, before the purge it wraps, so a kept latch can never outlive a tolerated purge failure.
Both wipe rows landed with the key.

The key-pinning split moved the module's single `// cryptographic-domain: legacy-read` marker out of
`loadEntries()` and into the new `decodeEntries` helper — **still exactly one** marker in
`PrivateStoreCore`, still the Phase 3 delete target. *Known stale, deliberately not fixed here:*
`PendingNarrativeBufferFormatCensus.swift:14`'s doc comment still attributes that branch to
`loadEntries()`; census files were out of scope for this pass, so the correction is owed to whoever
next touches that file, or to the final docs-vs-code reconciliation sweep.

### Phase 2.5 — `FernletLockService` content-key re-wrap — **BUILT**

Landed in `4b49175`; the diff-review fixes landed as `288e132`. The riskiest surface in the
plan — a failure here locks the user out of every sealed corpus — and the shape that answers it is
**one convert site, reached only with the credentials already in hand**: the `.legacyScryptWrapped`
unlock arm, after the scrypt unwrap has succeeded and before the Secure-Enclave hard-bind flip. The
migrator cannot be *constructed* without the recovered content key and the just-derived wrapping
key, so every other state is structurally a no-op rather than merely an unscheduled one. Zero new
purposes and **zero new derivations**: the new wrap comes out of the shipping `FLW2` writer through
the existing provider, same key, same AAD.

**The atomic recipe**, whose whole point is that no failure and no crash truncation can leave a row
that opens under neither branch: wrap → in-memory verify → **stage on a new sibling keychain row**
(`.wrappedContentKeyRewrapStaging`) → **read the staged row back fresh and prove it byte-identical
and unwrappable while the legacy wrap still stands untouched** → **single-transaction, update-only
promote** (`KeychainItem.updateReportingStatus`), where `errSecItemNotFound` aborts and the migrator
**never** falls back to creating a row — it must not mint custody state → live read-back → restore
the held old bytes on mismatch → verified staging delete with one retry and a loud audit if it still
fails. The generalized restore-before-reupload rule is satisfied: the proven-good artifact exists and
is verified before the only copy is superseded, the supersession is one transaction, and the old
bytes are held for restore until the new bytes are verified in place. Orphan lifetime is then bounded
independently of custody by an unconditional best-effort sweep in the **unlock tail** — placed after
the verifier match and before the custody switch, so it runs under every custody arm including
hard-bound and undeterminable — capping any staging orphan at the next successful passcode
verification. That placement is the phase's decisive finding: a legacy-arm-only cleanup would have
let the same unlock's hard-bind flip retire the only site that would ever have cleaned up, stranding
a scrypt-openable copy of the content key indefinitely. **A failed re-wrap never fails and never
slows the unlock** — every failure path is non-mutating with respect to the live row, the sole
exception being the restore of the bytes it held.

**Two named family deviations, recorded.** (a) **Credential-gated construction means no launch pass
exists** — not unscheduled, unconstructible — and the launch-time *observation* role the family's
launch pass would fill is already filled by the Phase-0 census row, which reads the same marker
through the same classifier; a second launch observer would only restate it. (b) **The row's own
`FLW2` marker IS the latch**: the `FormatMigrationLatching` witness is derived, `markComplete()` and
`reset()` are documented no-ops (the pass already wrote the record — the marker — and there is
nothing stored to clear), there is **no `UserDefaults` key and therefore no wipe rows owed**, and the
reset predicate equals the latch predicate because both are literally the same marker read. 2.2's
launch revalidation taken to its limit: observation beats memory, with no memory left to disagree.

**Five smaller implementer deviations from the design.** An absent row tallies
`examined: 0 / notApplicable: 1` rather than occupying the examined bucket; the S3–S5 failure paths
reuse S8's verified-with-retry staging delete instead of the design's plain best-effort one; T-25
lives in the migration suite rather than a KeychainHelpers suite (none exists); T-27 folded into the
hard-bound custody test rather than standing alone; and **both** `PrivacyWipeCoverage.md` duress rows
were edited (wipe and recovery-lock), not one. The new staging row joined the key-custody wall,
`destroyLocalUnlockKeys`, and both coverage rows in the landing commit — the same-commit rule applied
to a keychain row rather than a defaults key.

**Post-landing review.** An adversarial diff review over three lenses returned 10 findings, **0
fatal**; the fixes landed as `288e132` (boundary gate on it: 3244 tests / 291 suites green, both
scanners clean, zero gate fixes).

### Phase 3 — Delete the Class-A legacy readers

Gated on census = 0 for that surface, on real tester devices, not just simulators. Also close
`ColumnCrypto.sealPlaintext`'s `purpose-derived legacy-write` fail-open: once no device can produce
an unbound write, the branch that seals without a binding should refuse rather than silently write an
un-domained blob a future census would count.

Two surfaces have now recorded a gate more specific than "census = 0", and the specific reading is
the one that governs:

- **`HeartDropSidecarKey` — the zero-gate is PER ROW, not aggregate.** Zero `legacySealed` on the
  three MAIN rows (outbox, peer bundles, dedup). `outboxQuarantine` is **excluded** from the gate:
  no reader ever opens the quarantine path, so a legacy tombstone sitting there is not a reader
  dependency — and folding it into an aggregate count would strand the gate forever on bytes whose
  format cannot matter to anything.
- **`MediaAtRestCrypto`** — the latch set on a real upgraded device, **and** the census's unprefixed
  count equal to that device's audited named residues (Phase 2.3's list: non-JPEG pre-sealing
  plaintext, the undrained `MeshPhotoCache.json`, the benign-pending keyless wall root), **and**
  `hasBlindSpots` false. A latch alone does not discharge it, and neither does a raw census number
  without the residue audit beside it.
- **`FernletLockService` wrap** — the census reads 0 on a real upgraded device, either as a
  `v2Marked` row or as an absent row with an *earned* reading (no lock configured, enclave-bound, or
  a wrap that has gone missing — the row's three honest absences). The 2.5 **row-latch licenses
  nothing by itself**: it is a derived read of the same marker the census reads, so quoting it as the
  gate would be quoting the gate to itself. `malformedEmpty` and `unreadable` are not zeros.

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
- [x] Phase 2.1 — `SealedPhotoBackupService` migrator (source `db40984`; tests/docs commit follows.
      `AsyncFormatMigrator` sibling + the policy shell over the existing healing reconcile, zero new
      crypto; latch key landed with both wipe-wall rows. Three planned pins deferred as recorded
      testability residuals — see the phase section)
- [x] Phase 2.2 — `HeartDropSidecarKey` migrator (`5ca478e`; scan IS the census survey, quarantine
      row reported-never-blocking, launch revalidation of a set latch; Phase-3 gate is per-row)
- [x] Phase 2.3 — `MediaAtRestCrypto` migrator (`810c45f`; converts only the `OwnPhotoKeyMigrator`
      complement, shared classifier, compare-before-write index guard; latch KEPT across delete-all,
      named residues recorded for the gate)
- [x] Phase 2.4 — `PendingNarrativeBuffer` migrator (`81d65d9`; runs on the buffer key, NOT behind
      the app lock — the buffer exists to work while locked; absent file is an earned zero, purge
      hook resets the latch first)
- [x] Phase 2.5 — `FernletLockService` content-key re-wrap (`4b49175` + fixes `288e132`, merged to
      main 2026-08-28. Staged, read-back-proven, update-only promote at the sole credential-gated
      convert site; the row's own FLW2 marker is the latch — no UserDefaults key, two recorded
      family deviations. Adversarial diff review: 10 findings, 0 fatal, all seven accepted fixes
      applied; boundary gate 3244 tests / 291 suites green, zero gate fixes)
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
- Phase 2.1: ~1.6M. Big consumers: the 5-agent design workflow (~894k — expensive and worth it:
  two fatal design holes caught before a line of source existed), the implementer (~282k), the
  test writer (~161k), the docs pass (~64k), one gate run (~120k). The gate needed five fixes but
  only ONE full-suite run — the batch-review-fixes-first lesson from Phase 1 held. Remaining at
  the boundary: ~15.0M.
- Phases 2.2–2.4 (one batch): ~3.0M. Big consumers: the 12-agent three-surface design workflow
  (~1.85M — again the largest and again load-bearing: all seventeen accepted objections, including
  the 2.3 index-orphaning must-fix, predate any source), three sequential implementers who each
  self-verified with a targeted suite run (~294k/~296k/~378k), the docs pass (~62k), one combined
  gate run (~97k) that was green FIRST PASS with zero fixes — the implementer-self-verifies
  pattern paid for itself. Remaining at the boundary: ~15.0M.
- Phase 2.5: ~2.1M. Big consumers: the design workflow (~913k), the implementer across the landing
  and the fix round (~441k), the post-landing adversarial DIFF review (~534k — new for this surface,
  and it earned its cost: three must-fix test-strength holes on the lockout path), the docs/plan
  record (~60k), the gate (~150k, green first pass). Process notes from a peer session's transcript
  audit, adopted mid-phase: the `tail -f | grep -m1` build-wait blocked ~10 min per build all
  session (fix: foreground with explicit timeout, or Bash run_in_background + notification — now a
  standing rule); and failed builds get ALL diagnostics read in one pass, not one fix per rebuild.
  A session usage-window limit killed two agents mid-phase; both resumed cleanly after the reset.
  Remaining at the boundary: ~15.0M.

### Handoff to the Phase 3 session (written at the 2.5 boundary)

The loop that built Phases 1–2.6 ran in ONE session context via self-paced wakeups — contrary to
the loop prompt's belief, nothing compacts between phases, so Phase 3 MUST start as a fresh session
reading this file (the loop stops itself at the 2.6 boundary by owner instruction, 2026-08-28).
What the fresh session needs:

- **Branch state:** work lands on `claude/admiring-moser-43ae1d` and merges ff-only into main from
  the primary checkout after each phase boundary (never `update-ref`; check main has not moved
  first). Nothing is pushed — pushing stays a human step.
- **Hard gates before ANY legacy-reader delete (Phase 3):** per-surface census zeros on a REAL
  upgraded tester device — simulator zeros do not discharge them. Per-surface wordings live in the
  Phase 3 section: sidecar is per-row with the quarantine excluded; media is the three-part gate
  (latch + census residues + no blind spots); ColumnCrypto needs the keyed migrator's clean pass as
  the second witness; sealed-photo reads `minimumEntryHashVersion >= 2` across the three corpora.
- **Phase 4 is BLOCKED on owner decision D1** (§5) — no Class-B site is touched until it lands.
- **Recorded testability residuals:** 2.1's P10/P17/P19 (`.standard` latch seams, private
  teardownEpoch, private view predicates); 2.3's named residues (non-JPEG plaintext, undrained
  MeshPhotoCache.json, abortedNoWallKey benign-pending); 2.5's untestable-in-process promote
  atomicity (pinned instead via the update-only seam tests).
- **Build discipline:** private -derivedDataPath per gate; build-for-testing once then
  test-without-building; judge exit codes and include Swift Testing's "failed after" in greps;
  NEVER wait on a build with `tail -f | grep -m1` (it blocks the full Bash timeout) — foreground
  with explicit timeout for short runs, Bash run_in_background + completion notification for the
  full phase; read every diagnostic from a failed build in one pass.

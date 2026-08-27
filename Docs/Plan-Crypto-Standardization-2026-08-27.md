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
blocked on **Phase 1 adding a `hashVersion` marker to manifest entries** (default 1 on decode;
manifest-level minimum computed at write; self-propagating, since the manifest is re-encoded wholesale
each pass) — not on a census. The census row for this surface is static text saying so.

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

### Phase 1 — Generalize the migrator that already works

`PrivateMediaStore/OwnPhotoKeyMigration.swift` is a complete, shipping model: `run(maxPasses:)`,
`performPass()`, `candidateFiles()`, and a UserDefaults-backed latch (`markComplete()`, `reset()`).
Lift its shape into a shared protocol (`FormatMigrator`: scan → convert → latch, bounded passes,
resumable, idempotent) and keep `OwnPhotoKeyMigrator` as its first conformer to prove the
generalization is behavior-preserving.

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

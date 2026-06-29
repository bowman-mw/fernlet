# Follow-up plan — Sealed-backup escrow recovery + "nothing silent" settings (2026-06-28)

Status: **proposed follow-up** (not started). Spun out of the S3-hardening review
(branch `s3-hardening-followups`, commit `4a18528`). The hardening commit fixed the
backup-exclusion default and the sealed-store exclusion path; this plan covers the
**escrow-key provisioning race** (review finding #4) and turns the app's
destructive-settings behavior into a **fully non-silent** contract.

---

## Guiding principle (security-first, non-negotiable)

> **Nothing destructive happens silently.** Any action that deletes data, removes a
> recovery path, or can strand/lose user data — whether triggered by a Settings
> toggle, a migration, or a background reconcile — MUST be surfaced to the user
> **before** it happens, naming *exactly which data* and *why it can't be recovered*,
> and MUST require explicit confirmation. Failures (e.g. a restore that can't
> complete yet) MUST be visible and retryable, never swallowed. Every such event is
> also written to `FernletAuditLog`.

This is stricter than "no data loss": even *recoverable* actions get an honest
warning, because in a privacy-first app the user's mental model of "where is my
data and can I get it back" must always be correct.

---

## Problem 1 — Escrow-key provisioning race (review finding #4)

### Background
Cross-device sealed-backup restore was enabled by binding backups to the
**`backupEscrowPrivateKey`** (X25519, stored `synchronizable: true` so iCloud
Keychain replicates it across the user's devices). `SealedBackupCrypto.seal`/`open`
derive the AES-GCM key from it via `IdentityService.sealedBackupKey()`.

### The race
`IdentityService.ensureProvisioned()` (FernletKit/Sources/ProximityKit/Identity/IdentityService.swift)
branches on what is *currently present* in the local keychain at first launch:
- **Case 2** — escrow key already synced in → adopt it. ✅ correct new-device path.
- **Case 4** — no keys present → mint a **brand-new** escrow key, stored
  `synchronizable: true`.

iCloud Keychain sync is asynchronous with **no completion signal**. If first-launch
provisioning wins the race against the sync, Case 4 fires and mints a **divergent**
escrow key. Consequences:
1. Restore of the origin device's backups fails AES-GCM auth ("not mine").
2. The device publishes its *own* `synchronizable` escrow item under the same
   account; when the genuine key later syncs in, iCloud Keychain has a duplicate →
   last-writer-wins resolution could overwrite the real key on other devices too.

### Severity / likelihood (honest calibration: low–medium, "plausible")
- Common path is fine: iCloud Keychain restores during device setup, before the
  user opens third-party apps → Case 2 wins.
- Bites the tails: fresh *second-device* install opened immediately (not a restore);
  iCloud Keychain slow/offline/not-yet-approved; app launched mid-setup.
- Most outcomes are recoverable (origin device still has the data); the
  poison-all-devices outcome requires the conflicting write to win (unlikely).
- Pre-existing infra that the escrow-binding feature now *depends on*; documented
  in-code as a KNOWN RESIDUAL (IdentityService Case 2).

### Why not just "wait for sync"
There is no completion signal for iCloud Keychain, and blocking first launch on it
would hang the app. The fix is about **not minting a divergent synchronizable key
prematurely** and **detecting/healing a late key visibly**.

---

## Workstreams

### WS-1 — Defer escrow-key generation to first genuine need *(the "right depth" fix)*
At first launch generate only signing + KA (device-only — no race). Generate the
escrow key **lazily**, only when the user actually enables a sealed backup, and
only after re-querying the keychain for a synced key.

- Sealed backups are **off by default** (`sealedBackupSensitiveNotesEnabled` /
  `sealedBackupPeriodEnabled` default `false`), so enabling almost always happens
  long after first launch → the escrow key has time to sync; the race nearly
  vanishes.
- **Seal path**: mint-if-absent is acceptable, but re-check the keychain for a
  synced key first.
- **Open / restore path**: MUST NEVER mint an escrow key. Absent key = "not synced
  yet" → defer + retry (WS-4), never fabricate a new identity.
- Risk: provisioning is delicate and shared with proximity; needs targeted tests
  and a re-read of every `ensureProvisioned`/`sealedBackupKey()` caller.

### WS-2 — Never publish a freshly-minted escrow key as `synchronizable` until confirmed *(blast-radius reduction; do first)*
When a device must mint an escrow key, store it **`ThisDeviceOnly`** first; promote
to `synchronizable` only on a later launch once no conflicting synced key has
appeared. This eliminates the *worst* outcome (cross-device key conflict). A
divergent local key then breaks only that one device's cross-device restore.

- Small, contained change to the Case-4 (and Case-1 "generate if absent") branches.
- Pairs with WS-3 to promote/reconcile safely.

### WS-3 — Detect a late-arriving / conflicting escrow key and reconcile *(non-silent; most complex; do last)*
On launch (or before seal/open), compare any synced escrow key against the local
one.
- If a **different** synced key arrives after the device minted its own: do **NOT**
  silently overwrite either side. Surface to the user (per the guiding principle):
  *"We found the backup key from your other device. To keep your encrypted backups
  in sync across devices, this device will switch to it; backups made only on this
  device may need to be re-uploaded."* — with an explicit choice and an audit entry.
- Re-sealing local backups under the authoritative key needs unlock + re-upload →
  always user-initiated and explained, never background-silent.

### WS-4 — Restore failures: visible & retryable, never silently terminal
When `open()` / restore can't complete because the escrow key isn't present/matching
yet:
- Do **NOT** mark restore "done" and move on. Distinguish:
  - *"Not synced yet"* → retryable state + user-visible status: *"Couldn't restore
    your private backup on this device yet — iCloud Keychain may still be syncing.
    We'll keep trying, or tap Retry."*
  - *"Genuinely not yours / corrupt"* → distinct, honest message.
- Audit-log every restore attempt and outcome.
- Today `restoreSealedBackup` returns `false` on any failure (broad catch); split
  the outcomes so the retry/visible path is reachable.

---

## Problem 2 — "Nothing silent" settings audit *(directly from the user's directive)*

The app already confirms some *constructive* actions ("Turn on iCloud sync?", "Turn
on encrypted backup?", "Delete all protected data?" — `PrivacyDataSettingsView`).
The gaps are the **destructive directions** that currently happen with no warning.

### WS-5 — Warn before every destructive/irreversible settings action
Audit every toggle/action and add an explicit, data-specific confirmation **before**
the change commits. Reuse the existing `.alert` pattern for consistency.

| Action | What it destroys / strands | Required warning (before commit) |
| --- | --- | --- |
| **Turn OFF a sealed backup** (period / sensitive notes) → `reconcile(enabled:false)` → `deleteSealedBackup` tears down the whole chunk set | Permanently deletes that encrypted backup from iCloud | "This permanently deletes your encrypted [period / notes] backup from iCloud. If you lose or replace this device, that data can't be recovered. Turn off anyway?" |
| **Exclude local data from iOS backup** (`localBackupExcludedFromiOSBackup` → on) | Drops the sealed store (journals, intimate logs, cycle notes — no cloud recovery, ThisDeviceOnly key) from device backups | "Excluding from device backup means your journals, intimate logs, and cycle notes won't be in any iPhone backup. Because they're encrypted with a key that never leaves this device, erasing or losing this device would lose them permanently. Exclude anyway?" |
| **Turn OFF iCloud sync** (if it drops synced data / detaches recovery) | Verify whether disabling sync removes any recovery path | If yes: name it and confirm. If purely local-retaining, state that plainly (still non-silent, but reassuring). |
| **Disable HealthKit master / a capability** → cache teardown (`HealthKitDisableTests` covers fail-closed purge) | Deletes cached clinical data Fernlet holds | "Turning this off removes the [activity/cycle/…] data Fernlet has cached on this device. (Your data stays in Apple Health.) Continue?" — confirm it really only drops the cache, not Health itself. |
| **Change passcode / disable lock / reset** | If it can drop or rotate the content key and strand sealed data | Confirm + explain any recovery implication. |
| **Escrow reconciliation re-link** (WS-3) | May require re-uploading device-local backups | Per WS-3 wording. |

General rule to encode: **any setting whose change deletes data or removes a
recovery path renders a confirmation sheet that (1) names the exact data, (2) states
whether it's recoverable and how, (3) requires an explicit destructive-role
confirm.** Add a tiny reusable helper so new destructive toggles can't ship without
one.

---

## Sequencing & priority

1. **P0 — WS-2 + WS-4** (small, high value): stop publishing premature synchronizable
   keys (kills the worst outcome) and make restore non-silent/retryable.
2. **P0 — WS-5** (the user's directive; independently valuable): destructive-settings
   warnings, starting with *turn-off sealed backup* and *exclude-from-iOS-backup*.
3. **P1 — WS-1**: deferred escrow generation (the proper correctness fix).
4. **P2 — WS-3**: late-key reconciliation (most complex; do last, with care).

## Verification
- Unit: deferred escrow gen; `open()` never mints; restore splits "retry" vs
  "not yours"; reconcile surfaces (not silent); each destructive toggle presents its
  warning and only mutates on confirm.
- Two-device manual test of the race: provision a fresh device *before* escrow sync →
  confirm it does NOT mint a divergent synchronizable key and restore retries.
- Audit-log assertions on every failure/destructive path.
- Re-run `Scripts/spm-wall-check.sh` (touches IdentityService/ProximityKit + app).

## Open questions to resolve before coding
- Exact sealed-backup *enable* flow to hook lazy escrow generation
  (`SealedBackupCoordinator` / `PrivacyDataSettingsView`).
- iCloud Keychain duplicate-`synchronizable`-item conflict resolution semantics
  (needs device testing to confirm WS-2's assumption).
- Whether disabling iCloud sync / a HealthKit capability removes any recovery path
  (determines WS-5 wording).
- Whether `deleteSealedBackup` / disable currently has *any* confirmation (audit
  shows the ON paths do; confirm the OFF paths don't).

## Out of scope (tracked elsewhere / accepted)
- Static escrow key has no forward secrecy (accepted; documented at
  `IdentityService.sealedBackupKey()`). Optional future: per-generation HKDF salt.
- `SealedBackupCrypto.open()` propagating `IdentityError.notProvisioned` instead of
  `malformedRecord` (kept — the precise error is more correct; caught generically).

---

## Implementation status — 2026-06-28 (branch `s3-hardening-followups`)

**All five workstreams landed.** Resolutions to the open questions and what shipped:

### Open questions — resolved
- **Enable flow / lazy escrow hook.** `PrivacyDataSettingsView.handleSealedBackupToggle(true)`
  → confirm → `applySealedBackup` → `FernletStore.setSealedBackupEnabled(true)` →
  `SealedBackupCoordinator.setSealedBackupEnabled` → `makeIdentity(escrowMode: .forSealing)`
  → `IdentityService.provisionBackupEscrowKeyForSealing()` (mints **ThisDeviceOnly** if
  absent, after re-querying for a synced key) → `seal`. The open/restore path uses
  `escrowMode: .forOpening` → `loadBackupEscrowKeyForOpen()` which **never mints**.
- **iCloud Keychain duplicate-`synchronizable` semantics.** *Now confirmed from Apple's
  open-source `SecItemDataSource.c` conflict resolver + patents US9077759B2 / US9479583B2:*
  `kSecAttrSynchronizable` (and the access group) are part of the keychain primary key, so two
  `synchronizable` rows sharing service+account are ONE logical slot account-wide; divergence
  resolves by **newest `kSecAttrModificationDate` wins** (SHA-1-digest tiebreak only on an exact
  date tie), with no value coexistence and no app-visible merge callback. **Refinement to WS-2:**
  because the genuine key is the *older* write, withhold-and-promote *reduces* the chance a
  divergent key ever reaches the synced slot (common path: the genuine key syncs in by the next
  launch and `reconcileBackupEscrowKey` adopts it instead of promoting) but does **not guarantee**
  the genuine key survives if it is still in flight when a divergent local key is promoted — the
  newer divergent key would win. The real safety net is the **non-silent `.conflict` surface +
  WS-4 visible/retryable restore**, not promotion timing. This is a self-inflicted single-user
  race, mostly recoverable from the origin device (an attacker who can write this slot already
  holds the user's iCloud Keychain). *Empirically confirmed on the test host* that a
  `synchronizable` row and a `ThisDeviceOnly` row coexist as distinct items separable via
  `KeychainItem.SynchronizableScope.{synced,local}` — the conflict/promotion unit tests exercise
  this. Cross-*device* convergence is still the two-device-manual part (below).
  **Tracked follow-up — NOW SHIPPED (content-addressed slot, 2026-06-28).** The residual above is
  eliminated by Option 1 (content-derived slot). Each escrow key is now stored at a keychain account
  derived from a hash of its OWN public key (`IdentityService.escrowKeychainAccount(forPublicKey:)`),
  so two *different* keys occupy *different* accounts → distinct iCloud-Keychain slots that **coexist
  instead of resolving by newest-wins**. A promote/publish therefore always targets the publishing
  key's own slot and can only ever overwrite an identical copy of the same key — never a different
  (genuine) one. Divergence becomes an additive, detectable `.conflict` (≥2 coexisting keys), surfaced
  non-silently exactly as before, and because all keys survive the origin's backups are always
  recoverable — `SealedBackupCrypto.open` now tries *every* surviving key (decrypt-first,
  `sealedBackupKeyCandidates`), so restore even works through an unresolved conflict with no manual
  step. Zero-config recovery is preserved: the common path is exactly one key, adopted automatically;
  the legacy fixed account is still *read* for back-compat but never *written*. See the §"Implementation
  status" addendum below.
  *Option 2 (signed escrow envelope) was evaluated and rejected:* whatever key signs the envelope, a
  divergent escrow key is itself a legitimately-generated Fernlet key that signs its own envelope and
  verifies fine, so signing only catches corruption/foreign garbage (which AES-GCM auth already
  rejects) — and once newest-wins clobbers the genuine bytes on a shared slot, no envelope can recover
  them. It is strictly weaker than content-addressing and does not eliminate the residual.
- **Does disabling iCloud sync / a HealthKit capability remove a recovery path?**
  - *iCloud sync OFF*: "Stop syncing, keep iCloud data" is local-retaining (reassuring copy
    kept). "Delete iCloud data" **does** delete sealed backups (`SealedBackupRecord` is in
    `recordTypesForDeletion`) — the confirmation copy now names encrypted backups explicitly.
  - *HealthKit master OFF*: fail-closed cache purge of cached clinical values; the data stays
    in Apple Health → warning says exactly that. *A single capability toggle does NOT purge*
    (it only updates prefs), so it is non-destructive and intentionally carries no warning.
- **Did the OFF paths have any confirmation?** No — turn-OFF sealed backup, exclude-from-iOS-
  backup, and HealthKit-master-disable all committed silently. Now each routes through the
  shared `DestructiveConfirmation` helper. (Passcode *change* re-wraps the same content key —
  non-destructive, no warning; `reset()` already had its alert.)

### What shipped (by file)
- `FernletKit/.../FernletFoundation/KeychainHelpers.swift` — `SynchronizableScope` on
  `load`/`delete`; `store(replacing:)` so promotion removes only the local row.
- `FernletKit/.../ProximityKit/Identity/IdentityService.swift` — **WS-1** deferral
  (Case 1/4 never mint escrow); **WS-2** `provisionBackupEscrowKeyForSealing()` mints
  ThisDeviceOnly; `loadBackupEscrowKeyForOpen()` (never mints); **WS-3**
  `reconcileBackupEscrowKey()` (adopt / promote-on-later-launch / conflict) +
  `adoptSyncedBackupEscrowKey()`.
- `Fernlet/SealedBackupCoordinator.swift` — **WS-4** `SealedBackupRestoreOutcome`
  (restored / nothingToRestore / skippedStoreNotEmpty / deferredKeyNotSynced /
  deferredLocked / deferredTransient / notRecognized); split classification; escrow
  reconcile at launch; conflict re-link (`adoptSyncedEscrowAndReupload`).
- `Fernlet/FernletStore.swift` — observable `sealedBackupRestoreStatus` /
  `sealedBackupEscrowConflict`; `SealedBackupContext` recording callbacks.
- `Fernlet/DestructiveConfirmation.swift` (new) — reusable helper + `.destructiveConfirmation`
  modifier (mutation only runs on confirm).
- `Fernlet/PrivacyDataSettingsView.swift` — **WS-5** warnings on turn-OFF sealed backup,
  exclude-from-iOS-backup, HealthKit-master disable; enriched iCloud-delete copy; **WS-3/WS-4**
  status banner with Retry + "Use my other device's key".

### Audit events added
`identity.escrow.{mintedLocal,promotedLocal,conflictDetected,adoptedSynced}`,
`sealedBackup.{restoreAttempt,restoreDeferredKeyNotSynced,restoreDeferredLocked,
restoreNothingToRestore,restoreNotRecognized,escrowConflict,escrowAdopted,…}`,
`privacy.{sealedBackup.*DisableConfirmed,localBackup.excludeConfirmed,
healthKit.masterDisableConfirmed,sealedBackup.retryRestore,resolveEscrowConflict}`.

### Tests
- `IdentityServiceEscrowTests` — deferred gen, open-never-mints, ThisDeviceOnly mint,
  adopt-synced-over-mint, reconcile promote/adopt/conflict (no overwrite), adopt resolves.
- `SealedBackupRestoreOutcomeTests` — outcome semantics + host status recording.
- `DestructiveConfirmationTests` — mutation deferred until confirm.
- `SealedBackupTests` / `SealedBackupChunkTests` / `CloudKitDataServiceTests` updated to the
  new seal contract (`provisionBackupEscrowKeyForSealing` before sealing).
- `PrivacyDataSettingsUITests` — HealthKit-disable warns + confirm/cancel; exclude-backup
  warns + cancel-keeps-included (all green).
- `Scripts/spm-wall-check.sh` re-run → **WALL CHECK PASSED**.

> **Pre-existing, out of scope:** `PrivacyDataSettingsUITests.testICloudDisableShows…`
> (two cases) assert a `"Delete iCloud data?"` string that does not exist on this branch (the
> disable sheet header is `"Turn off iCloud sync?"`). They fail independently of this work — not
> touched here to avoid bundling unrelated changes.

### Two-device manual race test (cannot run in CI — requires two real devices + one Apple ID)
1. Device A: enable a sealed backup (e.g. period). Confirm in the keychain/audit that the
   escrow key is minted **ThisDeviceOnly** (`identity.escrow.mintedLocal`), not synced yet.
2. Relaunch A once → `identity.escrow.promotedLocal` (it publishes the key only on a later
   launch). Wait for iCloud Keychain to propagate.
3. Device B (fresh install), **opened immediately before the escrow key syncs**: confirm
   provisioning does NOT mint a divergent `synchronizable` escrow (WS-1) — Privacy & Data
   shows the "iCloud Keychain may still be syncing… Retry" status (WS-4), not a silent
   success, and no second escrow row appears under the account.
4. Once the key syncs to B, tap **Retry** → restore completes.
5. Force the conflict: enable a sealed backup on B *before* A's key syncs (B mints its own
   local key), then let A's key sync in. On B's next launch, confirm the **non-silent escrow
   conflict** banner appears and neither key is overwritten until the user taps
   "Use my other device's key" (`identity.escrow.{conflictDetected,adoptedSynced}`).

---

## Implementation status addendum — content-addressed escrow slot (2026-06-28, branch `s3-hardening-followups`)

**Optional hardening from the "Tracked follow-up" above is now SHIPPED.** Option 1 (content-derived
keychain slot) is implemented; Option 2 (signed envelope) was evaluated and rejected as strictly
weaker (it cannot distinguish a divergent-but-legitimate key, and cannot recover bytes already lost to
newest-wins). The residual where a divergent (newer) escrow key could silently overwrite the genuine
(older) one cross-device — permanently stranding the origin's backups — is **eliminated**: divergent
keys now land on different content-addressed accounts and **coexist** rather than overwriting.

### What shipped (by file)
- `FernletKit/.../FernletFoundation/KeychainHelpers.swift` — `KeychainItem.loadAll(service:synchronizable:)`
  to enumerate all rows under a service (a fresh device does not know a content-addressed account a priori).
- `FernletKit/.../ProximityKit/Identity/IdentityService.swift` —
  - `escrowKeychainAccount(forPublicKey:)` (public, nonisolated, pure): the per-key account = `"backupEscrowPrivateKey.k." + sha256hex(pub)`.
  - `gatherEscrowCandidates()`: enumerates content-addressed slots (synced + local) **and** the legacy
    fixed account, coalesces each key's rows, integrity-checks each CA row (`account == hash(pub)`),
    and orders deterministically (synced first, then by pubkey-hash) so every device picks the same
    canonical key with no coordination.
  - mint (`provisionBackupEscrowKeyForSealing`), promote/adopt (`reconcileBackupEscrowKey`,
    `adoptSyncedBackupEscrowKey`), and `ensureProvisioned` Case 3 all write **content-addressed**, never
    the legacy fixed account. `reconcile` returns `.conflict` for ≥2 coexisting keys (no overwrite).
  - **Legacy-key migration:** when reconcile adopts a genuine key that still lives ONLY at the legacy
    fixed account, it ADDITIVELY copies it to its content-addressed slot
    (`identity.escrow.migratedLegacyToContentAddressed`) so upgraded users' legacy-origin keys gain the
    same overwrite-immunity — the legacy row is left intact (old builds keep reading it) and the identical
    bytes coalesce to one candidate (no false conflict, zero-config recovery preserved). The legacy
    account itself is still never *written*.
  - `sealedBackupKeyCandidates()`: every escrow AES key the device holds (adopted first), for try-all-keys open.
- `Fernlet/SealedBackupService.swift` — `SealedBackupCrypto.open` now tries every candidate key
  (decrypt-first; the tag remains only an error-classification hint), so a record sealed under a
  *surviving-but-not-adopted* key (an unresolved conflict) still restores with no manual step.

### Behavioral guarantees preserved
- Zero-config cross-device recovery: common path = exactly one key, adopted automatically.
- The legacy fixed account `"backupEscrowPrivateKey"` is still **read** (back-compat for pre-content-
  addressing devices) but never **written** — in a pure new-build fleet it is never overwritten again.
- WS-1 (deferred gen / open-never-mints), WS-2 (mint ThisDeviceOnly, promote on a later launch), WS-3
  (`.conflict` outcome + non-silent UX), WS-4 (retryable restore) all unchanged at the API/UX level.

### Tests
- `IdentityServiceEscrowTests` — rewritten for content-addressed accounts; new tests:
  content-addressed-account determinism/uniqueness, conflict leaves BOTH coexisting keys intact
  (the core residual eliminator), `sealedBackupKeyCandidates` exposes the full set, legacy fixed-account adoption.
- `SealedBackupTests` — cross-device test updated to the CA account; new tests: record sealed under a
  surviving non-adopted key still opens (try-all-keys), legacy fixed-account seal+open round-trip.
- All escrow / sealed-backup / CloudKit-data suites green; `Scripts/spm-wall-check.sh` → **WALL CHECK PASSED**.

### Residual now (honest)
- A genuine ≥2-key conflict between two **synced** keys (both devices published before convergence)
  still surfaces repeatedly until the user/devices converge; `adoptSyncedBackupEscrowKey` only drops
  this device's *local* divergent key (never a synced one), so nothing is destroyed cross-device. Data
  is never lost — restore tries all surviving keys. This is the irreducible "two devices each made a
  key" case, and it is non-silent by design.
- Two-device manual race test (above) still applies, with the added confirmation that **no key is ever
  overwritten** on the shared account (there is no shared account anymore) — both rows persist under
  their distinct content-addressed accounts.

### Pre-merge multi-agent review (2026-06-28)
A 6-dimension adversarial review (crypto, keychain, state-machine, back-compat, tests, API-contract),
each finding refute-verified, returned **SAFE TO MERGE — 0 blockers**. Two non-blocking findings were
folded in before merge: legacy-key migration (above, finding A) and a negative test for the CA-row
integrity guard (finding B). One **deferred perf follow-up (finding C, non-blocking):** chunked restore
calls `sealedBackupKeyCandidates()` per chunk → O(4·chunkCount) `SecItem` queries. No correctness impact
(the candidate set is identical across chunks — synchronous `@MainActor`, no interleaved awaits; all-or-
nothing is enforced by GCM AAD chunk binding, not candidate-set stability) and it is a cold one-time
new-device path with realistically 1–2 keys. Optional optimization: resolve candidates once in
`restoreChunks` and pass them into a candidates-taking `open` overload (keep the per-call API for
single-record callers).

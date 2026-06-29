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

# Plan — Security hardening, OPUS TRACK: scoped-unlock rebase, crypto-erasure, salted escrow, backup coverage, SE-binding, media split, duress PIN (2026-08-10)

**Status:** Approved build plan, Opus review track. Base branch `main` @ `eeec53e`; the first work is
the crypto-seam rebase of the unmerged `claude/scoped-unlock-per-screen` (`b293238`) onto current
`main`, resolving its `unlock()`/`configure()`/`reset()` conflicts with the `d68ca9a` SE-wrap. Every
file:line below was checked read-only at those revisions across `FernletLockService.swift`,
`SecureEnclaveContentKeyWrap.swift`, `ColumnCrypto.swift`, `PrivatePersistenceController.swift`,
`SealedBackupService.swift`/`SealedBackupCoordinator.swift`, `IdentityService.swift`, the
`PrivateMediaStore` corpus, `FernletStore.swift`, and the wall/custody test + doc surfaces —
**re-verify against the Phase-0 rebased tree before writing code.**

This is the **crypto-critical / irreversible / novel-trust-model** track. It carries the six Opus
workstreams: the shared Phase-0 rebase; the **crypto-erasure normalization** (the redesign half of the
deletion audit — content-key destruction + keyless store rebuild); Hardening **#4** (v2
per-generation-salt escrow format); **journal + intimacy backup coverage** (the §6.1 prerequisite);
Hardening **#1** (hard SE-binding); Hardening **#3** (media-key split + own-photo device-binding +
escrow photo route); and the **duress PIN** (decoy / silent-wipe+decoy / recovery-lock). Between them
they close three of the six open owner decisions in [`Verifiability.md`](Verifiability.md) §6 — **#1
(§6.1)**, **#3 (§6.3)**, **#4 (§6.4)** — and land two of the 2026-08-10 new asks (the crypto-erasure
baseline and the duress PIN), plus the §6.1-blocking backup-coverage extension.

**Sibling file / track split.** The lower-risk, mechanical, reversible, no-novel-crypto items live in
[`Plan-Security-Hardening-FableTrack-2026-08-10.md`](Plan-Security-Hardening-FableTrack-2026-08-10.md):
**PIN-before-biometrics** (Phase 0), the **`RecipeWebImageAttemptMemory` wipe-coverage gap fix**
(Phase 0/1), the **deletion-audit verification pass** (the verify-`PrivacyWipeCoverage.md`-against-code
half of Phase 1, *not* the crypto-erasure redesign here), and Hardening **#6** (default-on backup
exclusion, §6.6, Phase 6). **The fixed global phase order (0→7) spans both files; neither file
re-sequences it.** Cross-track edges are called out in §4.

The through-line is the standing Fernlet posture from `Verifiability.md`: **a privacy claim is only as
good as the machine that checks it, and every trade must be a loud, reviewable diff.** Every phase
below carries its custody-tripwire, wall, and same-commit doc obligations for exactly that reason —
and because this track destroys keys and inverts recovery properties, "keep-old-until-verified" and
"gate the destructive flip on a completion latch" are the recurring discipline.

---

## 1. What this track plans, at a glance

Six Opus workstreams across the global 0–7 order. Phase 6 (**#6**) is a Fable phase and still sits
between Phases 5 and 7 in execution — it is shown here only as a boundary marker.

| Global phase | Opus workstream (one-line goal) | Risk | Inverts a recorded decision? |
|---|---|---|---|
| **0** | Rebase `claude/scoped-unlock-per-screen`; resolve the `unlock()/configure()/reset()` crypto-seam conflicts against the `d68ca9a` SE wrap — the shared foundation both tracks build on | Medium | No |
| **1** | **Crypto-erasure normalization** (redesign half): content-key destruction + a keyless `FernletPrivate` store rebuild so the locked corpus is honestly erased, and the forensically-real funnel the duress WIPE reuses | Medium | No (normalizes honesty; no behavior inversion) |
| **2** | **#4 v2 per-generation-salt escrow format** — each generation gets its own HKDF salt; versioned, coexists with v1 records in the wild; landed first so the Phase-3 payloads never write v1 | Medium | No |
| **3** | **Journal + Intimacy join the escrow-sealed backup**, launched directly on v2; Worry Box deliberately excluded | High | **Yes** — reverses the earlier "intimacy not in backup" call |
| **4** | **#1 hard SE-binding** — delete the scrypt-wrapped legacy content key once the SE wrap verifies; sealed corpus + full keychain dump useless off-device even with the passcode | High | Resolves §6.1; trades away same-device encrypted-backup restore for non-escrow types |
| _(6)_ | _(Fable) #6 default-on backup exclusion — shown only as a sequencing marker; see the sibling file_ | _—_ | _—_ |
| **5** | **#3 media-key split** (own photos vs friend wall) + a per-photo **escrow photo route**, then **device-bind the own-photo key** | High | **Yes** — reverses the documented "media key is backup-restorable" decision, own photos only |
| **7** | **Duress PIN** — decoy / silent-wipe+decoy / recovery-lock, chosen per setup; reuses the delete funnel, the #1 SE-binding finality, the scoped-lock API, the hide machinery, and the QR/mesh/X25519 stack | High | **Yes (scoped)** — the WIPE mode inverts "app-lock survives a wipe", on a duress-only seam |

---

## 2. Locked owner decisions relevant to this track (2026-08-10)

Recorded here so the file is self-contained. Settled; the residual soft calls are the appendix in §12.

- **Duress PIN — build all three responses, chosen per setup.**
  1. **DECOY** — reuse the period/intimacy hide machinery: sensitive surfaces absent, no content key in
     memory, no on-page trace; fully reversible with the real PIN.
  2. **SILENT WIPE + decoy** — destroy keys sub-second, then present the decoy.
  3. **RECOVERY-LOCK (new)** — destroy the *local* unlock keys so the coerced user truthfully cannot
     open the data, keep the sealed ciphertext + a recovery blob, and allow later recover-or-delete
     **only via a custodian = the user's own second device, in-person only** (QR + sealed-mesh
     ceremony; **no cloud / dead-drop path**). Offered only when a custodian device is enrolled;
     otherwise the option is unavailable.
- **#4 (per-generation escrow salt, versioned v2).** Accepted. Land v2 **first** so the new
  journal/intimacy payloads launch directly on v2 and never write v1. Keep the v1 pin (records in the
  wild) and add a v2 pin.
- **Backup-coverage extension (#1 prerequisite).** Journal narratives and Intimacy logs join the
  escrow-sealed backup. **Worry Box is deliberately left out** — accepted: worry notes die on any
  device reset once #1 lands; that is the desired property. **Intimacy joining reverses the earlier
  "intimacy not in backup" decision** — called out explicitly. Per-type opt-in toggles, each with the
  standard WS-5 destructive-off ceremony.
- **#1 (hard SE-binding).** Delete the scrypt-wrapped legacy item once the SE wrap verifies — **but
  only after its prerequisite (backup coverage) lands**, so no sealed type becomes unrecoverable on a
  device reset.
- **#3 (device-bind the media key).** Split the shared media key per corpus first (own photos vs friend
  wall); the own-photo key becomes device-bound (SE / `ThisDeviceOnly`); the friend photo wall keeps
  its backup-restorable key and its survives-delete-all property. Sanctioned cross-device route for own
  photos = **escrow-sealed backup** (new per-photo record format — the existing chunk scheme re-uploads
  the whole corpus on any change). The route ships **before** the key is bound.
- **"Review how data is deleted" = a deletion-audit deliverable.** The Fable file owns the
  verify-`PrivacyWipeCoverage.md`-against-code pass and the one found gap
  (`RecipeWebImageAttemptMemory.clearAll`). **This track owns the crypto-erasure normalization** — the
  redesign that makes "cleared by delete everything" defensible for the locked sealed corpus.

---

## 3. Where the crypto seams live (the one-paragraph model)

Everything below turns on one key graph, verified in the sources:

- The **lock content key** = a random 256-bit key. It is (a) ChaChaPoly-wrapped under
  `scrypt(passcode, salt)` into `LockKeychainKey.wrappedContentKey` (`FernletLockService.swift:356`);
  (b) additively ECIES-wrapped under a non-exportable Secure Enclave P-256 key into
  `.seWrappedContentKey` (:360); and (c) copied **raw** behind the biometric ACL into `.biometricBypass`
  (:362). The persisted verifier is `SHA256(scrypt(passcode, salt))` (`verifierDigest` :276).
- The **column keys** that seal the four `FernletPrivate` corpora (menstrual / journal / intimacy /
  worry) are HKDF-derived **per call** from that one content key (`ColumnCrypto.deriveColumnKey` :197),
  with the install-binding AAD (`DeviceBindingID`) mixed in at rest for v2 blobs.
- The **escrow key** that seals the CloudKit backup is a *separate* key, HKDF-derived from the escrow
  private key inside `IdentityService` (:129-136) — the one sanctioned synchronizable keychain
  exception, because cross-device restore is its purpose.
- The **media key** (`com.fernlet.private-media.contentKey`) is a *third*, independent key, minted
  `AfterFirstUnlock` non-sync (backup-restorable by design) and shared today across all four photo
  corpora.

The Opus track touches all three of these key families: it destroys the content key honestly (Phase 1),
re-derives the escrow key under a per-generation salt (Phase 2), extends what the escrow key covers
(Phase 3), makes the SE wrap of the content key authoritative and deletes the scrypt wrap (Phase 4),
splits and device-binds one media key into two (Phase 5), and adds a duress-triggered destruction path
plus a custodian-sealed recovery blob (Phase 7). Custody rigor is the whole job.

---

## 4. Dependency & sequencing

The order below is fixed. **Do not re-sequence** — each edge exists because the earlier phase removes a
data-loss hazard or a format churn the later phase would otherwise re-do.

```
Phase 0  Rebase claude/scoped-unlock-per-screen (b293238) onto main (eeec53e)
  │  resolve unlock()/configure()/reset() conflicts with the d68ca9a SE-wrap;
  │  ALL lock work (this track's Phase 7, AND Fable's PIN-before-biometrics) builds
  │  on the scoped .unlocked(scope:) API.
  ▼
Phase 1  Crypto-erasure normalization (content-key destruction + keyless store rebuild)
  │  (must precede the duress WIPE, which reuses the store-rebuild seam + key destruction)
  ▼
Phase 2  #4  v2 per-generation-salt escrow format  (keep v1 pin, add v2 pin)
  │  (new backup payloads must launch on v2 and never write a v1 record)
  ▼
Phase 3  Journal + Intimacy join the escrow backup (directly on v2)
  │  (the mandatory precondition for #1 — otherwise deleting the scrypt wrap strands them)
  ▼
Phase 4  #1  hard SE-binding (delete the scrypt fallback)
  │  (only after Phase 3; the included FernletPrivate file now has zero off-device recovery value)
  ▼
 (Phase 6  #6 default-on backup exclusion — FABLE; runs here, after #1)
  ▼
Phase 5  #3  media-key split + escrow photo route, THEN bind the own-photo key
  │  (route ships before the bind; bind-first strands existing corpora; derives on the v2 salted path)
  ▼
Phase 7  Duress PIN: decoy + wipe + recovery-lock
        (reuses: the Phase-1 key-destruction + store-rebuild seam, the #1 SE-binding finality,
         the scoped-lock API, the hide machinery, and the QR/mesh/X25519 stack)
```

**Why each Opus-internal edge:**

- **0 → 1 (and 0 → 7).** Every lock edit targets the rebased scoped `.unlocked(scope:)` API. Writing
  against the pre-scope signatures (`unlock(passcode:)`, `contentKey()`, `configure(credential:)`) will
  not compile after the rebase; landing lock work before the rebase conflicts in
  `unlock()/configure()/reset()`. **Phase 0 rebases first.**
- **1 → 7.** The crypto-erasure baseline — synchronous key destruction plus the keyless store rebuild —
  is the forensically-real deletion seam the duress WIPE reuses. It also fixes the honesty defect in the
  erasure docs before any new sealed payloads (Phase 3) inherit the overclaim.
- **2 → 3.** The v2 salted escrow format lands first so the journal/intimacy payloads are born v2 and
  never write a v1 record — no back-migration of the new types.
- **3 → 4.** #1 deletes the scrypt-wrapped content key. Without journal/intimacy in the escrow backup,
  an "Erase All Content and Settings" would strand them permanently. **#1 must not land before
  Phase 3.**
- **2 → 5.** The escrow photo route derives on the v2 salted escrow path, so it never writes a v1
  record; #3 therefore follows #4/Phase 2.
- **1,3,4 → 7.** The duress modes reuse the Phase-1 key-destruction + store-rebuild funnel (WIPE's
  crypto-erase + durable purge), the #1 key-destruction finality (WIPE/recovery-lock make deletion
  cryptographically real), the scoped-lock API (every mode calls the scoped signatures), and the hide
  machinery (the decoy substrate). Duress is last because it stands on all of them.

### 4.1 Cross-track dependencies

Three edges cross the Opus/Fable boundary. Each is stated in both files.

1. **Fable/PIN-before-biometrics → Opus/Phase 0.** PIN-before-biometrics extends the scoped
   `unlock(passcode:for:)` / `configure(credential:grantingScope:)` signatures and the
   `isBiometricUnlockAvailable` policy; it cannot compile or be tested until the Phase-0 rebase lands the
   scoped API. **Opus/Phase 0 must land first.** (Opus/Phase 7's duress flag also feeds
   `isBiometricUnlockAvailable`'s `!isDuressSessionActive` term — see §11 — so Fable should leave that
   conjunct as a hook and Opus wires the duress side in Phase 7.)
2. **Fable/#6 (default-on backup exclusion) → Opus/#1 (hard SE-binding, Phase 4).** The default flip is
   justified because, post-#1, an *included* `FernletPrivate` file is ciphertext-unreadable off-device
   even with the passcode, so its only marginal backup exposure is the plaintext metadata columns —
   "all-leak-no-recovery", which makes the default flip easy to justify. **Opus/#1 must land before
   Fable/#6.**
3. **Opus/duress-WIPE (Phase 7) → Opus/Phase-1 crypto-erasure AND the Fable deletion-audit.** The WIPE
   mode's sub-second crypto-erase is Opus/Phase-1 key destruction; its durable background purge fires
   `duressPurgeHook` into `FernletStore.deleteAllData` — **the delete funnel the Fable deletion-audit
   verification pass documents.** WIPE therefore depends on both halves: the redesign here and the
   verified funnel there. Do not ship WIPE claiming durable purge before the Phase-1 funnel work in both
   tracks is in.

---

## 5. Phase 0 — Rebase `claude/scoped-unlock-per-screen` (shared foundation)

**Goal.** Land the unmerged `claude/scoped-unlock-per-screen` (`b293238`, base `eeec53e`) onto current
`main`, resolving its conflicts with the `d68ca9a` SE-wrap changes in `unlock()`/`configure()`/`reset()`.
This is the crypto-seam conflict resolution both tracks build on; it is in the Opus track because the
conflicts sit on the content-key custody path.

**Why it is a crypto-seam conflict, not a mechanical rebase.** The scoped branch and `d68ca9a` both edit
the same three methods for different reasons: the scoped branch threads a `FernletLockScope` through
`configure`/`unlock`/`unlockWithBiometrics`/`contentKey` and changes when `_contentKey` is retained
(`retainContentKey(_:for:)` keeps it resident only for `.privateHub`); `d68ca9a` inserts the additive SE
maintain/verify into `configure()` and the `secureEnclavePreferredContentKey` equality gate into
`unlock()`. A naïve rebase can silently drop either the SE maintain call or the scope-narrowed key
retention. The resolution must preserve **both**: SE wrap maintained/verified on every configure and
unlock, AND `_contentKey` released only to `.privateHub`.

**Target API surface (what every later lock phase calls).** `configure(credential:grantingScope:)`,
`unlock(passcode:for:)`, `unlockWithBiometrics(for:)`, `contentKey(for:)` (releases `_contentKey` only
to `.privateHub`), `revokeUnlockOutside(_:)`, state `.unlocked(scope:)` with `FernletLockScope
{privateHub, progressPhotos, appLockSettings}`, plus `isUnlocked(for:)`, `hasResidentContentKey` (test
seam), and private `retainContentKey(_:for:)`. UI threads scope through `FernletLockView(scope:)` and
`fernletLockGate(scope:)` (`FernletLockGate.swift`).

**Steps.**
1. Rebase `b293238` onto `main`; take the union of the scope threading and the SE maintain/verify in
   `configure()` — the merged `configure` mints → scrypt-wraps → SE-wraps+verifies **and** grants the
   requested scope.
2. In `unlock()`, keep the `d68ca9a` order (scrypt unwrap → `secureEnclavePreferredContentKey` equality
   gate → `maintainSecureEnclaveWrap` on mismatch) *and* the scoped retention (`retainContentKey(_:for:)`
   for `.privateHub` only). Confirm `contentKey(for: .privateHub)` is the sole release path.
3. In `reset()`, keep the full destruction (`KeychainItem.deleteAll` +
   `SecureEnclaveContentKeyWrap.deleteKey` + buffer purge + `purgeEncryptedEntities`) and the scoped
   state teardown.
4. Build clean; run the lock suites (`FernletLockServiceTests`, `FernletLockTests`) + `SecureEnclaveWrapTests`
   + `KeyCustodyBoundaryTests` before any later phase starts.

**Files.** `FernletLock/FernletLockService.swift`, `FernletLockUI/FernletLockView.swift`,
`FernletLockUI/FernletLockGate.swift`, `FernletLock/Documentation.docc/FernletLock.md`,
`FernletLockUI/Documentation.docc/FernletLockUI.md`.

**Tests.** The existing scoped-unlock suite (`FernletLockScopeTests`) must pass unchanged; add a
regression asserting that after the merged `configure()` the SE wrap round-trip-verifies **and** the
scope is granted, and that after a merged `unlock()` on SE hardware the SE wrap is maintained while
`_contentKey` is resident only for `.privateHub` (assert `hasResidentContentKey` behaviour per scope).

**Risks / honest limits.** The rebase is the single point where a dropped SE-maintain call would go
unnoticed until Phase 4 tries to make the SE wrap authoritative — verify the SE wrap exists and verifies
after both `configure` and `unlock` on the merged tree, not just that the suite is green. **Rebase
coupling:** every later lock edit (Phase 7 here, PIN-before-biometrics in Fable) assumes this API; both
tracks block on it.

**Wall/custody.** `FernletLockService.swift` is CODEOWNERS-protected (custody file) — the rebase diff
gets the wall review gate. No S3-wall or No-Tracking-wall impact (no new import, no new endpoint).
`KeyCustodyBoundaryTests`' `WhenUnlockedThisDeviceOnly` + non-sync assertions must stay green through the
merge.

---

## 6. Phase 1 — Crypto-erasure normalization (redesign half of the deletion audit)

**Goal.** Make "cleared by delete everything" honest for the locked sealed corpus, and establish the
forensically-real deletion seam the Phase-7 duress WIPE reuses. **This track owns only the redesign
half**; the verify-`PrivacyWipeCoverage.md`-against-code pass and the `RecipeWebImageAttemptMemory` gap
fix are in
[`Plan-Security-Hardening-FableTrack-2026-08-10.md`](Plan-Security-Hardening-FableTrack-2026-08-10.md).

**Current state (verified).** In the `deleteAllData` path the **lock content key survives by design** —
the app-lock keychain (`com.fernlet.lock`) is a documented survivor
(`PrivacyWipeCoverage.md:83`, "Losing data must not silently un-lock the app"). Sealed rows are removed
by SQLite row-delete + history-prune only: `PrivateRowPlumbing.deleteRows`
(`PrivatePersistenceController.swift`-adjacent :39-56, **keyless** so it works while locked/hidden),
`purgeEncryptedEntities` (:123-135) batches all four entities under one save + prune, and
`PrivatePersistentHistoryPruner.prune` (:248-258) clears only the history shadow tables — it does **not**
checkpoint the WAL or vacuum the freelist. So residual ciphertext can linger in `-wal` frames / freed
pages until reused, and it stays openable in principle by anyone holding the surviving key + the passcode
+ a forensic image. The `purgeEncryptedEntities` doc (:122) currently claims rows are "unrecoverable
afterward — content key owned (and scrubbed) by `FernletLockService`", which is only true in the
`reset()` path (key destroyed). In `deleteAllData` the key is merely scrubbed from **memory**, not
destroyed. **That conflation is the honesty defect to fix.** By contrast, `reset()`
(`FernletLockService.swift:904-915`) *is* a true crypto-erasure: `KeychainItem.deleteAll(service:)`
(`KeychainHelpers.swift:216` — every generic password under the service) +
`SecureEnclaveContentKeyWrap.deleteKey` + `purgeEncryptedEntities` + buffer purge.

**Design — Option B (keyless store rebuild), layered with key destruction where available.**

Two honest options were weighed:
- **Option A — rotate/re-mint the content key after row purge.** *Infeasible in the primary (locked)
  delete path:* re-wrapping a fresh content key needs the scrypt wrapping key (from the passcode) or the
  SE, and delete-everything must run while locked; it would also violate the app-lock-survivor decision
  if it re-keyed the lock. Viable only when unlocked, and redundant with `reset()`/duress-WIPE, which
  already destroy the key.
- **Option B — delete+rebuild the `FernletPrivate` store file.** Path-independent and **keyless**: after
  `purgeEncryptedEntities`, tear the store off the coordinator, call
  `NSPersistentStoreCoordinator.destroyPersistentStore(at:ofType:options:)` (removes the sqlite file +
  `-wal`/`-shm`), delete the `_SUPPORT` external-blob dir, then re-add an empty store and re-apply
  `FileProtection.complete` (:64) + `BackupExclusion`. Physically removes the logical WAL/freelist
  residue without the key or passcode, and works locked.

**Recommendation: Option B as the funnel baseline, layered with key destruction where available.** It is
the only option that runs in the locked path; it is exactly what the Phase-7 duress WIPE reuses; and in
`reset()` / duress WIPE the content key is *also* destroyed, so those paths get both physical removal and
instant crypto-erasure.

**Platform truth to document verbatim.** `destroyPersistentStore` removes the file, but APFS
copy-on-write and flash wear-leveling mean the underlying physical blocks may persist until overwritten;
those blocks are protected by the `FileProtection.complete` class key (evicted when the device locks).
**Only destroying the content key is an instant honest erase** of the logical content regardless of
physical residue. So the `deleteAllData` path (key kept by design) is *bounded-honest* ("no live
ciphertext; residue is class-key-protected and key-bound"); the `reset()` / duress-WIPE path is *fully
honest* ("key destroyed").

**Steps.**
1. Implement keyless `rebuildStore()` on `PrivatePersistenceController`: remove the store from the
   coordinator, `destroyPersistentStore` the sqlite + `-wal`/`-shm`, delete the `_SUPPORT` blob dir,
   re-add an empty store, re-apply `FileProtection.complete` + `BackupExclusion`. Preserve the
   keyless/locked-safe property (no `contentKey()` call anywhere in it).
2. Wire the rebuild into the funnel **after** `purgeEncryptedEntities` / the sealed delete hooks, in
   **both** `reset()` and the `deleteAllData` leg (or expose it so `resetAll` invokes it once). Keep
   row-delete first, then rebuild (a partial rebuild failure still leaves the rows gone). Report "your
   sealed store" only if `destroyPersistentStore` throws (the nothing-silent principle).
3. Fix the doc comments **same commit**: `purgeEncryptedEntities` (:122), the pruner (:248-258),
   `PrivateStoreCore.md:11`, and `PrivacyWipeCoverage.md` — state that row-delete alone leaves
   class-key-protected, key-bound residue in `-wal`/freelist until reused; that Option B removes the
   logical residue; and that only key destruction (reset/duress WIPE) is an instant honest erase.
4. Record the crypto-erasure baseline as the seam the Phase-7 duress WIPE reuses (destroy keys via
   `reset()`'s `KeychainItem.deleteAll` + `SecureEnclaveContentKeyWrap.deleteKey`, then Option B
   rebuild).

**Files.** `PrivateStoreCore/PrivatePersistenceController.swift` (keyless `rebuildStore()`; fix
`purgeEncryptedEntities` doc), `PrivateStoreCore/PrivateRowPlumbing.swift` (residue-honesty doc if
touched), `PrivateStoreCore/Documentation.docc/PrivateStoreCore.md`, `Fernlet/FernletStore.swift` (wire
rebuild into `deleteAllData`/`resetAll` after the sealed purge), `Docs/PrivacyWipeCoverage.md`
(honesty language), a behavioral test file (`DeleteAllDataTests.swift` or `PrivacyWipeCoverageTests.swift`).

**Tests.** Store-rebuild residue: seal a narrative, purge + rebuild, assert the store loads clean with
zero rows **and** the `-wal` sidecar no longer carries the old frames (assert the files were
destroyed/re-created); assert the rebuild runs with **no content key set** (locked-safe). Locked-deletion
invariant: with the lock engaged (no `contentKey()`), drive
`periodDataDeleteHook`/`journalDataDeleteHook`/`intimacyDataDeleteHook`/`worryBoxResetHook` + the rebuild;
assert the rows are gone and **no decrypt was required** (the reversibility trap). Confirm the Fable-owned
`RecipeWebImageAttemptMemory` behavioral test and doc-sync gate still pass (the two tracks share the funnel
test file).

**Risks / honest limits.** In `deleteAllData` the lock content key is kept by design, so even with
Option B the honest claim is "no live ciphertext; residue is class-key-protected and key-bound", **not**
"crypto-erased" — do not overclaim. No user-space code can guarantee *physical* erasure (APFS COW +
wear-leveling); only key destruction sidesteps it. **Reversibility trap:** every deletion path reachable
while locked/hidden must stay keyless — do not introduce any decrypt/re-wrap into the funnel (precisely
why Option A is rejected in the locked path).

**Flagged follow-up (owner call, §12).** The `com.fernlet.narrative-buffer` key survives `deleteAllData`
(`PrivacyWipeCoverage.md:90`) while the journal/worry device keys are deleted
(`FernletStore.swift:4194-4195`) — an asymmetry. The buffer file is purged
(`pendingNarrativeBufferPurgeHook`) so nothing leaks today, but under the crypto-erasure baseline the
surviving key keeps any buffer-file residue openable; deleting it in the funnel is the symmetric fix.

**Wall/custody / same-commit docs.** The `PrivacyWipeCoverage.md` honesty language and the
`PrivateStoreCore.md` DocC page move in the same commit as `rebuildStore()` (doc-coverage baseline). No
S3-wall or No-Tracking-wall impact. `PrivatePersistenceController.swift` and `FernletStore.swift`'s delete
funnel are CODEOWNERS-protected — the rebuild diff gets the wall review gate. The Fable
deletion-audit's `PrivacyWipeCoverageTests` token/doc-row must be landed (its own commit) before this
track claims the funnel is fully audited.

---

## 7. Phase 2 — Hardening #4: v2 per-generation-salt escrow format

**Goal.** Give each backup generation its own random HKDF salt so a single escrow-key compromise no
longer derives one key that opens every past and future backup — a versioned "record format v2" that
coexists with the v1 records already in the wild, landed **first** so the Phase-3 payloads never write
v1. (`Verifiability.md` §5 states the current limit — static derivation means one escrow-key compromise
opens all generations; §6.4 records #4 as the deferred decision, now accepted, and asks for a "versioned
info string" for old/new coexistence.)

**Current state (verified).** Escrow key derivation is **static**:
`HKDF-SHA256(escrowPriv, salt: Data(), info: "com.fernlet.sealed-backup", 32)`
(`IdentityService.swift:129-136`). The per-generation-salt hardening is already sketched in that file's
own doc comment (:115-121). `sealedBackupKey()` (:122-125) and `sealedBackupKeyCandidates()` (:638-649)
take no salt today; the seven no-arg callers to preserve are `SealedBackupService.swift:49,100` and
`IdentityServiceEscrowTests.swift:78,90,112,209,255,275,296`. `SealedBackupCrypto.seal`
(`SealedBackupService.swift:39-81`) derives one key via `sealedBackupKey()` (:49), AES-GCM-seals, and
binds an AAD tagged `"fernlet.sealed-backup.aad.v2"` over payloadType + signingKey + chunkIndex/chunkCount
+ big-endian generation + floored `updatedAt` (:144-162); `open` (:90-123) tries every
`sealedBackupKeyCandidates()` decrypt-first. **The `aad.v2` string is the AAD byte-layout version and is
orthogonal to the record-format v1/v2 this phase introduces.** `SealedBackupRecord`
(`CloudKitSync/SealedBackupRecord.swift:34-90`) carries `payloadType, signingPublicKey,
keyAgreementPublicKey, nonce, ciphertext, tag, updatedAt, chunkIndex(=0), chunkCount(=1), generation`;
`decodeSealedBackup` (`CloudKitDataService.swift:533-571`) requires `generation` with **no** default
(:556-558, fail-closed → `malformedRecord`). `reconcileChunked` (`SealedBackupService.swift:224-250`)
mints one generation up front (:232) and writes the head chunk 0 **last** as the commit marker
(:233-248). `sealedBackupChunks` (`CloudKitDataService.swift:445-470`) requires contiguity +
sameChunkCount + sameGeneration. `SealedBackupFormatPinTests` pins the v1 key KAT (hex `84206218…dc610`
:26,48-56), the AAD-v2 byte layout end-to-end (:62-102), and `restoreNeedsOnlyTheEscrowKey` (:108-124),
with a header saying any drift must fail loudly because it would strand every sealed backup already in
CloudKit.

**Design.**

- **Explicit discriminator, not salt-presence inference.** Add two fields to `SealedBackupRecord`:
  `formatVersion: Int = 1` and `keySalt: Data = Data()`.
  - **v1** (existing records, or `formatVersion < 2`):
    `key = HKDF(escrowPriv, salt: Data(), info: "com.fernlet.sealed-backup")` — byte-identical to today,
    so every record in the wild keeps opening.
  - **v2**: `key = HKDF(escrowPriv, salt: keySalt[32 random bytes], info: "com.fernlet.sealed-backup.v2")`.
    The versioned info string is belt-and-suspenders domain separation on top of the salt (satisfies
    §6.4's "versioned info string") so a bug producing an empty v2 salt still cannot collide with a v1
    key.
- **AAD unchanged** (still `aad.v2`). The salt is a *key-derivation input*, so a tampered `keySalt`
  already yields a wrong key and fails AES-GCM open — binding it into the AAD would be redundant and
  needlessly fork the AAD pin. `keySalt` is a **plaintext** CKRecord field (like `nonce`), not inside
  the sealed payload — it must be, because it derives the key that opens the payload (a salt hidden
  inside the ciphertext is unrecoverable).
- **Salt on every chunk.** Because the head chunk is written last, the salt is stamped on **every** chunk
  record (all chunks of one generation share the one minted salt), sidestepping the head-written-last
  collision the §6.4 sketch ("stored in the head chunk") would create, and keeping each record
  self-describing so `open()` never depends on fetch order.
- **Key-custody seam.** `IdentityService`: change the private derivation to
  `deriveSealedBackupKey(from:formatVersion:salt:)` switching info/salt on version; keep
  `sealedBackupKey()` / `sealedBackupKeyCandidates()` as v1 defaults (salt empty, version 1) so the seven
  no-arg callers and the v1 KAT stay valid, and **add** `sealedBackupKey(formatVersion:salt:)` and
  `sealedBackupKeyCandidates(formatVersion:salt:)`. The escrow private key never leaves `IdentityService`;
  its keychain attributes (the one sanctioned synchronizable exception) are unchanged — only the HKDF
  salt/info change.
- **Mint site.** In `reconcileChunked` mint a 32-byte CSPRNG salt (`SymmetricKey(size: .bits256) → Data`)
  beside the generation mint (:232) and thread it through `saveChunk → seal` for every chunk; same for
  the single-record reconcile. **Recommendation: make ALL new writes v2** (period + sensitiveNotes too),
  so v1 becomes strictly read-only-compat and the blast-radius win applies everywhere; v1 records simply
  coexist until their next re-seal.
- **`SealedBackupCrypto`.** `seal` gains `keySalt: Data = Data()` (empty → v1); it computes
  `formatVersion` from `keySalt` (non-empty → 2), calls the versioned derivation, and stamps
  `record.formatVersion` + `record.keySalt`. `open` reads both and calls
  `sealedBackupKeyCandidates(formatVersion:salt:)` so every candidate is derived under **this** record's
  salt/version.
- **Decode, fail-closed for v2.** `formatVersion = (record["formatVersion"] as? Int) ?? 1`. If `>= 2`,
  **require** a 32-byte `keySalt` (else `malformedRecord` — the generation precedent). If `== 1`,
  `keySalt = Data()`. This never breaks v1 records (they lack both fields → version 1, empty salt).
  **Revised by review:** `sealedBackupChunks` deliberately does **not** gate on matching
  `formatVersion`/`keySalt` — both are unauthenticated fields a downlevel writer can leave mixed on an
  otherwise valid set — so contiguity + `chunkCount` + `generation` stay the transport-level checks and
  the mixed-set rejection happens at the decrypt, where AES-GCM is the authority.

**Old/new coexistence rule (state it once).** A v1 record has no `formatVersion`/`keySalt` fields →
decodes as version 1, empty salt, `"com.fernlet.sealed-backup"` info. A v2 record carries
`formatVersion=2` + a 32-byte `keySalt` → version 2, `"com.fernlet.sealed-backup.v2"` info. Both open
through the same `SealedBackupCrypto.open` on the same identity (candidates derived per record). Pure
additive read compat, no migration of existing records.

**Steps.** (1) `IdentityService` derivation refactor + versioned overloads, preserving the seven no-arg
callers. (2) `SealedBackupRecord` gains `formatVersion`/`keySalt` (crypto metadata only — no plaintext,
no sealed type; keeps the type wall-clean in `CloudKitSync`). (3) `CloudKitDataService`
`saveSealedBackup` writes both; `decodeSealedBackup` defaults `formatVersion=1`, requires 32-byte
`keySalt` when `>= 2`; add `sameKeySalt`/`sameFormatVersion`; **deploy the two new CloudKit fields to the
production schema** (dev auto-adds on first save; see `CloudKit-Schema-Deploy.md`). (4)
`SealedBackupCrypto.seal`/`open` stamp/read both; AAD untouched. (5) `SealedBackupService` mints the salt
and emits v2 for all new writes. (6) Format pin + docs (below).

**Files.** `ProximityKit/Identity/IdentityService.swift`, `CloudKitSync/SealedBackupRecord.swift`,
`CloudKitSync/CloudKitDataService.swift`, `Fernlet/SealedBackupService.swift`,
`FernletTests/SealedBackupFormatPinTests.swift`, `Docs/Verifiability.md`, `Docs/CloudKit-Schema-Deploy.md`.

**Tests.** Keep the v1 key KAT + v1 AAD-layout end-to-end; **add** a v2 key KAT (HKDF `plantedEscrowRaw`,
salt = known 32B, info `"com.fernlet.sealed-backup.v2"`), a v2 AAD+key end-to-end asserting
`record.keySalt == knownSalt && record.formatVersion == 2 && AAD bytes unchanged`, a v1↔v2
coexistence-open test on one identity, and a v2 `restoreNeedsOnlyTheEscrowKey`. Decode/round-trip: a
record with no `formatVersion`/`keySalt` decodes as v1 empty-salt; a v2 record round-trips both; a
`formatVersion >= 2` record with a missing/non-32-byte salt → `malformedRecord`; a chunk set mixing
salts/versions → `malformedRecord`. `IdentityService`: `sealedBackupKey()` still equals the pinned hex;
`sealedBackupKey(formatVersion:2, salt:)` differs and is deterministic; the candidate **set** count is
unchanged (salt changes the derived keys, not which candidates exist).

**Risks / honest limits.** **v2 salt must be 32 random bytes, never empty** — an empty v2 salt would
(absent the versioned info string) collide with the v1 key; enforce non-empty at mint, 32 bytes at
decode, versioned info as the backstop. **Old/new compat:** v1 records already in the wild must keep
opening; do not make `keySalt` globally required or bump the AAD tag. **Perf:** `open()` re-derives escrow
candidates per record under that record's salt; a 250-chunk v2 restore does 250 keychain enumerations ×
candidates — acceptable (restore is rare, network-bound per chunk), note it, hoist if a hot path appears.
**CloudKit schema:** the two new fields must reach production before v2 writes land.
**Downlevel writers during the rollout window (review finding, fixed read-side).** A CloudKit save is a
per-**field** update, not a record replace, so a build from before v2 rewrites a record's ciphertext while
the server keeps the prior v2 write's `formatVersion`/`keySalt` — an intact backup wearing a label that no
longer matches its bytes. `SealedBackupCrypto.open` therefore retries the v1 derivation once when a
v2-labelled record fails to authenticate; the version field is a *hint about which key to try*, never an
authorization decision, so AES-GCM stays the sole authority, the AAD is untouched, and the generation
high-water check still catches rollback. For the same reason `sealedBackupChunks` no longer treats
disagreeing `formatVersion`/`keySalt` as fatal (a downlevel writer that grows a set leaves stale fields on
the old indices and none on the new tail): contiguity + `chunkCount` + `generation` + the per-chunk AAD
carry the anti-splice property, and a genuinely wrong salt still fails closed at the decrypt. Residual
limits: without that fallback a stale build's write is unreadable to updated devices, and a v2 write is
unreadable to stale builds regardless — no forward compatibility is promised.

**Wall/custody / same-commit docs.** The escrow-key change alters only its HKDF salt/info, not its
keychain accessibility/synchronizable attributes — it stays within the single sanctioned synchronizable
exception and `KeyCustodyBoundaryTests` is unaffected. `SealedBackupRecord`/`CloudKitDataService` live in
the walled `CloudKitSync` module and the two new fields are pure crypto metadata (no plaintext, no
sealed-store type) — wall-clean; `spm-wall-check` stays green. No-Tracking wall unaffected (same
allowlisted CloudKit private DB, no new dependency). `Verifiability.md` §2 row for
`SealedBackupFormatPinTests` updated to "pins record format v1 **and** v2", §6.4 marked done — same
commit. `IdentityService` + the `CloudKitSync` transport are CODEOWNERS-protected — expect the wall
review gate on the escrow-derivation diff.

---

## 8. Phase 3 — Backup coverage: Journal + Intimacy join the escrow backup

**Goal.** Add **journal narratives** and **intimacy logs** as first-class sealed-backup payload types
(directly on v2) so they survive a fresh install / new device — the mandatory precondition for Phase 4
(#1) deleting the scrypt-wrapped lock content key, which would otherwise strand them on any device reset.
**Intimacy joining reverses the earlier "intimacy not in backup" decision** — call it out in the standing
decision doc. **Worry Box stays out by design** (it dies on any device reset once #1 lands — the accepted
property).

**Current state (verified).** Only `MenstrualNarrativeRepository` has the backup surface today:
`narrativeCount()` (:243), `narratives(offset:limit:contentKey:)` in total order dateKey+hkExternalUUID
(:256), `insertAtomically` (:165-186), and the `hasEverStoredNarrative` one-way divergence latch
(:113-122) keyed off an **injected** `UserDefaults` (key `"fernlet.menstrualNarrative.everStored"` :95,
:99,:130-140) that every mutation sets. `SealedBackupPayloadType` (`SealedBackupRecord.swift:20-23`) is
`{sensitiveNotes, periodData}`, a `String, Codable, CaseIterable` enum whose rawValue keys the record
name and the AAD. `SealedBackupGenerationStore.reset()` iterates `.allCases` (:83), so new cases
auto-reset on delete-all. `SealedBackupCoordinator.reconcilePeriodBackup` (:230-246) gates on
`host.isPeriodTrackingVisible` (silent no-op when hidden, :235) then `guard host.sealedBackupContentKey
else throw .locked` (:236), sizes `chunkCount = max(1, ceil(total/250))` (`periodBackupChunkSize=250`
:112), and pages `narratives(offset:limit:contentKey:)` into `reconcileChunked`. `applyRestoredChunks`
(:578-604): `sensitiveNotes` = whole-store overwrite via `host.replaceTierTwoMemories`, `periodData` =
`guard key else throw .locked` (:588) then decode `[MenstrualNarrative]` + `insertAtomically` (:602,
all-or-nothing). `isEmptyStoreForRestore` (:612-644): period requires `narrativeCount() == 0 &&
!hasEverStoredNarrative` (:641-642). `classifyRestoreFailure` (:492-519) maps `.locked → .deferredLocked`
(retryable, self-heals), `.storeNotEmpty → .skippedStoreNotEmpty`, stale generation → `.rolledBack`
(terminal). `adoptSyncedEscrowAndReupload` (:322-359) re-uploads enabled backups under the adopted key
(period guarded on `periodNarrativeCount() > 0` :293-294).

`IntimacyLogRepository` (`PrivateHealthStore/IntimacyLogRepository.swift`) has only unbounded
`logs(contentKey:)` (:129), `insert` (:109), `delete/deleteAll` (:146/:160) — **no** count/page/atomic/latch,
**no** defaults injection; it goes through the `@MainActor` visibility gate `IntimacyLogStore`
(`logs()` returns `[]`, `insert()` throws while hidden). `IntimacyLog` (:16-64) is self-contained
`{id, dayKey, eventDate, note, healthKitExternalUUID}`. `JournalNarrativeRepository`
(`PrivateMemoryStore/JournalNarrativeRepository.swift`) has `narratives(forDayKey/forDayKeys)` (:202/:225),
an **upsert** `insert` (:126), `delete/deleteAll` (:180/:194) — no count/page/atomic/latch/defaults.
`JournalNarrative` (:19-47) is self-contained `{id, dayKey, tag, entryDate, text, emotions, createdAt,
updatedAt}`.

**Journal key wrinkle.** `host.sealedBackupContentKey = journalSealingCoordinator.contentKey`
(`FernletStore.swift:4799`) returns `journalContentKey` (`JournalSealingCoordinator.swift:82`), set only
on unlock (`activateSealedJournals` :112-118) and **nil in no-lock mode** (`activateNoLockJournals`
:103-108, which seals under the device journal key). So this covers **lock-configured users only**,
exactly like period backup. **Journal display** reads `FernletDay.journals` *skeletons* and hydrates text
by id from the narrative store (`refreshSealedJournals` :270-295, `hydratingDecryptedJournals` :206-225)
— the days blob holds the skeleton+order, the narrative store holds the text, joined by id. `IntimacyLogStore`
is a `ContentView`-owned `@State` (`ContentView.swift:45`), not reachable from `FernletStore`; its
`isVisible` closure reads `store.isIntimacyTrackingVisible` (:145).

**Design.**

- **Payload types.** Add `SealedBackupPayloadType.journalNarratives` and `.intimacyLogs` (stable raw
  values `"journalNarratives"` / `"intimacyLogs"` — they key the record name and the AAD, never change
  once shipped). `CaseIterable` ripples automatically to delete-all (`FernletStore.swift:3967`),
  generation reset (`SealedBackupGenerationStore.swift:83`), the settings banner
  (`PrivacyDataSettingsView.swift:517`), `SealedBackupRollbackTests.swift:178`. It also forces the
  exhaustive switches to gain arms: `hasSealedBackup` (`FernletStore.swift:3901`),
  `setSealedBackupEnabled` (:197), `applyRestoredChunks` (:578), `isEmptyStoreForRestore` (:618),
  `setSealedBackupPreference` (`PrivacyDataSettingsView.swift:975`). **A CLEAN build is required** so
  every non-exhaustive switch surfaces as a compile error rather than an incremental build masking one
  (the FernletDomainModel-class hazard).
- **Prefs.** Add `sealedBackupJournalEnabled` + `sealedBackupIntimacyEnabled` to `StoragePreferences`
  (tolerant `decodeIfPresent(...) ?? false`, mirroring :95-97; init default false) and OR them into
  derived `hasSealedBackup` (:121-123). Extend the `SealedBackupContext` protocol
  (`SealedBackupCoordinator.swift:16-37`) with `isIntimacyTrackingVisible` (`FernletStore` already has
  it, :694), and add per-payload display names for the banner.
- **Restore semantics — insert-into-empty + diverged-latch for BOTH new types** (mirror period; NOT the
  `sensitiveNotes` whole-store overwrite). Both are user-authored text; overwrite could clobber.
  Insert-into-empty runs only when the payload store is genuinely empty AND the one-way divergence latch
  is unset, so a user who *deleted* entries is never resurrected from a stale cloud copy — the same harm
  the menstrual latch closes.
- **Repository APIs (new, mirroring `MenstrualNarrativeRepository`)** on both `JournalNarrativeRepository`
  and `IntimacyLogRepository`: (1) `count()` without decrypting; (2) a paged `page(offset:limit:contentKey:)`
  in a **total** order (journal: entryDate asc then id asc; intimacy: eventDate asc then id asc — id is
  the unique tiebreaker so pages never overlap/skip); (3) `insertAtomically([...], contentKey:)` — single
  transaction, rollback on any failure, **plain insert** into the gated-empty store (NOT the journal
  upsert), latch after commit; (4) a `hasEverStored` one-way divergence latch keyed off an **injected**
  `UserDefaults` (add `defaults: UserDefaults = .standard` to both inits) with count>0 backfill, set on
  every insert/insertAtomically/update/delete/deleteAll — per-type keys
  `"fernlet.journalNarrative.everStored"` / `"fernlet.intimacyLog.everStored"`. The latch **must** consult
  the injected defaults so tests get isolation (not the process-global suite).
- **Coordinator seal source.** Add `reconcileJournalBackup(using:)` (no visibility gate — journaling is
  always visible; `guard host.sealedBackupContentKey else throw .locked`) and
  `reconcileIntimacyBackup(using:)` (`guard host.isIntimacyTrackingVisible else` silent no-op — do NOT
  disable the pref, matching the period hidden no-op at :235, hidden must never read as empty — then
  `guard host.sealedBackupContentKey`). Both page their repo into `reconcileChunked`. Wire the
  `setSealedBackupEnabled` tuple switch: `(.journalNarratives, true) → reconcileJournalBackup`,
  `(.intimacyLogs, true) → reconcileIntimacyBackup`, `(_, false) → reconcile(Data(), …, enabled: false)`
  (deletes the chunk set). All three use `host.sealedBackupContentKey` — the same lock content key that
  seals menstrual/journal/intimacy columns (per-column HKDF labels under one content key), so it is
  correct for paging all three.
- **Coordinator restore.** Launch arms (`restoreSealedBackupsIfNeeded` :255-297) gated on prefs (journal
  if `sealedBackupJournalEnabled`; intimacy if `sealedBackupIntimacyEnabled && host.isIntimacyTrackingVisible`);
  `applyRestoredChunks` arms decode `[JournalNarrative]` / `[IntimacyLog]`, `guard host.sealedBackupContentKey
  else throw .locked` (→ `.deferredLocked`, self-heals on unlock), then `insertAtomically`;
  `isEmptyStoreForRestore` arms: journal `journalCount() == 0 && !hasEverStoredJournalNarrative`, intimacy
  `logCount() == 0 && !hasEverStoredLog` (a count error fails **closed** = non-empty = skip, matching
  period). Inject the repositories as optional params (like `narrativeRepository:`) so restore tests drive
  isolated stores.
- **Journal self-sufficiency (critical, journal only).** `JournalNarrative` carries the full entry, but
  the journal UI reads `FernletDay.journals` *skeletons* and hydrates text by id. On a sync-OFF device
  reset the days blob is gone too, so restoring narrative rows alone yields **invisible** entries — which
  defeats recovery precisely for the users the sealed backup exists to protect, and breaks the Phase-4
  (#1) guarantee. Journal restore must be self-sufficient: after `insertAtomically`, reconstruct the
  day-entry skeletons from the restored `JournalNarrative` rows into the diary/day store via a new host
  hook `reinstateJournalEntries(from: [JournalNarrative])` that merges `JournalEntry(id, tag, date,
  emotions, text: "")` into each day, schedules a snapshot save, and triggers a sealed-journal refresh so
  hydration fills the text. Intimacy needs no such step (`IntimacyLog` is self-contained and the intimacy
  UI reads `IntimacyLogStore.logs` directly).
- **Toggle-off orphan gap (recommend fixing here).** `applySealedBackup`'s disable branch clears the pref
  regardless of the CloudKit delete outcome (`PrivacyDataSettingsView.swift:956-973`, "honor the user off
  intent regardless of the delete outcome") — a failed delete leaves CKRecords in iCloud with the pref
  reading `false`, so `hasSealedBackup` is `false` and delete-all/re-toggle never targets them. Phase 3
  adds two payloads that each inherit it. Minimal fix mirroring delete-all's `keepSealedBackupFlags`: on a
  **failed** disable-delete, keep the pref ON and surface a non-silent retryable state (reuse the
  escrow/deferral banner) so a retry or delete-all still targets the orphaned CKRecords. Owner UX call
  (§12).

**Carry-through invariants.** **Restore-before-reupload:** the launch pass restores every payload before
any reconcile/re-upload runs; `adoptSyncedEscrowAndReupload` (:322) must guard the journal/intimacy
re-upload on `count > 0` so a not-yet-restored device never overwrites a good cloud backup with an empty
one (the guard the period deferral uses, `periodNarrativeCount() > 0` at :293-294).
**Empty-store-clobber:** `reconcileChunked` always writes a head record even for count 0
(`chunkCount = max(1, …)`), so any export from an empty store replaces the cloud copy — the `count > 0`
guards + restore-first ordering are the defense; carry both into every step.

**Files.** `CloudKitSync/SealedBackupRecord.swift` (enum cases),
`FernletFoundation/StoragePreferences.swift`, `PrivateMemoryStore/JournalNarrativeRepository.swift`,
`PrivateHealthStore/IntimacyLogRepository.swift`, `PrivateHealthStore/IntimacyLogStore.swift`,
`Fernlet/SealedBackupCoordinator.swift`, `Fernlet/SealedBackupGenerationStore.swift`,
`Fernlet/FernletStore.swift`, `Fernlet/ContentView.swift`, `Fernlet/PrivacyDataSettingsView.swift`,
`FernletTests/SealedBackupRollbackTests.swift`, `Docs/Verifiability.md`, `Docs/PrivacyWipeCoverage.md`,
and the intimacy-in-backup standing decision doc.

**Tests.** Per new payload: seal → restore into an empty store returns entries under v2; restore into a
non-empty store → `skippedStoreNotEmpty`; a set divergence latch (user deleted then empty) → skipped (no
resurrection); nil content key at restore → `deferredLocked` then self-heal after unlock; intimacy hidden
at reconcile → silent no-op (cloud untouched); intimacy hidden at restore → deferred, then restores on
un-hide. **Journal self-sufficiency:** after a journal restore into a device with no days blob, the
reconstructed skeletons make the entries visible and hydrate text by id. **Empty-store-clobber guards:**
enabling/adopt-reupload from an empty (un-restored) journal or intimacy store does NOT overwrite a
populated cloud backup (`count > 0` guard); a normal enable from a populated store DOES upload.
**Repository units (both new repos):** count without decrypt; paged reader is a total order with no
overlap/skip; `insertAtomically` is all-or-nothing (a mid-batch failure rolls back to empty); the latch is
set by insert/insertAtomically/update/delete/deleteAll, backfills from count>0, isolated per injected
suite. `SealedBackupRollbackTests` (allCases at :178) now exercises both new payloads (monotonic
generation; stale → `rolledBack`). Delete-all: new-payload cloud backups deleted via
`setSealedBackupEnabled(false)`; generation marks cleared; the two new latches **survive** the wipe
(one-way). A CLEAN-build compile pass proves switch exhaustiveness.

**Risks / honest limits.** **Empty-store clobber** (data loss) and **journal invisible-on-restore** are
the two load-bearing hazards above. **CaseIterable non-exhaustive-switch trap** — clean build mandatory.
**Divergence-latch direction** must be one-way and survive delete-all; every mutation path (incl deletes)
must set it, keyed off the injected defaults. **No-lock limit (honest):** `host.sealedBackupContentKey` is
nil unless a lock is configured and unlocked, so no-lock users cannot enable journal/intimacy (or period)
sealed backup — their device-key-sealed journals are uncovered. Consistent with the separately-deferred
§6.2 and unaffected by #1, but no-lock journals still die on a device reset. State it.

**Wall/custody / same-commit docs.** No new outbound endpoint (CloudKit private DB, already allowlisted)
and no new SPM dependency — No-Tracking wall unaffected. The new repository APIs live in the sealed
`PrivateMemoryStore`/`PrivateHealthStore`, unreachable from `AIProviders`/`CloudKitSync` — no import
crosses the S3 wall. Key-custody unaffected (no new key; escrow attributes unchanged). `Verifiability.md`
§2 (`SealedBackupFormatPinTests` now covers the new payloads on v2); `PrivacyWipeCoverage.md` — confirm
"Sealed iCloud backups (all payload types)" + the `SealedBackupGenerationStore.reset` row still hold via
`CaseIterable`, and add the two new device-local one-way divergence-latch `UserDefaults` keys to the
deliberately-kept table (they must outlive a wipe, mirroring the menstrual latch); `PrivacyWipeCoverageTests`
tokens unchanged. Update the standing decision doc to record the intimacy-in-backup reversal — same commit.

---

## 9. Phase 4 — Hardening #1: hard SE-binding of the lock content key

**Goal.** After Phase 3 lands, complete hard SE-binding: delete the scrypt-wrapped legacy content-key item
once the Secure-Enclave wrap proves a full unwrap round-trip, so the sealed corpus plus a full keychain
dump is useless off-device **even with the passcode** (kills off-device PIN brute force — a 4-digit PIN
through scrypt is ~10⁴ tries). Resolves `Verifiability.md` §6.1.

**Current state (verified).** SE-wrap plumbing already exists (`d68ca9a`) but is purely additive; the
scrypt wrap stays authoritative. The scrypt-wrapped content key = `LockKeychainKey.wrappedContentKey`
(`FernletLockService.swift:356`), ChaChaPoly-sealed under the scrypt-derived key; the verifier is
`SHA256(derivedKey)` (`verifierDigest` :276). The additive SE wrap = `seWrappedContentKey` (:360), an
ECIES wrap of the **raw** content key under a non-exportable SE P-256 key
(`SecureEnclaveContentKeyWrap.wrapVerified` :50-62, `unwrap` :69-74; ACL `WhenUnlockedThisDeviceOnly` +
`.privateKeyUsage`, `SecureEnclaveContentKeyWrap.swift:110-115` — device-unlock gated, **not** app-PIN
gated). `unlock()` (:800-834) unwraps scrypt (:821) then `secureEnclavePreferredContentKey` (:824,:984-993)
prefers SE bytes **only when** `constantTimeEqual(seUnwrapped, scryptUnwrapped)` (:988) — the equality gate
that keeps scrypt authoritative; otherwise it repairs via `maintainSecureEnclaveWrap` (:1001-1015). A
second raw-key copy — `biometricBypass` (:362), `WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`
(`storeBiometricBypass` :463-486) — feeds `unlockWithBiometrics` (:844-888, never touches scrypt/SE).
`reset()` (:904-915) destroys everything (key gone → true crypto-erasure). In `deleteAllData` the lock
keychain **survives by design** (`PrivacyWipeCoverage.md:83`).

**Design — state machine keyed off presence of the scrypt item.**

- **LEGACY** (pre-#1 / SE-less): `wrappedContentKey` present (authoritative). Unlock via scrypt, prefer SE
  only when equal — today's behavior, unchanged on SE-less hardware.
- **HARD-BOUND** (post-#1, SE available): `wrappedContentKey` **absent**; `seWrappedContentKey`
  authoritative; `salt` + `verifier` present (still the PIN gate). Unlock = verify passcode against the
  verifier, then recover the content key via `SecureEnclaveContentKeyWrap.unwrap` (no scrypt unwrap
  possible — the item is gone).

**Migration (keep-old-until-verified), on the first unlock under the #1 build.**
1. Do today's scrypt unlock and SE maintain/verify (`maintainSecureEnclaveWrap` re-establishes a wrap
   bound to the current SE key and round-trip-verifies inside `wrapVerified` :58-60).
2. **Guard:** `SecureEnclaveContentKeyWrap.isAvailable` AND a freshly re-read `seWrappedContentKey`
   unwraps to exactly the scrypt-unwrapped key (`constantTimeEqual`). Only then delete
   `wrappedContentKey` (`KeychainItem.delete(.wrappedContentKey)`). One-line flip; every failure path
   keeps the scrypt item (no hard-bind on SE-less devices, on a failed/absent SE wrap, or on any keychain
   error).
3. Rewrite the unlock/`changeCredential`/`configure` branches to detect the hard-bound state
   (`wrappedContentKey` absent) and recover via SE gated by the verifier. `configure()` on a fresh #1
   install mints → scrypt-wraps → SE-wraps+verifies → deletes the scrypt item (net: **born hard-bound**
   where SE exists). `changeCredential()` hard-bound: verify current passcode, pull the content key from
   SE (unchanged by a re-key so the SE wrap stays valid), write new salt+verifier+kind, never rewrite
   `wrappedContentKey`.

**New failure path (must be designed, not implicit).** Hard-bound + SE unwrap returns `nil` (SE key
destroyed by Erase-All / SE reset): the passcode verifier still matches but the content key is
cryptographically gone. Surface an explicit **"sealed data can no longer be opened on this device — reset
the app lock to continue"** state (a new `FernletLockError` case + gate copy), NOT a silent wrong-key.
This is the honest UX of the trade (the nothing-silent principle).

**Biometric-bypass raw-key residual — ACCEPT as documented residual for Phase 4** (do not SE-wrap it now).
It is `WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`, never leaves the device, and does not
undermine the off-device claim (#1's point is off-device); it IS destroyed by `reset()`'s
`KeychainItem.deleteAll` sweep (`KeychainHelpers.swift:216`), which the Phase-7 duress WIPE reuses. Residual
to disclose: while biometrics are enabled the content key also lives behind the biometric ACL (a
data-protection item, not SE-nonexportable), so §5's strongest claim ("key never exists in extractable
form except behind the SE") is only exactly true with biometrics off — state it plainly.

**Steps.** (0, BLOCKING) confirm Phase 3 landed — journal + intimacy in the escrow-sealed backup on v2;
**Worry Box is deliberately not backed up and will be lost on Erase-All once #1 lands (accepted).** (1)
hard-bound-state detector (`wrappedContentKey` absent AND `SecureEnclaveContentKeyWrap.isAvailable`);
branch `unlock()`. (2) migration flip (keep-old-until-verified). (3) `configure()` born-hard-bound where
SE exists. (4) `changeCredential()` hard-bound branch. (5) explicit unrecoverable error + gate copy;
neutralize the equality gate (:984-993) for the hard-bound branch (nothing to compare against once scrypt
is gone). (6) confirm `reset()`'s `KeychainItem.deleteAll` still sweeps the biometric bypass (it does). (7,
SAME COMMIT) update `Verifiability.md` (§6.1 done; §4 scrypt item deleted post-SE-verify; §5 honest-limit:
same-device encrypted-backup restore can no longer unlock non-escrow-backed sealed data with the passcode,
Worry Box dies on Erase-All), `KeyCustodyBoundaryTests`, `SecureEnclaveWrapTests`, and the
`FernletLock`/`SecureEnclaveContentKeyWrap` doc comments.

**Files.** `FernletLock/FernletLockService.swift`, `FernletLock/SecureEnclaveContentKeyWrap.swift`,
`FernletLock/Documentation.docc/FernletLock.md`, `Docs/Verifiability.md`,
`FernletTests/KeyCustodyBoundaryTests.swift`, `FernletTests/SecureEnclaveWrapTests.swift`,
`FernletTests/DeleteAllDataTests.swift` (or `PrivacyWipeCoverageTests.swift`).

**Tests.** After configure + first unlock on SE hardware, `wrappedContentKey` is DELETED and a second
unlock still recovers the SAME key via SE only. SE-less branch: `wrappedContentKey` RETAINED, unlock
byte-for-byte legacy (mirrors the existing else-branch :70-76). Keep-old-until-verified: corrupt/absent
`seWrappedContentKey` before migration → `wrappedContentKey` NOT deleted, unlock still works via scrypt
(extends :60-69). SE-key-death after hard-binding: `deleteKey`, then unlock → verifier matches but content
key unrecoverable → the new explicit error, not a silent wrong key. `changeCredential` hard-bound preserves
the content key via SE (new pin works, old fails, no `wrappedContentKey` rewritten).
`KeyCustodyBoundaryTests`: keep the `WhenUnlockedThisDeviceOnly` attribute assertions (:50-63); add that in
the hard-bound state the only content-key-bearing generic-password rows are `seWrappedContentKey` (+
optional `biometricBypass`), both non-synchronizable. Rely on Phase 3 having extended
`SealedBackupFormatPinTests.restoreNeedsOnlyTheEscrowKey` (:108-124) to journal + intimacy before #1 flips.

**Risks / honest limits.** **The headline #1 trade (verified):** once the scrypt item is deleted, an
Erase-All or any SE reset destroys the SE key, so a same-device restore from an encrypted iOS backup can no
longer unlock the sealed corpus with the passcode (today it can — `ThisDeviceOnly` items restore to the
same device but SE keys never do). Mitigation is Phase 3; Worry Box is permanently lost (accepted). **#1
must NOT land before Phase 3.** **Data loss if the flip is too eager** — mitigated by
keep-old-until-verified + SE-availability guard + never-delete-on-keychain-error. **On-device PIN weakening
(design sub-decision, §12):** the SE wrap wraps the *raw* content key and the SE key is only device-unlock
gated, so post-#1 a forensic on-device attacker can unwrap the content key via the SE **without** the app
PIN. For a 4-digit PIN that protection was already ~nil (10⁴ scrypt is trivial); for an alphanumeric app
password this removes a genuine barrier — see the SE-wrap-the-scrypt-blob alternative in §12. **Biometric
residual** as above.

**Wall/custody / same-commit docs.** `KeyCustodyBoundaryTests` MUST update same-commit (keep the attribute
assertions, add hard-bound coverage); the grep-walls (synchronizable confined to `IdentityService`, bare
accessibility confined to `PrivateMediaKeyStore` + `IdentityService`) are **unaffected** — #1 adds no
synchronizable or bare-accessibility spelling (the SE key uses `WhenUnlockedThisDeviceOnly`, which the
matcher ignores via its ThisDeviceOnly suffix check :171-185). The at-rest format-pin tests
(`FernletLockCryptoTests`, `ColumnCryptoDeviceBindingTests`, `SealedBackupFormatPinTests`) are unchanged —
#1 changes key **custody**, not the sealed-column or escrow **format**, which is the point.
**Deviation (P4 review, recorded rather than left to drift):** the format pins themselves are unchanged,
but `FernletLockCryptoTests`' FIXTURE is not. `configuredVerifierIsDigestNotWrappingKey` asserts against
the persisted scrypt wrap, which no longer exists after a born-hard-bound `configure()` on enclave
hardware, so the test now builds its service with enclave-wrap persistence refused (`freshService(persistEnclaveWrap: false)`)
and keeps its assertions UNCONDITIONAL instead of hiding them behind an `if let` that goes dead on every
Apple-silicon host. The hard-bound property gets its own pin beside it
(`hardBoundConfigureLeavesNoPasscodeDerivedRowThatOpensTheKey`), so both custody states are pinned on every
host rather than one state per host. `Verifiability.md`
is CODEOWNERS-protected: §4/§5/§6.1 edited in the same commit as the code (§6.1 moves from "awaiting owner
decision" to done; §5 gains the same-device-restore honest limit). No S3-wall or No-Tracking impact
(`FernletLock` legitimately imports `PrivateStoreCore`/`PrivateHealthStore`; nothing new crosses the wall).

---

## 10. Phase 5 — Hardening #3: media-key split, own-photo device-binding, escrow photo route

**Goal.** Break the one shared, backup-restorable media key into two — a device-bound key for the user's
**own** photos (meal/recipe/progress) and the existing backup-restorable key for the **friend photo wall**
— and give own photos a sanctioned cross-device route via a new per-photo escrow-sealed backup, so own
photos become worthless off-device (bulk file+keychain theft yields nothing) while still surviving a phone
swap. Lands after Phase 2 (v2 escrow) so the photo route launches directly on v2. Resolves
`Verifiability.md` §6.3.

**Current state (verified).** `KeychainPrivateMediaKeyProvider`
(`PrivateMediaStore/PrivateMediaKeyStore.swift:47-80`) reads **one** row — service
`com.fernlet.private-media`, account `com.fernlet.private-media.contentKey` (:48-49) — minted
`kSecAttrAccessibleAfterFirstUnlock`, NOT `ThisDeviceOnly`, non-sync (:75), i.e. deliberately
backup-restorable (doc :36-41). All four corpora default-construct this provider and share the key: friend
wall `PrivateMediaStore(indexURL:)` (`ProximityKit/Mesh/MeshNetworkManager.swift:291-294`, cap 1000 at
`PrivateMediaStore.swift:53,67-68`), meal `MealPhotoStore` at `Documents/MealPhotos`
(`FernletStore.swift:319-322`), recipe `MealPhotoStore` at `Documents/RecipePhotos` (legacy-plaintext OFF
:333-338), progress `ProgressPhotoStore` at `Documents/ProgressPhotos` with a GCM-sealed `index.bin` +
inner `Photos/` (`ProgressPhotoStore.swift:61-81`, inner `MealPhotoStore` at :68-72). At-rest crypto is
plain AES-256-GCM with **no AAD** (`MediaAtRestCrypto.gcmSeal/gcmOpen` :19-30), so a file carries no
binding to corpus/id/device. Own corpora are flat id→file maps with **no count cap**
(`MealPhotoStore.save` mints a UUID :74-79; normalize caps each JPEG at 1600px longest side, q0.8 :39-40).
`deleteAll` wipes meal/recipe/progress (`MealPhotoStore.deleteAll` :133-143; `ProgressPhotoStore.deleteAll`
:156-165; funnel `FernletStore.swift:4038` + `PrivacyWipeCoverage.md:37-39`). The friend wall **survives**
delete-all and its shared key survives too (`PrivacyWipeCoverage.md:85-86`; `deleteKeychainRowForWipe`
deliberately has NO callers :88-102). The friend-wall index `MeshPhotoCache.json` is **plaintext** and
holds `senderName`/`senderFingerprint`/`senderSigningPublicKey` (`FriendPhotoPayloads.swift:21-23`).
`KeyCustodyBoundaryTests` pins the media key as sanctioned exception 1/2 (AfterFirstUnlock + non-sync
:96-105; grep-wall bare-accessibility set exactly `{PrivateMediaKeyStore.swift, IdentityService.swift}`
:213; synchronizable:true only in `IdentityService` :198). `SecureEnclaveContentKeyWrap` is a **non-public**
`nonisolated enum` in `FernletLock` (:50-86) — `PrivateMediaStore` cannot import `FernletLock`, so
SE-wrapping the media key requires relocating/publicising it to `FernletFoundation`.

**Design — key custody (the heart of #3).** Two providers instead of one:
- **(a) Friend-wall provider** = the **existing** row unchanged (`com.fernlet.private-media` / `.contentKey`,
  AfterFirstUnlock, non-sync). Repurposing the existing row as the friend key means **zero re-encryption**
  of the wall, preserving its readability, survives-delete-all, and never-deleted-by-wipe properties
  verbatim (`PrivacyWipeCoverage.md:85-86` still describe exactly this row).
- **(b) Own-photos provider** = a **new** row `com.fernlet.private-media.ownContentKey` (same service).
  Minted AfterFirstUnlock **initially** (still backup-restorable, so nothing strands during migration),
  flipped to device-bound only in step 5c. Add a `deviceBound: Bool` mint mode so 5c is a one-line policy
  flip (the SE-wrap "flip not flag-day" precedent, `SecureEnclaveContentKeyWrap` header :4-8). Keep both
  in the same isolation domain per store owner (the provider is not `Sendable`, :43-46).

Wire `MeshNetworkManager`'s `PrivateMediaStore` (:294) to (a); wire `FernletStore`'s
meal/recipe/progress stores (:319-338; `ProgressPhotoStore` forwards to its inner `MealPhotoStore`
:68-72) to (b).

**Migration (own photos, legacy shared key → K_own).** Own files are currently sealed under the shared
(= friend) key, so a fresh K_own cannot open them until re-sealed. (1) An **eager, idempotent, crash-safe**
`migrateOwnPhotosToOwnKey()` enumerates `MealPhotos/`, `RecipePhotos/`, `ProgressPhotos/Photos/`, and
`ProgressPhotos/index.bin`; per file: if it already GCM-opens under K_own, skip; else open under the legacy
shared key and atomically re-seal under K_own (reusing `sealAndWrite`, `MediaAtRestCrypto.swift:36-44`). A
half-written file fails GCM-open and is retried next pass. (2) A **dual-open** safety net on the own read
path (try K_own, then legacy shared key + re-seal on access — the "legacy upgrade on read" idiom already in
`MealPhotoStore.imageData` :95-112 and `PrivateMediaStore.openSealed` :214-222). (3) A completion latch
`ownPhotoKeyMigrationComplete`, set ONLY when a full pass finds zero legacy-key files. **The latch is
load-bearing:** binding (5c) and dropping the dual-open fallback are GATED on it, so binding never silently
converts a straggler to `.unreadable`.

**Escrow photo route (new per-photo record scheme, ships in 5b BEFORE binding).** Reuse `SealedBackupCrypto`'s
escrow-key derivation (on the **v2 salted path** from Phase 2) and `SealedBackupGenerationStore`, but do
**not** reuse `SealedBackupPayloadType` or `reconcileChunked` — the chunkCount-in-AAD scheme rewrites the
whole set on every change (`SealedBackupService.swift:224-250`). Instead: one CloudKit record **per photo
id**, named `sealed-photo.<corpus>.<photoId>`, whose AAD binds a new domain tag + corpus + signingKey +
photoId + generation + updatedAt (a v3 AAD sibling of `authenticatedData` :144-162), ciphertext = the
normalized JPEG as a CKAsset (mirroring `saveSealedBackup` `CloudKitDataService.swift:394-423`). A sealed
**manifest** record `sealed-photo.<corpus>.manifest` is written **last** as the commit marker: it lists the
id set (+ per-id content hash) and carries the generation (from `SealedBackupGenerationStore` under a
photo-namespaced key). Restore: open the manifest (authenticate + generation high-water, exactly
`restoreChunks`' order :279-297), then fetch/open each id; a record not in the manifest is an ignored
orphan; an id in the manifest with no openable record fails **that photo**, not the set. **Incremental add**
= upload one new record + rewrite the small manifest; **delete** = drop from manifest (+ best-effort delete
record) — the property the chunk scheme lacks. Use a DISTINCT namespace (`SealedPhotoCorpus {meal, recipe,
progress}` or one `ownPhotos`) and a small `SealedPhotoBackupService` composing `SealedBackupCrypto` —
**NOT** an added case on `SealedBackupPayloadType`, because delete-all iterates
`SealedBackupPayloadType.allCases` (`FernletStore.swift:3967-3968`) and the settings toggles loop it too; a
new case there would mis-route photos through the chunk path. The route is **opt-in** behind a toggle (WS-5
destructive-off ceremony to disable), sized for iCloud quota.

**Binding (5c).** Flip `com.fernlet.private-media.ownContentKey` to `AfterFirstUnlockThisDeviceOnly`
(baseline) — or SE-wrap (stronger; owner call, §12). **Gate on `ownPhotoKeyMigrationComplete` AND (escrow
route enabled OR explicit user consent** that own photos won't restore to a new phone without escrow
backup). After binding, drop the dual-open fallback so the binding is meaningful.

**Steps.** (Gate) confirm Phase 2 exposes the v2 salted derivation API and Phases 0/1 are in. (5a-1) second
provider identity + `deviceBound` mint mode. (5a-2) wire providers. (5a-3) `migrateOwnPhotosToOwnKey()` +
latch, run once at launch off the main path. (5a-4) dual-open safety net; verify friend wall untouched.
(5b-1) define the photo escrow namespace + v3 AAD tag + record names; do NOT add a `SealedBackupPayloadType`
case. (5b-2) `SealedPhotoBackupService` (sealPhoto / writeManifest-last / restore / incremental). (5b-3)
CloudKit transport for per-photo records + manifest (mirror `saveSealedBackup`; enumerate-by-prefix for
teardown like `sealedBackupRecordIDs` :501-512). (5b-4) opt-in toggle + disclosure + restore path +
per-corpus no-clobber gate. (5b-5) register own-photo escrow teardown in the delete-all funnel BEFORE the
local wipe (mirror the sealed-backup teardown `FernletStore.swift:3956-3985`), reset the photo generation
namespace, and add the row to `PrivacyWipeCoverage.md` + the token to `PrivacyWipeCoverageTests` IN THE SAME
COMMIT (the Phase-1 same-commit rule). (5c-1) flip to device-bound, gated on the latch AND (escrow enabled
OR consent); drop dual-open. (5c-2, same commit as 5c-1) update `KeyCustodyBoundaryTests` (friend key stays
AfterFirstUnlock non-sync; NEW own-key `ThisDeviceOnly` non-sync assertion), the `PrivateMediaKeyStore` doc
comment, `Verifiability.md` §6.3 + §4.

**Files.** `PrivateMediaStore/PrivateMediaKeyStore.swift`, `PrivateMediaStore/MediaAtRestCrypto.swift`,
`PrivateMediaStore/MealPhotoStore.swift`, `PrivateMediaStore/ProgressPhotoStore.swift`,
`PrivateMediaStore/PrivateMediaStore.swift`, `Fernlet/FernletStore.swift`,
`ProximityKit/Mesh/MeshNetworkManager.swift:294`, `Fernlet/SealedBackupService.swift`,
`CloudKitSync/SealedBackupRecord.swift`, `CloudKitSync/CloudKitDataService.swift`,
`Fernlet/SealedBackupGenerationStore.swift`, `Fernlet/PrivacyDataSettingsView.swift`,
`FernletFoundation/StoragePreferences.swift` (per-corpus escrow-enabled pref if chosen),
`FernletLock/SecureEnclaveContentKeyWrap.swift` + `Package.swift` (ONLY if SE-wrap chosen — DAG/wall
change), `KeyCustodyBoundaryTests.swift`, `PrivateMediaStoreTests.swift`, `MealPhotoStoreTests.swift`,
`ProgressPhotoStoreTests.swift`, `SealedBackupFormatPinTests.swift`, `PrivacyWipeCoverageTests.swift`,
`Docs/Verifiability.md`, `Docs/PrivacyWipeCoverage.md`, `Docs/No-Tracking-Wall.md`,
`PrivateMediaStore/Documentation.docc/PrivateMediaStore.md`.

**Tests.** Friend-wall photos readable after the split/migration and survive a simulated delete-all.
Own-photo file re-seals under K_own and no longer opens under a friend-key-only provider; migration
idempotent (second pass a no-op) and crash-safe (a truncated file is retried, never returned as garbage).
Dual-open + latch: with one legacy file left, the own provider still returns bytes via fallback and the
latch stays false; only a clean full pass sets it true. Bind-gating: binding is refused (fallback retained)
until the latch is set — prove no own photo becomes `.unreadable` across the flip. `KeyCustodyBoundaryTests`:
friend key AfterFirstUnlock+non-sync (unchanged), own key `AfterFirstUnlockThisDeviceOnly`+non-sync (new);
grep-wall expected set stays green (friend key is still the bare exception in that file). Escrow incremental:
sealing photo B after A rewrites ONLY B's record + the manifest, A byte-identical. Commit marker: a set with
records but no manifest restores nothing; a manifest id with a missing record fails that photo, not the set.
Round-trip + per-corpus no-clobber. Rollback/identity: stale-generation manifest rejected via
`SealedBackupGenerationStore` high-water; a foreign-escrow-key manifest classifies as `notRecognized`.
Format pin: byte-exact per-photo AAD v3 layout, derived on the v2 salted escrow key. Delete-all: own-photo
escrow records for enabled corpora deleted; `PrivacyWipeCoverageTests` sees the new token (same commit).

**Risks / honest limits.** **DATA LOSS — bind before migrate:** flipping K_own device-bound (or dropping
dual-open) before every own file is re-sealed silently turns stragglers into `.unreadable` — the latch
gates both 5c and the fallback drop; the eager pass must enumerate **all** own dirs including
`ProgressPhotos/index.bin`. Own files never accessed never lazily migrate, so a lazy-only approach leaves
them under the backup-restorable key indefinitely — the **eager** pass is required, not optional. **Honest
limit:** until the eager pass completes, an un-migrated own photo is still openable under the friend
(backup-restorable) key; the binding guarantee is only fully real after the latch. **iCloud quota:** own
corpora have no count cap today; a heavy user's meal photos (~150-400 KB each at 1600px/q0.8) can reach
100-250+ MB against the user's iCloud storage — opt-in, incremental, CKAsset-backed, size-warned; **the
manifest itself can exceed CloudKit's ~1 MB inline limit at high photo counts** (thousands of UUID+hash
entries) and may need its own CKAsset/chunking. **Restore clobber:** own-photo ownership is scattered across
`Meal.photoID` / recipe id / progress index, so "empty store" must be a **per-corpus** file-presence check
(mirror the period no-clobber gate `isEmptyStoreForRestore`). **Out-of-scope leak (surfaced):** the
friend-wall `MeshPhotoCache.json` index stays **plaintext** (`senderName`/`senderFingerprint`/`senderSigningPublicKey`)
— friend identities remain in the device backup; sealing it under the friend-wall key is a clean follow-up
that touches the survives-delete-all wall (owner call, §12). **SE-wrap option** drags
`SecureEnclaveContentKeyWrap` out of `FernletLock` (non-public) into `FernletFoundation` — a package-DAG +
`spm-wall-check` change that must pass `spm-wall-selftest.sh`. **Dependency:** the route derives on Phase 2's
v2 salted derivation API; if that API shape is not final, the route's derivation and format pin block on it.

**Wall/custody / same-commit docs.** **Custody tripwire (CODEOWNERS-visible, same-commit):** binding K_own
updates `KeyCustodyBoundaryTests`' attribute assertions (add own-key `ThisDeviceOnly`, keep friend-key
AfterFirstUnlock), the `PrivateMediaKeyStore` doc comment, and `Verifiability.md` §6.3 + §4 — a deliberate
reviewable diff, the intended property. The grep-wall's bare-accessibility set `{PrivateMediaKeyStore.swift,
IdentityService.swift}` stays UNCHANGED (friend key remains the bare exception in that file); only the
attribute test gains the own-key assertion. If SE-wrap is chosen, that is a package-DAG change that must pass
`spm-wall-check.sh` and `spm-wall-selftest.sh`. **No-Tracking wall:** escrow photo records go to the **same**
allowlisted private CloudKit endpoint (no new host) but a new record TYPE/naming scheme — confirm
`NoTrackingBoundaryTests` needs no allowlist edit and document the new record type in `No-Tracking-Wall.md`
if the inventory enumerates record types. **Deletion audit (Phase-1 same-commit rule):** own-photo escrow
teardown added to `deleteAllData`, `PrivacyWipeCoverage.md`, and `PrivacyWipeCoverageTests` in one commit;
update the media-key exception row to reflect the split (friend key survives; own key device-bound, its
stores wiped).

---

## 11. Phase 7 — Duress PIN: decoy, silent-wipe+decoy, recovery-lock

**Goal.** A duress PIN with one chosen response per setup — **DECOY** (keyless unlock reusing the
period/intimacy hide machinery), **SILENT WIPE + decoy** (sub-second crypto-erase then decoy), and
**RECOVERY-LOCK** (destroy local unlock keys, keep the sealed ciphertext plus a recovery blob sealed to the
user's own second device, recoverable only in-person via QR + sealed mesh). The duress compare runs **ahead
of** the failed-attempt path and fires even during an active cooldown / `requiresReset`. Duress is last
because it reuses the Phase-1 key-destruction + store-rebuild funnel, the #1 SE-binding finality, the
scoped-lock API, the hide machinery, and the QR/mesh/X25519 stack.

**Current state (verified).** No existing duress/decoy/panic scaffolding (grep clean) — greenfield.
`FernletLockService` is `@MainActor @Observable`, created once per process as
`@State private var lockService = FernletLockService()` (`Fernlet/FernletApp.swift:33`), so any in-memory
non-persisted property is process-lifetime and resets on relaunch. `unlock()`
(`FernletLockService.swift:800-834`) refuses on `requiresReset` (:801) and `activeCooldownDeadline()` (:802)
BEFORE any scrypt derivation, then derives once, calls `verifierMatch` (:1030), and on `.none` calls
`recordFailedAttempt()` (:816, ladder :1147-1183). `changeCredential` (:753-791) and `setBiometricEnabled`
(:922-945) verify via the same `verifierMatch`. `reset()` (:904-915) does `KeychainItem.deleteAll` +
`SecureEnclaveContentKeyWrap.deleteKey` + buffer.purge + `purgeEncryptedEntities`. All `LockKeychainKey`
items (enum :348-379, `allCases` :1211-1232) are `WhenUnlockedThisDeviceOnly`, non-synchronizable
(`KeychainItem.store` :424-433). **Hide machinery (decoy substrate):** `FernletStore.isPeriodTrackingVisible`
(`FernletStore.swift:687-689`) = `settings.periodTrackingVisible ?? sex == .female`;
`isIntimacyTrackingVisible` (:694-696) = `isIntimateLoggingAllowed && settings.intimacyTrackingVisible`;
`sensitiveSurfaceVisibility` (:700-705) composes both; `allowedHealthCapabilities` (:1594) drops
`.cycleTracking`/`.intimateLogging` when not visible AND when `!lockState.isUnlocked(for: .privateHub)`
(scoped diff). `ContentView` wires `periodStore.isVisible`/`intimacyStore.isVisible` to those getters
(:141-145) and scrubs on the VALUE via `.onChange(of: store.sensitiveSurfaceVisibility)` (:132-135) —
`periodScrubHook` (`scrubCycleState` + `bridge.refresh(unlocked:false)`) + `scrubHiddenHealthContext`.
`HomeView.refreshRecentPeriodActivity` owns a **second** `HealthKitService` and the ungated Home
cycle-outlook card reads `periodStore.prediction`, so both must be covered by any gate. **Custodian
primitives:** `IdentityService.seal(_:to:format:)` (`IdentityService.swift:150-176`)
X25519-ECDH+HKDF+ChaChaPoly seals plaintext to a peer KA public key; `open(_:from:)` (:182-215) inverts it;
`localKeyAgreementPublicKey` (:98). `ProximityVerifyQR` (`Wire/ProximityVerification.swift`) is the signed
`fernlet://verify` QR carrying both peers' public keys + nonce + Ed25519 signature, plus a sealed
challenge/response proving the live peer holds the key (in-person mutual auth). **`FernletLock` does NOT
currently depend on `ProximityKit`.** **Funnel:** `deleteAllData` (:3941) delegates to `resetAll` (:4232)
and deliberately does NOT call `lockService.reset()` (only Settings App-lock reset does,
`SettingsSheet.swift:1875`); `PrivacyWipeCoverage.md:83` records the App-lock keychain as a DELIBERATE
survivor.

**Design.**

**Duress verifier storage.** Three new `WhenUnlockedThisDeviceOnly` `LockKeychainKey` cases: `.duressSalt`,
`.duressVerifier` (= `SHA256(scrypt(duressPIN, duressSalt))`), `.duressMode` (1 byte: 0=decoy, 1=wipe,
2=recoveryLock); plus (recovery) `.recoveryBlob`, `.custodianSigningPublicKey`,
`.custodianKeyAgreementPublicKey`. Add all to `allCases` (:1211-1232) — they store via the existing
`WhenUnlockedThisDeviceOnly` path, so `KeyCustodyBoundaryTests` covers them by construction.

**Own salt, not the shared primary salt.** Rationale: (1) it survives `changeCredential` without ever
re-entering the duress PIN (changeCredential rewrites only `.salt`/`.verifier`; a shared salt would strand
the duress verifier under the old salt after a re-key, since the app never has the duress plaintext at
change time to recompute it); (2) cryptographic independence; (3) cost is exactly one extra scrypt
derivation per unlock, already off-main in `Task.detached`, and unlock is not latency-critical. **To avoid a
timing oracle** that reveals whether a duress PIN exists, derive against `.duressSalt` **unconditionally**
(mint and store a random dummy `.duressSalt` when none is configured, compare to a never-matching verifier),
so unlock latency is constant at 2 derivations regardless. Centralize as
`private func duressMode(for passcode: String) async -> DuressMode?` that derives `scrypt(passcode,
.duressSalt)` and constant-time-compares `SHA256` against `.duressVerifier`.

**Ordering inside `unlock(passcode:for:)`.** After loading records but **before** the `requiresReset` and
cooldown guards, call `duressMode(for:)`; a match returns `handleDuress(mode:scope:)` and RETURNS — it never
reaches `recordFailedAttempt`, so duress never reads as a failed attempt AND fires even during
cooldown/`requiresReset`. (The decision: an inert duress PIN during lockout is the worst outcome, since
lockout is exactly when coercion is likely; the duress derivation is compared only to the duress verifier
and a non-match still hits the normal guards, so this is not a brute-force oracle on the real PIN.)
`changeCredential(current:)` and `setBiometricEnabled(_:passcode:)` call `duressMode(for:)` **FIRST** and,
on a match, invoke `handleDuress` instead of re-keying / enabling biometrics on the real key. `handleDuress`
logs the SAME audit string as the benign path (`FernletAuditLog` `lock.released` with method/scope; or
nothing) — no distinguishable label — and calls `clearAttemptState()` so no lingering attempt/cooldown
counter tells the two apart.

**DECOY (mode 0, non-destructive, reversible).** `clearAttemptState()`; leave `_contentKey` nil (KEYLESS —
`retainContentKey` is NOT called); set `public private(set) var isDuressSessionActive = true` (observable);
state = `.unlocked(scope:)`; do NOT set `passcodeUnlockedThisProcess`; return `UnlockResult(method:
.passcode)`. Because `contentKey(for: .privateHub)` returns nil, `ContentView.applySealedJournalActivation`
lands in `deactivateSealedJournals` (journal/worry appear empty). To force the sensitive-visibility gates
shut (a keyless hub unlock alone still lists HealthKit cycle samples via `isPeriodTrackingVisible`), the
store mirrors the flag: `ContentView`'s lock-state observer and initial `.task` set
`store.duressSessionActive = lockService.isDuressSessionActive`, and `FernletStore.isPeriodTrackingVisible`
/ `isIntimacyTrackingVisible` AND-in `!duressSessionActive`. This rides the **existing** hide machinery:
`sensitiveSurfaceVisibility` flips, the `.onChange(of: store.sensitiveSurfaceVisibility)` scrub fires
(dropping resident cycle state, the bridge trends, health context), `PrivateHubSection.visibleSections`
hides the period/intimacy sections, and `allowedHealthCapabilities` gates the HealthKit reads (covering
HomeView's second `HealthKitService` and the ungated outlook card). **The decoy lives in the SERVICE (the
flag) so it covers every lock entry surface, not a per-view `if`.** `isDuressSessionActive` is cleared ONLY
by a real-PIN unlock success, `configure`, or `reset` — NOT by `lock()` — so once a duress session starts,
biometrics stay suppressed (`isBiometricUnlockAvailable` ANDs `!isDuressSessionActive`) until the real PIN
is entered, closing the biometric side-door to the real content key.

**SILENT WIPE (mode 1, destructive, sub-second).** Synchronously destroy every local key so the sealed
corpus is crypto-erased instantly — delete `.salt`, `.verifier`, `.duressSalt`, `.duressVerifier`,
`.duressMode`, `.wrappedContentKey`, `.seWrappedContentKey`, `.biometricBypass`, `.biometricEnabledFlag`,
and `SecureEnclaveContentKeyWrap.deleteKey` (this **INVERTS** the lock-survives-wipe decision, but only on
this duress-only seam). Then re-mint a throwaway empty lock under the duress PIN (fresh salt/verifier/content
key) so the decoy is convincing and survives a re-lock — the duress PIN keeps opening an empty app — and
present the decoy (`isDuressSessionActive = true`, keyless view of the fresh empty content key, or keyless).
Then fire an injected, fire-and-forget hook `public var duressPurgeHook: (() -> Void)?` (wired app-side to
`FernletStore.deleteAllData`, the Phase-1 funnel) for the durable background purge of sealed CoreData rows
and cloud copies. **Sub-second crypto-erase comes from the synchronous key destruction; the funnel is
best-effort cleanup.** (This mode reuses BOTH the Opus/Phase-1 key destruction and the delete funnel the
Fable deletion-audit documents — see §4.1.)

**RECOVERY-LOCK (mode 2, new; only offered when a custodian is enrolled).** Enrollment (App-lock settings,
scope `.appLockSettings`, in-person): run the `ProximityVerifyQR` mutual-auth ceremony against the user's
second device to obtain its signing + KA public keys; seal a recovery wrapping of the content key to the
custodian KA pubkey via `IdentityService.seal(contentKeyData, to: custodianKAPub, format: .wire2)`; persist
`.recoveryBlob` + `.custodianSigningPublicKey` + `.custodianKeyAgreementPublicKey` (all `ThisDeviceOnly`;
safe locally — useless without the custodian KA private key). On trigger: destroy the LOCAL unlock keys
(`.salt`, `.verifier`, `.duressSalt`, `.duressVerifier`, `.duressMode`, `.wrappedContentKey`,
`.seWrappedContentKey`, `.biometricBypass`, `.biometricEnabledFlag`, SE key) but KEEP `.recoveryBlob` +
custodian keys + the sealed ciphertext corpus + the ProximityKit identity keys (`com.fernlet.identity`,
needed for the return ceremony); present the decoy. The coerced user then truthfully cannot open the data.
Recovery ceremony (later, in-person): QR mutual auth; the primary sends `.recoveryBlob` over the sealed
wire; the custodian opens it with `IdentityService.open(recoveryBlob, from: primaryKAPub)` and either
returns the content key sealed to the primary's current KA pub (primary re-establishes local unlock under a
NEW passcode via `reestablishLocalUnlock(contentKey:credential:)`: mint salt/verifier, wrap the recovered
content key, restore SE/biometric as chosen) or signals delete.

**Seam placement / wall.** The crypto and key-custody half lives in `FernletLock` (store/keep/destroy the
recovery blob; a public `reestablishLocalUnlock(contentKey:credential:)` entry). The ProximityKit ceremony
(QR + `IdentityService` seal/open + mesh transport) lives in a **NEW app-side `DuressRecoveryCoordinator`**
(the app target already imports both `FernletLock` and `ProximityKit`), so `FernletLock` gains **NO**
ProximityKit edge and the sealed-side module stays lean.

**State/API additions.** `isDuressSessionActive`, `passcodeUnlockedThisProcess` (defined in Fable's
PIN-before-biometrics; this phase adds the `!isDuressSessionActive` conjunct to `isBiometricUnlockAvailable`
— see §4.1), `isBiometricUnlockAvailable`, `duressMode(for:)`, `handleDuress(mode:scope:)`,
`configureDuress(pin:mode:)`, `removeDuress()`, `hasDuressConfigured`,
`enrollRecoveryCustodian(sealedBlob:signingPub:kaPub:)`, `hasRecoveryCustodian`,
`reestablishLocalUnlock(contentKey:credential:)`, `duressPurgeHook`. Every mode reuses the scoped seams:
`unlock(passcode:for:)` (entry), `contentKey(for: .privateHub)` (kept nil by the keyless decoy), state
`.unlocked(scope:)` (dismisses the gate), `revokeUnlockOutside` (unaffected).

**Steps.** (1) add the six `LockKeychainKey` cases to `allCases`. (2) `duressMode(for:)` own-salt
derivation, unconditional (dummy salt when unconfigured); `configureDuress`/`removeDuress`/
`hasDuressConfigured`. (3) reorder `unlock(passcode:for:)` to call `duressMode(for:)` before the guards; add
the same duress-first check to `changeCredential`/`setBiometricEnabled`. (4) `handleDuress(.decoy)`. (5)
mirror `store.duressSessionActive` in `ContentView`'s lock-state observer + initial `.task`, AND-in
`!duressSessionActive` to the visibility getters. (6) `handleDuress(.silentWipe)` + `duressPurgeHook` wired
to `FernletStore.deleteAllData` (**DEPENDS ON the Phase-1 funnel**). (7) `handleDuress(.recoveryLock)` +
`enrollRecoveryCustodian`/`hasRecoveryCustodian`/`reestablishLocalUnlock`. (8) app-side
`DuressRecoveryCoordinator` (enrollment + recovery ceremony). (9) duress-PIN setup UI under App-lock
settings (scope `.appLockSettings`): choose one response; RECOVERY-LOCK disabled/hidden unless
`hasRecoveryCustodian`; enter a duress PIN distinct from the real PIN; reuse `FernletNumericPad` / the setup
wizard; add a Manage/remove path. (10, SAME COMMIT) update `PrivacyWipeCoverage.md` (document the
duress-wipe path over `com.fernlet.lock` as a duress-only exception to the lock-survives-wipe rule) and
`Verifiability.md` §4/§6 (SE key destroyed on duress-wipe/recovery-lock; biometric bypass destroyed);
update the `FernletLock` and `FernletLockUI` DocC pages. (11) full regression suite + lock suites +
`KeyCustodyBoundaryTests` + `PrivacyWipeCoverageTests` + the S3 wall self-test.

**Files.** `FernletLock/FernletLockService.swift`, `FernletLock/SecureEnclaveContentKeyWrap.swift`,
`FernletLockUI/FernletLockView.swift`, `FernletLockUI/FernletLockGate.swift`,
`FernletFoundation/FernletLockError.swift`, `Fernlet/FernletApp.swift`, `Fernlet/ContentView.swift`,
`Fernlet/FernletStore.swift`, `Fernlet/SettingsSheet.swift`, `Fernlet/VerifyQRViews.swift` (reuse the QR
ceremony UI patterns), **`Fernlet/DuressRecoveryCoordinator.swift` (NEW)**,
**`Fernlet/DuressPINSetupView.swift` (NEW)**, `ProximityKit/Identity/IdentityService.swift` (read-only
reuse), `ProximityKit/Wire/ProximityVerification.swift` (read-only reuse), `Docs/PrivacyWipeCoverage.md`,
`Docs/Verifiability.md`, `FernletLock/Documentation.docc/FernletLock.md`,
`FernletLockUI/Documentation.docc/FernletLockUI.md`, `FernletLockServiceTests.swift`,
`FernletLockTests.swift`, **`FernletTests/DuressLockTests.swift` (NEW)**.

**Tests.** Duress verifier own-salt survives passcode change (configure real + duress; `changeCredential`;
duress still triggers, real path still unwraps the same key — mirror `biometricBypassSurvivesPasscodeChange`
`FernletLockServiceTests:122`). Duress fires during lockout (drive `recordFailedAttempt` to `requiresReset`
and an active cooldown via `FakeDateProvider`/`MockUptimeProvider`; the duress PIN triggers and does NOT
throw resetRequired/cooldownActive; a wrong non-duress PIN still refuses). Duress never counts as a failed
attempt (`currentAttemptCount` + cooldown level unchanged; identical `lock.released` audit label). Duress
consulted by `changeCredential` and `setBiometricEnabled` (real verifier + `wrappedContentKey` untouched).
DECOY keyless (`state == .unlocked(scope:)`, `hasResidentContentKey == false`,
`contentKey(for: .privateHub) == nil`, `isDuressSessionActive == true`, `passcodeUnlockedThisProcess ==
false`; a real-PIN unlock clears the flag and yields the real key; `lock()` does NOT clear the flag). DECOY
visibility (app-level `@testable import Fernlet`, like `FernletLockScopeTests`):
`isPeriodTrackingVisible`/`isIntimacyTrackingVisible` false regardless of settings;
`allowedHealthCapabilities` drops the two; `periodStore` entries + prediction scrubbed (assert via the scrub
hook path); reversible when the flag clears. WIPE crypto-erase
(`.verifier`/`.wrappedContentKey`/`.seWrappedContentKey`/`.biometricBypass` gone by keychain read-back; old
key unrecoverable; throwaway lock opens to empty under the duress PIN; `duressPurgeHook` invoked once; SE key
deleted — `SecureEnclaveContentKeyWrap.unwrap` returns nil). RECOVERY-LOCK round-trip (enroll a fake
custodian keypair; trigger; local unlock keys destroyed but `.recoveryBlob` + custodian keys + sealed corpus
+ identity keys intact; custodian `IdentityService.open` recovers the exact content key; `reestablishLocalUnlock`
restores unlock so the corpus opens again). RECOVERY-LOCK gate (`hasRecoveryCustodian == false` makes
`configureDuress(mode: .recoveryLock)` reject / the setup option unavailable; enrolling flips it). Custody +
wipe manifests: `KeyCustodyBoundaryTests` passes with the new rows (all `WhenUnlockedThisDeviceOnly`,
non-sync); `PrivacyWipeCoverageTests` still passes (normal funnel still keeps `com.fernlet.lock`; the
duress-wipe path is a separately-tested exception, not a change to `deleteAllData`).

**Risks / honest limits.** **DATA LOSS (WIPE):** silent-wipe is irreversible by design and destroys the SE
key, biometric bypass, and content key sub-second — a duress-ONLY seam never reachable from the normal
funnel, its copy/behavior reviewed as a destructive path. **DATA LOSS (RECOVERY-LOCK):** if the custodian
device is lost/wiped/its KA key rotates, the sealed corpus is permanently unrecoverable; possession of the
custodian device (plus its own unlock) = full recovery capability — the custodian is a **second key
holder**, not an escrow with extra checks. **DECOY reversibility invariant:** the decoy MUST persist nothing
and delete nothing — it only flips in-memory flags and rides the existing scrub-on-value path; a bug that
persisted the forced-hidden visibility (e.g. writing `settings.periodTrackingVisible = false`) would turn a
reversible decoy into silent data hiding and could interact with sealed-backup toggles that DELETE the
iCloud backup (the period-intimacy-gate hazard). Gate strictly via the in-memory flag, never the setter.
**Biometric side-door:** for the non-destructive DECOY the `.biometricBypass` item still holds the REAL
content key; mitigated by `isBiometricUnlockAvailable` ANDing `!isDuressSessionActive` AND
`passcodeUnlockedThisProcess`, and by NOT clearing the flag on `lock()` — both PIN-before-biometrics (Fable)
and the duress flag (here) must hold for this to be safe. **Timing oracle:** own-salt means 2 derivations
when configured vs 1 when not — mitigated by deriving against a dummy salt unconditionally. **Ordering vs
Phase 1:** the WIPE's durable purge reuses the Phase-1 funnel via `duressPurgeHook`; the sub-second
crypto-erase does NOT depend on Phase 1 (pure key destruction), but the background cloud/CoreData purge does
— do not ship WIPE claiming durable purge before Phase 1. **Cloud residue (honest limit):** silent-wipe
cannot instantly purge off-device copies — sealed iCloud backups and heart-drop dead-drops purge in the
background; offline, dead-drops age out at the 14-day sender lifetime; the crypto-erase makes them unopenable
**on this device** but the ciphertext exists remotely until purge/age-out. **Post-WIPE decoy state:**
re-minting a throwaway lock under the duress PIN keeps the decoy convincing across a re-lock, but it makes
the duress PIN the real PIN of a now-empty app (no duress PIN remains until re-set); the alternative (leave
`notConfigured`) shows a "set up app lock" CTA — a tell. Owner decision (§12). **Rebase coupling:**
everything targets the Phase-0 scoped API. **changeCredential/setBiometricEnabled coverage:** forgetting the
duress-first check in either lets a coerced user's duress PIN silently re-key or enable biometrics on the
REAL content key — both must consult `duressMode(for:)` first. **Audit indistinguishability:** any divergent
audit string, attempt-counter state, or cooldown record after a duress unlock is a forensic tell — emit the
benign label and `clearAttemptState` identically.

**Wall/custody / same-commit docs.** `FernletLock` is NOT a walled module and already imports
`PrivateStoreCore`/`PrivateHealthStore` (`FernletLockService.swift:17-18`), so the crypto/custody half adds
no forbidden edge. The recovery-lock ProximityKit work is deliberately in the app-side
`DuressRecoveryCoordinator`, NOT inside `FernletLock`, so `FernletLock` gains no ProximityKit dependency —
re-run `spm-wall-selftest.sh` after any `Package.swift` edge change. **No-Tracking wall:** recovery is
in-person mesh + QR ONLY, NO CloudKit/dead-drop path (per the locked decision) — NO new outbound
destination, NO allowlist/`No-Tracking-Wall.md` change; confirm `NoTrackingBoundaryTests` stays green and do
NOT introduce any cloud recovery route. **Key custody:** the six new rows go through the existing
`WhenUnlockedThisDeviceOnly`, non-synchronizable path, so `KeyCustodyBoundaryTests` covers them by
construction; the recovery blob is `ThisDeviceOnly` sealed data (safe locally); do NOT promote any duress
item to iCloud Keychain. **Custody tripwire / same-commit docs:** the duress-WIPE path destroys
`com.fernlet.lock` + the SE key, inverting `PrivacyWipeCoverage.md:83` — that file MUST be updated in the
SAME commit to document the duress-only wipe exception, and `Verifiability.md` §4/§6 must note the SE-key +
biometric-bypass destruction. `FernletLockService.swift`, the delete funnel, and the wipe-coverage doc are
CODEOWNERS-protected — these changes require the wall review gate. `PrivacyWipeCoverageTests` must stay
green: the normal `deleteAllData` still keeps the lock; the duress-wipe is a separately-tested destructive
seam, not an edit to the funnel's manifest.

---

## 12. Cross-cutting risks (this track)

Stated once here; each phase above carries its own local instances. Several are the *same* hazard recurring
across phases — a reviewer should watch for the class, not just the instance. Only the hazards this track
touches are listed.

| Hazard | What it is | Opus phases it touches |
|---|---|---|
| **Restore-before-reupload ordering** | The launch pass must restore every payload before any reconcile/re-upload can run, or a not-yet-restored device overwrites a good cloud backup with an empty one. | 3 (journal/intimacy `adoptSyncedEscrowAndReupload` count>0 guard), 5 (per-corpus no-clobber on the escrow photo route) |
| **Empty-store clobber** | `reconcileChunked` writes a head record even for count 0, so any export from an empty store replaces the cloud copy. Defense = restore-first ordering + `count > 0` guards. | 3, 5 |
| **FernletDomainModel / enum clean-build hazard** | Adding `CaseIterable` enum cases without a CLEAN build lets an incremental compile mask a non-exhaustive switch and ship a trap. | 3 (`SealedBackupPayloadType` +2 cases), 7 (`DuressMode`; `LockKeychainKey` +6 cases) — clean build after each |
| **Tolerant-decode on new prefs** | Every new `StoragePreferences` field must be `decodeIfPresent(...) ?? <default>`; a non-optional field throws on every existing blob. | 3 (`sealedBackupJournalEnabled`/`sealedBackupIntimacyEnabled`). _(Fable's #6 `backupExclusionChoiceMade` is the sibling instance — do NOT flip the existing bool's default there.)_ |
| **App-lock-survives-wipe inversion (duress-only)** | The duress WIPE destroys `com.fernlet.lock` + the SE key, inverting `PrivacyWipeCoverage.md:83`. Must be a duress-only seam never reachable from `deleteAllData`, documented same-commit. | 7 (and the Phase-1 crypto-erasure baseline it reuses) |
| **Bind-before-route / bind-before-migrate ordering** | Device-binding a key before the sanctioned cross-device route ships (or before every corpus file is re-sealed) silently strands data as `.unreadable`. Defense = ship the route / complete the migration first, gate the bind on a completion latch. | 5 (own-photo K_own bind gated on `ownPhotoKeyMigrationComplete` + escrow route), 4 (keep-old-until-verified before deleting the scrypt item) |
| **Nothing-silent principle** | A failed delete, a deferred restore, an orphaned CKRecord, or a duress event must surface a legible state, never a silent success/empty. | 1 (honest erasure docs), 3 (toggle-off orphan retryable banner; `deferredLocked` self-heal), 4 (explicit "sealed data unrecoverable" state), 5 (truncation/quota surfacing), 7 (duress must be forensically *indistinguishable* from benign — the inverse discipline: silent to an observer, but never a silent data loss to the user's own recovery model) |
| **Same-commit doc + custody-tripwire coupling** | Custody/format/wipe changes must move their doc + test in the same commit or CI fails. | 1, 2, 3, 4, 5, 7 (each lists its obligations) |

---

## 13. Testing & verification strategy (this track)

- **Suites to extend:** the lock suites (`FernletLockServiceTests` / `FernletLockTests` + new
  `DuressLockTests`) for the Phase-0 rebase regression and Phase 7 duress; `SealedBackupFormatPinTests`
  (Phase 2 v1+v2 pins, Phase 5 per-photo AAD v3 pin); `SealedBackupRollbackTests` (Phase 3 new payloads);
  `SecureEnclaveWrapTests` + `KeyCustodyBoundaryTests` (Phase 4 hard-bound; Phase 5 own-key device-bound;
  Phase 7 new rows); `StoragePreferencesTests` (Phase 3 tolerant decode); `PrivacyWipeCoverageTests`
  (Phase 5 own-photo escrow token; Phase 7 duress-wipe kept as a separately-tested exception); the
  repository unit tests for the two new backup-capable repositories (Phase 3); `DeleteAllDataTests`
  (Phase 1 store-rebuild residue + locked-deletion invariant).
- **Custody-tripwire updates (same-commit, CODEOWNERS-visible):** `KeyCustodyBoundaryTests` for #1
  (hard-bound rows), #3 (own-key `ThisDeviceOnly` assertion; the grep-wall bare-accessibility set stays
  unchanged), and the duress rows (covered by construction). `Verifiability.md` §2/§4/§5/§6 rows edited
  alongside the code they describe (§6.1/#1, §6.3/#3, §6.4/#4).
- **Clean-build requirements:** a CLEAN build after Phase 3 (`SealedBackupPayloadType` +2 cases) and after
  Phase 7's `DuressMode` / `LockKeychainKey` additions, so every non-exhaustive switch fails to compile
  rather than shipping a masked trap (the FernletDomainModel-class hazard). Incremental builds mask it.
- **Swift-Testing vacuous-filter gotcha:** method-level `-only-testing:` selectors on Swift Testing suites
  can silently match nothing and report success; scope by **suite**, and verify the run actually executed
  the intended cases (check counts / the "TEST EXECUTE SUCCEEDED" banner), not a naïve grep of the log.
- **Wall gates before merge on any phase touching a wall file:** `Scripts/spm-wall-check.sh` +
  `Scripts/spm-wall-selftest.sh` (any `Package.swift` DAG change — relevant only if #3 chooses the
  SE-wrap-K_own option); `FernletTests/S3BoundaryTests`; `FernletTests/NoTrackingBoundaryTests` (confirm
  green — **no phase in this track introduces a new outbound destination**; recovery-lock is in-person mesh
  only); the doc-coverage baseline (`Scripts/doc-coverage-scan.py`) for the touched DocC pages and
  load-bearing doc comments.
- **Test cadence:** targeted per-suite during increments; the full suite in batches at phase ends (the lock
  suite dominates, ~10 min); one clean build + the wall checks before each merge.
- **Shared-worktree discipline:** several sessions may share this tree and DerivedData — pathspec commits
  only, verify in an isolated worktree, and never attribute another session's flake to this diff.

---

## 14. Open owner sub-decisions (this track; residual calls, not blockers)

Deduped from the drafting passes. Each is a crisp question with a recommendation; none blocks starting the
build order.

**Lock / duress (Phase 7)**
- **One duress PIN with a chosen mode, or multiple duress PINs each mapped to a mode?** One = exactly one
  extra scrypt derivation per unlock; N PINs = N× latency. Storage supports one. **Recommend one.**
- **Post-WIPE decoy state:** re-mint a throwaway lock under the duress PIN (convincing, survives a re-lock,
  but the duress PIN becomes the empty app's real PIN) vs leave `notConfigured` (shows a "set up app lock"
  CTA — a tell). **Recommend re-mint.**
- **Timing oracle:** derive against a dummy duress salt unconditionally for constant 2-derivation latency
  (**recommended**) vs accept that unlock latency reveals only "a duress PIN is configured".
- **`isDuressSessionActive` lifetime:** clear ONLY on real-PIN unlock/configure/reset (**recommended**,
  keeps biometrics suppressed through a decoy re-lock) vs clear on `lock()`.
- **Recovery-lock presentation:** show the empty DECOY hub (**recommended**, hides that a recovery-lock
  happened) vs a benign "needs recovery on your other device" screen. The locked decision allows either.
- **Custodian enrollment entry point:** App-lock settings (scope `.appLockSettings`) via an in-person QR
  ceremony reusing `VerifyQRViews` patterns; confirm the entry point and whether enrollment requires the
  real PIN first.
- **Should a duress unlock count toward `passcodeUnlockedThisProcess`?** **Recommend NO** (keeps biometrics
  suppressed and the real content key unreachable during a duress session) — assumed throughout. (The flag
  is Fable's, but the duress interaction is decided here.)

**Sealed backup (Phase 2, 3)**
- **v2 discriminator:** explicit `formatVersion` field (**recommended**, fail-closed like generation) vs
  inferring v2 from salt presence.
- **v2 info string:** `"com.fernlet.sealed-backup.v2"` (**recommended**, satisfies §6.4 and backstops an
  accidental empty salt) vs reusing the v1 info and relying on the salt alone.
- **Scope of v2 emission:** make ALL new writes v2 including period + sensitiveNotes (**recommended** — the
  blast-radius win applies everywhere) vs only the two new payloads.
- **Toggle-off orphan gap:** fix here by keeping the pref ON + a retryable banner on a failed disable-delete
  (**recommended**; reuses delete-all's `keepSealedBackupFlags` philosophy) vs leave the current "honor off
  intent" behavior and accept orphaned CKRecords. Changes disable UX.
- **Journal skeleton reconstruction:** add the `reinstateJournalEntries` host hook so journal restore is
  self-sufficient (**recommended**; required for sync-off recovery under #1) vs rely on the iCloud days blob
  (fails silently for the users the backup most protects).
- **No-lock journal coverage:** leave no-lock device-keyed journals out of the backup (**recommended** —
  consistent with the separately-deferred §6.2 and unaffected by #1) vs expose the device journal key to the
  backup coordinator.
- **Restore semantics:** insert-into-empty + diverged latch for both new types (**recommended**) vs
  whole-store overwrite (can clobber user-authored text).
- **Per-type chunk size:** reuse `periodBackupChunkSize` (250) vs a smaller journal chunk (free text is
  longer than cycle notes). Minor; affects CKAsset size, not correctness.
- **Confirm the intimacy-in-backup REVERSAL is intended** and update the standing decision doc — it
  overturns the earlier "intimacy not in backup" call.

**Lock content key (Phase 4)**
- **SE-wrap the scrypt-BLOB vs the raw content key:** if the owner wants #1 to also preserve the
  cryptographic app-PIN requirement **on-device** (not just off-device), SE-wrap the existing scrypt-wrapped
  blob (`seWrappedContentKey = SE-wrap(ChaChaPoly-seal(contentKey, scryptKey))`); then "delete the scrypt
  item" means delete the standalone item while the scrypt wrap survives nested inside the SE blob, so unlock
  needs SE (device) AND the passcode. Costs one extra unwrap layer + a slightly more complex migration; buys
  a real barrier for alphanumeric passwords. The literal owner spec (raw-key SE wrap) is simpler and still
  delivers the off-device gain.
- **Biometric-bypass residual:** ACCEPT+document for Phase 4 (**recommended**; it's `ThisDeviceOnly`,
  destroyed under duress WIPE) vs route the biometric path through the SE too. Deferred owner call.
- **Crypto-erasure funnel scope:** Option B (store rebuild) for BOTH `reset()` and `deleteAllData`
  (**recommended** — one seam Phase 7 reuses) vs scope the rebuild to reset/duress-WIPE only and leave
  `deleteAllData` at row-delete + honest documentation.
- **Narrative-buffer key deletion:** fold `com.fernlet.narrative-buffer` key deletion into the funnel
  alongside the journal/worry device keys (**recommended** symmetric follow-up; closes the last
  surviving-key asymmetry under the new baseline).
- **Hard-bound unrecoverable UX copy:** the new "sealed data can no longer be opened on this device" state
  needs owner-approved wording matching the honest-recovery tone of the existing warnings.

**Media (Phase 5)**
- **K_own binding class:** `AfterFirstUnlockThisDeviceOnly` (**recommended** baseline; no DAG change) vs
  SE-wrap (stronger — key never extractable even with the passcode — but relocates
  `SecureEnclaveContentKeyWrap` to `FernletFoundation` and makes it public).
- **One "own photos" escrow toggle vs per-corpus toggles** (meal/recipe/progress). Per-corpus gives quota
  control; one is simpler. WS-5 destructive-off ceremony applies either way.
- **Seal the friend-wall plaintext index (`MeshPhotoCache.json`)** under the friend-wall key to close the
  friend-name/fingerprint backup leak? Touches the survives-delete-all friend wall — **recommend as a scoped
  follow-up, defaulted OUT of #3.**
- **Add a count/size cap (+ soft warning) to own-photo corpora** before enabling escrow (none exists today;
  the corpus rides the user's iCloud quota).
- **Manifest chunking threshold:** at what photo count does the manifest move from an inline field to its own
  CKAsset/chunk set (CloudKit ~1 MB inline limit).
- **Own-photos key on delete-all:** keeping the K_own row (like the friend key) is harmless and avoids a
  stale-cache hazard; the owner may prefer to also delete it for tidiness. Either is defensible.

---

## 15. Cross-track boundary recap

For convenience, the three boundary-crossing edges from §4.1, restated as the reviewer's checklist:

1. **Fable/PIN-before-biometrics** cannot land until **Opus/Phase 0** (scoped-unlock rebase) is in; it
   extends `unlock(passcode:for:)` / `configure(credential:grantingScope:)` and consumes the
   `isBiometricUnlockAvailable` policy whose `!isDuressSessionActive` conjunct is wired by **Opus/Phase 7**.
2. **Fable/#6** (default-on backup exclusion) is only justified after **Opus/#1** (Phase 4) makes an
   included `FernletPrivate` file all-leak-no-recovery; it must land after #1.
3. **Opus/duress-WIPE** (Phase 7) reuses **Opus/Phase-1 crypto-erasure** (key destruction) AND the delete
   funnel the **Fable deletion-audit** verification documents; do not ship WIPE's durable-purge claim before
   both funnel halves are in.

**Related documents:**
- Sibling track: [`Plan-Security-Hardening-FableTrack-2026-08-10.md`](Plan-Security-Hardening-FableTrack-2026-08-10.md)
  (PIN-before-biometrics, the `RecipeWebImageAttemptMemory` gap fix, the deletion-audit verification pass,
  and Hardening #6).
- The combined superset: [`Plan-Security-Hardening-2026-08-10.md`](Plan-Security-Hardening-2026-08-10.md).
- [`Docs/Verifiability.md`](Verifiability.md) — the §6 owner-decision list this track closes three of
  (#1/§6.1, #3/§6.3, #4/§6.4), plus the honest-limits framing (§5) each phase updates.
- [`Docs/PrivacyWipeCoverage.md`](PrivacyWipeCoverage.md) — the deletion contract; Phases 1/5/7 edit it in
  the same commit as their wipe changes.
- [`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md) — confirm every phase stays inside the egress allowlist
  (no phase adds an outbound destination; recovery-lock is in-person mesh only).
- [`Docs/CloudKit-Schema-Deploy.md`](CloudKit-Schema-Deploy.md) — the Phase-2 `formatVersion`/`keySalt`
  fields and the Phase-5 per-photo record type must reach the production schema before those writes land.
- Module DocC landing pages updated per phase:
  [`FernletLock`](../FernletKit/Sources/FernletLock/Documentation.docc/FernletLock.md),
  [`FernletLockUI`](../FernletKit/Sources/FernletLockUI/Documentation.docc/FernletLockUI.md),
  [`PrivateStoreCore`](../FernletKit/Sources/PrivateStoreCore/Documentation.docc/PrivateStoreCore.md),
  [`PrivateMediaStore`](../FernletKit/Sources/PrivateMediaStore/Documentation.docc/PrivateMediaStore.md).

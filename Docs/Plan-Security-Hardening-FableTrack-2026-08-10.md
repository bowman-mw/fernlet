# Plan — Security hardening, FABLE track: PIN-before-biometrics, deletion audit, default-on backup exclusion (2026-08-10)

> **Status: FULLY EXECUTED 2026-08-11.** Every phase in this track shipped and merged — P0b
> (PIN-before-biometrics) `f5c1f13`, P0c (`RecipeWebImageAttemptMemory` wipe gap) `2759af9`, P1b
> (deletion-audit verification pass) `500cf5d`, P6 (default-on backup exclusion) `4a853d4`, and P8
> (capture protection, queued into this build at the owner's request) `2e6cadb`. The ledger in
> [`Plan-Security-Hardening-Runbook.md`](Plan-Security-Hardening-Runbook.md) is the authoritative
> record. **Do not execute this file as a plan** — it was written against `main` @ `eeec53e` and its
> file:line steps predate the phases that rewrote those seams.
>
> One obligation is still open: P8's capture-protection spec §7 **manual device matrix** has never
> been walked on real hardware, and three §9 follow-ups were surfaced and deliberately not built. See
> [`Design-Capture-Protection-2026-08-10.md`](Design-Capture-Protection-2026-08-10.md).

**Status:** Approved build plan, **Fable review track**. Base branch `main` @ `eeec53e`, first work off
the unmerged `claude/scoped-unlock-per-screen` (`b293238`). This file carries the **lower-risk,
mechanical, reversible, no-novel-crypto** slice of the 2026-08-10 security-hardening effort — the work
Fable orchestrates *and* reviews end to end. It closes **`Verifiability.md` §6.6** (default-on backup
exclusion for the sealed `FernletPrivate` store, hardening #6) and delivers two of the three **new asks**
the owner raised on 2026-08-10: **PIN-before-biometrics** (no Face ID until a passcode unlock has
happened once this process) and the **deletion-audit verification pass** (verify `PrivacyWipeCoverage.md`
against code and close the one confirmed gap).

**Sibling file:** the crypto-critical, irreversible, and novel-trust-model work — the Phase-0 scoped-unlock
rebase, the crypto-erasure *redesign* half of the deletion audit, the v2 salted escrow format (#4), the
journal+intimacy backup coverage, hard SE-binding (#1), the media-key split (#3), and the duress PIN
(Phase 7) — lives in [`Plan-Security-Hardening-OpusTrack-2026-08-10.md`](Plan-Security-Hardening-OpusTrack-2026-08-10.md)
and is reviewed by Opus. **The fixed global phase order (0→7) spans both files**; neither file
re-sequences it, and two of this track's items depend on an Opus-track phase landing first (§3).

The through-line is the standing Fernlet posture from [`Verifiability.md`](Verifiability.md): **a privacy
claim is only as good as the machine that checks it, and every trade must be a loud, reviewable diff.**
Even the mechanical items here carry their same-commit doc and test-tripwire obligations for exactly that
reason.

---

## 1. What this track plans, at a glance

Three Fable-track workstreams across two phases (Phase 0 foundation items, plus Phase 6). Every file:line
below was checked at the base revisions noted; **re-verify against the Phase-0 rebased tree before writing
code** — the scoped-unlock rebase moves the `unlock()`/`configure()`/`reset()` and `FernletLockView`
signatures the PIN work extends.

| Global phase | Workstream (one-line goal) | Risk | Inverts / reverses a recorded decision? |
|---|---|---|---|
| **0** | **PIN-before-biometrics** — never offer biometric unlock until a passcode unlock (or initial `configure`) has succeeded once this process; fail-closed at the service + button + auto-prompt | Low | No |
| **0 / 1** | **Deletion-audit gap fix** — `RecipeWebImageAttemptMemory.clearAll` is called in `resetAll` but absent from the wipe doc + test manifest; add the doc row + manifest token + behavioral test, same commit | Low | No |
| **1** | **Deletion-audit verification pass** (verify half only) — walk the real wipe funnel against `PrivacyWipeCoverage.md` + the `wipeManifest`, confirm every token resolves and the deliberate-exceptions table is clean | Low | No (documents; no behavior change) |
| **6** | **#6 default-on backup exclusion** — flip the sealed `FernletPrivate` store to default-excluded via a one-time honest-trade-off prompt for existing installs; fresh installs default excluded | Medium | Changes the default (a recovery-expectation change), gated after Opus/#1 |

The **crypto-erasure normalization** half of the Phase-1 deletion audit (the keyless store rebuild, and
the `purgeEncryptedEntities` honesty-doc redesign) is **not in this file** — it is a crypto-seam change and
lives on the Opus track (§3, §6 below).

---

## 2. Locked owner decisions relevant to this track (2026-08-10)

Recorded here so the file is self-contained. These are settled; residual soft calls are the appendix in
§10.

- **PIN-before-biometrics.** Biometric unlock is not offered until a passcode unlock has succeeded once in
  the current app **process** (per launch/termination, like iOS first-unlock-after-reboot). `configure()`
  (initial passcode setup) counts as the process's passcode success. Enforced **fail-closed at the
  service** (`unlockWithBiometrics` guard) **plus** the button condition and the auto-prompt guard.
- **"Review how data is deleted" = a deletion-audit deliverable.** Verify `PrivacyWipeCoverage.md` against
  code, fix the one found gap (`RecipeWebImageAttemptMemory.clearAll` is called in `resetAll` but absent
  from the doc + test manifest — **same-commit rule, do not let it ride silently**), and normalize
  crypto-erasure honesty for the locked sealed corpus. *This track owns the verify-against-code +
  gap-fix half; the crypto-erasure normalization is the Opus track's.*
- **#6 (default-on backup exclusion for `FernletPrivate`).** Existing installs get a **one-time prompt**
  (honest recovery trade-off, matching the current warning copy); fresh installs default to excluded.
  Sequences **after #1** — post-#1 an included file is all-leak-no-recovery, which is exactly what makes
  the default flip easy to justify.

---

## 3. Dependency & sequencing

The global phase order (fixed in the Opus file) is `0 → 1 → 2 → 3 → 4 → 5 → 6 → 7`. This track occupies
Phase 0, part of Phase 1, and Phase 6. **Do not re-sequence.**

```
Phase 0  Foundation
  │  (Opus) rebase claude/scoped-unlock-per-screen (b293238) onto main (eeec53e);
  │         ALL lock work builds on the scoped .unlocked(scope:) API      ← Fable/PIN depends on this
  │  (Fable) PIN-before-biometrics        (small, independent of the gap fix)
  │  (Fable) RecipeWebImageAttemptMemory wipe-coverage gap fix  (small, independent)
  ▼
Phase 1  Deletion audit
  │  (Fable) verification pass — verify PrivacyWipeCoverage.md against the funnel; the one gap
  │          is already closed in Phase 0
  │  (Opus)  crypto-erasure baseline redesign (keyless store rebuild) — NOT this file
  ▼
  …  Phases 2–5 are entirely Opus-track  …
  ▼
Phase 6  (Fable) #6 default-on backup exclusion via one-time prompt   ← depends on Opus/#1 (Phase 4)
  ▼
Phase 7  (Opus) Duress PIN — reuses the delete funnel this track's audit documents
```

**Why each in-track edge holds:**

- **Phase 0 (PIN) is independent of the gap fix.** The two Phase-0 Fable items touch disjoint files
  (`FernletLock*` vs `PrivacyWipeCoverage*` / `FernletStore` test surface) and can land in either order,
  or in Phase 0 and Phase 1 respectively.
- **Gap fix (Phase 0) precedes the verification sign-off (Phase 1).** The verification pass's headline
  result *is* "the one reverse-direction gap is `RecipeWebImageAttemptMemory`" — closing it in Phase 0
  lets Phase 1 assert a clean, fully-reconciled doc.
- **#6 is last of this track's items (Phase 6) because it is gated on Opus/#1.** The default flip's whole
  justification is the post-#1 quantification (an *included* file leaks only plaintext metadata columns,
  §7); shipping it before #1 would flip a default whose recovery cost is not yet zero.

### 3.1 Cross-track dependencies

These edges cross the Fable↔Opus boundary; each references the sibling file
[`Plan-Security-Hardening-OpusTrack-2026-08-10.md`](Plan-Security-Hardening-OpusTrack-2026-08-10.md).

- **Fable/PIN-before-biometrics → Opus/Phase-0 rebase (scoped-unlock API).** PIN-before-biometrics
  extends `unlock(passcode:for:)`, `configure(credential:grantingScope:)`, `reset()`, and
  `FernletLockView(scope:)` — the scoped signatures the rebase introduces. Writing against the
  pre-scope signatures will not compile after the rebase, and landing before it conflicts in
  `unlock()`/`configure()`/`reset()`. **The Opus-track rebase must land first.**
- **Fable/#6 → Opus/#1 hard SE-binding (Phase 4) landing first.** Post-#1 an *included* `FernletPrivate`
  file is ciphertext-unreadable off-device even with the passcode, so its only marginal backup exposure
  is the plaintext metadata columns — which is the *all-leak-no-recovery* condition that justifies
  defaulting exclusion on at zero recovery cost. **#6 sequences after #1.**
- **Opus/duress-wipe (Phase 7) → this track's deletion audit (reverse edge).** The Opus duress WIPE reuses
  **both** the Opus/Phase-1 crypto-erasure baseline **and** the normal delete funnel that *this* track's
  deletion-audit verification documents. The audit is the contract the WIPE seam is checked against; keep
  `PrivacyWipeCoverage.md` accurate so Phase 7 has a forensically-real funnel to reuse.

The fixed global phase order governs execution across both files. Neither file re-sequences it.

---

## 4. Phase 0 — PIN-before-biometrics

**Goal.** Never offer biometric unlock until a passcode unlock (or initial `configure`) has succeeded once
in the current app process — like iOS first-unlock-after-reboot — enforced fail-closed at the service plus
the button condition and the auto-prompt guard.

**Current state (verified).** `FernletLockService` is `@MainActor @Observable`, created once per process
as `@State private var lockService = FernletLockService()` (`App/Fernlet/FernletApp.swift:33`), so any
in-memory non-persisted property is inherently process-lifetime and resets on relaunch/termination. No
biometric-gating on process-first-unlock exists today: a cold-launched, still-locked app auto-prompts
Face ID from `FernletLockView.onAppear` (`FernletLockUI/FernletLockView.swift:538-548`, `:542` guard) and
shows the biometric button whenever `biometricEnabled && biometricType != .none`
(`FernletLockView.swift:530`). `unlockWithBiometrics` (`FernletLockService.swift:844-888`) reads
`.biometricBypass` and installs the content key without touching the attempt counter. The existing view
catch (`FernletLockView.swift:722`) falls back silently to passcode when a biometric attempt throws.

**Design.** Add one in-memory observable to `FernletLockService`:

```swift
public private(set) var passcodeUnlockedThisProcess = false   // NOT @ObservationIgnored; NOT persisted
```

- Set `true` at the **end** of a successful `unlock(passcode:for:)` and inside
  `configure(credential:grantingScope:)` (initial setup counts as the process's passcode success).
- Set `false` in `reset()` (fresh `notConfigured`).
- Do **not** set it in `unlockWithBiometrics`. (Per the Opus/Phase-7 duress work, a duress unlock must not
  set it either — see the cross-track note in §10.)

Expose a single computed policy so the rule lives in one place and both UI sites reference it:

```swift
var isBiometricUnlockAvailable: Bool {
    biometricEnabled && biometricType != .none && passcodeUnlockedThisProcess
    // Opus/Phase-7 extends this with `&& !isDuressSessionActive`
}
```

Three fail-closed enforcement points:

- **(a) Service guard** — `unlockWithBiometrics(for:)` gains, right after the `requiresReset` guard
  (`FernletLockService.swift:845`):
  `guard passcodeUnlockedThisProcess else { throw FernletLockError.biometricNotAvailable }`.
  Throwing `biometricNotAvailable` makes `FernletLockView` fall back silently to passcode via its existing
  catch (`FernletLockView.swift:722`). This is the load-bearing enforcement — the UI conditions below are
  defense-in-depth, not the guarantee.
- **(b) Button condition** — `FernletLockView.swift:530` gates on `isBiometricUnlockAvailable`.
- **(c) Auto-prompt guard** — `FernletLockView.swift:542-545` adds `passcodeUnlockedThisProcess` /
  `isBiometricUnlockAvailable` to its `guard` list so a cold-launched locked app does not auto-prompt
  Face ID.

**Steps.**
1. Add `passcodeUnlockedThisProcess` (in-memory, default `false`); set it `true` at the end of a
   successful `unlock(passcode:for:)` and in `configure(credential:grantingScope:)`; set `false` in
   `reset()`. Do not persist; do not set in `unlockWithBiometrics`.
2. Add the fail-closed service guard to `unlockWithBiometrics(for:)` after the `requiresReset` guard.
   Expose the single computed `isBiometricUnlockAvailable` and reference it from both UI sites.
3. Gate the biometric button (`:530`) and the `onAppear` auto-prompt guard (`:542-545`) on
   `isBiometricUnlockAvailable` / `passcodeUnlockedThisProcess`.
4. Update the `FernletLock` + `FernletLockUI` DocC landing pages and add the regression tests (below).
   Verify against the **rebased** scoped-unlock API (`unlock(passcode:for:)`,
   `configure(credential:grantingScope:)`).

**Files touched.**
- `FernletKit/Sources/FernletLock/FernletLockService.swift` (the flag + the service guard + the computed
  policy)
- `FernletKit/Sources/FernletLockUI/FernletLockView.swift` (button `:530`, auto-prompt guard `:542-545`)
- `FernletKit/Sources/FernletLock/Documentation.docc/FernletLock.md`,
  `FernletKit/Sources/FernletLockUI/Documentation.docc/FernletLockUI.md` (key-scheme / gate note,
  same commit)
- `Tests/FernletTests/FernletLockServiceTests.swift` (regression tests)

**Tests to add.**
- *Service.* A fresh service after `configure` has `passcodeUnlockedThisProcess == true` (configure
  counts). A service restored from keychain in a new instance — relaunch simulation via
  `LockTestHarness.makeService` with the same `serviceID` — has it `false`. `unlockWithBiometrics(for:)`
  throws `biometricNotAvailable` while `false`; after `unlock(passcode:for:)` succeeds it becomes `true`
  and `unlockWithBiometrics` then succeeds. Use the `biometricBypassLoader` injection
  (`FernletLockServiceTests` `makeService` :549-557).
- *UI policy.* `isBiometricUnlockAvailable` is `false` pre-first-passcode even when
  `biometricEnabled && biometricType != .none`; `true` after a passcode unlock. (The
  `&& !isDuressSessionActive` leg is tested on the Opus track once Phase 7 lands.)

**Risks & honest limits.**
- **Legacy biometric-only installs** (upgraded pre-split, never enter a passcode) will be forced to enter
  the passcode **once per process** before Face ID. That is the intended hardening, not a regression — the
  unlock-screen copy should explain the first-time passcode requirement (owner sub-decision, §10).
- **Biometric side-door coupling (cross-track).** The full "no biometric bypass of a decoy session" story
  needs *both* `passcodeUnlockedThisProcess` (this track) *and* the Opus/Phase-7 `isDuressSessionActive`
  flag in `isBiometricUnlockAvailable`. This track ships the first half and the single-policy computed so
  Phase 7 only adds one conjunct — it must not rebuild the policy inline at the two UI sites.

**Wall / CODEOWNERS / custody-tripwire.** No keychain rows added, no key-custody attributes changed →
`KeyCustodyBoundaryTests` is **unaffected**. No S3-wall or No-Tracking-wall impact (an in-memory flag in a
non-walled module). Same-commit doc obligation: the two DocC landing pages and the load-bearing doc
comment on `unlockWithBiometrics` describe the new gate.

---

## 5. Phase 0 — Deletion-audit gap fix (`RecipeWebImageAttemptMemory`)

**Goal.** Close the one confirmed reverse-direction gap in the wipe contract without letting it ride
silently: a device-local sidecar that the funnel already clears but the doc and test manifest do not
record.

**The confirmed gap (verified).** `RecipeWebImageAttemptMemory.clearAll(defaults: webImageAttemptDefaults)`
is called in `resetAll` (`App/Fernlet/FernletStore.swift:4281`) but appears in **neither**
`Docs/PrivacyWipeCoverage.md` (only `BarcodeServingMemory`, the "Barcode serving memory" row) **nor** the
`PrivacyWipeCoverageTests` `wipeManifest` (only `"BarcodeServingMemory.clearAll"`,
`Tests/FernletTests/PrivacyWipeCoverageTests.swift:64`). It is a device-local `UserDefaults` sidecar
(`RecipeWebImageAttemptMemory.swift:50-52`, the "one automatic web-image attempt per recipe" memory), the
same class of surface as `BarcodeServingMemory` — so it needs a **doc row + a manifest token**, **not** a
keychain-service entry. The `knownKeychainServices` floor (`PrivacyWipeCoverageTests.swift:301-306`) is
unaffected.

**Design / fix (same commit, three edits — no production code change, the wipe call already exists at
`:4281` and is correct).**
1. Add token `"RecipeWebImageAttemptMemory.clearAll"` to `PrivacyWipeCoverageTests.wipeManifest`
   (`:29-…`), next to the `BarcodeServingMemory.clearAll` token (`:64`).
2. Add a row to `PrivacyWipeCoverage.md`'s "Cleared by delete everything" table — Surface: *Recipe
   web-image one-attempt memory*; Where: *UserDefaults*; Wiped by: `RecipeWebImageAttemptMemory.clearAll`.
   **Required**, because `coverageDocExistsWithExceptionsTable` (`:264-271`) asserts every manifest token
   is findable in the doc — the test *is* the same-commit enforcement.
3. Add a behavioral regression test: `RecipeWebImageAttemptMemory.recordAttempt(id, defaults:
   store.webImageAttemptDefaults)`, run `store.deleteAllData(includingHealthKitSamples: false)`, assert
   `!RecipeWebImageAttemptMemory.hasAttempted(id, defaults:)` afterward.

`deleteAllCoversEveryManifestSurface` (`:189-193`) then re-covers the new token automatically.

**Files touched.**
- `Tests/FernletTests/PrivacyWipeCoverageTests.swift` (token; behavioral test)
- `Docs/PrivacyWipeCoverage.md` (the new row)

**Tests to add.** The behavioral survival test above (serialized, real funnel — mirror the existing
`PrivacyWipeMediaKeySurvivalTests` pattern at `:335-361`, but asserting *removal*, not survival).
`deleteAllCoversEveryManifestSurface` and `coverageDocExistsWithExceptionsTable` re-cover the token and
doc row with no new assertion.

**Risks & honest limits.** None material — the funnel already clears the surface; this is a
documentation/manifest reconciliation. The only failure mode is *forgetting the doc row*, which the
doc-sync test blocks by construction.

**Wall / CODEOWNERS / custody-tripwire.** Same-commit obligation: the `PrivacyWipeCoverage.md` row and the
`PrivacyWipeCoverageTests` token move **together** (the doc-sync test enforces it). No keychain surface, so
the `knownKeychainServices` floor is untouched and `KeyCustodyBoundaryTests` is unaffected. No wall impact.

---

## 6. Phase 1 — Deletion-audit verification pass (verify half only)

**Goal.** Turn "how data is deleted" into an *audited* baseline: walk the real wipe funnel against
`PrivacyWipeCoverage.md` and the `wipeManifest`, confirm every documented token resolves to a real call,
and confirm the deliberate-exceptions table is honest. This is the **documentation / verify-against-code
half** of the Phase-1 deletion audit.

**Scope boundary (important).** The **crypto-erasure normalization** — the keyless `rebuildStore()` on
`PrivatePersistenceController`, wiring it into the funnel, and the `purgeEncryptedEntities` /
`PrivateStoreCore.md` honesty-doc redesign — is a **crypto-seam change on the Opus track**
([`Plan-Security-Hardening-OpusTrack-2026-08-10.md`](Plan-Security-Hardening-OpusTrack-2026-08-10.md),
Phase 1). This section produces only the audit result and the doc/test reconciliation.

**Verification method (no production code).** Walk every call in the comment-stripped bodies of
`deleteAllData` (`App/Fernlet/FernletStore.swift:3941-4225`) and `resetAll` (`:4232-4311`) against the
"Cleared by delete everything" table and the `wipeManifest`, in both directions.

**Result of the drafting pass (to be re-run against the rebased tree and signed off):**
- **Every documented token resolves to a real call**, and the deliberate-exceptions table cross-checks
  clean: app-lock keychain `com.fernlet.lock` (survivor — "Losing data must not silently un-lock the app",
  `PrivacyWipeCoverage.md`), shared media content key `com.fernlet.private-media` (shreds-with-the-wall),
  install-binding ID `com.fernlet.device-binding`, HealthKit anchor cursors
  `com.fernlet.healthkit-anchors`, the locked-note buffer key `com.fernlet.narrative-buffer`,
  MilestoneLedger, and the friend photo wall are each present and justified.
- **The one reverse-direction gap** was `RecipeWebImageAttemptMemory.clearAll` (`:4281`) — a funnel call
  with no doc row and no token. **Closed in Phase 0 (§5).** After that lands, the doc and the manifest are
  fully reconciled and the verification pass reports clean.
- All other `resetAll` calls are documented: `resetDiary`;
  `savedRecipeService`/`customItemService`/`coinLedgerService`/`aiRetryQueueService.reset`;
  `proximityTrustVault.apply`; `scrubStressLocalState`; `worryBoxResetHook`; the
  `heartLedger`/`moderationLedger`/`friendStateCache`/`closenessLedger`/`BarcodeServingMemory`/`activities.clearAll`
  sidecars; `guidedRunStateStore`/`cookingRunStateStore.clear`; `clearSensitiveVisibilityResolution`;
  `ageAssurance.clear`.

**Deliverable.** A signed-off statement in `PrivacyWipeCoverage.md` (and the Phase-1 section of the Opus
plan's record) that the wipe doc matches the funnel as of the rebased tree, with the one gap closed. No
new production behavior in this track's half.

**Files touched.**
- `Docs/PrivacyWipeCoverage.md` (audit sign-off / any wording nits found during the walk)
- `Tests/FernletTests/PrivacyWipeCoverageTests.swift` (already carries the Phase-0 token; no further change from
  the verify half)

**Tests.** No new tests beyond the Phase-0 gap-fix trio. The existing
`deleteAllCoversEveryManifestSurface` (`:189-193`), `coverageDocExistsWithExceptionsTable` (`:264-271`),
and the `knownKeychainServices` discovery floor (`:301-306`, `:292`) are the standing enforcement that the
verification pass leans on.

**Risks & honest limits.** The verify half asserts *doc ↔ funnel* correspondence only; it makes **no claim
about crypto-erasure completeness** — that honesty framing (row-delete leaves class-key-protected,
key-bound `-wal`/freelist residue until reused; only key destruction is an instant honest erase) is the
Opus track's redesign to write. Do not let this track's sign-off be read as an erasure guarantee.

**Wall / CODEOWNERS / custody-tripwire.** `PrivacyWipeCoverage.md` is the deletion contract; edits ride
the doc-sync test. No keychain-custody change, so `KeyCustodyBoundaryTests` and the `knownKeychainServices`
floor are untouched. No S3-wall or No-Tracking-wall impact.

---

## 7. Phase 6 — Hardening #6: default-on backup exclusion for `FernletPrivate`

**Goal.** Flip the sealed `FernletPrivate` store to **default-excluded** from iOS/iCloud device backups
via a one-time honest-trade-off prompt for existing installs (fresh installs default excluded), so that
post-#1 the store's only remaining backup exposure — its plaintext metadata columns — is removed by
default. Resolves `Verifiability.md` §6.6. **Sequences after Opus/#1** (Phase 4).

**Current state (verified).** `PrivatePersistenceController` applies `BackupExclusion` at store load from
the pref (`:85-89`) and re-applies it at runtime (`:103-117`) — **no data movement; exclusion is
re-applied every load.** The `FernletPrivate` plaintext columns are `id`/`dayKey`/`tag`/`entryDate`/
`createdAt`/`updatedAt` (`JournalNarrative` :176-188), `id`/`hkExternalUUID`/`dateKey`/dates (Menstrual
:148-168), `id`/`dayKey`/`eventDate`/`healthKitExternalUUID`/dates (Intimacy :199-218), `id`/`createdAt`
(Worry :223-237) — **metadata, never content.** `StoragePreferences.localBackupExcludedFromiOSBackup`
defaults **false** (`FernletFoundation/StoragePreferences.swift:25,:60,:70`) and the tolerant decode
returns false for the absent key (`:91`) — **so a stored-default and a chosen-false are indistinguishable**
(the exact problem to solve). Toggle + copy live in `PrivacyDataSettingsView.swift`: `localBackupCard`
(`:674-693`), copy "When off, your local Fernlet data is excluded from iOS and iCloud device backups."
(`:682`), and the exclude `DestructiveConfirmation` (`:1012-…`). `LocalFernletRepository`
(`LocalPersistence/LocalFernletRepository.swift`) has **no** `isExcludedFromBackup` reference — the local
JSON day blob is never excluded, so the toggle copy **overpromises** for sync-off users.

**Design (a correct fresh-vs-existing gate + an honest one-time prompt; no data movement, no crypto).**
- Add an additive `backupExclusionChoiceMade: Bool = false` to `StoragePreferences`, decoded tolerantly
  (`decodeIfPresent(...) ?? false`, mirroring the pattern at `:90-97`) — the **tri-state** that fixes the
  can't-distinguish-chosen-from-default problem. **Leave the existing bool's meaning and its absent-key
  default (`false`) unchanged** so no existing user silently flips. **Do NOT flip the decode default of
  `localBackupExcludedFromiOSBackup` to `true`.**
- **Fresh installs** get `excluded = true` via a first-run path (a dedicated persisted first-run marker, or
  the absence of the install-binding-ID row `com.fernlet.device-binding` as "prior use" evidence), and set
  `choiceMade = true` so they are never prompted.
- **Existing installs** (marker / prior data present, `choiceMade == false`, currently included) get the
  **one-time prompt** with the honest recovery trade-off (copy matching the current exclude
  `DestructiveConfirmation`); whichever they pick sets `choiceMade = true` and is never shown again. The
  manual toggle (`localBackupCard`) stays as-is for later changes.
- **Fix the copy overpromise:** apply `BackupExclusion.apply` to the `LocalFernletRepository` day-blob file
  URL when the pref is set (`BackupExclusion` already operates on any URL,
  `LocalPersistence/BackupExclusion.swift:35-51`), so "your local Fernlet data is excluded" stays true for
  sync-off users. (Alternative: narrow the copy at `:682` — **recommend applying.**)

**#1 interaction, quantified (why this is Phase 6, after Opus/#1).** Post-#1 an *included* `FernletPrivate`
file is ciphertext-unreadable off-device **even with the passcode** (the SE key never restores to another
device and the scrypt fallback is gone), so its only marginal backup exposure is the plaintext columns
above — which days have journal/period/intimacy/worry entries, their counts, tags, and HealthKit linkage
UUIDs (metadata, never content). Default-on exclusion removes even that at **zero** recovery cost: the
ciphertext already can't be opened off-device, and the escrow-backed types (period; journal + intimacy
after Opus/Phase 3) restore via escrow regardless. That is precisely why #6 sequences after #1 — the flip
becomes trivially justifiable.

**Steps.**
1. Add `backupExclusionChoiceMade` (additive, tolerant-decode `?? false`); do **not** change the existing
   bool's default or decode. Add a first-run marker (or adopt the install-binding-ID-presence heuristic).
2. Fresh path: default `excluded = true` + `choiceMade = true`, no prompt. Existing with
   `choiceMade == false`: show the one-time honest-trade-off prompt; the pick sets `choiceMade = true`.
   Wire at launch, after `StoragePreferencesStore` loads.
3. Apply `BackupExclusion` to the `LocalFernletRepository` day-blob URL when the pref is set (or narrow the
   copy — recommend applying).
4. **Same commit as the default flip:** update `Verifiability.md` §6.6 to "done" and note the post-#1
   justification (an included file leaks only plaintext metadata columns).

**Files touched.**
- `FernletKit/Sources/FernletFoundation/StoragePreferences.swift` (additive `backupExclusionChoiceMade`)
- `App/Fernlet/PrivacyDataSettingsView.swift` (the one-time prompt; `localBackupCard` copy)
- `FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift` (apply `BackupExclusion` to the day
  blob)
- `Tests/FernletTests/StoragePreferencesTests.swift` (tolerant decode / no silent flip)
- `Docs/Verifiability.md` (§6.6 → done)

**Tests to add.**
- *Fresh install.* No prior data → `localBackupExcludedFromiOSBackup` defaults `true`, `choiceMade` `true`,
  no prompt, `BackupExclusion` applied at load.
- *Existing install.* Prior data + `choiceMade == false` → one-time prompt shown once; each pick sets
  `choiceMade == true` and is not shown again.
- *Tolerant decode (no silent flip).* `backupExclusionChoiceMade` absent → `false`; an existing prefs blob
  decodes with its `localBackupExcludedFromiOSBackup` value **unchanged**.
- *Local blob.* With the pref set, `LocalFernletRepository`'s day-blob file carries `isExcludedFromBackup`,
  so the toggle copy is true for sync-off users.

**Risks & honest limits.**
- **The default flip must NOT ride the tolerant-decode default.** Changing the absent-key default of
  `localBackupExcludedFromiOSBackup` from `false` to `true` would silently flip **existing** users to
  excluded — a surprise loss of their sealed-store recovery. The separate `choiceMade` field + first-run
  marker are mandatory; the existing bool's default stays `false`.
- **Fresh-vs-existing detection is fiddly.** `StoragePreferencesStore` only writes on update, so "no blob"
  ≠ fresh. The first-run marker / install-binding-ID-presence heuristic must be chosen deliberately or the
  one-time prompt fires for the wrong cohort (owner call, §10).
- **Ordering honesty.** #6's zero-recovery-cost claim depends on Opus/#1 having landed; if #6 shipped
  first, an included file would still be openable off-device via the scrypt fallback and the flip would
  carry real recovery cost. Do not land #6 ahead of #1.

**Wall / CODEOWNERS / custody-tripwire.** No compiler/DAG wall — a pref + UI change with no crypto, no new
keychain row, and no new outbound endpoint (`KeyCustodyBoundaryTests` and `NoTrackingBoundaryTests`
unaffected). The default flip is a **user-recovery-expectation change** gated after #1; `Verifiability.md`
§6.6 moves to "done" in the **same commit** as the code (`Verifiability.md` is CODEOWNERS-protected, so
expect the review gate on that edit).

---

## 8. Cross-cutting risks (this track)

Only the recurring hazards this track actually touches. The remaining classes from the shared taxonomy —
**restore-before-reupload ordering**, **empty-store clobber**, the **FernletDomainModel / enum
clean-build hazard**, and **bind-before-route ordering** — do **not** arise in any Fable-track item (no
sealed-backup reconcile, no new `CaseIterable` enum case, no key-binding here); they live entirely in
[`Plan-Security-Hardening-OpusTrack-2026-08-10.md`](Plan-Security-Hardening-OpusTrack-2026-08-10.md).

| Hazard | What it is (in this track) | Phase(s) |
|---|---|---|
| **Tolerant-decode on new prefs** | Every new `StoragePreferences` field must be `decodeIfPresent(...) ?? <default>`; and the #6 flip must **not** ride the decode default — `backupExclusionChoiceMade` is added additively and the existing bool's absent-key default stays `false`, or existing users silently flip to excluded. | 6 |
| **App-lock-survives-wipe inversion (documentation-adjacent)** | This track does **not** invert it — but the Phase-1 verification pass must *confirm* the app-lock keychain (`com.fernlet.lock`) remains a documented survivor of `deleteAllData`, since the Opus/Phase-7 duress WIPE is the seam that inverts it on a duress-only path and is checked against this audit. Keep the exception row honest. | 1 (verify), reused by Opus 7 |
| **Nothing-silent principle** | A funnel call absent from the doc/manifest (the gap fix), a one-time prompt that silently flips a default, and an overpromising toggle copy are all silent-state failures. Each Fable item surfaces a legible state: the gap fix makes the wipe contract complete; #6 gates the flip behind an explicit prompt + a `choiceMade` tri-state and makes the copy true; PIN-before-biometrics falls back *visibly* to passcode rather than silently failing Face ID. | 0, 1, 6 |
| **Same-commit doc + test-tripwire coupling** | Doc/manifest changes must move with their test token or CI fails: the gap-fix doc row ↔ `wipeManifest` token (`coverageDocExistsWithExceptionsTable`); #6's `Verifiability.md` §6.6 ↔ the default flip; the PIN DocC pages ↔ the service gate. | 0, 1, 6 |

---

## 9. Testing & verification strategy (this track)

- **Suites to extend.** `FernletLockServiceTests` (PIN-before-biometrics — the process-flag lifecycle and
  the fail-closed `unlockWithBiometrics` guard, using the `biometricBypassLoader` injection at `:549-557`);
  `PrivacyWipeCoverageTests` (the Phase-0 gap token + the behavioral survival test; the standing doc-sync
  and discovery-floor tests re-cover the rest); `StoragePreferencesTests` (#6 tolerant decode and the
  no-silent-flip assertion).
- **Custody-tripwire.** **No Fable item changes key custody** — none add a keychain row or alter an
  accessibility/synchronizable attribute — so `KeyCustodyBoundaryTests` and the `knownKeychainServices`
  floor (`PrivacyWipeCoverageTests.swift:301-306`) are untouched. The tripwire coupling this track carries
  is the **wipe-doc ↔ manifest** and **`Verifiability.md` §6.6** same-commit obligations, not a
  keychain-custody assertion.
- **Clean-build requirement — not triggered by this track.** The FernletDomainModel enum clean-build
  hazard applies to `CaseIterable` additions (Opus/Phase 3's `SealedBackupPayloadType` +2, Phase 7's
  `LockKeychainKey` +6 / `DuressMode`). This track adds a `StoragePreferences` *field*, not an enum case,
  so no non-exhaustive-switch trap arises here; a normal incremental build is sufficient for the Fable
  items (though a clean build at the phase end is still cheap insurance).
- **Swift-Testing vacuous-filter gotcha.** Method-level `-only-testing:` selectors on Swift Testing suites
  can silently match nothing and report success. Scope by **suite**, and confirm the run actually executed
  the intended cases (check counts / the "TEST EXECUTE SUCCEEDED" banner), not a naïve grep of the log.
- **Wall / doc-coverage gates before merge.** `Tests/FernletTests/NoTrackingBoundaryTests` (confirm green — no
  Fable item adds an outbound destination or an SPM dependency); `Tests/FernletTests/S3BoundaryTests` (unaffected
  — no import crosses the AI/sync wall); the doc-coverage baseline (`Scripts/doc-coverage-scan.py`) for the
  touched DocC pages (`FernletLock.md`, `FernletLockUI.md`) and the load-bearing doc comments. No
  `Scripts/spm-wall-*.sh` run is required by this track (no `Package.swift` DAG change).
- **Cadence & shared-worktree discipline.** Targeted per-suite during increments; the lock suite is the
  slow one (~10 min) — batch it at phase ends. Several sessions may share this tree and DerivedData:
  pathspec-commit only your hunks, verify in an isolated worktree, and never attribute another session's
  flake to this diff.

---

## 10. Open owner sub-decisions (residual calls, not blockers)

Deduped from the drafting passes; each is a crisp question with a recommendation. None blocks starting the
build order.

**PIN-before-biometrics (Phase 0)**
- **Legacy biometric-only install UX.** Installs upgraded pre-split that never entered a passcode will be
  forced to enter it once per process before Face ID. This is the intended hardening — **confirm the
  unlock-screen copy explains the first-time passcode requirement.**
- **Should a duress unlock count toward `passcodeUnlockedThisProcess`? (cross-track coupling.)** The flag
  is built here, but the duress feature is Opus/Phase 7. **Recommend NO** — a duress unlock must not set
  it, so biometrics stay suppressed and the real content key stays unreachable during a duress session.
  Assumed throughout; the Opus file must honor it when it adds `!isDuressSessionActive` to
  `isBiometricUnlockAvailable`.

**Deletion audit (Phase 0 / 1)**
- **Where the `LocalFernletRepository` exclusion fix lands.** It keeps the #6 toggle copy honest, so it is
  scoped into #6 here (§7). The alternative is to land it as a Phase-0/1 hygiene item. Either is fine, but
  the copy at `PrivacyDataSettingsView.swift:682` should **not** stay overpromised past whichever phase
  ships first. **Recommend keeping it in #6.**

**Backup exclusion (Phase 6)**
- **Fresh-vs-existing detection mechanism.** A dedicated persisted first-run marker vs treating the
  presence of the install-binding-ID (`com.fernlet.device-binding`) / any day rows as "prior use". Pick
  one — it decides which cohort sees the one-time prompt. **Recommend a dedicated first-run marker** (the
  install-binding row is minted lazily and would misclassify some genuinely-fresh installs).

---

**Related documents.**
- [`Plan-Security-Hardening-OpusTrack-2026-08-10.md`](Plan-Security-Hardening-OpusTrack-2026-08-10.md) —
  the sibling crypto-critical track (Phase-0 rebase, crypto-erasure redesign, #4/#3/#1 escrow + SE +
  media, journal/intimacy coverage, duress PIN). The fixed global phase order spans both files.
- [`Verifiability.md`](Verifiability.md) — the §6 owner-decision list; this track closes §6.6, and the two
  new asks (PIN-before-biometrics, deletion-audit verify) get their own rows in §4/§5.
- [`PrivacyWipeCoverage.md`](PrivacyWipeCoverage.md) — the deletion contract; the Phase-0 gap fix and the
  Phase-1 verification pass edit it in the same commit as their test-manifest changes.
- [`No-Tracking-Wall.md`](No-Tracking-Wall.md) — confirm every Fable phase stays inside the egress
  allowlist (none add an outbound destination).

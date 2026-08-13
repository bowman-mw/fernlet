# Security-Hardening Build Runbook (2026-08-10)

Execution controller for the two-track security-hardening plan. A `/loop` run reads this file
each iteration, executes **one eligible phase** end to end (implement → adversarial review → fix →
verify green → commit → merge), updates the ledger below, and either advances or stops.

- Plans (source of truth for each phase's design/steps/tests):
  [`Plan-Security-Hardening-OpusTrack-2026-08-10.md`](Plan-Security-Hardening-OpusTrack-2026-08-10.md)
  and [`Plan-Security-Hardening-FableTrack-2026-08-10.md`](Plan-Security-Hardening-FableTrack-2026-08-10.md).
  **P8 is the exception:** its spec is [`Design-Capture-Protection-2026-08-10.md`](Design-Capture-Protection-2026-08-10.md).
- The **fixed global phase order** governs execution across both tracks; never reorder it.

### P8 is queued here, not ranked here

P8 (capture protection) was added to this ledger on 2026-08-10 at the owner's request so the loop
builds it too. It is **a different class of work** from P0–P7 and the distinction must survive:
P0–P7 move key custody, at-rest formats, and deletion semantics — mechanical guarantees with
tripwire tests behind them. P8 draws rectangles over views. It is *friction* against casual
self-sharing, never a security control, and it must never be described to users in the same register
(see the brief's §1 and [`Verifiability.md`](Verifiability.md) §5). **This ledger is an execution
queue, not a strength ranking.** P8 has no dependencies — it is last because it is lowest priority,
not because anything blocks it.

## Phase ledger

Status ∈ `TODO` / `IN_PROGRESS` / `DONE` / `BLOCKED`. The loop updates the row it works, recording
the merge commit on `DONE` or the reason on `BLOCKED`.

| # | Phase | Track / model | Depends on | Merge policy | Status | Commit / note |
|---|-------|---------------|-----------|--------------|--------|---------------|
| P0a | Rebase & land `claude/scoped-unlock-per-screen` onto main | Opus | — | auto after green | DONE | 801a3e4 |
| P0b | PIN-before-biometrics | Fable | P0a | auto | DONE | f5c1f13 |
| P0c | `RecipeWebImageAttemptMemory` wipe-coverage gap fix | Fable | — | auto | DONE | 2759af9 |
| P1a | Crypto-erasure normalization | Opus | P0a | auto | DONE | aaa4aac |
| P1b | Deletion-audit verification pass | Fable | — | auto | DONE | 500cf5d |
| P2 | Hardening #4 — v2 per-generation-salt escrow format | Opus | P1a | auto | DONE | 2faf53e — owner deployed formatVersion/keySalt to the production CloudKit schema 2026-08-11 ✔ |
| P3 | Backup coverage — Journal + Intimacy | Opus | P2 | auto | DONE | 4ed7437 |
| P4 | Hardening #1 — hard SE-binding (deletes scrypt fallback) | Opus | P3 | **OWNER GO/NO-GO** | DONE | 9f9af1b — owner GO 2026-08-11 ("no real users yet"); §14 residuals accepted (SE wraps the RAW key; current disclosure copy). CI Apple-silicon pinning declined as N/A (solo dev, M5-only). |
| P5 | Hardening #3 — media split + escrow photo route + bind | Opus | P0a | auto | DONE | 9388aec — OWNER ACTION: promote `SealedPhotoRecord` (queryable) to the Production CloudKit schema before shipping with the photo-backup toggle reachable (Docs/CloudKit-Schema-Deploy.md). Follow-up surfaced (§14, defaulted OUT): seal the plaintext friend-wall index `MeshPhotoCache.json`. |
| P6 | Hardening #6 — default-on backup exclusion | Fable | P4 | auto | DONE | 4a853d4 |
| P7 | Duress PIN — decoy, silent-wipe, recovery-lock | Opus | P0a, P1a, P4 | auto | DONE | d43bbce |
| P8 | Capture protection — Tiers 1+2 on the Private tab | Fable | — | auto | DONE | 2e6cadb — six agreed surfaces only; follow-ups surfaced, NOT built: §9#1 lookingBackCard (lean: modifier on the card), §9#6 First Aid worry composer (lean: protect `WorryEntryView` where hosted), §9#5 progress-photo `redactForSnapshot` consolidation. Manual device matrix (spec §7) still owed before ship. Spec is [`Design-Capture-Protection-2026-08-10.md`](Design-Capture-Protection-2026-08-10.md) — see §"P8 is queued here, not ranked here" below |

## Per-iteration protocol

1. **Select.** Read the ledger. Pick the first row (top-down) that is not `DONE`/`BLOCKED` and whose
   `Depends on` phases are all `DONE`. If none is eligible but incomplete rows remain, stop and
   report the dependency stall. If all rows are `DONE`, **stop the loop** — the build is complete.
2. **Guard the go/no-go.** If the selected phase's merge policy is `OWNER GO/NO-GO`, and the owner
   has not recorded approval for it in the ledger note, do the implement+review+verify+commit work
   **on the feature branch only**, then set the row `BLOCKED` with note `awaiting owner go/no-go —
   branch <name> is green+reviewed`, and stop the loop. Merge on a later invocation once approved.
3. **Branch.** From current `main`: `git checkout -b claude/harden-<phaseid>`.
4. **Implement (Workflow).** Read the phase's section in its track doc (for **P8**, the whole
   capture-protection brief); implement its ordered steps exactly. Pass `model: 'opus'` to
   implementer agents for **Opus-track** phases; default model for **Fable-track** phases. Honor
   every same-commit obligation the section names (wall doc, DocC page, custody-tripwire test,
   `PrivacyWipeCoverage.md` row). Every new type/member gets a `///` doc comment. New files just drop
   into their synced folder — no pbxproj surgery.
   - **P8 only:** run the brief's §9 "two empirical checks" FIRST (does the `.background` lock already
     paint before the OS snapshot; does `app.screenshot()` post the notification) — both change how
     much machinery is warranted. Follow the brief's documented **leans** for its open sub-decisions
     rather than stopping, EXCEPT the two scope calls (`lookingBackCard`, the First Aid worry
     composer): if the owner has not recorded a decision on those in this ledger's note column, build
     the six agreed Private-tab surfaces only and surface the two as a follow-up. Do not silently
     widen scope onto the Home tab.
5. **Review (Workflow).** Multi-dimension adversarial review of the branch diff `main..HEAD`
   (dimensions per phase: crypto/key-custody, data-loss/migration-reversibility, S3 + no-tracking
   walls, silent regressions). Dedup → verify each finding refute-by-default (`effort: 'high'`,
   `model: 'opus'` for Opus-track phases) → fix every CONFIRMED finding, add a regression test where
   the seam allows.
6. **Verify green.** CLEAN build first (`FernletDomainModel` structs change most phases). Then, at
   **suite** level (method-level `-only-testing:` is vacuous here — confirm real `Test case` lines):
   the phase's owning suites **plus** the standing tripwires `NoTrackingBoundaryTests`,
   `S3BoundaryTests`, `KeyCustodyBoundaryTests`, `SealedBackupFormatPinTests`,
   `ColumnCryptoDeviceBindingTests`, and `Scripts/spm-wall-check.sh` + `Scripts/doc-coverage-scan.py`.
   Known pre-existing red (leave it unless the owner's chip has fixed it):
   `CoreDataStagedBlobLoadTests/asyncLoadRefusesToOverwriteACorruptRecord` (reproduces on `main`).
7. **Commit + merge.** Commit on the feature branch (message body explains the why; end
   `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`). If merge policy is `auto`, `git merge
   --no-ff` to `main`. **Never `git push`** — origin is the owner's call.
8. **Record.** Set the ledger row `DONE` with the merge commit hash (or `BLOCKED`/go-no-go per step 2),
   commit the runbook update, then schedule the next iteration.

## Stop-and-surface conditions (end the loop, report to the owner)

- A phase needs a decision the plans did not resolve (a section's "Open owner sub-decisions" item
  that blocks a step, not merely a nice-to-have).
- A red test is **caused by this phase** and cannot be fixed within the iteration.
- A merge/rebase conflict needs human judgment (expected at P0a against the `d68ca9a` SE-wrap seams).
- The `OWNER GO/NO-GO` guard on **P4** (deleting the scrypt fallback is irreversible — once gone,
  any gap in P2/P3 backup coverage means permanent data loss; the owner confirms P3 coverage is
  actually live before this merges).
- An adversarial review surfaces a CONFIRMED critical that the fix pass could not close.

The decisions already locked on 2026-08-10 (intimacy joins the backup; duress may destroy the lock
key; Worry Box stays out) are **not** re-confirmation points — they are settled; proceed.

## Progress log

_(the loop appends one line per completed phase: `Pxx DONE <hash> — <one line>`)_

- P8 DONE 2e6cadb — capture protection Tiers 1+2 on the six agreed Private-tab surfaces (hub root inner to the lock gate + five sheet types at their body). §9#10 empirical checks ran FIRST: the .background lock wins the snapshot race for the hub (simulator-proven) but a backgrounded JournalSheet leaks the live composer into the switcher snapshot → the scenePhase cover ships at all six; app.screenshot() does NOT post the screenshot notification (positive-controlled) → the appearance gallery is safe from the pulse. Leans honored: always-on, no toggle, once-per-session nudge, automatic on Home-presented sheets, FernletUI home. Review: 10 findings → 7 CONFIRMED (occluded-nudge trio, keyboard/QuickType under the cover, VoiceOver announcement, pre-resolution cover, doc wording) — all fixed. Verify gate: clean build, 284 unit + 31 UI executions 0 failed, ScreenAppearanceUITests 25/25 non-blank, wall + doc coverage clean. OWED: the spec §7 manual device matrix before ship; follow-ups per the ledger note. ALL LEDGER ROWS NOW DONE — the hardening build is complete.
- P7 DONE d43bbce — duress PIN complete: one PIN/one mode, duress-before-guards ordering, own-salt + unconditional dummy derivation (constant 2-scrypt shape incl. on the duress branch), audit-indistinguishable; DECOY keyless via the in-memory store flag riding the hide machinery (persists nothing, biometrics suppressed at the fail-closed guard); SILENT WIPE sub-second key destruction (SE key, biometric bypass, private-media keys) + throwaway re-mint + purge hook into the delete funnel (duress-only seam, normal funnel still keeps the lock); RECOVERY-LOCK with blob-verified trigger, owner-KA identity binding, identityRotatedHook reconcile on delete-all, in-person QR recovery only (FernletLock gained no ProximityKit edge). Review: 30 findings → 13 CONFIRMED (5 critical: duress-session could open the duress-management surfaces; progress-photo scope revealed real photos; lockout entry inert; delete-all stranded the armed recovery blob) — all fixed, 8 new hardening suites. Verify gate: clean build, 340/340 (117 duress + 121 lock + 102 tripwire/funnel), wall check + negative selftest, doc coverage 0.
- P6 DONE 4a853d4 — default-on backup exclusion: fresh installs excluded silently (choiceMade latched), existing installs get the one-time honest prompt; tri-state pref additive with tolerant decode (existing bool's default untouched — the flip never rides the decode default); dedicated device-local prior-use marker that survives delete-all; local JSON day blob honors the pref (overpromise closed). Review: 12 findings → 4 CONFIRMED, all fixed (live-blob classification with fail-closed unreadable-keychain deferral + foreground retry; keychain-blob presence as the reinstall prior-use signal so a surviving "included" blob is never silently flipped; honest §6.6/module docs; PrivacyWipeCoverage row + doc-sync test for the wipe-surviving marker). Verify gate: clean build, 8 owning + 5 tripwire suites 0 failed, wall check + doc coverage clean.
- P5 DONE 9388aec — media-key split (friend row unchanged, new own-photos row), eager crash-safe re-seal migration behind a fail-closed latch, opt-in per-photo escrow route (v3 AAD on the v2 salted key, manifest-last commit marker, CKAsset bodies), and SecItemUpdate device-binding gated on latch AND committed-upload-or-consent. Adversarial review: 27 findings → 13 CONFIRMED (2 critical: latch could close over unreadable files; enable reported success with nothing committed) → all fixed with regression tests, incl. the seeded restore-skip gap (no-clobber gate now asks holdsOnlyUnopenableFiles()). Privacy policy ×3 + nutrition labels corrected for the opt-in upload. Verify gate: clean build, 579 tests / 0 failed across 22 suites + tripwires, wall check + doc coverage clean. OWNER ACTION: SealedPhotoRecord Production schema promotion pending.
- P4 DONE 9f9af1b — owner GO recorded 2026-08-11 (no real users yet; residuals accepted); merged the parked green branch unchanged. Owner also completed the P2 production CloudKit schema deploy and declined CI Apple-silicon pinning as N/A (solo dev, M5-only workstation).
- P4 was BLOCKED (branch claude/harden-p4 @ ab32363, NOT merged) — hard SE-binding built + reviewed + verified green (218 tests, SE branches proven live); review confirmed 10 findings, all fixed: reachable non-destructive reset card, terminal-vs-transient error split (contentKeyTemporarilyUnavailable), fail-closed custody detection (loadDistinguishingAbsence + .undeterminable), non-hub scopes tolerate a dead enclave key, biometric self-heal reachable (passcodeVerifiedThisProcess), no-overwrite wrap repair, honest disclosure copy + migration notice, doc reconciliation. Loop stopped here per the go/no-go gate; owner records the decision in this row's note, then re-runs /loop.
- P3 DONE 4ed7437 — journal + intimacy sealed-backup payloads on v2 (insert-into-empty + one-way latches, gated intimacy seam, journal self-sufficiency); seam audit FAILED first (enable-path clobber critical) then review confirmed 11 findings, all fixed (per-payload locked-enable deferrals, exportability-proving guards, targeted restores + unlock/un-hide settles, pinned freshness, keepSealedBackupFlags coverage); 315-test verify green. Intimacy-in-backup reversal recorded in the spec.
- P2 DONE 2faf53e — v2 per-generation-salt escrow format; v1 KAT byte-identical (independently recomputed); fail-closed decode + mixed-set rejection; all new writes v2; review confirmed the downgrade-stranding hazard (fixed: v1 fallback in open(), stale-salt-ignoring decode, explicit field clear); verify green. OWNER ACTION: production CloudKit schema deploy before ship.
- P1b DONE 500cf5d — bidirectional funnel audit signed off; THREE token gaps closed (generationStore.reset, healthKitSampleDeleteHook, + the reverse-direction doc-sync check that makes documented-but-unenforced rows visible); parser hardened; .serialized comments honest; verify green.
- P1a DONE aaa4aac — keyless Option-B rebuild in both delete legs; honesty docs (bounded-honest vs fully-honest); review confirmed 5 (all fixed: reset() sweeps sealed device keys so "crypto-erased" is true; structurally no-storeless rebuild + saveSealed() conversion; one _SUPPORT spelling); 274-test verify green. Owner's P8 brief (c6b4977) + runbook queue commit (fcc7a73) landed alongside.
- P0c DONE 2759af9 — RecipeWebImageAttemptMemory manifest token + doc row + behavioral removal test; review fixed the verify-batch selector gap; two advisories carried to P1b (SealedBackupGenerationStore.reset has a doc row but no manifest token — doc-sync test checks manifest→doc only; `.serialized` is inert cross-suite on the live-wipe suites); verify green.
- P0b DONE f5c1f13 — PIN-before-biometrics fail-closed at the service guard + single isBiometricUnlockAvailable policy at both UI sites; review confirmed 3 test-strength findings (fixed: loader-consult ordering pin + test-only biometricTypeOverride seam); refuted 1 (unlock-screen copy = open owner sub-decision §10); verify green.
- P0a DONE 801a3e4 — scoped-unlock landed over the d68ca9a SE seams as the documented union; seam audit pass; 12 review findings all refuted (pre-existing/original-branch design, several noted for P1a/P1b); verify green (clean build, 424 cases across owning suites + tripwires, wall check, doc coverage 0). Gotcha: `-only-testing:Tests/FernletTests/WorryBoxTests` is vacuous — the file declares suites `WorryBoxRepositoryTests` + `WorryBoxServiceTests`; use those names.

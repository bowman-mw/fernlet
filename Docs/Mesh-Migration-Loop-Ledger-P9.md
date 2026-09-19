# Mesh Migration Loop Ledger — P9

**Phase:** P9 (the remaining radios, MC retirement), with P8's device gate still open · **Prompt:** [Next-Round-Prompt-Mesh-P9-2026-09-19.md](Next-Round-Prompt-Mesh-P9-2026-09-19.md)
**Started:** 2026-09-19 · **Iteration:** 1 (closed 2026-09-19) · **Tree at seed:** `main` = the P8 close-out (`bb454fe`); P8 BUILT at tier 1/1b, §15 NOT RUN; the P7 lane fix `80934b7` is on `main` (HEAD~1 at seed)

**Environment of this session:** a Mac with Xcode 26 and the iOS 26.5 SDK, working in the worktree `.claude/worktrees/wizardly-haslett-ddce10` on branch `claude/loving-bell-296321` (its own DerivedData); `main` is fast-forwarded from it in the primary checkout after each iteration. The primary holds `App/Fernlet/Localizable.xcstrings`, `xcuserdata/**`, the plan and several `Docs/*.md` uncommitted — every commit is by explicit pathspec, plan edits land as index-only blobs. **Devices:** exactly ONE physical device connected (`iPhone 17 Pro Max`, iOS 26.6.1, `xcrun devicectl` state `connected`); the owner is not at the keyboard. Item 0's rows need two to four phones in the owner's hands (lock, Control Centre, walks, 3 h / 6 h soaks), so they are `blocked (owner)` — P9 is NOT gated by them.

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | P8's device lanes (§15.1–§15.4, device plan A–F) + the two owed re-runs; the ladder decided | 3 | — | blocked (owner) | — | one device connected, two to four needed plus the owner's hands. **Device-free half DONE 2026-09-19:** this ledger, item 1 (`dad86e9`) and its tier-1 walls. **Still owed and device-free:** a Lane C run at HEAD that DISCOVERS (confirms `80934b7` before any tier-2 row of items 2/3 is believed) — run it to open item 2's pass 2 |
| 1 | The `assertionFailure`-in-`catch` family | 1 | — | done | `dad86e9` | 40 traps enumerated (not 19): **27 environmental sites FIXED** (26 through the new `PersistenceFailureAudit.record` in `FernletFoundation`, token + `NSError` domain/code only; DiaryStore's existing token kept, its day-key context dropped), **12 programmer-error guards LEFT**, 1 DEBUG demo-seed site reverted after the verify doubted its class; 27 cells one-to-one in `PersistenceFailureAuditTests`. Verify → **FIX FIRST**, 5 fixes + 2 notes applied: **a failed recipe payload encode left the previous `payloadData` on the record and the read path served the pre-edit recipe back — a silent edit revert the removed assert was the only signal for** (would have shipped; the catch now clears the blob); purge cells were clearing `UserDefaults.standard`; two docs claimed a rollback the encode path does not do; the day key in an audit; a duplicate import. Gates: scans 0 / 0, build green, **392 tests / 26 suites green**, no restart, `spm-wall-check` PASSED; three red-onces kept (`…/scratchpad/item1/redonce-RED.log`, `…/item1-fix/test-pfa-RED.log`). No full-suite run |
| 2 | Presence over QUIC — posture first | 1 + 2 | — | todo | | two passes; pass 2 opens with the Lane C confirmation run |
| 3 | Recipe share over QUIC — pause/resume preserved | 1 + 2 | 2 | todo | | two passes |
| 4 | Retire MultipeerConnectivity (2 files, 6 or 8 plist strings, the wipe row, the permit list) | 1 | 2, 3 | todo | | one commit; the coach pair is §18 decision 4 |
| 5 | The 1:1 foreground anchors — widget or retire | 1 | — | todo | | default: retire |
| 6 | Gate the fourteen (247 cells / 11 s) | 1 | — | todo | | floor re-measured |
| 7 | The six process-global drain counts + `parkedReoffered` | 1 | — | todo | | D-6a.10 shape |
| 8 | The two accessibility-ratchet baselines | 1b | — | todo | | fresh Simulator; **needs no device** |
| 9 | P9 acceptance battery + CI lines | 1 | 2–4 | todo | | pin and floor measured (48 / 469 at the P8 boundary) |
| 10 | Close-out: §17.1 BUILT, §15 updated, the P10 handoff, the next launcher, memory | 1 | 0–9 | todo | | draft → verify → apply |

## Blocked on owner
- **Devices for item 0** — two minimum (rows A–E, F1–F6, F9, F11, F12), three for E3 / F8, four for F7. The runbook's Lane B table (`Docs/Mesh-Network-Feasibility-Runbook.md` § "Lane B", line ~1939) is the evidence table; the device plan's Results table (`Docs/Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md` § Results) takes A–E. **Every row below is NOT RUN as of 2026-09-19:**
  - Device plan **A1–A8, B1–B4, C1–C2, D1–D5, E1–E4, E7** (E5, E6 are tier-1-only by design).
  - **F1–F12** (plan §15.1–§15.4; F10 is the owner's call; F11 = Lane D phone ↔ Simulator, cable out, the cheapest first run).
  - The **tier-3 rows P8 item 6 named**: registration accepted; a `.fail` submission **granted** (no grant observed anywhere); the launch and expiration handlers firing on the real `SystemContinuationScheduler` conformer; the tunnel surviving the whole task; slow progress across the 3 h / 6 h soaks; no proximity Live Activity present; the Control-Centre peek re-submission (F12).
  - The **re-run of P8 item 0's four founding fixes (a)–(d)** on the fixed build, with the **three eyeballs**: Friends tab entry/exit (observed incidentally on Simulators only), Control Centre over the Friends tab, delete-all during a live session.
  - **§15.3 decides the degraded ladder** — unchosen until the soak runs; plan §14's scope unchanged.
- **The drawer is now safe to open in DEBUG**: item 1 removed every environmental trap a lock or background row could fire (`dad86e9`).
- Carried from plan §26.4 (read it; do not re-list it here).

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| The first iteration | item 0's device-free half (this ledger, item 1, its tier-1 walls); item 0's device rows `blocked (owner)` | 2026-09-19 |
| Item 1's scope | **the whole family** — every `assertionFailure` inside a `catch` (or a `guard let … try? … else { assertionFailure }`) that fires on an environmental Core Data / file I/O / encode failure, in every module: the acceptance is per site, any one of them crashes a DEBUG lock row. Programmer-error asserts stay (12, each justified in the commit). Owner may narrow. | 2026-09-19 |
| Item 1's demo-seed site (`FernletStore+DemoSeed.swift`) | **reverted to its `assertionFailure`** — `#if DEBUG` demo code that never runs on a locked device, and `seeded == nil` from a bundled image is as likely bad seed data as an I/O failure; no seam for a cell | 2026-09-19 |
| Item 1's `upsert` return after a failed recipe payload encode | **stays `true`** — the fresh legacy columns are durable and a `false` would retry-loop on a non-finite value; the structured half is dropped (`payloadData` cleared), audited (`savedRecipe.payloadEncode.failed`) and documented at `apply`, `upsert` and the landing page | 2026-09-19 |
| Presence posture | (default: reproduce before the framing) | — |
| Recipe share | (default: request/response, pause/resume in pass 1) | — |
| When MC is deleted | (default: same phase, after both radios cross) | — |
| The coach radio (plan §18 decision 4) | (default: hold the two `_fernlet-coach` strings; drop the other six) | — |
| The 1:1 anchors | (default: retire) | — |
| Gate the fourteen | (default: yes) | — |
| New persisted surface | (default: none) — item 1 added none | — |
| The degraded ladder | (decided by §15.3 in item 0) | — |

## Surprises worth not re-deriving
- **The assert family was 40 traps, not 19.** The plan's 19 counted the literal `catch` shape; eight siblings were `guard let x = try? … else { assertionFailure }` on the same environmental failures (a store fetch, a payload encode of a non-finite `Double`). Enumerate by failure class, not by syntax.
- **Removing an `assertionFailure` can remove the only signal for a silent data revert.** `SavedRecipe.apply`'s encode `catch` left the previous `payloadData` on the record; the read path prefers the blob whenever the legacy projection has not diverged, so an edit to a structured-only field vanished on the next load. Every converted `catch` must leave the row in the state the *read path* expects, not merely "not trap".
- **A controller whose store never loaded is NOT a throwing rig**: zero stores → empty fetch, no-op save, nothing throws (and an insert crashed the runner). To make saves throw, re-attach the SAME store with `NSReadOnlyPersistentStoreOption`; to make fetches throw, overwrite the database file (and WAL) under the open connection — SQLite re-reads page 1 per read transaction.
- **A test that builds `LocalFernletRepository` without `legacyDefaults:` purges `UserDefaults.standard`** when it drives `purgeAllPersistedData()` — the seam's own doc comment names the hazard; pass `isolatedDefaults()` and `backupExclusionPreference: { false }` on every construction.
- **`power-of-10-scan.py`'s assertion-density floor counts `assertionFailure` as a check**: 27 removals moved 0.775 → 0.770 against a 0.68 floor. A future sweep of this shape moves it further.
- **A continued-processing task is delivered while the app is still in the foreground.** Any state meaning "we are continuing in the background" keys on (task in hand ∧ scene dark).
- **Gating cost is not proportional to cell count**: +92 % cells cost +10 % wall time on a tier-1 step. Price a gate before deferring it.
- **A hold is not a stop**: every clock that assumes browsing must pause with the radios — grep every `arm…Clock` when adding a pause-shaped verb.
- **A terminal state erases its cause unless a projection rule keeps it**; and **a reset that clears state without walking the table strands every side effect the table owed**.
- **`hasSlot(for:)` means ANY slot** — read the body of every predicate a new door consults; a **re-entry row keys on facts, not on `previous`**.
- **A protocol requirement declared in an app file is a second occurrence of a grep-wall's needle**; **a grep for `@Suite` under-counts the suites** (some are plain structs found by their `@Test`s).
- **A background build's notified exit code is the last command's**; **a Simulator that has run ~3 h stops rendering** — erase and reboot before believing a UI red.
- **Every P8 adversarial verify found something real.** Seven for seven; five would have shipped. **P9 item 1's did too** (the stale blob).
- **Every P6 and P7 lesson still binds**: a log with `Restarting after unexpected exit` has no usable total; never chain a build and a run on one DerivedData; `-only-testing:` names the SUITE; `@Test(arguments: [])` is green over nothing; a process-global audit signal cannot witness a per-cell claim; `.inactive` is foreground for the radios; `FernletLockState` carries associated values; the chat age gate is `AgeGate.chat`; zsh passes an unquoted `$ARGS` as one argument.
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family, the crypto-purpose / `PayloadType` / record-kind spellings, plan §10.7–§10.10, §11.1–§11.4, §12.1–§12.4, §13.1–§13.4 and §14.1–§14.4; `Docs/Proximity-Security-Followups-2026-08-18.md` §1. Concurrent sessions share the tree; never stage the catalog working copy, `xcuserdata`, or the stray PDF.
- **A worktree has its own DerivedData** (the path hash differs from the primary's): the first build there is cold (~20 min here), and "one `xcodebuild` at a time" is a CPU rule as much as a DerivedData rule — `pgrep -x xcodebuild` still gates every start.

## Next item
**2** — Presence over QUIC, posture first. Pass 1 is tier 1 (the rotation table). **Before pass 2's tier-2 row: the Lane C confirmation run** (sim↔sim, `STAGGER=1`, fresh log dir; a `[mesh-quic]` banner and `proximity.transport.quic` records at HEAD prove `80934b7` repaired the lane). Item 8 needs no device and may be taken whenever the build slot is free. Item 0's device rows stay `blocked (owner)` until two phones are in hand.

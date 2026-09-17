# Loop Prompt — ProximityKit Network Migration: P8 (background continuation)

**Written:** 2026-09-17, at the P7 boundary (branch `claude/hopeful-edison-rl5hb3`, last shipping commit `a528760`; the phase landed on `82fc4d7` = `main` = `origin/main` = the P6 push). **Nothing in P7 was compiled or executed — item 0 below is the gauntlet debt, and it blocks everything.**
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. **§14 is the P8 specification; §15 is the entry criteria; §25 is the handoff; §13.3's findings 1–5 are the named obligations.** This file is the launcher and the loop contract.
**Ledger:** `Docs/Mesh-Migration-Loop-Ledger-P8.md` — the loop's memory, created on iteration 1 (§7). It lives on disk, not in context. The P7 ledger is a finished record; **do not reuse it.**
**Scope:** build **P8** — the app-target `MeshContinuationCoordinator`, the `BGContinuedProcessingTask` lifecycle it owns, the one setter that feeds its state into the run policy P7 built, the `.backgrounded` / `.foregrounded` raises that make `.continuingInBackground` real, and the ProximityKit primitive that lets a continued mesh **stop searching and keep its committed links**. **Stop the loop at the P8 boundary.**

**P8 is not mostly wiring.** P7 was; this is not. §15's gates are background, lock, radio physics,
battery, thermal and OS policy, and a Simulator answers none of them — `BGTaskScheduler` returns
error 1 there. **P8 is a tier-3 phase with a tier-1
skirt.** Build the coordinator and the seams at tier 1 against an injected task state, then stop and
wait for the phone drawer. Do not simulate your way to a claim this phase cannot make.

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P8-2026-09-17.md and run one iteration of it.
```

Self-paced (no interval): the work is build-and-test-bound, not clock-bound, so the loop wakes when
work completes, not on a timer. A session that is not a `/loop` runs the same iterations back to
back; the ledger is the state either way.

---

## 0. Orchestrator contract — read this first, it is the binding constraint

**The orchestrator is a limited model budget.** That is the scarcest resource in this project, scarcer
than build minutes or sim time. Every rule below exists to protect it.

### The orchestrator does not do the work. It decides what work happens next.

| Orchestrator DOES | Orchestrator DELEGATES |
|---|---|
| Read the ledger (one short file) | Reading any source file |
| Pick the next unblocked item | Writing or editing any file |
| Dispatch one subagent | Multi-file surveys, refactors, test authoring |
| Read the subagent's summary | Anything that would pull >100 lines into context |
| Grep one marker line out of a build log | Diagnosing a build failure |
| Update the ledger | — |
| Schedule the next wake | — |

Delegate with `Agent(..., model: "opus")`. **Each item is three dispatches, never one:** understand +
design + implement (one agent, the ledger's decisions as input), then an **adversarial verify** of
the diff by a second agent that has not seen the first's reasoning (it reads the item's acceptance
criterion, the walls in §4 and the diff, and answers "what would make this green for the wrong
reason"), then a fix agent for what survives. When the owner has enabled ultracode, the same three
steps run as one small Workflow — but a Workflow is the owner's opt-in, never the orchestrator's
default. If Opus 529s at spawn, ask the owner whether Opus is down rather than burning retries.

### Hard token rules for the orchestrator

1. **Never `cat` a source file.** Use `sed -n '120,180p'` or a targeted `grep -n`. If you need more
   than ~60 lines of a file, that is a subagent's job.
2. **Never let build or test output reach context.** Always:
   ```bash
   xcodebuild … > "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG"
   grep -E "EXIT=|BUILD (SUCCEEDED|FAILED)|TEST EXECUTE|Test run with" "$LOG"
   ```
   Three lines in, not three thousand.
3. **One work item per iteration.** Finish it, record it, wake again.
4. **Write state to the ledger, not to your own memory.** `/loop` resumes the *same* context and
   never compacts between iterations.
5. **Stop early rather than run out.** See §6.
6. **When a close-out step needs synthesis across many verified facts, use draft → adversarial
   two-lens verify → apply**, with drafts written to scratch files first. P4's close-out caught 51
   real corrections that way; P6's draft agent found the owed catalog list was two keys wrong; **P7's
   draft agent found the phase had never been compiled and wrote the gauntlet debt into §13.3 rather
   than letting "done" stand alone.**
7. **A row that lands in two passes needs its gate to assert the later pass RAN** (§23.5). P8's
   item 2 (the coordinator, then the feed) and item 5 (the primitive, then its use) are two-pass by
   shape.
8. **This phase cannot be finished on this Mac, and the orchestrator must say so out loud rather
   than degrade.** §15's gates need 2–4 physical devices and multi-hour soaks. When the tier-1 skirt
   is done, **stop** — do not invent a simulator claim for a row a simulator cannot answer. The
   entire §7.7/§12.4 discipline of naming what a lane did NOT observe exists for exactly this
   moment.
9. **P7 was never compiled.** Item 0 below is not optional and it is not a formality. Until it is
   green, every red this phase sees is ambiguous between two phases' code.

### If the budget runs out mid-phase

Stop the loop, write the handoff (§6/§8), and say plainly what is left. Do not silently degrade into
doing the work yourself.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P8.md`. On iteration 1, create it from §7's
   template.
2. **Check the tree is safe to build on** — first iteration, or after any owner activity:
   ```bash
   git -C . log --oneline -1; git -C . status --porcelain
   ```
   Another session has long held `App/Fernlet/Localizable.xcstrings` and a personal
   `xcschememanagement.plist`; a stray untracked PDF sits in `Docs/`. **Leave all three alone.**
   Commit with explicit pathspecs, never `git add -A`. If a new surface adds catalog keys, sync the
   catalog from `HEAD`'s blob and stage it as a blob (`f4a69f1`'s method, repeated at P6's and P7's
   close-outs) — never from the held working copy.
3. **Pick the next item** whose prerequisites are met, from §3's list, in ledger order. **Item 0
   first, always.** Prefer a tier-1 item over a tier-2 one, and never start a tier-3 item without the
   owner's devices in hand — see §2.
4. **Dispatch the three agents** with the item's full context: the acceptance criterion, the walls it
   must not trip (§4), the decisions already taken in the ledger, and that the implementer must run
   the gauntlet subset for what it touched (§6).
5. **Verify** — grep the marker line out of its build/test log yourself. This repo has notified a
   failed build as exit 0, a crossed log has shown ~20 phantom failures under concurrent-session
   contention, an interrupted-mid-run log has no markers at all, and a `-only-testing:` line naming a
   non-existent suite prints `TEST EXECUTE SUCCEEDED` over zero tests. Check `Test run with N tests`
   is non-zero and count `◇ Suite` starts against `✔ Suite` passes.
6. **Commit** with explicit pathspecs.
7. **Update the ledger**: item → done, with the SHA, one line on anything surprising, the next
   unblocked item, and any new sub-item the work exposed. **Use the `Verified` column** (§7) — P7's
   ledger carried "done" and "build-unverified" six words apart in the same row, and that is exactly
   how a phase reads green while nothing has been compiled.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy (re-tiered at the P7 boundary, §25.5)

**The tier-1 re-tier that carried P3–P7 ends here.** It held through P7 — items 1–5 and 7 all landed
without a simulator, and the two items that needed a Mac are the two that did not land. P8 inverts
the ratio.

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | **The coordinator's state machine, the feed, the seam and the primitive.** The CPT state is already a policy input with every row decided (`App/Fernlet/ProximityRunPolicy.swift:424`), so the policy half needs no task at all — inject the state. The coordinator's clocks, its exactly-once completion and its progress derivation are all pure over an injected clock and an injected task façade. `BGTaskScheduler` errors on a Simulator, so a façade is not a convenience, it is the only way to test this at all. **If a check CAN live here, it MUST.** | Free, deterministic, CI. |
| **1b — UI tests, the app's own harness** | The Live Activity suppression, the CPT-refused explanation copy, and the resume card on a `.foregrounded` return. **`FernletUITests` is in NO workflow and has never been run** (§13.3 finding 8) — item 0 runs it for the first time. Run serially and **PIN the environment** (iPhone 17, portrait, its own invocation). | Minutes per run, same Mac. |
| **2 — sim↔sim, real QUIC** | **Only the half a Simulator can answer**: backgrounding one node with a second `simctl launch` and observing the pushed `appIsForeground` leg **fall** — P6 named it reachable, P7 did not attempt it, and it is now P8's own central question rather than a leftover. Everything CPT is unreachable here. Also P7's item 8 leftovers: the heart eligibility negative; P6's rows behind `FERNLET_MESH_ARM_AFTER`. Budget wall clock at **≈ 3.5 ×** the driver tick number. | One Mac, `simctl`, minutes per run. |
| **3 — physical devices, and this is the phase's spine** | **All of §15.** The radio matrix (QUIC surviving background+lock; cached-endpoint re-dial while backgrounded; fresh Bonjour browse while backgrounded — expected to fail, record it; each × infra-Wi-Fi and AWDL; plus Low Power Mode on/off and memory-pressure kills), §15.2's partition walks, **§15.3's 3 h and 6 h progress soaks**, §15.4's bounded Wi-Fi Aware evaluation. Plus the two P2 residuals: item 11's AWDL half and Lane B's "at most one connection per peer pair". **The §15.3 soak SELECTS §14's degraded ladder rung** — running it late means building the wrong one. | Owner's devices and hours. Not optional, not substitutable. |

**The first hardware sample, and it is the number to beat:** 2026-09-02, DEBUG probe, one sample —
iOS ended a user-started continued-processing task **≈ 46 s** after it started, shortly after the app
was backgrounded, with the fail-immediately strategy and **no progress reported on the task**. It
does not answer the "survives background+lock" row, because the probe tears its own tunnel down when
the task ends; that gate needs a variant that keeps the tunnel and keeps logging past expiry.

Lane gotchas carried from P2–P7 — obey them, they are all paid for:
- **Launch the sims ~1 s apart (`STAGGER=1`)**; always re-harvest identities after any `xcodebuild
  test` run (the full suite resets simulator app state).
- **A fresh log directory per run**, and `pgrep -x xcodebuild` before believing any failure. Never
  `pgrep -f` your own command string.
- **The FIRST `test-without-building` after a build or an idle gap hangs** (~350 s, counted as 1
  failed test); the second invocation passes. Warm the runner with a tiny suite first.
- **`simctl launch --console-pty` intermittently attaches no stdout.** A node with no
  `[mesh-matrix] run label=` banner proves nothing about that node.
- **Every Lane C launch carries `FERNLET_MESH_MATRIX=1`, which bypasses the launch restore** — and
  since P7 the restore has a *visible* surface, so a lane that wants to see the resume card must run
  **without** the harness, using `FERNLET_MESH_RESUME_PRESENTATION` instead.
- **NEW in P7: a Lane C run must stay on the Friends tab.** The policy is the only radio owner now,
  so any leg change off Friends stands the harness's radios down mid-run. Pass B has the harness feed
  the tab leg; a run that navigates is still unsafe.
- **Do not chain a build and a test run in one backgrounded command on a shared DerivedData.**

---

## 3. The work list

Ledger order. Each is one iteration unless noted. *File:line anchors are current at `a528760` (the
phase's last shipping commit);
re-check before editing — P8's own commits move them. Every claim below was fact-checked against HEAD
at the boundary; the P6 launcher had **10 wrong of 62** and each cost an iteration.*

| # | Item | Tier | Prereq |
|---|---|---|---|
| **0** | **The P7 gauntlet debt — a Mac session runs it FIRST, before any P8 code.** P7 landed 10 492 insertions across 42 files and **compiled none of them**: no build, no test run, no wall shown red, no simulator. Run, in order: `python3 Scripts/power-of-10-scan.py` (expect ≈ 509 files, **0 violations**, density ≥ 0.68 — it was 0.782 at the boundary); `python3 Scripts/doc-coverage-scan.py` (expect **0**); `xcodebuild build-for-testing`; the **full `FernletTests` suite in ONE invocation**; `Scripts/spm-wall-check.sh`; `Scripts/spm-wall-selftest.sh`; `Scripts/sync-string-catalogs.sh --check`; **every new P7 wall shown red once** and restored byte-identically (the occurrence-counting single-writer wall, the receiver-agnostic zero wall and its **two** fixtured by-name exemptions, the nine-needle continuation-task sweep (`granted` / `refused` / `expired`, each in three type-scoped spellings), the gate-purity scan, the resume file's no-radio scan, the poller's index-order assertion, the matrix's 832-row deviation pin); **`FernletUITests/ProximityResumeCardUITests`** (7 cells, serially, iPhone 17, portrait, its own invocation) which is in no workflow and has never run; and a confirmation that the gated mesh step reports **`Test run with 335 tests`** rather than meeting a statically-counted floor. **And separately: re-run the hosted S3 Wall job once.** It is RED on `origin/main` (`82fc4d7`, run 71) in `MeshRoutedHeartCeremonyTests.everyHeartFailureCauseHasItsOwnSentence()` — the owner's cell, §13.3 finding 1, diagnosed read-only; if it reproduces, download the RAW log for the expected/actual line (the Actions API returns only a long run's tail). **Nothing else in this list may start until item 0 is green.** | 1 + 1b | — |
| 1 | **`MeshContinuationCoordinator` — the type §14 names and §13's options table assigned the FEEDER role, which does not exist at HEAD.** App-target (it owns `BGTaskScheduler`, which ProximityKit must not import, exactly as it must not import UIKit). It owns: concrete-ID **registration** at mesh start (`MBO.Fernlet.mesh-continuation.<meshID>`; the plist wildcard is already present), **`.fail` submission** on the user's start/join action once the **first peer commits**, the **6-hour and 30-minute clocks**, **endpoint-cache reconnection** (never background Bonjour re-browse as the primary path), routed-store draining, **progress + title/subtitle updates**, **expiration/cancel handling**, and **exactly-once completion** into one idempotent shutdown (the probe's `completeBackgroundTask` pattern, already right). Build it against an **injected task façade and an injected clock** — `BGTaskScheduler` errors on a Simulator, so a façade is the only way this is testable at all. **No feed into the policy in this commit.** | 1 | 0 |
| 2 | **The `setContinuationTask(_:)` feed.** One setter on `ProximityRunPolicyHost` and one caller (the coordinator). The host today binds `private let continuationTask: ProximityContinuationTaskState = .inert` — there is no setter at all. The policy already decides every row: `run` requires **both** `hasCommittedPeer` **and** `continuationTask == .granted`; `.refused` and `.expired` answer identically (`foregroundOnly`); discovery/admission, presence and recipe do not read the state at all. **Follow the house rule** — record, re-decide, push — but **deduplicate** like `setSessionLive(_:)` does, because a progress update every 30 s must not re-push four radios. **The teardown still wins:** `tearsDownSession` is a dominating input and the CPT state may never override it. **Wall to add:** the app target has exactly one `setContinuationTask(` call site, counted by **occurrence** across a comment-stripped `App/` sweep (a file-name wall is green with two call sites in one file), and shown red once. | 1 | 1 |
| 3 | **The `.backgrounded` / `.foregrounded` raises, and the leg disagreement made real.** Nothing in shipping raises either event: they exist as `MeshSessionEvent` cases and as transition arms only, the seven transition arms all inside `MeshSessionStateMachine.swift`. P8 raises them, which is what makes `.continuingInBackground` (`MeshSessionStateMachine.swift:41`) reachable for the first time. **And the moment it is reachable, the two legs must DISAGREE, deliberately:** the pushed `appIsForeground` leg (the app's scene fact, written through the one gate call at `App/Fernlet/FernletApp.swift:415` → `MeshNetworkManager.applyRoutedAccessGate(_:now:)` at `MeshNetworkManager.swift:1451`) and the heart predicate's `sessionState` leg (`mayCommitRoutedHeartLedgerJudgement` at `MeshNetworkManager.swift:9333`, the `.activeForeground` read at `:9335`) — **a CPT-continued mesh custodies ciphertext and decrypts nothing.** The shipping doc already says so at `MeshNetworkManager.swift:9327–9330`. **Do not close the gap by making one leg read the other.** Before changing anything the predicate reads: `sessionState == .activeForeground` still has exactly **ONE** shipping reader at HEAD, and the commit must carry the count. | 1 | 2 |
| 4 | **"Stop searching, keep committed links" — the primitive ProximityKit does not have.** `MeshNetworkManager.applyRunState(links:discovery:)` (`:2235`) already resolves the P8-only pair **links `run` + discovery `stop`** — exactly what a continued mesh wants — and it moves **nothing**, recording `ProximityRunStateSeam.noStandAloneDiscoveryStop`. It is honest rather than silent because there is no primitive: `stopJoin()` runs `stopSearching()`, which **empties the committed slots and clears the group key state**, so "stop searching" and "drop the mesh" are one call today. **Build the primitive, then make the pair use it**, and keep `stopJoin()` a teardown. *Two passes by shape: the primitive with its own tier-1 cells, then the seam arm that calls it and the acceptance cell that stops being a no-op* (`Tests/FernletTests/MeshP7AcceptanceTests.swift:725`, `theP8OnlyPairMovesNothingAndNamesItself`, asserts the pair moves nothing — **that cell must be amended, not deleted**, and the amendment is the proof pass B ran). | 1 | 3 |
| 5 | **Progress, on the clock the manager already owns.** §14 fixes the unit: **elapsed session time toward the ceiling**, monotonic by construction, with title/subtitle carrying the human truth (`Fernlet mesh` / `N friends connected`, the count being roster members with fresh authenticated heartbeats excluding self — hardcoded in the probe, dynamic here). The manager already measures exactly that: `sessionMonotonicOrigin` is a `ContinuousClock.Instant?` (`MeshNetworkManager.swift:9344`), stamped when a session starts or is restored (`:9923`), and `enforceSessionCeiling(now:monotonicElapsed:)` (`:10005`) derives elapsed runtime from it when the caller passes `nil` — which is exactly what P7's poller door does, so the number is already the manager's own. **Read the same origin; do not mint a second one.** **Decide whether progress rides the poller's tick** (§5a). **And close §13.3 finding 5 first:** the ordinary proximity joiner (`currentMesh == nil` arm of `handleMeshDescriptor`) still arms **no** ceiling, so a CPT can run against a mesh with no denominator; only the yielding founder's adopt path arms one (`adoptSessionCeiling(of:now:)`, `:9952`). | 1 | 1 |
| 6 | **Expiration, cancellation and exactly-once completion.** iOS can end the task under pressure regardless — the first hardware sample is **≈ 46 s**. One idempotent shutdown, the probe's `completeBackgroundTask` pattern. **Route an EXPIRED task through `.localIdleStop`** so the existing resume surface offers the mesh back: that transition is the one that raises `.offerForegroundResume` (`MeshSessionStateMachine.swift:331` and `:446`, applied at `MeshNetworkManager.swift:9614–9615`), and P7 already built the whole consumer — `sessionResumeProjection` (`:10356`), `acceptForegroundResume(now:)` (`:10412`, **arms no radio**), `declineForegroundResume()` (`:10449`), and the card at `App/Fernlet/ConnectView.swift:374`. A user returning to a pocketed phone is offered the mesh rather than finding it gone. **Wall:** exactly-once, witnessed per run, never by a process-global audit count (a process-global signal cannot witness a per-cell claim under concurrent suites). | 1 | 1, 3 |
| 7 | **Live Activity suppression, and the reaper that stays.** §14: the custom foreground anchor is suppressed for continued meshes (no duplicate UI); its **once-per-launch orphan reaper stays**. **Grep before assuming a type name** — the plan's `ProximityForegroundAnchor` spelling appears at HEAD only in test doubles; the protocol is `ProximityForegroundAnchoring`. | 1 | 1 |
| 8 | **The degraded ladder, and the copy that tells the truth about it.** §14 pre-decides three rungs — full background mesh → background on infra-Wi-Fi only → foreground-only with opportunistic sync on reunite (which P4 makes automatic) — **and §15.3's soak SELECTS the rung**. Build the ladder as a value with all three rungs testable at tier 1, so the soak's result is a configuration rather than a rewrite. The **CPT-refused** row already has a policy answer (`foregroundOnly`) and §13 says "with the UI explaining background continuation is unavailable" — **that explanation does not exist**; it is new display copy, so it is `LocalizedStringKey` in the app from the first line, frozen English tokens in ProximityKit, listed in the handoff and **synced at close-out from `HEAD`'s catalog blob**. | 1 | 2 |
| 9 | **The P8 acceptance battery + the CI gate lines, in ONE commit.** One serialized `MeshP8<Clause>AcceptanceTests` suite per §14 clause, mirroring P5/P6/P7's shape — the coordinator's lifecycle whole, the feed, the raises and the leg disagreement asserted as a **disagreement**, the primitive, progress monotonicity, exactly-once completion, the ladder — plus an **honesty** suite naming what the battery does not claim (no `BGTaskScheduler`, no device lock, no real background, no thermal, no battery; and whatever §15 has not yet answered). `CIGateSelectorBoundaryTests` fails any declared `MeshP8*AcceptanceTests` the workflow's mesh step does not name, and its battery pin — **`>= 42` at `CIGateSelectorBoundaryTests.swift:167`** — is **measured** at the commit that moves it, never inherited. The `mesh-batteries` floor is **335 over 56 suites** today (`.github/workflows/s3-wall.yml:258`, with the 56 names at `:259–314`), **itself a static count P7 never confirmed on a runner** — so item 0's `Test run with 335 tests` line is this item's baseline, not the workflow literal. Neither pinned digest may move: `594b6f77…5765` (overlay) and `ca898bcc…6930` (schedule) — a move is a red, not a re-pin. | 1 | 1–8 |
| 10 | **Tier 2, the half a Simulator can answer.** (a) **The backgrounding half of the gate** — background one node with a second `simctl launch` and observe the **pushed `appIsForeground` leg fall** and the routed re-entry behave. P6 named it reachable; P7 did not attempt it; it is now P8's own central sim-lane question. (b) P7's item 8 leftovers: the **heart eligibility negative** (a heart to a member with no trust-vault row must be a FINAL, audited refusal with custody kept; needs a third simulator that sat out session 1), and **only if** a `FERNLET_MESH_ARM_AFTER=<polls>` hook closes L-3's founder-collapse arming race first, P6's removal vote and `.chatAgeGated` three-leg negative. **Everything CPT is unreachable here** — `BGTaskScheduler` errors on a Simulator. Timebox to two iterations; what does not cross is recorded by name with a paste-ready owner sentence, never left as "flaky". | 2 | 2, 3 |
| 11 | **Tier 3 — §15, and it is the phase's spine, not its tail.** §15.1's radio matrix; §15.2's partition walks; **§15.3's 3 h and 6 h progress soaks, which select item 8's ladder rung**; §15.4's bounded (2-day) Wi-Fi Aware evaluation; plus P2's two residuals — item 11's AWDL half and Lane B's "at most one connection per peer pair" — and **Lane A's report** and **Lane D with the cable OUT**, both owed since P2. Results land in the runbook's gate table with dates. **Owner's devices and hours. Do not start it without them, and do not substitute a simulator for any row of it.** | 3 | 1–9 |
| 12 | **Close-out** (§8): §14 BUILT with §14.1–§14.4, the §26 P9/P10 handoff, the next launcher, the memory note. | 1 | 0–11 |

### Not this phase

- **P9/P10's remaining radios, the MC retirement (iOS 27) and the companion `BGAppRefreshTask`.**
  §9's table puts them after P8 and behind P2 proven in the field.
- **Relay increment 2** — still gated on the tier-2 measurement §11 names (chunk pacing at 256 KiB,
  control-stream starvation), not run, so not earned.
- **Re-deciding P7's policy.** The matrix is a pure table over the full input product with every CPT
  row already decided; P8 feeds it, it does not re-open it. If a row is wrong, that is a finding for
  §14.3, not a rewrite.
- **"Fixing" the two-leg disagreement.** §25.1 and the shipping doc both say it is deliberate.
- **Option (b) for `handleEncryptedMetadata`; D-7.30's once-per-window; §18.2's partition UX copy;
  the legacy unsigned two-party removal's retirement; transcript `sid`.** All owner's, all unchanged.
- **The conflicted-member blast radius** (§12.3 finding 6) and **the charged forwarder** (finding 4)
  — one-line owner answers about policy.
- **`ConnectionInspectorTests.beginSessionCreatesLiveLog()`** — record a new sighting in the ledger,
  do not chase it; it is the owner's suite and it voided four P6 full runs.
- **P7's own open findings 6, 7, 9, 11, 12, 13** (the unreaped terminated context, the nameless
  sealed context, the unpinnable `.refused`/`.expired` spellings, the one-frame leg lag, Lane C's
  tab-leg dependency, the recipe listener under a held `.social` tab) — record sightings, do not
  chase. **Findings 5, 8 and 10 ARE P8 work** and are items 5, 0 and 5 respectively.

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| **Whether P8 starts before P7's gauntlet is green** | **No — item 0 first.** | P7 inserted 10 492 lines that were never compiled. Building on top makes every red ambiguous between two phases. |
| **Where the coordinator lives** | **A new app-target `MeshContinuationCoordinator`** — §14's word, and §13's options table already gave it the FEEDER role. It owns `BGTaskScheduler`, which ProximityKit must not import. | The composition-root pattern P7 established: ProximityKit stays UIKit-free, BackgroundTasks-free and testable. |
| **How the CPT state reaches the policy** | **One setter, `setContinuationTask(_:)`, on `ProximityRunPolicyHost`**, recording, re-deciding and pushing — but **deduplicating**, like `setSessionLive(_:)`. | Every other leg's seam owns its own edge; the CPT's does not, because the coordinator is the seam. A progress update every 30 s must not re-push four radios. |
| **Whether the CPT state can override a teardown** | **No.** `tearsDownSession` wins; delete-all, below-age and duress end the session whatever the task is doing. | Two owners for one radio is the bug class §13 rejects option C for, and P7's teardown door already ENDS the session (`stopJoin()` + `leaveSession()`). |
| **Whether progress rides the poller's tick** | **Yes** — one wake at 30 s, elapsed session time from `sessionMonotonicOrigin` toward the ceiling. | The only periodic wake the mesh has; reusing it keeps progress and expiry from drifting. Cost: the poll interval becomes a progress-resolution decision, and it is **still unmeasured** (§13.3 finding 10). |
| **What "stop searching, keep links" looks like** | **A new ProximityKit primitive**, not a widened `stopJoin()`. | `stopJoin()` → `stopSearching()` empties committed slots and clears group key state; that is a teardown and must stay one. The `held noStandAloneDiscoveryStop` record exists so the gap is logged rather than silently wrong. |
| **Whether an EXPIRED CPT offers a resume** | **Yes** — route it through `.localIdleStop`, which already raises `.offerForegroundResume`. | The whole surface exists and arms no radio; the alternative is a mesh that vanishes silently while the phone was in a pocket. |
| **Whether P8 adds a persisted surface** | **Assume yes and pay for it.** A durable task id or resume token owes a `Docs/PrivacyWipeCoverage.md` row **and** delete-all writer wiring **in the same commit**. | P6 and P7 each added none in a whole phase. P8 is the first with a real claim to one, and the wall is unforgiving. |
| **New display copy** | **`LocalizedStringKey` in the app, frozen English tokens in ProximityKit**, listed in the handoff and synced at close-out from `HEAD`'s catalog blob. | `ProximityResumeCopy` (P7), `RoutedShareRefusalCopy` and `SessionHeartStatusCopy` are the three patterns; all exhaustive over `CaseIterable`, so a new case fails a test until it is copied. The catalog is **1950** keys at HEAD. |
| **When to stop for hardware** | **The moment the tier-1 skirt is done.** Write the handoff, name every §15 row by name, and stop. | §15's gates are irreducibly physical, and inventing a simulator claim for one of them is the failure mode §12.4's "what the lane could NOT observe" section exists to prevent. |

---

## 4. Walls that will bite

P8's diff spans both targets: a new app-target coordinator, one setter on an app-target host, and a
real primitive plus two event raises inside ProximityKit. **All of P7's walls stand, and P8 adds
four.**

**Carried from P7, and every one of them is still live:**

- **The gate has exactly one writer.** `applyRoutedAccessGate(` appears **once** outside ProximityKit
  — `App/Fernlet/FernletApp.swift:415`, inside the mount, as an injected closure. The wall counts
  **occurrences** across a comment-stripped `App/` sweep and pins the total at 1 beside the file-list
  claim. A coordinator that assembles its own gate breaks it.
- **The zero wall: the mount body is the only place in the app target that names a proximity radio.**
  The sweep is **receiver-agnostic** (a receiver-qualified needle is blind to the same object under
  another name — P7's pass-B P1) with exactly **two** by-name exemptions, each fixtured against the
  exact calls it was written for: the DEBUG rejection-matrix harness and the active recipe share
  sheet. **A coordinator that calls a radio directly is a third owner** — feed the policy instead.
- **The policy decides radios, never plaintext.** D-10.3: iOS data protection gates plaintext
  (decrypt + canonical-store mutation) and store readability; Fernlet's app lock gates **nothing** in
  the mesh; a duress session closes the gate on its own `.onChange`. The decision carries the
  `MeshRoutedAccessGate` through **untouched** — the host constructs none and reads neither `isOpen`
  nor `permits(_:)`.
- **`.inactive` is not a background leg, and `ScenePhase` is not frozen.**
  `FernletApp.routedGateForeground(for:)` is the one phase-to-foreground translation and
  `ProximityRunInputs` has exactly one initialiser, which takes a `ScenePhase` — so no caller can
  hand the policy a foreground fact from anywhere else. The widening's exact extent is pinned at
  **832 rows**.
- **Three session predicates, three jobs.** `isSessionLive` (`MeshNetworkManager.swift:1262`) for
  projections and ceremonies, `hasCommittedPeer` (`:1205`) for radio guards and the resume arm,
  `isInSession` for the layout swap. P6 item 2's pass-B P1 is what collapsing them costs.
- **Nothing may spin.** The poller is **one** host-owned self-re-arming one-shot at 30 s, armed on
  the rise of `setSessionLive(_:)` and cancelled on the fall, with an `isolated deinit`. A tick
  re-checks cancellation **and** liveness after the sleep. A timer that survives a stopped session is
  the battery bug P8 will be blamed for.
- **Wipe wall.** Any new persisted surface or `UserDefaults` key owes a
  `Docs/PrivacyWipeCoverage.md` row **and** delete-all writer wiring in the same commit
  (`PersistedSurfaceWipeBoundaryTests`, `PrivacyWipeCoverageTests`, `DeleteAllDataTests`). P6 and P7
  each added **none**.
- **The routed walls, all standing:** the registry is the only per-type source; two admission doors
  and only two; every pre-store refusal exits through `refuseRoutedFrameBeforeStore` **except** the
  digest family; no epoch on the routed path; W2's pins move with the file that moves them; the three
  retirement zero-lists.
- **Schemas.** `MeshSessionContext` is **3** (`MeshSessionContext.swift:60`,
  `MeshSessionContextSchema.current`), the routed index is **2**. Neither moved in P7 and neither
  should move in P8 — unless item 1 persists a task id, in which case it is a schema bump with a
  wipe row and a v-prior-is-corrupt arm, exactly as P6 item 1 did 2 → 3.
- **The CI selector wall.** Every `MeshP<n>*AcceptanceTests` declared in the tree must be named in
  `.github/workflows/s3-wall.yml`'s mesh step, every named suite must be declared, and every step
  runs through `Scripts/run-gated-suites.sh <label> <min-tests> <Suite>…`. **335 over 56 today**
  (`:258`, names at `:259–314`) — a **static** count, never confirmed on a runner. A **cell-level**
  selector is not an option: the script rejects any selector containing a `/`, and
  `everyGatedSelectorNamesADeclaredSuite` requires each selector to name a declared top-level type.
- **Determinism.** `594b6f77…5765` (overlay) and `ca898bcc…6930` (schedule) must not move. A move
  means something touched the overlay, a schedule draw or `MeshScheduleEvent`, and it is a red, never
  a re-pin.
- **Localization.** Wire tokens, `rawValue`s, audit tokens and refusal spellings stay **frozen
  English**; display text is `LocalizedStringKey` in the app, never `String`. New keys are listed in
  the handoff and synced at close-out from `HEAD`'s catalog blob — never from the held working copy.
- **Power of 10:** ≤ 60 code lines per function/`body`, bounded loops, no `!`/`try!`/`as!`/
  `fatalError`, no swallowed `try?`, no mutable globals, **no nested `#if`**, warnings-as-errors.
  At the boundary: **509 files, 0 violations**, density 0.782 (floor 0.68).
- **MC containment:** `TransportNeutralityBoundaryTests` permits MC types only in
  `MeshMultipeerSession.swift` / `MCPeerIDStore.swift`.
- **Memory lifecycle:** `MemoryLifecycleBoundaryTests`' ML4/ML5 fail a new unmarked detached `Task`
  in a host-holding manager. **The coordinator will own tasks and timers** — this is the wall it is
  most likely to trip. P7's poller uses an `isolated deinit` (ML1) and there is app-target precedent
  (`NetworkMeshFeasibilityProbe.swift`).
- **DocC:** every new type carries `///`; `doc-coverage-scan.py` stays at **0**; the ProximityKit
  landing page, `Docs/ProximityFunctionIndex.md` and `Docs/FileIndex.md` gain their rows in the same
  commit as the file. `ProximityFunctionIndex` indexes **ProximityKit shipping functions only** — an
  app-target type gets a `FileIndex` row and no function row.
- **Do NOT touch** `App/Fernlet/Localizable.xcstrings`'s working copy or
  `App/Fernlet.xcodeproj/xcuserdata/**` (held by another session), or the stray PDF in `Docs/`.

**New in P8, and each must be shown red once:**

- **The single-writer wall for the CPT feed.** `setContinuationTask(` appears exactly **once** in the
  app target outside the host that declares it, counted by **occurrence** across the comment-stripped
  sweep and named from a brace-matched body. Same shape as the gate wall, for the same reason.
- **The zero-radio wall extends to the coordinator.** The coordinator names **no** proximity radio
  door — not `startJoin`, `stopJoin`, `applyRunState`, `leaveSession`, `start()` or `stop()` — and
  the zero wall's sweep must include its file **without** an exemption. A coordinator that reaches a
  radio is exactly §13 option C.
- **The consumer wall for `.activeForeground`.** After item 3, `sessionState == .activeForeground`
  still has exactly **one** shipping reader (`MeshNetworkManager.swift:9335`). Count it, pin it, and
  fail the build if a second appears — because a second reader is how the deliberate disagreement
  becomes an accidental agreement.
- **The resume walls.** (a) `acceptForegroundResume(` still has exactly **one** app-target call site
  (`App/Fernlet/ConnectView.swift`'s `resumeLastSession()`), and a CPT expiry must reach the offer
  through `.localIdleStop`, not by calling accept itself. (b) The resume decision is still the app's
  **one** call to `ProximityResumeDecision.decide(_:)` — no second opinion anywhere.

---

## 5. Three items with a design call inside

### (a) Progress is a decision about the poller, not about a bar (items 5 and 2)

The tempting shape is a progress timer of the coordinator's own. It is the wrong shape for the same
reason §13 rejected two owners for one radio: the mesh already has exactly one periodic wake — P7's
poller, a host-owned self-re-arming one-shot at 30 s — and a second one is a second thing that can
outlive a stopped session. Ride the existing tick. The price is honest and must be written down:
**the poll interval becomes a progress-resolution decision as well as a battery one, and it has
never been measured** (§13.3 finding 10). If §15.3's soak says the system wants finer progress than
30 s, the interval moves for both reasons at once — measure it then, and write the measurement into
the commit rather than inheriting the number a third time.

### (b) The two legs must disagree, and the test must assert the disagreement (item 3)

The moment `.continuingInBackground` is reachable, a CPT-continued mesh has `appIsForeground` false
on the pushed gate and `sessionState` not `.activeForeground` — and it **custodies ciphertext and
decrypts nothing**. The failure mode is not that someone argues with this; it is that a later commit
makes one leg read the other because the disagreement looks like a bug. **So the acceptance cell must
assert the disagreement positively**: drive a state where the two legs differ, and pin that a heart
arriving in that window is held rather than judged. A cell that merely asserts "the heart predicate
is false in background" passes for the wrong reason the day someone makes the gate leg read the
session state. And before touching anything the predicate reads: grep the readers of
`.activeForeground` (there is **one**, `MeshNetworkManager.swift:9335`) and write the count into the
commit — P6 item 6's P1 was bounded that way, and P7 kept the discipline.

### (c) The primitive is the item; the seam arm is the proof (item 4)

`applyRunState(links: .run, discovery: .stop)` already resolves to **nothing**, with an audit record
naming itself. That is not a stub to be replaced — it is a measurement of a missing capability, and
the record is why P8 does not have to rediscover it. Build the primitive in ProximityKit with its own
tier-1 cells (stop browsing and advertising; keep committed slots; keep the group key state; keep the
routed drain; and prove each of those four separately, because "stop searching" is four facts
wearing one name), **then** point the seam arm at it and **amend** the acceptance cell that asserts
the pair moves nothing. Amending that cell — not deleting it — is what proves pass B ran; §23.5's
rule, and P5 item 13 is what happens when a two-pass item's gate cannot tell.

---

## 6. Stop conditions — end the loop on any of these

Call `ScheduleWakeup({stop: true})` (or, outside a `/loop`, simply stop), write the handoff (§8), and
report.

1. **The tier-1 skirt is complete and §15 needs hardware.** This is the EXPECTED stop for P8, not a
   failure. Name every §15 row by name with a paste-ready owner sentence and stop.
2. **Item 0 goes red.** If P7's gauntlet fails, that is the phase's first real finding. Record it,
   fix it if it is small, and stop rather than building P8 on top of it.
3. **Blocked on the owner** and no tier-1 work remains. Say exactly what is needed and stop.
4. **Budget is running low.** Stop with items to spare, not at zero.
5. **Context is filling.** `/loop` resumes the same context and never compacts.
6. **A gate goes red for a reason you did not cause.** Record it, stop, report — do not spend
   iterations bisecting someone else's commit. The known ones:
   `ConnectionInspectorTests.beginSessionCreatesLiveLog()` (~206 s under full-suite load against a
   120 s limit); `MeshRoutedHeartCeremonyTests.everyHeartFailureCauseHasItsOwnSentence()` **red on
   `origin/main` today** (§13.3 finding 1, item 0's second half); and
   `sync-string-catalogs.sh --check`, which may be known-red on stale keys from the held catalog. A
   log containing `Restarting after unexpected exit, crash, or test timeout` has **no usable total**
   — re-run, never bisect.

### Gauntlet — the subagent runs it; you check the marker line

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh          # once anything wall-relevant moves
Scripts/spm-wall-selftest.sh       # after any change to the wall or its permit lists
Scripts/sync-string-catalogs.sh --check
```

**The baseline is UNKNOWN, and that is item 0's whole point.** P6's boundary was **4866 tests in 486
suites**, green, EXIT=0, ONE invocation, 1909.4 s (`64c47f2`). **P7 added eleven new suites and did
not run any of them**, so the true P7 boundary number is whatever item 0 measures — expect roughly
4866 + 35 (battery) + 87 (the four non-battery new suites' `@Test` DECLARATION counts:
`ProximityRunPolicyTests` 13, `ProximityRunPolicyHostTests` 34, `ProximityResumeDecisionTests` 22,
`ProximityRunStateSeamTests` 18) + the amended suites' deltas — **and the full-suite total is
UNKNOWN until a Mac runs it.** Four suites in this phase's diff were amended, not added
(`CIGateSelectorBoundaryTests`, `MeshPairwiseFoundingTests`, `MeshRoutedLockedDeviceTests`,
`PrivacyWipeCoverageTests`), each with a net delta nobody has counted, so **measure it, do not
compute it** — the sum above is an order-of-magnitude check, not a prediction.

Check the **exit code** and the `Test run with N tests` line, never a grep for "passed"; count
`◇ Suite` starts against `✔ Suite` passes; and grep for `Restarting after unexpected exit, crash, or
test timeout` **before** believing any total. Repository gates at the boundary bundle:
`power-of-10-scan.py` → **509 files, 0 violations**, 21 allowlisted, density **0.782** (floor 0.68);
`doc-coverage-scan.py` → **0** undocumented type declarations.

Per-item, the subset is: every suite the diff touches + the routed suites (`MeshRouted*`, `MeshP5*`,
`MeshP6*`, `MeshP7*`, `MeshP8*`) + the wall suites (`MeshRoutedLockedDeviceTests`,
`MeshRoutedDrainTests`, `MeshRoutedDrainWallTests`, `MeshRoutedRefusalBudgetTests`,
`CryptographicPurposeBoundaryTests`, `CIGateSelectorBoundaryTests`, `LocalizationBoundaryTests`,
`PowerOfTenBoundaryTests`) — and, because P8 edits the app target, also
`PersistedSurfaceWipeBoundaryTests`, `PrivacyWipeCoverageTests`, `DeleteAllDataTests`,
`NoTrackingBoundaryTests`, `MemoryLifecycleBoundaryTests`, `TransportNeutralityBoundaryTests`, and
**P7's five new suites** (`ProximityRunPolicyTests`, `ProximityRunPolicyHostTests`,
`ProximityResumeDecisionTests`, `ProximityRunStateVocabularyTests`, `ProximityRunStateSeamTests`).
**Regenerate the suite list from the `@Suite` declarations**, never inherit one, and add by hand the
three suites that carry no `@Suite` attribute (`MeshRoutedStoreIsolationTests`,
`PowerOfTenBoundaryTests`, `LocalizationBoundaryTests`). A `-only-testing` line must name the
**struct**, never the file: `MeshRoutedDrainTests.swift` holds two suites,
`MeshRoutedManifestTests.swift` holds two, `MeshIntroductionAuthorityTests.swift` holds three, and
**P7 added a fourth of that shape — `ProximityRunStateSeamTests.swift` holds
`ProximityRunStateVocabularyTests` and `ProximityRunStateSeamTests`**.

**Every new or amended wall is shown red once**: disable the guard (or revert the fix), **REBUILD**,
run the suite, keep the log, restore the exact text, re-grep the needles, **REBUILD** again.
`test-without-building` runs the LAST build. A negative whose "before" text is an empty string cannot
be reverted by a count-1 replace.

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P8.md` on iteration 1 if absent. Keep it **short**.
**Note the new `Verified` column** — P7's ledger carried "done" and "build-unverified" in the same
row and the phase read green while nothing had been compiled.

```markdown
# Mesh Migration Loop Ledger — P8

**Phase:** P8 (background continuation) · **Prompt:** [Next-Round-Prompt-Mesh-P8-2026-09-17.md](Next-Round-Prompt-Mesh-P8-2026-09-17.md)
**Started:** 2026-__-__ · **Iteration:** 1 · **Tree at seed:** the P7 close-out commit on `claude/hopeful-edison-rl5hb3` (last P7 shipping commit `a528760`); `main` = `origin/main` = `82fc4d7` (P6); `origin/<branch>` tracks the branch — **P7 is pushed to its branch, NOT merged to `main`, and was NEVER COMPILED** (see item 0)

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
**Verified:** `no` until a Mac ran the item's gauntlet subset on its SHA. A row is not done while this says `no`.
| # | Item | Tier | Prereq | State | Verified | SHA | Note |
|---|---|---|---|---|---|---|---|
| 0 | The P7 gauntlet debt + the hosted S3 Wall re-run | 1 + 1b | — | todo | no | | BLOCKS EVERYTHING |
| 1 | `MeshContinuationCoordinator` (registration, `.fail` submission, the two clocks, endpoint-cache reconnection, completion) | 1 | 0 | todo | no | | injected task façade + clock |
| 2 | The `setContinuationTask(_:)` feed | 1 | 1 | todo | no | | one setter, dedup, teardown wins |
| 3 | The `.backgrounded` / `.foregrounded` raises + the leg disagreement | 1 | 2 | todo | no | | grep `.activeForeground` readers first |
| 4 | "Stop searching, keep committed links" — the primitive | 1 | 3 | todo | no | | two passes |
| 5 | Progress on `sessionMonotonicOrigin`; close the joiner's unarmed ceiling | 1 | 1 | todo | no | | |
| 6 | Expiration, cancellation, exactly-once completion; expiry → `.localIdleStop` | 1 | 1, 3 | todo | no | | |
| 7 | Live Activity suppression; the orphan reaper stays | 1 | 1 | todo | no | | `ProximityForegroundAnchoring` |
| 8 | The degraded ladder + the CPT-refused explanation copy | 1 | 2 | todo | no | | new catalog keys |
| 9 | The P8 acceptance battery + CI gate lines, one commit | 1 | 1–8 | todo | no | | pin measured, never inherited |
| 10 | Tier 2: the backgrounding half; P7's item 8 leftovers | 2 | 2, 3 | todo | no | | timebox 2 iterations |
| 11 | Tier 3: all of §15 | 3 | 1–9 | todo | no | | OWNER'S DEVICES — the phase's spine |
| 12 | Close-out: §14 BUILT, §26 handoff, next launcher, memory | 1 | 0–11 | todo | no | | draft → verify → apply from files |

## Blocked on owner
- **P7 was never compiled** (`Docs/Mesh-Migration-Loop-Ledger-P7.md:6`) — item 0.
- **The S3 Wall is RED on `origin/main` (`82fc4d7`, run 71)** in `MeshRoutedHeartCeremonyTests.everyHeartFailureCauseHasItsOwnSentence()` — the owner's cell, plan §13.3 finding 1.
- **P7 is not pushed.**
- **§15's hardware gates** — 2–4 physical devices, multi-hour soaks, Low Power Mode, battery. The phase cannot finish without them.
- Carried unchanged from plan §25.4: items 6 and 8 of P7 (the ungated drain cells, the un-run tier 2); option (b) for `handleEncryptedMetadata`; D-7.30 once-per-window; §18.2 copy; the legacy unsigned removal; transcript `sid`; the hardware lanes (A report, B double-dial, AWDL, D with the cable out); the two census/duress questions; the final wording of the routed hold / refusal / heart / resume copy (19 + 15 sentences in the catalog); §17.3's privacy paragraph; `browsed peers=` downgraded from `.notice`/`.public`; the `HeartDrop` CloudKit record type still not promoted to the Production schema.
- P7 §13.3's open findings 6, 7, 9, 11, 12, 13 and P6 §12.3's, none of them P8 work.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| P8 starts before P7's gauntlet | (default: no — item 0 first) | — |
| Where the coordinator lives | (default: app-target `MeshContinuationCoordinator`) | — |
| How the CPT state reaches the policy | (default: one deduplicating `setContinuationTask(_:)`) | — |
| CPT vs teardown | (default: teardown wins) | — |
| Progress rides the poller's tick | (default: yes, 30 s, `sessionMonotonicOrigin`) | — |
| "Stop searching, keep links" | (default: a new ProximityKit primitive) | — |
| An expired CPT offers a resume | (default: yes, via `.localIdleStop`) | — |
| New persisted surface | (default: assume yes and pay the wipe row) | — |

## Surprises worth not re-deriving
- (seed from §9 of this launcher's "Lessons carried from P7")

## Next item
0 — always, on iteration 1.
```

**Lessons carried from P7 — seed the surprises list with these so P8 does not re-learn them:**
- **A phase can land 10 492 lines without compiling one of them and still read green**, because
  "done" and "build-unverified" sat six words apart in every row. Give the ledger a `Verified`
  column.
- **A host leg the host lowers itself can never rise again if the observed predicate never fell.**
  P7 item 4's P1: the teardown set liveness false while `isSessionLive` stayed true — `stopJoin()`
  nils no `currentMesh` and moves no `sessionState` — so `.onChange` had nothing to carry and the
  poller was dead for that mesh's life. **The predicate drives the leg; a door that wants the leg to
  fall ends the thing the predicate reads.**
- **A self-re-arming one-shot must re-check cancellation AND liveness after the sleep, before the
  tick.** A continuation already queued on the main actor outlives `cancel()`; a tick can land
  mid-wipe and re-arm over a fresh `connect`.
- **A matrix oracle that reads the policy's computed inputs, or a host cell that recomputes the
  decision, is a tautology** — 0 mismatches by construction. The oracle takes the RAW inputs and
  spells the SHIPPING predicates; the host expectation is a **literal** per step.
- **A "single writer" wall that collects file NAMES is green with two call sites in one file.**
  Count occurrences across the sweep and pin the total, beside the file-list claim.
- **A receiver-qualified needle is blind to the same object under another name**
  (`store.recipeShareManager.start()` vs `manager.start()` — a real second owner whose restart guard
  read `lockService.state`, which is `.unlocked` during duress). Sweep receiver-agnostically and
  exempt by file name with a pinned count; **fixture every exemption against the exact calls it was
  written for**, or an exemption that stops matching is a hole nobody can see.
- **An input struct that stores the foreground Bool collapses `.active`/`.inactive` into one
  value.** A product over 3 phases yields 2/3 that many distinct inputs; pin the distinct count as
  its own literal, never `== rowsEnumerated`.
- **The app target is `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY
  = YES`.** Every `nonisolated` Equatable/Hashable/Codable type in `App/Fernlet` stores only
  explicitly `nonisolated` types — a new one storing an un-annotated app enum is a likely compile
  error. **Mark the stored enum `nonisolated`, not the container `@MainActor`.**
- **A `private` file-scope type returned by an unmarked member of an internal `@Suite` is a compile
  error** ("must be declared fileprivate"). Mark the helpers `private static`.
- **The Xcode project uses `PBXFileSystemSynchronizedRootGroup`** for `App/Fernlet` and
  `Tests/FernletTests` — a new `.swift` file under either is in its target with **no pbxproj edit**.
  `Tests/FernletUITests` is a different target and is in **no workflow**.
- **`@ObservationIgnored` on a fact a view derives from means the view never repaints for it**, and
  `a ?? b` in a projection registers no dependency on `b` while `a` is non-nil.
- **Per-launch `@State` dismissal resets on every cold start**, so any launch-derived presentation
  that recurs nags. A presentation may key only on a fact that is consumed or on an event this run.
- **"Inert until P8" rots.** `sessionState == .activeForeground` has exactly ONE shipping reader and
  `.linksLost` reaches it on every blip. Measure a predicate's blast radius before changing it and
  write the count into the commit.
- **A process-global audit signal cannot witness a per-cell claim under concurrent suites.** Witness
  per run.
- **The Actions job-log API returns only the tail of a long run** (~55 s of a 444 s step); a cell
  that failed early leaves no retrievable expectation text. Download the raw log.
- **A full log containing `Restarting after unexpected exit, crash, or test timeout` has NO usable
  total** — re-run, never bisect. A red can be a starvation, not a regression.
- **Never chain a build and a test run in one backgrounded command on a shared DerivedData;**
  `pgrep -x xcodebuild` before each.
- **`-only-testing:` names the SUITE** (one file can hold four); `Suite/cell` runs 0 tests under a
  green banner. `@Test(arguments: [])` is green over nothing; collapse whitespace before `contains`
  and assert every allowlist entry matches something.
- **`#expect(_, "literal")` only** — no concatenation or interpolation; bind `allSatisfy` Bools
  first; never `==` on signed records; `MeshRoutedStorageScope.production` may not appear as a test
  literal.
- **A headless Simulator satisfies the heart predicate's foreground leg by accident**; `simctl` has
  no lock verb. **Every Lane C launch bypasses the launch restore** — and since P7 the restore has a
  visible surface, so a lane that wants it must run without the harness.
- **Any harness bypass that skips a shipping door is a place where a product claim can hide.** L-1
  hid there for five phases; P7 added a second such door. Give the CPT path a non-harness lane from
  the start.
- **Long agent work can die of the session usage limit at a fixed local reset hour** — resume, don't
  retry; apply steps read their inputs from scratch files.
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family, the crypto-purpose
  / `PayloadType` / record-kind spellings, plan §10.7–§10.10, §11.1–§11.4, §12.1–§12.4 and
  **§13.1–§13.4**, `Docs/Proximity-Security-Followups-2026-08-18.md` §1.
- **Other sessions may hold `App/Fernlet/Localizable.xcstrings` + `xcschememanagement.plist`** —
  never stage them; commit with explicit pathspecs.

---

## 8. Close-out, when P8 is done

1. Mark P8 **BUILT** in §14 of the plan with landing SHAs, adding §14.1–§14.4 in the §11.1–§11.4 /
   §12.1–§12.4 / §13.1–§13.4 format (what landed; deviations from the sketch and why; findings for
   the owner deliberately not fixed, **with their costs**; acceptance evidence with the verified
   `-only-testing` lines).
2. Record deviations and say where §14 was silent and which §3 default was taken, and which §5 calls
   the owner should read as **policy acts**.
3. Record findings you deliberately did NOT fix, with what they cost. **Every "Blocked on owner" line
   in the ledger must end resolved, taken-as-default, or written into §14.3 with its cost** — P6's
   close-out made that the rule and P7 kept it.
4. **Say in the FIRST sentence of each block what was not run.** P7's §13 opens by saying the phase
   was never compiled, because a reader who learns that in the last paragraph has already believed
   the first ten.
5. Memory note: what landed, what surprised you, what the next session must not re-derive.
6. Write the **§26 P9/P10 handoff block** (in the §24/§25 format). §9's table puts P9/P10 behind "P2
   proven in the field": the remaining radios, the MC retirement (iOS 27) and the companion
   `BGAppRefreshTask`.
7. Write the **P9 launcher** from §26, as this file was written from §25. **Fact-check every claim
   against HEAD before writing it** — the P6 launcher had 10 wrong of 62, and each cost an iteration.
8. **Run the close-out as draft → adversarial verify → apply from files** (§0 rule 6).
9. **Sync the string catalog from `HEAD`'s blob** for every key the phase's handoffs listed
   (`f4a69f1`'s method, repeated at P6's and P7's close-outs), and check the count against the list
   before committing — P6's owed list was 19 sentences of which 2 already existed; P7's was 15 of
   which 1 did. The catalog is **1950** keys at the P8 seed.
10. **Record every §15 row's result, by name and with its date**, in the runbook's gate table — and
    every row that did NOT run, with a paste-ready owner sentence. A gate with no row is
    indistinguishable from a gate that failed.
11. Note anything P8 learned that re-tiers P9/P10.

---

## 9. The road to TestFlight

The owner's goal is the whole migration before the first TestFlight build. After P8, one phase remains.

| Session | Phase | Prerequisite |
|---|---|---|
| P2 (done) | NetworkMeshSession over QUIC | built + proven sim↔sim |
| P3 (done) | durable context, roster, membership | built; three sims form a full mesh |
| P4 (done) | partition + merge | built; property test found 3 merge defects, all closed by P5 |
| P5 (done) | encrypted store-and-forward routing | built (§11 BUILT `848f202`; post-close review corrections `318d1dc` `f4a69f1` `3404e10`; the resulting P5 boundary, and `origin/main` until the P6 push, was `3a32be0`); photos ride it end to end; 4615 green |
| P6 (done) | feature routing (text, hearts) + key advertisement + pairwise identity | built (§12 BUILT); 4866 green; text AND a routed heart both observed end to end on real QUIC. **Pushed** — `origin/main` is `82fc4d7` — and the first hosted run is RED on the owner's own heart-copy cell (§13.3 finding 1) |
| P7 (done, **unverified**) | app-layer run policy, the poller, the resume surface | built (§13 BUILT, `82fc4d7..a528760`, 17 shipping commits of 51 at `6ccd619`) — **and never compiled or executed**. One policy, one gate writer, three radio seams, one poller, a visible resume surface. Items 6 and 8 did not land. The gauntlet is P8's item 0 |
| **this** | **P8** — background continuation | **§15's gates: physical devices, multi-hour soaks, Low Power Mode, battery — irreducibly physical.** The CPT state is already a policy input with every row decided; what does not exist is the coordinator, the feed, the raises, and the "stop searching, keep links" primitive |
| +1 | **P9/P10** — remaining radios, MC retirement (iOS 27), companion `BGAppRefreshTask` | P2 proven in the field |

**The tier-1 re-tier that carried P3–P7 ENDS here.** It held through P7 — six of its nine items
landed with no simulator at all — and the two that needed a Mac are the two that did not land. P8's
background / battery / thermal gates are the one thing that still needs the phone drawer and the
multi-hour soaks TestFlight does not supply, and **a Simulator cannot produce
`.continuingInBackground` at all**. Scope P8 as a tier-3 phase with a tier-1 skirt from the first
iteration.

**Still owed by the owner, and most of it now blocking:**
- **The P7 gauntlet** (item 0) and **the merge**. P7's branch **is** pushed —
  `origin/claude/hopeful-edison-rl5hb3` tracks `claude/hopeful-edison-rl5hb3` exactly — but `main`
  and `origin/main` are both still `82fc4d7` (P6), so P7 is **not merged** and no hosted runner has
  ever built a line of it.
- **The hosted S3 Wall red on `82fc4d7`** — `MeshRoutedHeartCeremonyTests.everyHeartFailureCauseHasItsOwnSentence()`,
  the owner's cell. Re-run once; if it reproduces, download the raw log.
- **Hardware, and it is now the critical path:** §15.1's radio matrix, §15.2's partition walks,
  **§15.3's 3 h and 6 h soaks** (which select §14's ladder rung), §15.4's Wi-Fi Aware evaluation,
  plus **Lane A's report**, **Lane B's double-dial row**, **item 11's AWDL half** and **Lane D with
  the cable OUT**.
- **P7's items 6 and 8:** gate `MeshRoutedDrainTests` (**43 `@Test`** at HEAD) and price P6's ~286
  ungated cells; and the un-run tier-2 lane.
- **Option (b)**, **D-7.30**, **transcript `sid`**, **the legacy unsigned removal**, **§18.2 copy**,
  **the census/duress questions**, and **the final wording** of the routed hold, refusal, heart and
  now **resume** copy — P6 added 19 display sentences and P7 added 15 (synced at `2389d01`, 14 added
  + 1 present, catalog 1936 → 1950); only the English is outstanding.
- **§17.3's privacy paragraph** by the first TestFlight build — drafted in §24.4; and **downgrade
  `browsed peers=` from `.notice`/`.public`** before QUIC ships.
- **The `HeartDrop` CloudKit record type** is still not promoted to the CloudKit **Production**
  schema (`Docs/CloudKit-Schema-Deploy.md:95`; `Docs/ImplementationPlan.md:51`).

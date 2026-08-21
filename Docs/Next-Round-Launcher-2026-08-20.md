# Next round — launcher

Paste the block below into a fresh session to begin. It is deliberately short on *what* to build:
the work is specified in [`Next-Round-Prompt-2026-08-20.md`](Next-Round-Prompt-2026-08-20.md), and
restating it here would create exactly the two-sources-of-truth drift the 2026-08-20 doc sweep spent
a day cleaning up. What it does specify is *how* to run the round.

**Orchestrator: Fable 5.** **Implementation: workflows.** **Delicate subagent work: Opus.**

---

Work on Fernlet at `/Users/michaelbowman/Desktop/Fernlet 5-18/Fernlet`, on `main`
(6 commits ahead of origin, unpushed).

You are the **orchestrator**, not the implementer. Scout, partition, and verify yourself; do the
building through workflows. The exception is a fix small enough that writing the agent prompt costs
more than the edit — say so when you make that call, and just do it.

Read these three, in order, before touching anything:

1. `CLAUDE.md` — the four walls (S3, no-tracking, Power-of-10, localization). Enforced by CI and by
   zero-violation scanners. Not negotiable, and not worth rediscovering the hard way.
2. `Docs/Next-Round-Prompt-2026-08-20.md` — this round's work, in four parts. **Read Part 4's
   opening before you decide what order to work in**; it is the only part touching a promise
   published at fernlet.com/privacy/.
3. `Docs/RemainingWork-2026-08-20.md` — the surrounding backlog, and what is deliberately cut.

## How to run each part

Suggested order: **Part 4.1 a–c → Part 1 → Part 3 → Part 2.** 4.1a–c and Part 1 are what an outside
tester or a privacy-minded reader actually hits; Part 3 is fifteen minutes; Part 2 is the only
multi-day work and benefits from the rest being settled. Deviate if you find a reason — say why.

- **Part 1 (four cheap fixes)** — one parallel workflow, one agent per fix. They are file-disjoint,
  which is what makes the fan-out safe. Two of the four (1.1, 1.2) want a screenshot afterwards, so
  keep the simulator for yourself rather than handing it to an agent.
- **Part 4.1–4.3 (delete-everything coverage)** — partition **by owning file**, not by finding. The
  surfaces cluster: HealthKit-side, LocalPersistence legacy keys, the wipe funnel in
  `FernletStore.swift`, and the ProximityKit/media ones. Several findings want the *same* funnel
  edited, so route every funnel change through a single agent and let the others report the token
  they need added. Resolve the tombstone → Health-delete disagreement (4.2) **before** dispatching
  anyone to fix it — the auditors contradicted each other and the prompt says so deliberately.
- **Part 4.4 (the wall)** — the one place adversarial structure earns its cost: design the matcher,
  implement it, then spawn agents whose *only* job is to defeat it. A wall nobody attacked is a wall
  whose strength you do not know. Make them try: a key assembled from a variable, a clear that only
  exists inside `#if DEBUG`, a `.cleared` token sitting in a dead branch, a regex change that
  silently discovers nothing. Anything that gets through is either a fix or an honestly-documented
  limit.
- **Part 2 (two features)** — independent of each other, so run them as two pipelines rather than
  one barrier: implement → review → fix, per feature. Per-exercise progress has a design constraint
  worth pinning in the agent's prompt (spec §12 keeps ambient surfaces free of charts and grades;
  Move is not ambient, and factual recall is not a score).
- **Part 3 (CODEOWNERS)** — too small to orchestrate. Do it yourself.

**Two cross-part collisions to plan around**, because they defeat the obvious partitioning:
`HealthKitService.swift` is touched by both Part 1.2 (splitting the availability branch) and Part
4.1a (clearing `requested-capabilities`) — run those in the same agent or in different stages, never
in parallel. And `FernletStore.swift` is the funnel five separate Part 4 findings need edited; that
file wants exactly one owner for the whole round.

## Models

- **You orchestrate as Fable 5.**
- **Pass `model: "opus"` for the delicate agents**: anything touching the wipe funnel, the wall
  design and its attackers, and the token/display invariants. Those are the places where a subtly
  wrong change is silent — a dropped sealed row, a wall that passes vacuously, a localized rawValue
  that empties a checklist.
- Mechanical agents (Part 1.3, 1.4, the ProximityKit residue fixes) can inherit your model.

## Orchestration rules, learned the expensive way here

- **Give every agent an explicit file-ownership list, and say that touching a file outside it
  destroys another agent's work.** Concurrent edits to one file in a shared tree lose writes
  silently. This is the single most important instruction in any fan-out prompt for this repo.
- **Commit or stash before dispatching.** A fan-out implement workflow on a dirty tree has silently
  reverted uncommitted work in this repo before.
- **Agents must not build or run tests.** They fight over DerivedData and corrupt each other's runs.
  You build and test centrally, between stages. This also gives you the real error list, which is
  better ground truth than any agent's report.
- **Read the agent reports, but verify the claims you act on.** Last round an agent's structured
  report failed to serialize while its edits landed fine — and separately, two auditors contradicted
  each other on a real finding. Reports are evidence, not conclusions.
- **Expect handoffs.** Agents restricted to their own files will find edits needed elsewhere. Ask
  for them explicitly and exactly, because you will apply them blind.

## Traps that have already cost time here

- **Any change under `FernletKit/Sources/FernletDomainModel/` needs a CLEAN build before you trust a
  test run.** An incremental build after enum/struct changes there produces nonsense failures —
  *expected error ".malformedRecord" of type SealedBackupError, but ".malformedRecord" of type
  SealedBackupError was thrown instead*. That exact shape means stale artifacts, not a real bug. It
  cost 25 phantom failures last round.
- **`-only-testing:` takes the target name** — `FernletTests/SuiteName`, not a path. Test in
  batches; the full suite is ~9 minutes.
- **If the simulator wedges** ("Application failed preflight checks / Busy"):
  `xcrun simctl shutdown all`, `killall -9 com.apple.CoreSimulator.CoreSimulatorService`, reboot the
  device. Retrying the same command in a loop will not clear it.
- **Line numbers in the docs will have drifted.** Every anchor was verified 2026-08-20; grep for the
  code, don't seek to the line.
- **Several sessions may share this working tree.** If you find changes you did not make, leave them
  alone and commit only your own hunks.
- **`xcodebuild` rewrites `project.pbxproj` synced-group display comments** as a side effect. That
  churn is not yours; keep it out of your commits.

## Verify with the simulator, not by asking

Parts 1.1, 1.2 and 4.1c are defects a person *sees*. A screenshot settles in ten seconds what
reading the code argues about for ten minutes. Drive the simulator yourself and confirm the fix;
do not hand the verification back to the owner.

## Definition of done

The prompt doc's own definition-of-done governs. Two additions:

- **Update `RemainingWork-2026-08-20.md` in the same commit that lands each item.** Its predecessor
  drifted for a month and became a to-do list of finished work — roughly a third wrong, always in
  the direction of under-reporting progress. Do not recreate that.
- **If a doc turns out to be wrong rather than the code, fix the doc and say so plainly in it.** A
  reader who relied on the old text deserves the warning, not a silent correction.

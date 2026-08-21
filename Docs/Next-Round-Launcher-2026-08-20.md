# Next round — launcher

Paste the block below into a fresh session to begin. It is deliberately short: the work itself is
specified in [`Next-Round-Prompt-2026-08-20.md`](Next-Round-Prompt-2026-08-20.md), and duplicating
it here would create exactly the two-sources-of-truth drift the 2026-08-20 doc sweep spent a day
cleaning up.

**Model: Opus 5.** Three parts of this round are genuinely delicate — the delete-everything fixes
touch a promise published at fernlet.com/privacy/, the wall in Part 4.4 has to be designed to fail
loudly rather than pass vacuously, and the token/display invariants are easy to get subtly and
silently wrong. Fast mode is fine for the mechanical parts (Part 1.4, Part 3).

---

Work on Fernlet at `/Users/michaelbowman/Desktop/Fernlet 5-18/Fernlet`, on `main`
(6 commits ahead of origin, unpushed).

Read these three, in this order, before touching anything:

1. `CLAUDE.md` — the four walls (S3, no-tracking, Power-of-10, localization). They are enforced by
   CI and by zero-violation scanners. Not negotiable, and not worth rediscovering the hard way.
2. `Docs/Next-Round-Prompt-2026-08-20.md` — this round's work, in four parts. **Read Part 4's
   opening before you decide what order to work in**; it is the only part that touches a published
   privacy promise.
3. `Docs/RemainingWork-2026-08-20.md` — the surrounding backlog, and what is deliberately cut.

## Suggested order

Part 4.1 a–c, then Part 1, then Part 3, then Part 2. Rationale: 4.1a–c and Part 1 are what an
outside tester or a privacy-minded reader actually hits; Part 3 is fifteen minutes; Part 2 is the
only multi-day work and it benefits from the rest being settled. Deviate if you find a reason —
but say why.

## Tools

- **Bash** for builds, tests, and the scanners. Every command you need is in the prompt doc's
  definition-of-done.
- **The iOS Simulator control tool**, for Parts 1.1, 1.2 and 4.1c specifically. All three are
  defects a person *sees*, and a screenshot settles in ten seconds what reading the code argues
  about for ten minutes. Verify them yourself rather than asking the owner to check.
- **Subagents / the Workflow tool** are worth it for Part 2 (two independent features) and Part 4.4
  (design the matcher, then adversarially try to defeat it — a wall nobody attacked is a wall you
  do not know the strength of). Pass `model: "opus"` when you delegate substantive work. For Parts
  1 and 3, orchestration costs more than it saves — just do them.
- You should not need the web. If you think you do, say what for.

## Traps that have already cost time in this repo

- **Any change under `FernletKit/Sources/FernletDomainModel/` needs a CLEAN build before you trust
  a test run.** An incremental build after enum/struct changes there produces nonsense failures —
  *expected error ".malformedRecord" of type SealedBackupError, but ".malformedRecord" of type
  SealedBackupError was thrown instead*. That exact shape means stale artifacts, not a real bug.
  It cost 25 phantom failures last round.
- **`-only-testing:` takes the target name**, `FernletTests/SuiteName` — not a path. And test in
  batches; the full suite is ~9 minutes.
- **If the simulator wedges** ("Application failed preflight checks / Busy"):
  `xcrun simctl shutdown all`, `killall -9 com.apple.CoreSimulator.CoreSimulatorService`, reboot the
  device. Retrying the same command in a loop will not clear it.
- **Line numbers in the docs will have drifted.** Grep for the code. Every anchor was verified on
  2026-08-20 and the tree moves.
- **Several sessions may share this working tree.** If you find changes you did not make, leave them
  alone and commit only your own hunks.
- **`xcodebuild` rewrites `project.pbxproj` synced-group display comments** as a side effect. That
  churn is not yours; keep it out of your commits.

## Definition of done

The prompt doc's own definition-of-done section governs. Two additions:

- **Update `RemainingWork-2026-08-20.md` in the same commit that lands each item.** Its predecessor
  was allowed to drift for a month and ended up a to-do list of finished work — roughly a third of
  it wrong, always in the direction of under-reporting progress. Do not recreate that.
- **If a doc turns out to be wrong rather than the code, fix the doc and say so plainly in it.** A
  reader who relied on the old text deserves the warning, not a silent correction.

# Mesh Migration Loop Ledger — P7

**Phase:** P7 (the app-layer run policy, the poller, the resume surface) · **Prompt:** [Next-Round-Prompt-Mesh-P7-2026-09-12.md](Next-Round-Prompt-Mesh-P7-2026-09-12.md)
**Started:** 2026-09-17 · **Iteration:** 1 · **Tree at seed:** `82fc4d7` = `main` = `origin/main` (P6 **is pushed** — the launcher's "not pushed" line is stale; see Blocked on owner) · **Branch:** `claude/hopeful-edison-rl5hb3`

**Environment of the session that seeded this ledger:** a Linux container with **no Swift toolchain** — `xcodebuild`, the full suite, `spm-wall-check.sh` and the UI harness cannot run here; only `power-of-10-scan.py` and `doc-coverage-scan.py` do (both green at seed: 503 files / 0 violations / density 0.781; 0 undocumented). **Every SHA this session lands is "scan-green, build-unverified"** until a Mac session runs §6's gauntlet on it, and every wall it writes still owes its "shown red once" log. Item 6 (a measured step time) and item 8 (tier 2) cannot be done from this environment at all.

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | `ProximityRunPolicy` as a pure value + the matrix over the full input product | 1 | — | in-flight | | no wiring in this commit |
| 2 | The policy is the single writer of `applyRoutedAccessGate` (6 sites → 1) | 1 | 1 | todo | | |
| 3 | The radios get `apply(_:)` seams; ContentView + FernletStore stop calling them | 1 | 1, 2 | todo | | two passes |
| 4 | The poller — one timer, three consumers (ceiling → idle lapse → partition) | 1 | 1, 3 | todo | | |
| 5 | The resume surface over `MeshSessionRestoreOutcome` | 1 + 1b | 1 | todo | | two passes |
| 6 | Gate `MeshRoutedDrainTests` (43) and price P6's ~286 ungated cells | 1 | — | todo | | P6 §12.3 finding 14; needs a Mac to measure |
| 7 | The P7 acceptance battery + CI gate lines, one commit | 1 | 1–6 | todo | | |
| 8 | Tier 2: the backgrounding half; the heart eligibility negative; P6's remaining rows behind `FERNLET_MESH_ARM_AFTER` | 2 | 3, 4 | todo | | timebox 2 iterations; needs a Mac |
| 9 | Close-out: §13 BUILT, §25 P8 handoff, P8 launcher, memory | 1 | 1–8 | todo | | draft → verify → apply from files |

## Blocked on owner
- **The P6 push happened** (`82fc4d7` on `origin/main`, 2026-09-15) and **hosted CI is RED on it**: S3 Wall run 71 failed at step 12, *Mesh acceptance batteries (P3 / P4 / P5 / P6) + the CI selector wall* (steps 1–11 green; Power of 10 run 31 green). Cause: `Test run with 300 tests in 50 suites failed … with 1 issue` — **`MeshRoutedHeartCeremonyTests.everyHeartFailureCauseHasItsOwnSentence()`** (the floor of 300/50 was met exactly; everything else green). Prime suspect: the committed catalog blob vs. the owner's held working copy (the launcher's own "known-red on stale keys" note). Not P7's to bisect (§6 stop condition 5) — diagnosis delegated on iteration 1, result recorded under Surprises; items 6 and 7 edit exactly that step, so it must be understood before item 7.
- Carried unchanged from plan §24.4: option (b) for `handleEncryptedMetadata`; D-7.30 once-per-window; §18.2 copy; the legacy unsigned removal; transcript `sid`; the hardware lanes (A report, B double-dial, AWDL, D with the cable out); the two census/duress questions; the final wording of the routed hold / refusal / heart copy (19 sentences in the catalog since `6b77ec2`); §17.3's privacy paragraph (drafted in §24.4); `browsed peers=` downgraded from `.notice`/`.public`; the `HeartDrop` CloudKit record type still not promoted to the Production schema.
- P6 §12.3's open findings, none of them P7 work: the charged forwarder (4), `ConnectionInspectorTests` (5), the conflicted-member blast radius (6), the un-linked third member (7), item 6's two residuals (8), D-4.5's expiring heart (9), I-13's vanished pair (10), the peer-holdings-shrink shape (11), tier 2's un-run rows (12), L-3's arming race (13), the unpinned audit tokens (15), 1c's sibling wall-clock leg (16), the battery's own named weaknesses (17), the un-taken `MeshRoutedAckStageTable.increment1` alias cleanup (19), and the grouped residuals of finding 20.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Where the run policy lives | app-target `ProximityRunPolicy`, §13 option A (default) | 2026-09-17 |
| Single writer of the routed access gate | yes, six sites → one, seam unmoved (default) | 2026-09-17 |
| Policy decides plaintext | no — radios only (default) | 2026-09-17 |
| Poller ownership and interval | policy-owned, one timer, 30 s, ceiling → idle lapse → partition (default) | 2026-09-17 |
| What the launch restore presents | Friends-surface affordance, nothing modal; deferred is silent (default) | 2026-09-17 |
| Delete-all / age / duress reach the radios | as policy inputs producing `stop` (default) | 2026-09-17 |
| New persisted surface | none (default) | 2026-09-17 |

## Surprises worth not re-deriving
- **No Swift toolchain in this session's container** (see the environment line). Compile correctness is by reading declarations, never by building; the verifier's first job on every item is "would this compile".
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup` for `App/Fernlet` and `Tests/FernletTests` — a new `.swift` file under either is in its target with **no pbxproj edit**.
- A full log containing `Restarting after unexpected exit, crash, or test timeout` has NO usable total — re-run, never bisect. A red can be a starvation, not a regression (a 1749 s fixed-seed cell passed in 1.3 s alone).
- Never chain a build and a test run in one backgrounded command on a shared DerivedData; `pgrep -x xcodebuild` before each.
- `-only-testing:` names the SUITE (one file can hold four); `Suite/cell` runs 0 tests under a green banner. `@Test(arguments: [])` is green over nothing; a wall whose needle matches nothing is the same failure — collapse whitespace before `contains` and assert every allowlist entry matches something.
- A negative control whose "before" text is empty cannot be reverted by a count-1 replace — re-insert the exact block and re-grep the needles.
- "Inert until P8" rots: `sessionState == .activeForeground` has exactly ONE shipping reader (`mayCommitRoutedHeartLedgerJudgement`) and `.linksLost` reaches it on every blip. Measure a predicate's blast radius (grep its readers) before changing it and write the count into the commit.
- A roster-wide invariant is not key-generic (`routedDeliveryState` answers `.reclaimed` for "no record"). A process-global audit signal cannot witness a per-cell claim under concurrent suites.
- The first test invocation after a build or an idle gap hangs (~350 s, 1 "failed"); the retry is the acceptance. zsh passes an unquoted `$ARGS` as ONE argument; a `while read` with no trailing newline drops the LAST suite. Under load a few `✔ Suite` lines are corrupted by `[startup]` stdout — banner, exit code and zero `✘` are the signals.
- `#expect(_, "literal")` only — no concatenation or interpolation in the comment; bind `allSatisfy` Bools first; never `==` on signed records; `MeshRoutedStorageScope.production` may not appear as a test literal.
- A headless Simulator satisfies the heart predicate's foreground leg by accident; `simctl` has no lock verb. Every Lane C launch (`FERNLET_MESH_MATRIX=1`) bypasses the launch restore — L-1 hid there for five phases.
- Long agent work can die of the session usage limit at a fixed local reset hour — resume, don't retry; apply steps read their inputs from scratch files.
- Closed; do not re-audit: `MeshTunnelConvergence`, the id-vs-endpoint family, the crypto-purpose / `PayloadType` / record-kind spellings, plan §10.7–§10.10, §11.1–§11.4, §12.1–§12.4, `Docs/Proximity-Security-Followups-2026-08-18.md` §1.
- Other sessions may hold `App/Fernlet/Localizable.xcstrings` + `xcschememanagement.plist` on the owner's Mac — never stage them; commit with explicit pathspecs. (This container's clone was clean at seed.)

## Next item
1 — in flight (iteration 1). Then 2.

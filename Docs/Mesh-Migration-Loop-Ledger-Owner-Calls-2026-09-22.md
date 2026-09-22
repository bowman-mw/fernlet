# Mesh Migration Loop Ledger — the owner's calls, built

**Round:** not a phase — two build items the owner decided in the device round, plus the two product findings
salvaged from the superseded P7 branch. The launcher is
[Next-Round-Prompt-Owner-Calls-2026-09-22.md](Next-Round-Prompt-Owner-Calls-2026-09-22.md); the round it follows is
[Mesh-Migration-Loop-Ledger-Device-2026-09-22.md](Mesh-Migration-Loop-Ledger-Device-2026-09-22.md) (item 3, the five calls).
**Started:** 2026-09-22 12:54 EDT. **Tree at seed:** `main` = `3397cc2`; HEAD's CODE byte-identical to `d88062c`
(`git diff --stat d88062c..HEAD -- . ':(exclude)Docs'` empty — every commit since touched `Docs/` only).
**Worktree:** the primary checkout, `main` directly. The owner's held working copies were never staged or written:
`App/Fernlet/Localizable.xcstrings`, the migration plan, `Docs/FernletSpecificationV3.md`, `Docs/ImplementationPlan.md`,
`Docs/Mesh-Migration-Loop-Ledger-P6.md`, `Docs/Next-Round-Prompt-Mesh-P7-2026-09-12.md`, `Docs/RemainingWork-2026-08-20.md`,
the xcuserdata plist, and the untracked `Docs/RemainingWork-2026-09-14.md`. Plan edits land as index-only blobs.
**Session note:** the desktop app restarted twice mid-round; each restart killed the in-flight background verifier and one
test run, and nothing committed was lost.

## Entry condition — the soak
| Condition | Found | Consequence |
|---|---|---|
| The 6 h soak of 2026-09-22 read out | **Not run yet** — the device round scheduled it for the EVENING of 2026-09-22; this round started at 12:54. The device round's scratch (`soak/`, `readout.sh`) is not on disk: both of that session's scratchpads (`933b433c…`, `d49fdbba…`) are empty | Item 0 stays OWED. Items 1–3 were built anyway, deliberately: the soak runs on the build INSTALLED on the phone (`MBO.Fernlet 1.0 (1)`, installed by the device round, code = `d88062c`), and a tree change does not reach an installed app. **Do not install anything from `4d1fa0b` or later on the phone before the soak has run.** The soak's scripts must be rewritten from the runbook's *Lane B* row when it runs |

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`.

| # | Item | State | Commits | Notes |
|---|---|---|---|---|
| 0 | The soak's read-out | **blocked (owner) — not yet run** | — | Scheduled for the evening of 2026-09-22 on the phone's installed (`d88062c`-code) build; see the entry condition |
| 1 | P9-3-A — make it work | **done** | `4d1fa0b` · plan blob `ef3b511` | The app-lock FACT is retired, not re-projected: no leg in `presenceState`/`recipeShareState`, no `Input.appLockEngaged`, no projection, no feed, and `ProximityRunPolicy.swift` imports no `FernletLock`. Product 23 040 → **11 520** (3 × 5 × 4 × 3 × 2⁶), every derived count moved with it. Red once against the restored old table (the P7 clause failed on the count, `agrees` and `inactiveIsForeground`; the new cell failed five ways). The `ContentView` lock-state edge survives as the view's duress feed and the gate's re-entry pass (view-edge count stays 7). Two funnel rows now pin `selectedTab = .personal`, because `allowNearbyRecipeShares` defaults to TRUE and the lock had been what kept a unit test from starting a real recipe listener |
| 2 | Option 1b's name deferral | **done** | `e83ec82` · record `f8687d5` (plan blob inside) | One send-side gate, `disclosedDisplayName` ("" until `confirmPeerIdentity()`), read by all FIVE coordinator send sites — the introduction alone was not enough: a pre-commit heartbeat's ack carried the name. The receive side ignores any name on an introduction (so an older peer is shown by fingerprint too); the name is adopted from the first verified post-commit envelope, once, from the verified key only. No new frame and no wire-shape change. Subscribers: the mesh roster and the recipe picker. The join screen shows `FingerprintText` until the dwell or the tap. Red once: 9 issues across the five cells. **Lane C OBSERVED on two Simulators** (runbook *Lane C — Option 1b*): each side's `peers=[…]` is the other's fingerprint at `awaitingProximityCommit` and its name at `connected` |
| 3a | The cold-start nag | **done** | `b277888` | `MeshSessionContext.endingPresented` (additive, no schema bump — `localTermination`'s precedent), inside the sealed file so delete-all and a new session already cover it; the presentation answers `.nothing` for a marked ending; `acknowledgeSessionEndingPresented()` is the card's `.onAppear`. Neither launcher sketch as written: reaping loses the rejoin bar, and narrowing to a rejoin-bar hit silences EVERY ending at launch (removal, ceiling). The pin — two launches over one sealed `ownDeparture` context — reads ONE presentation and `rejoinRefusal == .ownDeparture`; red once it read `[.youLeft, .youLeft]` |
| 3b | The nameless, modeless context | **skipped (inert — taken with the resume-accept door)** | — | Nothing on main mints a descriptor from a restored context (`promoteToMesh` is the only mint, and no resume-ACCEPT door exists), so the missing name/mode can reach no surface yet. The v3 → v4 bump, its decode-compat cell and any wipe row belong to the commit that builds that door (P7 item 5's 1b half) |
| 3c | The branch's resume-card UI suite as a template | **not built (not asked)** | — | Commit `85e79ea` still resolves in the local object store (`git cat-file -t 85e79ea` → `commit`; `Tests/FernletUITests/ProximityResumeCardUITests.swift` and the `FERNLET_MESH_RESUME_PRESENTATION` hook readable via `git show`). Unreferenced objects go at the next `git gc` — the owner's call whether to pin them before then |
| 4 | Optional: the three priced hardenings | todo | — | See below |

## Verification
| Item | Verifier | Result |
|---|---|---|
| 1 + 2 | one blind Opus pass over `4d1fa0b`…`f8687d5`, own worktree and DerivedData | in flight |
| 3 | — | owed |

## Gates, as read
- Item 1: 51 tests in 6 suites green (both run-policy suites, the funnel, both P7 clauses, P7 honesty); power-of-10 0 violations; doc coverage 0.
- Item 2: `ProximityCoordinatorTests` 41/41; 294 tests in 16 neighbouring suites; the four boundary walls green but for the held-xcstrings red below; `Scripts/spm-wall-check.sh` WALL CHECK PASSED (warnings are errors).
- Item 3: 66 tests in 9 session/restore/store/wipe suites; with five boundary walls 166/167 across 14 of 14 named suites.
- No full-suite run (the owner's standing rule).

## Pre-existing reds in the primary checkout — NOT caused by this round
1. `LocalizationBoundaryTests.countBearingKeysCarryPluralVariations` — the held `App/Fernlet/Localizable.xcstrings` lost the
   `%lld friends connected` plural variation (its comment is `isCommentAutoGenerated`). HEAD's committed catalog has it.
2. The plan-needle cells of `MeshP9HonestyAcceptanceTests` and `MeshP10HonestyAcceptanceTests` — the held plan on disk is a
   4 535-line older copy (HEAD: 6 478 lines) that contains no `P9-3-A`, no §15/§27 sections.
Both come from the owner's held working copies; a verification in a clean worktree reads the committed files.

## Concurrent work seen
`claude/mesh-reconnect-fixes-2026-09-22` (`f210db6`, one commit, its own worktree) also edits
`FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift` (+146) and the runbook. Items 2 and 3 touch the same file in
different functions; whichever merges second should expect a textual merge, not a semantic one. Its two booted Simulators
(`Fernlet Reconnect A/B`) were left alone.

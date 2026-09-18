# Mesh Migration Loop Ledger — P8

**Phase:** P8 (background continuation), preceded by the P7 gauntlet · **Prompt:** [Next-Round-Prompt-Mesh-P8-2026-09-18.md](Next-Round-Prompt-Mesh-P8-2026-09-18.md)
**Started:** 2026-09-18 · **Iteration:** 1 · **Tree at seed:** `main` = the P7 close-out (fast-forwarded 2026-09-18, `292ea0e`); P7 UNBUILT until item 0

**Environment of this session:** a Mac with Xcode 26 and the iOS 26.5 SDK, the owner's primary checkout. Concurrent sessions hold `App/Fernlet/Localizable.xcstrings`, `xcuserdata/**` and several `Docs/*.md` uncommitted; every commit below is by explicit pathspec, and the catalog and plan edits land as index-only blobs (the held working copies are untouched).

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | Build and run P7: the gauntlet, the red-onces, the floor and pin re-measured, the catalog sync, the UI suite, the full suite; §13 → BUILT | 1 + 1b | — | in-flight | see item 0 log | every red = a P7 fix commit; five landed so far, listed below |
| 1 | P7 item 6 carried: gate the drain cells, measured | 1 | 0 | todo | | |
| 2 | P7 item 8 carried: tier 2 (backgrounding half; eligibility negative; ARM_AFTER rows) | 2 | 0 | todo | | timebox 2 |
| 3 | The stop-browsing-keep-links verb; the refused row executed; the token a zero-count wall | 1 | 0 | todo | | two passes |
| 4 | `MeshContinuationCoordinator` as a pure value + the state table; progress arithmetic | 1 | 0 | todo | | |
| 5 | The two raises (coordinator only) + the disagreement cell | 1 | 3, 4 | todo | | two passes |
| 6 | Task wiring: register, submit, expire, cancel, complete once; keeps the tunnel; feeds the store; anchor suppressed | 1 + 3 | 4, 5 | todo | | |
| 7 | Refusal / expiry presentation on the Friends card slot; privacy sentence | 1 + 1b | 4 | todo | | keys listed for sync |
| 8 | Tier 3 part one: the device plan A–E | 3 | 0 | todo | | first observation of any P7 behaviour |
| 9 | Tier 3 part two: §15.1–§15.4 → the runbook's Lane B table | 3 | 6, 8 | todo | | the degraded ladder is decided here |
| 10 | P8 acceptance battery + CI lines | 1 | 3–7 | todo | | pin and floor measured |
| 11 | Close-out: §14 BUILT, §15 filled, §26 handoff, next launcher, memory | 1 | 0–10 | todo | | draft → verify → apply |

## Item 0 log — every red is its own commit
| Step | Result | SHA | Note |
|---|---|---|---|
| Two scans | 0 violations / 0 undocumented, re-checked after every commit below | — | density 0.778 |
| `build-for-testing` at `292ea0e` | RED — five compile errors, one per build cycle (package → app → tests) | `cb34622` | `nonisolated extension` under `defaultIsolation(MainActor)`; `MeshSessionCeiling.ceilingSeconds` public for the poller; `Hashable` on both presentation enums; `Set<LocalizedStringKey>` (not `Hashable`); `@testable import FernletCrypto` for `DeviceBindingID.$testOverride` |
| Owner device finding (a): the asymmetric-commit founding outage | FIXED — `reannounceToNewbornPeerIfNeeded` on the foreign refusal, once per (sender, meshID) | `4b5a2d8` | red-once cell runs BOTH orderings; higher-first was always green |
| Owner device finding (b): the recipe listener's self-stop with no re-start | FIXED — listeners reconcile against `isListening`, not the last verdict; `PresenceManager` now self-stops on `didNotStart*` | `32b2d5c` | NOT the launcher's level-trigger: presence never self-stopped, and level-triggering re-pinned 13 cells; 13 cells untouched this way |
| Finding (c), new: photos to nobody were silent | FIXED — `photosKeptOnThisPhone` + `mesh.routedShare.skipped` + one sentence in the camera info sheet, never an alert per shot | `a29197b` | one new app string, owed to the catalog sync below |
| Owner retest: still no merge in either ordering | FIXED — finding (d): the yield's "provably empty" guard counted OTHER meshes' custody; now `holdsNoRoutedItem(mintedIn:)` | `90ba678` | reproduced sim↔sim with the audit stream: `droppedUncommittedSlot` → `yieldRefusedRoutedContent` (items=4) → (a)'s reannounce → the peer (items=0) yielded → members=2 |
| `ProximityRunPolicyTests` alone | green (in fix (b)'s batch) | — | |
| Per-item suites (items 1–7) | green in the fix batches: seams, funnel-adjacent, locked-device, founding, photo, drain, P3, P7 six, poll, resume, copy | — | 138 + 96 + 111 + 81 tests across the batches |
| Red-once item 7: one `MeshP7…` selector deleted from the workflow line | RED by name (`everyMeshAcceptanceBatteryIsGated`, 4 tests / 1 issue), GREEN on restore — no rebuild needed, the wall reads the workflow at test time | — | |
| Red-once item 3: `store.presenceManager.stop()` planted in `ContentView.handleTabChange`; then a second `meshNetworkManager.startJoin()` there | RED by verb and RED by name (`everyRadioVerbLivesInTheSeamsFile`, 17 tests / 1 issue each), GREEN on restore | — | the first attempt's edits never landed (an anchor that matched twice) and its green runs proved nothing — re-done with line-number edits and a `git diff --stat` printed before each run |
| Red-once item 2: a second `applyRoutedAccessGate(.closed, now: Date())` under `App/`; then the funnel's gate line removed from the core's body | RED by file name (`theGateHasExactlyOneWriterOutsideProximityKit`, 27 tests / 1 issue); RED on both halves (2 issues) with the line out of the body; GREEN on restore | — | the second negative deleted the line rather than relocating it (the relocation insert did not land), which reddens both halves — the brace-matched half is exercised either way |
| Red-once item 1: `routedGateForeground(for:)` flipped to `phase == .active` | RED on 5 cells (`anInactiveSceneIsAForegroundScene`, the mirror oracle, the listener rows…; 19 tests / 5 issues) after a rebuild, GREEN after the restore and a second rebuild; tree clean | — | `CIGateSelectorBoundaryTests` green (4 tests) against the raised floor |
| Mesh-batteries line as the workflow spells it; floor re-measured | `Scripts/run-gated-suites.sh mesh-batteries 300 <the 56-suite line>`: **316 ran, 0 failed, result=Passed** (the script's own bundle count), 160 s | floor commit below | expected 313 = 300 + 13; measured 316 = 313 + 2 (the founding suite's two new cells: the two-ordering asymmetric cell counts once, and the custody cell) + 1 not attributed per suite from the console log (a suite on the line grew by one since P6's measure) — write 316, the measured number, never the expectation |
| Catalog sync from HEAD's blob, index-only commit | DONE — 16 insertions: P7's 13 (counted against the P7 ledger's list) + (c)'s 3 (`1 photo…`, `%lld photos…`, `Film remaining: %lld. %@`); `--check` exit 0 | `45c8449` | synced in a clean worktree with its own DerivedData; the held working copy is untouched and still shows `M` |
| UI suite serially | pending | | |
| Full suite, one invocation, vs 4 866 / 486 — FIRST run | 4 939 tests in 499 suites, 2 119 s, EXIT=65 with 3 issues, no restart; none a product defect: the wipe-path scan had no pin for `reapplyProximityRunPolicy` (P7 item 3's call, never run under a toolchain), and two founding counts were process-wide (`== N` over a global audit signal, D-6a.10) | `b7606d2` | pin added with its reason; both counts scoped by the line's `held` context to the rig's own mesh id; the refusal now carries `held`. Re-run whole at the end for the EXIT=0 number |
| Full suite, one invocation — CLEAN re-run | pending | | after the red-onces and the wall build |
| Strict wall build (`Scripts/spm-wall-check.sh`) | pending | | |
| Three simulator eyeballs | pending | | Friends tab entry/exit; Control Centre over the tab; delete-all during a live session |
| Plan §13 → BUILT with measured numbers in §13.4 | pending | | index-only blob (the plan is held) |

## Blocked on owner
- Devices in hand from item 8 on; the runbook's Lane B rows are the evidence table. The owner's phone ↔ Simulator run is the first device observation and it produced findings (a)–(d) above; a re-run on the fixed build is owed.
- `DayRecordRepository` (and 18 sibling sites): `assertionFailure` inside a `catch` on a Core Data / file I/O failure traps DEBUG builds on an environmental error (`Task 437: Fatal error: day record delete failed`); the store loads with `FileProtectionType.complete` and nothing defers day writes while the device is locked. Diagnosed 2026-09-18, NOT built; the owner chooses the scope (day repository only, or the 19-site family).
- Carried from plan §25.4: the hardware lanes (A report, B double-dial, AWDL, D cable-out); option (b); D-7.30; §18.2 copy; the legacy unsigned removal; transcript `sid`; the census/duress questions; the final wording of P6's 19 and P7's 13 sentences; §17.3.
- P6 §12.3's open findings 4–13, 15–17, 19, 20; P7 §13.3's residuals 4–9, 13–14.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| The first iteration | item 0 whole, in-session | 2026-09-18 |
| Process deviation | the owner drove the session directly ("build all three in that order"; "do the catalog sync, the ledger lines and the rest of item 0"); no three-agent dispatch — the shape was kept as three read-only verifying agents for the diagnosis, then in-session implement + red-once + regression batch per fix | 2026-09-18 |
| Finding (b)'s design | reconcile against the radio's own `isListening`, not a level-triggered seam | 2026-09-18 |
| Finding (c)'s surface | a count, never an alert per shot; no offline queue (freeze-at-mint stays the design) | 2026-09-18 |
| Finding (d)'s guard | this mesh's minted items only; a parked record never counts; load-state fail-closed unchanged | 2026-09-18 |
| How the coordinator reaches the radios | (default: feeds the store; never a verb) | — |
| Who raises `.backgrounded` / `.foregrounded` | (default: the coordinator only) | — |
| The stop-browsing verb | (default: one new public verb; `stopJoin()` unchanged) | — |
| The progress unit | (default: elapsed toward the ceiling) | — |
| The poller under a task | (default: unchanged) | — |
| When the task is submitted | (default: first commit, `.fail`, concrete id) | — |
| What refusal / expiry presents | (default: the Friends card slot) | — |
| The degraded ladder | (decided by §15.3) | — |
| New persisted surface | (default: none) | — |

## Surprises worth not re-deriving
- **An unbuilt round produces four error classes first**: a `extension` under a MainActor-default module silently isolating its members (`nonisolated extension`); app-side reads of internal package symbols; `Set`/`Dictionary` over `LocalizedStringKey` (Equatable, not Hashable); `@TaskLocal` test overrides reached through a non-`@testable` import. One build cycle each, because errors stop per target.
- **Two Simulators, or a Simulator and a phone, simulate NI ranging at 34 cm** — the dwell never fires and the row shows "Move closer"; the Force button (Settings → Advanced → Connection log → Developer tools → "Proximity debug tools") is the only commit path on a Simulator. That toggle needed a DRAG on the switch under the simulator tool; taps missed.
- **The audit stream is readable on a Simulator**: `xcrun simctl spawn <udid> log stream --level info --predicate 'subsystem == "com.fernlet"'` — info level is required (`Logger.info`), and the `.private` context IS shown on a Simulator. The two decisive tokens for a "not connecting" report are `mesh.meshDescriptor.droppedUncommittedSlot` and `mesh.descriptor.yieldRefusedRoutedContent`.
- **Leaving the Friends tab drops the link, and a five-minute search with no commit ends the session** (`mesh.session.endedByDiscoveryTimeout`) even while a peer is visible but uncommitted.
- **`MeshRoutedCustodyFixtures.rig` uses PINNED past dates**: the founding's expiry sweep removes the seeded item, and a yield cell over it is green for nothing. Seed with live dates (`seedLiveForeignCustody`).
- **`Text + Text` is deprecated in iOS 26 and warnings are errors** — `Text("\(a). \(Text(b))")` interpolation instead.
- **The store uses `FileProtectionType.complete`** and nothing in the persistence layer consults protected-data availability; a debounced day save landing after the device locks throws, and 19 `assertionFailure`-in-`catch` sites turn that into a DEBUG crash.
- Carried from P7 (all still binding): `stopJoin()` tears the slots down; `.inactive` is foreground for the radios; the three store stop sites were not all teardown; a helper repeating a counted spelling reads one too many; persisting effects on the founding rig need the pinned install binding; the chat age gate is `AgeGate.chat`; `FernletLockState` carries associated values; every P6 lesson (a log with `Restarting after unexpected exit` has no usable total; never chain a build and a run on one DerivedData; `-only-testing:` names the SUITE — one file can hold four, and `Suite/cell` runs 0 tests under a green banner; zsh passes an unquoted `$ARGS` as one argument).
- Closed; do not re-audit: `MeshTunnelConvergence`, the id-vs-endpoint family, the crypto-purpose / `PayloadType` / record-kind spellings, plan §10.7–§10.10, §11.1–§11.4, §12.1–§12.4 and, as a record, §13.1–§13.4; `Docs/Proximity-Security-Followups-2026-08-18.md` §1.
- Concurrent sessions share the tree; never stage the catalog working copy, `xcuserdata`, or the stray PDF.

## Next item
0 (the pending rows of the item 0 log, in order)

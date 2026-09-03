# Mesh Migration Loop Ledger — P4

**Phase:** P4 (partition and merge) · **Prompt:** [Next-Round-Prompt-Mesh-P4-2026-09-02.md](Next-Round-Prompt-Mesh-P4-2026-09-02.md)
**Started:** 2026-09-02 · **Iteration:** 2 done · **Tree at seed:** main = `262f3da` (pushed; = `3722511` + the launcher commit)

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | Partition detection + branch-local operation (§10.2) | 1 | — | done | `e48ab81` | `MeshBranchView` + `MeshPartitionDetector` (pure edge detector); `evaluatePartition(reachable:now:)` on-demand, no timer; nothing calls it in shipping code yet (P7 polls). 10 tests, 3708 green |
| 2 | The single merge path (§10.3) on `mergeMembershipLedger` | 1 | 1 | in-flight | 2a `bf81039` | 2a: all four reconnect entries (blip/heal/lapse/restart) route through `mergeReconnected(_:entry:)` → the one path; union rides the existing inventory-digest + re-gossip (no wire change); `MeshMergeOffer.foldedHeads` names cap overflow; schema 2. **2b owes:** (i) overflow counted at the writer (`writeSessionContext`), small; (ii) a tier-1 digest ask driven end-to-end through `FakePeerNetwork`, small; (iii) gate `openBlipMergeIfReconnected` on "peer ∈ derived roster before commit" so a NEW admission still rotates `.membership`, not `.merge`, small. Epoch heads *on the wire* → handed to item 3 (see surprises). |
| 3 | Divergent-epoch reconciliation, coexist → one head | 1 | 2 | todo | | successor = max+1, cause .merge, no wall clock |
| 4 | §10.5 re-gossip + departure recovery at merge | 1 | 2 | todo | | owner's worked example verbatim |
| 5 | Quorum under partition (§10.4), rosters 2–8 | 1 | 1 | todo | | check if proposal/vote records exist first |
| 6 | Termination + development under partition (§10.6) | 1 | 1, 5 | todo | | final pair = MERGED roster |
| 7 | Content merge: order, dedup, gates re-run at ingestion | 1 | 2 | todo | | |
| 8 | Delivery-target semantics for P5 (§10.1) | 1 | 1 | todo | | design call §5c |
| 9 | §16.2 convergence property test, fixed seed | 1 | 2,3,5,7 | todo | | 2 iters |
| 10 | P4 acceptance battery | 1 | 1–9 | todo | | |
| 11 | Tier 2: real 2/2 and 3/1 split, 4 sims | 2 | 10 | todo | | STAGGER=1, re-harvest identities |
| 12 | Tier 2: real quorum removal ≥ 3 nodes | 2 | 5 | todo | | retires FERNLET_MESH_CHAOS_BARRED |
| 13 | Tier 2: §10.5 re-gossip on the radio | 2 | 4 | todo | | leaver with no tunnel to one survivor |
| 14 | Tier 2: MeshLedgerAdoption rebase, non-founder admitter | 2 | — | todo | | needs a MeshFlowDriver change |

## Blocked on owner
- Departure-delivery ack vs P5 recovery (§21.3) — default: P5; P4 asserts the merge recovery.
- Transcript-`sid` move (§18 decision 7) — still owner-gated; P4 moves no wire bytes either.
- §18.2 partition UX copy — the first phase that actually wants it.
- §17.3 `PrivacyInfo` / privacy-copy paragraph — P3's debt, deadline = first TestFlight.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Departure delivery | (default: wait for P5, assert merge recovery) | — |
| Merge re-runs ingestion gates | (default: yes) | — |
| Epoch head cap 8 | (default: assertion, not a knob) | — |
| Partition detection mechanism | (default: no new timer; P7 polls) | — |
| Minting coordinator absent at merge | (default: lowest fingerprint present) | — |
| `temporarilyDisconnected` persisted | (default: no — presence only, schema stays 2) | — |

## Surprises worth not re-deriving
- `LoadToken` is an associated value of `loaded`/`absent` only — `refused`/`deferred`/`corrupt` structurally cannot `save`.
- `isSessionOpen` gates *members*, not *links* (0b, `871b7ee`); `mayLinkToDiscoveredPeers` is the link gate. Relaxing a link gate is only safe on a members-only transport: QUIC is, MC is not — hence `maySeatVerifiedPeer`.
- A joiner's bootstrap root is its ADMITTER's key, not the founder's; `MeshLedgerAdoption.adopt` rebases from the self-admitted root. On a pair the rebase is an unproven no-op — item 14 is the first exercise.
- `.merge` > `.membership` > `.timer` in a 2 s coalescing window; a merge-seeded test cannot then observe a membership rotation (`seedMembershipLedgerForTesting`).
- The keyring stamps supersession INSIDE the rotation whose drain waits ~10 s for acks a fake never sends — bracket grace assertions accordingly.
- `PayloadType` is switched only with `default` (manager + coordinator) — adding a case has no clean-build non-exhaustive-switch hazard.
- Harness: `STAGGER=1`; re-harvest identities after any `xcodebuild test`; fresh log dir per run; `pgrep xcodebuild` before believing a failure; a bare-integer link key is the reliable negative.
- Instrument the wire before believing an inference — "never arrived" and "arrived and refused" read identically without an echo.
- `/loop` never compacts between iterations → fresh session per phase; this ledger is the only durable state.
- Closed; do not re-audit: `MeshTunnelConvergence`, the id-vs-endpoint family (`96337a3`, `2f273a9`), the crypto-purpose / `PayloadType` / record-kind spellings (walled).
- Concurrent sessions share this tree and sim fleet; `Localizable.xcstrings` + `xcschememanagement.plist` are held by another session — never stage them.
- `sync-string-catalogs.sh --check` is known-red on nine stale keys (§21.4) — do not bisect it.
- **(P4 i1)** The `test runner hung before establishing connection` flake hit runs 1, 3 and 5 of 6 with both sims already Booted; a plain retry cleared it every time. Budget **two** invocations per acceptance run (~13 min each).
- **(P4 i1)** A bare `IdentityService(keychainService:)` is **not provisioned**: every unprovisioned instance reports the *same* placeholder fingerprint, so a multi-member fixture roster silently dedupes and assertions go vacuous. Fixtures must `try service.ensureProvisioned()`; write roster-size as a hard precondition.
- **(P4 i1)** Seams left: item 2 — the heal already sets `beginMerge`/`awaitingResumeMerge`, and a *partial* heal routes the returning peer to `peerCommitted` (no event); item 6 — `MeshBranchView.rosterIsFinalPair` is the roster-derived answer, copied through; item 8 — `temporarilyDisconnectedFingerprints` is exactly "pending deliveries" (destination stays the full roster). DEBUG accessors `rotationRosterForTesting` / `epochCoordinatorFingerprintForTesting` exist (no env hook). §18.2 copy: none built; `MeshMemberPresence` is a frozen token.

- **(P4 i2)** **Item 3 has a radio blocker:** `MeshEpochAcceptance.introductionVerdict` answers `divergent` for two well-formed unequal heads and the transport **refuses the tunnel** — two branches that both rotated cannot connect to merge at all today. Tier 1 is unaffected (offers are handed in directly). Item 3 must open that gate *as part of* minting the successor, and carry the epoch heads on the wire (2a folds only a locally-assembled `MeshMergeOffer`; no frame carries a peer's head set). Check first whether the existing `epochRef` frame can carry the head set before adding a frame (golden + registry + framing case together if so).
- **(P4 i2)** Two fail-opens found by wiring, both fixed in `bf81039`: a relaunched member held **no ledger** (dropped every membership frame `droppedNoLedger`) until `restoreMembershipLedger(from:)` re-verified the sealed one through `MeshLedgerAdoption.adopt`; and a merge delivering this device's *own* removal/termination did not eject — `applyMergedRosterVerdict` now runs before the rotation so a departed device asks for no key.
- **(P4 i2)** The `peerCommitted` self-edge carried no effects — that was the silent merge bypass for blips and partial heals. Any future state-machine self-edge needs the same check.
- **(P4 i2)** `awaitingResumeMerge` no longer clears inside `mergeMembershipLedger`; the window closes on a peer digest that *matches* local inventory, and a re-split abandons it. Interrupted-run logs (`** BUILD INTERRUPTED **`) carry no markers — count only runs with a `Test run with` line.

## Next item
2b — the three small residuals above (i–iii) in one iteration, then item 3 (which absorbs "heads on the wire" + the `divergent` tunnel gate). Items 5 and 8 remain unblocked (prereq 1 only) if 2b/3 stall.

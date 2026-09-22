# Mesh Migration Loop Ledger — the deletion round (MultipeerConnectivity leaves the tree)

**Round:** not a phase — plan §28 says the phases are spent. The launcher is
[Next-Round-Prompt-Deletion-Round-2026-09-21.md](Next-Round-Prompt-Deletion-Round-2026-09-21.md); the round it follows is
[Mesh-Migration-Loop-Ledger-Cutover-2026-09-21.md](Mesh-Migration-Loop-Ledger-Cutover-2026-09-21.md) (D-4.3 = Option 1, D-4.4 =
pure retire, the flip BUILT at `5d88247`…`4e70d0a`).
**Started:** 2026-09-21 23:45 local (item 0's first launch crossed midnight; every run is dated 2026-09-22 UTC) · **Closed:** 2026-09-22 (stop condition 1: item 0 observed, item 1 landed and gated, the plan and this ledger updated)
· **Tree at seed:** `main` = `515145b` (the launcher), 31 ahead of `origin/main` (`0a85e06`), not pushed.
**Worktree:** `.claude/worktrees/happy-chatterjee-9cf9ef` on `claude/happy-chatterjee-9cf9ef`; main fast-forwarded after each
item (`git -C <primary> merge --ff-only`); plan edits land in the primary as index-only blobs (the primary's working copy of the
plan is held). **The phone was not touched** (§15.5's overnight recorders; runbook Lane E *How to resume*).

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`.
| # | Item | Prereq | State | SHA | Note |
|---|---|---|---|---|---|
| 0 | **The gate**: the unseeded Lane C pair — founding through the provisional path, then the double-mint re-dial | — | **done — PASS** | this commit (the record) | Run 1 (`unseeded1-*`): two mesh-less Simulators, `legacyRosterFallback members=0` on both, `accepted` both ways with zero `refused`, both commit, both mint (A `droppedUncommittedSlot` on B's early descriptor, B `yieldedNewbornMesh`), `autoGrantedFoundingPair` on A, `bootstrapped`/`adopted members=2` on B, **`derived=2` on both under one epoch head, 1.6 s from browse**; harness fallbacks silent (`armed=false`, no `admitting`, no `requesting admission`). Run 2 (`unseeded2-*`): joiner frozen (`SIGSTOP`) the instant the founder's driver committed → founder alone at `derived=1` → `tunnelEnded … NWError 60` at +90 s → thaw → **both re-introduced and re-accepted** (A real id vs B `unbound`, the tolerated arm both ways; pre-D-4.3 this is matrix row 4's `refused foreignMesh … mesh=00000000-…`) → both re-committed → B minted and yielded (`adopted=93C7EE35-…`) → `autoGrantedFoundingPair` → **`derived=2` on both, 4 s after the thaw**. Recorded: runbook "Lane C — the deletion round's item 0" + matrix row 1a + two dated corrections; the design's correction block; `MeshNetworkManager.armFounderLedgerForHarness` doc, `MeshPairwiseFoundingTests` cell doc, `MeshMatrixRole` doc. Plan §28.8: with the deletion blob. |
| 0.1 | Harness fix the lane needed: `MeshFlowDriver`'s commit dedupe keyed on the coordinator instance, pruned to the live set | 0 | done | this commit | Found by run 2's first attempt: `PeerSlot.id == peer.id`, so a re-dialed slot came back under the same `UUID` with a fresh coordinator and `asked: Set<UUID>` never asked again — both halves parked at `awaitingProximityCommit` for 180 s (and the joiner dropped nine coordinator beacons, `mesh.groupKey.droppedUncommittedSlot` — Option 1b's gate observed live). DEBUG-only, app target, no env read added (`TestHookBoundaryTests` count unchanged), no persisted surface. Built (`xcodebuild build`, `** BUILD SUCCEEDED **`) before the second attempt. |
| 1 | The deletion — one coherent commit series | 0 PASS | **done** (verified, fixed) | **C1 `ec05b0c`** (the deletion) · **C2 `f9ea93c`** (the Edit 7 prose sweep) · **C4 `3de2d2b`** (the blind verify's 15 findings fixed; mesh line **1216 / 140 MEASURED**, floor 1214 → 1216) · **C3 `63418ce`** (the plan blob, index-only in the primary) | Acceptance met: `import MultipeerConnectivity` zero times under `FernletKit/Sources` and `App/`; no framework identifier in shipping code; the framework linked nowhere; `permittedFiles = []` with the wall kept and asserting zero; the tree green at every commit (C1: 471/27 + 39/6; C2: 185/12; C4: 176/12 + 23/3; the mesh line 1214/140 then 1216/140; no restart anywhere). Details: the work list re-anchored at HEAD by a blind Opus survey before any edit, whose four additions to the launcher's list were folded in (a hard compile break in `NetworkMeshWireTests`, a 16th bare import, a Power-of-10 allowlist entry, the harness banner's dead read). C1: the two files; Variant A (`MeshTransportKind`/`MeshTransportFactory`/`resolvedKind`/the env key/both MC conformances gone, `MeshTransportSession` + `MeshPeerChannel` kept for the fake); `MeshNetworkManager.init` → `NetworkMeshSession()`; `Info.plist` −2 (coach pair held); `MeshP9McRetirementAcceptanceTests` the zero-list; `NoTrackingBoundaryTests` friend pair live → retired; `MultipeerPeerTests` / `PeerIDArchiveWipeTests` / `MeshTransportErrorSurfacingTests` / `MeshMultipeerSessionIdentityTests` deleted (the cap identity ported; the ephemeral-identity invariant satisfied by construction); `MeshTransportSelectionTests` 12 → 8; the 16-file import sweep; `NearbyRangingSessionTests`' stand-in → `NSString`; the two needle lists kept, "vacuous by design"; `measuredSuiteNameCounts` 141 → 140 argued; the allowlist entry gone (density 0.775 / 0.68); docs (FileIndex 5 rows out + 1 rewritten; ProximityFunctionIndex's MC section out and its pre-existing `PeerHandle.swift / MCPeerIDStore.swift` heading error fixed; DocC 528 → 523; No-Tracking-Wall §4c; the runbook sentence; PrivacyWipeCoverage prose; `Package.swift` comments); `grep -rl MultipeerConnectivity Tests/` 34 → 16. C2: 36 files by an Opus agent + 2 by hand, comment-only by its own diff filter; shipping-tree MC mentions 105 → 99, all historical; nine outright falsehoods removed (listed in the commit). C4: see the verify findings below. |

## Blocked on owner
- Everything plan §28.4 carries. This round asks nothing new of the owner; the `_fernlet-coach` strings stay held (plan §18
  decision 4's default), and the `ConnectionSessionLog.transport.mcSessionState` FIELD stays spelled as it is (a persisted
  `Codable` token — see item 1's decisions).

## Decisions taken
| Decision | Choice | Taken on |
|---|---|---|
| Which node is the founder on an unseeded run | The **lower fingerprint** (`foundsPairwiseMesh` is `local < peer`): the harness's founder loop guards on `membershipVerifier == nil`, which is the yielder's exact state between `unwindNewbornMesh()` and the grant, so a founder role on the yielding half would race the shipping yield. On an unseeded run the roles are inert either way. | 2026-09-22 |
| How to "kill the tunnel between the two commits" | Freeze the joiner's process (`SIGSTOP` by saved PID) from a watcher on the founder's console at its `committing slot` line; let the founder's three-missed-beats rule end the tunnel (+90 s); `SIGCONT`. Not a relaunch: a relaunch changes the `sid` and the endpoint and so proves less about the re-dial. | 2026-09-22 |
| `ConnectionInspectorView`'s "MCSession" row | **Label renamed** to "Session state" (a bare `String`, not a catalog key — the inspector's pre-existing localization gap, unchanged); the **FIELD `mcSessionState` stays** (a persisted `Codable` token decoded from two stored fixtures). The in-file comment had said both would move together behind a decode-compat shim; a shim for a frozen key buys no user-visible value and adds a decode path to test, so the field keeps its historical spelling with the reason on it. Deviation from the cutover round's note, recorded here. | 2026-09-22 |
| The harness limitation run 2 found | **Fixed in the harness, not worked around** — the re-dialed slot's second commit is exactly what the driver stands in for. Keyed on `ObjectIdentifier(slot.coordinator)`, pruned to the live coordinators each poll. | 2026-09-22 |
| What the re-dial observation claims | **Real id vs `unbound`** at the re-dial (the joiner's pre-freeze commit never landed). The both-real-ids shape rides the same arm (`hello.meshID == localHello.meshID \|\| isProvisionalStranger` — the ids' values play no part) and stays tier-1 only; said so in the runbook rather than claimed. | 2026-09-22 |

## Verify findings
(one adversarial verify per item — implement → a verifier blind to the first's reasoning → fix)

**Item 0:** no code verify dispatched — the item is an observation, and its record names every token a reader can grep for
in the raw logs; the harness fix is eleven lines in a DEBUG file and is read by the deletion verify with the rest.

**Item 1 (`3eb1768` + `ec05b0c` + `f9ea93c`, verified as one series by a blind Opus verifier with the raw lane logs and the
launcher's acceptance criteria) — COMMIT WITH FIXES, 2 MEDIUM + 7 LOW + 6 NOTE; the deletion itself CLEAN (zero imports, no
linked framework anywhere — no pbxproj reference, no xcconfig, no `linkerSettings`; the plist and its three siblings right;
the one conformer; no code reader of the variable; both neutrality scans reddenable by replica; the three Bonjour sets partition
the plist identically in both suites; every deleted suite's invariant either still pinned on QUIC or pinning nothing that
exists; the 140 names all declared, the floor 1214 corroborated off the retained log; the allowlist and the scan clean; the
docs and the DocC inventory exact; every quoted token and number in the item 0 record but two matched the logs; both code
claims in the record true). **All 15 taken in the fix commit (C4):**
1. MEDIUM — the QUIC radio's OWN oversized-datagram DROP (`receiveDatagrams`, `mesh.quic.droppedOversizedDatagram`) and the
   outbound over-cap refusal in `send` were unpinned once the MC suite went; the three surviving wire cells exercise
   `NetworkMeshWire.payloadLength` only (the control-stream path, transitively). A `>=`, a doubled ceiling or a deleted guard
   stayed green. → `NetworkMeshSession.withinWireCeiling(_:)`, one predicate both directions ask at their guard; pinned as a
   VALUE (at-cap admits, one-over refuses) and the two call sites pinned by source needle, with an inline comparison forbidden.
2. MEDIUM — the item 0 harness fix claimed the prune-to-live-set made a freed coordinator's `ObjectIdentifier` unable to shadow
   a later one; it cannot — an identifier is an address, and a coordinator minted at a recycled address between polls would be
   skipped (the parked-at-the-gate failure, now probabilistic). → the table RETAINS its coordinators, so an entry's address
   cannot be recycled while the entry lives; the doc says so.
3. LOW — "0.3 ms apart" was 0.51 ms. → 0.5 ms.  4. LOW — "the same six variables" were five. → five.
5. LOW — two MEASURED annotations carried (kit 143 → 141 measured but 143 left in the sibling cell; app "179" was 185). → 141 / 185.
6. LOW — the seam's four retired identifiers were pinned OUT of one file only; a `MeshTransportKind` in a NEW file was
   invisible to every wall (Fernlet's own names). → the needles walk the whole package.
7. LOW — the `transport ?? NetworkMeshSession()` source pin was satisfiable by a trailing comment (`codeOnly` strips whole-line
   comments only). → a code-LINE check, the text before `//`.
8. LOW — No-Tracking-Wall §4c's QUIC row still named `MeshTransportFactory.shippingDefault` in a table about today. → reworded.
9. LOW — `TestHookBoundaryTests`' global annotation "68" was 67 after the family lost one. → 67.
10. NOTE — "zero `refused`" was contradicted by the joiner's `heartbeat datagram refused` line in the same cell. → "zero
    introduction refusals", the other line named.  11. NOTE — the parenthetical about B's pre-freeze commit ask was undecidable
    from the untimestamped console. → reworded to what the audit stream decides (no `keyAgreement.folded` before the thaw).
12. NOTE — `MultipeerServiceType.trainer` / `_fernlet-coach` confirmed dead in shipping (every `.trainer` caller is under
    `Tests/`), as plan §18 decision 4 records — the owner's, unchanged.  13. NOTE — `ProximityCoordinator.serviceType(for:)`
    still returns the literal `"fernlet-friend"` for `.friend`, inert only because both conformers' discovery doors are no-ops.
    → a comment at the site saying so.  14. NOTE — the DocC inventory's three dangling roots (``ProximityKit``,
    ``ProximityForegroundAnchor``, ``ProximityManagerDeallocationTests``) are pre-existing.  15. NOTE — the record's "Raw logs"
    paragraph listed `events.log` in run 1 (none; no freeze) and the banner token it quotes is the pre-deletion constant. → said.

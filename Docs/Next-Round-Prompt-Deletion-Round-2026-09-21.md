# Loop Prompt — the deletion round (MultipeerConnectivity leaves the tree), and the phase after it

**Written:** 2026-09-21, at the close of the cutover round (`main` = `96a8fab`: the stranger-admission path and the
MC→QUIC **flip are BUILT**, verified and fixed; the friend mesh ships on QUIC; MC is a DEBUG-only bisect path).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — §28.8 is the
cutover round's account, §17.1.2 deviation 1 the flip's status, §7.2 the amended reject bullet.
**Record of the round this follows:** [Docs/Mesh-Migration-Loop-Ledger-Cutover-2026-09-21.md](Mesh-Migration-Loop-Ledger-Cutover-2026-09-21.md)
(every SHA, three blind verifies' findings, the owner's D-4.3/D-4.4, the flip/gate/delete split).
**The design and its corrections:** [Docs/Mesh-Stranger-Admission-Design-2026-09-21.md](Mesh-Stranger-Admission-Design-2026-09-21.md)
(read the dated correction block before §2).
**The patches:** [Docs/Mesh-P9-Item4-Design-2026-09-20.md](Mesh-P9-Item4-Design-2026-09-20.md) — the survey's appendices are the
deletion round's work list: `Info.plist` (`:316`), `MeshTransportSelection.swift` **Variant A** (`:632`),
`TransportNeutralityBoundaryTests.swift` (`:812`), docs (`:936`), tests (`:1115`); `MeshNetworkManager.swift` (`:406`) only Edit 1
now — Edits 2–7 were taken by the cutover round (re-applying 5/6 would UNDO the admission work). Re-anchor by text; the survey's
line numbers are from `ba34491`.
**Memory:** `cutover-round-2026-09-21`, `catalog-commit-under-held-working-copy`, `merge-worktree-branch-into-main`, `prefer-opus-subagents`.

---

## Item 0 — the gate: observe the flip unseeded before deleting the radio it replaced

The QUIC first-meeting capability the cutover round built has **never been observed on any radio**. Run the runbook's Lane C
pair (`Docs/Mesh-Network-Feasibility-Runbook.md`, Lane C, with its four **Corrected 2026-09-21 (D-4.3)** notes) with
**no** `FERNLET_MESH_MATRIX_MEMBERS` and no seeded descriptor, `FERNLET_MESH_ROLE=founder|joiner`, two Simulators, and
record — dated, in the runbook's Lane C table and in plan §28.8 — that two mesh-less Simulators found a mesh through the
provisional path over a real QUIC tunnel: `admitsStrangersProvisionally` answering at the introduction, the identity
introduction, the dwell/tap commit, `promoteToMesh`, the descriptor, the admission request auto-granted, `derived=2` on
both. Then the double-mint re-dial (kill the tunnel between the two commits; both must re-introduce under the tolerated
meshID). **If either fails, that is stop condition 3 — record it, do not delete.** Rebuild before the lane; kill audit
streams by saved PID; a Simulator up for hours stops rendering (erase + reboot).

## Item 1 — the deletion (one coherent commit series; flip first was the rule, and the flip is done)

1. **Delete** `FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift` and `MCPeerIDStore.swift`. Apply the
   survey's `MeshTransportSelection.swift` **Variant A** (`MeshTransportKind`, `MeshTransportFactory`, `resolvedKind`,
   `quicSelectionEnvironmentKey` and the MC conformance go; the surviving extension's three MC comments re-tensed); the
   `MeshNetworkManager.init` default becomes `NetworkMeshSession()` (Edit 1). `FERNLET_MESH_TRANSPORT` retires — the
   `TestHookBoundaryTests` `FERNLET_MESH` family floor is 7 against ~18 lines; the Lane C recipes keep the variable as an
   inert no-op for bisects (the runbook says so).
2. **The pins, in the SAME commit as the deletion** (or the tree is red): `TransportNeutralityBoundaryTests.permittedFiles`
   → `[]`, suite kept, docs per the appendix (`everyFloorFileIsStillCovered` asserts each permitted path EXISTS; read
   `floorFiles` too). `MeshP9McRetirementAcceptanceTests` (`Tests/FernletTests/MeshP9AcceptanceTests.swift:894`+) flips its
   deletion-round VALUES (the two files' absence, the two-homes import walk → zero, `_fernlet-friend` ABSENT — it pins
   PRESENT today, with the bisect reason). `App/Fernlet/Info.plist`: drop `_fernlet-friend._tcp`/`._udp`; keep
   `_fernlet-coach._{tcp,udp}` (plan §18 decision 4's default, an owner call not this round's); keep all three QUIC types.
3. **Tests** (the survey's tests appendix, re-anchored): delete `MultipeerPeerTests.swift` and `PeerIDArchiveWipeTests.swift`
   (D-4.4 was pure retire, so nothing to rewrite); delete `MeshTransportErrorSurfacingTests.swift` **only after** confirming
   `NetworkMeshTransportTests` already carries the two `maxInboundWireBytes` cap cells, else port them first; delete
   `MeshMultipeerSessionIdentityTests` from `PeerTransportNeutralityTests.swift` (record its ephemeral-identity invariant as
   satisfied by construction); `MeshTransportSelectionTests` loses `everyTransportKindBuildsItsOwnRadio` and
   `theMultipeerRadioIgnoresTheAuthorityWithoutIncident` and the DEBUG-selectable cell; the 15-file bare-import sweep;
   `NearbyRangingSessionTests`' `MCPeerID` archiver stand-in → `NSString`; `ProximityRecipeShareCapTests`' comments; the two
   needle lists (`PresenceOverQUICTests:~652`, `RecipeShareOverQUICTests:~926`) stay, with a one-line comment that they are
   now vacuous by design. Re-measure `grep -rl MultipeerConnectivity Tests/` before and after (34 at the P10 boundary).
4. **CI pins, in the commits that move names:** every deleted suite is a name LEAVING a line — LOWER
   `measuredSuiteNameCounts` in `CIGateSelectorBoundaryTests` deliberately, with the retirement argued (mesh-batteries is
   **141 names / floor 1222**, s3-grep 7, battery pin 58); re-measure the mesh line exactly as CI runs it and set the floor
   to the number. `Scripts/power-of-10-scan.py`'s assertion-density floor moves when 718 lines of `guard`-bearing code go —
   re-run it and check `Scripts/power-of-10-allowlist.json` for an entry naming either file.
5. **Docs and plan** (the survey's docs appendix, minus the D-4.4 rows): `Docs/FileIndex.md` (the two rows deleted, the
   `MeshTransportSelection.swift` row rewritten), `Docs/ProximityFunctionIndex.md` (the `MeshMultipeerSession` section; the
   pre-existing `PeerHandle.swift`/`MCPeerIDStore.swift` heading error — say it was pre-existing), the DocC `ProximityKit.md`
   symbol bullets (`MCPeerIDStoring`, `FileMCPeerIDStore`, `MeshTransportKind`, `MeshTransportFactory` — **there is no DocC
   build in this repo**: count the ``symbol`` inventory before/after and remove exactly the deleted names),
   `Docs/No-Tracking-Wall.md` §4c (the row goes; the coach pair moves to the "declared but unused" note), the runbook's
   Lane C sentence, and the plan as an index-only blob: §17.1 fully BUILT, §17.1.2 deviation 1 closed, §26.3's deletion
   paragraph, §6 finding 8, the §28.3 row. Then the **Edit 7 prose sweep** — 29 files / ~71 MC mentions, present → past;
   `MeshMultipeerSession.swift:98-99`'s stale presence claim dies with the file.
6. **Owed hardenings the cutover round surfaced, priced here, taken if cheap:** `recordError(domain:)` labels are unlocalized
   display strings across the inspector (a `LocalizationBoundaryTests` gap); `MeshLinkTable.links` is never evicted by the
   cache eviction (only the counters are); the wipe wall pins that `wipeIdentityForDeleteAll` exists and is called, never
   what it does; `accepted`/`datagramCapacity` were never peer-derived (closed as misdescribed, nothing to do).

## The rules that still apply

Three adversarial dispatches per item (implement → a verifier blind to the first's reasoning, model `opus` → fix) — every verify
in P8–P10 and all three in the cutover round found something real (one HIGH each in the last two). Work in a git worktree of
your own; the primary checkout holds the plan, `Localizable.xcstrings` and several `Docs/*.md` uncommitted — plan edits land
in the primary as **index-only blobs** (`git hash-object -w` in the worktree, `git update-index --cacheinfo` in the primary,
`diff --cached --name-only` must list ONLY the plan, commit with no pathspec, then `checkout --` the plan in the worktree and
`merge --ff-only main`); fast-forward main after each item with `git -C <primary> merge --ff-only <branch>`; commit by explicit
pathspec. Build every commit; name the STRUCT in `-only-testing`, never the file, quote every selector; green only with `✔ Suite
<Struct> passed` and `Test run with N tests in M suites passed`; never a total from a log carrying `Restarting after unexpected
exit`; one `xcodebuild` at a time (`pgrep -x xcodebuild`), output to a log, grep the markers; **NO full-suite runs**; every
new or changed cell shown red once; the `iPhone 17` Simulator is `09F57BCA-DF29-4E43-9E06-E363AE688A88` (check Booted). No new
`UserDefaults` key or persisted surface without a `Docs/PrivacyWipeCoverage.md` row and delete-all wiring in the same commit.
An enum/struct change needs ONE clean build (incremental builds hide non-exhaustive switches). A design's mechanism sentence
must name the SUBSCRIBER of a seam, not the hook (the cutover round's lesson). **Do not touch the owner's phone**: §15.5's
overnight recorders may still be running (runbook Lane E, *How to resume*; the state is that session's `p10dev/STATE.md`).

## Stop conditions

1. **Item 0 observed and item 1 landed and gated** — `import MultipeerConnectivity` zero times under `FernletKit/Sources` and
   `App/`, the tree green with `permittedFiles` empty, the plan and the ledger updated, the round's own ledger written.
2. **Item 0 fails** — the provisional path does not found a mesh on a real tunnel, or the double-mint re-dial deadlocks: record
   it in the runbook and plan §28.8, stop, report; that is a design change, not a bug to fix in flight, and MC stays.
3. **A wall that cannot be satisfied without a design change** — record, stop, report.
4. **Budget or context running low** — stop with the record in the plan and the ledger.

---

## The phase after this one — the owner's, not a launcher's

The plan's phases are spent (§28). After the deletion round what remains is **the device round** (entry condition A of
[Next-Round-Prompt-Device-Round-2026-09-21.md](Next-Round-Prompt-Device-Round-2026-09-21.md), now to be run on the CUTOVER
build): §15.5's overnight window read back (`p10dev/run2/device-console.log`: a grant shows as `companionRefresh.submitted
trigger=handle` then `runFinished`), §15.1's radio matrix (two phones), §15.2's partition walks (three, four for topology),
§15.3's 3 h / 6 h soak **that decides the degraded ladder**, §15.4 Wi-Fi Aware bounded to two days, P9-2-C's boundary-wake drift,
and Lane D's founder/joiner shape **unseeded** on hardware — the first meeting between two phones that have never met, on the
radio that now ships. And the product calls the cutover round left to the owner: Option 1b's name deferral (a bystander with the
doors open learns the display name, as on MC), Option 2's two-scan QR pre-admission, P9-3-A, the `_fernlet-coach` strings,
the degraded ladder. A round that opens and finds only owner items should say so in one page and stop.

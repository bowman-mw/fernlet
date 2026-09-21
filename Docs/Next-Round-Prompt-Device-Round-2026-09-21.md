# Loop Prompt — the device round, or the MC cutover, whichever the owner unblocks first

**Written:** 2026-09-21, at the P10 boundary (`main` = the P10 close-out; **P10 is BUILT at tier 1 and
1b**, its tier 2 is measured **negative**, and its grant is a device row).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. **§17.2** is what P10 built;
**§15 + §15.5** are the unpaid gates; **§28** is the handoff and the reason this is one page.
**This is not an eleventh phase.** After P10 the plan's phases are spent; what is left is the owner's —
two to four phones, the stranger-admission design, the product calls. **A round that opens and finds
nothing but owner items should say so in one page and stop.**

---

## The two entry conditions — take ONE; if neither holds, write the one-page "still blocked" note and stop

### A. Phones are in hand → the device round

Cheapest first. **Install the private-data logging profile before anything else**, or every
`FernletAuditLog` context comes back `<private>` and the rows you most need are the ones you cannot
read (§17.2.3 finding 2).

1. **Lane D** — the production transport, phone ↔ Simulator, cable out (device row F11). One phone;
   the cheapest first run — **RUN 2026-09-21** (runbook *Lane D*: every row dated; the NECP `EEXIST` is
   present and non-fatal; routed text/photo need `FERNLET_MESH_ROLE=founder|joiner` + `FLOWS_AFTER`).
2. **§15.5, P10's eight rows** — one phone. D1 and D2 come together (background the app and leave the
   phone alone); D5 and D6 are two Settings toggles; D3, D4, D7 and D8 fall out of D2 once a grant
   happens at all. **FIRST ATTEMPT 2026-09-21** (runbook *Lane E* § *Device run*; plan §28.7): D7 earned, D4
   and D6 half, D5 blocked by the phone's policy, D1–D3/D8 not reached — no grant in 1 h 55 min. The rest is
   an **overnight** window from the runbook's *How to resume*; the logging profile is refused by iOS 26.6.1
   (owner decision), and `OS_ACTIVITY_DT_MODE=YES` covers every devicectl-launched row instead.
3. **§15.1** radio matrix — a QUIC connection surviving background + lock, re-dial via a cached
   endpoint while backgrounded, a fresh background browse (expected to fail — record it), each ×
   infra-Wi-Fi and AWDL, Low Power Mode both ways, memory-pressure kills. Rows F1–F6. Two phones.
4. **§15.2** partition walks (three phones, four for topology), then **§15.3** the 3 h / 6 h soak —
   **that row decides the degraded ladder**, unchosen until it runs.
5. **P9-2-C** the boundary-wake drift on hardware; **§15.4** Wi-Fi Aware, bounded to two days, a
   recommendation not a dependency.

**Walls that bite here:** cables out for every background or lock row, then check no ready line names
`en8` / `en9` / `anpi0`. Rebuild before every lane run — a build log's date is not the tree's date.
Kill audit streams **by saved PID**, never `pkill -f "log stream"`. Capture `subsystem ==
"com.apple.BackgroundTasks"` beside `com.fernlet` — a second, independent witness. A DEBUG build no
longer crashes on exactly these rows (P9's `assertionFailure` sweep, `dad86e9`), which is what made
them runnable. **Do not re-run Lane E on a Simulator** — its verdict is recorded with its evidence
(`Docs/Mesh-Network-Feasibility-Runbook.md:2375`).

### B. The owner says D-4.3 → the MC→QUIC cutover

The survey, the decision and the **ready patches** are
[Docs/Mesh-P9-Item4-Design-2026-09-20.md](Mesh-P9-Item4-Design-2026-09-20.md) — seven appendices,
`Appendix A` the rule-7 cell (`:155`) and six anchored patches from `:316`, every hunk `[SPLIT:
LATER]`. Nothing in it is stale; it has been waiting on a person, not on code.
**DESIGN WRITTEN 2026-09-21** — `Docs/Mesh-Stranger-Admission-Design-2026-09-21.md` (plan §28.8): D-4.3 redefined as "cut over WITH provisional stranger admission" and ASKED; the three one-liners of §28.1/§28.4 are taken (`97d1bd9`, `737399c`, `b4cd1ac`). **The prerequisite is a design, not a patch.** `MeshTransportFactory.shippingDefault` is `.multipeer`
(`FernletKit/Sources/ProximityKit/Transport/MeshTransportSelection.swift:267`) and QUIC refuses a
stranger before any app frame (§8.7 finding 3), so cutting over without a first-meeting
stranger-admission path **ships a build where two phones that have never met cannot found a mesh**.

**Walls that bite here:** `MeshP9McRetirementAcceptanceTests`
(`Tests/FernletTests/MeshP9AcceptanceTests.swift:894`) pins today's truth as VALUES, so the cutover
commit must edit it in the same breath. **D-4.4** rides along — the `MCPeerIDStore` wipe row becomes a
legacy `FileManager` sweep, because `FernletPeerID.archive` survives on any pre-P9 install.
`TransportNeutralityBoundaryTests`' permit list (`:32`) is **not** the inventory: its scan roots
(`:21`) are `FernletKit/Sources/ProximityKit` + `App/Fernlet` and never saw `Tests/`, where the
plan records **32** files naming MC (§17.1.1) — `grep -rl MultipeerConnectivity Tests/` reports **34**
at this boundary. **Re-measure before the cutover.**

---

## The rules that still apply

Build every commit. Every wall shown **red once** — disable the guard, **rebuild**, run, keep the log,
restore the exact text, **rebuild** again. Name the **struct**, never the file:
`-only-testing:FernletTests/<FileName>` runs zero tests and reports green. Raise a
`measuredSuiteNameCounts` entry in the same commit that adds names (the pin is `>=`; it catches a
removal, never an addition) — at this boundary mesh-batteries is **140 names / floor 1198**
(`.github/workflows/s3-wall.yml:584`), battery pin **58**
(`Tests/FernletTests/CIGateSelectorBoundaryTests.swift:236`). Never take a total from a log carrying
`Restarting after unexpected exit, crash, or test timeout`. `Scripts/spm-wall-check.sh` runs **last**
and leaves no `FernletTests.xctest` behind, so expect a `build-for-testing` after it. **No full-suite
runs** — the owner's standing instruction since P8 item 0; the last measured one is P8's **5 055 /
513**. Three adversarial dispatches per item (implement → a verifier blind to the first's reasoning →
fix): **every verify in P8, P9 and P10 found something real.** **No known red is on the board:** the
mesh-batteries line is green at **1198 tests in 140 suites** (`da3bac1`). The one red item 9 met was
a latent TEST defect, not an environment — `LocalizedStringKey ==` on an interpolated key is not a
value comparison and flips with codegen of unrelated source in the same module; compare
`String(describing:)` (§17.2.3 finding 9).

---

## Stop conditions

1. **The chosen entry condition is done** — rows in the runbook with dates, §15 / §15.5 statuses moved,
   plan and ledger updated.
2. **Neither entry condition holds** — say so in one page, name what is needed, stop. Do not open a
   phase to fill the space.
3. **A device row fails in a way that changes the design** (the soak ends the task, a grant never
   comes) — record it, stop, report. The degraded ladder's trigger, not a bug to fix in flight.
4. **Budget or context is running low** — stop with rows to spare; the runbook is the state.

# Loop Prompt — the owner's calls, built (Option 1b's name deferral; P9-3-A made to work)

**Written:** 2026-09-22, the evening of the device round (`main` = the device round's decisions commit).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) —
§28.3 carries the five calls as TAKEN, §28.9 the round that asked them. The design is
[Docs/Mesh-Stranger-Admission-Design-2026-09-21.md](Mesh-Stranger-Admission-Design-2026-09-21.md) § *Option 1b*.
The record to read first is [Docs/Mesh-Migration-Loop-Ledger-Device-2026-09-22.md](Mesh-Migration-Loop-Ledger-Device-2026-09-22.md)
(item 3, the decisions table, item 4's continuation grant).
**Not a phase.** Two build items the owner decided, plus the soak's read-out if it has not been read.

---

## Entry condition

The 6 h soak of 2026-09-22 has been **read out** (the session scratch `soak/` of the device round — `readout.sh`, then the
runbook's *Lane B* *Progress soak* row and plan §15.3 with dates, the degraded ladder chosen by its numbers). If it has not,
that is item 0 and it comes first: it runs on the observed build, and the two build items below change the tree.

## Items, in order (each: implement → a blind Opus verifier → fix; build every commit; no full-suite runs; name STRUCTS in `-only-testing`)

0. **The soak's read-out** if still owed (above). The ladder's rung goes into plan §14 / §15.3 and the runbook's Lane B.
1. **P9-3-A — make it work.** A configured Fernlet Lock at rest (`FernletLockState.locked`) parks the presence and recipe-share
   radios permanently because `ProximityRunPolicy.presenceState` / `recipeShareState` guard on `!input.appLockEngaged`
   (`App/Fernlet/ProximityRunPolicy.swift:476`, `:487`) and the projection (`:340`) is `true` for `.locked`. The mesh row
   (`:424`) has no such leg. The recommendation the owner took: **drop the leg from the two rows and retire
   `Input.appLockEngaged` with its projection** — a scoped lock protects the Private tab, the progress photos and the lock
   settings, not a radio. That re-pins `ProximityRunPolicyTests`' product count (23 040 → the enums' new product) and
   `MeshP7AcceptanceTests`' run-policy clause (all rows, flat re-statements), and retires every `appLockEngaged` feed
   (`grep -rn appLockEngaged App/ FernletKit/ Tests/`). Show the change red once: the P7 clause must fail on the old table.
   No persisted surface. The runbook's *Lane C — P9 item 3* finding and plan §17.1.3 finding 1 get a dated "FIXED".
2. **Option 1b's name deferral — withhold the display name until commit.** Today the identity introduction carries the local
   display name before commit (design § *Option 1*, the trust paragraph). Build: the introduction sent **without** the display
   name while the slot is provisional; the name delivered on `.connected` (a small frame on the control stream, or the
   existing capabilities exchange if it already crosses at commit — read the reader first, §28.5's rule: name the
   SUBSCRIBER, not the hook); a coordinator state for the deferred name; the join screen showing the fingerprint until the
   15 cm dwell or the tap (the `.awaitingManualCommit` / `.awaitingProximityCommit` branches of `ConnectView`); a
   `ProximityCoordinatorTests` row; a wire golden if the introduction's shape changes (`MeshChannelIntroduction`); a Lane C
   pair run showing `peer=<fingerprint>` before commit and the name after; the localization wall for any new string.
   Threat model unchanged otherwise — Option 1's mechanism, bounds and tests stay.
3. **Optional, if budget remains — the three priced hardenings** (ledger item 3's table): `recordError(domain:)` typed
   domain (six call sites), the `MeshLinkTable.links` eviction leg, the wipe-effect value tests ×3.

## Walls that bite

Every wall red once; raise `measuredSuiteNameCounts` in the same commit that adds a mesh-battery suite; the mesh-batteries
line is **140 names / floor 1216** at this boundary. An enum/struct change needs ONE clean build. The primary checkout holds
the plan uncommitted — plan edits land as index-only blobs. The phone is not needed for items 1–3; if item 0 is owed, the
soak's build must be the observed one (`d88062c`'s code, i.e. anything before item 1 lands).

## Stop conditions

1. Items 1 and 2 built, verified, gated; item 0 read out; the ledger closed.
2. The soak is still running or unread and the owner says to wait — record, stop.
3. Budget or context low — stop with the record.

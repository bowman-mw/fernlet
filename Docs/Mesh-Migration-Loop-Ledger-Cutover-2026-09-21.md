# Mesh Migration Loop Ledger — the cutover round (P10's one-liners, then the MC→QUIC cutover)

**Round:** not a phase — plan §28 says the phases are spent. Entry condition **B** of
[Next-Round-Prompt-Device-Round-2026-09-21.md](Next-Round-Prompt-Device-Round-2026-09-21.md) (the owner's D-4.3), preceded by
the three one-liners P10 named and did not take (plan §28.1 "the residuals P10 leaves", §28.4).
**Started:** 2026-09-21 · **Closed:** open · **Tree at seed:** `main` = `0702fc9` (§15.5/§28.7 as an index-only blob on
`fa7de83`), 2 ahead of `origin/main` (`0a85e06`), not pushed.
**Worktree:** `.claude/worktrees/serene-banach-374c4e` on `claude/affectionate-hugle-58faac`; main fast-forwarded after each
item (`git -C <primary> merge --ff-only`); plan edits land in the primary as index-only blobs
(the primary's working copy of the plan is held).
**Entry condition A's item 2 (§15.5)** is parked on the owner's phone for its overnight window and is NOT touched by this
round — the runbook's Lane E *How to resume* is where it continues.

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`.
| # | Item | Prereq | State | SHA | Note |
|---|---|---|---|---|---|
| 2a | Pin CI's Simulator device (`s3-wall.yml` "Resolve a simulator destination": hard failure, no fallback) + the reading cell in `CIGateSelectorBoundaryTests` | — | done | `97d1bd9` | plan §17.2.3 finding 6, §28.3 "three UI residuals" |
| 2b | `@Suite(.serialized)` on `AppIntentsTests` | — | done | `737399c` | plan §17.2.3 finding 5 |
| 2c | A refused registration no longer spends the edge budget (`CompanionRefreshCoordinator.appDidEnterBackground` charges AFTER `submitNext` reports the ask reached the seam) + the cell | — | done | `b4cd1ac` | plan §17.2.3 finding 3 |
| 1.1 | Stranger-admission DESIGN for the owner (`Docs/Mesh-Stranger-Admission-Design-2026-09-21.md`), D-4.3 asked with D-4.4 | 2 | done (asked) | record commit | written, blind-verified (20 findings, all taken — see below), D-4.3 REDEFINED and asked; STOPPED for the owner's answer |
| 1.2 | The admission path (Option 1 + 1b's gating half) with its tests | D-4.3 taken | in-flight | | Opus implementer in this worktree → blind verify → fix |
| 1.3 | The flip: `shippingDefault` → `.quic`, `MeshP9McRetirementAcceptanceTests` values, `MeshNetworkManager.swift` edits 1–7 (Edit 4 pure-retire, D-4.4), docs/plan rows, pins raised, mesh line re-measured | 1.2 | todo | | MC files, plist strings, permit list, test sweep = the deletion round |

## Blocked on owner
- **D-4.3** (with **D-4.4**): the cutover, on the stranger-admission design's recommendation.
- Everything plan §28.4 carries, less the two one-liners this round takes (the private-data logging profile remains).

## Decisions taken
| Decision | Choice | Taken on |
|---|---|---|
| Where the edge budget is charged | AFTER the ask, only for one that reached the seam (a refused submission still counts; an unregistered edge does not) — the header's rationale ("bounds a pathological edge storm of refused submissions") stays true, and `edgeSubmissions <= submissions` becomes an invariant | 2026-09-21 |
| The CI device | pinned by name, hard failure, no fallback; the cell also pins the two scripts' defaults and the UI probe's text to the same destination string | 2026-09-21 |
| **D-4.3** (the owner, asked via the design's §5) | **TAKEN — Option 1**: cut the friend mesh over to QUIC with provisional stranger admission while the join doors are open, membership at the existing three doors, plan §7.2's "non-roster member" bullet amended, §15 still undated; plus Option 1b's frame-gating half (group-key family + vouch list gated on commit). 1b's name deferral and Option 2 NOT taken. | 2026-09-21 |
| **D-4.4** (the owner, asked with D-4.3) | **PURE RETIRE** — the owner chose against the design's recommendation (the legacy `FileManager` sweep): the archive leg of `wipeIdentityForDeleteAll` and the `PrivacyWipeCoverage.md` row retire with a prose note; a pre-P9 install's `FernletPeerID.archive` is left behind by delete-all. Cost recorded: the only install (the owner's phone) has run pre-P9 builds and holds the file until a reinstall. | 2026-09-21 |
| The series' split (this round vs the deletion round) | **Flip, gate, then delete** (the launcher's rule): this round = the admission path + `shippingDefault` `.multipeer` → `.quic` + `MeshP9McRetirementAcceptanceTests` values + the `MeshNetworkManager.swift`/docs/plan edits + D-4.4's pure retire; the **deletion round** = the two MC files, the `_fernlet-friend` plist strings (a DEBUG `FERNLET_MESH_TRANSPORT=multipeer` bisect path stays alive until then), the permit list, the 34 test files' sweep. | 2026-09-21 |

## Verify findings
(one adversarial verify per item — implement → a verifier blind to the first's reasoning → fix; every verify in P8–P10 found something real, and so did these)

**Item 2 (the three one-liners, verified as one diff, `97d1bd9`+`737399c`+`b4cd1ac`) — COMMIT WITH FIXES, 7 findings + 3 notes, fixed in `18dd46a`:**
1. MEDIUM — the plan still records §17.2.3 findings 3/5/6 as unfixed, and finding 6's citation (`s3-wall.yml:106–:120`) is stale (the step is at `:119–:131` now). → the plan blob marks them FIXED with the SHAs and re-points the range.
2. MEDIUM — `stepBody` reads the FIRST step of a name and the cell never pinned uniqueness: a second `- name: Resolve a simulator destination` carrying a fallback was green (simulated). → the cell pins exactly one declaration; shown red once by planting a duplicate step.
3. LOW — `!step.lowercased().contains("fallback")` was a false-red risk (a trailing `# …` comment on a code line, or a future error message using the word — the current message's wording was load-bearing and undocumented). → replaced by the invariant the fix actually established: `name` is assigned exactly once, to the literal; the `::warning::` check stays; the message's wording is free.
4. LOW — two comments (the workflow's, the cell's doc) said the ratchet "fails in both directions on any other device" — that is the PRE-guard failure mode; since 2026-09-20 `isOnBaselineEnvironment` refuses to run the ratchet at all off-baseline. → corrected in both places.
5. LOW — the holders check greps whole files, so the doc's "the UI probe's own failure text" overclaimed (the string appears twice in `UXScreenProbe.swift`). → doc softened to "its source names it".
6. LOW — three `Docs/FileIndex.md` rows behind the file's own convention. → six rows revised (this commit).
7. LOW — the mesh-batteries floor narrative one behind: `CIGateSelectorBoundaryTests` is on that line and gained a cell, so the line runs 1199 at floor 1198 (green, `>=`). → floor RAISED 1198 → 1199 and MEASURED over the exact 140-name list on this Mac before the commit.
8. NOTE — one deliberate behaviour delta beyond the finding: an unregistered launch says `submitWithoutARegistration` on every edge, not sixty-four of them (person-bounded; the uncapped `edgeFoundARequestAlreadyPending` set the precedent). → said in the code comment.
9. NOTE — `edgeSubmissions <= submissions` holds; the cap guard reads the counter before the ask, so a synchronously-delivering scheduler re-entering the method could overshoot by its depth — none exists (the system seam is a straight `submit`; the fake records or throws). → said in the code comment.
10. NOTE — a step written `- id:` first or with a quoted name reads as MISSING (safe direction, misleading message). → the message says so.
Clean: finding 3's every caller/reader traced (11 sites; no expectation weakened); `.serialized` on a `final class` valid and serializes the suite's own cells; `topLevelTypeName` still parses the declaration; YAML loads; the `::error::` quoting is sound under `set -euo pipefail`; no needle of the 84 tripped; Power of 10 / ML1 untouched; every workflow consumer parses byte-identically; no pinned NAME count moves (an `#expect`, not a `@Test`, in the P10 battery); no wipe row owed; the pre-push hook claim is accurate (`Scripts/git-hooks/pre-push:79`).

**Item 1.1 (the stranger-admission design) — HAND WITH CORRECTIONS, 5 HIGH + 8 MEDIUM + 7 LOW, all taken in the same file before hand-off:**
1. HIGH — the draft's central hop did not exist: `onPeerVerified` has NO subscriber (`NetworkMeshSession.swift:376`, fired `:1458`; `wire(_:)` forwards five handlers, `MeshTransportHandlers` has no verified-peer member), so a `.provisional` field on `MeshVerifiedPeer` would have had no reader and reaching the manager would have been a transport-seam change `TransportNeutralityBoundaryTests` polices. → the verdict is transport-local; the manager reads nothing; the seat gate at the identity introduction is the stage, as for MC; no `MeshVerifiedPeer` field.
2. HIGH — Option 1 sends the local display name and three keys to any nearby dialer before any commit (`handleChannelReady` builds the coordinator with `displayName`, `:11376`; friend mode sends the intro immediately, `ProximityCoordinator.swift:644-647`; `maySeatVerifiedPeer` runs after and returns true on a first meeting, `:1206`) and the draft's "what it does not give" list omitted it. → stated as the delta the decision turns on; MC does the same today, QUIC did not.
3. HIGH — the target-mesh rule was not expressible: `MeshIntroductionAuthority.meshID` is peer-less (`:14775`) and the responder's hello is frozen before it hears the dialer's (`introduce()` builds the exchange with a `let localHello`, `:1916-1919`, `MeshChannelIntroduction.swift:437`, then `exchangeHellos`). → re-sized as three arms (session join target; mesh-less-dials dial-policy arm OR an exchange restructure; newborn arm), the largest piece of Option 1.
4. HIGH — the double mint is a `.foreignMesh` DEADLOCK on QUIC: both halves found with their own `UUID()` (`:11507-11512`, `:11633`); if the tunnel drops before `yieldsNewbornMesh` converges them, `receive`'s unconditional meshID equality refuses every re-dial for the session — a regression against MC, which has no meshID check. → the newborn arm (c) of the rule.
5. HIGH — the §7.2 rebuttal answered a sentence §7.2 does not contain ("degraded accept" is a code gloss); §7.2's bullet lists "non-roster member" as a reject condition verbatim (plan `:462`). → quoted; Option 1 AMENDS it (tunnel, not roster); the plan edit is an owed patch.
6. MEDIUM — the plan's own sketch, "a bounded pre-admission channel" (§8.7 finding 3, `:965-973`), was never engaged. → Option 1b: gate the group-key family + vouch list on commit (pure hardening, taken in the series) and withhold the display name until commit (a join-screen product call, left to the owner).
7. MEDIUM — "the same narrow set (`.meshAdmissionRequest` and the identity introduction)" was false: an uncommitted slot also reaches `.meshAdmissionGrant` (`:2807-2814`), `.verifyChallenge`/`.verifyResponse` (`:2743-2748`), `.meshFriendVouchList` (`:2751-2756`) and the whole group-key family with NO fingerprint guard at dispatch (`:2759-2760`, `:10708-10750`). → the real list, in §1's table.
8. MEDIUM — the provisional-slot deadline exists and the draft pointed at an enum case and a re-propose budget: it is `timeoutSeconds: isProximityJoin ? 25 : 60` (`:11377`) → `armTimeoutIfNeeded` (`ProximityCoordinator.swift:1561-1583`) → the stale sweep (`:14102-14106`). → replaced.
9. MEDIUM — slot/re-dial exhaustion missing: `maxTotalSlots 5`/`6` (`:517-518`), `maxPendingInboundTunnels 8` (`NetworkMeshSession.swift:334`), and `maxReproposalsPerEndpoint = 6` NEVER reset (`MeshLinkTable.swift:329-355`) — a provisional peer evicted by the seat gate or the timeout burns it, stranding a genuine friend after six. → named; the implementation must charge it for owner refusals only.
10. MEDIUM — D-4.2 dropped and D-4.3 silently redefined. → D-4.2 restored in §5; the redefinition said out loud.
11. MEDIUM — "§15 has dates" is D-4.1's other condition and was a table cell. → promoted to a named, undischarged blocker in §4 and the decision sentence.
12. MEDIUM — the authority has six members, not five (the "kept to five" comment at `:576` is stale). 13. MEDIUM — a one-way scan is not impossible on v1: the hello nonce is the QR's width and checked only for inequality/freshness — a policy change, not a wire change. → corrected, still not recommended.
14–20. LOW — six anchors wrong or weaker than the claim (`ProximityCoordinator.swift:1011` blank / `:1601` an enum case; `:243-259` the doc, decl `:260`; `ConnectView.swift:1292` and UWB devices never see the QR branch; the runbook phrase at `:1294-1295`; `:33`/`:79-81` for the nonce; SEVEN checks not eight). → swept.
Clean: every MC-posture anchor, every QUIC-path anchor, the three doors, `holdCommittedLinks` closing the provisional path (`:2135-2163`), no auto-grant for a provisional peer riding another's slot, `.barred` precedence, `browsed peers=` at `.public` (`:1056`), Option 2's primitive claims.

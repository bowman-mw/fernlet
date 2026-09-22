# Mesh Migration Loop Ledger — the device round (the deletion build on hardware)

**Round:** not a phase — plan §28 says the phases are spent. The launcher is
[Next-Round-Prompt-Device-Round-2026-09-21.md](Next-Round-Prompt-Device-Round-2026-09-21.md), entry condition **A**, run
on the DELETION build as [Next-Round-Prompt-Deletion-Round-2026-09-21.md](Next-Round-Prompt-Deletion-Round-2026-09-21.md)
§ *The phase after this one* says; the round it follows is
[Mesh-Migration-Loop-Ledger-Deletion-2026-09-22.md](Mesh-Migration-Loop-Ledger-Deletion-2026-09-22.md).
**Started:** 2026-09-22 15:10Z · **Closed:** 2026-09-22 (stop condition 1 as far as one phone allows: items 0 and 1 run
and recorded, item 2's rows named, item 3's page written, the blind verify's 24 findings fixed, this ledger closed).
**Tree at seed:** `main` = `d88062c` (the deletion round's close). **`origin/main` = `d88062c` too** — the owner had pushed
the 37 commits the handoff called unpushed; verified with `git rev-list --count origin/main..main` = 0 at 15:10Z.
**Worktree:** `.claude/worktrees/vigilant-sinoussi-a14e32` on `claude/vigilant-sinoussi-a14e32`; main fast-forwarded after
each item (`git -C <primary> merge --ff-only`); plan edits land in the primary as index-only blobs (the primary's working
copy of the plan is held). **Phone:** the owner's iPhone 17 Pro Max (iOS 26.6.1, fp `5c73ce4c29dc84be`), the only phone
in hand; connected over Wi-Fi (`transportType: localNetwork`), cable out.

## Entry conditions — both checked before any work
| Condition | Found | How |
|---|---|---|
| **A** — the iPhone 17 Pro Max connected; a second phone for §15.1/§15.2 | **Half**: the one phone `connected` (`xcrun devicectl list devices`), **no second phone** anywhere on the Mac | `devicectl list devices` shows one device; §15.1/§15.2 rows are therefore named unreachable (item 2), never inferred |
| **B** — §15.5's overnight window finished or handed over; no prior recorders attached | **Finished on its own**: `pgrep -fl xctrace` and `pgrep -fl devicectl` both empty at 15:10Z; the 2026-09-21 session's `p10dev/` scratchpad read as it stood — its console session had ended with *connection invalidated* at ≈20:39Z and its chunk chain with *Timed out waiting for device to boot* from 20:39:39Z | Nothing touched the phone until this was known; the first phone command of the day was `devicectl device info details` at 15:10Z |

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`.
| # | Item | Prereq | State | SHA | Note |
|---|---|---|---|---|---|
| 0 | §15.5's overnight window read back | B | **done — NO GRANT; the phone ended the window** | this commit (the record) | App-side witness `p10dev/run2/device-console.log` (pid 10752; `registered` 18:43:04.280Z; `submitted trigger=background` 18:43:05.901Z; floor 18:58:05Z): no `trigger=handle`, no `runFinished`, no `taskWasDelivered`, no termination line; last entry devicectl's *The connection was invalidated (Mercury 1001)*, mtime 20:39Z — the session was on the WIRED transport. Framework-side witness: readable chunks `c-2`, `c-3`, `night-2`…`night-5` (18:42:34–20:35:20Z, exported with the prior session's `extract.sh` + a second pass counting exact tokens); `c-4` 19:15:45–19:30Z UNREADABLE (never finalised — the `night` chain's bounded 240 × 5 s wait fell through at 19:30:04Z while `c-4` was still recording; a 16 min 54 s gap, 19:14:25.5 → 19:31:19.3Z, covered by the console only); `night-6` zero rows; `night-7` *Timed out waiting for device to boot* at 20:39:39Z and `night-8`…`night-40` each ended within seconds (two more timeouts among them). The chain never abuts: every chunk boundary is 71–110 s un-traced (the 18:58:05Z floor instant among them), ≈24 min in all — the console is the continuous witness. In every readable chunk: `bgRefresh-MBO.Fernlet.companion-refresh:44EF40` once (the 18:43:05.885Z submission, floor to the second), no STARTING/RUNNING/COMPLETED, no `companion-refresh` mention after, no termination of pid 10752, `dasd` silent on the activity. **1 h 56 min from submit, 1 h 41 min past the floor, no grant; ≈3 h 36 min pending across the two days** (three requests, disjoint intervals; the first draft's 3 h 51 min double-counted a 15-min overlap and is still in `f8dbcae`'s commit subject). The phone was found on `localNetwork`, cable out, locked, **Fernlet not running** at 15:10Z (pid 10752 died in the unwitnessed 18½ h). Witness finding: the trace carries NONE of the app's `companionRefresh.*` audit lines for this launch (the console mirror does; the 2026-09-21 probe export did) — console = app-side witness, trace = framework-side only. Recorded: runbook *Lane E* § *The overnight window, read back 2026-09-22* + the D2 row; plan §15.5 D1/D2 + §15's "Second device entry" + §28.9; the launcher's item 2. |
| 1 | **Lane D founder/joiner UNSEEDED on hardware** — the first meeting on the radio that ships | 0 (the phone free), the owner's unlock | **done — PASS** (three runs) | this commit (the record); scripts in the session scratch `lane/` | Build `d88062c` for the device and the Simulator into a fresh DerivedData (both `** BUILD SUCCEEDED **`, 0 `error:`), installed fresh on both. **A locked phone refused the launch** (`FBSOpenApplicationErrorDomain error 7 (Locked)`, transcript kept as `lane/harvest/phone-locked-15-18-43Z.txt`) — the owner unlocked it and kept it awake; every run's preflight `passcodeRequired=false`, `en9 present = 0`, `transport = localNetwork`, no `xcodebuild`/`xctrace`. Roles by fingerprint: the phone `5c73…` < the iPhone 17 Pro Simulator `fb79…` → phone founder, Simulator joiner (also the only assignment that lets the re-dial freeze the Simulator; the phone's `--console` cannot die without killing the app). **Run 1b (the record):** `legacyRosterFallback members=0` on both → `accepted` both ways, zero introduction refusals → both commit (the phone at `awaitingManualCommit`, the Simulator at `awaitingProximityCommit`) → both mint, **the other arm** of the double-mint repair from the Simulator lane (the phone committed first: `droppedForeignMesh` + `reannouncedToNewbornPeer`; the Simulator `droppedUncommittedSlot` → `yieldedNewbornMesh adopted=7F74…`) → `autoGrantedFoundingPair` (harness fallbacks silent: `founder armed=false`, no `admitting`, no `requesting admission`) → `bootstrapped` / `adopted members=2` → **`derived=2` on both under `1.83eb…5c73ce4c29dc84be`, ≈1.4 s from browse**; 0 `tunnelEnded`, 4/4 heartbeats over datagrams each way, `en0[802.11]`, no `awdl0`, no `en9`; the NECP `EEXIST` once at the FIRST inbound flow, absorbed. **Run 2 (the re-dial, freeze shape):** the Simulator `SIGSTOP`ped at the phone's `committing slot` (15:28:26Z; the Simulator 0 commits, 0 ledgers) → the phone alone `derived=1` → the dead tunnel ended **by the transport at +111 s** (`controlStreamEnded`, NWError 60 — the idle timeout by its token, against `idleTimeoutMs=90000`; no `localEviction`) → thaw 15:30:19Z → both re-accepted under the tolerated meshID (phone real-id vs Simulator unbound, the same `sid`s) → both re-committed, the Simulator minted and yielded (`adopted=424F…`), auto-grant → **`derived=2` on both ≈4 s after the thaw**. **Run 1 (inverted roles by a script bug — a `roles` function run in a pipeline):** the same chain passed with the founder role on the yielding Simulator (`armed=false` there too); recorded, not the record. Recorded: runbook *Lane D* § *The device round's item 1* (three tables, timelines, findings); the device plan's Results (F11 unseeded); plan §17.1.2 deviation 1 + §28.9; the launcher's item 1. |
| 2 | §15.1 radio matrix, §15.2 partition walks, P9-2-C, §15.4, §15.3 soak | two to four phones; the owner's hands | **blocked (owner) — every row named, none inferred** | this commit (the record) | One phone in hand. §15.1 (F1–F6): UNREACHABLE as specified (two phones; the background/lock rows need the owner to lock the phone by hand and a far end that is not the Mac). §15.2 (F7–F8): UNREACHABLE (three or four phones). §15.3 (F9, F12): NOT RUN — reachable with one phone and a Simulator holding the far end, but it needs the phone in the owner's normal use for 3 h / 6 h on the Mac's Wi-Fi; **the degraded ladder stays unchosen**. §15.4: the owner's call, unchanged. P9-2-C: NOT RUN — presence has no launch-env hook (a Settings switch on the phone), the lane needs a third friend seeded (P9-2-B), and a ≥ 767 s arm. Recorded: runbook *Lane B* (a dated status paragraph naming each row); plan §15 rows 15.1–15.4 (dated); the launcher's items 3–5. |
| 3 | The owner's product calls + the three owed hardenings, in one page | — | **done — written, and the five calls DECIDED by the owner the same day** | this commit | Below, § *Item 3*; the decisions in the table below and plan §28.3. |
| 4 | **Correction, read back after the record:** the continued-processing task is GRANTED on the phone at every first commit | — | **done — OBSERVED, six of six runs** | the decisions commit | Every Lane D transcript of 2026-09-21 and every run of item 1 carries `mesh.continuation.registered` → `submitted event=firstPeerCommitted` → **`started event=taskStarted state=running`** 4–7 ms later (today 11:22:22.569 / 11:25:32.873 / 11:28:26.725; yesterday 12:22:22.166 / 12:28:32.957 / 12:35:57.252); the task stayed `running` across both re-dials (`absorbed … state=running`); no `refused`/`expired`/`cancelled`/`completed` anywhere (every run terminated from the Mac). Three §15 tier-3 rows moved: registration, the `.fail` grant, the launch handler; the expiration handler, the tunnel outliving the task and the soak stay open. The two "no grant of any class" sentences (this ledger, the runbook's Lane B paragraph) were wrong for this class and are corrected; §15.5's class is still ungranted. Recorded: runbook *Lane D* (last paragraph of the item 1 subsection), *Lane B* (paragraph + a dated row); plan §15's tier-3 table + §28.9. |

## Blocked on owner
- **A second phone** — §15.1, §15.2, the Simulator-survivor direction of the re-dial, the two-phone first meeting.
- **What the continuation grant still leaves open** — the expiration handler, the tunnel outliving the task, the running
  card, a force quit while the task runs, exactly-once completion on the real conformer: the soak and its ends.
- **The §15.5 window** — hours, not minutes: the phone on the charger, on the Mac's Wi-Fi, untouched; the console launched
  wirelessly (a wired console dies with the cable) or no console at all (the trace as the only witness, framework lines
  only). What happened at the phone at ≈20:39Z on 2026-09-21 is the owner's to say.
- **The 3 h / 6 h soak** (§15.3) — one phone and a Simulator would carry it, with the owner using the phone normally
  on the Mac's Wi-Fi for the duration. It decides the degraded ladder. **Scheduled: the evening of 2026-09-22** (the
  scripts and the owner's checklist are in the session scratch `soak/`; the read-out is the next session's first item).
- **P9-2-C** — the presence switch on the phone, a third friend seeded, a ≥ 767 s arm.
- ~~Item 3's five calls~~ — **taken 2026-09-22** (below). The three hardenings stay priced, not taken.
- **The build round the calls imply** — Option 1b's name deferral and P9-3-A made to work: `Docs/Next-Round-Prompt-Owner-Calls-2026-09-22.md`, after the soak is read.
- Everything plan §28.4 already carries.

## Decisions taken
| Decision | Choice | Taken on |
|---|---|---|
| Which Simulator pairs with the phone | The **iPhone 17 Pro** (`454FCC9C-…`, fp `fb79…`): its fingerprint is ABOVE the phone's, so the phone is the founder (the lower fingerprint) and the Simulator the joiner — the only assignment under which the re-dial can freeze the joiner, because the phone's `--console` process cannot be killed without killing the app. The `iPhone 17` (`09F57BCA-…`, fp `1b4f…` at the deletion round) would have made the phone the yielder and the Simulator the founder. | 2026-09-22 |
| How to kill the tunnel between the two commits | Freeze the Simulator's process (`SIGSTOP` by pid, from a watcher on the phone's console at `committing slot`); let the phone end the tunnel; `SIGCONT`. The Simulator lane's shape, mirrored. The phone cannot be the frozen side. | 2026-09-22 |
| Run 1's inverted roles | **Re-run (run 1b) rather than re-label**: the record must mirror the recipe (founder on the lower fingerprint), and run 1 is kept as what it is — one sample of the configuration the deletion round declined to run, passed. The script bug (a variable-setting function inside a pipeline) is named in the runbook so nobody repeats it. | 2026-09-22 |
| What the read-back claims about the phone at 20:39Z | Only what the Mac saw: the wired console invalidated and `xctrace` timing out within the same minute. "A pulled cable does this" is stated as the shape, not as the cause; the cause is the owner's to give. The app's death is dated to the unwitnessed gap, cause unread. | 2026-09-22 |
| The trace-witness contradiction | Recorded as a NARROWING of the 2026-09-21 note, not a retraction: that day's probe export did carry an audit line in the clear; this window's did not. Two candidate causes named, neither claimed. The practical rule is what matters and is stated. | 2026-09-22 |
| The owner's five calls (item 3) | **(1) withhold the display name until commit; (2) Option 2 left alone — QR stays an in-session verification, not a pre-admission; (3) P9-3-A: make it work — the recommendation is to drop the `!input.appLockEngaged` leg from `presenceState`/`recipeShareState` (the mesh row has none) and retire the input with its projection, re-pinning the 23 040-row product and P7's acceptance clause, because a scoped lock at rest protects private surfaces, not radios; (4) hold the `_fernlet-coach` pair for Coach (§18 decision 4 = its default); (5) the 6 h soak runs tonight, the ladder chosen by its numbers.** (1) and (3) build after the soak's read-out, on the launcher named above. | 2026-09-22 (the owner) |
| §15.3's soak with one phone | **Not attempted in the session; SCHEDULED for the evening** — reachable in shape: it needs the owner's normal use of the phone for hours on the Mac's Wi-Fi, which this session did not have, and a half-attended soak would be a pass for the wrong reason (the device plan's own rule). Named as reachable so the owner can choose to spend the hours. | 2026-09-22 |

## Verify findings
(one adversarial verify per item — implement → a verifier blind to the first's reasoning → fix)

**Items 0–3 (records; no code changed) — one blind Opus verify over the whole record set against the raw logs, the
chunk exports and the tree at HEAD: COMMIT WITH FIXES, 1 HIGH + 9 MEDIUM + 10 LOW + 4 NOTE, all taken in the fix commit.**
Both headline conclusions survived (no grant in the overnight window; the unseeded first meeting observed on hardware).
1. HIGH — "≈3 h 51 min of accepted-and-pending" was not derivable: it added the first session's 1 h 55 min to this
   window's 1 h 56 min, which overlap by 15 min 35 s, and counted four requests where three exist. → **≈3 h 36 min**,
   three requests, disjoint intervals stated (runbook, plan ×2, launcher, ledger; the `f8dbcae` subject keeps the old
   number and says so here).
2. MEDIUM — run 1b's Wi-Fi row cited a peer address (`fe80::4f5:…`) that is in runs 1 and 2's witness (the Simulator as
   listener), not run 1b's (the Simulator as dialer); and "the link-local flow formed the tunnel" was unsupported. → the
   row claims only what run 1b's witness shows and attributes the address to runs 1 and 2.
3. MEDIUM — `night-9`'s window was `night-10`'s. → 20:40:13.9–20:40:16.2Z (2.3 s); night-10 zero rows.
4. MEDIUM — the c-4/night-1 mechanism was wrong: the night chain's 240 × 5 s wait FELL THROUGH (started 19:09:53Z + 20 min
   = 19:30:04Z to the second) while c-4 was still recording, 41 s before its own limit. → said; the lesson now names the
   bounded wait.
5. MEDIUM — the chunk chain never abuts: 71–110 s un-traced at every boundary, the 18:58:05Z floor instant inside one,
   ≈24 min in all. → said; the console named as the continuous witness.
6. MEDIUM — `recordError(domain:)` has six call sites, not three (`:870`, `:894` "Envelope", `:1367` "Ranging" missed). → six.
7. MEDIUM — the `MeshLinkTable` doc-comment citation (`:401-404`) pointed at `reproposals`/`reproposalRefunds`, whose
   comments are true; `links` (`:398`) has none. → the clause dropped, the eviction's actual effect stated, `:733` cited.
8. MEDIUM — "every `.trainer` caller is under `Tests/`" was false (`ProximityCoordinator.swift:1374`,
   `CoachSessionTrustPolicy.swift:51`, `ProximityPersistenceRecords.swift:101`). → the `NoTrackingBoundaryTests` claim
   (every shipping `begin` passes `.friend`; `TrainerProximityService` only under `Tests/`).
9. MEDIUM — the locked-launch quote had no kept artifact. → a verbatim copy of the terminal saved as
   `lane/harvest/phone-locked-15-18-43Z.txt` and cited.
10. MEDIUM — the one "refused" word sat 0.4 ms after a `TLS error (security error 61)` on the same connection. → said;
    "path-race loser" softened; "not an introduction refusal" kept (all three refusal tokens 0 on both nodes, all runs).
11. LOW — the Simulator build started 15:17:09Z. 12. LOW — `:683` is the call site; the function is at `:733`.
13. LOW — run 2's "at that instant" quote was a post-thaw line. → the watcher's counts and the audit stream's silence.
14. LOW — the c-4 gap is 16 min 54 s (c-3's toc end → night-2's start). 15. LOW — "night-7 onward timed out" overstated
    (three timeouts; the rest ended within seconds). 16. LOW — ≈1.4 s is Simulator-browse → Simulator-adopted; the phone's
    anchor gives ≈1.2 s; "on both" is pinned on the Simulator side. → anchors stated. 17. LOW — "≈4–5 s" vs "≈4 s". → ≈4 s
    everywhere, +3.7 s / +5 s poll stated. 18. LOW — the Status header blamed the second phone for §15.3/§15.4. → split.
19. LOW — "do not unplug" is `STATE.md`'s, not the preflight's; `registered`/`submitted` are 1.6 s apart, not one second;
    the runs took eleven minutes, not twelve. 20. LOW — "at 30 s spacing" was read off `beatSeconds=30`, not measured.
21. NOTE — plan §17.1.2 item 2's plist sentence was stale (three types now). → a dated bracket. 22. NOTE — `iPhone18,2`
    unwitnessed. → dropped. 23. NOTE — "the transport's idle timeout" is an inference from the token and the interval. →
    worded as such. 24. NOTE — "already dialing at :32.00" was a browse line. → "browsed".

**Gates** (run at `6ca4d73` before the verify, re-run after the fix commit): `build-for-testing` `** TEST BUILD SUCCEEDED **`,
0 `error:`; `MeshP10HonestyAcceptanceTests` + `CIGateSelectorBoundaryTests` → `✔ Suite … passed` ×2, `Test run with 10 tests
in 2 suites passed`; `MeshP8HonestyAcceptanceTests` + `MeshP9HonestyAcceptanceTests` → ×2, `9 tests in 2 suites passed`; 0
`Restarting after unexpected exit`. No full-suite run (the owner's standing instruction).

---

## Item 3 — the owner's calls (one page; asked, not decided)

### Five product calls

1. **Option 1b's name deferral.** As built (D-4.3 Option 1, `5c8d5ac`…), a bystander with the join doors open learns the
   LOCAL DISPLAY NAME at the identity introduction — before the 15 cm dwell or the tap — exactly as MultipeerConnectivity
   showed it (`Docs/Mesh-Stranger-Admission-Design-2026-09-21.md` § *Option 1b*). 1b's second half withholds the name until
   `.connected`: the join screen shows a fingerprint, not a name, until commit. Engineering: a coordinator state for the
   deferred name, the introduction without the name, the name on commit, a `ProximityCoordinatorTests` row — small. The
   call is what "find people nearby" *shows* before consent. **Ask: keep MC's posture (name before commit), or withhold it?**
2. **Option 2's two-scan QR pre-admission.** No stranger ever gets a tunnel; QUIC stays members-only before any app frame;
   §7.2's bullet unamended (design § *Option 2*). Cost: a new pre-session screen, two scans per pairing on both phones, a
   two-person ceremony for a newcomer to a group, the pre-admission table and its tests, a QR v2 if `meshID` rides along,
   a Lane C run driven by seeded scans and a Lane D run. The design calls it "the right *next* design". **Ask: build it
   next, or leave Option 1 as the shipping first meeting?** (Today's first meeting is now observed on hardware — item 1.)
3. **P9-3-A — a configured Fernlet Lock parks the recipe-share and presence radios permanently.**
   `ProximityRunPolicy.presenceState` / `recipeShareState` stop on `appLockEngaged`, and `.locked` is the RESTING state of
   a configured lock (plan §17.1.3 finding 1; runbook *Lane C — P9 item 3*). The default (plan §28.3) is to leave the
   policy alone and **surface why** — a sentence on the Nearby settings when a lock is configured — because changing a
   run-policy row is a P7 bug fix that re-runs the 23 040-row product. **Ask: surface it (small), or change the policy?**
4. **The `_fernlet-coach._{tcp,udp}` strings.** Still declared in `App/Fernlet/Info.plist` (`:18-19`); `MultipeerServiceType.trainer`
   is dead in shipping in the sense `NoTrackingBoundaryTests` (`:940-943`) pins: every shipping `ProximityCoordinator.begin` passes
   `mode: .friend`, and `serviceType(for: .trainer)` (`ProximityCoordinator.swift:1374`) is reached only from `TrainerProximityService`,
   which exists only under `Tests/` — the token itself is still read by shipping code (`CoachSessionTrustPolicy.swift:51`,
   `ProximityPersistenceRecords.swift:101`), so "dead" means unreachable, not unreferenced; plan §18 decision 4's default is **hold**. Dropping them is a product decision about the Coach app, not transport cleanup.
   **Ask: hold for Coach, or drop the pair?**
5. **The degraded ladder** (plan §14: full background mesh → infra-Wi-Fi only → foreground-only with opportunistic sync).
   Decided by §15.3's soak and by nothing else; the soak has no numbers (item 2). **Nothing to ask until it runs; the
   owner decides whether to spend the 3 h / 6 h** (one phone + a Simulator suffice for the shape).

### Three owed hardenings, priced by the deletion round and not taken — priced again, still not taken

| Hardening | Where it stands at `d88062c` | Price |
|---|---|---|
| `recordError(domain:)` labels are unlocalized display strings across the inspector | **Six** call sites pass bare `String`s that the inspector displays: `"Transport"` (`FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift:575`), `"Ranging"` (`:678`, `:1367`), `"Envelope"` (`:870`, `:894`), `"export"` (`App/Fernlet/Proximity/UI/ConnectionInspectorHistoryView.swift:140`); the sink is `ConnectionInspector.recordError(domain:message:recoverable:)` (`App/Fernlet/Proximity/Audit/ConnectionInspector.swift:136`). `LocalizationBoundaryTests` does not scan the `recordError(domain:` shape, so a fourth bare label is an error nowhere. The inspector's "Session state" row label (renamed in the deletion round) is the same class. | **Small**: a typed domain (an enum with a localized display name), six call sites, one wall rule that forbids a string literal at `recordError(domain:`; the bare row labels ride along or stay named. One round item. |
| `MeshLinkTable.links` is never evicted by the cache eviction (only the counters are) | `NetworkMeshSession.links` (`Transport/NetworkMeshSession.swift:490`) is a `MeshLinkTable` whose `links: [MeshLinkKey: Link]` (`Transport/MeshLinkTable.swift:398`) is cleared by `forget` (`:656`) and `removeAll()` (`:666`) only; `evictOldestCachedEndpointIfFull()` (defined `:733`, called from `remember` at `:683`) removes the evicted key from the endpoint cache, `reproposals` and `reproposalRefunds` (the two fields whose doc comments at `:399-404` say so, truthfully) and only clears a flag on `links[oldest]` — the link map itself is never evicted. A crowded room grows `links` for the session's life. | **Small–medium**: an eviction leg for closed links past a bound (first-seen order already exists for the cache), a value test that plants N closed links and reads the count after eviction. One round item. |
| The wipe wall pins that `wipeIdentityForDeleteAll` exists and is called, never what it does | `PrivacyWipeCoverageTests` names the function (`:193`) and asserts `source.contains("func wipeIdentityForDeleteAll")` per owner (`:754`); `FernletStore.swift:5736-5738` calls the three conformers (`MeshNetworkManager:13429`, `PresenceManager:1638`, `ProximityRecipeShareManager:179`). The cutover round saw the wipe leg's retirement go red nowhere for exactly this reason (§28.8). | **Medium**: one value test per conformer — mint an identity, wipe, assert the keychain item is gone and a fresh mint differs — on a Simulator keychain; three cells, a shared rig. One round item. |

None of the three is a one-liner; each stays in plan §28.4's list.

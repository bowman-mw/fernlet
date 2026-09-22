# Mesh Migration Loop Ledger — the device round (the deletion build on hardware)

**Round:** not a phase — plan §28 says the phases are spent. The launcher is
[Next-Round-Prompt-Device-Round-2026-09-21.md](Next-Round-Prompt-Device-Round-2026-09-21.md), entry condition **A**, run
on the DELETION build as [Next-Round-Prompt-Deletion-Round-2026-09-21.md](Next-Round-Prompt-Deletion-Round-2026-09-21.md)
§ *The phase after this one* says; the round it follows is
[Mesh-Migration-Loop-Ledger-Deletion-2026-09-22.md](Mesh-Migration-Loop-Ledger-Deletion-2026-09-22.md).
**Started:** 2026-09-22 15:10Z · **Closed:** 2026-09-22 (stop condition 1 as far as one phone allows: items 0 and 1 run
and recorded, item 2's rows named, item 3's page written, this ledger closed).
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
| 0 | §15.5's overnight window read back | B | **done — NO GRANT; the phone ended the window** | this commit (the record) | App-side witness `p10dev/run2/device-console.log` (pid 10752; `registered` 18:43:04.280Z; `submitted trigger=background` 18:43:05.901Z; floor 18:58:05Z): no `trigger=handle`, no `runFinished`, no `taskWasDelivered`, no termination line; last entry devicectl's *The connection was invalidated (Mercury 1001)*, mtime 20:39Z — the session was on the WIRED transport. Framework-side witness: readable chunks `c-2`, `c-3`, `night-2`…`night-5` (18:42:34–20:35:20Z, exported with the prior session's `extract.sh` + a second pass counting exact tokens); `c-4` 19:15:45–19:30Z UNREADABLE (never finalised — the `night` chain started while the `c` chain was finalising it; a 15½-min gap covered by the console only); `night-6` zero rows; `night-7` onward *Timed out waiting for device to boot* from 20:39:39Z. In every readable chunk: `bgRefresh-MBO.Fernlet.companion-refresh:44EF40` once (the 18:43:05.885Z submission, floor to the second), no STARTING/RUNNING/COMPLETED, no `companion-refresh` mention after, no termination of pid 10752, `dasd` silent on the activity. **1 h 56 min from submit, 1 h 41 min past the floor, no grant; ≈3 h 51 min pending across the two days.** The phone was found on `localNetwork`, cable out, locked, **Fernlet not running** at 15:10Z (pid 10752 died in the unwitnessed 18½ h). Witness finding: the trace carries NONE of the app's `companionRefresh.*` audit lines for this launch (the console mirror does; the 2026-09-21 probe export did) — console = app-side witness, trace = framework-side only. Recorded: runbook *Lane E* § *The overnight window, read back 2026-09-22* + the D2 row; plan §15.5 D1/D2 + §15's "Second device entry" + §28.9; the launcher's item 2. |
| 1 | **Lane D founder/joiner UNSEEDED on hardware** — the first meeting on the radio that ships | 0 (the phone free), the owner's unlock | **done — PASS** (three runs) | this commit (the record); scripts in the session scratch `lane/` | Build `d88062c` for the device and the Simulator into a fresh DerivedData (both `** BUILD SUCCEEDED **`, 0 `error:`), installed fresh on both. **A locked phone refused the launch** (`FBSOpenApplicationErrorDomain error 7 (Locked)`) — the owner unlocked it and kept it awake; every run's preflight `passcodeRequired=false`, `en9 present = 0`, `transport = localNetwork`, no `xcodebuild`/`xctrace`. Roles by fingerprint: the phone `5c73…` < the iPhone 17 Pro Simulator `fb79…` → phone founder, Simulator joiner (also the only assignment that lets the re-dial freeze the Simulator; the phone's `--console` cannot die without killing the app). **Run 1b (the record):** `legacyRosterFallback members=0` on both → `accepted` both ways, zero introduction refusals → both commit (the phone at `awaitingManualCommit`, the Simulator at `awaitingProximityCommit`) → both mint, **the other arm** of the double-mint repair from the Simulator lane (the phone committed first: `droppedForeignMesh` + `reannouncedToNewbornPeer`; the Simulator `droppedUncommittedSlot` → `yieldedNewbornMesh adopted=7F74…`) → `autoGrantedFoundingPair` (harness fallbacks silent: `founder armed=false`, no `admitting`, no `requesting admission`) → `bootstrapped` / `adopted members=2` → **`derived=2` on both under `1.83eb…5c73ce4c29dc84be`, ≈1.4 s from browse**; 0 `tunnelEnded`, 4/4 heartbeats over datagrams each way, `en0[802.11]`, no `awdl0`, no `en9`; the NECP `EEXIST` once at the FIRST inbound flow, absorbed. **Run 2 (the re-dial, freeze shape):** the Simulator `SIGSTOP`ped at the phone's `committing slot` (15:28:26Z; the Simulator 0 commits, 0 ledgers) → the phone alone `derived=1` → the dead tunnel ended **by the transport's idle timeout at +111 s** (`controlStreamEnded`, NWError 60; no `localEviction`) → thaw 15:30:19Z → both re-accepted under the tolerated meshID (phone real-id vs Simulator unbound, the same `sid`s) → both re-committed, the Simulator minted and yielded (`adopted=424F…`), auto-grant → **`derived=2` on both ≈4 s after the thaw**. **Run 1 (inverted roles by a script bug — a `roles` function run in a pipeline):** the same chain passed with the founder role on the yielding Simulator (`armed=false` there too); recorded, not the record. Recorded: runbook *Lane D* § *The device round's item 1* (three tables, timelines, findings); the device plan's Results (F11 unseeded); plan §17.1.2 deviation 1 + §28.9; the launcher's item 1. |
| 2 | §15.1 radio matrix, §15.2 partition walks, P9-2-C, §15.4, §15.3 soak | two to four phones; the owner's hands | **blocked (owner) — every row named, none inferred** | this commit (the record) | One phone in hand. §15.1 (F1–F6): UNREACHABLE as specified (two phones; the background/lock rows need the owner to lock the phone by hand and a far end that is not the Mac). §15.2 (F7–F8): UNREACHABLE (three or four phones). §15.3 (F9, F12): NOT RUN — reachable with one phone and a Simulator holding the far end, but it needs the phone in the owner's normal use for 3 h / 6 h on the Mac's Wi-Fi; **the degraded ladder stays unchosen**. §15.4: the owner's call, unchanged. P9-2-C: NOT RUN — presence has no launch-env hook (a Settings switch on the phone), the lane needs a third friend seeded (P9-2-B), and a ≥ 767 s arm. Recorded: runbook *Lane B* (a dated status paragraph naming each row); plan §15 rows 15.1–15.4 (dated); the launcher's items 3–5. |
| 3 | The owner's product calls + the three owed hardenings, in one page | — | **done — written, not decided** | this commit | Below, § *Item 3*. |

## Blocked on owner
- **A second phone** — §15.1, §15.2, the Simulator-survivor direction of the re-dial, the two-phone first meeting.
- **The §15.5 window** — hours, not minutes: the phone on the charger, on the Mac's Wi-Fi, untouched; the console launched
  wirelessly (a wired console dies with the cable) or no console at all (the trace as the only witness, framework lines
  only). What happened at the phone at ≈20:39Z on 2026-09-21 is the owner's to say.
- **The 3 h / 6 h soak** (§15.3) — one phone and a Simulator would carry it, with the owner using the phone normally
  on the Mac's Wi-Fi for the duration. It decides the degraded ladder.
- **P9-2-C** — the presence switch on the phone, a third friend seeded, a ≥ 767 s arm.
- **Item 3's five calls and three hardenings** — below.
- Everything plan §28.4 already carries.

## Decisions taken
| Decision | Choice | Taken on |
|---|---|---|
| Which Simulator pairs with the phone | The **iPhone 17 Pro** (`454FCC9C-…`, fp `fb79…`): its fingerprint is ABOVE the phone's, so the phone is the founder (the lower fingerprint) and the Simulator the joiner — the only assignment under which the re-dial can freeze the joiner, because the phone's `--console` process cannot be killed without killing the app. The `iPhone 17` (`09F57BCA-…`, fp `1b4f…` at the deletion round) would have made the phone the yielder and the Simulator the founder. | 2026-09-22 |
| How to kill the tunnel between the two commits | Freeze the Simulator's process (`SIGSTOP` by pid, from a watcher on the phone's console at `committing slot`); let the phone end the tunnel; `SIGCONT`. The Simulator lane's shape, mirrored. The phone cannot be the frozen side. | 2026-09-22 |
| Run 1's inverted roles | **Re-run (run 1b) rather than re-label**: the record must mirror the recipe (founder on the lower fingerprint), and run 1 is kept as what it is — one sample of the configuration the deletion round declined to run, passed. The script bug (a variable-setting function inside a pipeline) is named in the runbook so nobody repeats it. | 2026-09-22 |
| What the read-back claims about the phone at 20:39Z | Only what the Mac saw: the wired console invalidated and `xctrace` timing out within the same minute. "A pulled cable does this" is stated as the shape, not as the cause; the cause is the owner's to give. The app's death is dated to the unwitnessed gap, cause unread. | 2026-09-22 |
| The trace-witness contradiction | Recorded as a NARROWING of the 2026-09-21 note, not a retraction: that day's probe export did carry an audit line in the clear; this window's did not. Two candidate causes named, neither claimed. The practical rule is what matters and is stated. | 2026-09-22 |
| §15.3's soak with one phone | **Not attempted**, though reachable in shape: it needs the owner's normal use of the phone for hours on the Mac's Wi-Fi, which this session did not have, and a half-attended soak would be a pass for the wrong reason (the device plan's own rule). Named as reachable so the owner can choose to spend the hours. | 2026-09-22 |

## Verify findings
(one adversarial verify per item — implement → a verifier blind to the first's reasoning → fix)

**Items 0–2 (records; no code changed):** one blind Opus verify over the whole record set against the raw logs — see the
row appended below when it returns.

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
4. **The `_fernlet-coach._{tcp,udp}` strings.** Still declared in `App/Fernlet/Info.plist`; `MultipeerServiceType.trainer`
   is confirmed dead in shipping (every `.trainer` caller is under `Tests/`; deletion round verify note 12); plan §18
   decision 4's default is **hold**. Dropping them is a product decision about the Coach app, not transport cleanup.
   **Ask: hold for Coach, or drop the pair?**
5. **The degraded ladder** (plan §14: full background mesh → infra-Wi-Fi only → foreground-only with opportunistic sync).
   Decided by §15.3's soak and by nothing else; the soak has no numbers (item 2). **Nothing to ask until it runs; the
   owner decides whether to spend the 3 h / 6 h** (one phone + a Simulator suffice for the shape).

### Three owed hardenings, priced by the deletion round and not taken — priced again, still not taken

| Hardening | Where it stands at `d88062c` | Price |
|---|---|---|
| `recordError(domain:)` labels are unlocalized display strings across the inspector | Three call sites pass bare `String`s that the inspector displays: `"Transport"` (`FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift:575`), `"Ranging"` (`:678`), `"export"` (`App/Fernlet/Proximity/UI/ConnectionInspectorHistoryView.swift:140`); the sink is `ConnectionInspector.recordError(domain:message:recoverable:)` (`App/Fernlet/Proximity/Audit/ConnectionInspector.swift:136`). `LocalizationBoundaryTests` does not scan the `recordError(domain:` shape, so a fourth bare label is an error nowhere. The inspector's "Session state" row label (renamed in the deletion round) is the same class. | **Small**: a typed domain (an enum with a localized display name), three call sites, one wall rule that forbids a string literal at `recordError(domain:`; the bare row labels ride along or stay named. One round item. |
| `MeshLinkTable.links` is never evicted by the cache eviction (only the counters are) | `NetworkMeshSession.links` (`Transport/NetworkMeshSession.swift:490`) is a `MeshLinkTable` whose `links: [MeshLinkKey: Link]` (`Transport/MeshLinkTable.swift:398`) is cleared by `forget` (`:656`) and `removeAll()` (`:666`) only; `evictOldestCachedEndpointIfFull()` (`:683`) bounds the endpoint cache, not the link map — per the deletion round's read; the doc comment at `:401-404` claims otherwise and should be re-verified at implementation. A crowded room grows `links` for the session's life. | **Small–medium**: an eviction leg for closed links past a bound (first-seen order already exists for the cache), a value test that plants N closed links and reads the count after eviction, a comment made true. One round item. |
| The wipe wall pins that `wipeIdentityForDeleteAll` exists and is called, never what it does | `PrivacyWipeCoverageTests` names the function (`:193`) and asserts `source.contains("func wipeIdentityForDeleteAll")` per owner (`:754`); `FernletStore.swift:5736-5738` calls the three conformers (`MeshNetworkManager:13429`, `PresenceManager:1638`, `ProximityRecipeShareManager:179`). The cutover round saw the wipe leg's retirement go red nowhere for exactly this reason (§28.8). | **Medium**: one value test per conformer — mint an identity, wipe, assert the keychain item is gone and a fresh mint differs — on a Simulator keychain; three cells, a shared rig. One round item. |

None of the three is a one-liner; each stays in plan §28.4's list.

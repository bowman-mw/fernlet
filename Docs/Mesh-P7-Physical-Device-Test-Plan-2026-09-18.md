# Mesh P7 Physical-Device Test Plan

Network migration **P7** (the app-layer run policy, the poller, the resume surface — plan §13) on
**two to three physical iOS devices**, plus the §15 hardware gates P8 owns, as one checklist with a
results table. Written 2026-09-18 at the P7 boundary.

> **Status: this plan cannot be run yet.** Every P7 file was written in a session with **no Swift
> toolchain**; nothing in P7 has compiled, and no P7 test has run. Before any row below is attempted,
> the Mac gauntlet in `Docs/Mesh-Migration-Loop-Ledger-P7.md` § "Owed to a Mac" must be green
> (the P8 launcher's item 0). A row observed on a build that has not passed that gauntlet is an
> observation of an unknown binary. **No run of this checklist has been recorded.** When one happens,
> fill the **Result** and **Date** columns at the bottom, with the device models and iOS versions,
> so the next reader can tell a passed row from an unrun one — a blank cell reads as untested.

Sections A–E are P7's own behaviours, none of which a Simulator can prove the way a phone can (a
Simulator has no lock, no Control Centre, no real background suspension, and it satisfies the
foreground legs by accident). Section F is plan §15 as a checklist — **P8's entry gate**, not P7's
acceptance; it is here so the phone drawer is opened once, not twice.

## What the tester sees, in words

- **The Friends tab** is the `Friends` tab (`person.2.fill`). Entering it starts the search; the
  header shows the pulse **"Looking for nearby friends…"**. If the radios could not start it says
  **"Can't look for nearby friends"** instead.
- **A session** begins when a peer is committed (the full-screen **"Connected"** celebration); a
  session ends with the review sheet (**"Nice hangout!"**, then **"Keep as friends?"**).
- **The resume card** appears on the Friends tab after a launch, above the album, and only when the
  last session's restore has something to say. Its titles are exactly: **"Pick up your last
  session"**, **"Your last session couldn't be reopened"**, **"Your last session ended"**, **"Your
  last session timed out"**, **"You left your last session"**, **"Your last session ended for you"**.
  Its one button is **"Got it"**. It never appears while a session is up.
- **Nearby settings** are under **Nearby friends**: **Presence** ("Lets friends see you're around"),
  **Share your vibe**, **Recipe shares**. Presence runs on Home / Food / Move / Friends; recipe shares
  listen on Home / Food / Move only (never on Friends, never on Private).
- **Evidence** is Console.app on the Mac, filtered on `subsystem:com.fernlet`, for the device under
  test. The lines this plan reads:
  - `mesh.sessionCeiling.armedFromAdoptedMesh` — a joiner armed the six-hour ceiling (item 4).
  - `mesh.sessionPoll.moved` with `ceiling=` / `idle=` / `partition=` / `live=` — a 30-second poll
    that changed something (item 4). **Silence between changes is correct.**
  - `mesh.routedAccess.gateChanged` — the routed access gate moved (item 2); one line per real edge.
  - `proximityRunPolicy.unsupportedTransition` — **must be zero in every run.** One sighting is a
    defect: it means the policy asked for "mesh runs, discovery stops", which P7 refuses and P8 owns.
    **Retired by P8 item 3** (2026-09-18): that row is now EXECUTED — `holdCommittedLinks()` — so the
    token is emitted by nothing and the rule above is vacuously true; `ProximityRunSeamsTests` holds
    it at zero occurrences under `App/`. Watch `mesh.session.linksHeld` / `mesh.session.linksResumed`
    instead — one pair per background hold and foreground return.
  - `mesh.sessionState.rejoinBarred` — a re-join into a terminated mesh was refused (item 5's
    "ended" cards).

## Prerequisites

1. **The gauntlet is green** (see the status note). Then the same DEBUG build, from Xcode, on every
   device: iPhone, iOS 26.5 or later, **Local Network** permission granted on first prompt.
2. **Two devices minimum** (rows A–E); **three** for the removal row (E3) and any partition walk;
   **four** for §15.1's topology row.
3. Each device on the **same non-isolated Wi-Fi**, no VPN, no client isolation. For the AWDL rows,
   Wi-Fi off on one device. **Unplug every cable** before a background or lock row — a tethered phone
   does not sleep the way the row needs (`Docs/Mesh-Network-Feasibility-Runbook.md`, Lane D's setup),
   and check afterwards that no ready line names `en8`/`en9`/`anpi0`.
4. Onboarding completed; **Nearby friends → Presence** on; hearts opted in on both if E3 is run.
5. **App lock configured** (a Fernlet PIN) on one device for B1; **a duress PIN** for B2 — see
   `Docs/Plan-Security-Hardening-OpusTrack-2026-08-10.md` for both.
6. Console.app open on the Mac with each device selected in turn, filter `subsystem:com.fernlet`;
   in the app, **Settings → Advanced → Connection log** (the Advanced section exists in DEBUG builds
   only) for the live session log where the row says so.
7. **Auto-Lock → Never** on both devices for D1 and the soaks, restored afterwards; otherwise leave
   Auto-Lock at its default so the lock rows are real.

Roles: **A** and **B** are the two devices; **C** is the third where named. Run every row once with A
as the founder and once with B, unless the row says otherwise — the yielding founder is the one P6
§12.3 finding 3 was about.

## A. Tab and scene edges (items 1–3)

| Row | Steps | Expected |
|---|---|---|
| A1 | Cold-launch A **onto the Friends tab** (kill the app, launch, tap Friends within a second). | The pulse appears and stays; no stalled state (§13.3 finding 14 — the first scene push must not arrive after the tab edge and leave the pulse missing). |
| A2 | On A, enter Friends (pulse), then switch to Home **before** any peer commits. Return to Friends. | Pulse gone on Home, back on Friends. B (searching on its own Friends tab) is not connected in between. |
| A3 | A and B on Friends until **"Connected"**. On A, switch to Home for two minutes. | The session stays up on both; A's Friends tab still shows the session on return. (`hold`: a committed link survives a tab exit.) |
| A4 | A and B connected, both on Friends. On A, **pull down Control Centre** and hold it open for a minute; dismiss. | Nothing changes: no `gateChanged` line, session up, pulse or session view unchanged. **This is the P7 behaviour change** — before P7 an `.inactive` scene stopped presence, recipe and discovery. |
| A5 | A on Friends, searching, no peer. Press Home on A; wait 30 s; return to Friends. | The search stood down in the background (B's Friends tab no longer lists A) and restarted on return (pulse back). |
| A6 | A and B connected. Press Home on A; wait two minutes; return. | The session is still up if iOS kept the process alive; if iOS suspended A, the return shows either the session (link recovered) or the review sheet within the idle window — **record which**, with the time away. No `unsupportedTransition` line either way. |
| A7 | A and B connected, A on Friends. **Lock A** (side button); wait 30 s; unlock. | Console on A: `gateChanged` to closed on lock (protected data unavailable), `gateChanged` to open on unlock, followed by exactly one `mesh.routedAccess.reentry`. The session is up after unlock. |
| A8 | A connected, on Friends. Leave A on the **Private** tab for a minute. | Session held (as A3); presence off while on Private (B's presence list drops A after its window). |

## B. The hard stops (items 1 and 3)

| Row | Steps | Expected |
|---|---|---|
| B1 | A connected to B, Presence on. Engage A's **app lock** (background past the lock grace, or lock from Settings). Unlock with the PIN. | While locked: presence and recipe shares stop (B stops seeing A's presence); **the mesh session is untouched** — app lock gates nothing in the mesh (D-10.3). After unlock: presence resumes on the Friends/Home tab. |
| B2 | A connected to B. Enter A's **duress PIN**. | Every radio stops on A: the session ends on A (review sheet or none — record which), B sees A depart; `gateChanged` to closed on A. Exiting the duress session (per the hardening plan's exit) re-opens the gate and the next tab entry searches again. |
| B3 | A connected to B, a photo shared in the session. On A run **Delete all data**. | The session ends **at once** on A (leg 0), before the wipe's later legs. Record whether a **"Keep as friends?"** sheet appears after the wipe (§13.3 finding 6 — it may; note it either way). B sees A depart. Afterwards A is a fresh install: no resume card, no friends. |
| B4 *(optional)* | On a test account with a **final below-13 age ruling** for chat, or guardian communication limits, open Friends. | No search starts; no session can be founded; chat is refused as before. An account with **no** ruling (never asked) searches normally. |

## C. The nearby settings (item 3)

| Row | Steps | Expected |
|---|---|---|
| C1 | A on Home, B on Home, both with **Presence** on and each other kept as friends. Turn A's Presence **off**; wait a minute; turn it **on**. | B's presence list drops A after the off, and shows A again after the on — without leaving the tab. |
| C2 | A on Food with **Recipe shares** on; B sends A a recipe. Then A switches to Friends and B sends again. | The first arrives; the second does not (recipe shares never listen on Friends). Switching A back to Food and re-sending arrives. |

## D. The poller: ceiling, idle lapse, partition (item 4)

| Row | Steps | Expected |
|---|---|---|
| D1 — the ceiling | A and B connected (Auto-Lock Never, both on Friends, plugged into wall power, **not** a Mac). Leave them for **six hours**. | Console on the **yielding** founder shows `mesh.sessionCeiling.armedFromAdoptedMesh` at the founding (finding 3 closed). At six hours from the founding, within one 30 s tick, both devices end the session: `mesh.sessionPoll.moved ceiling=true … live=false`, then the review sheet. Relaunching afterwards shows **"Your last session timed out"** (E4). This row doubles as §15.3's six-hour soak **only if** a task is running, which P7 cannot do — record it as the foreground soak. |
| D2 — partition, then reunite | A and B connected. Walk B out of range (or airplane mode on B) for **five minutes**; return. | On A, within a tick of the loss: `mesh.sessionPoll.moved … partition=` (a move to partitioned); the session is **not** ended and no review sheet appears (a blip must present no sheet). On return, the links restore and the session continues; a second `partition=` line records the heal. |
| D3 — idle lapse | As D2, but keep B away for **more than 30 minutes** (`idleWindowSeconds`). | Between 30 and 30.5 minutes after the last authenticated heartbeat, A logs `mesh.sessionPoll.moved … idle=true … live=false` and ends the session locally (review sheet). Relaunching A afterwards shows **"Your last session ended"** (E2's ended card, `localIdleStop`). |
| D4 — the timer stops | After D1 or D3, leave A open on Friends for five minutes. | No `mesh.sessionPoll.moved` line after the ending; Xcode's Debug navigator on A shows the CPU gauge idle (no 30-second wakeup). A new session starts a new timer. |
| D5 — discovery timeout | A on Friends alone (B's app closed) for **five minutes**. | The pulse gives up at `discoveryGiveUpInterval` (5 min); re-entering the tab searches again. |

## E. The resume surface (item 5)

| Row | Steps | Expected |
|---|---|---|
| E1 — resumable | A and B connected, a photo in flight. **Force-quit A** (app switcher). Relaunch A; open Friends. | The card **"Pick up your last session"** with the message about keeping the tab open. With B still nearby and searching, A reconnects into the **same** mesh (B sees A return, not a new session) and the in-flight photo finishes arriving. The card is gone once the session is up. |
| E2 — you left | A and B connected. On A, tap **End session** in the session view and confirm **End Session**; complete the review sheet. Force-quit and relaunch A; open Friends. | **"You left your last session"** — "It can't be reopened, but anything you kept is already saved." Tapping **Got it** dismisses it; it does not return on the next tab visit in this launch. B, relaunched after its own end, shows **"Your last session ended"**. |
| E3 — removed *(three devices)* | A, B, C in one session. On A and then B, open C's participant row in the session view and propose removal (the roster-quorum moderation flow, plan §10.4). Relaunch C; open Friends. | On C: **"Your last session ended for you"** — "You were removed from that session." |
| E4 — timed out | After D1, relaunch either device; open Friends. | **"Your last session timed out"** — "Sessions last up to six hours." |
| E5 — set-aside file | *Not reachable without a corrupt sealed context; do not fake one on a device.* | Covered by tier 1 (`MeshSessionResumePresentationTests`, `SessionResumeCopyTests`). Record "not run on device". |
| E6 — locked launch | *A launch with protected data unavailable is not reachable by hand on a device.* | Covered by tier 1 (the deferral is silent). Record "not run on device". |
| E7 — silence | Fresh install, or a device whose last session ended and whose card was dismissed. Relaunch; open Friends. | No card. |

## F. Plan §15 — the hardware gates (P8's entry criteria, recorded here so the drawer opens once)

These rows are **not** P7's acceptance and most of them need P8's task to mean anything. They are
listed so a device session that has the devices in hand can bank the rows that need no task, and so
the ones that do are named with the P8 item that unlocks them. Results go in
`Docs/Mesh-Network-Feasibility-Runbook.md` § "Lane B", with dates.

| Row | Gate | Needs | Note |
|---|---|---|---|
| F1 | §15.1 established QUIC connection surviving background + lock | P8 item 6 (the task keeps the tunnel) | Without a task, A6 and A7 above record what iOS does to a foreground-only session; that is the **baseline** F1 is measured against. |
| F2 | §15.1 re-dial via cached endpoint while backgrounded | P8 item 6 | — |
| F3 | §15.1 fresh Bonjour browse while backgrounded | P8 item 6 | Expected to fail; record it. |
| F4 | §15.1 each × infra-Wi-Fi and AWDL | no task needed for the foreground half | Run A3/D2 once over infra-Wi-Fi and once with one device's Wi-Fi off (AWDL). Record which path carried it. |
| F5 | §15.1 Low Power Mode on/off | no task needed for the foreground half | Repeat D2 with Low Power Mode on; record discovery and reconnect timings. Undocumented by Apple — the empirical answer is the deliverable. |
| F6 | §15.1 memory-pressure kill | P8 item 6 | — |
| F7 | §15.2 partition walks: 2/2 with traffic both sides, walk back, one post-merge rotation | four devices | Convergence is checked by both halves showing the same roster and transcript after the merge; the rotation by one `epoch` step in the inspector. |
| F8 | §15.2 3/1 with a removal vote; departure carried by a third member | three or four devices | E3 is the removal half without the partition. |
| F9 | §15.3 progress soak, 3 h and 6 h, elapsed-based progress under normal phone use | P8 items 4 and 6 | D1 is the **foreground** six-hour soak and is the control. |
| F10 | §15.4 Wi-Fi Aware evaluation, bounded to two days | owner's call | A recommendation, not a dependency. |
| F11 | Lane D: the production mesh, phone ↔ Simulator, cable OUT | no P7 or P8 code | The cheapest first device run; specified in the runbook, never run. |
| F12 | §15.3 submission churn: does a Control-Centre peek spend the background claim? | P8 item 6 | `appForegroundDidChange(_:)` is LEVEL-triggered — a Control-Centre pull, the app switcher and a notification-shade peek all raise `.active`, which completes the task in hand and re-submits, spending one of the 8 `maxSubmissionsPerSession`. During F9's soak, peek Control Centre and the app switcher once every ten minutes with the mesh backgrounded and a task running. **Expected:** the Console shows one `mesh.continuation.submitted` per peek; after the eighth, `mesh.continuation.submissionCapReached` and the Friends card turns to the refusal sentence for the rest of that mesh. **Record how many peeks a normal hour costs.** If the answer is "more than eight", the fix is a rising-edge latch (a foreground push that follows a background one) rather than a bigger cap. |

## Results

Fill one line per row per run. Device models and iOS versions once at the top of each run's block.

| Row | Result (pass / fail / not run, one line of evidence) | Date | Devices |
|---|---|---|---|
| A1 | | | |
| A2 | | | |
| A3 | | | |
| A4 | | | |
| A5 | | | |
| A6 | | | |
| A7 | | | |
| A8 | | | |
| B1 | | | |
| B2 | | | |
| B3 | | | |
| B4 | | | |
| C1 | | | |
| C2 | | | |
| D1 | | | |
| D2 | | | |
| D3 | | | |
| D4 | | | |
| D5 | | | |
| E1 | | | |
| E2 | | | |
| E3 | | | |
| E4 | | | |
| E5 | not run on device (tier 1 only) | — | — |
| E6 | not run on device (tier 1 only) | — | — |
| E7 | | | |
| F1–F12 | see the runbook's Lane B table | | |

**A deviation from the Expected column is a finding, by row name**, into the P8 ledger; a row that
passes for a reason other than the one stated (a Simulator-style accident, a tethered phone that never
slept) is not a pass.

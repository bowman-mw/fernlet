# Loop Prompt — ProximityKit Network Migration: P6 (feature routing — text, hearts, and the key advertisement)

**Written:** 2026-09-10, at the P5 boundary (main = `3a32be0`, the post-close review corrections on top of the P5 close-out).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. **§12 is the P6 specification; §23 is the handoff; §11.3 items 12–13 and §23.3 are the named obligations.** This file is the launcher and the loop contract.
**Ledger:** [Docs/Mesh-Migration-Loop-Ledger-P6.md](Mesh-Migration-Loop-Ledger-P6.md) — the loop's memory, created on iteration 1 (§7). It lives on disk, not in context. The P5 ledger is a finished record; **do not reuse it.**
**Scope:** build **P6** — the two §12 rows P5 did not land (**temporary text** and **hearts** onto the routed store, each replacing and deleting its legacy sealed-envelope path), the **receiver-side per-type size cap** the registry has been waiting for, and the **two prerequisites the post-close review put at the head of this list**: a signed **key-advertisement wire family** (so a mint can address every roster member, not only the ones it happens to be linked to) and a **mesh identity for the pairwise phase** (so the default two-device path has a meshID, a ledger and a destination set at all). Plus the projection's retryable-vs-final distinction, the `sentAt` monotonicity guard, the tier-1 battery for all of it, and P6's own tier-2 lane job — the two-session hearts/moderation ceremony across Simulators. **Stop the loop at the P6 boundary.** Photos already ride the routed path end to end (P5 item 13, `0a33bc7`) — that §12 row is done and is the pattern every other row copies.

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P6-2026-09-10.md and run one iteration of it.
```

Self-paced (no interval): the work is build-and-test-bound, not clock-bound, so the loop wakes when
work completes, not on a timer. A session that is not a `/loop` runs the same iterations back to
back; the ledger is the state either way.

---

## 0. Orchestrator contract — read this first, it is the binding constraint

**The orchestrator is a limited model budget.** That is the scarcest resource in this project, scarcer
than build minutes or sim time. Every rule below exists to protect it.

### The orchestrator does not do the work. It decides what work happens next.

| Orchestrator DOES | Orchestrator DELEGATES |
|---|---|
| Read the ledger (one short file) | Reading any source file |
| Pick the next unblocked item | Writing or editing any file |
| Dispatch one subagent | Multi-file surveys, refactors, test authoring |
| Read the subagent's summary | Anything that would pull >100 lines into context |
| Grep one marker line out of a build log | Diagnosing a build failure |
| Update the ledger | — |
| Schedule the next wake | — |

Delegate with `Agent(..., model: "opus")`. Opus does the reading and writing; the orchestrator spends
tokens on judgement. A subagent that returns 40 lines of summary has saved the orchestrator thousands
of lines of file content — that ratio is the whole point. **Each item is three dispatches, never
one:** understand + design + implement (one agent, the ledger's decisions as input), then an
**adversarial verify** of the diff by a second agent that has not seen the first's reasoning (it reads
the item's acceptance criterion, the walls in §4 and the diff, and answers "what would make this
green for the wrong reason"), then a fix agent for what survives. When the owner has enabled
ultracode, the same three steps run as one small Workflow (P5 ran every item that way, 40–57 agents
each) — but a Workflow is the owner's opt-in, never the orchestrator's default. If Opus 529s at
spawn, ask the owner whether Opus is down rather than burning retries; if it is, omit `model:`.

### Hard token rules for the orchestrator

1. **Never `cat` a source file.** Use `sed -n '120,180p'` or a targeted `grep -n`. If you need more
   than ~60 lines of a file, that is a subagent's job.
2. **Never let build or test output reach context.** Always:
   ```bash
   xcodebuild … > "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG"
   grep -E "EXIT=|BUILD (SUCCEEDED|FAILED)|TEST EXECUTE|Test run with" "$LOG"
   ```
   Three lines in, not three thousand. Only if it failed do you hand `$LOG` to a subagent to diagnose.
3. **One work item per iteration.** Finish it, record it, wake again. Do not batch — a batched
   iteration that fails halfway leaves the ledger lying. (Bundling a genuinely tiny, file-disjoint
   fix as its *own commit* is fine, as P5's 1a/1b/6a were beside the items that exposed them.)
4. **Write state to the ledger, not to your own memory.** `/loop` resumes the *same* context and
   never compacts between iterations, so anything you keep in your head is paid for again on every
   subsequent turn and is lost if the session ends. The ledger is the only durable state.
5. **Stop early rather than run out.** See §6. A clean handoff is cheap; a loop that dies mid-item is
   expensive to reconstruct. When the ledger is the only thing a fresh session would need to resume,
   that is the moment to stop.
6. **When a close-out step needs synthesis across many verified facts (marking a phase BUILT, writing
   a handoff), use draft → adversarial two-lens verify → apply**, with drafts and corrections written
   to scratch files first — never one long inline agent call. P4's close-out caught 51 real
   corrections that way; P5's post-close review caught five more (one of them P1) that the close-out
   had not. Keep apply-step prompts short by pointing at files.
7. **A row that lands in two passes needs its gate to assert the later pass RAN** (§23.5). P5 item 13
   reported green with pass B untouched because the script's second pass never fired. Items 4 and 6
   below are each two passes by shape — a sender/format pass and a retirement pass — so "all green"
   means the retirement wall is *in the tree and green*, not that the run exited 0.

### If the budget runs out mid-phase

Stop the loop, write the handoff (§6/§8), and say plainly what is left. Do not silently degrade into
doing the work yourself — that is exactly how the budget disappears.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P6.md`. On iteration 1, create it from §7's
   template, seeded with the eleven items below. Thereafter it is already seeded — go straight to
   the next item.
2. **Check the tree is safe to build on** — first iteration, or after any owner activity:
   ```bash
   git -C . log --oneline -1; git -C . status --porcelain
   ```
   Another session has long held `App/Fernlet/Localizable.xcstrings` (a large foreign diff) and a
   personal `xcschememanagement.plist`; a stray untracked PDF sits in `Docs/`. **Leave all three
   alone**; never stage them. Commit with explicit pathspecs, never `git add -A`. If a new routed
   type adds catalog keys, sync the catalog from `HEAD`'s blob as the post-close review did
   (`f4a69f1`) — never from the held working copy.
3. **Pick the next item** whose prerequisites are met, from §3's list, in ledger order. Prefer a
   **tier-1** item over a tier-2 one — see §2.
4. **Dispatch the three agents** with the item's full context: the acceptance criterion, the walls it
   must not trip (§4), the decisions already taken in the ledger, and that the implementer must run
   the gauntlet subset for what it touched (§6).
5. **Verify** — grep the marker line out of its build/test log yourself. Do not take "it passed" on
   trust: this repo has notified a failed build as exit 0, a crossed log has shown ~20 phantom
   failures under concurrent-session contention, an interrupted-mid-run log has no markers at all
   (check the log's mtime is after the last source edit, and that a build succeeded after it), and a
   `-only-testing:` line naming a non-existent suite prints `TEST EXECUTE SUCCEEDED` over zero tests
   (check `Test run with N tests` is non-zero and count `◇ Suite` starts against `✔ Suite` passes).
6. **Commit** with explicit pathspecs (note `git mv` stages a rename immediately, so check
   `git diff --cached --name-status` first).
7. **Update the ledger**: item → done, with the SHA, one line on anything surprising, the next
   unblocked item, and any new sub-item the work exposed.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy (§12's own testing-lane paragraph, re-tiered 2026-09-01 and again at the P5 boundary, §23.5)

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | **Everything in items 1–9.** Key-advertisement records and their verifier; the pairwise promotion; the per-type cap; text and heart origination, custody, delivery and projection; the foreground heart ceremony behind its predicate; the retirement walls; the `sentAt` guard; and the P6 battery as **new cases in the existing routed overlay** (append after field 8, every draw unconditional, every field resolved — §23.5). All on `FakePeerNetwork` + `FakeMeshTransportSession` + an injected clock anchored to `MeshRoutedFixtureClock`, **no wall-clock sleeps**. **If a check CAN live here, it MUST.** The trust-vault rows hearts need are seeded directly at tier 1 — the two-session ceremony is a tier-2 *observation*, not a tier-1 precondition. | Free, deterministic, CI. |
| **2 — sim↔sim, real QUIC, 3 Simulators** | **Two things, and both are P6's, not the owner's.** (a) **Text on the routed path costs a harness change of zero** — `MeshFlowVerb.chat` / `.chatAgeGated` (`App/Fernlet/Proximity/Feasibility/MeshFlowDriver.swift:34`) already drive `sendTempMessage`, so the moment item 4 originates, the Lane C three-node run re-observes text as a *routed* flow; re-run it and record the rows. (b) **The two-session hearts/moderation ceremony** (§12, §23.5): both need mutual trust-vault rows, which need a *second* session — commit, end, complete `pendingFriendReview` on both sides, reconnect. Scripting that pair of sessions across two Simulators is this phase's first real lane job; `FriendReviewBatchTests` / `FriendMintingStoreTests` (suites in `FriendMintingTests.swift` — the file name is not a suite) and `MeshClothingShopTests` are the tier-1 precedents for the state it drives. Same Lane C harness, seams and env hooks (`FERNLET_MESH_ROLE`, `FERNLET_MESH_FLOWS`, `FERNLET_MESH_MATRIX*`, `FERNLET_MESH_CONSOLE_LOG`, `armFounderLedgerForHarness()`, runbook §Lane C at line 842 / three nodes at 1133). | One Mac, `simctl`, minutes per run. |
| **3 — physical devices** | Only §15's hardware gates. **P6 owes tier 3 nothing.** | Owner's time; not this phase. |

Lane gotchas carried from P2–P5 — obey them, they are all paid for:
- **Launch the sims ~1 s apart (`STAGGER=1`)**; always re-harvest identities after any `xcodebuild
  test` run (the full suite resets simulator app state).
- **A fresh log directory per run**, and `pgrep xcodebuild` before believing any failure.
- **The FIRST `test-without-building` after a build or an idle gap hangs** (`The test runner hung
  before establishing connection`, ~350 s, counted as 1 failed test); the second invocation passes.
  Warm the runner with a tiny suite before a gated step; never read a hung first invocation as red.
- **A two-node Lane C run with `FERNLET_MESH_LEAVE_AFTER` emits `terminated.v1`**, not
  `member-departure.v1` (three-node runs unaffected).
- **A lane photo (or, after item 4, text) failure is now a *routed* failure** — the legacy pull path
  is gone. Three lane-visible refusals are deliberate and by name until items 1–2 land: the pairwise
  phase has no transport at all (D-13.18), a mint refuses any destination without a verified X25519
  key (D-13.22 — star, over-cap, any resumption), and a capped destination raises
  `routedDeliveryHold`.

---

## 3. The work list

Ledger order. Each is one iteration unless noted. *File:line anchors are current at `3a32be0`;
re-check before editing — P6's own commits move them.*

| # | Item | Tier | Prereq |
|---|---|---|---|
| 1 | **The signed key-advertisement wire family** — `fernlet.mesh.key-agreement.v1`, the fix §11.3 item 13 names for D-13.22's three mint refusals (a **star** topology where two members never link, a roster above `maxTotalSlots` 5, and **any** resumption — restart, idle-lapse resume, rejoin — which restores the ledger but not the memory-only session roster). Each member signs **its own durable X25519 public key** (`IdentityService.swift:7` — `keyAgreementPrivateKey` is keychain-resident, ThisDeviceOnly, never rotated per session, which is what makes an advertisement worth persisting) under its **admitted Ed25519 key**, carrying `meshID` + `fingerprint` + key + `advertisedAt`; gossiped as a **grow-only set** bounded by `MeshMembershipBounds.maxRecordsPerKind` (16, the admission set's capacity); **full trio** (golden, crypto-domain registry row, framing-transcript case) in one commit. The receive door verifies against `ledger.admissions` (the same trust root as the ledger), so a verified advertisement becomes the **third verified source** the mint's resolver accepts. The resolver is `routedDestinationKeys(for:)` (`MeshNetworkManager.swift:4798`, doc `:4785–4797`) and it already merges **two** verified sources — every live slot's `verifiedKeyAgreementPublicKey` and every `sessionRoster` entry (`MeshSessionRosterEntry.keyAgreementPublicKey`, `MeshSessionTypes.swift:138`, written by `recordSessionParticipant` from the same handshake-verified value); D-13.1's rule is the `destinationNotAddressable` doc at `MeshRoutedOrigination.swift:46–50` — amend it, not work around it. Precedence = a handshake-verified key (slot or roster) first, else the advertised key; **a handshake-verified key present and unequal to the advertised one ⇒ refuse that destination by name** (`keyMismatch`, a new `MeshRoutedShareRefusal` case → app copy + catalog) — a durable key that disagrees with the handshake is a substitution or a re-provisioned identity, never a case to pick one. `MeshMember.keyAgreementPublicKey` (descriptor gossip, `Wire/MeshPayloads.swift:35`, doc `:25–28` — "never used for sealing") stays **unverified** and stays out. Persist the set inside `MeshSessionContext` (schema **2 → 3**, older treated as corrupt per P3's precedent; the context's wipe row already covers it — confirm, don't assume) so a resumption can address every member. Sent at the three ask doors (`beginMergeExchange`, `askOneReconnectedPeer`, `handleAdmissionGrant` — the same link-open moments the membership digest uses) as its own additive frame — **not** a fourth ask door and **not** a fifth `MeshMembershipRecordKind` (§5a). `theDrainFiresOnlyFromTheMergeDoor` counts only `sendRoutedInventory(` / `sendInventoryDigest(` / `sendRoutedBulk(`, so a new `sendKeyAdvertisements(` is invisible to it (as `sendEpochHeads(` already is): **amending that wall to count the new send is mandatory, and the amended wall must be shown red once.** `R-16` (`aMintAfterASessionResetRefusesVisiblyWithTheLedgerIntact`, the resumption refusal §11.3 item 13 pins) and `R-12` (the star refusal — "a destination with no handshake-verified key refuses the whole mint, visibly") flip from asserting the refusal to asserting the **mint succeeds** (delivery still needs a link or a departure hand-off — say exactly which of the three named refusals becomes a delivery and which only a custodied mint; do not overclaim). **`R-17`** (`aCaptureWithNoDestinationsStillReachesTheOwnWallSilently`, the `.noDestinations` silent echo) is **item 2's** cell to flip, not this item's. **Owner-gate note:** plan §23.4 and §11.3 item 13 call this and item 2 "strictly bigger than a P6 item" and owner-gated; the post-close review recommended taking both *before* text and hearts and the P5 ledger records that recommendation as taken — this launcher takes them under that record, and §8.2 reports both as policy acts. | 1 | — |
| 2 | **A mesh identity for the pairwise phase** (D-13.18, §11.3 item 13(i)). Today `promoteToMesh()` (`MeshNetworkManager.swift:8324`) fires at **two** commits (`:54` — "pairwise → mesh at two commits"), so a two-device auto-dwell stays `currentMesh == nil` all session: no meshID, no membership ledger, no destination set, and a capture there is cached on the user's own wall and shared with **nobody**, silently — the default two-device path, and the first thing a hardware validation hits. `startNewMesh` (`:1517`) would form one but is **unreachable from the app** (`startJoin()`, `:1608`, is the only entry). Default: **promote at ONE committed peer** (§5b) — reuse every existing door rather than mint a second, descriptor-less ledger shape. **Audit first, then flip:** list in the ledger every behaviour `currentMesh != nil` switches on for a two-device session (group-key rotation and epochs, the ledger + re-gossip, the Live Activity title, the shop window, `pendingFriendReview`, the session ceiling/idle-lapse machine, the rejoin bar) and state for each whether a two-device session should now carry it; the item's cells assert the pairwise photo is **delivered**, not `.skipped(.noDestinations)`, and that a third commit still merges into the same mesh. The false comment the review corrected ("shared when the session promotes") must not come back in any form. Prereq 1 because a promoted pair with no advertisement would still refuse after a resumption. | 1 | 1 |
| 3 | **The receiver-side per-type size cap, in ONE commit with P6's first narrowed cap** (D-11.4, §23.3): the check at the manifest door (`entry.maxItemByteCount` against `manifest.size`, the sealed *ciphertext* blob), its new `MeshRoutedManifestRejection` case, and that case's **NON-dropping** arm in `MeshRoutedParkedDrop.reason` (D-9.3: only `unknownTypeToken ∧ sender == origin` drops; an over-cap manifest keeps its bytes — say why in the arm). The first narrowed cap is the **photo row's**: `PrivateMediaStore.maxIncomingPhotoBytes` — **widen its access rather than restating 10 MB**, and keep the registry doc's ciphertext-vs-plaintext distinction (the ciphertext cap must exceed the plaintext bound by the sealer's overhead, stated as a formula, not a literal). Pre-store exit ⇒ through `refuseRoutedFrameBeforeStore` (the refusal budget's one door; `MeshRoutedRefusalBudgetTests`' wall counts it). File-disjoint from items 1–2; a good first iteration if 1 is still in design. | 1 | — |
| 4 | **Temporary text on the routed store** (§12). *Sender pass:* `sendTempMessage` (`:9434`) becomes the **three lines `shareRoutedPhoto` (`:1820`) uses** — `routedTypes.token(forCanonicalStore: .sessionTranscript)` → encode a `MeshRoutedTextBody` framed per `MeshRoutedItemBodyFormat` (`MeshRoutedItemBody.swift:37`: `[.sortedKeys, .withoutEscapingSlashes]`, `.secondsSince1970` both ends, length-prefixed header ‖ raw payload, never one `Codable` blob; all three hostile framing shapes land on the one frozen `malformed` token) → `originateRoutedItem(body:typeToken:itemID:now:)` (`:4756`), delivered by `pushOriginatedItem` (`:4907`), surfacing only a refusal. The text row's cap narrows to the sanitized maximum's ciphertext bound (item 3's formula). The 13+ age gate stays at the send **and** is re-applied at projection. `sessionMessages.appendOutgoing` stays — the projection is the UI. *Receiver pass:* a `.sessionTranscript` arm in `routedCanonicalDispatch` (`:5786`) → re-apply `isChatAllowed` + the block list → `SessionMessageStore.receiveIncoming(id:senderFingerprint:senderDisplayName:text:sentAt:) -> Bool` (`SessionMessageStore.swift:135` — it already dedups, sanitizes and flood-caps per sender, and audits a `false` as `mesh.tempMessage.refused`; do not re-implement any of that in the arm), with **`.sessionTranscript` added to `projectableRoutedTypeTokens` (`:2204`) in the same edit** (D-13.34) and **wall W2(b) extended to that first real canonical-mutation verb in the same commit** (`MeshRoutedLockedDeviceTests.swift:808–838`); the five W2 pins (`:768–772`) move and name their predicate. Session rules: the transcript still **vanishes at session end** (`clearSessionMessagesIfSessionEnded`), and a routed text item whose session has ended is **not projected at re-entry** — cleared per §12, custody kept until expiry. *Retirement pass:* the legacy `.tempMessage` fan-out (`:9453–9456`) and its handler are **deleted**, their symbols added to a zero-list wall beside `theRetiredPhotoTransportIsGone` (`MeshRoutedDrainTests.swift`), `onTempMessageSendForTesting` re-aimed at the origination, and `SessionMessageStore`'s "memory-only, never persisted" guard rewritten per §17.3 (projection memory-only; sealed inbox beneath is the durable truth). Then the tier-2 `.chat` re-observation (item 10a) is free. | 1 | 1, 2, 3 |
| 5 | **The projection's retryable-vs-final distinction** (D-13.32, §23.3 — "build it when P6 adds its second projectable type"). A refusing projection is deliberately not marked projected, so a refusing set larger than the 16-item re-entry allowance (`reentryProjectRoutedContent`, `:5163`) starves new items; with one arm that needs 16 simultaneously-refusing photos, and §23.3 says "with three arms it is ordinary" — at this item's prerequisite point there are two, and the third (item 6) must not land before this distinction exists. **Final** (blocked origin, removed origin `mesh.routedProjection.originRemoved`, unregistered-store `noDispatchArm`, a malformed body) is excluded from `itemsAwaitingLocalProjection` for good; **retryable** (an origin the admission ledger cannot resolve *yet*, a store that answered deferred) is re-tried under its own sub-allowance so it cannot occupy the whole pass. Decide where the final mark lives (durable on the routed index — schema bump — vs memory-only re-derived each pass) and say why; a mark that dies with the process is honest only if the refusal is re-derivable from the bytes. | 1 | 4 |
| 6 | **Hearts on the routed store** (§12). *Registry:* flip the heart row's `destinations` (`MeshRoutedTypeRegistry.swift:285`, in `increment1` at `:263`, heart row `:282–290`) to **`.singleRecipient` in place** (§5c — `:37–40` says exactly "until P6 lands one and flips the column", and no build has ever minted `fernlet.mesh.routed-type.heart.v1`; the entry doc at `:113–120` is amended in the same commit) and land the **subset initializer** on `MeshDeliveryTarget` (`MeshDeliveryTarget.swift:334` is the only one; the new one refuses a recipient outside the roster-at-creation by name) so the mint's `unsupportedDestinationSemantics` refusal retires. *Sender pass:* `sendSessionHeart` (`:788`) keeps every gate it has — `allowNearbyHearts`, active-record-only, `heartLedger.canSendHeart(to:)`, the fingerprint-keyed in-flight claim, `sessionHeartState` feedback — and its delivery becomes the three lines: `MeshRoutedHeartBody` (**`itemID == giftID`**, frozen for this token — `MeshRoutedAck.swift`'s `guard proof.giftID == giftID` is the enforcement; `sentAtDayKey` as today), `.heartLedger` token, `originateRoutedItem`. **Consume-on-stage** (§5d): `.staged` ⇒ `recordHeartSent` + `onHeartSent` + `.sent`; a refusal ⇒ `.failed` with the refusal's copy. The live-slot requirement goes with the legacy send — a heart to an admitted member who is not linked right now is custodied and drained later, which is the whole point of the routed store. *Receiver pass — the ceremony P5 wired and left fail-closed:* behind **`mayCommitRoutedHeartLedgerJudgement`** (`mayDecryptRoutedContent ∧ mayMutateCanonicalStoreWithRoutedContent ∧ sessionState == .activeForeground`, D-10.12 — the one stage whose source demands foreground) at **both** the live delivery door and `reentryHeartStage` (`:5191`, today a counted no-op reached from `reentryFinishLocalAcks`' job 4c, `:5111`): unwrap → `allowNearbyHearts` + `PresenceManager.isHeartEligibleFriend(peer, in: store)` (the trust-vault + block-list gate the legacy handler at `:740` applies) → `heartLedger.recordReceivedHeart(id: giftID, …)` (`ProximityHeartLedger.swift:215`; dedup + cooldown live there and are never re-implemented) → `commitProof(for:)` (`:284`) → `MeshRoutedHeartAck(outcome:giftID:proof:)` (nil unless judged exactly once *and* `proof.giftID == giftID`, D-4.8/4.9) → `committingDelivery(… evidence: .heartLedgerCommit(ack))`. A non-eligible recipient is a **final** refusal (item 5), audited, custody kept until expiry. `.heartLedger` joins `projectableRoutedTypeTokens` in the same edit; the W2 pins move again (`MeshRoutedHeartAck(` 0 → 1, `.heartLedgerCommit(` 1 → 2). *Retirement pass:* the `.friendHeart` handler (`:740`), `deliverSessionHeart`'s sealed send (`:844`, the module's one `.friendHeart` call site) and `HeartPayload`'s mesh use are **deleted** into the zero-list wall; `onSessionHeartSendForTesting` re-aimed. **Leave the presence-path heart fallback alone** — `canSendSessionHeart(toFingerprint:)` (`:780`) is the seam the app reads (`App/Fernlet/DisposableCameraView.swift:1676`/`:1687`) before falling back to `PresenceManager.sendHeart(to:)` (`PresenceManager.swift:641`); it must keep answering truthfully for a *routed* heart (an admitted member with an advertised key and no live slot is now sendable), and the presence path itself is P9's. Inherited residual, handed on unchanged: a heart never foregrounded before the mesh ends expires at `hardDeadline + 20 min` as `custodied(by: self)` (D-4.5). | 1 | 1, 5 |
| 7 | **The `sentAt` monotonicity guard on `recordPeerRoutedInventory`** (`:3962`; D-12.12 amended, §23.3: take it). A peer's own replayed older digest currently regresses this device's view of that peer's holdings and re-stamps `quiescentLocalAsOf` from the stale instant — a stale delta, budget-bounded, never a lost delivery. Refuse `payload.sentAt < inventorySentAt` by name (audit token, no budget charge — the digest family stays outside the refusal budget, D-5.12/D-6.10) and **assert in the property battery that `inventorySentAt` never moves backwards**. Its own commit: it changes items 5/6's door behaviour and the stamp item 7's window rule reads. | 1 | — |
| 8 | **The departed-origin custodian-forwarding cell** for `sendRoutedChunks`' slot un-record (P5 item 12's `forget(frameID:from:)` — "a repaired chunk slot must be refillable"), explicitly not taken by P5 item 14 because rectangle C's pipeline ends at the hand-off assertions and holds no forwarding leg. Needs a **second rig**: origin departs (item 8's push), the custodian forwards to a destination whose chunk slot was repaired, the window must not answer `replayed` for the refilled slot. Tier 1, one cell plus its negative control. | 1 | — |
| 9 | **The P6 acceptance battery.** New cases in the **existing** routed overlay (`MeshConvergenceSchedule.swift` — `seed ^ routedSalt ^ routedShapeSalt(shape)`, 40 cells over P4's five shapes and root seed `0x00F32B1C00090002`): a text origination and a heart origination as **fields appended after field 8, every draw unconditional, every field resolved** (§23.5); **never a new `MeshScheduleEvent` case** (D-14.1). Invariants: every text and heart destination reaches `delivered` or a closed state; a heart's ledger is judged **exactly once** per gift across any partition tree — the per-gift witness is `MeshRoutedHeartAck.judgementsForGift` (`MeshRoutedAck.swift:198`), **never** the batch counter `MeshHeartCommitOutcome.judgements` (`MeshContentIngest.swift:217`; `MeshRoutedAck.swift:205–207` forbids `== 1` on it); no text projected below the age gate; the advertised-key set converges on every member; a pairwise session delivers. Mirror P5's shape: one serialized `MeshP6<Clause>AcceptanceTests` suite per clause (KeyAdvertisement, PairwiseIdentity, PerTypeCap, TextRouting, ProjectionRetry, HeartCeremony, Determinism), reverted mutations proving non-vacuity, and **the CI gate lines in the SAME commit** — `CIGateSelectorBoundaryTests` fails any declared `MeshP6*AcceptanceTests` that `.github/workflows/s3-wall.yml`'s mesh step does not name (the step is `Scripts/run-gated-suites.sh mesh-batteries 113 …`; raise the floor to the measured count). Of the two pinned SHA-256 digests in `MeshP5DeterminismAcceptanceTests`, **`pinnedOverlayDigest`** (over the 40 routed overlays) **will** move because the overlay grew, and **`pinnedScheduleDigest`** (over P4's 80 membership schedules) **must not** — if it does, a `MeshScheduleEvent` case was added. The overlay digest's new value is a decision recorded in the ledger, never a silent re-pin. | 1 | 1–8 |
| 10 | **Tier 2, P6's own lane work** (§2): (a) the Lane C three-node run with `.chat` after item 4 — text observed as a routed flow, rows added to the runbook's Lane C section; (b) the **two-session hearts/moderation script** — commit, end, complete `pendingFriendReview` on both sides, reconnect, send a heart, observe the foreground ceremony and the recipient receipt on the wire, then a removal vote under the same rows; recorded as new Lane C rows with dates. Timebox to two iterations; what does not cross is recorded by name and handed to the owner list, never left as "flaky". | 2 | 4, 6 |
| 11 | **Close-out** (§8): §12 BUILT with §12.1–§12.4, the §24 P7 handoff, the P7 launcher, the memory note. | 1 | 1–10 |

### Not this phase

- **Relay increment 2** (live third-party relay of in-flight chunks). Still gated on the tier-2
  measurement §11 names (chunk pacing at 256 KiB, control-stream starvation) — not run, so not
  earned. No hop plumbing "for later".
- **Option (b) for `handleEncryptedMetadata`** (`:9688`) — delete the receive-only door whole and park
  `PayloadType.meshEncryptedMetadata`. A wire/interop decision, owner's (§23.4). P6 must not
  re-introduce an epoch anywhere on the routed path; `theRoutedPathNamesNoEpochSymbol` is the wall.
- **D-7.30's per-session re-gossip budget** once-per-window — transport decision, blast radius all
  120 cells and both digests. Owner's.
- **§18.2 partition UX copy** (default: subtitle count only, no new string); **the legacy unsigned
  two-party removal's retirement** (frozen); **transcript `sid`** (§18 decision 7).
- **Hardware:** Lane A report, Lane B double-dial, item 11's AWDL half, Lane D. Owner's.
- **1c** (the P4 quorum cell's load flake) and **6b** (main-actor drain I/O) — record any new
  sighting in the ledger, do not chase; **H-1a.3/H-1a.4** (four app-side `unowned` hosts; the
  un-cancelled fan-out) — app target, outside P6.
- **`MeshSessionContext.routingInventoryDigest`** (dead since P5 item 5, still a decoded schema-2
  field): §23.4 (`:3051`) says its disposal is the owner's. Item 1 bumps that schema anyway, so the
  default is to **retire the field in the same bump and amend §23.4's line in that commit** — an
  owner "keep" said before item 1 lands overrides; afterwards it is recorded as taken, not owed. The `MeshRoutedAckStageTable.increment1` alias deletion
  is unowed cleanup; take it at close-out only if it costs nothing.
- **The census/duress questions** for `com.fernlet.mesh-session` / `com.fernlet.mesh-routed`
  (§23.4). Owner's. Item 1's schema bump adds no new keychain service.
- **§17.3's `PrivacyInfo` / privacy-copy paragraph** — by the first TestFlight build; P6 makes it
  plural (text and hearts held as ciphertext by nearby devices). Draft the sentence in the ledger at
  close-out; the owner places it.

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| **How text and hearts originate** | **The same three lines photos use** — `routedTypes.token(forCanonicalStore:)` → encode → `originateRoutedItem`, delivered by `pushOriginatedItem`. No new send door, no advertisement, no second per-type source. | D-13.31 (`noShippingCodeBranchesOnARoutedTypeToken` fails the build on a typed token) and D-13.28 (an advertisement delivers nothing — the drain is push-only and inverted). |
| **The legacy path each row replaces** | **Delete it with the row, in the same commit, into a zero-list wall** — as item 13 did for photos. | Keeping both alive is what makes a retirement a fiction (D-13.18's inadmissible fix). |
| **Key advertisement: family shape** | **A new additive frame family with its own door**, not a fifth `MeshMembershipRecordKind`. | §5a. A fifth kind widens the membership digest and the re-gossip budget (`maxProofs` = 49 = `maxReGossipFrames`, pinned), moving goldens P4 held still across three commits. |
| **Key advertisement: where it persists** | `MeshSessionContext`, schema **2 → 3**, older corrupt. | Public keys of admitted members are session-context data (the roster already lives there); a separate sidecar would owe a wipe row and a fifth-state discipline for no gain. |
| **Pairwise identity** | **Promote at one committed peer.** | §5b. Reuses every existing door; a descriptor-less two-member ledger is a second shape P7/P8 would have to gate separately. |
| **Heart destination semantics** | **`.singleRecipient`, flipped in place**, with the subset initializer. | §5c. The registry's own doc anticipated the flip; nothing has ever minted heart v1, so the freezing rule's failure mode (silent divergence between builds) cannot occur. |
| **Heart send feedback** | **Consume-on-stage**: `.staged` is "Sent". | §5d. Durable-before-acknowledged makes the stage the durable moment; the recipient's dedup makes a re-send harmless. |
| **The second `MeshRoutedExpiryRule` case** | **Not added.** Text and hearts keep `.meshHardDeadlinePlusGrace`; D-11.22's discriminating test stays owed. | Expiry is bound into four verifiers' floored equality — a per-type rule is a fleet-wide flag day, and nothing in §12 needs one (the transcript clears by *projection* rule, not by expiry). |
| **Durable attribution after the mesh ends** | **Fail-closed, for text and hearts too** — an origin the admission ledger cannot resolve is a refusal, custody kept, one audit line. Item 5 decides only whether that refusal is retryable. | D-13.21. Item 1 is the real answer for keys; identity stays the ledger's. |
| **Body framing** | **`MeshRoutedItemBodyFormat`'s frozen pair**, or a stated reason. | D-13.20/13.20a — `JSONEncoder` base64s `Data`, silently re-scaling `manifest.size`, the chunk count and item 9's caps. |

---

## 4. Walls that will bite

- **The registry is the only per-type source.** `noShippingCodeBranchesOnARoutedTypeToken` permits
  `MeshRoutedTypeToken.` only where the constants are declared and the rows are built; a sender asks
  `token(forCanonicalStore:)`. **The shipped rule freezes `finalAck` and `destinations` once a token
  is *registered*** (`MeshRoutedTypeRegistry.swift:113–120`; only `maxItemByteCount` and
  `canonicalStore` are editable in place) — item 6's flip **amends** that rule rather than fitting
  inside it: edit the doc in the same commit, and state the reason the amendment is safe (no build
  has ever minted heart v1, so the rule's failure mode — silent divergence between builds — has no
  second build to diverge from).
- **Seven doors answer `entry(for:) == nil` as "unknown"** — a new door that consults the registry
  answers the same way, never a default.
- **The drain's shape is walled by count.** `theDrainFiresOnlyFromTheMergeDoor` pins
  `sendRoutedInventory(` at 4, `sendInventoryDigest(` at 6 and names every door from a brace-matched
  body; `sendRoutedBulk(` has a call-site count. Item 1's advertisement rides the existing doors and
  adds none; if it must add a call, **amend the wall by name** in the same commit.
- **Every pre-store refusal exits through `refuseRoutedFrameBeforeStore`** (`MeshRoutedRefusalBudget`,
  cap `sessionFramesPerPeer` 1056, sender = the authenticated envelope sender); the wall in
  `MeshRoutedRefusalBudgetTests` counts the exits. The two digest doors stay outside it.
- **No epoch on the routed path.** `theRoutedPathNamesNoEpochSymbol` — nothing routed reads a key
  epoch, a group key, a branch or a roster version; the replay window is keyed
  `(meshID, author, contentID)` and `admit` runs only when the outcome is `.completed ∧ settled`.
- **W2 and its pins.** `everyRoutedPlaintextSeamNamesItsPredicate` sweeps all of
  `FernletKit/Sources/ProximityKit` (asserting `sources.count >= 100`, so a shrunken sweep fails) for
  five spellings with `elsewhere == 0`; `theRoutedStoreNamesNoDecryptionSeam` scans a **literal list
  of 12 routed-store files** (`scanned == files.count` guards a dropped name, not the sweep) — a new
  routed-store file joins that list or is never scanned. **Move the pin, name the predicate, add the
  file — same commit.** A canonical mutation names
  `mayMutateCanonicalStoreWithRoutedContent`; a decrypt names `mayDecryptRoutedContent`; the heart
  judgement names `mayCommitRoutedHeartLedgerJudgement`, each defined **once**.
- **Two admission doors, and only two.** `theStoreHasExactlyTwoAdmissionDoors` (`recordAdmitting` /
  `recordStaging`, both carrying `capacityRefusal(`). A mint inherits the refusal or fails the wall.
- **The routed overlay's discipline.** Append after field 8; every draw unconditional; every field a
  resolved value; **no new `MeshScheduleEvent` case** — one more element re-phases every P4 shape and
  seed and voids §10.10's evidence *and its provenance*. `MeshP5DeterminismAcceptanceTests`' two
  digests move only as a recorded decision.
- **The CI selector wall.** Every `MeshP<n>*AcceptanceTests` declared in the tree must be named in
  s3-wall.yml's mesh step, every named suite must be declared, and every step runs through
  `Scripts/run-gated-suites.sh <label> <min-tests> <Suite>…` with a floor the step actually meets.
- **Wire discipline.** New wire content = a **new additive frame** with the **full trio** (golden,
  crypto-domain row, `canonicalSerializerTranscriptsMatchTheirDeclaredFraming` case) in one commit;
  never a widened existing frame; **never re-pin a golden** (the `91c3956` lesson: ~200 unexplained
  failures). Ed25519 signatures are hedged — goldens exclude the signature bytes.
- **Schema bumps.** `MeshSessionContext` is **2**; item 1 makes it **3** with older-as-corrupt and the
  five-state load discipline (`loaded` / `absent` / `deferred` / `corrupt` + seal-refused). The routed
  index is **2**; item 5 may make it 3 the same way. Never conflate the two.
- **Wipe wall.** Any new persisted surface or `UserDefaults` key owes a `Docs/PrivacyWipeCoverage.md`
  row **and** delete-all writer wiring in the same commit. Item 1 adds no surface (confirm the
  context's row wording still covers what it now holds).
- **Fixture discipline.** `MeshRoutedFixtureClock` is the one anchor (a ninth hardcoded copy fails
  two cells); `ensureProvisioned()` + roster size as a hard precondition; distinct `identity:` per
  manager; one `ProximityCoordinator` per link; sample state right after a synchronous pump, never
  after an `await`; heals ordered; a healed partition re-forms with a second commit round; test fakes
  hold fabrics `weak`; `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on the test target.
- **Localization.** Wire tokens, `rawValue`s and refusal spellings stay **frozen English**; display
  text forks in the app as `LocalizedStringKey` (`RoutedShareRefusalCopy` is the pattern for a new
  refusal case — its test is exhaustive over `CaseIterable`, so a new case fails it until copied).
  Never `String` for UI text. The age gate is a **product rule**, applied at the send and again at
  the projection.
- **Power of 10:** ≤ 60 code lines per function/`body`, bounded loops, no `!`/`try!`/`as!`/
  `fatalError`, no swallowed `try?`, no mutable globals, no nested `#if`, warnings-as-errors. The
  heart ceremony wants to be one long function; split it before the scanner does.
- **MC containment:** `TransportNeutralityBoundaryTests` permits MC types only in
  `MeshMultipeerSession.swift` / `MCPeerIDStore.swift`.
- **DocC:** every new type carries `///`; `doc-coverage-scan.py` stays at zero; the ProximityKit
  landing page, `Docs/ProximityFunctionIndex.md` and `Docs/FileIndex.md` gain their rows in the
  same commit as the file.
- **Do NOT touch** `App/Fernlet/Localizable.xcstrings`'s working copy or
  `App/Fernlet.xcodeproj/xcuserdata/**` (held by another session), or the stray PDF in `Docs/`. A
  catalog sync is done against `HEAD`'s blob and staged as a blob (`f4a69f1`).

---

## 5. Four items with a design call inside

### (a) The key advertisement is an additive family, not a fifth record kind (item 1)

The tempting shape is a fifth `MeshMembershipRecordKind` — it would ride the ledger's gossip, merge
and adoption for free. It is the wrong shape for three reasons that are all walls: the membership
digest (`fernlet.mesh.inventory-digest.v1`) and its golden enumerate records by kind; the re-gossip
budget `maxReGossipFrames` = `maxProofs` = 49 is pinned by assertion against `maxRecordsPerKind * 3
+ maxTerminationRecords`, so a fifth kind moves a number P4's 80 cells and P5's 40 cells were
measured under; and a key is not a membership fact — it is *addressing* for an already-admitted
member, so it must verify against the admission and can never create, end or revoke one. Build it
as its own signed record with its own verifier, sent at the link-open moments the membership digest
already uses, folded into a grow-only set on the session context. The one behaviour it changes is
the mint's resolver: a verified advertisement is a second verified source with a stated precedence
and a named mismatch refusal.

### (b) Promote at one commit (item 2)

The pairwise phase exists because v1's product had a two-person "friend" ceremony before a "mesh"
existed; P5 made the routed store the only content path, so a session with no mesh is now a session
with no content. Forming the mesh at the first commit reuses the founder/joiner doors, the ledger,
the ceiling and every P3–P5 cell as they stand. The cost is that a two-device session now carries
everything a mesh carries — rotation, epochs, the ledger, the Live Activity title — and the audit in
item 2 is what makes that a decision rather than a side effect. The alternative (a descriptor-less
two-member ledger) is a second session shape that P7's run policy and P8's continuation would each
have to gate; reject it unless the audit finds a behaviour a pair must not have.

### (c) The heart row flips in place (item 6)

`MeshRoutedTypeEntry`'s doc (`:113–120`) freezes `destinations` once a token is *registered*,
because two builds disagreeing on it diverge silently — and the same file's `.singleRecipient` doc
(`:37–40`) promises that P6 "lands one and flips the column". The two conflict; the flip resolves it
in favour of the column's promise, and the entry doc is amended in the same commit to say a
never-minted row may be re-declared once. The freezing rule's failure mode needs a build that
*mints* the old value; none exists — heart v1 has been registered, admitted and custodied by nobody.
Flip it, land the subset initializer, and write the v2-token alternative into the commit so the next
reader knows it was weighed. If the owner disagrees, the cost of a `…heart.v2` token is one registry
row and one test pin, not a redesign. Report the amendment as a policy act at close-out (§8.2).

### (d) Consume-on-stage (item 6)

The legacy heart consumed on the wire write because the wire write was the only durable moment it
had. The routed store's stage is durable-before-acknowledged: a `.staged` outcome means the sealed
item is on disk with a signed manifest and will be pushed, drained or custody-transferred until it is
delivered or expires. That *is* "sent" in every sense the cooldown protects — a second tap inside
the window would mint a second gift the recipient's ledger dedups. Arm the cooldown, feed closeness
and show `.sent` at `.staged`; show the refusal's copy at `.refused`; keep the in-flight claim for the
synchronous window between the tap and the stage.

---

## 6. Stop conditions — end the loop on any of these

Call `ScheduleWakeup({stop: true})` (or, outside a `/loop`, simply stop), write the handoff (§8), and
report.

1. **P6 is complete** — every item done, gauntlet green, §12 marked BUILT, P7 handoff written.
2. **Blocked on the owner** and no tier-1 work remains. Say exactly what is needed and stop; do not
   idle-wake waiting for a human. (Every §3 decision has a default, so this should not happen before
   item 10.)
3. **Budget is running low.** Stop with items to spare, not at zero.
4. **Context is filling.** `/loop` resumes the same context and never compacts, so a long P6 will run
   out. When the ledger is the only thing you would need to resume, stop and let a fresh session
   continue from it.
5. **A gate goes red for a reason you did not cause.** Record it, stop, report — do not spend
   iterations bisecting someone else's commit. (`sync-string-catalogs.sh --check` may still be
   known-red on stale keys from the held catalog — **do not bisect it.**)

### Gauntlet — the subagent runs it; you check the marker line

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh          # once anything wall-relevant moves
Scripts/spm-wall-selftest.sh       # after any change to the wall or its permit lists
```

Full `FernletTests` was last **recorded** at **4615 green in 461 suites, 1128.6 s, one invocation**
(`3f323e9`, plan §11.4/§23.5); the post-close corrections added five suites and no full run at
`3a32be0` is recorded anywhere, so **P6's first full run establishes the new baseline — write the
number into the ledger**. Check the **exit code** and the `Test run with N tests` line, never a grep
for "passed". Per-item, the subset is: every suite the diff touches + the routed suites
(`MeshRouted*`, `MeshP5*`, `MeshP6*`) + the wall suites (`MeshRoutedLockedDeviceTests`,
`MeshRoutedDrainTests`, `MeshRoutedRefusalBudgetTests`, `CryptographicPurposeBoundaryTests`,
`CIGateSelectorBoundaryTests`, `LocalizationBoundaryTests`, `PowerOfTenBoundaryTests`) —
**regenerate the suite list from the `@Suite` declarations**, never inherit one (P5 lost two runs to
a stale list). The property battery runs its **fixed seed family** (root `0x00F32B1C00090002`).

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P6.md` on iteration 1 if absent. Keep it **short** — it is
read on every wake, so every line costs orchestrator budget forever.

```markdown
# Mesh Migration Loop Ledger — P6

**Phase:** P6 (feature routing — text, hearts, key advertisement) · **Prompt:** [Next-Round-Prompt-Mesh-P6-2026-09-10.md](Next-Round-Prompt-Mesh-P6-2026-09-10.md)
**Started:** <date> · **Iteration:** <n> · **Tree at seed:** main = `3a32be0`

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | Key-advertisement wire family `fernlet.mesh.key-agreement.v1` | 1 | — | todo | | additive family, own door; MeshSessionContext 2→3; second verified source + keyMismatch |
| 2 | Pairwise mesh identity — promote at one commit | 1 | 1 | todo | | audit what currentMesh != nil switches on first |
| 3 | Receiver-side per-type cap + photo row's narrowed cap | 1 | — | todo | | one commit: check + rejection case + non-dropping arm |
| 4 | Temporary text on the routed store | 1 | 1, 2, 3 | todo | | three passes: sender / receiver+W2(b) / retirement wall |
| 5 | Projection retryable-vs-final | 1 | 4 | todo | | final excluded; retryable sub-allowance |
| 6 | Hearts on the routed store | 1 | 1, 5 | todo | | .singleRecipient flip + subset init; ceremony behind mayCommitRoutedHeartLedgerJudgement; consume-on-stage |
| 7 | sentAt monotonicity guard | 1 | — | todo | | own commit; battery asserts never backwards |
| 8 | Departed-origin custodian-forwarding cell (second rig) | 1 | — | todo | | owed by name from P5 item 12/14 |
| 9 | P6 acceptance battery + CI gate lines | 1 | 1–8 | todo | | overlay fields after 8; MeshP6*AcceptanceTests; s3-wall.yml same commit |
| 10 | Tier 2: Lane C .chat re-run + two-session hearts/moderation script | 2 | 4, 6 | todo | | timebox two iterations |
| 11 | Close-out: §12 BUILT, §24 P7 handoff, P7 launcher, memory | 1 | 1–10 | todo | | draft → verify → apply from files |

## Blocked on owner
- Option (b) for handleEncryptedMetadata; D-7.30 once-per-window; §18.2 copy; legacy unsigned removal; transcript sid; hardware lanes; census/duress for the two mesh keychain services; final wording of the routed hold/refusal copy.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Key advertisement family shape | (default: additive family, own door, not a record kind) | — |
| Key advertisement persistence | (default: MeshSessionContext 2→3, older corrupt) | — |
| Pairwise identity | (default: promote at one commit) | — |
| Heart destinations | (default: .singleRecipient flipped in place + subset init) | — |
| Heart send feedback | (default: consume-on-stage) | — |
| Second expiry rule | (default: not added) | — |
| routingInventoryDigest | (default: retired in item 1's schema bump) | — |

## Surprises worth not re-deriving
- (carry the P5 lessons below until they stop earning their place)

## Next item
3 (file-disjoint, no prereq) or 1 — the orchestrator's call on iteration 1
```

**Lessons carried from P5 — seed the surprises list with these so P6 does not re-learn them:**
- **`test-without-building` runs the LAST build.** A reverted probe still in the bundle produced 11
  red suites / 243 issues. Revert, then REBUILD, then test.
- **A suites list is only as good as its names.** A non-existent suite, or a *file* rather than a
  `@Suite` struct, runs zero tests under a green banner; count `◇ Suite` starts against `✔ Suite`
  passes; a `@Suite("display name")` prints its display name, so grep the struct name and the
  display name.
- **The first test invocation after a build or an idle gap hangs** (~350 s, 1 "failed" test); the
  retry is the acceptance. Warm the runner with a tiny suite first.
- **A process-global audit signal cannot witness a per-cell claim** when suites run concurrently in
  one process; witness per run (`MeshRoutedBackpressureAuditCapture`'s global handler is the named
  hazard, D-6a.10).
- **CryptoKit Ed25519 signatures are hedged.** Never compare signed records by full `==`; goldens
  exclude the signature bytes. `CryptographicWallScan` matches primitive names in *comments* too.
- **`#expect(_, "comment")` needs a literal comment**; `#expect(xs.allSatisfy(\.p))` fails to build —
  bind the Bool first.
- **ColumnCrypto seals with a fresh nonce on every write** — compare decoded values, never sealed
  bytes.
- **An empty routed store's pre-first-unlock refusal arrives at `.seal`, not `.open`**; a
  corrupt-quarantine test must establish the seal key before planting garbage.
- **A settle's `until:` fires synchronously inside the pump** — assert on the frame count, not on
  the state change that provoked it.
- **After fixing an `unowned` trap, expect the next `unowned` down the call chain**; test fakes hold
  fabrics `weak`; `MeshNetworkManager` still holds its host store `unowned` — use the rigs.
- **`activeSlots` is a distance rank, not a reach set**; `reachableRosterFingerprints()` is the same
  trap with a helpful name. Reach = every committed slot ∩ derived roster.
- **A parameterized `@Test(arguments:)` over an empty array is green over nothing.**
- **`MeshQuorumFixtures` mints placeholder-signed proposals the verifier refuses** — a removed origin
  needs a real `SignedRemovalRecord.signed(…)` on a 3-rig.
- **A `ProximityPayloadHandling` conformance cannot take a `now:`** — inject the clock one call below.
- **`Result<_, MeshRoutedUnavailability>` will not compile and must not** — it is an outcome value.
- **`MeshRoutedStorageScope.production` may not appear as a literal in any test source** —
  assemble it at run time.
- **Workflows and long agent calls can die of the session usage limit** at a fixed local reset hour;
  resume rather than retry, and start the longest work right after a reset.
- **Close-out apply steps read inputs from scratch files, not a long inline prompt** (529s).
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family (`96337a3`,
  `2f273a9`), the crypto-purpose / `PayloadType` / record-kind spellings (walled), plan §10.7–§10.10
  and §11.1–§11.4, `Docs/Proximity-Security-Followups-2026-08-18.md` §1.
- Concurrent sessions share this tree and sim fleet; `Localizable.xcstrings` +
  `xcschememanagement.plist` are held by another session — never stage them.

---

## 8. Close-out, when P6 is done

1. Mark P6 **BUILT** in §12 of the plan with landing SHAs, adding §12.1–§12.4 in the §11.1–§11.4
   format (what landed; deviations from the sketch and why; findings for the owner deliberately not
   fixed; acceptance evidence with the verified `-only-testing` lines).
2. Record deviations from the sketch and why — say where §12 was silent and what default (§3) was
   taken, and which §5 calls the owner should read as policy acts (the family shape, the promotion
   point, the in-place flip).
3. Record findings you deliberately did NOT fix, with what they cost, the way §11.3 does.
4. Memory note: what landed, what surprised you, what the next session must not re-derive.
5. Write the **P7 handoff block** (a new §24, in the §23 format). P7 is the app-layer run policy
   (§13): hand it the exact `apply(_:)`-shaped door P5 built (`applyRoutedAccessGate(_:now:)`, six
   `FernletApp.swift` call sites, `routedGateForeground(for:)` deciding foreground once), the
   sessionState leg the heart predicate reads and where it will *disagree* with the pushed leg once
   P8's `.continuingInBackground` is real (§23.5), the poller's three consumers
   (`enforceSessionCeiling` / `evaluateIdleLapse` / `evaluatePartition`), and what item 2's
   promotion change did to the two-device session's lifecycle.
6. Write the **P7 launcher** from §24, as this file was written from §23.
7. **Run the close-out as draft → adversarial verify → apply from files** (§0 rule 6); consider a
   post-close external review as P5 had — it found a P1.
8. Note anything P6 learned that re-tiers P7–P8 further.

---

## 9. The road to TestFlight

The owner's goal is the whole migration before the first TestFlight build. After P6, three phases remain.

| Session | Phase | Prerequisite |
|---|---|---|
| P2 (done) | NetworkMeshSession over QUIC | built + proven sim↔sim |
| P3 (done) | durable context, roster, membership | built; three sims form a full mesh |
| P4 (done) | partition + merge | built; property test found 3 merge defects, all closed by P5 |
| P5 (done) | encrypted store-and-forward routing | built (§11 BUILT `848f202`; review corrections `3a32be0`); photos ride it end to end; 4638 green |
| **this** | **P6** — feature routing (text, hearts) + key advertisement + pairwise identity | P5. Closes the two feature outages item 13 named and the hearts/moderation ceremony P2 could not reach. |
| +1 | **P7** — app-layer run policy | P3's states; **mostly wiring** — `ProximityRunPolicy` becomes the single writer of `applyRoutedAccessGate` and the poller's three consumers. Can interleave earlier. |
| +2 | **P8** — background continuation | **§15 gates: physical devices, multi-hour soaks, Low Power Mode, battery — irreducibly physical.** First hardware sample: iOS ended a user-started continued-processing task ≈ 46 s in. |
| +3 | **P9/P10** — remaining radios, MC retirement (iOS 27), companion `BGAppRefreshTask` | P2 proven in the field. |

**The tier-1 re-tier holds through P6 and not into P8.** P6's one genuinely-lane question is the
two-session ceremony, and it is a sim-lane question. P8's background/battery/thermal gates are the
one thing that still needs the phone drawer and the multi-hour soaks TestFlight does not supply.

**Still owed by the owner, not blocking P6** (carried from §23.4, unchanged unless P6 resolves one):
- **Hardware, unchanged:** the Lane A report, Lane B's double-dial row, the **AWDL half** of item
  11, and **Lane D** with the cable OUT.
- ~~**The first push.**~~ **Done and green:** `3a32be0` is at parity with `origin/main`, and both
  hosted workflows (S3 Wall, Power of 10) completed **success** on it on 2026-09-06 — the first CI
  build of P4/P5 code, batteries gated. The 1c load flake did not show there (one run; not proof).
- **Option (b)**, **D-7.30**, **transcript `sid`**, **the legacy unsigned removal**, **§18.2 copy**,
  **the census/duress questions**, **the final wording** of the routed hold and refusal copy (item 1
  adds one more refusal sentence).
- **§17.3's privacy paragraph** by the first TestFlight build — now plural; and **downgrade
  `browsed peers=` from `.notice`/`.public`** before QUIC ships.
- **The `HeartDrop` CloudKit record type** is still missing from the container.

# Moderation self-ban recovery — design note (2026-09-23 tracker §3.5)

**Status:** implemented on the moderation-ledgers branch (2026-09-24). Owner instruction: "Those
gaps should be addressed." This note covers what was built, why it cannot be used to dodge a real
ban, and which decisions are still the owner's to make.

## The problem as found

The clothing shop's self-ban is the device's own 30-day "your shop is paused" state. A designer
gets it when at least three artworks each carry reports from at least two distinct, vault-trusted,
one-hop reporters, with no reporter counting toward more than two of that designer's artworks
(`ClothingModerationLimits`: 2 / 3 / 2). So it takes at least three people. The audit of
2026-09-23 confirmed four things:

- **It cannot be wiped.** The record is a keychain row under a dedicated service, account
  `selfBan.device`, ThisDeviceOnly. It survives reinstall, "Delete everything" and identity
  rotation, and a clock-tamper-proof countdown times it. All of that is deliberate (2026-07-17: a
  ban a wipe could clear is a ban-evasion tool).
- **Nothing ever lifted it.** `reconcile` only applied bans. `writeBanIfNotActive` never shortened
  one. A reporter's retraction reduced the live report count, but the ban stayed in force. The
  only exit was the full 30 days.
- **The UI was not honest.** `ShopAlert` said the shop reopens "after a while", and
  `selfBanRemainingSeconds()` had no caller.
- **Colluding reporters can impose one.** Three colluding friends can impose a ban with
  fabricated artwork hashes (SEC-M17). The owner accepted that on 2026-08-19 as a disclosed
  residual.

## What is implemented

**1. The alert names the real remaining time.** `listCustomItemForSale` returns
`.storeBanned(remainingSeconds:)`, and the refusal and the number come from the same keychain
read. The alert reads "It reopens automatically in 30 days / 36 hours / 12 minutes". The count is
one unit, always rounded UP, so the copy never promises the shop back early. Foundation's
`Duration.UnitsFormatStyle` localizes the unit and its plural. The sentence around it is a catalog
key (`… in %@ — …`), so translators control the word order (`ShopBanRemainingTime`,
`App/Fernlet/ShopAlert.swift`).

**2. A ban records the evidence it rests on, and reporters' withdrawals can lift it.**

- *What is recorded.* When a ban is applied, the keychain record stores that ban's evidence as
  `BanEvidence`. Each entry holds a reporter tag, the artwork hash and the report's `reporterSeq`.
  The tag is SHA-256 over a registered domain
  (`FernletCryptoPurpose.Hash.moderationBanReporterTagV1`), a fresh random 32-byte salt for this
  ban, and the reporter's key.
- *Why a tag, not a key.* This row survives "Delete everything", so it must never hold another
  person's key. The salt makes tags from different bans unlinkable.
- *What "withdrawn" means.* On every reconcile, an active ban removes the entries whose reporter
  has positively withdrawn: the ledger's winning row for that reporter and artwork is a `retract`
  with a higher seq. Any new live reports are folded in.
- *When the ban lifts.* The ban lifts when (a) at least one entry was withdrawn and (b) what is
  left no longer reaches the threshold. "Lifted" means the countdown is no longer consulted. The
  artworks this ban had claimed are handed back, so a reporter who withdraws and then re-reports
  re-arms a ban rather than being waved through as "already served" (`ModerationBanRecovery` in
  FernletDomainModel; `ModerationBanStore.reconcile`).

  The threshold is tested **without** the per-reporter cap, deliberately. The capped count is not
  monotone: adding reports can lower it, because the greedy cap assignment shifts. The uncapped
  count is monotone and never lower. So the lift test can only err towards keeping a ban, never
  towards lifting one early.

**3. Retraction needed no protocol change.** A retraction is already a first-class ledger row
(`ModerationEntryKind.retract`, superseding its report by a higher `reporterSeq`), and it already
travels. `ModerationReportRelay.buildPayload` sends reports and retracts together, and
`verifiedRows` accepts both under the same one-hop signature binding. The lift consumes what the
wire already carries. (What does *not* exist is a way to produce a retract — see the open
questions.)

**4. Peer bans follow the same rule.** This device's own 30-day ban on another designer lifts when
the reporters behind it withdraw. It uses the same code path. For a peer ban, the local user's own
report counts as evidence, and so does their own withdrawal.

**5. Old records.** A record written before this change, or by the direct `applySelfBan` path,
has no evidence. It can only serve out its time.

## The policy in three lines

1. **A ban ends when its time is served, or when the people who reported it take their reports
   back.** Nothing else ends it.
2. **Only a positive withdrawal counts.** Missing rows, decayed rows and clock moves never count.
3. **The banned device's own rows never count**, for or against its own ban.

## Why the banned person cannot lift their own ban

Each of these is pinned by a test in `ModerationBanRecoveryAdversarialTests`. Each cell also ends
with a genuine withdrawal and requires the lift, so no cell can pass by breaking lifting
altogether.

| The banned person's move | What it does to the evidence | Result |
| --- | --- | --- |
| "Delete everything" (clears the ledger, rotates the identity, sweeps peer bans) | Rows are **absent**; the evidence rides the keychain row | Ban stands |
| Delete and reinstall | Keychain row survives; ledger sidecar gone (absent) | Ban stands |
| Block or remove the reporters | Their rows stop arriving (the mesh drops blocked or untrusted senders) or are later evicted: **absent** | Ban stands |
| Report or retract with their own key | Own rows are ignored in both directions | Ban stands |
| Get someone who never reported them to send a retract | The tag matches no recorded evidence | Ban stands |
| Move the clock forward (decaying every report) or back; reboot | Decay is not withdrawal; the countdown already defeats clock tampering | Ban stands |

Every cell was shown **red** against the plant that would let its move through:

- the wipe, reinstall, block, own-rows and clock cells against a naive lift that re-evaluates the
  current ledger, so that absence and decay count as withdrawal (PLANT-2);
- the own-rows cell also against a lift that does not exclude the banned device's own key
  (PLANT-3);
- the stranger cell against a lift that accepts any retract for the artwork, whoever signed it
  (PLANT-4).

Its post-wipe step is the one that bites. With the ledger intact, the reporters' still-live reports
re-enter through the live-evidence merge, which is a second defense.

All the lift cells were red against the old never-lift behavior (PLANT-1).

What the banned person *can* do is ask a reporter to withdraw. That is the designed recovery path,
and it is the reporter's decision.

## Still the owner's call

1. **Nothing produces a retraction yet.** The recovery path is live but has no producer:
   `ModerationLedger.recordLocalRetract` has no caller, so no build can take a report back.
   - *Where it would live.* A "Withdraw report" action would naturally sit on a reported friend's
     card in Friends & Blocks, where "Reported" is already shown.
   - *Whether it should also unblock.* Reporting also blocks the maker
     (`reportClothingItem` → `proximityTrustVault.report(…, blockAlso: true)`). The reporter's rows
     are only relayed to vault-trusted friends, so a withdrawal reaches the banned maker only if the
     reporter trusts them again (meets them in person). This must be decided alongside the button.
   - *Recommendation:* the button withdraws only, and unblocking stays its own act.
2. **Should reports from reporters the banned person later blocked expire sooner?**
   *Recommendation: no.* Blocking is the banned person's own action. If it shortened the ban, that
   would be exactly the evasion rule 2 closes: block the three reporters and the ban ends early.
   Blocking already stops those reporters' future rows from arriving. That only removes their
   ability to *withdraw*, which is why the "Withdraw report" design in question 1 matters.
3. **No appeal path.** There is no server, so there is no appeal. The only exits are time and the
   reporters' own withdrawal. The shorter-ban options that remain are all blunt:
   - a shorter `banDurationDays`;
   - a one-time self-lift per device lifetime (it would weaken every legitimate ban equally);
   - binding self-ban evidence to artwork this device actually broadcast. This is SEC-M17's
     proposed fix, and it stops bans built on fabricated hashes without weakening real ones.

   The third is the only option that shrinks the collusion residual rather than the ban. The owner
   declined it on 2026-08-19; it is worth revisiting now that bans can lift.
4. **A re-arm starts a fresh 30 days.** A reporter who withdraws and then re-reports re-arms a
   full ban; the time served under the lifted one is not credited. Crediting it is possible (the
   record keeps its countdown) if the owner prefers.
5. **The lift is conservative in rare cases.** Because the lift test ignores the per-reporter cap,
   an evidence set that the capped rule would no longer ban can stay banned. Example: two reporters
   left on three artworks. This only ever errs towards the ban.
6. **Evidence is bounded at 64 entries, 8 per artwork.** The most-reported artworks are kept
   first. A flood of one-reporter artworks never displaces the evidence a ban rests on. An
   extremely wide ban (more than 8 qualifying artworks) keeps only the most-reported ones. A
   withdrawal is then measured against those. This matters only if the reporters themselves both
   flood and withdraw.
7. **Privacy-policy wording (proposed, not applied).** §9 of `Docs/Privacy-Policy.md` could add:
   "If several friends report items you shared, your own shop may pause for up to 30 days. The app
   shows how long is left. The pause ends early if the people who reported you withdraw their
   reports. A record of the pause stays on this device, even after 'Delete everything', until it
   ends. It stores coded references to the reports, never who made them."

## Out of scope, named

- The routed mesh path does not consult `ModerationBanStore` (`MeshNetworkManager.swift` ~8191,
  ~8649 — a mesh residual in the 09-23 tracker §3.4).
- Enforcement remains honest-client compliance. The load-bearing moderation is receiver-side
  hiding.

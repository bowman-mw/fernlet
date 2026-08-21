# Remaining Work — 2026-08-20

**Supersedes** [`RemainingWork-2026-07-19.md`](RemainingWork-2026-07-19.md).

Compiled from a five-track audit of `main` on 2026-08-20 that verified **every** claim in the
previous tracker against the code rather than against its own status lines. 226 commits landed in
the month between the two documents, and roughly a third of the old tracker turned out to be wrong
— in both directions. Items that had quietly shipped are struck; items that were understated are
promoted; two defects the old tracker never noticed are now at the top of §2.

Conventions: file references are `path:line` at audit time and **will drift** — grep, don't trust.
✅ = verified resolved in code on the date noted.

---

## 0. The one-paragraph version

The app is closer to shipping than the previous tracker implied, and almost nothing left is
feature work. The critical path is **owner paperwork in App Store Connect**, plus one large
unverified risk: **no two-device P2P flow has any recorded real-device validation**, in an app
whose largest module (`ProximityKit`, 19,258 lines) is exactly the part a simulator cannot
exercise. The cheapest high-information action available is to build a Release archive, which has
never once been done.

---

## 1. Release path

### Owner-only (no engineering can shorten these)

- **App Store Connect setup.** Create the app record; paste the App Description (ready-to-paste
  copy in [`Export-Compliance-Encryption.md`](Export-Compliance-Encryption.md) §10.3 — ASC will
  not assess encryption documentation until this field is populated); set Privacy Policy URL
  `https://fernlet.com/privacy/` and Support URL `https://fernlet.com/support/`; enter the labels
  from [`App-Privacy-Nutrition-Labels.md`](App-Privacy-Nutrition-Labels.md); answer the age-rating
  questionnaire; walk the encryption flow; deselect China mainland and the Country Group E:1
  storefronts.
- **Promote `SealedPhotoRecord` to the Production CloudKit schema.** Flagged independently by two
  auditors. TestFlight runs against Production, Production does not auto-create record types, and
  the delete-everything teardown enumerates by record type — so a missing type means sealed photo
  backups cannot be restored **and** the wipe is silently incomplete. Also verify
  `HeartDrop.tag`/`HeartDrop.payload` rode along in the 2026-08-11 batched deploy;
  [`CloudKit-Schema-Deploy.md`](CloudKit-Schema-Deploy.md) says not to assume it.
- **Sign and date** the self-classification memo
  ([`Export-Self-Classification-Memo.md`](Export-Self-Classification-Memo.md) ends with an unsigned
  signature block) and file the one-time France/ANSSI declaration.
- **App Store screenshots** do not exist. No shortcut, but the UX-appearance UI-test harness plus
  the DEBUG launch hooks in `App/Fernlet/UITestSupport.swift` already produce per-screen galleries.

### Engineering

- **Build a Release archive and Validate App.** Never done. CI only runs `build-for-testing` in
  Debug, so whole-module optimization, `ENABLE_NS_ASSERTIONS = NO`, distribution code signing, and
  the real entitlements have been exercised nowhere. Highest information per hour on this list —
  and it settles the entitlement item below. Now a per-release checklist item in
  [`Release-Process.md`](Release-Process.md) §2.
- ✅ 2026-08-20 — **`TARGETED_DEVICE_FAMILY = "1"`** set on every configuration of all five
  targets that carried the setting (app, widgets, share extension, both test targets); the pbxproj
  diff touched exactly those ten lines.
- **Entitlements.** `App/Fernlet/Fernlet.entitlements` carries `aps-environment = development`
  plus a stray macOS-only `com.apple.developer.aps-environment` key. Keep the capability —
  `NSPersistentCloudKitContainer` needs the silent-push path — but delete the macOS key and
  confirm the distribution export carries `production`. Resolved by the archive above.

### ✅ Already done (the old tracker still lists these as pending)

- ✅ **Repository is public** — <https://github.com/bowman-mw/fernlet>.
- ✅ **`fernlet.com` is deployed** and `https://fernlet.com/privacy/` serves the policy at the
  matching effective date. The old tracker's "create the Cloudflare Pages project" step is moot.
- ✅ Export compliance is consistent with the 5D992.c determination *in code*:
  `ITSAppUsesNonExemptEncryption = YES` in both app configurations, zero StoreKit anywhere in the
  tree (the free invariant), Apache-2.0 source published (the public invariant).
- ✅ No TODO/placeholder strings a tester would see; DEBUG surfaces walled behind `#if DEBUG`;
  icons, launch screen, and version 1.0(1) consistent across all targets.

---

## 2. User-visible defects

Ordered by what a tester hits first. The previous tracker's seven items are reconciled at the end.

1. ✅ 2026-08-20 — **Disposable camera "Develop → Save selected"** now hydrates via
   `manager.hydratedPhotos(…)` like the ConnectView siblings, and FRND-12 landed with it: **Keep**
   is the primary action (no Photos authorization involved) with "Also save to Photos" secondary,
   so a Photos denial can no longer cost the in-app keep. Covered by `DisposableCameraSaveTests`
   (behavioral + source-wall). Residual closed 2026-08-21: ConnectView's disconnect-review now uses the
   same keep/export split (`ConnectReviewKeepTests`); the album carousel's per-photo Photos save was
   assessed and deliberately left — export is that button's point, no keep is at stake.
2. ✅ 2026-08-20 — **Settings → Health** now triages by real cause (`HealthAvailabilityState`):
   device-unavailable keeps the old message; integration-off says "Health is switched off for
   Fernlet." with a link to Privacy & Data (the toggle stays there, with its consent copy and audit
   logging). `HealthAvailabilityMessageTests` pins the three states.
3. ✅ 2026-08-20 — **Recipe web-image decompression bomb** closed with an 80 MP area clause at
   the shared `normalizedJPEG` funnel (both save paths). Deliberate deviation from reusing the
   24 MP peer predicate: that would reject stock iPhone camera output (5712×4284 = 24.47 MP) and
   the documented 48 MP picks. Worst hostile transient decode is now ~320 MB (bounded, same order
   as the user's own photos) vs ~1.6 GB. `MealPhotoDecompressionBombTests` includes a genuinely
   decodable declared-20000×20000 PNG fixture.
4. **Reset-app-lock confirmation still uses `.confirmationDialog`.** The systemic XCUT-02 fix
   landed and five siblings were converted to `.alert`; `FernletLockGate.swift:188` was left
   behind — and it is the one whose destructive button destroys the only key to the sealed
   journal/cycle corpus.
5. **Recipe detail never renders the recipe's steps** (FOOD-22). A user types steps into the
   editor, saves, and can only read them by entering cooking mode. `FoodView.swift:4191`
   composes eight sections and steps is not one of them. Labelled "mockup needed", but it is a
   plain functional gap.
6. **No contextual HealthKit request for workout logging** — and onboarding promises one. Cycle
   tracking *does* have a contextual request, but it throws and is swallowed whenever the master
   toggle is off. Same root cause as item 2; fix them together.
7. **First Aid card is user-removable**, and nothing else guarantees the crisis line stays
   reachable. Either protect `.firstAid` in `removeHomeWidget` or add the crisis resource to
   `SafetyReportingView` (whose search keyword already points there).
8. **Crisis nudge still has no trigger** — owner decided SHIP a month ago. Mitigating context the
   old tracker didn't record: First Aid is a permanent default Home card, so this is an
   enhancement to a working safety net, not a hole. Safety-adjacent design; deserves care, not
   speed.

### Reconciliation with the old §2

| Old item | Status now |
| --- | --- |
| 1. Settings → Move dead button + "M2" copy | Half-fixed — control and milestone tag gone, but the screen now carries *different* wrong copy denying a shipped feature |
| 2. Mesh admission prompt unreachable | ✅ Resolved — merged into a shared `JoinPromptSheet` with two live call sites |
| 3. No contextual HealthKit request | Partly wrong: cycle has one; workout does not — see §2.6 |
| 4. Hearts "for now" copy | ✅ Resolved — away-heart delivery shipped and the copy now branches on the user's own opt-out |
| 5. Crisis nudge trigger | Still open — see §2.8 |
| 6. Day Detail drift | **Cut.** §3.7 of the same document already closed it as accepted drift; the tracker contradicted itself |
| 7. Friend avatars a static glyph | Cosmetic, one surface, design intent now written into the code — defer |

---

## 3. Finished infrastructure with no consumer

The most expensive category in the repo: work that is done, tested, and returns nothing until a
screen exists. All three were understated or missing in the old tracker.

1. ✅ 2026-08-20 — **Per-exercise progress** shipped in both increments: a factual "Last time:
   3×8 @ 135 lb" recall line in the shared exercise row editor (WorkoutSheet / WorkoutPlanSheet /
   QuickExerciseSheet), and an "Exercise history" Move sub-screen (recency-ordered; last / best /
   times logged) — both driven by the one existing `rollUpExerciseHistory` implementation, no
   re-derived parsing, factual-only per the spec constraint. `ExerciseLastTimeTests` +
   `ExerciseHistoryScreenTests`. Residual closed 2026-08-21: GuidedWorkoutEditorSheet's per-exercise cards
   carry the same recall line (shared catalog key, own a11y id; `GuidedEditorLastTimeTests`).
2. ✅ 2026-08-20 — **AI audit log screen** shipped as "AI activity log" in Settings (Privacy
   section + settings search): every AI call, newest first — kind, destination, boundary badge,
   outcome incl. failures, field names only. The parked-token contract is honored and PINNED by
   test: a token recorded by a newer build renders verbatim with boundary "can't say", never the
   privacy-worst freeze default. `AIAuditLogScreenTests`. Residuals: the `hubLink` String idiom was
   forked 2026-08-21 (labels are `LocalizedStringKey`; `SettingsSearchEntry` split into frozen
   matching tokens + `displayTitle`, matching pinned English-stable by test). Screen still snapshots
   once per push (deliberate). ✅ 2026-08-21 — the two same-species follow-ups landed
   ([`Next-Round-Prompt-2026-08-21.md`](Next-Round-Prompt-2026-08-21.md) Parts 1–2): the settings
   search fold is locale-independent (`locale: nil`, pinned — `.current`'s Turkish case rules
   silently emptied results), and `hubToggle` took the same `LocalizedStringKey` fork as `hubLink`
   (type-only per the owner decision; the 11 switch labels are in the synced catalog, signature
   pinned beside `hubLink`'s). Still planned from that prompt: the milestone reset-boundary marker
   (Part 3; owner decided 2026-08-21: milestone marker + dialog disclosure for custom items/days).
   The 61 dynamic search-title keys still await the deferred search-catalog curation pass.
3. **The coach proximity channel.** Trust policy, verification ceremony, sealed wire envelope and
   pre-decode DoS caps — all hardened, all referenced only by tests. See §5.

---

## 3b. Delete-everything coverage — the promise has holes

A four-track audit on 2026-08-20 enumerated every persisted surface and checked each against the
wipe funnel. **~20 surfaces are not cleared**, five seriously. The full, verified list with fixes is
Part 4 of [`Next-Round-Prompt-2026-08-20.md`](Next-Round-Prompt-2026-08-20.md); the headline items:

1. ✅ 2026-08-20 — `fernlet.healthkit.requested-capabilities` is now `HealthCapabilityRequestLedger`,
   a device-only keychain row (never rides a backup, not `defaults read`-able), with a one-shot drain
   of the legacy plaintext key; cleared by the wipe funnel **and** by `disableIntegration()`.
2. ✅ 2026-08-20 — `purgeAllPersistedData()` now clears the whole `LegacyKeys` corpus (all six fixed
   families plus every `fernlet-day-*` row), so the wipe removes the unsealed JSON and the next
   launch has nothing to re-import. `LegacyKeysPurgeTests` pins the no-resurrection property.
3. ✅ 2026-08-20 — the Health-deletion offer now keys off "has Fernlet ever been prompted for a
   write-capable Health capability" (the persisted ledger from item 1), not the master toggle, and
   `deleteAllAuthoredSamples()` was verified ungated. Toggle-off users get the offer and honest copy.
4. Sealed photos are torn down by enumerating `SealedPhotoRecord` — the type still unpromoted in the
   Production CloudKit schema (§1). **Still open, owner action** (console-only; preflight in
   `Release-Process.md` §2 and `CloudKit-Schema-Deploy.md` both verified in place 2026-08-20).
5. ✅ 2026-08-20 — `SavedRecipes.json` gained a delete with a real failure signal, called from
   `resetAll`.

Also landed 2026-08-20 from the same audit's §4.2/§4.3 list: workout tombstone ring cleared (the
over-reach question was resolved: no funnel over-reach, but a surviving unconfirmed tombstone could
delete a kept Health sample on re-enable — the ring is now cleared), Recent-activity chips,
moderation **peer** bans (self-ban kept per the 2026-07-17 decision), the milestone ledger
(local + CloudKit, reversing the survive-by-design rule), the sealed friend photo-wall **index**
(now GCM-sealed under the wall key, with plaintext migration), `FernletPeerID.archive` (cleared with
identity rotation), companion petting state (the clear is no longer DEBUG-only), an unconditional
legacy direct-CloudKit sweep (previously gated on sync-off + kept-copy), and a main-store
checkpoint+vacuum residue pass (destroy is deliberately banned for the CloudKit-backed store; the
weaker guarantee is documented in `PrivacyWipeCoverage.md`).

✅ 2026-08-20/21 — the structural cause is closed: `PersistedSurfaceWipeBoundaryTests` now
DISCOVERS every UserDefaults-backed surface from source (accessor-anchored incl. receiver-checked
KVC `setValue`, `@AppStorage`, symbolic/interpolated key resolution, DEBUG stripped on both sides,
unresolvable keys become declared seams — never dropped) and requires each of the 52 discovered
surfaces to carry a `cleared`/`kept`/`unreachableByDesign`/`openGap` disposition, with cleared
tokens bound to their key through the coverage doc's table. Built adversarially: 4 attacker agents
produced 49 evasions; ~20 folded classes confirmed and fixed with planted fixtures (incl. two live
findings: a compound `#if DEBUG &&` the stripper missed, and an unregistered internal wipe leg),
6 documented as the honest ceiling in `PrivacyWipeCoverage.md`. Floors: ≥350 files, ≥52 surfaces,
16 always-rediscovered known keys. `DeleteAllDataTests` remains the behavioural complement.

---

## 4. Engineering health

Strong where most projects are weak: 2,519 tests across 226 suites with three skips repo-wide,
four independent mechanical walls, and near-zero dead code. Weak in two places that matter:

1. **No recorded real-device validation of any two-device P2P flow.** Both validation docs
   ([`Recipe-P2P-Real-Device-Validation.md`](Recipe-P2P-Real-Device-Validation.md),
   [`Friend-Shop-Real-Device-Validation.md`](Friend-Shop-Real-Device-Validation.md)) are
   procedures with no results section. Simulators cannot exercise MultipeerConnectivity or
   NearbyInteraction at all, so the entire social half of the app is unverified on the evidence in
   this repo. **Get a second iPhone, run both checklists on one build, and add a results block
   (date, build number, pass/fail per step) to each doc.** Do the friend-mesh connect path first.
2. **CI never runs the test suite** — only the seven boundary suites gate a push, by a decision
   (`Release-Process.md` §1) that made sense when CI was fragile and stopped making sense at eight
   commits a day. The pre-push hook builds but runs no tests. ~5-line workflow diff.
3. ✅ 2026-08-20 — **CODEOWNERS repaired**: the 11 stale pre-restructure paths fixed, the three
   never-added wall tests plus the Power-of-10 scanner/allowlist added, and
   `CodeOwnersResolutionTests` now fails loudly if any pattern stops resolving (anchored/trailing-slash
   semantics modeled; globs rejected; required-pattern floor set). `Release-Process.md` §1 and the
   `KeyCustodyBoundaryTests` tripwire comment are true again.
4. Two-device sync has no integration test. Don't build an automated two-device suite — run a
   scripted manual smoke on TestFlight instead (log on A → confirm on B → conflicting same-day
   edits → delete-all on A → confirm B).

---

## 5. Fernlet Coach — recommend closing the track

Its Fernlet-side prerequisites alone are months before Coach's own ~23 screens begin: signed
origin class, offline App Attest verification (an explicitly unvalidated go/no-go), coach vault and
pairing UI, universal links plus AASA hosting, and an App Clip. The manual clipboard exchange
shipped 2026-08-12 and already delivers the loop's actual value: export summary out, plan pasted
back, safety-passed, review-gated into dated `PlannedWorkout` rows.

A solo developer with an unlaunched first app should **close this track, not phase it**. The
specification stays as a record of the design.

---

## 6. Cut list

Confirmed zero-code, blocking nobody, serving no user who exists yet: BGTaskScheduler background
refresh, BIP39 mnemonic escrow, `ownedDevice`/`relationshipType`, App Attest, signed origin class,
universal links. Also cut: the Day Detail rework (§2 table above).

---

## 7. Open findings from the review rounds

The 2026-08 review rounds were real — both static walls still hold after 226 commits plus the
localization merge (Power-of-10: 370 files, 0 violations, density 0.695; doc coverage: 0
undocumented). The Power-of-10, memory-leak, doc-anomaly and security-hardening rounds are
**closed**; their residuals have no user-visible symptom.

What remains:

- Of the security review's five "unfixed" findings, four are refutations or clean-surface notes.
  Only **M17** (irreversible shop self-ban with no escape hatch) is genuinely open — and the real
  exposure is the irreversibility, not the attack: any bug producing three qualifying reports
  strands a user permanently. Owner decision.
- That same document's follow-up section lists five *further* open items it does not count,
  including the decompression bomb now promoted to §2.3.
- The UI/UX review's 45 "mockup needed" findings are **not blocked**: only 3 are High, 12 are Tier
  2 product decisions only the owner can make, and the rest carry precise written recommendations
  implementable today without a design round-trip.

---

## 8. Doc corrections made 2026-08-20

- [`Verifiability.md`](Verifiability.md) said the repo was private and the site undeployed. Both
  false since 2026-08-19 — on the project's most-read trust document.
- [`Release-Process.md`](Release-Process.md) §5 listed both publish steps as pending; §1 said five
  wall suites when the workflow runs seven. Added Release-archive and CloudKit-schema preflights
  to the §2 checklist.
- [`Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md`](Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md)
  opened with "proposed follow-up (not started)" while its own implementation-status section 180
  lines later said all five workstreams landed.
- [`Localization-Plan-2026-07-19.md`](Localization-Plan-2026-07-19.md) carries the Phase 0 and
  Phase 1 records (updated 2026-08-19/20).

**Lesson worth keeping:** every one of these documents was wrong in the direction of
*under-reporting progress*. A tracker that is never reconciled becomes a to-do list of things
already done, which is worse than no tracker — it spends the reader's attention on settled
questions. Reconcile against code, not against status lines.

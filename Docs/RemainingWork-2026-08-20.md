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
- **`TARGETED_DEVICE_FAMILY = "1"`.** The app target ships `"1,2,7"` — iPad *and* visionOS — with
  zero iPad adaptation (one comment in the whole app target mentions iPad), while `README.md` and
  `Site/index.html` both say "iPhone". Family 2 commits you to 13" iPad screenshots and an App
  Review pass on an iPhone-only layout; family 7 is meaningless in an `iphoneos`-only build.
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

1. **Disposable camera "Develop → Save selected" can never succeed.**
   `DisposableCameraView.swift:1298` hands `manager.sessionPhotos.filter { … }` straight to the
   Photos saver, but `MeshNetworkManager.swift:2917` stores `cachedPhoto.withoutImageData()`, so
   every payload has `imageData == nil`. The saver skips nil payloads and throws
   `NothingSavedError`; because `finishSessionPhotos(keeping:)` runs only on success, the photos
   are **never kept on the in-app wall either**. Two sibling call sites do it correctly
   (`ConnectView.swift:152`, `:868`) by wrapping in `manager.hydratedPhotos(…)`. End-of-session
   flow of a flagship social feature; logged 2026-08-04 and still open. No test covers this path.
2. **Settings → Health tells every new user their device can't do Health.**
   `SettingsSheet.swift:1122` renders "Health data is not available on this device" whenever
   `healthKit.snapshot.isAvailable` is false — but that flag is *not* device capability:
   `HealthKitService.swift:757` sets it to `isIntegrationEnabled`, and the master toggle defaults
   to **off** and lives on a different screen. So the default state of every fresh install names
   the wrong cause and offers no route out, on the gateway to a headline feature. Split the
   branch: `HKHealthStore.isHealthDataAvailable()` false ⇒ the device message; integration-off ⇒
   "Health is switched off for Fernlet" plus a control.
3. **Recipe web-image decompression bomb.** `MealPhotoStore.swift:337` caps each dimension at
   20,000 with no area clause, so a declared 20000×20000 (400 MP) image passes — a few hundred KB
   on the wire, ~1.6 GB decoded. The correct predicate already exists and is tested two files
   away (`PrivateMediaStore.isWithinSafePixelBounds`, enforcing dimension **and** pixel count) and
   MealPhotoStore already calls it on *restore* but not on `save`. Reachable from a shared recipe
   link via `FernletStore.swift:4126` / `:4294`.
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

1. **Per-exercise progress.** `TrainerExportBuilder.swift:587` computes, per exercise: sessions,
   total sets, first/last logged, last sets/reps/weight, best weight, and an Epley 1RM estimate.
   Its only production consumer is the trainer export. Fernlet ships a guided runner, a Live
   Activity, a plan approver and a logger, and cannot answer *"what did I lift last time?"* The
   parse-and-rollup half is already covered by `CoachPlanExchangeTests.swift:349`.
   **Highest-value unbuilt thing for an actual user.**
2. **AI audit log screen.** The log is an actor with a file-backed sink, a 500-entry ring, an
   `outcome` field with dispatch-then-update discipline, tolerant enum decode with parked tokens,
   four live call sites, and delete-all wiring — and `entries` is read by nobody.
   `AIAuditLog.swift:92` even spells out the display contract for the screen that does not exist.
   For a privacy-first app this is the strongest available proof point: *every AI call this device
   made, what kind, where it went, how it turned out.*
3. **The coach proximity channel.** Trust policy, verification ceremony, sealed wire envelope and
   pre-decode DoS caps — all hardened, all referenced only by tests. See §5.

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
3. **CODEOWNERS is stale after the repo restructure** — 11 of 26 paths match nothing, including
   *all seven* wall/crypto test files, which now live under `Tests/`. `Release-Process.md` and
   `KeyCustodyBoundaryTests.swift:197` both assert a protection that is currently false. Fifteen
   minutes, plus a check that every CODEOWNERS path resolves so the next restructure fails loudly.
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

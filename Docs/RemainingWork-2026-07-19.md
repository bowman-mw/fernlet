# Remaining Work — 2026-07-19

**Supersedes** [RemainingWork-2026-06-23.md](Completed%20Implemtations/RemainingWork-2026-06-23.md).
Compiled from a two-track code audit of `main` on 2026-07-19 (doc-tracker reconciliation + a
source-level sweep for stubs, dead seams, and stale copy). Everything shipped was verified in code,
not taken from doc status lines. The **Fernlet Coach** track is specified separately in
[FernletCoach-Specification-2026-07-19.md](FernletCoach-Specification-2026-07-19.md) — its items are
not duplicated here beyond the pointer in §7.

Conventions: file references are `path:line` at audit time. ✅ = resolved on the date noted.

---

## 1. App Store submission

- ✅ **Privacy policy finalized 2026-07-19** — contact `fernletapp@gmail.com`, effective date set,
  draft banners removed, doc + in-app copy (`Fernlet/PrivacyPolicyView.swift`) in sync.
- ✅ **LICENSE added 2026-07-19** — Apache-2.0, repo root (also unblocks coach-spec decision D5).
- ✅ **Internal-docs bundle leak fixed 2026-07-19** — 15 planning docs (including the full security
  code review and the period/intimacy plans) were in the app target's Resources phase and shipped
  inside the .app bundle. All 15 removed from the pbxproj; built bundle verified `.md`-free. Rule
  going forward: never add `Docs/` files to target membership.
- **Manual App Store Connect steps (unchanged, human-only):** host the policy text at a public URL
  and enter it in ASC; set the support email in the listing; enter the privacy nutrition labels from
  [App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md).
- **EULA/terms:** policy §9 now references the in-app safety rules and Apple's standard EULA; if a
  custom EULA is ever wanted, that's new work.
- **Release-country / compliance checklist (researched 2026-07-19):**
  - **Encryption declaration — DECIDED 2026-07-19: mass-market 5D992.c.** Flip
    `ITSAppUsesNonExemptEncryption` to true/non-exempt in ASC's flow, self-classify 5D992.c
    (standard CryptoKit crypto ⇒ no BIS reporting since 2021), and file the one-time France/ANSSI
    declaration via ASC. Rationale: the medical-end-use exemption would contradict the app's
    wellness-not-medical positioning (MDR / App Review).
  - **Pricing — DECIDED 2026-07-19: Fernlet is always free** (no IAP). EU DSA: declare
    **non-trader** — nothing gets published on EU product pages. (Coach-app monetization is a
    separate, later question — spec D7.)
  - **fernlet.com site: BUILT 2026-07-19** — the full static site lives in [`Site/`](../Site/README.md)
    (landing, `/privacy/` generated from Privacy-Policy.md, `/support/`, 404, Cloudflare `_headers`
    with the future-AASA content-type rule; zero JS/cookies/external requests, app theme colors,
    dark mode). **Remaining is owner-only:** create the free Cloudflare Pages project, deploy
    `Site/`, add the custom domain, switch nameservers at the registrar, then enter
    `https://fernlet.com/privacy/` + `https://fernlet.com/support/` in App Store Connect. Coach
    AASA + `/plan` pages get added at coach P0/P1 (deploy steps in the Site README).
  - **Age rating:** Apple's new 4+/9+/13+/16+/18+ questionnaire (mandatory since Jan 31 2026)
    covers medical/wellness topics + UGC; Fernlet's report/block flows satisfy the UGC
    requirements; intimacy features stay 18-gated in-app.
  - **US state age laws:** Texas App Store Accountability Act in effect since Jan 1 2026 (Utah et
    al. following) — consume the store-provided age-category/parental-consent signals, delete any
    personal data received for verification, notify stores on significant policy changes.
  - **China mainland: exclude** — the MIIT app-filing/ICP regime requires a Chinese entity or
    local partner; not viable for an indie release (all other ~174 storefronts are fine for a
    wellness app; Russia/Belarus have paid-app/payout suspensions).
  - HealthKit guideline 5.1.3 (no HK data in iCloud, no ads use) — already engineered: HK samples
    are deliberately excluded from the synced blob.

## 2. User-visible defects (fix next)

1. **Settings → Move claims a shipped feature doesn't exist.** `Fernlet/SettingsSheet.swift:678`
   shows "Available after Apple Fitness integration lands (M2)" beside a dead, disabled
   `Button("Request access") {}` (`:684`, `.disabled` at `:691`) — but the workout→Health write path
   is fully wired (`FernletStore.swift:1731` → `HealthSyncCoordinator.swift:59` →
   `WorkoutHealthKitSync.swift:69` → `HealthKitService.swift:715`). Replace with live status + a
   real request/consent control.
2. **Mesh admission requests can never surface.** `Fernlet/MeshAdmissionPromptSheet.swift` has zero
   call sites while the manager raises pending admissions (`MeshNetworkManager.swift:66,1683`).
   Wire the sheet (or delete it and the pending-admission path deliberately).
3. **No contextual HealthKit first-use request** — authorization is reachable only via the Settings
   toggle; Move/Home never prompt in context.
4. **Hearts copy promises a future** — "Hearts travel in person for now" at
   `Fernlet/FriendListView.swift:430` and `ProximityKit/Presence/PresenceManager.swift:508,518`.
   Either build remote send-heart (decided design: CloudKit E2EE dead-drop hybrid) or drop "for now."
5. **Crisis nudge trigger missing.** The 988 card exists (`Fernlet/FirstAidView.swift:181-189`) but
   the spec'd `moodTrend == declining` nudge has no trigger — `Fernlet/AmbientCards.swift:165`
   reads the trend and routes only to breathe/worry-box. Needs an explicit ship-or-cut decision.
6. **Day Detail drift vs spec** — still a NavigationStack push (`Fernlet/JournalView.swift:83-84`)
   with old empty-day copy (`:793`); spec wants a modal, split Log food / Log workout actions, and
   a narrower editing scope.
7. **Friend avatars are a static leaf glyph** — `FriendProfilePlaceholder`
   (`Fernlet/ConnectView.swift:794`, used `:648`); every photo-wall post header looks identical.

## 3. Product decisions — RESOLVED 2026-07-19 (owner decision round)

All decided by the owner in the 2026-07-19 decision round; the first four are now the
**implementation queue**:

1. **Crisis nudge: SHIP** — add the `moodTrend == declining` trigger as a gentle ambient offer
   routing to the existing First Aid surface (closes the June safety flag).
2. **Body photos, no lock configured: inline lock-setup nudge** on first body photo — skippable,
   never blocks (`ProgressPhotoTimeline.swift:49` gains the nudge path).
3. **Barcode: wire the web UPC lookup** behind the existing `webNutritionLookupEnabled` opt-in —
   **OpenFoodFacts API (free, keyless)** primary, USDA FoodData Central API (free key) as
   US-branded fallback; sends barcode digits only. No subscription. The offline ODR branded
   catalog stays the roadmap endgame.
4. **Mesh admission prompt: WIRE `MeshAdmissionPromptSheet`** (don't delete the path).
5. **Hearts copy: keep "for now"** — remote send-heart ships when the CloudKit dead-drop
   foundation lands with coach P1.
6. **Deferred without guilt** (parked, not blocking): `.aiResolved` inline FM branch ·
   goal-weight reconcile vs spec §6 · starter customization scope · home heart-bonus render.
7. **Day Detail: CLOSED as-is** — editing scope was decided "keep" in June; the modal/copy drift
   is accepted.

## 4. Unstarted / partial feature work

- **Localization (es/fr/de)** — full plan in
  [Localization-Plan-2026-07-19.md](Localization-Plan-2026-07-19.md): zero scaffolding exists
  today; Phase 0 fixes are live locale bugs even in English (Sunday-pinned calendar grids,
  US-only 988 crisis links, decimal-comma parsing, kg-only weight entry); regional food-data
  packs (CIQUAL/BLS 4.0/BEDCA via ODR) answered and sequenced as v2.
- **Third-party AI via OHTTP (plan Phase 17)** — nothing but a placeholder comment
  (`FernletKit/Sources/FernletDomainModel/AIDestination.swift:4`).
- **AI audit log durability** — in-memory only, no outcome/period fields
  (`FernletKit/Sources/AIContext/AIAuditLog.swift:31`).
- **Memory controls suite** — editable Core Memory UI, natural-language forget/edit, derived-signal
  inspection; two-tier AI journal extraction (storage-time classifier shipped, AI pass deferred).
- **Multi-device without iCloud, Phases 2–3**
  ([design](Multi-Device-Without-iCloud-Design-2026-06-29.md)): owned-device pairing
  (`relationshipType`/`ownedDevice` — zero hits), mesh backup transfer for new-device setup,
  truly-offline escrow (key still rides iCloud Keychain), mesh live-merge, and a settings
  field-merge policy (settings remain a last-writer-wins blob). *Phase 1 warnings and the per-row
  day split are shipped.*
- **BIP39 recovery codes** (sealed-backup escrow follow-up).
- **Background App Refresh** — zero `BGTaskScheduler` references.
- **Two-device sync integration tests** (claims currently untested).
- **Live micronutrients in recipe builder** — backend exists
  (`FernletStore.micronutrientTotals(for:)`, `Fernlet/FernletStore.swift:2833`), no UI binding.
- **Ingredient variant dedup + brand-disclosure grouping** (labels shipped, grouping didn't).
- **Manual people-tagging UI** for photos; **photo-surfacing exclusion** (blocked on deferred
  Sensitive Memory store).
- **Companion loading states during AI inference.**
- **Move per-exercise progress; sleep HealthKit summary** (plan Phase 6 residuals).
- **Onboarding production polish** (plan Phase 4 residuals).
- **Meal-estimation overhaul residue** — M1 dish decomposition, SQLite catalog, and the web product
  importer shipped; the chain-restaurant importer extension and dynamic product-image discovery from
  [Meal-Estimation-Overhaul-Plan.md](Meal-Estimation-Overhaul-Plan.md) were not re-audited item-by-item.
- ✅ **Send-heart remote delivery SHIPPED 2026-07-25** (bitchat adoptions Increment 3, branch
  `claude/bitchat-adoptions`, [Plan-Bitchat-Adoptions-2026-07-25.md](Completed%20Implemtations/Plan-Bitchat-Adoptions-2026-07-25.md)):
  CloudKit public-DB E2EE dead-drop + proximity hybrid, with one-time-prekey forward secrecy and
  day-rotating HMAC tags; opt-in `heartsAwayDelivery` (default OFF). The same round also landed
  wire2 sealed-payload compress+pad framing, the enforced privacy-wipe coverage checklist
  (identity keys now die with delete-all), and the QR verification ceremony for non-UWB commits.
  **OWNER ACTION before TestFlight:** promote the `HeartDrop` record type (`tag` queryable,
  `payload` bytes) from the CloudKit Development schema to Production in the console — dev
  auto-creates it on first save; production will not.
- **BLE wake-on-proximity presence** — deferred by decision 2026-07-25; design sketch in
  [Plan-Bitchat-Adoptions-2026-07-25.md](Completed%20Implemtations/Plan-Bitchat-Adoptions-2026-07-25.md) §E (tags/envelopes
  kept transport-agnostic for it); revisit with the Android/cross-platform transport work.
- **Cloud cascading-trust for large group activities** — deferred by scope from the social plan.

## 5. Tech debt & cleanup

- ✅ **FernletUI + FernletLockUI carved 2026-07-19** — design system (theme/fonts/tokens/primitives/
  ModelColors) and the lock views are package targets; ProximityKit gained `UI/` with the two
  app-free movers (KeepFriendsPromptSheet, FriendPhotoReviewSheet); nav enums stayed app-side in
  `Fernlet/FernletNavigation.swift`. Wall check + full suite green (1499/1500; the one failure is
  the pre-existing `ProximityCoordinatorTests.timeoutInDiscoveringMovesToEndedTimeout` load flake,
  3/3 green in isolation). The remaining 5 Proximity UI files stay app-side because they hold
  `FernletStore` refs — they move with a future §5d store inversion, not a UI carve.
- **AI-file inversions (the one remaining carve item, optional):** full verified implementation
  map now in [plan §14 item 1](SPM-Module-Carveup-Plan.md) — launch seam is ~16 members;
  dish-decomposition needs 4 downward moves incl. a Bundle.module resource migration;
  FoodProductWebImporter is blocked by an AppServices→AIProviders cycle.
- ✅ Flaky `test_reload_updatesReloadingState` — already hardened (synchronous observation
  recording); verified 3/3 green 2026-07-19.
- ✅ §5e-vs-§14 inconsistency resolved — §5e had actually shipped; annotated with the
  `DerivedSignalFactory`-in-LocalPersistence deviation.
- ✅ Dead `GoalsCard` deleted; ✅ stale `FernletFoundation`/`Package.swift` headers fixed;
  ✅ goals copy reworded to the permanent privacy stance; ✅ root-level
  `DisposableCameraView.swift`/`CompanionVectorAssets.swift` relocated into `Fernlet/` (explicit
  pbxproj refs removed). All 2026-07-19.
- **New watch item:** `ProximityCoordinatorTests.timeoutInDiscoveringMovesToEndedTimeout` is a
  load-sensitive flake under full-suite parallelism (same class as the fixed reload test).

## 6. Real-device verification queue

- #21 widget watchdog crash — re-check on device (sim artifact suspected).
- Guided-workout Live Activity end-to-end (sim proves plumbing only; one on-device confirm done
  2026-07-19 for the interactive flow — re-verify after any ActivityKit change).
- Body-photo detail must not re-prompt Face ID.
- #3 water widget — confirm with the tester before touching.
- Recipe-cap sender UX (connect timeout + visible rejection) — targeted check.

## 7. Fernlet Coach track (separate spec)

All coach work lives in [FernletCoach-Specification-2026-07-19.md](FernletCoach-Specification-2026-07-19.md)
(P0→P4). Nothing is implemented; the shipped groundwork is the declared wire seam (payload types,
`fernlet-coach` service string, `WorkoutPlanSource.coach`, trainer export file flow). P0 gates:
offline App Attest verify prototype, D11 `LPLinkMetadata` device test
([harness ready](D11-LinkMetadata-Prototype.md)), App Clip fragment survival, universal-link domain
(D6). D5 licensing: ✅ resolved 2026-07-19 by the Apache-2.0 LICENSE.

## 9. Survivors from the three closed review/brief docs (added 2026-08-09)

`CODE_REVIEW_2026-06-12.md`, `UI-UX-Redesign-Brief-2026-07-08.md`, and
`Design-Briefs-Report-Features-2026-07-05.md` were closed into `Completed Implemtations/` on
2026-08-09 after a code-verified reconciliation. Everything still genuinely open from them lives
here now, so the archived docs are not load-bearing.

**From the code review (10 of 195 findings open; 185 fixed):**

1. **Sealed backup replay/rollback** — `updatedAt`/versioning are not authenticated, so a record can
   be rolled back. *The only security item left.* Deferred by cost: needs versioned AAD plus a
   CloudKit re-seal migration.
2. **`SharedRecipeImportRecord` duplicated across the app and share-extension targets** with
   divergent App-Group fallback paths — and the extension-side mirror omits `budgetDeferredDayKey`
   while rewriting the whole queue file, so any share strips the budget-deferral stamp from every
   queued record. Also uncoordinated (no `NSFileCoordinator`) on the extension side. *This is now a
   real bug, not just duplication.*
3. **HTML fetch / JSON-LD helpers duplicated** between `RecipeWebImporter` and
   `FoodProductWebImporter` (`fetchHTML` still defined in both). Blocked by the
   `AppServices`→`AIProviders` cycle in [SPM-Module-Carveup-Plan.md](SPM-Module-Carveup-Plan.md) §14.
4. **Draft-exercise state machine copy-pasted** across `WorkoutSheet` and `WorkoutPlanSheet`
   (`MoveView.swift` 748/763 vs 2976/3005) — the row editor is shared, the state machine is not.
5. **Two parallel proximity audit trails** (`ConnectionSessionLog` + `TrainerAuditLog`) record the
   same events. Needs a keep-both-or-merge decision; may be intentional.
6. **`loadSnapshotAsync` duplicates the `loadDatabase` pipeline** in `CoreDataFernletRepository`. The
   snapshot-assembly half was fixed by `FernletSnapshot.assembled`; the load pipeline was not.
7. **`addJournal` overloads duplicate bookkeeping** — the today path uses `batchSnapshotPersistence`,
   the dated path uses `diary.mutateDay`.
8. **`SUPPORTED_PLATFORMS` claims macOS/visionOS** on several targets while sources import UIKit
   unconditionally.

**From the UI/UX brief (2 of 4 open questions; the other 2 were answered by shipped code):**

9. **Global IA (A1)** — flatten the Private tab to a NavigationStack list, or keep nested paging?
   Still a paged `TabView`.
10. **Settings (A2) + the placeholder `PersonalScreenView`** — decide whether Debug/Tier-2/Signals
    compile out under `DEBUG`; and the legacy `PersonalScreenView` path is still reachable **and
    still renders placeholder copy** ("Tap to view your cycle" on a non-tappable card; "Photo imports
    can live here when the photo picker is added"). Shipped placeholder UI — treat as a defect.

**From the design briefs (open *design* asks, not implementation work):**

11. **Briefs 12–14** — adventure/rest energy loop, proud-dandelion cumulative growth, and the
    cumulative history/insights view. Zero code exists for any of them; each brief is a question to a
    designer, so these need design answers before they can be scoped.

---

## 8. Reference docs status

> **Doc-structure pass 2026-08-09.** Nine completed plans were closed into `Completed Implemtations/`
> (security hardening + its WI-6 canonical-signing fix and session prompt, the bitchat-adoptions
> round, the coin ledger, the social Phase 6–7 and UI/UX review prompts, the 2026-05-28 architecture
> review, and the workout-rest research). All three indexes were refreshed, `ImplementationPlan.md`
> gained a reconciled phase-status table, and every markdown link in the repo now resolves.

- [ImplementationPlan.md](ImplementationPlan.md) — **refreshed 2026-08-09:** now carries a reconciled
  per-phase status table and a current "Next up" section. Its per-phase *prose* remains
  as-written-at-the-time; take completion state from the table, and fine-grained remaining work from
  this tracker.
- [Meal-Estimation-Overhaul-Plan.md](Meal-Estimation-Overhaul-Plan.md) — partially shipped; not
  re-audited item-by-item (see §4).
- [Fernlet-Review-and-Plan-Updates.md](Completed%20Implemtations/Fernlet-Review-and-Plan-Updates.md) — historical 2026-05-28
  review; its SEC-1/2/3 findings were fixed by the later security-hardening work.
- Function indexes ([StoreRepositoryFunctionIndex.md](StoreRepositoryFunctionIndex.md),
  [ProximityFunctionIndex.md](ProximityFunctionIndex.md)) — **refreshed 2026-08-09** with the
  subsystems shipped since 2026-07-19: away-hearts dead-drop, `ProtectedSidecar`, wire2 framing, the
  QR ceremony, the coach trust/ceremony types, the AI routing/budget seam, `AppendOnlyRowStore` and
  its ledger services, and the CloudKit heart-drop transport.
  [FileIndex.md](FileIndex.md) — **refreshed 2026-08-09**; a coverage scan now confirms every source
  file in the repo has a row (75 were missing, mostly the July AI-ladder, heart-drop, coach, and
  cooking-mode rounds).
- Ten completed plans were closed into `Completed Implemtations/` on 2026-07-19 and twelve more on
  2026-08-09, each with a status banner. The last three (the 2026-06-12 code review, the UI/UX
  redesign brief, and the report-feature design briefs) were closed after a code-verified
  reconciliation; their survivors are §9 above.

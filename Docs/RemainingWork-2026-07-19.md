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
  - **fernlet.com** is owned but unhosted/empty — it now has three jobs: host the privacy-policy
    page (the ASC public URL), and later the coach AASA + `/plan` static pages. A free static host
    (GitHub Pages / Cloudflare Pages) satisfies all three and the "no operated servers" rule.
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
- **Send-heart remote delivery** (decided: CloudKit public-DB E2EE dead-drop + proximity hybrid) —
  shares the dead-drop foundation with the coach track; unbuilt.
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

## 8. Reference docs status

- [ImplementationPlan.md](ImplementationPlan.md) — historical phase statuses are stale (2026-05-18
  era); trust this tracker instead. Kept for phase definitions and rationale.
- [Meal-Estimation-Overhaul-Plan.md](Meal-Estimation-Overhaul-Plan.md) — partially shipped; not
  re-audited item-by-item (see §4).
- [Fernlet-Review-and-Plan-Updates.md](Fernlet-Review-and-Plan-Updates.md) — historical 2026-05-28
  review; its SEC-1/2/3 findings were fixed by the later security-hardening work.
- Function indexes ([StoreRepositoryFunctionIndex.md](StoreRepositoryFunctionIndex.md),
  [ProximityFunctionIndex.md](ProximityFunctionIndex.md)) — not refreshed in this pass; verify
  against source when in doubt. [FileIndex.md](FileIndex.md) refreshed 2026-07-19.
- Ten completed plans were closed into `Completed Implemtations/` on 2026-07-19, each with a status
  banner.

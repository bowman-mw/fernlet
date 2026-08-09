> **CLOSED 2026-08-09 — SUPERSEDED.** Historical 2026-05-28 architecture review. Its SEC-1/2/3 findings were fixed by the later security-hardening work, and its Parts D–H change-lists were applied to the three referenced planning docs at the time. Superseded as a live document by [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md); kept for the rationale behind the phase ordering it introduced.

# Fernlet — Architecture Review & Planning Updates

**Date:** 2026-05-28
**Scope:** Security & privacy audit, progress-vs-spec, friction features, meal/recipe overhaul, settings consolidation, plus ready-to-merge updates for `FernletSpecificationV3.md`, `ImplementationPlan.md`, and `MeshNetworkImplementationPlan.md`.
**Method:** Internal source + design audit against the v3 spec. Findings cite `file:line` evidence. This is a planning document — it specifies *what to build and in what order*; it does not change code.

> **How to use this doc.** Parts A–C are the review. Parts D–E are new phases written in your plans' own style, ready to slot in as the next phases. Parts F–H are change-lists for the three docs plus the settings/friction designs. The doc updates have been applied as targeted patches to the three referenced files, so nothing in those large files gets silently dropped.

---

## Part A — Security & Privacy Findings

Ranked by severity. The headline: **today, no app data leaves the device for AI at all** — there is no third-party/OHTTP provider in the codebase, and the only AI is on-device Foundation Models. So the live risk surface is (1) what the *on-device* model receives, (2) what is encrypted at rest, and (3) proximity. The architecture you *specified* (compile-time module boundaries that make leakage impossible) is **not yet built** — it is currently enforced by convention. That's the central gap.

### SEC-1 — Proximity trust is keyed on a 32-bit fingerprint, not the public key  **[High]**
- **Evidence:** `ProximityTrustVault.swift:36-51` (`isTrustedProximityPeer`, `isRevoked…`, `isBlocked…` all match on the 8-char `fingerprint` string), `:55-72` (`trust(…)` finds existing records by fingerprint). `IdentityService.fingerprint(of:)` = `String(SHA256(pubkey).hex.prefix(8))` = 32 bits (`IdentityService.swift:165-169`). Auto-confirm of "trusted" peers uses the fingerprint (`ProximityCoordinator.swift:730-732`).
- **Why it matters:** A 32-bit identifier is brute-forceable offline (~2³² ≈ 4.3B SHA-256 ops — minutes-to-hours on commodity GPUs). An attacker can grind an Ed25519 keypair whose fingerprint collides with a trusted peer's, then be **auto-confirmed as that peer** in friend mode and receive content. The full `signingPublicKey` *is* stored on the record but is never compared against the inbound envelope's key when making trust/block/revoke decisions.
- **Fix (Phase S1):** Make the full 32-byte signing public key the trust primary key. In `handleIdentityEnvelope`, require the stored peer's `signingPublicKey == envelope.senderSigningPublicKey` before auto-confirm. Change `isTrusted/isRevoked/isBlocked` to compare the public key (or a full-length SHA-256, not an 8-char prefix). Keep the 8-char fingerprint as a display aid only. Bump the user-visible fingerprint to ≥16 hex chars for the manual "verify in person" step.

### SEC-2 — Transport encryption is `.optional` and 1:1 payloads default to plaintext  **[High]**
- **Evidence:** `MultipeerSession.swift:210` — `MCSession(…, encryptionPreference: .optional)`. The envelope factory defaults `payloadEncryption: .none` (`FernletIdentityEnvelope.swift:276`), and `ProximityCoordinator.sendPayload` (`:297-308`) never sets `.sealedTo`. So 1:1 friend photos and trainer attachments are **signed but not confidential**, riding on optional (downgrade-negotiable) transport encryption.
- **Why it matters:** `.optional` lets a peer negotiate down to no transport encryption; combined with `.none` app-layer payloads, sensitive content (photos, plans) can be observed on the air.
- **Fix (Phase S1):** Set `encryptionPreference: .required` on every `MCSession`. For sensitive 1:1 payloads, use the already-implemented `IdentityService.seal/open` (ChaCha20-Poly1305 + ephemeral X25519, with forward secrecy) by sending `payloadEncryption: .sealedTo(recipientKeyAgreementPublicKey:)`. The crypto is built and tested — the senders just aren't using it.

### SEC-3 — Period narrative syncs to CloudKit on general iCloud sync, bypassing the period hard-opt-in  **[High]**
- **Evidence:** A single `NSPersistentCloudKitContainer(name: "Fernlet")` backs the whole model (`Persistence.swift:128`); when `preferences.iCloudSyncEnabled && iCloudAvailable`, CloudKit options are set on the store description for the **entire** store (`:160`). `MenstrualNarrative` is part of that model (`:338`, `makeMenstrualNarrativeEntity` `:374`). Spec §19 says period data leaves the device **only** via the dedicated sealed-backup path, a *separate hard opt-in*, **default off**, with a political-sensitivity warning.
- **Why it matters:** The narrative's note/symptoms/scales columns are ciphertext (good — Apple sees ciphertext), **but** `dateKey`, `createdAt`, `hkExternalUUID`, `id` are plaintext (`MenstrualNarrativeRepository.swift:89-96`) and would sync — leaking *which days have period narratives* to iCloud. Period data is the most politically sensitive category handled.
- **Fix (Phase S2):** Exclude `MenstrualNarrative` (and any future sealed entity) from CloudKit mirroring — either a second, non-synced persistent store/configuration for sealed entities, or ensure those entities are not in the mirrored configuration. Period data should leave the device **only** through the dedicated AES-GCM sealed-backup path gated by `sealedBackupPeriodEnabled`. Add a test asserting no period entity appears in the CloudKit-mirrored configuration.

### SEC-4 — At-rest sealing covers period narrative only; journal text and intimacy notes are plaintext  **[High]**
- **Evidence:** The lock's content key is consumed **only** by period code (`ContentView.swift:288`, `LogPeriodSheet.swift:159`, `PeriodTrackerView.swift:112`). The main store writes plaintext JSON with `.completeFileProtection` (`LocalFernletRepository.swift:288`) and never uses `contentKey()` or `deriveColumnKey`. The lock gate protects the *screen* (`PrivateHubView.swift:41` `.fernletLockGate()`) but not the bytes.
- **Why it matters:** Journal entries and intimacy notes are plaintext on disk, protected only by iOS file protection (device-passcode-tied) and a UI gate. File protection does not protect against forensic extraction while the device is unlocked.
- **Fix (Phase S2):** Extend the proven sealed-store pattern to journal text and any local intimacy notes. `MenstrualNarrativeRepository` already shows the exact recipe: ChaChaPoly per-column + `HKDF(contentKey, info:)` column key. Reuse it for `JournalEntry.text` (and emotions) and intimacy notes.

### SEC-5 — No AI privacy boundary: no modules, no typed payloads, no audit, Tier-2 memory passed raw  **[Medium]**
- **Evidence:** No `PrivateHealthStore`/`PeriodContextBridge`/`PrivateMemoryStore`/`PrivateMediaStore`/`ContextBuilder`/`AIProviders` modules exist (Phase 3 of the impl plan is not done — single target). No `AIContextPayload`, allowlist, forbidden-field test, or AI audit log anywhere. The on-device thought prompt injects `tierTwoContextSummary(maxChars: 400)` — raw Tier-2 (sensitive) memory text — directly into the prompt (`LaunchPreparationService.swift:222-235`; `FernletStore.swift:200-214`), with no Memory Agent, no recency/destination filtering, no `containsDiagnosticLanguage` post-classifier.
- **What's actually clean (good):** Raw journal **text** is *not* sent to any model — only the journal color/emotion *tag* (`LaunchPreparationService.swift:186,220`). Period data is **not** in any prompt. The one fully-wired AI call (meal selection, `FoundationFoodSelection.swift`) sends only the meal description + candidate names. Minimal-data is mostly true *by current convention*.
- **Fix (Phase S3):** Build the boundary before any third-party path: (1) split sealed types into their own Swift packages with import-boundary build checks; (2) define typed per-request `AIContextPayload`s with field allowlists and unit tests asserting forbidden fields are absent; (3) add the local AI audit log; (4) route Tier-2 access through a Memory Agent that applies recency/destination filtering and the `DIAGNOSTIC_PATTERNS` post-classifier before any text reaches a prompt.

### SEC-6 — Friend handshake has no physical-proximity (≤30 cm) gate  **[Medium]**
- **Evidence:** Spec §9 step 6 requires "Physical confirmation at ≤30 cm." In code, friend mode auto-completes tap confirmation on transport connect (`ProximityCoordinator.swift:417-419` → `finishTapConfirmation`), and the distance/tap gate only runs in **trainer** mode and **only with UWB** (`:471-475`). On non-UWB devices and in friend mode, the handshake proceeds without any proximity confirmation.
- **Fix (Phase S1):** Require a proximity confirmation for friend handshakes: a UWB ≤-threshold tap when UWB is available, and an explicit user "confirm this is the person in front of you" step on non-UWB devices instead of auto-proceeding.

### SEC-7 — Replay protection is session-local; most envelopes never expire  **[Low–Medium]**
- **Evidence:** `ReplayCache` is in-memory, 24 h, 10k cap (`ReplayCache.swift`). The envelope factory leaves `expiresAt: nil` by default; photo/attachment sends don't set it. So after an app restart or >24 h, a captured envelope replays cleanly.
- **Fix (Phase S1):** Set a sensible `expiresAt` on all envelopes. Bind photo/attachment envelopes to the session/epoch.

### SEC-8 — Metadata leaks at rest  **[Low]**
- **Evidence:** Period narrative `dateKey`/`createdAt` are plaintext columns (`MenstrualNarrativeRepository.swift:91,95`) — readable even without the content key. `NSPersistentHistoryTrackingKey = true` (`Persistence.swift:143`) can retain deleted sensitive rows in transaction history until pruned.
- **Fix (Phase S2):** Treat the date index as sensitive (derive/obfuscate the lookup key, or accept and document). Prune persistent history for sealed entities on delete.

**Proximity strengths (credit where due):** Ed25519 envelope signing over canonical JSON, replay cache, X25519+ChaCha forward-secret `seal/open`, scrypt(32768/8/1)-derived wrapped content key with monotonic-anchor cooldown and reboot detection (`FernletLockService.swift`), and a genuinely well-built encrypted period-narrative store. The bones are strong; the gaps above are about *applying* this consistently and keying trust on the right thing.

---

## Part B — Progress vs Specification

The biggest meta-finding: **the app is significantly further along on proximity/mesh than `ImplementationPlan.md` claims.** The plan lists proximity as future "Phase 7/8/9," but `MeshNetworkManager`, `MeshMultipeerSession`, `MeshLobbyView`, `MeshAdmissionPromptSheet`, `FriendListView`, admission tokens, block model, and the full `ProximityCoordinator` all exist and are tested. Mesh **Phase 1 (and much of Phase 2)** is implemented; Phase 3 (encryption) is designed but not built. The plan has been updated to reflect this.

| Spec area | Status | Notes / evidence |
|---|---|---|
| Local storage, JSON repo, past-date writes | **Done** | `LocalFernletRepository`, tested |
| Goal scoring, sickness, avatar states | **Done** | `Scoring.swift`, tested |
| AI fallbacks, retry queue (meals), Fernlet-voice | **Done (meals)** | Journal/recipe retry expansion pending |
| AI status indicator | **Done** | |
| Food DB (USDA bundle), micronutrients on FoodItem | **Done** | `USDAFoodItems.json`, 13,104 foods |
| Ingredient search | **Done but weak** | See Part C — branded pollution, no generic-first ranking |
| Recipe builder/search/edit/export | **Done** | Import deferred; URL import is a separate SwiftData path not merged |
| Meal AI parse (paste→parse→review) | **Partial/buggy** | Composite logic mis-fires — see Part C |
| Day Detail sheet + month nav + past-date logging | **Mostly done** | Micronutrient summary + cached `daySummaryText` display pending |
| Overnight day-summary batch | **Partial** | Generation code exists (`LaunchPreparationService:195-210`), invalidation rules pending |
| Derived signals | **Partial** | Records + thought-bubble consumption exist; full `SignalsCard`/`TrendsModal` pending |
| Ambient features (year-ago, macro-gap, forgotten favorites, preventive-care, "today's intent") | **Mostly not done** | |
| Memory: Core edit UI, NL-forget, diagnostic filter | **Not done** | Tier-2 record storage exists; no Memory Agent/filter |
| App lock (passcode/biometric/cooldown) | **Done** | `FernletLockService` — robust |
| Period tracker + sealed narrative | **Done (narrative sealed)** | But CloudKit isolation gap — SEC-3 |
| Intimacy (HealthKit sexualActivity, 18+ gate) | **Partial** | Event count only via HealthKit; local "intimacy notes" need sealing — SEC-4 |
| **Privacy modules / sealed boundaries (Phase S3)** | **Not done** | No separate packages — SEC-5 |
| **AI typed payloads + allowlist + audit log** | **Not done** | SEC-5 |
| iCloud sync + onboarding storage choice + audit log | **Done** | `Persistence`, `OnboardingStorageChoiceView`, `FernletAuditLog` |
| Encrypted sealed backup (AES-GCM blobs) | **Not done** | `StoragePreferences` flags exist; upload/download path pending |
| Mesh Phase 1/2 (transport, admission, block, lobby, friends UI) | **Largely done** | Updated in `ImplementationPlan.md` |
| Mesh Phase 3 (group encryption) | **Designed, not built** | §17 of mesh plan |
| Third-party AI / OHTTP | **Not started** | Nothing leaves device for AI today |
| Photos / Photowall | **Not started** | Deferred |
| Wardrobe/Creation Studio | **Not started** | Deferred to v8 |

---

## Part C — Meal Tracker & Recipe Overhaul (the French-fries bug, root-caused)

**What happens with "I had French fries with my lunch":** the description is split into items; for the item "french fries", candidate FoodItems are gathered and the **top three are all added as separate ingredients**; because three ingredients resolve, the meal builder **packages them into a single "recipe" and sums their macros**. The bundle's branded subset has separate "French fries" entries for Wendy's, McDonald's, and Burger King — so you get a 3-serving, 3-brand fry "recipe." Exactly the reported behavior.

### Root causes (evidence)
- **RC1 — top-3-as-ingredients for an atomic food.** `FoundationFoodSelection.swift:64-81` (`deterministicIngredients`) takes `itemCandidates.prefix(3)` and emits **all** as ingredients. Right for sandwiches, wrong for single foods.
- **RC2 — composite-by-count.** `MealBuilder.swift:40-45`: `if resolved.count > 1 { createRecipe(…) }` — any item that resolved to >1 ingredient becomes a multi-ingredient recipe whose macros are summed. Three brands of one food → summed.
- **RC3 — no generic-vs-branded ranking.** `FoodDataCatalog.swift:251-257`: all USDA items share one `sourcePriority`. Foundation/SR-Legacy generics and branded restaurant items are indistinguishable to the ranker, so short branded names win on the name-length tiebreak (`:230-249`).
- **RC4 — no data-type on FoodItem.** The model carries `brandSource: String?` and `source: {usda, manual, aiResolved}` but no `foundation | srLegacy | branded` classification to rank or filter on.
- **RC5 — loose token matching.** Prefix-token matching + a small length penalty lets many near-identical branded entries tie and all surface.

### Fix design (Phase M1)
1. **Add a data-type classification to `FoodItem`** (`foundation`, `srLegacy`, `branded`/`restaurant`) derived at bundle-generation time and persisted. This is the keystone for everything below.
2. **Generic-first ranking.** Rank `foundation`/`srLegacy` above `branded` unless the query or meal description contains a brand/restaurant token. Add a curated brand/chain lexicon. When a chain is named ("McDonald's fries"), flip to "restaurant mode" and prefer that brand.
3. **Single-best candidate per atomic item.** In meal parsing, an atomic food yields **one** ingredient (the best match), not three. Reserve multi-ingredient expansion for genuine composites.
4. **Composite detection by lexicon, not by count.** Detect composites ("sandwich", "burger", "bowl", "salad", "tacos", "wrap", "stir fry", "smoothie", …) and only then expand into parts. Replace the `resolved.count > 1` recipe trigger with "is this item a known composite?"
5. **Dedupe near-identical results.** Collapse multiple brand variants of the same food in both search and candidate building; surface one generic with a "more brands" disclosure.
6. **Ingredient-search UX.** Generic first, deduped, grouped; "Branded / restaurant" behind a disclosure; show data source on each row.
7. **Quantity sanity.** Keep the sandwich/grilled-cheese 2-slice heuristic but make it lexicon-driven, and default atomic foods to one realistic portion (USDA portion gram weight when present).

**Exit criteria:** "French fries" logs **one** generic fries portion (not three brands); naming a chain logs that chain; "grilled cheese" still expands to bread + cheese; ingredient search shows the generic first and hides brand duplicates behind a disclosure; macro totals for a single food are realistic.

---

## Part D — New Implementation-Plan Phases

Phases S1, S2, M1, and S3 have been added to `ImplementationPlan.md`. **Recommended order: S1 → S2 → M1 → S3**, ahead of the remaining ambient/recipe polish. Security first, then the meal fix, then the AI boundary (needed before any third-party path).

---

## Part E — Mesh Plan: Phase 3 Review + new Phase 4

Phase 3 review issues and Phase 4 have been added to `MeshNetworkImplementationPlan.md`. See §17 pre-ship notes and §18 Phase 4. Implement Phase 3 and Phase 4 together.

---

## Part F — `FernletSpecificationV3.md` change-list (applied)

The following changes have been applied to `FernletSpecificationV3.md`:

1. **§0/§3 food-count inconsistency** — reconciled to 13,104 in both places.
2. **§0 prototype status** — updated to 2026-05-28; added: app lock, period tracker + encrypted narrative, mesh Phase 1/2, Foundation Models, no third-party AI.
3. **§2 Keychain contradiction** — added a "Decision needed" note: spec says `Synchronizable` but code uses `ThisDeviceOnly`. Choose direction before enabling encrypted backup.
4. **§9 transport** — updated from "BLE handles discovery" to MultipeerConnectivity + NearbyInteraction. Added `.required` encryption and sealed payload requirements.
5. **§9/§2 trust model** — added: full 32-byte signing public key is the trust primary key; friend handshakes require proximity confirmation.
6. **§3 sealed-store scope** — added note that Phase S2 extends sealing to journal text/emotions and intimacy notes, and that sealed entities must be in a non-CloudKit-mirrored configuration.
7. **§7 AI boundary status** — added implementation-status note: modules, typed payloads, audit log, and Memory Agent are required and not yet built (Phase S3). No OHTTP until S3 is complete.
8. **§18 App Store labels** — added a review note: if S2 seals journal text, the "User Content (journal entries — synced)" label needs revision.

---

## Part G — Settings consolidation (priority #6)

**Current:** 8 top-level sections plus debug surfaces exposed in production (Debug, Connection Inspector, Connection History, developer-note toggles, mode picker) — 4 shipping rows of prototype tooling.

**Proposed information architecture (≈5 sections):**
- **You** — name/appearance, Goal & nutrition, Layout & shortcuts, sick mode. Move goal picker + sick mode here so the two most-changed toggles are one tap in.
- **Tracking** — Health/HealthKit, Sleep, Move, Hydration, Hygiene/care tasks. Folds today's "Wellness" + scattered steppers.
- **Privacy & Security** — App lock, Privacy & Data, Period visibility (move "Hide predictions / Hide fertile window" here from top-level Period section), sealed-backup toggles. Period-tracking *behavior* stays on the Period screen; only privacy toggles live here.
- **Connections** — Friends and blocks, mesh defaults. Today's "Friends."
- **About & Behavior** — AI status + manual-off, Memory & signals, app info. A single **"Developer mode"** toggle (off by default in production) reveals Debug, Connection Inspector, Connection History, and developer notes — moving all prototype tooling behind one switch instead of four shipping rows.

**Principle:** put the 3–4 most-changed controls (goal, sick mode, AI manual-off) one tap from the top; push everything else behind labeled disclosure rows.

---

## Part H — Friction-reduction features (priority #3)

Ordered by effort-to-value, grounded in what already exists:

1. **One-tap re-log from history.** The `recentMeals` data is already there (`Models.swift`); surface tappable chips that copy a past meal to today. Also a speced ambient feature — kills two birds.
2. **App Intents / Siri + Lock-Screen & Home-Screen widgets** for "log water," "log a bottle," "log workout," "new journal entry." Hydration/hygiene especially are pure tap-count features that belong on a widget, not three taps deep.
3. **Barcode scanning for branded foods.** `NutritionLabelScanner`/`NutritionLabelCameraSheet` already do label OCR; add a barcode path → branded lookup. Removes manual macro entry for packaged goods.
4. **Voice meal entry → on-device parse.** Dictate "two eggs and toast," route through the (fixed, Phase M1) meal parser. Lower friction than typing, and on-device so it's private.
5. **Smarter defaults & fewer taps.** Default the last-used bottle size; surface recent meals before search; remember the usual hydration target; one-tap "same as yesterday" for hygiene.
6. **Finish Day Detail past-date logging** for hydration/hygiene/sleep (food/workout already work) so backfilling a missed day is frictionless.
7. **Recipe-from-photo / faster recipe capture** once the recipe AI paste-parse path is completed.

A good first friction sprint: #1, #2 (widgets), and #5 — low-risk, no new sensitive data, immediately reduce daily taps.

---

## Suggested sequencing (one view)

1. **S1 — Proximity Security Hardening** (full-key trust, required transport, sealed 1:1, friend gate, envelope expiry).
2. **S2 — At-Rest Sealing & CloudKit Period Isolation** (seal journal/intimacy; period off-cloud by default).
3. **M1 — Meal-Tracking & Food-Search Overhaul** (the French-fries fix + generic-first search).
4. **S3 — AI Privacy Boundary** (modules, typed payloads, audit log, Memory Agent) — required before any third-party AI.
5. **Mesh Phase 3** (group encryption) **+ Mesh Phase 4** (mesh security hardening) — implement together so confidentiality ships with trust/transport fixes.
6. Sprinkle in: settings consolidation (Part G), friction features (Part H), and the remaining ambient/recipe/day-summary polish already in the plan.

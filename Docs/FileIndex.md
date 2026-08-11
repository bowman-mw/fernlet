# Fernlet File Index

This index maps the main project files to their responsibilities. It is intended as a quick orientation guide for app navigation, feature work, tests, and documentation.

Last updated: 2026-08-09. Paths are written from the directory containing the repo checkout, so `Fernlet/…` is the repo root: `Fernlet/Fernlet/…` is the app target folder, `Fernlet/FernletKit/…` is the local Swift package, and `Fernlet/FernletTests/…` etc. are the sibling test/extension targets.

## FernletKit Package (Module Map)

The on-device source is carved into the `FernletKit` local SPM package (see [SPM-Module-Carveup-Plan.md](SPM-Module-Carveup-Plan.md)). The app links one umbrella product; the layered dependency DAG *is* the S3 privacy wall — the walled `AIProviders` and `CloudKitSync` modules list no `Private*` dependency, so a forbidden `import` is a hard build error. Per-file rows appear in the feature sections below; this table is the module-level map.

| Module | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Package.swift` | Package manifest: the layered target DAG, per-target MainActor isolation choices, and the single external dependency (CryptoSwift, for FernletLock's Scrypt KDF). |
| `FernletFoundation` | Layer 0 — shared utilities: dates, keychain helpers, audit log, storage preferences, monotonic clock, startup timing, backup exclusion. |
| `FernletCrypto` | Layer 0 — pure sealing primitives (`ColumnCrypto`, CryptoKit-only). |
| `WebScrapingKit` | Layer 0 — zero-dependency web-scraping substrate: shared HTML/JSON-LD helpers for both web importers, plus `EphemeralWebSession`, the no-cookie/no-cache/no-credential "private tab" URLSession every outbound fetch goes through. |
| `FernletDomainModel` | Layer 1 — portable, nonisolated domain value types (nutrition/workout/wellbeing/companion models, settings aggregate, wire DTOs). |
| `FernletScoring` | Layer 1 — scoring/goal-weight/meal-parse/workout-plan engines, abstract period-scoring signal types, and the stress engine. |
| `FoodCatalog` | Layer 1 — USDA food search/scoring; owns the bundled read-only `FoodCatalog.sqlite` resource (loaded via `Bundle.module`). |
| `FernletPersistence` | Layer 2 — persistence contract: `FernletRepository` protocol, `FernletSnapshot` aggregate, and the per-store repositoring protocols. |
| `LocalPersistence` | Layer 2 — Foundation-only local JSON repository, log-record DTOs, and the derived-signal / Tier-2 memory engines. |
| `PrivateStoreCore` | Layer 2.5 — sealed local-only Core Data stack shared by the `Private*` stores (protected side of the S3 wall). |
| `PrivateHealthStore` | Layer 3 — sealed cycle/intimacy store: `PeriodTrackerStore`, cycle prediction, menstrual-narrative and intimacy repositories, raw cycle types. |
| `PrivateMemoryStore` | Layer 3 — sealed journal and worry-box narrative repositories. |
| `PrivateMediaStore` | Layer 3 — at-rest AES-GCM-sealed photo stores (mesh friend photos, meal photos, progress photos). |
| `PeriodContextBridge` | Layer 4 — sanctioned egress converting raw cycle data into the abstract period signals scoring consumes. |
| `AIContext` | Layer 4 — typed AI context payloads (the de-identification contract), the `MemoryAgent` gatekeeper, and the AI audit log. |
| `AIProviders` | Layer 5 — **walled** on-device Foundation-model consumers; structurally cannot import any `Private*` store. |
| `CloudKitSync` | Layer 6 — **walled** iCloud-synced Core Data + CloudKit persistence; must never name a sealed type. |
| `StoreCore` | Layer 7 — store-side services lifted out of the app: derived signals, snapshot saves, AI retry queue, saved recipes, coins/custom items/milestones. |
| `DiaryStore` | Layer 8 — the portable `@Observable` diary slice of `FernletStore` (days, meals, journals, goals, scoring methods); the app-side facade forwards to it. |
| `HealthKitGateway` | Layer 6 — HealthKit platform shim: `HealthKitService`, workout sync, activity-type catalog, authorization seams. |
| `FernletLock` | Layer 6 — app-lock service (Scrypt via CryptoSwift); drains the sealed pending-narrative buffer on unlock. |
| `AppServices` | Layer 6 — assorted platform services: notifications, WeatherKit, nutrition-label OCR, barcode scanning, food image classification, share-extension import queue. |
| `ProximityKit` | Layer 6 — the peer-to-peer subsystem as one black-box shim: mesh transport, identity, trust, ranging, and the recipe/photo/clothing/heart/message/moderation flows. |

## App Entry And Shell

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/FernletApp.swift` | SwiftUI app entry point. Creates the shared persistence, app store, period tracker, launch preparation service, and lock service objects. |
| `Fernlet/Fernlet/ContentView.swift` | Main app container and navigation shell. Hosts primary tabs, launch state, lock gate integration, quick sheets, and meal/journal notifications. |
| `Fernlet/FernletKit/Sources/FernletUI/FernletUIComponents.swift` | Shared UI primitives: adaptive color tokens, headers, chip styles, sheet fields, section pickers, layout helpers, searching pulse, medallion/coin glyphs. |
| `Fernlet/FernletKit/Sources/FernletUI/FernletPrimitives.swift` | `FernletCard`, `SectionLabel`, `EmptyState` — the cross-screen layout primitives extracted from HomeView for package-resident views. |
| `Fernlet/FernletKit/Sources/FernletUI/FernletTheme.swift` | App-wide color palette, theme defaults, custom light/dark background support, and UIKit/SwiftUI color vending. |
| `Fernlet/FernletKit/Sources/FernletUI/FernletDesignSystem.swift` | Design-system foundation: the `FernletTextRole` serif/sans type scale, warm token palette, 8pt spacing/radii/shadow/motion tokens, and bundled-font resolution. |
| `Fernlet/FernletKit/Sources/FernletUI/ModelColors.swift` | SwiftUI `Color` extensions mapping domain enums (`MealType`, `WorkoutSplit`, `WorkoutType`…) to palette colors; split out so domain models stay Foundation-only. |
| `Fernlet/FernletKit/Sources/FernletUI/ActivityShareView.swift` | `ActivityShareView` — the app's single `UIActivityViewController` wrapper, with the `onFinish` completion hook the plaintext exports are deleted at. Shared by the data export (`PrivacyDataSettingsView`), the trainer/nutritionist summary (`TrainerExportView`), and the proximity connection-log export (`ConnectionInspectorHistoryView`); replaced the two private copies and one `ShareLink`. |
| `Fernlet/FernletKit/Sources/FernletUI/OptionalPresenceBinding.swift` | `Binding.isPresent()` — collapses an optional-backed binding into the `Bool` shape SwiftUI's `alert` / `sheet` / `confirmationDialog` / `fullScreenCover` modifiers take (presented while non-nil; setting `false` clears the value, setting `true` is a no-op). The shared home for the "present while this optional state is set" binding previously inlined at every call site (`ActivitiesView`, `ConnectView`, `DisposableCameraView`, `FriendListView`, `FriendShopView`, `PrivacyDataSettingsView`, `FriendPhotoReviewSheet`); sites with a compound getter or a side-effecting setter deliberately keep their hand-rolled binding. |
| `Fernlet/Fernlet/FernletNotificationDelegate.swift` | `UNUserNotificationCenterDelegate` that presents gentle notifications while foregrounded and routes a check-in tap to the journal sheet via a pending-open flag `ContentView` consumes. |
| `Fernlet/Fernlet/UITestSupport.swift` | DEBUG-only launch hooks for UI tests: central reader of the `FERNLET_UI_TEST_*` appearance-test flags (seed demo, bypass private lock, jump-to-screen). |
| `Fernlet/Fernlet/Assets.xcassets` | Image and color assets used by the app. |
| `Fernlet/Fernlet/Info.plist` | App bundle metadata and platform configuration. |
| `Fernlet/Fernlet/Fernlet.entitlements` | App capability entitlements. |
| `Fernlet/Fernlet/SettingsSearchIndex.swift` | `SettingsRoute` (every addressable Settings destination, driving the hub's single `navigationDestination`) and `SettingsSearchIndex` (the searchable entry table). Adding a route is a compile-time prompt to give it a view and at least one search entry. |

## Feature Views

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/HomeView.swift` | Home dashboard with companion state, quick logging, signal trends, macro summaries, hygiene, and photo wall UI. |
| `Fernlet/Fernlet/FoodView.swift` | Food logging, recipes, imported recipe review, ingredient editing, meal creation, macro display, saved recipe book, and Safari presentation. Also hosts the in-file `RecipeDetailView` (sealed photo, macros, edit/log/share actions, in-app Safari source link). |
| `Fernlet/Fernlet/MoveView.swift` | Movement/workout screen with workout logging, suggestions, workout rows, and goal summaries. Hosts `WorkoutExerciseDraft`, the exercise-draft state machine shared by `WorkoutSheet` and `WorkoutPlanSheet`. |
| `Fernlet/Fernlet/ActivityPickerSection.swift` | Activity-mode workout picker, recent activity shortcuts, and activity-specific workout fields. |
| `Fernlet/Fernlet/JournalView.swift` | Journal calendar, prompts, entry creation/editing, day detail, day nutrition breakdowns, and daily edit sheets. |
| `Fernlet/Fernlet/CycleTrackerView.swift` | The Private hub's merged Cycle page: one layered calendar (period flow tints + a distinct intimacy marker), period predictions/trends, and a single plus-menu; each half gates on its own derived visibility. |
| `Fernlet/Fernlet/CycleDayDetailView.swift` | Combined day detail for the Cycle calendar: the period half (samples, narrative, edit/delete) and the intimacy half (events/notes), each rendered only when its own gate allows. |
| `Fernlet/Fernlet/LogPeriodSheet.swift` | Sheet for logging period events. |
| `Fernlet/Fernlet/MonthCalendarCard.swift` | `MonthGridModel` + `MonthCalendarCard` — the shared month-calendar chrome (paging chevrons with future months disabled, weekday row, 7-column grid inside a `FernletCard`) plus its pure layout math, whose day keys are canonicalized through `FernletDate.dayKey` rather than a locale-following formatter. The single home of the previously duplicated month grids, now filled by `JournalView` and the layered cycle calendar in `CycleTrackerView`; each supplies its own day cells and footer. |
| `Fernlet/Fernlet/PrivateHubView.swift` | Private hub screen with private-section navigation. |
| `Fernlet/Fernlet/SocialHubView.swift` | Social hub entry point for the Friends photo wall and active disposable-camera session flow. |
| `Fernlet/Fernlet/ConnectView.swift` | Friends tab photo wall, nearby-discovery status, connection-success transition, session photo review, and full-screen saved-photo feed. Presents `DisposableCameraView` while a Friends session is active. |
| `Fernlet/Fernlet/CreationStudioView.swift` | Animal-Crossing-style grid fabric editor for designing custom clothing/accessories (per-slot pixel canvas, palette, live companion preview). Pushed from the customization sheet. |
| `Fernlet/Fernlet/WardrobeView.swift` | The closet: owned custom items grouped by slot; equip/unequip, edit, delete, mark shop-shareable. Entry point into the Creation Studio. |
| `Fernlet/Fernlet/CustomItemRendering.swift` | Renders a palette-indexed `ItemGridTexture` to a cached `CGImage` (`ItemTextureRenderer`) and the `CustomItemThumbnail` preview tile. |
| `Fernlet/Fernlet/CompanionVectorAssets.swift` | Vector companion renderer (`CompanionView` + body/accessory/clothing/side-item layers). Hosts `CompanionCustomItemLayer`, which draws equipped user-designed grid items in per-slot regions. |
| `Fernlet/Fernlet/OnboardingView.swift` | First-run profile setup, nutrition profile editing, and nutrition preview UI. |
| `Fernlet/Fernlet/SettingsSheet.swift` | Settings sheet and user preferences UI. |
| `Fernlet/Fernlet/SharedSheets.swift` | Reusable logging sheets for water, sleep, goals, hygiene, and texture entries. |
| `Fernlet/Fernlet/AmbientCards.swift` | `AmbientCardsView` — low-cost ambient Home surfaces: once-a-day gentle offer, look-back journal card, macro-gap meal nudge, forgotten-favorite/workout nudges, and a preventive-care micronutrient bubble. |
| `Fernlet/Fernlet/CompanionAmbienceLayer.swift` | Full-bleed environment layer behind the Home companion: local-hour time-of-day tint (`CompanionDayPhase`) plus optional WeatherKit sky accents (clouds/rain/snow). |
| `Fernlet/Fernlet/QuickMoodRow.swift` | `QuickMoodRow` — one-tap mood check-in row of `FeelingTag` chips (Home + Journal) logging a tag-only journal entry via `logQuickMood`, updating today's check-in in place. |
| `Fernlet/Fernlet/GoalPresetCards.swift` | `GoalPresetCards` — selectable goal preset cards (one per `GoalType`) surfacing the paired nutrition + training setup each goal configures. |
| `Fernlet/Fernlet/JournalPromptLibrary.swift` | `JournalPromptLibrary` — static curated journaling prompts with a deterministic per-`dateKey` daily rotation (deliberately non-AI, journal text stays walled from models). |
| `Fernlet/Fernlet/MilestonesView.swift` | `MilestonesView` — lifetime-milestones surface: warm cumulative care counts and coin gifts from the append-only ledger, plus a keepsake-medallion shelf. |
| `Fernlet/Fernlet/PetInteractionGovernor.swift` | `PetInteractionGovernor` — gentle anti-compulsion pacing state machine for tap-to-pet (rolling window → settling → calm-idle), state kept in device-local `UserDefaults`. |
| `Fernlet/Fernlet/PhotoCaptureControl.swift` | `PhotoCaptureControl` — reusable camera-first / library photo-capture control shared by meal capture and progress photos, with raw-`Data` or `UIImage` sinks. |
| `Fernlet/Fernlet/LogIntimacySheet.swift` | `LogIntimacySheet` — sealed intimacy-log entry sheet (date, note, protection used) written through the fail-closed decrypt/seam gate. |
| `Fernlet/Fernlet/TrainerExportView.swift` | `TrainerExportView` — trainer/nutritionist export review + consent screen: pick optional includes and see exactly what is always/never shared before preparing the file. |
| `Fernlet/Fernlet/LinkMetadataPrototypeView.swift` | DEBUG-only D11 link-metadata prototype (temporary): tests whether sender-supplied `LPLinkMetadata` survives into a sent iMessage bubble; not wired into any screen. |

## Wellbeing, Stress, And First Aid

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/FirstAidView.swift` | `FirstAidView` / `FirstAidTool` — calm first-aid sheet routing to breathing, 5-4-3-2-1 grounding, and the Worry Box, plus a static 988 support row. |
| `Fernlet/Fernlet/BreathingExerciseView.swift` | `BreathingExerciseView` — animated breathing circle (box 4-4-4-4 / relax 4-7-8, 1–3 min, optional haptics); a completed session reports its interval to the caller for Apple Health. |
| `Fernlet/Fernlet/GroundingView.swift` | `GroundingView` — 5-4-3-2-1 grounding: a stepped tap-to-advance sensory flow with a per-sense colour wash, ending on a soft affirmation. |
| `Fernlet/Fernlet/WorryBoxView.swift` | Worry Box surfaces: `WorryEntryView` write-and-let-go entry flow (hosted in First Aid) and the Private-hub kept-worries list with per-worry release. |
| `Fernlet/Fernlet/WorryBoxService.swift` | `WorryBoxService` — app-side owner of sealed, local-only Worry Box notes (user-lock/device-key model, never synced, absent from SealedBackup). |
| `Fernlet/Fernlet/StressService.swift` | `StressService` (`StressScoringContextProviding`) — opt-in body-signals stress estimate joining HealthKit HRV/RHR/respiration/temp with diary confounders via `StressEngine`; baselines in a device-local sidecar. |
| `Fernlet/FernletKit/Sources/FernletScoring/StressEngine.swift` | Pure personal-baseline stress estimator (`StressDaySample`) mapping HRV/resting-HR deviation to gentle wellness states. |
| `Fernlet/Fernlet/StressExplainerSheet.swift` | `StressExplainerSheet` — gentle "how we estimate this" body-signals explainer (wellness framing, not-medical disclaimer) that can chain into First Aid. |
| `Fernlet/Fernlet/GentleOffers.swift` | `GentleOfferKind` + pure gating/rotation logic for the once-per-day ambient gentle-offer card (breathing / worry box / short walk). |

## Workouts And Guided Training

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/WorkoutSetupView.swift` | `WorkoutSetupSheet` — captures durable workout context: split, training location/equipment, weekly frequency, experience, interests, and areas to work around. |
| `Fernlet/Fernlet/WorkoutLocationSetupView.swift` | `WorkoutLocationSetupView` — location creator + equipment picker: choose where you train, then check off equipment in a categorized grid mapped to coarse planning capabilities. |
| `Fernlet/Fernlet/WorkoutPlanningService.swift` | `WorkoutPlanningService` — split recommendation, day-plan generation, and AI day-plan adjustment extracted from `FernletStore` (owns the FoundationModels workout dependency). |
| `Fernlet/Fernlet/GuidedWorkout.swift` | `GuidedWorkoutSheet` — in-app guided workout runner (current exercise, set X of Y, live rest countdown) driven by `store.guidedRunState` and mirrored to the Live Activity. |
| `Fernlet/Fernlet/GuidedWorkoutEditorSheet.swift` | `GuidedWorkoutEditorSheet` — manual editor for a suggested session (per-exercise sets/reps/rest override, remove, reorder, add from catalog); saving replaces the session in today's plan. |
| `Fernlet/Fernlet/EquipmentIcons.swift` | `EquipmentIconLibrary` + a lightweight SVG renderer — editable stroke-only vector glyphs for gym equipment / locations, tinted to foreground, with SF Symbol fallback. |
| `Fernlet/Fernlet/ProgressPhotoTimeline.swift` | `ProgressPhotoSection` — Move-tab gym progress-photo timeline: sealed-at-rest body photos behind the global Fernlet lock, with camera/library add and tap-through detail. |

## Custom Clothing, Coins, And Friend Shop

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/ZoomablePixelCanvas.swift` | `ZoomablePixelCanvas` — zoomable/pannable `UIScrollView` pixel-painting surface for the clothing editor (pinch-zoom, two-finger pan, one-finger paint), rendering via `ItemTextureRenderer`. |
| `Fernlet/Fernlet/FriendShopView.swift` | `FriendShopView` — browse friends' post-session shops and buy items with coins (banned-seller filtered, with per-item report). |
| `Fernlet/Fernlet/ClothingShareCodec.swift` | `ClothingShareCodec` — domain⇄wire codec for the in-person clothing shop: builds the device's own-designs `ClothingCatalogPayload` and re-sanitizes every incoming item before use. |
| `Fernlet/Fernlet/ShopAlert.swift` | `ShopAlert` + `ShopAlertContext` — the three ways a shop listing can be refused (flagged name, listing cap, store ban) as alert cases, with the per-screen copy keyed by which screen is presenting. The shared home of the refusal alerts previously written out twice, in `CreationStudioView`'s confirmation step and `WardrobeView`'s swipe-to-sell path; in every case the item itself was already saved, just left unlisted. |
| `Fernlet/FernletKit/Sources/StoreCore/CoinLedgerService.swift` | `@MainActor @Observable CoinLedgerService` owning the coin ledger in memory with debounced append-only persistence. |
| `Fernlet/FernletKit/Sources/StoreCore/CustomItemService.swift` | `@MainActor @Observable CustomItemService` owning the custom-item collection with debounced append/upsert persistence. |
| `Fernlet/FernletKit/Sources/StoreCore/MilestoneLedgerService.swift` | `@MainActor @Observable MilestoneLedgerService` owning the milestone ledger with debounced append-only persistence. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CoinLedgerRepository.swift` | Per-row Core Data + iCloud coin-ledger store (`CoinLedgerRepository`), append-only JSON payload rows. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CustomItemRepository.swift` | Per-row Core Data + iCloud custom-item store (`CustomItemRepository`), append/upsert-only JSON payload rows. |
| `Fernlet/FernletKit/Sources/CloudKitSync/MilestoneLedgerRepository.swift` | Per-row Core Data + iCloud milestone-ledger store (`MilestoneLedgerRepository`), append-only, no delete path. |
| `Fernlet/FernletKit/Sources/CloudKitSync/AppendOnlyRowStore.swift` | `AppendOnlyRowStore` — the shared upsert-only per-row Core Data engine (JSON `payloadData` rows keyed by a stable `idString`, sorted by `createdAt`, encoded via `RowPayloadCoders`) whose load/upsert bodies `CoinLedgerRepository`, `MilestoneLedgerRepository`, and `CustomItemRepository` previously carried as byte-for-byte clones. Upserts only the rows handed to it (a stale in-memory set cannot wipe rows synced in from another device) and deliberately exposes **no** delete path — deletion policy stays per repository. |
| `Fernlet/FernletKit/Sources/ProximityKit/ClothingSharing/MeshClothingShop.swift` | Friend-mesh clothing shop: accumulates pairwise-sealed `.clothingCatalog` payloads from committed slots, then opens a 1-hour memory-only post-session browse window; receive/window state only, never persisted. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/ClothingSharePayloads.swift` | In-person clothing-shop wire models: `ClothingCatalogPayload` carrying a peer's anonymous designer id, display name, and capped deterministically-ordered `CustomizationItem`s. |

## Onboarding

| File | Purpose |
| --- | --- |
| `Fernlet/Fernlet/OnboardingCoordinator.swift` | Onboarding state machine, step progression, storage choice, lock setup deferral, iCloud data detection, and `OnboardingDefaults` keys. |
| `Fernlet/Fernlet/OnboardingWelcomeView.swift` | First onboarding screen presenting the Fernlet welcome message and entry CTA. |
| `Fernlet/Fernlet/OnboardingPermissionsView.swift` | Onboarding step for requesting HealthKit and notification permissions. |
| `Fernlet/Fernlet/OnboardingStorageChoiceView.swift` | Onboarding step for choosing local vs. iCloud storage, with existing cloud data detection and migration summary. |
| `Fernlet/Fernlet/OnboardingLockSetupView.swift` | Onboarding step for setting up a passcode or biometrics-only lock, with a skip/defer path. |

## Lock And Privacy

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/FernletLockUI/FernletLockGate.swift` | View modifier that gates protected UI behind the Fernlet lock state. |
| `Fernlet/Fernlet/AgeAssuranceStore.swift` | `AgeAssuranceStore` — owns the device-local age determination behind the intimacy (16+) and mesh-chat (13+) gates. Persists to the never-synced sidecar; fail-closed on a fresh or undecodable record. |
| `Fernlet/Fernlet/AgeAssuranceRequest.swift` | The single seam to Apple's `DeclaredAgeRange` framework: one prompt for gates 13/16/18, plus the `.requestsAgeRange` view modifier. Every failure path lands on undetermined. |
| `Fernlet/Fernlet/AgeGateNotice.swift` | `AgeGateNotice` — the locked-state row for an age-gated feature: states the true reason, and offers a re-check plus the manual confirmation only when the system never ruled. |
| `Fernlet/FernletKit/Sources/FernletLockUI/FernletLockView.swift` | Lock setup, unlock UI, numeric pad, passcode entry, and related lock interaction views. |
| `Fernlet/FernletKit/Sources/FernletLock/FernletLockService.swift` | Lock service protocols, lock state, credential types, crypto provider, keychain item handling, audit logging, and lock/unlock orchestration. |
| `Fernlet/FernletKit/Sources/FernletFoundation/KeychainHelpers.swift` | Low-level Keychain read/write/delete helpers shared by lock and identity services. |
| `Fernlet/FernletKit/Sources/FernletFoundation/FernletLockError.swift` | `FernletLockError` error enum for app-lock/passcode/biometric failures with localized descriptions. |
| `Fernlet/FernletKit/Sources/FernletCrypto/ColumnCrypto.swift` | Shared ChaChaPoly column-encryption helper (`ColumnCrypto`) sealing/opening per-column values under a per-label derived key. Also the single home of the HKDF-SHA256 column-key derivation (`deriveColumnKey`, module-internal so production code reaches it only through the sealing methods) since the duplicate `FernletLockCrypto.deriveColumnKey` was deleted — the label and the derivation are part of the at-rest format, so changing either orphans every sealed column. |
| `Fernlet/FernletKit/Sources/FernletCrypto/DeviceBindingID.swift` | Per-install random ID (ThisDeviceOnly keychain row) passed by `ColumnCrypto` as AEAD associated data on new sealed-column writes (device-bound v2 format); fail-open to the legacy format when unavailable. |
| `Fernlet/FernletKit/Sources/FernletLock/SecureEnclaveContentKeyWrap.swift` | ECIES wrap of the lock content key under a non-exportable Secure Enclave P-256 key. Additive while `LockKeychainKey.wrappedContentKey` exists (LEGACY / SE-less hardware); AUTHORITATIVE and the only recoverable copy once the service has proven a round-trip and deleted the scrypt item (HARD-BOUND — Docs/Verifiability.md §4/§6.1, done). `unwrap` fails soft to nil for the maintenance paths; the hard-bound recovery path uses `unwrapResult` instead, so a destroyed enclave key (`FernletLockError.contentKeyUnrecoverable`) is never confused with a keychain that would not answer (`.contentKeyTemporarilyUnavailable`). |
| `Fernlet/Fernlet/JournalSealingCoordinator.swift` | `JournalSealingCoordinator` (`JournalSealingContext`) — sealed journal management (content key, device fallback key, sealed-ID set, narrative repository) extracted from `FernletStore`; `isSealed` drives the snapshot text-strip. |
| `Fernlet/Fernlet/SealedBackupService.swift` | `SealedBackupCrypto` — AES-GCM seal/open of `SealedBackupRecord`s bound to the iCloud-Keychain escrow signing key. |
| `Fernlet/Fernlet/SealedBackupCoordinator.swift` | `SealedBackupCoordinator` (`SealedBackupContext`) — sealed iCloud backup/restore of Tier-2 memory, journals, and period narratives under the escrow key, extracted from `FernletStore`. |
| `Fernlet/Fernlet/SealedPhotoBackupService.swift` | `SealedPhotoCrypto` (AAD **v3**, per-photo) + `SealedPhotoBackupService` — the own-photo escrow route's mechanism half (hardening Phase 5, step 5b): seal one record per photo id, write the per-corpus manifest LAST as the commit marker, restore manifest-first (authenticate → generation high-water → fetch bodies), incremental add, delete, corpus teardown. Derives on the same v2 salted escrow key as the chunked route; a **distinct namespace**, never a `SealedBackupPayloadType` case. |
| `Fernlet/Fernlet/OwnPhotoBackupCoordinator.swift` | `OwnPhotoBackupCoordinator` (`OwnPhotoBackupContext`) — the own-photo escrow route's policy half: the single opt-in preference, the per-corpus FILE-PRESENCE no-clobber gate, restore-before-reupload ordering, the progress corpus's sealed-index sidecar, the delete-all teardown, and `OwnPhotoUploadLedger` (the device-local record of which ids THIS device uploaded — the prune scope that keeps one device's pass from deleting another device's photos). Owns its own `MealPhotoStore`/`ProgressPhotoStore` instances over `OwnPhotoCorpusLayout`. |
| `Fernlet/Fernlet/DeleteAllDataConfirmation.swift` | `DeleteAllDataConfirmation` — the single shared destructive confirm dialog for "delete everything", funneling both Settings entry points to `FernletStore.deleteAllData`. |
| `Fernlet/Fernlet/DeleteEverythingFlow.swift` | `DeleteEverythingFlow` — per-screen "delete everything" wipe state (busy/success/failure) + confirmation glue and the shared `.deleteEverythingAlerts` outcome alerts, instantiated once per entry point (`SettingsSheet`, `PrivacyDataSettingsView`); buttons/overlays/dismiss guards stay in the views. |
| `Fernlet/Fernlet/PrivacyPolicyView.swift` | `PrivacyPolicyView` — in-app Privacy Policy screen rendering the policy in the app's voice/type, with a DEBUG-only draft banner. |
| `Fernlet/Fernlet/PrivacyDataSettingsView.swift` | Privacy and data settings screen for managing storage preferences, HealthKit toggles, and sealed backup options. Routes every destructive/OFF toggle through a pre-commit warning; surfaces the sealed-backup restore status + escrow-conflict banner (retry / re-link). |
| `Fernlet/Fernlet/DestructiveConfirmation.swift` | Reusable destructive-action confirmation (`DestructiveConfirmation` + `.destructiveConfirmation` modifier): the mutation runs only on an explicit destructive-role confirm, so no destructive settings toggle can ship without a warning. |

## Data, Persistence, And State

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/FernletDomainModel/` | Core domain models (formerly the app's `Models.swift`), split per area — see the Domain Models section. |
| `Fernlet/Fernlet/FernletStore.swift` | Main observable app store that coordinates repository data and app-level state changes. |
| `Fernlet/FernletKit/Sources/StoreCore/AIRetryQueueService.swift` | AI analysis retry queue; stores pending retry records and calls `onChange` on each mutation. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/StoreCore/DerivedSignalsService.swift` | Derived signal computation and deferred post-launch rebuild scheduling. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/StoreCore/DerivedSignalsRebuilder.swift` | Pure helper that rebuilds derived signals from a historical day window; used by `DerivedSignalsService`. |
| `Fernlet/FernletKit/Sources/StoreCore/SavedRecipeService.swift` | Observable saved recipe list manager; loads, adds, deletes, and persists saved recipes. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/StoreCore/SnapshotSaveCoordinator.swift` | Debounced snapshot persistence coordinator and remote-change reload handler. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/StoreCore/PendingWriteBuffer.swift` | `DebouncedRowBuffer` / `DebouncedAppendBuffer` — the queue-then-debounce-then-flush write machinery, and its durability contract (the pending queue is the sole un-persisted copy, so it is cleared only after a confirmed write and a failed write keeps it for retry instead of trapping), shared by `SavedRecipeService` / `CustomItemService` (upsert+delete rows) and `CoinLedgerService` / `MilestoneLedgerService` (append-only rows). The one home of what those four services previously carried as byte-identical copies; row meaning, load-time dedup, and reset semantics stay in each service. |
| `Fernlet/Fernlet/FernletStoreLoader.swift` | Async store bootstrap coordinator that manages `preparing → ready → failed` phase transitions at launch. |
| `Fernlet/Fernlet/DataExportBuilder.swift` | `FernletDataExport` + `FernletStore` builder — assembles the user's non-sealed data into one human-readable JSON export file (allowlist projection; sealed/sensitive data excluded by construction). |
| `Fernlet/Fernlet/TrainerExportBuilder.swift` | `TrainerExportBundle` / `TrainerExportOptions` + `FernletStore` builder — curated fail-closed-allowlist workout + nutrition export for a trainer/nutritionist, with opt-in extras. |
| `Fernlet/Fernlet/FernletStore+DemoSeed.swift` | DEBUG-only `FernletStore` extension that seeds today's diary with representative demo content (day-idempotent) so every tab renders populated cards for the UX appearance UI tests. |
| `Fernlet/FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift` | Local JSON-style repository contract and implementation, snapshot/database records, derived signal creation, limits, and memory engine logic. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CoreDataFernletRepository.swift` | Core Data-backed repository implementation. |
| `Fernlet/FernletKit/Sources/CloudKitSync/Persistence.swift` | Core Data persistence controller setup for runtime and previews/tests. |
| `Fernlet/FernletKit/Sources/FernletFoundation/CoreDataModelBuilding.swift` | `CoreDataModelBuilding.makeAttribute` — the shared `NSAttributeDescription` factory for the two programmatic (no `.xcdatamodeld`) model builders, `PersistenceController` (CloudKitSync) and `PrivatePersistenceController` (PrivateStoreCore), each of which previously held a private byte-identical copy. Pure in-memory construction that names no sealed or synced entity, which is what lets it sit at layer 0 and be reused from both sides of the S3 wall. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CloudKitDataService.swift` | CloudKit record read/write service and `ExistingDataSummary` detection used during onboarding migration. |
| `Fernlet/FernletKit/Sources/FernletFoundation/StoragePreferences.swift` | Codable model for user storage preferences: iCloud sync, local backup exclusion, HealthKit capability toggles, and sealed backup flags. |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/PeriodTrackerStore.swift` | Period tracker domain state, cycle events, symptom/flow models, cycle phase logic, HealthKit integration contract, and store behavior. |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/MenstrualNarrativeRepository.swift` | Persistence for menstrual narrative entries. |
| `Fernlet/FernletKit/Sources/PrivateStoreCore/PendingNarrativeBuffer.swift` | Codable buffer for pending menstrual narrative payloads. |
| `Fernlet/FernletKit/Sources/CloudKitSync/SavedRecipe.swift` | Saved recipe model and repository implementations, including legacy JSON migration support. |
| `Fernlet/FernletKit/Sources/HealthKitGateway/ActivityTypeCatalog.swift` | Workout activity type search and HealthKit activity type mapping. |
| `Fernlet/FernletKit/Sources/FernletPersistence/FernletRepository.swift` | The abstract `FernletRepository` persistence contract for snapshot/day/tier-two load and save. |
| `Fernlet/FernletKit/Sources/FernletPersistence/FernletSnapshot.swift` | `FernletSnapshot` persisted aggregate value type serialized to/from storage. |
| `Fernlet/FernletKit/Sources/FernletPersistence/RemoteChangePublishingRepository.swift` | `RemoteChangePublishingRepository` refinement exposing an iCloud remote-change `AnyPublisher`. |
| `Fernlet/FernletKit/Sources/FernletPersistence/DayRecordRepositoring.swift` | Per-day persistence protocol (`DayRecordRepositoring`) plus the sanitize-barrier `DayRecordUpsert` mint. |
| `Fernlet/FernletKit/Sources/FernletPersistence/SavedRecipeRepositoring.swift` | `@MainActor` append/upsert-only saved-recipe persistence protocol (`SavedRecipeRepositoring`). |
| `Fernlet/FernletKit/Sources/FernletPersistence/CoinLedgerRepositoring.swift` | `@MainActor` append-only coin-ledger persistence protocol (`CoinLedgerRepositoring`). |
| `Fernlet/FernletKit/Sources/FernletPersistence/CustomItemRepositoring.swift` | `@MainActor` append/upsert-only custom-item persistence protocol (`CustomItemRepositoring`). |
| `Fernlet/FernletKit/Sources/FernletPersistence/MilestoneLedgerRepositoring.swift` | `@MainActor` milestone-ledger persistence protocol (`MilestoneLedgerRepositoring`); append-only, deliberately no delete. |
| `Fernlet/FernletKit/Sources/LocalPersistence/DayContentSummary.swift` | `DayContentSummary` precomputed content-count roll-up carried in the aggregate blob for single-read existing-data detection. |
| `Fernlet/FernletKit/Sources/LocalPersistence/DerivedSignalFactory.swift` | `DerivedSignalFactory` computing the rolling derived-signal window (mood/energy/eating/progression/micronutrient trends) from stored day pairs. |
| `Fernlet/FernletKit/Sources/LocalPersistence/LogRecords.swift` | Derived-table DTO records (`DailyLogRecord`) persisted alongside the local database. |
| `Fernlet/FernletKit/Sources/LocalPersistence/TierTwoMemoryEngine.swift` | `TierTwoMemoryEngine` deriving capped tier-two behavioral memories from the rolling 14-day window. |
| `Fernlet/FernletKit/Sources/LocalPersistence/FeelingTagMoodScale.swift` | `FeelingTag.moodScore` — the fixed 0.2–1.0 mood scale shared by the deterministic derived engines, and the single home of the two previously duplicated private copies in `DerivedSignalFactory` and `TierTwoMemoryEngine`. |
| `Fernlet/FernletKit/Sources/CloudKitSync/DayRecordRepository.swift` | Per-row Core Data + iCloud day-history store (`DayRecordRepository`) with duplicate-row dedup by `dateKey`. |
| `Fernlet/FernletKit/Sources/FernletFoundation/RowPayloadCoders.swift` | `RowPayloadCoders`: single source of truth for the persisted-JSON encoder/decoder config (sorted keys + ISO-8601 dates, with opt-in pretty-printing for the human-readable on-disk files). Moved down to layer 0 from `CloudKitSync` so the local-only blob file in `LocalPersistence` shares it too; it replaced the per-store private `makeEncoder`/`makeDecoder` pairs that had drifted (the coin-ledger and custom-item row stores once wrote bare numeric dates). ISO-8601 truncates to whole seconds — callers comparing dates across representations must account for that. |
| `Fernlet/FernletKit/Sources/CloudKitSync/MultiDeviceSyncWarning.swift` | Pure `MultiDeviceSyncWarning` classifier for the "devices will diverge without iCloud" warning state. |
| `Fernlet/FernletKit/Sources/CloudKitSync/SealedBackupRecord.swift` | Sealed-backup transport DTOs (`SealedBackupRecord`, `SealedBackupPayloadType`): the opaque encrypted CloudKit record shape. |
| `Fernlet/FernletKit/Sources/CloudKitSync/SealedPhotoRecord.swift` | Own-photo escrow transport DTOs (`SealedPhotoCorpus`, `SealedPhotoSlot`, `SealedPhotoManifest`, `SealedPhotoRecord`): one encrypted record per photo id plus the sealed per-corpus manifest (id set + per-id content hash + the progress corpus's index sidecar). Born at record format 2 — no legacy shape to tolerate. |
| `Fernlet/FernletKit/Sources/DiaryStore/DiaryStore.swift` | `@MainActor @Observable DiaryStore`: the portable diary-state slice (scoring, meal/recipe/workout/journal/settings) carved from `FernletStore`. |
| `Fernlet/FernletKit/Sources/PrivateStoreCore/PrivatePersistenceController.swift` | `PrivatePersistenceController`: dedicated local-only (never-iCloud) Core Data store for sealed, encrypted entities. |
| `Fernlet/FernletKit/Sources/PrivateStoreCore/PrivateRowPlumbing.swift` | `PrivateRowPlumbing.deleteRows` — the shared keyless fetch → guard → delete → save → history-prune sequence that the sealed repositories' `deleteAll()` methods (`JournalNarrativeRepository`, `WorryNarrativeRepository`, `IntimacyLogRepository`, `MenstrualNarrativeRepository`) each repeated inline. Rows are deleted without decrypting them, so deletion stays available while the app is locked or the feature is hidden, and the (rethrowing) persistent-history prune is part of the sequence. Deliberately not used by `purgeEncryptedEntities()`, whose wipe must stay atomic across all four entities under one save. |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/IntimacyLogRepository.swift` | Sealed Core Data repository for `IntimacyLog` records (ChaChaPoly column-encrypted intimacy notes). |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/IntimacyLogStore.swift` | `@MainActor IntimacyLogStore`: the fail-closed, visibility-gated funnel for every intimacy sealed-note read/write. |
| `Fernlet/FernletKit/Sources/PrivateMemoryStore/JournalNarrativeRepository.swift` | Sealed journal-narrative store: `JournalNarrative` model, `JournalNarrativeStoring` protocol, and its encrypted repository. |
| `Fernlet/FernletKit/Sources/PrivateMemoryStore/WorryNarrativeRepository.swift` | Sealed, device-only Worry Box store: `WorryNarrative` model, `WorryStoring` protocol, and its encrypted repository. |
| `Fernlet/FernletKit/Sources/PeriodContextBridge/PeriodContextBridge.swift` | Period-module egress bridge: raw→abstract cycle conversions (`PeriodPhaseBand`) exporting only coarse enums past the S3 wall. |
| `Fernlet/FernletKit/Sources/PeriodContextBridge/PeriodPhaseTrendEngine.swift` | `PeriodHealthTrend` device-sealed per-phase wellbeing trend (coarse direction + confidence band) from the user's own history. |
| `Fernlet/FernletKit/Sources/CloudKitSync/HeartDropCloudTransport.swift` | CloudKit **public**-database ferry for heart drops (the app's only public-DB use): upload one sealed drop per tag, fetch a friend's tag window with per-chunk anti-starvation budgeting. Sees tags and ciphertext only. |
| `Fernlet/Fernlet/SealedBackupGenerationStore.swift` | Device-local, never-synced high-water mark of the highest sealed-backup generation this device has written or accepted, per payload type **and per own-photo corpus** (a separate key namespace, since the two routes have independent write histories) — the state half of the rollback defense. The crypto half is the generation binding in `SealedBackupCrypto.authenticatedData`. Cleared by the delete-all path. |
| `Fernlet/FernletKit/Sources/CloudKitSync/CloudKitSchemaDeploy.swift` | The schema-deploy launch flag. `isRequested(arguments:)` is pure and testable; the caller that actually pushes the schema is `#if DEBUG`-gated so it cannot fire in Release. See [CloudKit-Schema-Deploy.md](CloudKit-Schema-Deploy.md). |

## Domain Models (FernletDomainModel)

The portable value-type layer that replaced the app's old `Models.swift`, split per area.

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/FernletDomainModel/WellbeingModels.swift` | Day, health-context, journal, sleep, hygiene, goals, and daily-score value models (`FernletDay`, …). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/NutritionModels.swift` | Nutrition, food, meal, recipe, and macro/micronutrient value models (`UserNutritionProfile`, …). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/WorkoutModels.swift` | Workout, exercise, muscle, and equipment value models (`Workout`, …). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/WorkoutProgram.swift` | Workout program/training model value types: `ExperienceLevel`, `WorkoutProfile`, training-split selection. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/WorkoutRestGuidance.swift` | Evidence-based default rest-between-sets table (`WorkoutRestGuidance`) keyed by movement `Demand` and training goal. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/CompanionModels.swift` | Companion appearance, workshop, and texture value models (`WorkshopData`, `TextureEntry`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/SettingsModel.swift` | `FernletSettings` app-settings serialization aggregate (hydration, companion, equipped items, designer provenance). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/AgeAssurance.swift` | `AgeGate` (13/16/18), `AgeGateVerdict`, `AgeAssuranceProvenance`, and `AgeAssuranceRecord` — the pure age-gate rules: fail-closed, a below-gate verdict is unappealable, and provenance is asymmetric (it can close a gate but not open one). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/NavigationEnums.swift` | Screen/widget/shortcut navigation enums (`FernletScreen`, `ConnectionInspectorMode`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ScoringValueTypes.swift` | Pure scoring value types (`ScoringWeights`) carved out of the app-layer scoring logic. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/FoodItemSearch.swift` | Pure relevance-search value logic over `FoodItem` plus a restaurant-chain brand lexicon (`FoodItemSearch`, `FoodBrandLexicon`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/RecipeSourceURLMatcher.swift` | The one source-URL normalization rule (scheme/host case-insensitive, fragment stripped, query kept) behind the zero-network duplicate skip, the supersede-on-re-import match, the superseded-photo cleanup, and the mesh already-saved decision. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/EnumDecodeCompat.swift` | Forward-compatible decode helpers (`EnumDecodeCompat`) for synced raw-value enums: park and re-adopt unknown tokens via side channels. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/AIAnalysisRetryRecord.swift` | Codable retry-queue record (`AIAnalysisRetryRecord`) for pending AI-analysis payloads; element type of `FernletSnapshot.retryQueue`. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/AIDestination.swift` | `AIDestination` enum naming where an AI call is routed (on-device FoundationModels or web nutrition lookup). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/TierTwoMemoryRecord.swift` | Codable tier-two behavioral memory record (`TierTwoMemoryRecord`) referenced by the repository and memory agent. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/DiagnosticLanguage.swift` | Pure best-effort classifier (`DiagnosticLanguage`) flagging clinical/diagnostic language to screen out of AI prompts and stored memories. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/CustomItemModels.swift` | User-designed custom clothing/accessory models: `ItemSlot` taxonomy, palette-indexed grid textures, `CustomizationItem`. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ItemDesigner.swift` | `ItemDesigner` provenance value carrying only an anonymous, stable designer id for "designed by …" attribution. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ItemNameModeration.swift` | Pure profanity/slur name gate (`ItemNameModeration`) for items listed for sale in the clothing shop. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ClothingModeration.swift` | Value types and pure verdict math for the in-person clothing-shop report/ban moderation ledger (`ReportReason`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ClothingShopLimits.swift` | Shared constants and a wire-boundary sanitizer (`ClothingShopLimits`) clamping untrusted peer-received shop items. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/CoinEconomy.swift` | Append-only coin-ledger model (`CoinLedgerEntry`, `CoinLedgerKind` earn/spend) and balance-aggregation math with structural idempotency. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/MilestoneLedger.swift` | Append-only cumulative care-milestone ledger model (`MilestoneEventKind`, `MilestoneLedgerEntry`); lifetime counts that survive resets. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/IdentityDedup.swift` | `Array.deduplicatedByID()` — the application-level union-merge that collapses duplicate-id rows (first seen wins, order preserved), needed because `NSPersistentCloudKitContainer` mirrors by record identity and does not honor an id attribute as unique. The one implementation now behind `CoinEconomy.deduplicatedByID`, `MilestoneEconomy.deduplicatedByID`, and the StoreCore per-row services' load paths, which each held their own copy of the loop. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/Closeness.swift` | Deterministic closeness math and close-friend slot assignment: `FriendInteractionDayCounts` and capped daily warmth points. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/FriendState.swift` | Friend-facing fuzzy wellbeing state (`FriendFuzzyState`) and its sealed shareable payload, derived from the state enum, never the score. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/HeartSharing.swift` | Wire model (`HeartPayload`) and presentation math for proximity "send good vibes" hearts between friends. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ActivityModels.swift` | Pure value types for proximity group activities: host-signed versioned rosters, join tokens, and `ActivityLimits`. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ProximityCoordinatorEnums.swift` | Top-level proximity enums (`ProximityRole`, `ProximityMode`, `ProximityRangingMode`) hoisted out of `ProximityCoordinator`. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ProximityPersistenceRecords.swift` | Codable proximity trust/audit DTOs (`ProximityTrustedPeerRecord`) for the persisted, synced trust vault. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/FDADailyValues.swift` | The single FDA Daily Value reference table shared by the gap analyzer and the label scanner, verified against 21 CFR 101.9. Flat label-comparison reference — no age/sex adjustment, no upper intake levels. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/GroceryAggregation.swift` | Pure, catalog-free shopping-list aggregation (F3, §11.3): merges several recipes' ingredients into one consolidated list. Below the wall, no I/O — `FoodItem` resolution stays the caller's job. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/RecipeScaling.swift` | Pure proportional recipe scaling (F4, §11.4). A non-persisted view/share-time transform returning scaled *copies* — it never mutates a stored recipe, resolves no `FoodItem`, and touches no catalog. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/RecipeSubstitution.swift` | A bound substitution suggestion: a catalog `FoodItem` proposed to replace one ingredient, plus an optional display-only reason. The model picks a candidate *number*; code binds it back to the catalog. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/HeartDropTransport.swift` | The `HeartDropRecord` (rotating pairwise day tag + sealed blob) and the `HeartDropTransporting` seam. The transport neither knows nor can learn who either endpoint is — this is why the wall holds across CloudKit. |

## Food, Nutrition, And Recipe Services

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/FoodCatalog/FoodDataCatalog.swift` | USDA food item record decoder (compact + raw FDC), source-JSON loading for the DB generator, `FoodItemSearch` scorer, and recipe search helpers. |
| `Fernlet/FernletKit/Sources/FoodCatalog/FoodCatalog.swift` | `FoodCatalog` service: merges the SQLite bundled food source with the in-memory user-item snapshot; search via FTS candidate prefilter → `FoodItemSearch` scorer, plus ID/exact-name resolution. Replaces the old in-memory `allFoodItems` array. |
| `Fernlet/FernletKit/Sources/FoodCatalog/BundledFoodStore.swift` | `BundledFoodSource` protocol + read-only SQLite-backed `SQLiteBundledFoodSource` (FTS5 candidate query, id/exact lookups, hydration) and `InMemoryBundledFoodSource` for tests; shared `FoodCatalogSchema`. |
| `Fernlet/Fernlet/FoodCatalogDatabaseBuilder.swift` | Build-time generator that converts the `FoodDataSource/*.json` foods into the shipped read-only `FoodCatalog.sqlite` (run via the gated `FoodCatalogGenerationTests`). Not used at runtime. |
| `Fernlet/FoodDataSource/USDAFoodItems.json` | Source USDA food item dataset consumed by the build-time DB generator (not bundled at runtime). |
| `Fernlet/FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite` | The shipped read-only SQLite food catalog (FTS5), generated from `FoodDataSource/` and loaded via `Bundle.module`. |
| `Fernlet/Fernlet/WorkoutExercises.json` | Bundled exercise dataset consumed by the workout system. |
| `Fernlet/FernletKit/Sources/AIProviders/FoundationFoodSelection.swift` | Foundation model availability and food selection model helpers. |
| `Fernlet/FernletKit/Sources/AppServices/NutritionLabelScanner.swift` | Nutrition label scan result model, scan errors, and scanner implementation. |
| `Fernlet/Fernlet/NutritionLabelCameraSheet.swift` | Camera and image picker UI for capturing nutrition labels and reviewing scan results. |
| `Fernlet/FernletKit/Sources/AIProviders/RecipeWebImporter.swift` | Recipe import pipeline for extracting structured recipes from web content and metadata. |
| `Fernlet/Fernlet/RecipeShareCodec.swift` | Encodes and decodes recipes into a shareable text format for peer-to-peer recipe sharing. |
| `Fernlet/Fernlet/MealBuilder.swift` | Converts a `FoodSelectionPlan` and food candidates into structured `Meal` records and inline recipe definitions, with good-protein threshold logic. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/CustomIngredientUpsert.swift` | Resolves manual recipe ingredient inputs into `FoodItem` records, creating or updating custom food entries in the catalog. |
| `Fernlet/Fernlet/MealResolutionService.swift` | `MealResolutionService` + `MealPlausibility` — the quick-log meal-resolution cascade (AI decomposition → AI selection → lexicon → plan → heuristic) plus the micronutrient fallback and implausible-total gate. |
| `Fernlet/Fernlet/FoundationDishDecomposition.swift` | `FoundationDishDecompositionModel` — on-device Foundation Models decomposition of a meal description into catalog-resolved, scaled `Meal` components with a match confidence. |
| `Fernlet/Fernlet/DishTemplateLexicon.swift` | `DishTemplateLexicon` + JSON template types — loads `DishTemplates.json` for deterministic, count-aware dish-template lookup (the decomposition fallback path). |
| `Fernlet/Fernlet/FoodCaptureRouter.swift` | `FoodCaptureRoute` + router — auto-detects a captured photo (barcode / nutrition label / meal) and routes to the matching existing flow, or `.ambiguous` for a gentle chooser. |
| `Fernlet/Fernlet/MealPhotoRecognizer.swift` | `MealPhotoRecognizer` (+ host protocol) — on-device Vision food-photo classification that composes a text description into the existing `resolveMeals` cascade, always pausing at review. |
| `Fernlet/Fernlet/MealPhotoPolaroid.swift` | `MealPhotoPolaroid` — polaroid-framed meal-photo tile with lazy sealed-byte load and `MealPhotoPresence` classification (here / on other device / unreadable). |
| `Fernlet/Fernlet/RecentBites.swift` | `RecentBite` + `MealPhotoPresence` — pure 7-day windowing behind Home's "Recent bites" photo strip (resolves which photographed meals to show without reading sealed bytes). |
| `Fernlet/Fernlet/BarcodeScanView.swift` | `BarcodeResolveFlowView` / `BarcodeScanView` — scan a product barcode and resolve it (user items → catalog → gentle not-found that creates a food item with the barcode remembered). |
| `Fernlet/Fernlet/BrandedCatalogResourceLoader.swift` | `BrandedCatalogResourceLoader` — loads the ~364k-product branded food DB (`FoodCatalogBranded.sqlite`) via bundle-first or On-Demand Resource and attaches it as a secondary `FoodCatalog` source. |
| `Fernlet/Fernlet/FoodProductWebImporter.swift` | `FoodProductWebImporter` / `FoodProductWebSearch` / `ImportedFoodProduct` — on-device Foundation Models import of a branded product's nutrition from a web product page. |
| `Fernlet/Fernlet/NutritionTargetsEditor.swift` | `NutritionTargetsEditor` — Settings card to edit macro targets (calories/protein/fat overridable, carbs shown as the live rebalancing residual). |
| `Fernlet/FernletKit/Sources/FernletScoring/Scoring.swift` | Health scoring, goal weights, meal parsing, workout planning, workout suggestions, and date helpers. |
| `Fernlet/FernletKit/Sources/FernletScoring/PeriodScoringSignals.swift` | Abstract period-scoring vocabulary (`PeriodSignalStrength`, `PeriodPhaseSignal`, `PeriodScoringAdjustment`) consumed by the scoring engine. |
| `Fernlet/FernletKit/Sources/AppServices/BarcodeScanner.swift` | Vision still-photo product-barcode detection (`BarcodePayloadDetecting` seam + `VisionBarcodeDetector`/`BarcodeScanner`) over EAN-13/EAN-8/UPC-E, the fallback for devices lacking live `DataScannerViewController`. |
| `Fernlet/FernletKit/Sources/AppServices/FoodImageClassifier.swift` | On-device meal-photo image classification behind the `FoodImageClassifying` seam (`VisionFoodImageClassifier` via `VNClassifyImageRequest`), returning raw taxonomy labels; the photo never leaves the device. |
| `Fernlet/FernletKit/Sources/WebScrapingKit/EphemeralWebSession.swift` | `EphemeralWebSession` — the single private-browsing `URLSession` (ephemeral + cookies/cache/credentials explicitly disabled) that both web importers fetch through. The per-setting rationale, including which knobs are redundant under `.ephemeral` and why they are set anyway, lives here (see [No-Tracking-Wall.md](No-Tracking-Wall.md) §2a). |
| `Fernlet/FernletKit/Sources/WebScrapingKit/HTMLScraper.swift` | `HTMLScraper` — shared regex capture reads, HTML-entity decoding (`decodingNumericEntities:` preserves both importers' differing policies), and the body-to-plain-text pass; returns `nil` on an empty page so each caller throws its own error. |
| `Fernlet/FernletKit/Sources/WebScrapingKit/JSONLDScraper.swift` | `JSONLDScraper` — `application/ld+json` script extraction, `@type` reading, and the recursive `@graph`/`itemListElement` search that finds a schema.org `Product` or `Recipe`. |
| `Fernlet/FernletKit/Sources/FoodCatalog/CuratedNutrientSources.swift` | Hand-authored "good source" foods per tracked micronutrient — the F2 gap-filling nudge's payload, pinned to real bundled-catalog ids so the card can bind the food and offer "add it". |
| `Fernlet/Fernlet/GroceryListComposer.swift` | F3 app-target glue between the recipe stores and the pure `GroceryAggregation` engine: catalog resolution the engine refuses to do, F4 "cook for N" scaling, and web-import lines through `DataExportBuilder.recipeIngredientLines`. The list is one-shot share text; only the weekly plan persists. |
| `Fernlet/Fernlet/GroceryPlannerView.swift` | The Phase A shopping-list builder: multi-select recipes with an optional per-recipe yield, preview the aggregated list, share as plain text. Nothing here persists. |
| `Fernlet/Fernlet/IngredientSubstitutionSheet.swift` | F4 substitution UI (§11.4): replace ONE structured ingredient. Applying forks a new recipe only on an explicit "Save as new recipe" tap — cancelling forks nothing and never mutates the source. |
| `Fernlet/Fernlet/CookingMode.swift` | `CookingModeAvailability` — the single rule deciding whether a recipe gets a "Cook" action (authored steps, structured ingredients, or a web import's free-text lines). UIKit-free. |
| `Fernlet/Fernlet/CookingLiveActivityController.swift` | App-target-only requester of the cooking Live Activity (starting one is the only thing solely the app process can do). Updates/ends go through the shared `CookingActivityBridge`. |
| `Fernlet/Fernlet/BarcodeServingStepView.swift` | The quick serving-count step after a barcode scan, plus its device-local last-serving memory keyed by normalized GTIN — a `UserDefaults` sidecar deliberately kept off the synced/sealed blob path. |
| `Fernlet/Fernlet/RecipeWebImageAttemptMemory.swift` | Device-local `UserDefaults` sidecar recording which recipes' one automatic web-image download THIS device already attempted — the per-device half of the “one attempt per device, suppression syncs” contract (the synced half is `RecipeWebImport.webImageSuppressed`). |

## AI Context And Providers

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/AIContext/AIContextPayload.swift` | `AIContextPayload` marker protocol and concrete payload types (food-selection, meal-decomposition, etc.) defining the exact allowlisted fields that may enter each AI prompt. |
| `Fernlet/FernletKit/Sources/AIContext/MemoryAgent.swift` | Gate routing Tier-2 memory into AI prompts through a destination allowlist, recency filter, confidence filter, and diagnostic-language post-classifier, returning a char-capped context string. |
| `Fernlet/FernletKit/Sources/AIContext/AIAuditLog.swift` | `AIAuditEntry` metadata record plus the in-session `AIAuditLog` actor logging each AI call's payload kind, destination, included field names, and memory char count — metadata only, never persisted. |
| `Fernlet/FernletKit/Sources/AIProviders/FoundationWorkoutAdjustment.swift` | On-device workout adjuster: `WorkoutAdjustmentCandidateBuilder` builds the equipment/injury-filtered, ranked, capped candidate pool and `FoundationWorkoutAdjustmentModel` maps a natural-language request to substitutions within it via FoundationModels. |
| `Fernlet/FernletKit/Sources/AIContext/AICapabilityTier.swift` | The minimum capability an AI task declares, plus its ordered `escalationLadder`. The router picks the *cheapest available* destination meeting the tier, never above device capability or the user's ceiling (Ladder §3.1). |
| `Fernlet/FernletKit/Sources/AIContext/AIDeviceCapability.swift` | Snapshot of which AI rungs the *device* can physically reach, independent of user settings; obtained through the `AIDeviceCapabilityProviding` seam so tests can inject a fixed value. `.webNutritionLookup` always reports false by design (settings-gated web path, not an LLM rung). |
| `Fernlet/FernletKit/Sources/AIContext/AICallQuota.swift` | The daily AI-call budget with day-key rollover (Ladder §3.2). A pure value the *caller* stores device-locally — the derived `.sleepy`/`.resting` states must never reach synced `FernletSettings`, or one device's usage would throttle another. |
| `Fernlet/FernletKit/Sources/AIContext/FernletModelRouter.swift` | Capability-capped route resolution and its `AIRouteResolution`/fallback-reason vocabulary, letting deferred tasks tell a transient budget fallback from a persistent one before spending a retry. |
| `Fernlet/FernletKit/Sources/AIContext/FernletAIGate.swift` | The single routing entry point every AI call site funnels through — router + stored user intent + device-local quota in one value. `dispatch`/`resolveRoute` are the only places the daily quota is charged. |
| `Fernlet/FernletKit/Sources/AIProviders/SystemLanguageModelCapabilityProvider.swift` | Production `AIDeviceCapabilityProviding`: wraps `SystemLanguageModel.default.availability`. The PCC and BYOK rungs report false here — their symbols are iOS 27 APIs. |
| `Fernlet/FernletKit/Sources/AIProviders/FoundationIngredientSubstitution.swift` | On-device stage for F4 substitution: the model contributes world knowledge only (substitute food *names* plus an optional reason) — never a quantity, macro, or binding. Code rebinds each name through the local catalog. |
| `Fernlet/Fernlet/FernletAIComposition.swift` | Composition-root factory for the AI provider seam. Lives in its own file on purpose: naming `SystemLanguageModel…` matches the S3 grep-wall's AI-facing marker, keeping the type out of `FernletStore.swift`. |
| `Fernlet/Fernlet/AICallQuotaStore.swift` | The device-local, non-synced daily AI-call counter backed by `UserDefaults`. Deliberately app-target-only: the walled AI module reaches it solely through the `AICallQuotaStore` protocol declared in `AIContext`. |
| `Fernlet/Fernlet/FileAIAuditLogStore.swift` | Device-local, non-synced persistence sink for the AI audit log (Ladder §7.2) — one JSON file in Application Support, reached only through the `AIAuditLogPersisting` protocol. |

## Health And Launch Services

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/HealthKitGateway/HealthKitService.swift` | HealthKit service protocol and implementation, capability metadata, authorization snapshots, body/activity/cycle/mindfulness context, and authorization view model. |
| `Fernlet/FernletKit/Sources/HealthKitGateway/WorkoutHealthKitSync.swift` | HealthKit workout import pipeline; reads `HKWorkout` samples and upserts matching `Workout` records via a `WorkoutSyncContext`. |
| `Fernlet/Fernlet/HealthSyncCoordinator.swift` | `HealthSyncCoordinator` (`HealthSyncContext`) — HealthKit ingestion (daily-context merge, derived sleep, workout import/backfill/observe) extracted from `FernletStore`. |
| `Fernlet/Fernlet/CoreDataHealthKitCacheCleaner.swift` | `CoreDataHealthKitCacheCleaner` — concrete `HealthKitCacheClearing` that scrubs HealthKit-cached values from Core Data / the local DB, fail-closed so opt-out never silently "succeeds". |
| `Fernlet/Fernlet/WorkoutTombstoneStore.swift` | `WorkoutTombstoneStore` — persisted capped FIFO ring of removed workout ids so a resurrected orphan HealthKit sample is deleted-and-skipped rather than re-imported. |
| `Fernlet/FernletKit/Sources/PrivateHealthStore/CyclePredictionEngine.swift` | Statistical cycle prediction engine using historical period data to forecast next period start, flow patterns, confidence level, and predicted flow days. |
| `Fernlet/Fernlet/LaunchPreparationService.swift` | Launch preparation state and photo wall seed loading. |
| `Fernlet/FernletKit/Sources/FernletFoundation/StartupTiming.swift` | `os_signpost`-based startup timing probes for measuring and instrumenting app launch phases. |
| `Fernlet/FernletKit/Sources/AppServices/NotificationService.swift` | Thin `UNUserNotificationCenter` wrapper for the opt-in gentle daily check-in local reminder: authorization, status check, and scheduling. |
| `Fernlet/FernletKit/Sources/AppServices/WeatherKitService.swift` | Opt-in coarse-location WeatherKit service producing tiny derived snapshots (`WeatherComfort` walk-friendliness, `AmbientSky` sky bucket) for mood-recovery prompts and Home ambience; degrades to nil, leaking no raw data. |
| `Fernlet/FernletKit/Sources/FernletFoundation/FernletDate.swift` | Layer-0 date helpers (`FernletDate`): canonical `yyyy-MM-dd` day-key formatting, enumeration, and display. |
| `Fernlet/FernletKit/Sources/FernletFoundation/MonotonicClock.swift` | `MonotonicClock` protocol plus sleep-counting `SystemMonotonicClock` (`mach_continuous_time`) for the store-ban clock. |
| `Fernlet/FernletKit/Sources/FernletFoundation/FernletAuditLog.swift` | Privacy audit-log facade (`FernletAuditLog`) emitting os_log events with a test-observable capture-handler registry. |
| `Fernlet/FernletKit/Sources/FernletFoundation/BackupExclusion.swift` | Layer-0 helper (`BackupExclusion`) toggling `isExcludedFromBackupKey` across a Core Data store file and its sidecars. |
| `Fernlet/FernletKit/Sources/FernletFoundation/FernletFoundation.swift` | Overview/placeholder source standing up the layer-0 `FernletFoundation` module. |

## Social And Mesh Networking

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift` | Observable mesh network coordinator managing active/lightweight peer slots, proximity-join (15 cm commit gate), pairwise/mesh promotion, session open/closed state, member removal proposals, admission requests, friend-of-friend vouchers, photo session metadata, encrypted mesh payloads, coordinator beacons, and key rotation. Its observation loop explicitly finishes cancelled streams so repeated Friends-tab discovery sessions do not retain suspended observers. |
| `Fernlet/Fernlet/DisposableCameraView.swift` | Active Friends-session disposable-camera UI: `CameraCaptureController` (`@Observable`, queued `AVCaptureSession` lifecycle, rotation handling, and arm/wind gate), `CameraPreviewView`, and the full-screen camera. The session-info sheet exposes the 10-shot film count, open/closed access, mesh rename, participant options, friend-of-friend labels, diagnostics, removal requests, and end-session flow; admission requests and mesh errors are presented as popups. |
| `Fernlet/Fernlet/JoinPromptSheet.swift` | `JoinPromptSheet` — the shared "someone wants to join" confirmation for both closed-group gatekeepers: mesh admission requests (presented by the disposable-camera session flow) and Group Activity join requests (presented by `ActivitiesView`). Generic over the request payload via display-name/fingerprint extractor closures; swipe-to-dismiss declines everything still pending (fail-closed). Replaced the former `MeshAdmissionPromptSheet.swift` and `ActivityJoinPromptSheet.swift`. |
| `Fernlet/Fernlet/FriendListView.swift` | Friend list screen for browsing trusted proximity peers with all/friends/blocked filters and block management. |
| `Fernlet/Fernlet/ActivitiesView.swift` | `ActivitiesView` — Group Activities screen (host form / nearby invites / hosting roster / joined states) off the Friends tab, driven by `ProximityActivityManager`. |
| `Fernlet/Fernlet/SessionChatPanel.swift` | `SessionChatPanel` — live-session ephemeral chat panel (memory-only transcript cleared at session end) over `MeshNetworkManager`. |
| `Fernlet/Fernlet/SafetyReportingView.swift` | `SafetyReportingView` — always-available report/block explainer and no-tolerance policy for shared shop items and people (App Store UGC compliance). |

## Proximity

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift` | High-level coordinator for proximity sessions; orchestrates MultipeerConnectivity transport, signed identity/ranging-token handshake, UWB startup, heartbeat RTT, payload dispatch, and inspector recording. |
| `Fernlet/FernletKit/Sources/ProximityKit/Engine/ObservationLoop.swift` | `ObservationLoop.start` — the shared `withObservationTracking` re-arm loop behind the proximity managers' coordinator-state observers (`MeshNetworkManager.startObserving`, `ProximityRecipeShareManager.startObserving`, `PresenceManager.startHeartObserving`), which each hand-rolled the same machinery until its leak-fix comment had drifted to only one copy. Holds the owner weakly and finishes the `AsyncStream` explicitly, so a cancelled discovery session leaves no suspended observer task behind. |
| `Fernlet/FernletKit/Sources/ProximityKit/Transport/MultipeerPeer.swift` | MultipeerConnectivity peer model plus persistent `MCPeerID` storage shared by active mesh transport and future trainer transport work. |
| `Fernlet/FernletKit/Sources/ProximityKit/Transport/MultipeerTransport.swift` | Neutral MultipeerConnectivity transport protocol, state, invite, inbound-message, error, and reserved trainer-service definitions. |
| `Fernlet/FernletKit/Sources/ProximityKit/Engine/ProximityCommitDetector.swift` | Rolling distance-window detector used by proximity commit and trainer tap gates. |
| `Fernlet/FernletKit/Sources/ProximityKit/Ranging/RangingProvider.swift` | Ranging provider contract plus shared distance and state models. |
| `Fernlet/FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift` | Shared `MCSession` host for multi-peer mesh; `PeerChannelTransport` adapts per-peer state and data routing without managing the MC lifecycle directly. |
| `Fernlet/FernletKit/Sources/ProximityKit/Mesh/MeshSessionTypes.swift` | Mesh session slot, group-key, ranking-window sample, participant, and encryption-error support models extracted from the manager. |
| `Fernlet/FernletKit/Sources/ProximityKit/Mesh/MeshNameGenerator.swift` | Generates random human-readable two-word mesh names from adjective/noun word lists. |
| `Fernlet/FernletKit/Sources/ProximityKit/Ranging/NIRangingSession.swift` | NearbyInteraction UWB ranging session for measuring real-time distance and direction between Fernlet devices. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/FernletIdentityEnvelope.swift` | Ed25519-signed wire envelope for all peer-to-peer transfers, including canonical JSON encoding and verification. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/PayloadType.swift` | Peer-to-peer payload classification, envelope encryption mode, and payload summary models. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/MeshPayloads.swift` | Mesh descriptor, admission, removal, voucher, group-encryption, and coordinator-beacon wire models plus admission-token signing and verification. |
| `Fernlet/FernletKit/Sources/FernletDomainModel/FriendPhotoPayloads.swift` | Friend-photo payload, session metadata, manifest, and missing-photo request wire models. |
| `Fernlet/FernletKit/Sources/ProximityKit/Identity/IdentityService.swift` | Per-device Ed25519 signing identity and X25519 key-agreement, with keys stored in Keychain under `AfterFirstUnlockThisDeviceOnly`. |
| `Fernlet/FernletKit/Sources/ProximityKit/Identity/ReplayCache.swift` | Rolling 24-hour envelope-ID cache for replay-attack prevention; injectable clock for deterministic testing. |
| `Fernlet/Fernlet/Proximity/Audit/ConnectionInspector.swift` | Live and historical proximity session logging, ranging mode/distance samples, RTT samples, event subsampling, and session lifecycle recording (`ProximityInspectorRecording`). |
| `Fernlet/FernletKit/Sources/FernletDomainModel/ConnectionSessionLog.swift` | Structured session log model capturing peer info, ranging state, transport counters, envelope records, and error events. |
| `Fernlet/Fernlet/Proximity/UI/ConnectionInspectorView.swift` | On-demand live connection inspector UI for real-time proximity diagnostics, distance, RTT, and fallback status. |
| `Fernlet/Fernlet/Proximity/UI/ConnectionInspectorHistoryView.swift` | View for browsing and reviewing historical proximity connection session logs. |
| `Fernlet/FernletKit/Sources/ProximityKit/UI/KeepFriendsPromptSheet.swift` | `KeepFriendsSection` + prompt sheet — session-end one-sided "keep as a friend?" affordance that mints a local-only trust-vault record (peer never notified). |
| `Fernlet/Fernlet/Proximity/UI/ProximityRecipeShareSheet.swift` | `ProximityRecipeShareSheet` + `ProximityRecipeShareDraft` — outbound sheet to share a recipe with a nearby Fernlet over the proximity channel. |
| `Fernlet/Fernlet/Proximity/UI/ProximityRecipeShareReviewSheet.swift` | `ProximityRecipeShareReviewSheet` — review an incoming proximity-shared recipe (title, servings, macros) before saving it. |
| `Fernlet/Fernlet/ProximityHostAdapter.swift` | Conforms `FernletStore` to the Proximity subsystem's `ProximityHost` seam (proximity display name, nearby-hearts opt-in). |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/TrainerAuditLog.swift` | Trusted peer records, `ProximityTrustPolicy`, and trainer-named audit event vocabulary shared by proximity sessions. |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/FriendSessionTrustPolicy.swift` | Friend-session trust-policy wrapper over `ProximityTrustVault`; blocked, revoked, and audit operations delegate to the vault while proximity-gated sessions remain permissive for remembered-trust checks. |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/ProximityTrustVault.swift` | Trusted proximity peer records and trainer audit event vault; implements `ProximityTrustPolicy`. Extracted sub-service of `FernletStore`. |
| `Fernlet/FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift` | Review tile, review sheet, and photo-library saver for shared friend photos. |
| `Fernlet/FernletKit/Sources/ProximityKit/ForegroundAnchor/ProximityForegroundAnchor.swift` | Live Activity anchor that keeps proximity sessions alive when the app moves to the background. |
| `Fernlet/FernletKit/Sources/ProximityKit/ProximityHost.swift` | `@MainActor` host-protocol seam letting the mesh/recipe-share managers reach app state (display name, trusted peers, trust vault, block/fingerprint checks, nearby-hearts opt-in) without naming concrete `FernletStore`. |
| `Fernlet/FernletKit/Sources/ProximityKit/PeerDisplayNames.swift` | The subsystem's two shared display-name coercions: `ProximityHost.resolvedProximityDisplayName` (the LOCAL advertised name — host preference trimmed, device name as fallback), the one home of the three identical private `displayName` vars in `MeshNetworkManager`, `ProximityRecipeShareManager`, and `PresenceManager`; and `ItemNameModeration.moderatedPeerDisplayName` (the wire-boundary sanitize-or-"A friend" coercion for a PEER-supplied name), the one home of that idiom in the heart-receive, vouch-list, session-chat, and keep-as-friend paths. `FernletStore.shopDisplayName` and the heart-drop name paths differ on purpose and deliberately do not adopt it. |
| `Fernlet/FernletKit/Sources/ProximityKit/Support/JSONSidecarFile.swift` | `JSONSidecarFile` — the shared best-effort load/save/remove plumbing for the device-local Application Support JSON sidecars (`.completeFileProtection`, never synced) that `FriendStateCache`, `ClosenessLedger`, `ModerationLedger`, `ProximityActivityManager`, and `MeshNetworkManager`'s photo-wall preferences each repeated verbatim; it replaced the private `FriendPhotoWallPreferencesStore` outright. Deliberately the naive idiom — every read failure (including a locked-device read) returns nil and reads as "no data", so anything that is data of record must use `ProtectedSidecar` instead. |
| `Fernlet/FernletKit/Sources/ProximityKit/Activities/ProximityActivityManager.swift` | State-and-logic brain for Group Activities riding the friend mesh: roster state, host-authoritative join-token minting/verification, and a device-local never-synced sidecar surviving relaunch until expiry. |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/ProximityHeartLedger.swift` | Device-local JSON sidecar for received hearts (Home bubble + 24h health-bar glow) plus the rolling 1-per-friend-per-5-minute rate limit enforced both directions; never synced. |
| `Fernlet/FernletKit/Sources/ProximityKit/Messaging/SessionMessageStore.swift` | Deliberately non-`Codable`, memory-only holder of the current friend-session chat transcript; sanitizes/caps/dedupes/rate-limits messages and clears them at every session end and formation. |
| `Fernlet/FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift` | Standing presence radio on `fernlet-near` broadcasting only rotating pairwise-DH tags for nearby-friend recognition, and driving the on-demand short-lived pairwise heart send/receive handshake; memory-only. |
| `Fernlet/FernletKit/Sources/ProximityKit/Presence/ClosenessLedger.swift` | Device-local day-granularity per-friend interaction counters feeding the deterministic closeness score and close-slot assignment (with persisted hysteresis); capped, never synced. |
| `Fernlet/FernletKit/Sources/ProximityKit/Presence/FriendStateCache.swift` | Device-local cache of a friend's fuzzy wellbeing state + avatar appearance captured at the last in-person meet (`CachedFriendState`), with 30-day staleness treatment; never synced. |
| `Fernlet/FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift` | `@MainActor` `@Observable` manager for one-at-a-time in-person recipe sharing: nearby-recipient discovery, a single verified sealed connection, send-state machine, pending inbound shares, and diagnostics. |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/FriendMintingReview.swift` | Pure view-free decision logic for the post-session keep-as-friend prompt: chooses the session-end review mode and filters roster candidates for eligibility against the trust vault at presentation time. |
| `Fernlet/FernletKit/Sources/ProximityKit/Moderation/ModerationBanStore.swift` | Tamper-resistant 30-day designer store-ban clock: reinstall-proof via a dedicated Keychain service and clock-tamper-proof via a `mach_continuous_time` countdown plus a wall-clock high-water ratchet. |
| `Fernlet/FernletKit/Sources/ProximityKit/Moderation/ModerationContentHash.swift` | Stable content key an abuse report binds to: order-stable SHA-256 over a sanitized item's artwork (texture grid + slot), so relisting under a new id/name cannot evade a report. |
| `Fernlet/FernletKit/Sources/ProximityKit/Moderation/ModerationLedger.swift` | `@MainActor` append-only JSON sidecar of moderation report/retract rows keyed for idempotent de-dupe and supersede-by-`reporterSeq`; bounded, never synced. |
| `Fernlet/FernletKit/Sources/ProximityKit/Moderation/ModerationReportRelay.swift` | One-hop report wire: `SignedModerationReport`/`ModerationReportPayload` models plus verification of each row's Ed25519 signature against the transport-verified sender key (no transitive relay — the Sybil defense). |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/ActivityPayloads.swift` | Group Activities wire envelopes plus `schemaVersion`-gated join-token/roster-snapshot signing and verification and the `ActivityParamsHash` descriptor hash. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/CanonicalSignatureSerializer.swift` | Deterministic, cross-platform-stable positional length-prefixed binary canonical-byte serializer for Ed25519 signing, replacing JSON `.sortedKeys` to prevent cross-stack `signatureInvalid`. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/MessagePayloads.swift` | `TempMessagePayload` wire value type for a single sealed live-session chat message (id/text/sentAt); receiver sanitizes and length-caps before use. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/RecipeSharePayloads.swift` | `ProximityRecipeSharePayload` wire envelope wrapping a `ProximitySharedRecipe` for in-person recipe sharing, plus the optional 512 KB `imageJPEGData` wire image (cap enforced at the receive door via `droppingOversizeImage()`) and the share-notes / include-picture strips. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/SealedIntroductionEnvelope.swift` | Transport wrapper carrying only the ciphertext of a KA-sealed identity intro/ack for presence-heart handshakes, so a tag-replay forger cannot deanonymize the sender's identity. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/TrainerPayloads.swift` | `TrainerExportPayload` wire envelope carrying the opaque, size-bounded curated Trainer/Nutritionist export bundle; sealing-required so an unsealed send fails closed at verify. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/SealedPayloadFraming.swift` | wire2 sealed-body framing (compress + pad inside the AEAD). Threaded through `IdentityService.seal/open` and envelope verify; derived from the peer's advertised capabilities, never from the bytes alone. |
| `Fernlet/FernletKit/Sources/ProximityKit/Wire/ProximityVerification.swift` | The QR verification ceremony that upgrades a non-UWB `awaitingManualCommit` slot to ceremony grade: the QR proves the signing key is physically on screen, the sealed challenge/response proves the live peer holds it. |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/CoachVerificationCeremony.swift` | Slot-independent verification ceremony for the in-person coach session (Increment 10). Carries the nonce-binding rules — per-peer nonce, sign-after-check, wrong-peer drop must not clear. **No production callers yet:** the coach session manager is unbuilt. |
| `Fernlet/FernletKit/Sources/ProximityKit/Trust/CoachSessionTrustPolicy.swift` | `CoachSessionContract` (the written-down coach/trainee role split) and the coach trust policy — a coach is NOT a friend, so only an unrevoked `.trainer` vault record with `unknownModeToken == nil` auto-confirms. **No production callers yet.** |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/HeartDropService.swift` | Offline "away" hearts over the CloudKit public-DB dead-drop. All crypto happens here on the sealed side of the wall; the injected transport only ever sees rotating day tags plus ciphertext. |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/HeartDropSealer.swift` | The outer seal for heart drops: versioned wire form with a prekey id (all-zeros = sealed to the static key). Gates payload size *before* key agreement. |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/HeartPrekeyStore.swift` | One-time X25519 prekeys for forward-secret drops, plus the X3DH-style signed prekey. Private halves live in one keychain blob (`AfterFirstUnlockThisDeviceOnly`, never synchronizable). |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/HeartDropPeerBundleCache.swift` | Cached prekey bundles gossiped by friends plus per-friend consumed-prekey marking. A bundle is only ever stored from a verified, signed identity intro, keyed by the sender's full signing key. |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/HeartDropOutbox.swift` | Persisted sender-side queue for offline drops plus the durable receive dedup — two sidecars beside `HeartLedger.json`, deliberately outside the synced snapshot. |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/ProtectedSidecar.swift` | The `ProtectedSidecar` state machine (absent / deferred / corrupt / loaded) and `SidecarSeal`. Fixes the class of data loss where any read failure read as "no data" and the next persist overwrote the real file. |
| `Fernlet/FernletKit/Sources/ProximityKit/HeartSharing/HeartDropSidecarKey.swift` | Keychain-backed ChaChaPoly seal for the heart-drop sidecars at rest — the plaintext versions were a timestamped log of who the user sent affection to. One-way plaintext→sealed migration. |
| `Fernlet/Fernlet/VerifyQRViews.swift` | `QRCodeRenderer` plus the verify-QR display/scan sheets — renders this device's signed `fernlet://verify` URL for the ceremony above. |

## Private Media Stores

| File | Purpose |
| --- | --- |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/PrivateMediaStore.swift` | Disk-backed mesh photo index with **AES-256-GCM at-rest encryption** of image/thumbnail bytes, thumbnail generation, hydration, FIFO eviction (1000 cap / 900 warn), and orphan cleanup. (Formerly `MeshPhotoCacheStore`.) |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/PrivateMediaKeyStore.swift` | `PrivateMediaKeyProviding` + the keychain-backed AES key provider, split per `Role` since hardening Phase 5: `.friendWall` = the original backup-restorable `AfterFirstUnlock` row (`…contentKey`, unchanged), `.ownPhotos` = a second row (`…ownContentKey`) for the user's own meal/recipe/progress media, whose device binding is a one-line policy flip in `defaultDeviceBinding(for:)`. Fails closed (no mint) when the keychain read is *unreadable* rather than definitively absent. |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/OwnPhotoKeyMigration.swift` | The own-photo key migration: `OwnPhotoCorpusLayout` (the one home of the own corpora's on-disk names), `OwnPhotoKeyMigrator` (eager, idempotent, crash-safe re-seal pass run once per launch off the main path), and `OwnPhotoMigrationLatch` (the persisted, fail-closed proof that gates device-binding and the removal of the read-path dual-open fallback). |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/MediaAtRestCrypto.swift` | Shared AES-256-GCM at-rest helpers on `PrivateMediaKeyProviding` (`gcmSeal`, `gcmOpen`, `sealAndWrite` — the last writes nothing at all on a nil key or seal failure, so plaintext never reaches disk). The one home of the seal / open / seal-then-write idiom `PrivateMediaStore`, `MealPhotoStore`, and `ProgressPhotoStore` each hand-rolled; deliberately policy-free, so each store keeps its own fail-closed decision (and its legacy-plaintext branch) at the call site. |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/FriendPhotoImageHelpers.swift` | `UIImage` resizing helper for friend-photo sharing. |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/MealPhotoStore.swift` | `MealPhotoStore`: on-device AES-256-GCM-sealed store for meal and other private photos with bounded downscale. |
| `Fernlet/FernletKit/Sources/PrivateMediaStore/ProgressPhotoStore.swift` | `ProgressPhotoStore`: sealed gym progress-photo timeline over `MealPhotoStore` bytes plus a GCM-sealed dated index. |

## Widgets, Live Activities, And App Intents

| File | Purpose |
| --- | --- |
| `Fernlet/FernletWidgets/FernletWidgetsBundle.swift` | `@main` `WidgetBundle` registering the companion widget (mood glyph + water) and the guided-workout Live Activity. |
| `Fernlet/FernletWidgets/WidgetSharedModels.swift` | Deliberately duplicated app-group models (`WidgetSnapshot`, `PendingWidgetAction`, `WidgetCompanionState`, day-key/JSON helpers) so the standalone widget extension avoids linking FernletKit. |
| `Fernlet/FernletWidgets/WaterPlusOneIntent.swift` | `AppIntent` behind the companion widget's interactive "+1 water" button; queues a pending action and reloads the widget timeline. |
| `Fernlet/FernletWidgets/WorkoutLiveActivity.swift` | Widget-target `Widget` rendering the Lock Screen card and Dynamic Island for the guided-workout rest-timer Live Activity. |
| `Fernlet/FernletWidgets/WorkoutActivityAttributes.swift` | `ActivityAttributes`/`ContentState` contract for the guided-workout Live Activity, compiled into both the app and widget targets. |
| `Fernlet/FernletWidgets/GuidedWorkoutRunState.swift` | Codable/Hashable value type for an in-progress guided workout, mirrored into the app-group container so Lock Screen intents can advance it. |
| `Fernlet/FernletWidgets/AppGroupRunStateStore.swift` | `AppGroupRunStateStore` + `AppGroupRunStatePersistable` — the generic `NSFileCoordinator`-guarded app-group reader/writer behind both run-state files (ISO-8601 + sorted-keys codecs, atomic protected writes, nil-tolerant reads that treat a missing/corrupt/still-protected file as "no active run", and the `updatedAt` re-stamp the app's reconcile ages out on). The single home of the plumbing `GuidedWorkoutRunStateStore` and `CookingRunStateStore` each carried; self-contained (literal app-group id) so it compiles identically into both targets. |
| `Fernlet/FernletWidgets/GuidedWorkoutRunStateStore.swift` | The guided-workout specialization of that store — now a `typealias` for `AppGroupRunStateStore<GuidedWorkoutRunState>`; the persistence seam between the app's in-app transitions and the Lock Screen intent runner. |
| `Fernlet/FernletWidgets/GuidedWorkoutActivityBridge.swift` | Shared bridge (app + widget targets) that syncs a `GuidedWorkoutRunState` onto the live workout Activity, updating or ending it. Remains the documented seam, now delegating the loop to `LiveActivityReflector`. |
| `Fernlet/FernletWidgets/LiveActivityRunReflecting.swift` | `LiveActivityRunReflectable` + `LiveActivityReflector` — the one generic update/end engine (update while the run is live, end on terminal) that `GuidedWorkoutActivityBridge` and `CookingActivityBridge` delegate to instead of each carrying the loop. Every call is parameterized by its own `ActivityAttributes` type, so ending one activity kind can never enumerate the other's instances. Compiled into both the app and widget targets. |
| `Fernlet/FernletWidgets/GuidedWorkoutLiveActivityIntents.swift` | `LiveActivityIntent`s for the guided-workout Live Activity's "Done set" and "Skip rest" Lock Screen buttons. |
| `Fernlet/Fernlet/WidgetBridge.swift` | `WidgetSnapshot` + bridge — app side of the FernletWidgets app-group JSON bridge: outbound benign snapshot and inbound pending widget actions (deliberately S3-walled twin types). |
| `Fernlet/Fernlet/WorkoutLiveActivityController.swift` | `WorkoutLiveActivityController` — app-side requester for the guided-workout Live Activity (starts one, ends any stale one; degrades silently when Live Activities are disabled). |
| `Fernlet/Fernlet/LiveActivityStarter.swift` | `LiveActivityStarter.start` — the shared generic requester behind `WorkoutLiveActivityController` and `CookingLiveActivityController`: ends any already-live activity of the same attributes type, then requests one, and no-ops when the user hasn't enabled Live Activities (request failures degrade silently). App-target only and deliberately outside the dual-membership set, because only the app process can start an activity — unlike the update/end engine (`LiveActivityRunReflecting.swift`), which the Lock Screen intents also need. |
| `Fernlet/Fernlet/FernletNavigation.swift` | App navigation enums (`FernletTab`, `FernletSheet`) — split out of the design system when it moved into the FernletUI package target (`FernletSheet` references app-resident `FirstAidTool`). |
| `Fernlet/Fernlet/FernletAppIntents.swift` | App Intents — `LogWaterIntent` (background app-group queue append, no app launch), `LogMealIntent` / `OpenJournalIntent` (open the app to the matching sheet via a persisted deep-link). |
| `Fernlet/Fernlet/FernletShortcuts.swift` | `FernletShortcuts` (`AppShortcutsProvider`) — surfaces the log-water/log-meal/open-journal App Intents to Siri and Spotlight with natural phrases. |
| `Fernlet/FernletWidgets/CookingActivityAttributes.swift` | ActivityKit contract for the cooking Live Activity (recipe name + per-step `ContentState`), compiled into both targets. |
| `Fernlet/FernletWidgets/CookingLiveActivity.swift` | The cooking Live Activity widget: Lock Screen card plus every Dynamic Island presentation. Registered in `FernletWidgetsBundle` alongside the workout activity. |
| `Fernlet/FernletWidgets/CookingActivityBridge.swift` | The single seam reflecting a `CookingRunState` onto the live activity — shared by the in-app walker and the Lock Screen intents. Delegates its loop to `LiveActivityReflector`. |
| `Fernlet/FernletWidgets/CookingLiveActivityIntents.swift` | `LiveActivityIntent`s for the cooking activity's "Next"/repeat-step buttons and the matching Siri phrases; `CookingIntentRunner` performs them in the app's process and posts the notification `FernletStore` reconciles on. |
| `Fernlet/FernletWidgets/CookingRunState.swift` | A cooking session as a flat value that survives process death in the app group, carrying the full ordered `steps` so a cold-launched intent can render the next step with no live app state. |
| `Fernlet/FernletWidgets/CookingRunStateStore.swift` | Coordinated app-group reader/writer for `CookingRunState.json` — the persistence seam between `FernletStore` and the Lock Screen/Siri intent runner. |

## Share Extension

| File | Purpose |
| --- | --- |
| `Fernlet/FernletShareExtension/ShareViewController.swift` | Share-extension entry `UIViewController` that extracts the shared URL and enqueues it via `SharedRecipeImportQueueWriter`. |
| `Fernlet/FernletShareExtension/SharedRecipeImportQueueWriter.swift` | App-group JSON queue writer that records shared recipe URLs (`SharedRecipeImportRecord`) for the app to import later. A deliberate hand-copied twin of `AppServices/SharedRecipeImportQueue.swift` (the extension links no FernletKit products); field list, coder config, container fallback chain, and `NSFileCoordinator` coordination must stay in sync — enforced by `SharedRecipeImportQueueMirrorTests`. |
| `Fernlet/FernletKit/Sources/AppServices/SharedRecipeImportQueue.swift` | App-group-backed queue of shared recipe-URL import records (`SharedRecipeImportRecord` with attempt/error tracking) handed off from the share extension for later import. |

## Tests

### Unit Tests

| File | Purpose |
| --- | --- |
| `Fernlet/FernletTests/FernletTests.swift` | Core app/domain tests. |
| `Fernlet/FernletTests/FernletPersistenceTests.swift` | Persistence behavior tests. |
| `Fernlet/FernletTests/FernletLockTests.swift` | Lock-related integration or behavior tests. |
| `Fernlet/FernletTests/FernletLockCryptoTests.swift` | Lock crypto tests: `FernletLockCrypto`'s scrypt passcode derivation, content-key wrapping, and verifier digest, plus the column-key HKDF derivation — which now lives in `ColumnCrypto` (FernletCrypto), characterized here via `@testable import FernletCrypto` including a pinned known-answer vector. |
| `Fernlet/FernletTests/FernletLockServiceTests.swift` | Lock service tests plus local fake providers and harnesses. |
| `Fernlet/FernletTests/ColumnCryptoDeviceBindingTests.swift` | Pins the device-bound sealed-column v2 format: round trip, legacy-blob compatibility (incl. the version-byte nonce collision), cross-install refusal, re-seal rebinding, and fail-open sealing. |
| `Fernlet/FernletTests/SecureEnclaveWrapTests.swift` | Secure-Enclave content-key wrap tests: round trip, key-death on delete, lock-service maintain/repair without ever blocking unlock, reset removing the enclave key; both SE-present and SE-absent branches. |
| `Fernlet/FernletTests/KeyCustodyBoundaryTests.swift` | Key-custody tripwire: reads real keychain rows' accessibility/synchronizable attributes back per store, plus grep-walls confining `synchronizable: true` and bare non-ThisDeviceOnly accessibility classes to the two sanctioned files. |
| `Fernlet/FernletTests/SealedBackupFormatPinTests.swift` | Pins the sealed-backup at-rest format end-to-end: escrow HKDF known-answer via a planted key, the AAD v2 byte layout opened independently, and the restore-needs-only-the-escrow-key guard. |
| `Fernlet/FernletTests/FernletTestHelpers.swift` | Shared test helper utilities. |
| `Fernlet/FernletTests/ActivityTypeCatalogTests.swift` | Activity type taxonomy, search, and HealthKit mapping tests. |
| `Fernlet/FernletTests/MoveRefactorTests.swift` | Move refactor taxonomy tests for workout modes, muscle groups, body regions, and equipment. |
| `Fernlet/FernletTests/HealthKitWorkoutTests.swift` | HealthKit workout logging configuration, duration default, and metadata helper tests. |
| `Fernlet/FernletTests/HealthKitDisableTests.swift` | Tests for disabling individual HealthKit capabilities via `StoragePreferences`. |
| `Fernlet/FernletTests/NutritionLabelScannerTests.swift` | Nutrition label scanner tests. |
| `Fernlet/FernletTests/PeriodTrackerTests.swift` | Period tracker domain tests. |
| `Fernlet/FernletTests/CyclePredictionEngineTests.swift` | Cycle prediction accuracy, edge cases, and confidence scoring tests. |
| `Fernlet/FernletTests/CloudKitDataServiceTests.swift` | CloudKit data service and existing-data detection tests. |
| `Fernlet/FernletTests/StoragePreferencesTests.swift` | Storage preferences model encoding, defaults, and mutation tests. |
| `Fernlet/FernletTests/StoragePrivacyIntegrationTests.swift` | Integration tests for storage preference changes propagating through the app. |
| `Fernlet/FernletTests/IdentityServiceTests.swift` | Ed25519/X25519 identity provisioning, signing, and key-agreement tests. |
| `Fernlet/FernletTests/FernletIdentityEnvelopeTests.swift` | Envelope signing, verification, canonical encoding, and payload type tests. |
| `Fernlet/FernletTests/MultipeerPeerTests.swift` | Extracted MultipeerConnectivity peer-ID persistence tests. |
| `Fernlet/FernletTests/NearbyRangingSessionTests.swift` | NearbyInteraction ranging session state machine and distance update tests. |
| `Fernlet/FernletTests/ConnectionInspectorTests.swift` | Connection inspector session recording, subsampling, and purge-old logic tests. |
| `Fernlet/FernletTests/ProximityCoordinatorTests.swift` | Proximity coordinator handshake, payload dispatch, and error recovery tests. |
| `Fernlet/FernletTests/TrainerProximityServiceTests.swift` | Trainer proximity service disclosure card and audit event tests. |
| `Fernlet/FernletTests/FriendPhotoManifestPayloadTests.swift` | Friend-photo manifest payload round-trip and blocked-sender request filtering tests. |
| `Fernlet/FernletTests/RecipeShareCodecTests.swift` | Recipe share codec encoding and round-trip tests. |
| `Fernlet/FernletTests/FernletSnapshotRoundTripTests.swift` | Snapshot serialization round-trip integrity tests. |
| `Fernlet/FernletTests/ProximityTrustVaultTests.swift` | ProximityTrustVault trust/revoke idempotency, audit ring-buffer cap, onChange callback, and apply atomicity tests. |
| `Fernlet/FernletTests/AIRetryQueueServiceTests.swift` | AIRetryQueueService queue, clear, apply, reset, and onChange callback tests. |
| `Fernlet/FernletTests/DerivedSignalsServiceTests.swift` | DerivedSignalsService rebuild accuracy and deferred-rebuild single-run guard tests. |
| `Fernlet/FernletTests/DerivedSignalsRebuilderTests.swift` | Derived signals rebuilder accuracy and day-window boundary tests. |
| `Fernlet/FernletTests/MeshNetworkManagerTests.swift` | Mesh network manager discovery visibility, session open/closed transitions, slot allocation, peer admission, lifecycle, session-photo retention, and film-quota tests (10-shot limit, `filmRemaining`, `leaveSession` reset). |
| `Fernlet/FernletTests/DisposableCameraControllerTests.swift` | Pure state-machine unit tests for `CameraCaptureController`: initial armed state, disarm, wind progress, arm-on-full-wind, re-arm cycle, and no-op guards. |
| `Fernlet/FernletTests/MealBuilderTests.swift` | Meal builder food plan to meal/recipe conversion tests. |
| `Fernlet/FernletTests/SavedRecipeServiceTests.swift` | Saved recipe service load, add, delete, and persistence tests. |
| `Fernlet/FernletTests/SnapshotSaveCoordinatorTests.swift` | Snapshot save coordinator debounce and remote-reload tests. |
| `Fernlet/FernletTests/WorkoutHealthKitSyncTests.swift` | HealthKit workout import and upsert logic tests. |
| `Fernlet/FernletTests/FoodCatalogTests.swift` | SQLite food catalog round-trip/hydration, search parity with the in-memory scorer, user-item merging, and the gated `FoodCatalog.sqlite` regeneration test. |
| `Fernlet/FernletTests/CustomIngredientUpsertTests.swift` | Custom ingredient resolution and food item creation tests. |
| `Fernlet/FernletTests/AIContextPayloadTests.swift` | AI context payload de-identification: forbidden and allowlisted field tests. |
| `Fernlet/FernletTests/ActivityTests.swift` | Proximity group-activity token/snapshot crypto and join-token verification tests. |
| `Fernlet/FernletTests/AppIntentsTests.swift` | App Intents pending-sheet deep-link round-trip, consume-once, and expiry-window tests. |
| `Fernlet/FernletTests/BarcodeScanTests.swift` | Barcode scan GTIN normalization, schema-tolerance, and resolution-cascade tests. |
| `Fernlet/FernletTests/BrandedODRCatalogTests.swift` | Branded On-Demand-Resource food catalog attach, resolve, and detach-fallback integration tests. |
| `Fernlet/FernletTests/ClosenessTests.swift` | Friend closeness day-point weighting and closeness-formula tests. |
| `Fernlet/FernletTests/ClothingShareCodecTests.swift` | Clothing-share codec catalog-building and untrusted-catalog sanitization tests. |
| `Fernlet/FernletTests/CoinEconomyTests.swift` | Coin-economy ledger aggregation, idempotent earn/spend, and store-wiring tests. |
| `Fernlet/FernletTests/CommitResolutionPersistenceTests.swift` | Regression test for meal-resolution recipe creation persisting without accompanying meals. |
| `Fernlet/FernletTests/CreationStudioEditorTests.swift` | Creation Studio item-editor texture reprojection and dimension round-trip tests. |
| `Fernlet/FernletTests/CustomItemModelTests.swift` | Custom clothing-item texture helpers, Codable round-trip, and CRUD persistence tests. |
| `Fernlet/FernletTests/CyclePhaseResolverTests.swift` | Cycle-phase resolver tests deriving phase from entries, predictions, and calendar math. |
| `Fernlet/FernletTests/DataExportTests.swift` | Data-export shape round-trip and sensitive-vocabulary exclusion tests. |
| `Fernlet/FernletTests/DayDecodeCompatTests.swift` | Forward-compatibility tests for unknown enum tokens in day-resident fields. |
| `Fernlet/FernletTests/DayHistoryUncappedTests.swift` | Day-history uncapped per-row storage and read-cache invalidation tests. |
| `Fernlet/FernletTests/DayRecordRepositoryTests.swift` | DayRecordRepository upsert/load round-trip and non-destructive-upsert tests. |
| `Fernlet/FernletTests/DayRowMigrationTests.swift` | Day-row migration tests moving legacy blob days into the per-row store. |
| `Fernlet/FernletTests/DeleteAllDataTests.swift` | "Delete all data" reset tests verifying day history and inbox are fully purged. |
| `Fernlet/FernletTests/DestructiveConfirmationTests.swift` | Destructive-action confirmation tests verifying mutation is deferred until confirm. |
| `Fernlet/FernletTests/EquipmentIconTests.swift` | Equipment/location SVG icon markup parsing and path-bounds sanity tests. |
| `Fernlet/FernletTests/FernletFontRegistrationTests.swift` | Bundled font registration and text-role-to-font resolution tests. |
| `Fernlet/FernletTests/FoodProductWebImportTests.swift` | Food-product web-import structured-data (schema.org) nutrition extraction tests. |
| `Fernlet/FernletTests/FoodSearchLabelAndFallbackTests.swift` | Food-search data-source labeling and micronutrient-fallback tests. |
| `Fernlet/FernletTests/FriendMintingTests.swift` | One-sided friend-minting session-roster, review-batch, and vouch-list-gate tests. |
| `Fernlet/FernletTests/FriendShopTests.swift` | In-person friend-shop buy-flow, listing-cap, and ephemeral-catalog tests. |
| `Fernlet/FernletTests/FriendStateTests.swift` | Friend companion-state fuzzy-fold and constant-length wire-payload contract tests. |
| `Fernlet/FernletTests/GentleOffersTests.swift` | Gentle-intervention offer-engine gating/rotation, weather-comfort, and HealthKit write-gating tests. |
| `Fernlet/FernletTests/GoalSelectionPersistenceTests.swift` | Goal-selection persistence regression test (`setSelectedGoal` schedules a save and survives reload). |
| `Fernlet/FernletTests/GuidedWorkoutRunStoreTests.swift` | Guided-workout-run store approval-gate, start/finish/log, and Live-Activity mirroring tests. |
| `Fernlet/FernletTests/HealthKitCacheCleanerTests.swift` | HealthKit cache-cleaner opt-out purge tests preserving user-authored sleep entries. |
| `Fernlet/FernletTests/HealthKitScoringTests.swift` | HealthKit-aware scoring-engine tests verifying backward-compatible score computation. |
| `Fernlet/FernletTests/HeartShareTests.swift` | Presence-layer heart-share codec, trust-gate, rate-limit, and glow-decay tests. |
| `Fernlet/FernletTests/IdentityServiceEscrowTests.swift` | Identity-service backup-escrow-key provisioning-race and conflict-reconciliation tests. |
| `Fernlet/FernletTests/IslandViewfinderMetricsTests.swift` | Dynamic Island viewfinder geometry and device-classification tests. |
| `Fernlet/FernletTests/ItemNameModerationTests.swift` | Clothing-listing item-name moderation and sanitization tests. |
| `Fernlet/FernletTests/JournalNarrativeRepositoryTests.swift` | Sealed journal-narrative repository insert/fetch encryption round-trip tests. |
| `Fernlet/FernletTests/JournalQuickMoodTests.swift` | Quick-mood tag-only journal-entry and prompt-rotation tests. |
| `Fernlet/FernletTests/KnownDesignerNamesBoundTests.swift` | Known-designer-names map cardinality-bound regression test against hostile peer cycling. |
| `Fernlet/FernletTests/LogRecordsDecodeCompatTests.swift` | Forward-compatibility tests for derived log-record unknown-enum decoding. |
| `Fernlet/FernletTests/MacroRingProgressTests.swift` | Macro-ring progress NaN/Infinity guard tests for zero or degenerate goals. |
| `Fernlet/FernletTests/MealPhotoRecognitionTests.swift` | Meal-photo recognition taxonomy-filtering and resolveMeals-pipeline tests. |
| `Fernlet/FernletTests/MealPhotoStoreTests.swift` | Meal-photo store at-rest encryption, downscaling, and fail-closed-without-key tests. |
| `Fernlet/FernletTests/MemoryStorageScreeningTests.swift` | Memory-storage diagnostic-language screening classifier (storage-time gate) tests. |
| `Fernlet/FernletTests/MeshClothingShopTests.swift` | Mesh friend-clothing-shop catalog lifecycle, exchange, and hostile-input guard tests. |
| `Fernlet/FernletTests/MeshEncryptionTests.swift` | Mesh group symmetric-encryption (group key) unit tests. |
| `Fernlet/FernletTests/MeshTransportErrorSurfacingTests.swift` | Mesh transport didNotStart-error surfacing callback tests. |
| `Fernlet/FernletTests/MilestoneLedgerTests.swift` | Milestone-ledger aggregation, exactly-once coin-award, and reset-survival tests. |
| `Fernlet/FernletTests/ModerationBanTests.swift` | Moderation self-ban store default-state and reinstall-persistence tests. |
| `Fernlet/FernletTests/ModerationTests.swift` | Moderation content-hash stability and local report-ledger idempotency tests. |
| `Fernlet/FernletTests/MultiDeviceSyncWarningTests.swift` | Multi-device sync-warning classification tests across iCloud/sync-state combinations. |
| `Fernlet/FernletTests/NutritionTargetOverrideTests.swift` | Nutrition-target-override derivation and settings round-trip tests. |
| `Fernlet/FernletTests/PastDayJournalScrubMigrationTests.swift` | Past-day journal scrub-migration retry regression test for failed sealing passes. |
| `Fernlet/FernletTests/PastDayJournalSealingTests.swift` | Past-day journal sealing tests ensuring no plaintext leaks into the synced blob. |
| `Fernlet/FernletTests/PeriodAwareScoringTests.swift` | Period-aware scoring adjustment and backward-compatibility tests. |
| `Fernlet/FernletTests/PeriodContextBridgeTests.swift` | Period-context bridge phase-signal derivation and 3-cycle-gate tests. |
| `Fernlet/FernletTests/PeriodPhaseTrendEngineTests.swift` | Period phase-trend correlation-engine minimum-cycle-gate and trend-detection tests. |
| `Fernlet/FernletTests/PeriodPredictionUITests.swift` | Period-prediction UI visibility-gating (`hidePredictions` setting) tests. |
| `Fernlet/FernletTests/PeriodTestSupport.swift` | Shared deterministic fixtures and scoring-context stub used by the period-aware test suites. |
| `Fernlet/FernletTests/PetInteractionGovernorTests.swift` | Pet-interaction time-lock governor and ambience pure-function tests. |
| `Fernlet/FernletTests/PhotowallPhotoSelectorTests.swift` | Photowall photo-selector next-launch dedup and ranking-strategy tests. |
| `Fernlet/FernletTests/PresenceHeartsTests.swift` | Presence-layer heart reachability, invitation-gate, and opt-out tests. |
| `Fernlet/FernletTests/PresenceManagerTests.swift` | Presence-manager radio state-machine roster, advertise-cap, and epoch-rotation tests. |
| `Fernlet/FernletTests/PresenceTagTests.swift` | Presence-tag Diffie-Hellman primitive mutual-derivation and epoch-rotation tests. |
| `Fernlet/FernletTests/PrivateEncryptedRepositoryRecoveryTests.swift` | Private encrypted-repository recovery tests skipping rows keyed by a destroyed key. |
| `Fernlet/FernletTests/PrivateHistoryPruningTests.swift` | Private-history deletion/pruning tests verifying no residual record remains. |
| `Fernlet/FernletTests/PrivateMediaStoreTests.swift` | Private media-store (mesh photo cache) decompression-bomb defense and at-rest encryption tests. |
| `Fernlet/FernletTests/ProgressPhotoStoreTests.swift` | Progress-photo store at-rest encryption and fail-closed-without-key tests. |
| `Fernlet/FernletTests/ProximityRecipeShareCapTests.swift` | Proximity recipe-share two-device cap and radio pause/resume lifecycle tests. |
| `Fernlet/FernletTests/ProximityRecipeShareDiagnosticsTests.swift` | Proximity recipe-share diagnostics capped ring-buffer append/ordering tests. |
| `Fernlet/FernletTests/ProximityRecordDecodeCompatTests.swift` | Forward-compatibility tests for persisted proximity records (trust vault, audit, session logs). |
| `Fernlet/FernletTests/ProximityWireOffMainDecodeTests.swift` | Proximity wire-type Sendable conformance and off-main decode/signature-verification tests. |
| `Fernlet/FernletTests/RecentBitesTests.swift` | Home "Recent bites" 7-day photographed-meal window tests. |
| `Fernlet/FernletTests/RecipeWebImporterTests.swift` | Recipe web-importer SSRF/URL-safety allow- and block-list tests (including encoded IP-literal spellings), page-image extraction/normalization, and the image-download MIME/sniff/size guards. |
| `Fernlet/FernletTests/RecipeWebImageTests.swift` | Recipe web-image feature tests: tolerant `RecipeWebImport` decode, the per-device attempt + synced suppression gates (cancellation, photo-wins, deletion), mesh receive neutralization and the already-saved keep decision, and wire image compatibility/strips. |
| `Fernlet/FernletTests/RecipeSourceURLTests.swift` | `RecipeSourceURLMatcher` normalization table plus re-import contract tests (live-row merge, deleted-row nil, attempt re-arm, drain duplicate skip). |
| `Fernlet/FernletTests/ReplayCacheTests.swift` | Replay-cache oldest-eviction and envelope-replay-detection tests. |
| `Fernlet/FernletTests/SharedRecipeImportQueueMirrorTests.swift` | Drift guard for the share extension's hand-copied `SharedRecipeImportRecord` mirror: parses both source files and requires identical field lists (the `budgetDeferredDayKey` stripping regression), plus wire-format round-trip, `NSFileCoordinator` coordination, and container-fallback-order parity. |
| `Fernlet/FernletTests/CoreDataStagedBlobLoadTests.swift` | Parity coverage for `CoreDataFernletRepository`'s two aggregate-blob entry points: async/sync agreement, first-launch legacy migration, and read-only-recovery latching on fetch failure and corrupt payload via `loadSnapshotAsync`. |
| `Fernlet/FernletTests/JournalAppendPathTests.swift` | Pins the single journal-append path (`addJournal` overloads + `logQuickMood`): today updates day/`previousJournals`/memories, a back-dated entry touches none of the today-scoped state but persists and hydrates on its own day. |
| `Fernlet/FernletTests/NoTrackingBoundaryTests.swift` | No-tracking wall: banned advertising/analytics SDKs and symbols across every target, exact SPM dependency + hardcoded-destination allowlists, pinned HTTP-client files, and PrivacyInfo.xcprivacy/entitlements assertions. See [No-Tracking-Wall.md](No-Tracking-Wall.md). |
| `Fernlet/FernletTests/S3BoundaryTests.swift` | S3 privacy-wall grep-based backstop tests scanning AI-facing sources for sealed-store access. |
| `Fernlet/FernletTests/SavedRecipeMigrationTests.swift` | Legacy SavedRecipe-to-RecipeDefinition migration round-trip tests. |
| `Fernlet/FernletTests/SealedBackupChunkTests.swift` | Sealed-backup chunked-export paging and multi-chunk restore-writeback tests. |
| `Fernlet/FernletTests/SealedBackupRestoreOutcomeTests.swift` | Sealed-backup restore-outcome classification and status-recording tests. |
| `Fernlet/FernletTests/SealedBackupRestoreTests.swift` | Sealed-backup restore-into-stores tests (empty-store guard, Tier-2 writeback, locked-key path). |
| `Fernlet/FernletTests/SealedBackupTests.swift` | Sealed-backup crypto round-trip and escrow-key provisioning tests. |
| `Fernlet/FernletTests/SealedIntroductionTests.swift` | Sealed-introduction mesh handshake tests guarding against unsealed identity leakage. |
| `Fernlet/FernletTests/SealedStoreConfigTests.swift` | Sealed-store/CloudKit-model isolation tests keeping sensitive entities out of the synced model. |
| `Fernlet/FernletTests/AgeAssuranceTests.swift` | Age-gate tests: the pure record rules, the device-local store's persistence and fail-closed decode, and the wiring into the intimacy visibility gate, the mesh chat seams, and `resetAll`. |
| `Fernlet/FernletTests/SensitiveSurfaceGateTests.swift` | Sensitive-surface (period/intimacy) hard hide-gate visibility tests. |
| `Fernlet/FernletTests/SessionMessageTests.swift` | Live-session ephemeral message codec, dispatch-gate, and transcript-clearing tests. |
| `Fernlet/FernletTests/SettingsDecodeCompatTests.swift` | Forward-compatibility tests for unknown enum tokens in synced `FernletSettings` fields. |
| `Fernlet/FernletTests/SnapshotModelsDecodeCompatTests.swift` | Forward-compatibility tests for unknown enum tokens across remaining synced-blob model types. |
| `Fernlet/FernletTests/StressEngineTests.swift` | Stress-engine HRV z-score classification and scoring-modifier tests. |
| `Fernlet/FernletTests/TabBarCompactionTests.swift` | Tab-bar compaction hysteresis decision-logic tests. |
| `Fernlet/FernletTests/TrainerExportTests.swift` | Trainer/nutritionist export bundle fail-closed category-exclusion tests. |
| `Fernlet/FernletTests/WidgetBridgeTests.swift` | Widget-bridge snapshot mirroring and pending-action-queue codec tests. |
| `Fernlet/FernletTests/WorkoutProgramTests.swift` | Workout-program location identity-stability and template-ID collision tests. |
| `Fernlet/FernletTests/WorkoutRecoveryTests.swift` | Logged-workout removal/edit recoverability and bookkeeping-reversal tests. |
| `Fernlet/FernletTests/WorryBoxTests.swift` | Worry Box sealed repository round-trip, deletion, and key-migration tests. |
| `Fernlet/FernletTests/FernletModelRouterTests.swift` | Router resolution: capability caps, tier escalation ladders, and fallback-reason classification. |
| `Fernlet/FernletTests/FernletAIGateTests.swift` | Gate dispatch: the single quota-charge point, user intent, and route resolution. |
| `Fernlet/FernletTests/AICallQuotaTests.swift` | Daily AI-call budget: day-key rollover and the derived `.sleepy`/`.resting` states. |
| `Fernlet/FernletTests/AIAuditLogTests.swift` | AI audit entries: `modelIdentifier`/outcome fields and device-local persistence. |
| `Fernlet/FernletTests/HeartDropTests.swift` | Heart-drop core: sealing, prekey selection and consumption, tag rotation, outbox and dedup behavior. |
| `Fernlet/FernletTests/HeartDropAppWiringTests.swift` | App-side heart-drop wiring: opt-in gating, delivery paths, and wipe coverage. |
| `Fernlet/FernletTests/ProtectedSidecarTests.swift` | The sidecar state machine: absent/deferred/corrupt/loaded classification and the fail-closed persist policy. |
| `Fernlet/FernletTests/SealedPayloadFramingTests.swift` | wire2 compress+pad framing round-trips and capability gating. |
| `Fernlet/FernletTests/ProximityVerificationTests.swift` | QR ceremony: nonce binding, sign-after-check ordering, and wrong-peer drops that must not clear state. |
| `Fernlet/FernletTests/CoachSessionHardeningTests.swift` | Coach-path hardening as an executable contract: the role split, coach-vs-friend trust policy, the freeze-default `.trainer` guard, and the pre-decrypt wire-size gate. |
| `Fernlet/FernletTests/SealedBackupRollbackTests.swift` | Rollback defense: AAD binding (editing `generation`/`updatedAt` breaks authentication, sub-second timestamps still open) and the high-water mark (monotonic minting, per-payload independence, forward-only accept, wipe reset, and the authentic-older-generation rejection). |
| `Fernlet/FernletTests/PrivacyWipeCoverageTests.swift` | The enforced delete-all coverage checklist — identity and sidecar keys must die with the wipe. See [PrivacyWipeCoverage.md](PrivacyWipeCoverage.md). |
| `Fernlet/FernletTests/GroceryAggregationTests.swift` | Pure aggregation engine: unit merging, duplicate collapse, and unresolvable-line passthrough. |
| `Fernlet/FernletTests/GroceryListComposerTests.swift` | App-side composition: catalog resolution, "cook for N" scaling, and web-import line unification. |
| `Fernlet/FernletTests/RecipeScalingTests.swift` | Proportional scaling arithmetic and the non-persistence guarantee. |
| `Fernlet/FernletTests/IngredientSubstitutionTests.swift` | Substitution: candidate-number binding, gram-equivalence quantities, and fork-only-on-save. |
| `Fernlet/FernletTests/RecipeStepsTests.swift` | `RecipeStep` schema, web-import step preservation, and mesh wire compatibility. |
| `Fernlet/FernletTests/CookingRunStateTests.swift` | Cooking run value semantics: step numbering, last-step detection, and advance/finish. |
| `Fernlet/FernletTests/CookingRunStoreTests.swift` | App-group cooking-run persistence, including the injectable directory seam. |
| `Fernlet/FernletTests/SavedRecipePayloadMigrationTests.swift` | The `SavedRecipeRecord` typed-column → payload-blob migration that unblocked F3/F4/F5. |
| `Fernlet/FernletTests/MealDecompositionRecipeWireTests.swift` | Meal-decomposition recipe payloads over the wire. |
| `Fernlet/FernletTests/FDADailyValuesTests.swift` | Daily Value table values and their single-source coupling to the gap analyzer. |
| `Fernlet/FernletTests/NutrientSuggestionTests.swift` | The gap-filling nutrient nudge: curated-source binding and suppression rules. |
| `Fernlet/FernletTests/BarcodeServingStepTests.swift` | Serving-step prefill memory keyed by normalized GTIN, and its wipe. |
| `Fernlet/FernletTests/CloudKitSchemaDeployTests.swift` | Purity of the schema-deploy launch-flag parse. |
| `Fernlet/FernletTests/SettingsSearchIndexTests.swift` | Asserts every `SettingsRoute` case has at least one search entry and a destination. |
| `Fernlet/FernletTests/AdaptiveColorIsolationTests.swift` | Theme-token resolution isolation across trait changes. |
| `Fernlet/FernletTests/DisposableCameraOrientationTests.swift` | Camera landscape/rotation and Dynamic-Island-merge geometry. |
| `Fernlet/FernletTests/MeshSessionHeartTests.swift` | In-session hearts delivered over the mesh. |
| `Fernlet/FernletTests/SessionMessageUnreadTests.swift` | Mesh session message unread signalling. |
| `Fernlet/FernletTests/MeshFavoriteObservationTests.swift` | Favorite-peer observation and its effect on home weighting. |
| `Fernlet/FernletTests/WeightedPhotowallOrderingTests.swift` | Weighted photo-wall ordering. |

### Test Mocks

| File | Purpose |
| --- | --- |
| `Fernlet/FernletTests/Mocks/MockMultipeerTransport.swift` | In-memory mock for MultipeerConnectivity transport used in proximity unit tests. |
| `Fernlet/FernletTests/Mocks/MockRangingProvider.swift` | Controllable mock for NearbyInteraction ranging used in coordinator and session tests. |

### UI Tests

| File | Purpose |
| --- | --- |
| `Fernlet/FernletUITests/FernletUITests.swift` | UI automation tests for core app workflows. |
| `Fernlet/FernletUITests/FernletUITestsLaunchTests.swift` | UI launch and performance tests. |
| `Fernlet/FernletUITests/OnboardingFlowUITests.swift` | End-to-end UI tests for the onboarding flow. |
| `Fernlet/FernletUITests/PrivacyDataSettingsUITests.swift` | UI tests for the privacy and data settings screen. |
| `Fernlet/FernletUITests/StoragePrivacyUITests.swift` | UI tests for storage and privacy preference flows. |
| `Fernlet/FernletUITests/MeshNetworkUITests.swift` | Legacy mesh-lobby UI automation suite. Currently skipped pending replacement with coverage for the active Friends-session disposable-camera flow. |
| `Fernlet/FernletUITests/UXScreenProbe.swift` | Test harness (`UXTestApp` launcher + chainable `UXScreenProbe` geometry assertions/screenshot capture) backing the appearance UI-test suites. |
| `Fernlet/FernletUITests/ScreenAppearanceUITests.swift` | Visual/layout regression suite screenshotting every primary tab, private hub, and logging sheet, asserting nothing is clipped or blank. |
| `Fernlet/FernletUITests/OnboardingAppearanceUITests.swift` | Walks the 8-screen onboarding flow, screenshotting each screen and asserting its title and primary action button render on-screen. |
| `Fernlet/FernletUITests/SettingsAppearanceUITests.swift` | Walks each Settings sub-screen (pushed destination), screenshotting and asserting its nav bar renders on-screen. |
| `Fernlet/FernletUITests/HomeCardsRedesignUITests.swift` | UI test guarding the redesigned First Aid and Milestones home cards render and open their destinations. |
| `Fernlet/FernletUITests/GoalPresetCardsUITests.swift` | UI test for the Goal & Nutrition preset cards: renders and verifies tapping a card updates the selection. |
| `Fernlet/FernletUITests/NutritionTargetsEditorUITests.swift` | End-to-end UI test of the Settings nutrition targets editor, covering residual rebalancing and the fat placeholder tracking calorie overrides. |
| `Fernlet/FernletUITests/RecentBitesUITests.swift` | UI test verifying the Home "Recent bites" polaroid strip of photographed meals renders. |
| `Fernlet/FernletUITests/RecipeDetailUITests.swift` | UI test for the read-only recipe detail view, opened from both the recipe book and the Food page's Recipes section. |
| `Fernlet/FernletUITests/ProgressPhotoUITests.swift` | UI test for the Move tab's progress-photo timeline: strip renders and its detail view (caption + delete) is reachable. |
| `Fernlet/FernletUITests/WorkoutLocationUITests.swift` | UI test for gym-location delete/rename, asserting a deletion persists after closing and reopening the sheet. |
| `Fernlet/FernletUITests/ItemCreationFlowUITests.swift` | UI test for the split item-creation flow: the drawing-only editor leading to a separate naming/shop-listing confirmation step. |
| `Fernlet/FernletUITests/DeleteAllDataUITests.swift` | End-to-end UI test proving "Delete everything" empties the app and stays deleted across a relaunch. |
| `Fernlet/FernletUITests/DeleteAllDialogAppearanceUITests.swift` | Screenshots the "Delete everything?" confirm dialog and logs its rendered copy/buttons for review. |
| `Fernlet/FernletUITests/TrainerExportShareUITests.swift` | Trainer-summary share flow, including the delete-on-share-completion path. |

## Documentation

DocC landing pages (one per SPM module, plus the app and extension targets) are the orientation
layer and live in-source at `Documentation.docc/`; the tables below are the planning-doc layer.

### Active

| File | Purpose |
| --- | --- |
| `Docs/FernletSpecificationV3.md` | Canonical product & architecture specification — the source of truth for intended behavior. |
| `Docs/ImplementationPlan.md` | Phase definitions and rationale, with a reconciled phase-status table and the current "Next up" ordering at the end. |
| `Docs/RemainingWork-2026-07-19.md` | The live work tracker: App Store items, user-visible defects, the owner-decided implementation queue, unstarted feature work, tech debt, and the real-device verification queue. |
| `Docs/FernletCoach-Specification-2026-07-19.md` | The Fernlet Coach track (P0→P4), both apps. **§3.3/§3.6/§6/§8 need revising** — they still describe the iMessage+CloudKit hybrid as primary, reversed by the owner on 2026-07-26. |
| `Docs/Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md` | Sidecar durability, signed prekey, and the coach path. Tracks A and B shipped; Track C stopped at Increment 10's hardening subset — the coach session manager/UI is the outstanding work. |
| `Docs/Data-Provenance-Coach-Trust-2026-07-12.md` | The coach trust model the coach spec builds on: origin class, trust basis, and per-source revocation. |
| `Docs/D11-LinkMetadata-Prototype.md` | Harness for the coach P0 `LPLinkMetadata` device test. |
| `Docs/AI-Provider-Ladder-2026-07-23.md` | The routed provider ladder. Provider seam shipped; the cloud/PCC, BYOK, and iOS-27 tracks remain gated. |
| `Docs/AI-Feature-Expansion-2026-07-23.md` | Seven features riding the ladder, and the canonical build order for both AI docs. F3/F4/F5 shipped; F6/F7 deferred by decision D-C. |
| `Docs/SPM-Module-Carveup-Plan.md` | The `FernletKit` carve-up: the S3 compile-time privacy wall and cross-platform layering. One optional item remains (§14 AI-file inversions). |
| `Docs/Doc-Pass-Anomalies-2026-08-04.md` | Bugs, dead code, and smells logged during the DocC pass. **Never triaged** — several entries are real defects, not smells. |
| `Docs/Meal-Estimation-Overhaul-Plan.md` | Meal-estimation overhaul. Partially shipped; the chain-restaurant importer and dynamic product-image discovery were not re-audited item-by-item. |
| `Docs/Multi-Device-Without-iCloud-Design-2026-06-29.md` | Multi-device without iCloud. Phase 1 shipped; Phases 2–3 (owned-device pairing, mesh backup transfer, offline escrow, live merge) unstarted. |
| `Docs/Custom-Clothing-Plan-2026-06-29.md` | Custom clothing: Increment 1 shipped (grid editor / wardrobe); Increments 2 (coins) and 3 (in-person friend shop) pending. |
| `Docs/Localization-Plan-2026-07-19.md` | es/fr/de localization. Nothing implemented; Phase 0 fixes are live locale bugs even in English. |
| `Docs/Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md` | Sealed-backup escrow follow-ups, including BIP39 recovery codes. Not started. |
| `Docs/Privacy-Policy.md` | The published privacy policy text, mirrored by the in-app view. |
| `Docs/App-Privacy-Nutrition-Labels.md` | Draft answers for the App Store Connect App Privacy questionnaire (owner-entered). |
| `Docs/No-Tracking-Wall.md` | The enforced no-tracking boundary: permitted network destinations and why each exists, mechanical vs. policy enforcement, and how to add a destination. Backed by `NoTrackingBoundaryTests`. |
| `Docs/PrivacyWipeCoverage.md` | The enforced delete-all coverage checklist, backed by `PrivacyWipeCoverageTests`. |
| `Docs/CloudKit-Schema-Deploy.md` | Runbook for pushing the Core Data model to CloudKit's server-side schema — a manual, developer-run ritual. |
| `Docs/Friend-Shop-Real-Device-Validation.md` | Two-device validation script for the in-person friend shop. |
| `Docs/Recipe-P2P-Real-Device-Validation.md` | Two-device validation script for recipe sharing. |
| `Docs/FileIndex.md` | This file index. |
| `Docs/ProximityFunctionIndex.md` | Function-level map for proximity, mesh, transport, identity, trust, audit, friend-photo, and recipe-share code. Read before adding proximity behavior. |
| `Docs/StoreRepositoryFunctionIndex.md` | Function-level map for `FernletStore`, repositories, persistence, storage preferences, snapshot saves, and the extracted store services. Read before adding data-mutation or save/load behavior. |
| `Docs/design-refs/*.html` | Design mockups the shipped UI was ported from (widget, first aid, companion moments, home ambiance, milestones, good vibes, barcode handoff). Cited from `FernletWidgetsBundle.swift`. |

### Completed Implementations

Archived plans, each carrying a closure banner stating what shipped and what (if anything) was
carried to the tracker.

| File | Purpose |
| --- | --- |
| `Docs/Completed Implemtations/Security-Hardening-Plan-2026-06-27.md` | S3-wall security hardening. WI-1 through WI-10 plus WI-Q all shipped, including the two deferred architectural items. |
| `Docs/Completed Implemtations/Canonical-Signing-Encoding-Fix.md` | Cross-platform canonical signing encoder, delivered as WI-6 (`CanonicalSignatureSerializer`, envelope schema v2 with dual verify). |
| `Docs/Completed Implemtations/WI-6-WI-9-session-prompt.md` | Spent handoff prompt for those two items. |
| `Docs/Completed Implemtations/Plan-Bitchat-Adoptions-2026-07-25.md` | wire2 framing, privacy-wipe coverage, offline hearts dead-drop, QR ceremony. Merged 2026-07-26; §E BLE presence still deferred. |
| `Docs/Completed Implemtations/Coin-Ledger-Design-2026-06-29.md` | The append-only coin ledger that replaced the unsound derive-from-day-history model. |
| `Docs/Completed Implemtations/Social-AppStore-Implementation-Plan-2026-07-11.md` | App Store blockers + the friend social layer, all 6 phases. |
| `Docs/Completed Implemtations/Phase6-7-Kickoff-Prompt.md` | Spent kickoff prompt for Phases 6–7 of that plan. |
| `Docs/Completed Implemtations/UI-UX-Review-Prompt-2026-07-09.md` | Spent review prompt for the merged redesign branch. |
| `Docs/Completed Implemtations/UX-Batch-Continuation-2026-07-17.md` | UX batch round 1. |
| `Docs/Completed Implemtations/UX-Batch-Continuation-2026-07-17b.md` | UX batch round 2, including the goal preset cards. |
| `Docs/Completed Implemtations/UX-Batch-Continuation-2026-07-18.md` | UX batch round 3 plus the workout Live Activity. |
| `Docs/Completed Implemtations/Plan-Goal-Presets-And-Workout-LiveActivity-2026-07-17.md` | Goal presets and the guided-workout Live Activity design. |
| `Docs/Completed Implemtations/CODE_REVIEW_2026-06-12.md` | Multi-agent review, triage complete: 195 findings, 185 fixed. The 10 survivors are on the tracker (§9). |
| `Docs/Completed Implemtations/UI-UX-Redesign-Brief-2026-07-08.md` | The parchment redesign brief, delivered via the UX-Batch rounds. Two of its four open questions turned out to be answered by shipped code; two moved to the tracker. |
| `Docs/Completed Implemtations/Design-Briefs-Report-Features-2026-07-05.md` | Paste-ready mockup briefs; 1–11 shipped (outputs in `design-refs/`). Briefs 12–14 are unanswered design asks, now on the tracker. |
| `Docs/Completed Implemtations/Fernlet-Review-and-Plan-Updates.md` | 2026-05-28 architecture review; its SEC findings were fixed by the later hardening work. Superseded as a live document. |
| `Docs/Completed Implemtations/RemainingWork-2026-06-23.md` | The previous work tracker. |
| `Docs/Completed Implemtations/Day-PerRow-Split-Plan-2026-06-29.md` | The per-row `DayRecord` split. |
| `Docs/Completed Implemtations/Proximity-Mesh-Redesign-2026-07-10.md` | Proximity mesh redesign, all 5 phases. |
| `Docs/Completed Implemtations/Proximity-Mesh-Consolidation-Plan.md` | Proximity/mesh consolidation. |
| `Docs/Completed Implemtations/MeshNetworkImplementationPlan.md` | Mesh network and MultipeerConnectivity implementation plan. |
| `Docs/Completed Implemtations/phase7-proximity-implementation-plan.md` | Phase 7 proximity feature implementation plan. |
| `Docs/Completed Implemtations/proximity-handshake-process-map.md` | Process map for the proximity identity handshake flow. |
| `Docs/Completed Implemtations/FernletStore-Refactor-Plan-v2.md` | FernletStore architecture refactor (v2). |
| `Docs/Completed Implemtations/PR0-Incremental-Migration-Plan.md` | PR0 incremental `@Observable` migration plan. |
| `Docs/Completed Implemtations/Life-Tab-Redesign-Implementation-Plan.md` | Life tab (Friends/social) redesign. |
| `Docs/Completed Implemtations/StartupAndBiometricFixPlan.md` | Startup sequence and biometric authentication fixes. |
| `Docs/Completed Implemtations/healthkit-integration-plan.md` | HealthKit integration plan. |
| `Docs/Completed Implemtations/fernlet-period-intimacy-plan.md` | Period and intimacy feature plan. |
| `Docs/Completed Implemtations/PeriodAlgorithimResearch.md` | Research behind period/cycle prediction. |
| `Docs/Completed Implemtations/Workout-Rest-Guidance-Research-2026-07-19.md` | Evidence base behind the shipped `WorkoutRestGuidance` defaults. |
| `Docs/Completed Implemtations/Dead-Code-and-Carryover-Gap-Review.md` | Dead-code review plus the `MeshLobbyView` → `ConnectView` carryover-gap audit. |
| `Docs/Completed Implemtations/codex-implementation-prompts.md` | Codex-style prompts used to guide the Move refactor and trainer integration. |

## Scripts And CI

| Path | Purpose |
| --- | --- |
| `Fernlet/Scripts/spm-wall-check.sh` | S3 wall enforcement: builds with `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` so a forbidden cross-wall `import` fails the build. Run pre-merge and in CI. |
| `Fernlet/Scripts/spm-wall-selftest.sh` | Negative test proving the wall is load-bearing: plants a forbidden `import PrivateHealthStore` in `AIProviders`, asserts the build fails, then reverts. |
| `Fernlet/Scripts/install-git-hooks.sh` | Once per clone: points `core.hooksPath` at the versioned `Scripts/git-hooks` so pushes run the wall check. |
| `Fernlet/Scripts/git-hooks/pre-push` | Versioned pre-push hook running `spm-wall-check.sh` when a push touches wall-relevant files. |
| `Fernlet/Scripts/branded-catalog/` | Python pipeline converting the USDA branded dataset into the curated and On-Demand-Resource SQLite catalogs. |
| `Fernlet/.github/workflows/s3-wall.yml` | CI workflow running the wall enforcement self-test plus the grep-wall on push/PR to `main`. |

## Dependency

| Path | Purpose |
| --- | --- |
| `Fernlet/FernletKit/` | The local Swift package holding the carved-up on-device modules (see the FernletKit Package module map above). |
| CryptoSwift | Remote SPM dependency (`.upToNextMinor` from 1.10.0) supplying the Scrypt KDF used by `FernletLock`; no longer checked into the repo. |

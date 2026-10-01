# ``Fernlet``

The iOS app layer of Fernlet — the composition root that wires the FernletKit modules into a privacy-first, "tamagotchi-of-yourself" health and self-care app.

## Overview

The `Fernlet` app target is deliberately thin on policy and heavy on wiring: almost every domain rule lives in the local `FernletKit` package (`FernletDomainModel`, `FernletScoring`, `DiaryStore`, `StoreCore`, the `Private*` sealed stores, `ProximityKit`, and the walled `AIProviders` / `CloudKitSync` modules, among others), and this target is where all of those modules are composed into a running app. It is the one layer allowed to see both sides of the SPM "S3 wall": the walled AI and iCloud-sync modules must never import the sealed `Private*` stores, so any flow that touches both — a snapshot save, a delete-everything funnel, an AI call over health context — is stitched together here, without ever handing sealed plaintext across the wall.

``FernletApp`` is the `@main` entry point and launch state machine. It owns the app-lifetime singletons a cold launch needs before any view exists — the keychain-backed `FernletLockService`, the `StoragePreferencesStore`, and ``FernletStoreLoader``, which loads the store off the first frame and drives the preparing/ready/failed launch phases. Scene-phase changes relock the app and flush pending saves; storage-preference changes reload persistence and re-apply the sealed store's and the local day blob's backup exclusion. The ready phase also runs the one-shot ``BackupExclusionLaunchGate`` (security-hardening Phase 6): fresh installs — detected as carrying NONE of the three prior-use signals (the device-local ``FernletPriorUseMarker``, legacy onboarding evidence, and the presence of the reinstall-surviving preferences keychain blob) — silently default to backup-excluded, while existing installs with no recorded choice get a one-time honest trade-off alert whose answer is recorded in `StoragePreferences.backupExclusionChoiceMade` and never asked again. The gate classifies over the live keychain blob and defers (retrying on each foreground activation) when the keychain is unreadable, so a prewarmed pre-first-unlock launch can neither re-prompt a decided user nor clobber their real preferences.

``FernletStore`` is the central `@MainActor` `@Observable` facade every screen reads and mutates. The portable diary slice lives in `DiaryStore`; the facade owns everything app-only — per-row ledger services, the proximity subsystem, the coordinators (`SnapshotSaveCoordinator`, ``JournalSealingCoordinator``, ``SealedBackupCoordinator``, ``HealthSyncCoordinator``), the sealed photo stores, and the AI gate/quota/audit plumbing. Mutations persist through a debounced snapshot save against the active `FernletRepository` — Core Data + CloudKit or local JSON, selected by `StoragePreferences`. Sensitive data never enters that snapshot: journal, cycle, and intimacy text is sealed into the encrypted narrative stores, and device-local sidecars (AI quota, hearts, moderation, age assurance, sensitive-surface visibility) deliberately never sync.

``ContentView`` is the post-onboarding root shell: the five-tab container (Home, Food, Move, Friends, Private) — a plain `TabView` with the system bar hidden per page, switched only by taps on the app's own floating bar, deliberately not a horizontal pager, which used to take any drag an inner scroller declined and flip the tab mid-gesture — the single-active-sheet modal router, and the runtime wiring hub that injects the sensitive-surface visibility gates, scoring contexts, delete-everything hooks, widget bridge, and proximity listener lifecycles.

It also mirrors the lock's duress flag (security-hardening Phase 7): `FernletLockService.isDuressSessionActive` is copied into `FernletStore.duressSessionActive` from the launch task, the lock-state observer, and a dedicated observer on the flag itself — the last of these because the duress branches of `changeCredential`/`setBiometricEnabled` fire while the user is already on an unlocked screen, so they never produce a lock-state transition. The store's `isPeriodTrackingVisible` / `isIntimacyTrackingVisible` AND in `!duressSessionActive`, which makes the decoy ride the *existing* hide machinery rather than a per-view `if`: the visibility value flips, the `.onChange` scrub drops resident cycle state and the bridge's derived trends, `PrivateHubSection` hides the sections, and `allowedHealthCapabilities` closes the ambient HealthKit reads (covering `HomeView`'s second `HealthKitService` and the ungated cycle-outlook card). The flag is in-memory only and writes no preference — that is what keeps the decoy fully reversible when the real passcode clears it. `ContentView` is also where `duressPurgeHook` is wired to `deleteAllData(includingHealthKitSamples: true)`, the durable half of the duress wipe.

The store gate covers one corpus the keyless decoy cannot hide by itself: **progress photos**. Body photos are sealed under `PrivateMediaStore`'s own key rather than the lock's content key, and a duress unlock entered on the photo strip's own gate satisfies `.progressPhotos` like any other — so `FernletStore.progressPhotoRecords()` and `progressPhotoData(for:)` AND in `!duressSessionActive` at the READ seam, where every surface goes through, and the mutating helpers go inert so a decoy still destroys nothing. `ContentView` also wires `FernletStore.identityRotatedHook` (and runs the same reconcile at launch) to `DuressRecoveryCoordinator.reconcileEnrollmentWithLocalIdentity()`: "Delete everything" regenerates this device's proximity identity while deliberately keeping the app lock, and the duress recovery blob is sealed with the OLD identity key mixed into its derivation, so an unreconciled phone would keep `DuressMode.recoveryLock` armed over a blob nobody can open.

``DuressRecoveryCoordinator`` is the app-side half of the third duress response, `DuressMode.recoveryLock` — the one that destroys this phone's unlock keys but keeps the sealed corpus, recoverable in person from the user's own second device. It lives here rather than in `FernletLock` because it needs BOTH sides of a wall: the lock owns the recovery blob and the re-establish entry point, while the ceremony needs ProximityKit's signed `fernlet://verify` QR and `IdentityService`'s X25519 seal/open — and `FernletLock` must gain no ProximityKit dependency edge. The app target already imports both, so the two halves meet through a closure: the lock releases the content key into `IdentityService.seal(_:to:format:)` and persists what comes back, never handing the key across a return. One type plays both roles (any install can be somebody's custodian): the custodian DISPLAYS a QR and answers sealed challenges, and the primary SCANS, because the scanner is the side with something to lose — at enrollment it is about to seal its content key to the scanned device, and at recovery it is about to install whatever that device hands back. Four things authorize a recovery, in order: the blob opens only for the genuine custodian; the reply is sealed to the SAME key-agreement key that authenticated the blob, never a separately claimed one; the reply is SIGNED by the enrolled custodian, because `IdentityService.seal` gives confidentiality and not sender authentication (without it anyone could seal a "destroy" instruction to a public key and have it obeyed); and the lock refuses a returned key whose digest is not the one its blob seals. Transport-free by construction — every step returns the bytes to send and consumes the bytes that arrived — so the mesh wiring and sheets compose it, and the whole ceremony is unit-testable by running two coordinators against each other. There is no cloud recovery route of any kind, deliberately: recovery is in-person mesh + QR only, so this adds no outbound destination. Its audit lines log under the NEUTRAL `mesh.verifyQR.*` family the friend ceremony already uses, never a `duressRecovery.*` one: event names reach the unified log with `.auto` privacy and survive a sysdiagnose, and "this device enrolled a recovery custodian" is a near-synonym for "this device has a duress code" — which is why `configureDuress` and `enrollRecoveryCustodian` emit nothing at all.

``DuressPINSetupView`` is where that response is chosen, under Settings → App lock. It is real-PIN-gated by construction rather than by a re-prompt — the page it is pushed from is already `.appLockSettings`-gated, and a duress code can never satisfy that gate (`FernletLockService` refuses to grant `.appLockSettings` on the duress path, so reaching a gated page really does prove the real passcode) — which is exactly why `configureDuress(pin:mode:)` takes no `current:` argument. Two further layers make that structural rather than assumed: every duress mutator on the service refuses outright while a duress session is in force, and `DuressSetupAvailability` fails closed on the same flag, so a session that somehow reached this screen would see exactly what a phone with no duress code sees. Two of its three options destroy something and one of those is irreversible, so the copy on that screen is treated as reviewable surface: each response states what it does to the user's data in plain words, the destructive pair carry a second explicit confirmation, and the service's own rejections (a duress code equal to the passcode; the recovery lock chosen with no enrolled device) are surfaced verbatim instead of restated, so the screen and the lock can never disagree. Its gating rules live in the view-free `DuressSetupAvailability` so they are unit-testable. ``DuressRecoveryEnrollmentSheet`` and ``DuressRecoveryReturnSheet`` drive the coordinator's two ceremonies from either side, on both phones; their transport is a QR relay rather than the friend mesh, because the coordinator is transport-free and carrying it over the radio would mean new `PayloadType` cases for a ceremony that only ever happens with both phones in the user's own hands. The relay adds no trust of its own — the small hops carry public nonces and public keys only, and a relay that substitutes its own key produces a response the real scanner rejects.

### App Shell & Core State

Beyond the entry points above, the shell's second-stage launch pipeline runs in ``LaunchPreparationService`` behind the companion launch screen — guided-run and cooking reconciliation, photowall seeding, ambient AI day summaries, and the companion thought. System integration flows through narrow persisted seams: App Intents and Shortcuts ride the widget's app-group action queue (``PendingWidgetActionQueue``) for background water logging or the expiring ``PendingIntentSheet`` token for foreground opens, ``FernletNotificationDelegate`` hands sheet requests across launch via a pending flag, and ``WidgetSnapshotMirror``'s two `NSFileCoordinator`-guarded JSON files are deliberate byte-format twins of the widget-side copies so the extension never links the FernletKit umbrella. AI plumbing stays wall-respecting — ``FernletAIComposition`` alone names the concrete `SystemLanguageModel` capability provider, and the device-local, never-synced ``UserDefaultsAICallQuotaStore`` and ``FileAIAuditLogStore`` back the sleepy/resting quota overlay and the "what left my device" audit ledger. ``HealthSyncCoordinator`` owns HealthKit ingestion behind the `HealthSyncContext` seam (marking the sleep hours it writes as HealthKit's, so the storage strip can keep them out of iCloud). HealthKit information is never stored in iCloud (owner decision 2026-09-23): the strip removes every HealthKit reading from the synced rows and blob, and ``FileDeviceHealthResidueStore`` — device-local, backup-excluded, bounded, one production instance — keeps this device's copy, recorded at the ingestion points by `FernletStore+HealthKitResidue.swift` and overlaid back by `DiaryStore` (``InMemoryDeviceHealthResidueStore`` is the hermetic default of the synchronous initializer). The same cache holds this device's HealthKit body-profile import (`FernletStore+HealthBodyProfile.swift`): age, sex, height and weight from Health no longer overwrite the synced `settings.userProfile` but are laid over the typed profile as `effectiveUserProfile` — targets, the profile screen and the period-visibility default read it — and a profile-screen edit writes only the fields the user changed. ``CoreDataHealthKitCacheCleaner`` provides the fail-closed opt-out — it scrubs whatever an older build left in the per-row day records and the aggregate synced blob and empties that cache — and, in capture mode, the one-time launch scrub of rows written before the strip existed. The Home dashboard (``HomeView``, ``AmbientCardsView``, ``GentleOfferEngine``) renders the companion-centered daily view with quiet, at-most-once-a-day nudges that disappear rather than nag, and ``UITestSupport`` gives the UX-appearance UI-test suite deterministic DEBUG-only launch hooks that never ship in release builds. Re-tapping the tab already on screen follows the iOS pair: ``ContentView`` bumps that tab's re-select token, and each tab page with a navigation stack routes it through ``TabReselectModifier`` — with a page pushed it clears its path in one write, popping every level back to the tab's main page; at the main page it scrolls to the top (``TabReselectAction``, never both on one tap). A pushed page that holds typed input (the embedded recipe editor, the recipe import, the barcode "New to Fernlet" form, the Activities host form) reports it through ``TabReselectDraftModifier`` into the tab's ``TabDraftRegistry``, and the pop then waits on the shared discard alert — the sheet presentations' `fernletDraftGuard` contract, carried to the tab button. Food and Friends push their root pages as ``FoodRoute`` and ``FriendsRoute`` path values for that reason (the Friends album pops the friend shop itself when its window lapses); Home pushes nothing on its own stack and only scrolls.

### Food & Nutrition

The entire eating surface. ``FoodView`` is the tab root (today's meals by type, macro totals vs. targets, cooking-resume card, recipe previews) and ``MealSheet`` is the quick-log front door reachable from any tab. A typed description runs ``MealResolutionService``'s tiered cascade — on-device AI dish decomposition (``FoundationDishDecompositionModel``, re-grounded in the food catalog by ``MealDecompositionResolver``), candidate-constrained AI selection, the deterministic ``DishTemplateLexicon``, a deterministic plan, and a keyword fallback — with ``MealBuilder`` assembling catalog-bound meals and a calorie plausibility gate downgrading implausible results to the pre-log ``MealReviewSheet``, so no low-confidence guess ever commits silently. ``FoodCaptureRouter`` unifies camera capture, auto-detecting barcode → nutrition label → meal photo and routing into the live scanner (``BarcodeScanView``), the OCR label sheet, the per-GTIN serving-count confirm step, and Vision-based photo identification that always pauses at review. The catalog side ships a build-time-generated USDA SQLite database plus a ~364k-product branded database attached as an On-Demand Resource (``BrandedCatalogResourceLoader``), and the opt-in, egress-audited web importer (``FoodProductWebImporter``). A barcode that misses every local catalog can, behind the same web-nutrition-lookup consent and one explicit tap per lookup, be looked up on Open Food Facts (``OpenFoodFactsLookupCard`` → ``OpenFoodFactsClient``, the one fixed-host client the no-tracking wall pins): the result only prefills ``BarcodeNotFoundView`` so its plausibility gate reviews it, and a kept product becomes a `.openFoodFacts` user food carrying the ODbL attribution wherever its source is shown. Search also learns: when the correction sheet's Replace path is SAVED, `FoodSearchCorrectionMemory` remembers the text that was searched and the food that was chosen — a device-local, wipe-covered sidecar (never synced between devices, though it rides an encrypted device backup) republished into `FoodCatalog`, so the same search answers with the user's own pick first (research §26 fix 1.10). It is a retrieval signal only; the bind-confidence floors that route a quick-log to review never see it. Recipes round out the group: editors and a read-only detail view (a recipe can be split into parts, like a dressing made first and then the salad: ``RecipePartsEditor`` over the pure ``RecipePartsDraft`` builder, with ``RecipePartsLayout`` and ``RecipePartHeader`` grouping the detail, mise en place and the proximity review sheet by part), ``RecipeShareCodec`` for text and proximity-mesh sharing, AI-assisted ingredient substitution that forks rather than mutates, the grocery planner, and the cooking mode whose shared run state survives app kills and drives an interactive Live Activity (``CookingModeView``, ``CookingLiveActivityController``). Meal photos are sealed in the private media store and rendered honestly via ``MealPhotoPresence``/``RecentBites``; everything renders macros-first, with calories only behind an explicit opt-in.

### Movement & Workouts

The Move tab end to end: ``MoveView`` hosts a week-strip workout calendar over per-day plan/log drill-ins, manual logging (full ``WorkoutSheet``, quick-exercise fast path, plan-ahead ``WorkoutPlanSheet``), and the deterministic suggestion engine ``WorkoutPlanningService`` — split recommendation and weekday-rotated day plans filtered by equipment and injuries, with an optional on-device-AI natural-language adjustment that degrades to the unchanged plan. On a rest day — readiness `"needs rest"`, which marking today unwell on Home forces (spec §6a) — `FernletStore.needsRestToday` turns the whole suggestion surface gentle: the split is not consulted (``WorkoutPlanningService`` hands back its one-line un-guided rest plan), the Suggest sheet offers only the Light chip and says rest instead of an intensity, and the root card's copy (``MoveRestDayCopy``) never pushes. A committed day plan flows into the guided runner (``GuidedWorkoutSheet``), whose run state lives on ``FernletStore`` mirrored into the app group so the Lock Screen Live Activity buttons (``WorkoutLiveActivityController``, which — like its cooking counterpart — requests its activity through the shared ``LiveActivityStarter``) advance the same run, and ``GuidedWorkoutAvailability``/``GuidedWorkoutCardState`` reconcile "already logged" across relaunches. Durable context comes from ``WorkoutSetupSheet`` (split, frequency, experience, injuries) and ``WorkoutLocationSetupView`` with its granular equipment checklist rendered from hand-drawn SVG glyphs (``EquipmentIconLibrary``); ``GoalPresetCards`` surfaces the paired nutrition+training consequences of each goal. ``WorkoutTombstoneStore`` is the small persisted ring that stops a removed workout's in-flight Apple Health copy from resurrecting as an unremovable import. ``WorkoutHealthAccessOffer`` makes onboarding's "Asked the first time you log a workout…" true (2026-09-23): the first workout logged or started (`FernletStore.addWorkout` — every logging route, planned completions and guided finishes included — and `startGuidedRun`, which also starts the Live Activity) asks once for workout access, mirroring Settings' "Give access" (master + workout switches, the prompt, the ledger), and puts the switches back on a decline. It asks at most once per install, never a user who switched Health or workout sharing off in Settings, and never when HealthKit would show no sheet (so an earlier answer is never silently turned back into sharing); the workout is always logged, and every save awaits the ask so it reaches Health only if allowed. Not wired under a test harness. ``ProgressPhotoSection`` gives a sealed, lock-gated, snapshot-redacted body-photo timeline, and ``TrainerExportView`` — reached from the Move tab's header "Share" pill, which replaced "Suggest" (that moved into ``WorkoutPlanSheet``, gated to a new plan for today because the suggestion flow is today-scoped) — builds the fail-closed allowlisted trainer/nutritionist bundle: sensitive categories strictly opt-in, sealed data with no representation in the DTO at all. Behind `settings.coachExchangeEnabled` that screen is also the manual **coach exchange**: ``CoachExportPromptBuilder`` puts the windowed bundle plus a schema preamble on the clipboard, and a plan pasted back through ``CoachPlanPasteSheet`` is decoded by ``CoachPlanImporter`` and gated by ``CoachPlanReviewView`` — safety-checked against the user's avoid lists, per-exercise strikes, collision choice — before it becomes dated coach-tagged `PlannedWorkout` rows — or, via ``ResolvedCoachPlanEdit``, before it rewrites or removes workouts already on the calendar, targeted by the row ids the export echoes and shown as a before/after summary (an edit can never reach a logged workout, a missing one, or a past day). The plan is unsigned by construction on this path, so the review screen IS the security boundary; the eventual Coach app changes the transport under it, not the gate.

The progress-photo timeline keeps capture working with no lock at all, so for a user who skipped the onboarding lock step it carries a one-time ``ProgressPhotoLockNudgeCard`` — "Set up lock" (granting `.progressPhotos` and nothing else) or "Not now" — driven by ``DeferredLockSetupNudge``, the first-use prompt `OnboardingDefaults.lockSetupDeferredKey` always promised. ``ProgressPhotoSectionContent`` decides the section's content in one place, so that card rides above the capture control and can never replace it.

### Proximity, Social & Companion Customization

The in-person social layer plus the companion economy that feeds it. The Friends tab (``FriendsView``) is a shared photo album when idle and swaps into ``DisposableCameraView`` — a wind-to-arm "disposable camera" whose viewfinder morphs out of the Dynamic Island — once the mesh commits a session; session end runs a model-state-driven review that saves photos and mints one-sided friends against the trust vault. Around the live session sit the ceremony and safety surfaces: QR identity verification (``VerifyQRDisplaySheet``), the one shared gatekeeper confirmation ``JoinPromptSheet`` behind both mesh admission requests and Group Activity join requests, session-scoped vanishing chat (``SessionChatPanel``, 13+ gated), Group Activities hosting and joining (``ActivitiesView``), the Friends & Blocks roster with block/report/remove and both live-presence and dead-drop "away" hearts (``FriendListView``, ``AwayHeartsCopy``), and the App-Store-compliance safety-reporting flow. ``ConnectionInspector`` records per-session proximity diagnostics, and `ProximityHostAdapter` is the one seam bridging `ProximityKit`'s host abstraction onto ``FernletStore``. The companion economy runs from the ``CreationStudioView`` pixel editor (over ``ZoomablePixelCanvas``, which owns every touch that starts on it, laid out by ``CreationStudioLayout`` so the drawing screen does not scroll; unlisted-first saves, name moderation) through ``WardrobeView`` into the post-session ``FriendShopView`` window, with ``ClothingShareCodec`` sanitizing the catalog wire format in both directions and ``ItemTextureRenderer`` as the single rasterization path; a refused listing (flagged name, shop cap, store ban) surfaces the shared ``ShopAlert`` cases from both the studio and the wardrobe, worded per ``ShopAlertContext``. ``CompanionView`` is the app-wide vector-drawn creature; its emotions (owner decision 2026-09-24) are presentation-only and deliberately never persisted — Home derives one through `FernletStore+CompanionEmotion.swift` and the pure `CompanionEmotionEngine`, ``CompanionExpression`` resolves it (with the state and the settled pose) into eyes, mouth, blush and brows, ``CompanionEmotionMotif`` adds one small vector motif, the old stress/calm accents are now the `frazzled`/`calm` emotions, ``CompanionFeelingsSettingsCard`` holds the device-local cue switch and bedtime (``CompanionEmotionPreferences``), and the widget snapshot carries a widget-safe emotion timeline; ``PetInteractionGovernor`` paces tap-to-pet anti-compulsively, and ``MilestonesView`` shows append-only, grow-only care counts whose coin gifts fund the shop. Behind the surfaces, the radios' decisions are VALUES rather than view code: ``ProximityRunPolicy`` maps the app's lifecycle facts to what each radio must do, ``ProximityRunTransition`` turns two verdicts into an ordered action list, ``ProximitySessionPoller`` decides the one session timer, and — network migration P8 item 4 — ``MeshContinuationCoordinator`` is that same shape for the background continuation claim: six states × eight events → the next state, the `ProximityContinuationState` the run policy is fed, and the task completion the system is owed **exactly once per entry into `running`** (`completion != nil ⟺ (from == .running && next != .running)`) — which is once per delivered task under the one identifier item 6 registers, and never once per session — with ``MeshContinuationProgress`` ratcheting the monotonic progress fraction iOS requires to keep the task alive and ``MeshContinuationCopy`` holding the task card's two localizable sentences. None of the three new values registers, submits, drives or completes anything: the `BGContinuedProcessingTask` itself, and the manager facts it needs, are later items' work. Item 7 adds the fourth and the only one the person meets: ``MeshContinuationCardPresentation`` turns that claim into the Friends tab's card — a pure table over the state AND the frozen token that named its last move, because `completed` is the terminal after any session end and would otherwise erase a refusal nobody was shown — with ``MeshContinuationCardKind`` as its frozen token and ``MeshContinuationCard`` as the copy (three headlines; a present-tense sentence while that session is still on screen, folding to one shared past-tense sentence once it has ended), read off `FernletStore`'s observed `meshContinuationState` / `meshContinuationLastAudit` projection (which item 6 will set — through `MeshContinuationCardPresentation.projectedAudit(previous:outcome:)`, the rule that keeps an ending alive across the claim's own session end rather than letting the `completed` token erase it — and which nothing persists). ``MeshContinuationSlotDecision`` is the precedence over the Friends tab's one banner slot, which P7's ``SessionResumeCopy`` card shares: the live claim outranks it, the ended one yields to it. Item 5 then gives that claim its driver and its two edges: ``MeshContinuationDriver`` holds the claim and, on exactly the moves item 4's table makes, speaks ProximityKit's new `beginBackgroundContinuation()` / `endBackgroundContinuation()` pair — the first shipping raiser the mesh session machine's background and foreground events ever had, and therefore the first time `continuingInBackground` is a state the product can be in. That state is a **deliberate disagreement** with the routed access gate: a mesh carried on in the background custodies routed ciphertext and judges no heart, while the gate's own foreground leg is pushed separately by the run policy from `ScenePhase`, so neither leg reads the other and only both together open the heart stage. The driver holds no timer and no task handle — an ending of nothing raises nothing, an unclaimed delivery is adopted, ended at once and presents nothing. The `begin` raise needs **both** a task in hand and a dark scene: a continued-processing task is delivered while the app is normally still on screen, so raising at the delivery would close the heart stage while the person is using Fernlet, and the driver therefore raises at the delivery only when the scene is already dark and otherwise on `sceneDidGoDark()`, with `end` fired only for a delivery that raised one. Item 6 is the wiring that finally makes the claim move on its own: ``MeshContinuationTaskHost`` owns the driver and the `BGContinuedProcessingTask` — registering `MBO.Fernlet.mesh-continuation.<meshID>` when a mesh starts, submitting with `.fail` on the entry into `requested`, installing the expiration handler, and completing the task exactly once through the probe's idiom — while speaking to `BackgroundTasks` only through ``BackgroundContinuationScheduling`` and ``ContinuationTaskHandle``, because `BGTaskScheduler` refuses a continued-processing submission on a Simulator and the five acts would otherwise have no tier-1 coverage at all. It lives in its own file rather than inside the driver so the driver stays provably free of the framework, the scheduler, the store and the clock. It **keeps the tunnel** — no radio verb, no teardown, no gate — and reaches the radios the one way P8 allows: `FernletStore.setMeshContinuation(state:lastAudit:)` assigns the projection and re-runs the policy, which is the store's sixth own edge and the line that finally makes `runProximityPolicy`'s `continuation:` a fact rather than a literal. Its progress bar rides ``ProximitySessionPoller``'s existing tick, never a second clock — and so does the news that a session ended in the BACKGROUND, because a dark scene's body is not re-evaluated and the view's mesh observer may never fire. It holds the one decided-once foreground fact so the driver's raise can wait for the scene, and every refusal it meets — a registration the system refused, a ninth identifier, a missing identifier, the per-session submission cap — MOVES the claim to `refused` rather than returning silently, because a claim resting on `requested` shows the person no card while the truth is that the session lasts only while Fernlet is on screen.

### Cycle, Journal & Private Data

The sealed/private surface: everything the app promises stays encrypted, device-local, or behind the app lock. **A passcode is optional** (period-data design 2026-09-30, the owner's option B): one hub content key exists per install either way, and without a passcode the Private tab still opens only by a deliberate tap on an unlock screen with exactly one button — friction, not security. ``PrivateHubOpenCoordinator`` is the app's side of that button: it opens the device-custody key, and before any fresh key is minted it checks for entries no key on this iPhone can open (a new iPhone from a device backup, an erased one), names them on a card, and removes exactly those only on the user's "Remove them and open Private". The launch wiring hands the sealed backups the Private tab's own key (never the journal section's, which was nil on the Cycle section in both modes) and routes an app-lock reset into ``FernletStore``'s reset funnel, which moves the Sealed backup work epoch (a suspended v2 pass fails its next gate), clears the backup bookkeeping (the three divergence latches, and every v2 payload's restore marker, accepted head and observed foreign head, with every pending Privacy & Data backup choice made over them) and holds ambient restores — and every re-upload of a backup that was on at the reset, so its pre-reset cloud copy stays as it was — for the device owner (``SealedBackupRestoreHold``) until Privacy & Data's owner-checked "Restore" releases it; each backup's uploads then stay held until its own restore has landed (every restore is a merge, so it always can, whatever this iPhone wrote since the reset), and a hold that keeps no enabled backup's copy is released as soon as the owner enters Privacy & Data. **Every Sealed backup — period, intimate logs and journal — runs on the Sealed backup v2 engine** (``SealedBackupV2Engine``; journal and intimacy Sealed backup v2 design 2026-09-30, building on period design unit 5): ONE engine, owned by ``SealedBackupCoordinator`` and so by ``FernletStore``, runs every pass of every v2 payload on one serial worker, each payload reached through a small adapter over its own gated store (``SealedBackupV2Adapter``; period: ``CycleRecordBackupAdapter``; intimate logs, since unit B2: ``IntimacyBackupAdapter``, over the app's ONE intimacy funnel — `ContentView`'s, handed over at launch wiring before the bookkeeping is seeded, so every write any surface makes marks the upload owed through the funnel's mutation hook, and the intimate-log marker seeds once from that funnel's latch; every decrypt of an intimacy backup chunk runs inside the funnel's own gate, so hidden, under 16 or in duress the engine fetches, decrypts and writes nothing, and Privacy & Data's ``SealedBackupV2StatusRows`` — derived by ``SealedBackupV2RowState`` — name nothing; journal, since unit B3: ``JournalBackupAdapter`` over the sealed journal store — its snapshot is the sealed entries some day still references, so an orphan row is never exported; a day row that will not decode names its day and every sealed entry on that day is kept (nothing heals such a row, so it never stops the backup), and only while the day store cannot account for every row (read-only recovery, a failed fetch, a row with no date key: `FernletRepository.loadAllDaysWithUnreadable()`) does the snapshot fail with nothing written instead of calling every entry on an unread day an orphan; each chunk is read under the hub key OR the journal device key read without minting (``SealedDeviceKeyRead``), so an entry written from Home and not folded yet is backed up as it is; its restore merge keeps every entry that opens here and adds a backup entry whose words differ beside it as its own entry — recognising the other iPhone's copy of an entry it already holds (the same words and creation stamp), so "Restore it here" on both iPhones settles at both versions — then rebuilds the day skeletons, writing only a day that lacks one and staying unresolved when a write fails; `JournalSealingCoordinator`'s writes mark the upload owed through `JournalSealingContext.sealedJournalStoreDidChange()`; its seam is shut only by a duress session, during which Privacy & Data shows no journal row). A pass checks its gates first and **again after every await and immediately before every decrypt and local write**: not wiping and the work epoch unchanged, no duress session, the surface visible, the Private tab's hub key live, iCloud sync and that backup on (the in-memory preferences; a switch being turned off counts as off), and the sealed store attached. The restore is an id-keyed MERGE that runs while this install's restore is unresolved (a persisted marker in ``SealedBackupBookkeeping`` that never resolves because sync or the backup is off, seeded once from its legacy latch — unresolved instead while the owner hold still keeps that backup's pre-reset copy) and never while an app-lock reset waits for the owner — the Retry included. With no escrow key the restore still reads whether a set exists (nothing is opened): none means nothing to wait for, so the restore resolves and the export may mint the first key; a set waits for the synced key; a set that authenticates but that only a newer Fernlet can read (its envelope, or a record such as an unknown feeling tag) is named as needing a newer Fernlet — not retried in this process, never called damaged; and Privacy & Data offers the confirmed "Start a new backup" for a restore that can never open its set, and "Restore it here" or "Replace" for one refused as older than a set this iPhone has seen. The export runs only behind restore-first (E1), a writer-first compare-and-swap against the set in iCloud (E2: this install's own set — its writer tag, or for a v1 set its AAD-bound signing key — up to the highest generation this install recorded, its accepted SET (generation and salt, never a writer and number alone), or exactly the set the user chose to replace; an own set numbered above anything this install recorded — an iPhone put back from an older device backup of itself — reopens the restore, which merges it before anything is exported; "Start a new backup" writes only over a set this iPhone cannot open; anything else is held and named "saved from another iPhone", with "Restore it here" and "Replace", and persisted as an observation), every chunk decrypted and sealed IN MEMORY before the first save (E3), and a commit that records its in-flight generation, writes the suffix chunks under names scoped to their own set (`…chunk.<i>.<set>`, ``SealedBackupV2Envelope``) and then the head — the one commit point — inside a background-task assertion, then verifies the head and every suffix chunk of its set and prunes only the sets at or below the head it read (never the set the current head names), so a concurrent export's chunks survive while its head lands. An interrupted export therefore never damages the previous backup, and two iPhones can never interleave chunks. The generation is computed above everything this install has seen and recorded only on a verified commit. "Delete everything", the app-lock reset, turning a backup off and "Stop syncing and delete iCloud data" all stop the worker before they touch the cloud or the stores — the commit re-checks before EVERY save that no wipe or reset ran and that sync and the backup are still on, and the turn-off and the cloud delete wait for it — so no set is ever written after its cloud copy was deleted, and a CloudKit call such a stop cancels records no failure. A hub session settles every v2 payload once, on whichever Private section opens first (Worry Box included), with a 15-minute backoff after a failure; explicit choices in Privacy & Data are in-memory intents the next hub settle carries out. Every cycle-record, intimate-log and journal change moves the host's mutation epoch and marks the upload owed through its funnel's or the sealing coordinator's hook. The Privacy & Data delete-all sheet says, while any Sealed backup is on, that Sealed backups in iCloud are deleted for every iPhone that uses them. ``PrivateHubView`` (wrapped in the app-lock gate) pages between the Journal, the merged Cycle page, and Worry Box, with the Cycle page conditional on the store's derived visibility — it exists while either the period or the intimacy half is visible, each half gates itself independently inside ``CycleTrackerView``, and the clamped selection can never land on a hidden page. The journal and cycle pages draw their month grids from one shared ``MonthCalendarCard`` — canonical day keys, paging chevrons, weekday row — and fill it with their own per-feature cells; the cycle calendar layers period flow tints and a distinct intimacy marker in one grid, and day taps open the combined ``CycleDayDetailView``. **Every cycle entry is saved in Fernlet, whatever the Health switches say** (the cutover, design unit 4; owner report 2026-09-29): each is ONE sealed `CycleRecord` — clinical fields, note and symptoms together — sealed at once while the Private tab is open, or held in the pending buffer until it next opens (nothing is dropped), and only THEN copied to Apple Health, while the user's cycle sharing is on. ``LogPeriodSheet`` therefore never refuses for sharing: it says up front, while sharing is off, that the entry saves privately and is not copied; it maps the store's outcome to one honest sentence pinned above its Save bar (held until Private opens, the Health copy failed, an edit removed Fernlet's older Health copy); and an edit updates the record in place under the same id. ``CycleTrackerView`` runs drain → legacy import → load after every unlock (the import moves the pre-cutover sealed notes and Fernlet's own Health samples into records, idempotently, and names any note this iPhone cannot open on a card), reads Apple Health only while the cycle capability is on, and no longer asks for Health access itself (owner question Q4). ``CycleDayDetailView`` shows "Your entry" (Fernlet's records), Fernlet's own Health copies with no record here — with "Keep in Fernlet" and "Delete from Apple Health" when that is all the day holds — and other apps' samples read-only by source; its Delete removes Fernlet's rows first and says so when Apple Health still holds a copy. "Delete everything" stops the import's writers in its first leg and marks both import halves done, and its confirmation names the whole "cycle history" (every field, not only the notes), which for a user who never shared with Apple Health is the only copy. Free-text narratives are sealed into the `Private*` stores under the hub content key while the Private tab is open (by passcode or by tap) or a device-bound Keychain fallback while it is closed, every fallback row folded under the hub key the next time the tab opens — ``JournalSealingCoordinator`` enforces that plaintext never reaches the synced snapshot blob, and ``WorryBoxService`` is its deliberately simpler, never-synced sibling. Core Memory rides that same blob, so a journal entry never lands there as words (owner decision 2026-09-23): `FernletStore` mints an emotion-only memory — the entry's feeling token, no text — and may then upgrade it with an on-device summary through ``JournalMemorySummarizing`` (production: ``OnDeviceJournalMemorySummarizer``), re-checked against the full entry before it is written; the Settings Core memory page builds the emotion-only sentence at render time. ``SealedBackupCrypto``, ``SealedBackupService``, and ``SealedBackupCoordinator`` add the opt-in AES-GCM sealed CloudKit backup with escrow-key reconciliation and fail-closed, merge-only restores. Its payloads are period, journal and intimacy data; the fourth, `sensitiveNotes` — the Tier-2 behavioral memories — is RETIRED (owner decision 2026-09-23: "Tier 2 sensitive notes shouldn't be backed up to iCloud at all"): it has no switch, is never sealed or restored, and the launch pass deletes any copy an earlier build left in iCloud, quietly and idempotently. The coordinator's host seam no longer exposes Tier-2 at all; those records live only in the device-local, backup-excluded `TierTwoMemoryStore`. ``FirstAidView`` offers slow breathing, grounding, the Worry Box, and a crisis-support row whose number comes from ``CrisisResources``, keyed on the device's **region** rather than its language — a German speaker in the US must still see 988, and an American in Spain must see 024 — and read at render time, not cached, so someone who travels or changes their region setting sees the line that works where they are now. Every listed line was verified against the operator's own publication and is free and staffed around the clock, which is what lets one piece of shared copy make that promise for all of them; an unlisted region deliberately gets supportive copy and **no button at all**, because a dialable-looking number that does not connect in that country is the worst thing this screen could do to someone in crisis. (This page described a *static 988 row* until 2026-08-20, which stopped being true when the region table landed — putting 988 back in the view would ship a dead call to every user outside the US and Canada.) ``StressService`` computes the opt-in body-signals estimate into a device-local sidecar it scrubs the moment consent lapses. ``AgeAssuranceStore`` walls intimacy tracking (16+) and mesh chat (13+) behind DeclaredAgeRange verdicts, stored device-locally and failing closed on anything undetermined.

### Onboarding, Settings & Shared UI

The app's front door and its conscience: first-run onboarding, the Settings hub with its privacy and data controls, and the reusable sheets those surfaces share. ``OnboardingCoordinatorModel`` drives the eight-step, strictly-forward flow, accumulating every choice as draft state and committing it to ``FernletStore`` in a single `complete()` call — except the lock step (recorded immediately) and the storage step, which probes the iCloud account through ``ExistingCloudDataDetecting`` so a returning user is steered toward "Restore from iCloud". The personal-details step runs the one unprompted age-range request, and for a user the 16+ intimacy gate admits it is followed by ``OnboardingIntimacyChoiceScreen`` — keep intimacy tracking (the default) or turn it off — as a second page of that same step rather than a ninth one (and swapped in, not presented, because it appears the moment the system age sheet returns), so under-16 and undetermined users never see it and their setting is never written. The answer is draft state like the rest and lands through `FernletStore.setIntimacyTrackingVisible(_:)`, the setter the Settings toggle drives, so it is the Settings setting and a hide, never a delete. ``SettingsSheet`` is a searchable hub navigating over ``SettingsRoute`` with ``SettingsSearchIndex`` as its hand-written catalog; since the 2026-08-21 redesign (SETT-14/29) it is four groups — Your day, Data & sources, Privacy & data, Friends & private — whose row sub-labels double as the search breadcrumbs, with a DEBUG-only Advanced section holding the Connection log. The friend toggles live on ``NearbyFriendsSettingsView`` (dependency-ordered, one footnote per toggle), the period/intimacy visibility gates on ``PeriodSensitiveSettingsView``, the quick-log tile order in ``QuickLogShortcutsEditor`` (one reorderable list; the stored array is never visibility-filtered), and ``HealthAccessSettingsView`` is the single Health surface — a master switch plus one state-and-action card per capability, so two pages can no longer disagree about whether a kind is shared. A card's switch is also a WRITE gate (2026-09-23): with it, or the master, off, the HealthKit gateway writes nothing to Apple Health, so a feature that asks in context goes through ``HealthAccessGrant``, which opens the kind's switch the way "Give access" does and closes it again on a declined prompt. The period sheet and the Cycle page no longer ask (owner question Q4, default since the cycle cutover): cycle sharing is turned on here only, and `HealthAccessGrant.requestInContext` is kept so reinstating the ask is one call. ``PrivacyDataSettingsView`` is the privacy control room — entered through a fresh Face ID / iPhone passcode check with or without a Fernlet passcode (period-data design Q5) — protection first (the moss-outlined photo-protection card), then backups and export, with the page's only two terracotta actions grouped under Delete at the bottom. The connective tissue is the nothing-destructive-happens-silently invariant: every data-destroying action routes through ``DestructiveConfirmation``; delete-everything itself presents ``DeleteEverythingSheet`` — a typed-gate sheet whose confirm word is a localized matching input (``DeleteConfirmationWord``: the UI compares the localized word, the CloudKit service keeps its frozen English token) and whose this-deletes / kept-on-purpose lists must stay reconciled with the wipe funnel that ``DeleteAllDataConfirmation`` records; ``DeletingEverythingOverlay`` blocks interaction for the duration of a wipe. Both Settings entry points drive that wipe through their own instance of the shared ``DeleteEverythingFlow`` — one copy of the busy/success/failure state and its outcome alerts, deliberately per-screen so each screen's overlay, button disabling, and dismissal guards key off the wipe it actually started. The Debug tab carries two DEBUG-only cryptographic surfaces, kept side by side rather than folded together because their promises differ: ``CryptoFormatCensus`` counts stored blobs by their format MARKER BYTES only — nothing decrypts, nothing fetches a key, nothing is written or persisted — while the ``Phase3GateReadoutView`` pushed beside it folds six gate rows over the three completion latches that remain (media at-rest, own-photo key, sealed-photo backup), can fetch and decrypt the three sealed-photo iCloud manifests on request, and can fund a media at-rest conversion pass through `performPass()` (which never touches that surface's latch, because the latch IS the gate). Three of its six rows — sealed columns, app-lock content-key wrap, heart-drop sidecars — are census-only since Phase 3 deleted the legacy readers they gated: they license no deletion any more and instead report how many stored rows this build can no longer open. The page moves NO latch in either direction; the fifth control that used to clear the sealed-column latch to arm a keyed pass went with `ColumnCrypto`'s legacy read rung, along with the migrator that pass would have run, so nothing here can write a bit a later launch would read as one a shipped pass earned. Both are absent from Release by a file-scope `#if DEBUG`, so a Release caller fails to build rather than failing review; the readout persists nothing (``Phase3ReadoutSession`` is in-memory process state, cleared on a duress engage) and refuses to render at all under a duress session.

## Topics

### App Shell & Core State

- ``FernletStore``
- ``FernletApp``
- ``ContentView``
- ``FernletStoreLoader``
- ``LaunchPreparationService``
- ``BackupExclusionLaunchGate``
- ``FernletPriorUseMarker``
- ``FernletSheet``
- ``FernletTab``
- ``TabReselectAction``
- ``TabReselectModifier``
- ``TabReselectDraftModifier``
- ``TabDraftRegistry``
- ``TabDraftLease``
- ``FernletNotificationDelegate``
- ``PendingIntentSheet``
- ``WidgetSnapshotMirror``
- ``PendingWidgetActionQueue``
- ``HealthSyncCoordinator``
- ``HealthAccessGrant``
- ``WorkoutHealthAccessOffer``
- ``WorkoutHealthAccessOutcome``
- ``CoreDataHealthKitCacheCleaner``
- ``FileDeviceHealthResidueStore``
- ``InMemoryDeviceHealthResidueStore``
- ``UserDefaultsAICallQuotaStore``
- ``FileAIAuditLogStore``
- ``FernletAIComposition``
- ``HomeView``
- ``AmbientCardsView``
- ``GentleOfferEngine``
- ``UITestSupport``

### Food & Nutrition

- ``FoodView``
- ``FoodRoute``
- ``MealSheet``
- ``MealResolutionService``
- ``MealBuilder``
- ``FoundationDishDecompositionModel``
- ``MealDecompositionResolver``
- ``DishTemplateLexicon``
- ``FoodCaptureRouter``
- ``MealPhotoRecognizer``
- ``MealReviewSheet``
- ``RecipeSheet``
- ``RecipeDetailView``
- ``RecipeBookSheet``
- ``RecipePartsDraft``
- ``RecipePartsEditor``
- ``RecipePartEditorCard``
- ``RecipePartEditorActions``
- ``RecipeIngredientRows``
- ``RecipeStepEditorCard``
- ``RecipeEditorActionLabel``
- ``RecipeEditorInputs``
- ``RecipePartsLayout``
- ``RecipePartHeader``
- ``RecipePartsIngredientList``
- ``RecipePartsStepList``
- ``BarcodeScanView``
- ``BarcodeNotFoundView``
- ``BarcodeServingStepView``
- ``OpenFoodFactsLookupCard``
- ``OpenFoodFactsClient``
- ``OpenFoodFactsProductParser``
- ``OpenFoodFactsBarcode``
- ``NutritionLabelCameraSheet``
- ``NutritionTargetsEditor``
- ``BrandedCatalogResourceLoader``
- ``FoodProductWebImporter``
- ``FoodProductWebSearch``
- ``RecipeShareCodec``
- ``ShoppingListBuilderView``
- ``WeeklyMealPlannerView``
- ``IngredientSubstitutionSheet``
- ``CookingModeView``
- ``CookingLiveActivityController``
- ``RecentBites``
- ``MealPhotoPresence``

### Movement & Workouts

- ``MoveView``
- ``WorkoutSuggestionSheet``
- ``GuidedWorkoutAvailability``
- ``GuidedWorkoutCardState``
- ``MoveRestDayCopy``
- ``GuidedWorkoutSheet``
- ``GuidedWorkoutEditorSheet``
- ``WorkoutSheet``
- ``WorkoutPlanSheet``
- ``WorkoutSetupSheet``
- ``WorkoutLocationSetupView``
- ``ActivityPickerSection``
- ``WorkoutPlanningService``
- ``WorkoutPlanningContext``
- ``WorkoutLiveActivityController``
- ``LiveActivityStarter``
- ``WorkoutTombstoneStore``
- ``ProgressPhotoSection``
- ``ProgressPhotoSectionContent``
- ``ProgressPhotoLockNudgeCard``
- ``DeferredLockSetupNudge``
- ``ProgressPhotoDetailView``
- ``TrainerExportBundle``
- ``TrainerExportOptions``
- ``TrainerExportWindow``
- ``TrainerExportView``
- ``ExerciseLineParser``
- ``CoachExportPromptBuilder``
- ``CoachPlanImporter``
- ``CoachPlanImportReview``
- ``ResolvedCoachPlanEdit``
- ``CoachPlanSafetyFlag``
- ``CoachPlanImportResult``
- ``CoachPlanCollisionPolicy``
- ``CoachPlanImportFailure``
- ``CoachPlanPasteSheet``
- ``CoachPlanReviewView``
- ``GoalPresetCards``
- ``EquipmentIconLibrary``

### Proximity, Social & Companion Customization

- ``FriendsView``
- ``FriendsRoute``
- ``DisposableCameraView``
- ``CameraCaptureController``
- ``IslandViewfinderMetrics``
- ``ConnectionInspector``
- ``ProximityRunPolicy``
- ``ProximityRunTransition``
- ``ProximitySessionPoller``
- ``SessionResumeCopy``
- ``MeshContinuationCoordinator``
- ``MeshContinuationProgress``
- ``MeshContinuationCopy``
- ``MeshContinuationCardPresentation``
- ``MeshContinuationCardKind``
- ``MeshContinuationCard``
- ``MeshContinuationDriver``
- ``MeshContinuationEndReason``
- ``MeshContinuationAdoption``
- ``MeshContinuationSlotDecision``
- ``MeshContinuationTaskHost``
- ``BackgroundContinuationScheduling``
- ``ContinuationTaskHandle``
- ``ContinuationTaskRequest``
- ``SystemContinuationScheduler``
- ``SystemContinuationTaskHandle``
- ``FriendListView``
- ``SendGoodVibesLabel``
- ``AwayHeartsCopy``
- ``ActivitiesView``
- ``JoinPromptSheet``
- ``SessionChatPanel``
- ``VerifyQRDisplaySheet``
- ``ProximityRecipeShareSheet``
- ``RecipeShareConfirmation``
- ``RecipeShareOutcomeLatch``
- ``RecipeShareConfirmationPanel``
- ``RecipeShareRadioCustody``
- ``RecipeShareRadioHandBack``
- ``ProximityRecipeShareReviewSheet``
- ``ClothingShareCodec``
- ``FriendShopView``
- ``CreationStudioView``
- ``CreationStudioLayout``
- ``WardrobeView``
- ``ShopAlert``
- ``ShopAlertContext``
- ``ZoomablePixelCanvas``
- ``ItemTextureRenderer``
- ``CompanionView``
- ``CompanionExpression``
- ``CompanionEmotionMotif``
- ``CompanionFeelingsSettingsCard``
- ``CompanionEmotionPreferences``
- ``PetInteractionGovernor``
- ``MilestonesView``

### Companion Background Refresh

- ``CompanionRefresh``
- ``CompanionRefreshRequest``
- ``CompanionRefreshTaskHandle``
- ``CompanionRefreshScheduling``
- ``SystemCompanionRefreshTaskHandle``
- ``SystemCompanionRefreshScheduler``
- ``CompanionRefreshCoordinator``
- ``CompanionRefreshStep``
- ``CompanionRefreshOutcome``
- ``CompanionRefreshRun``
- ``CompanionRefreshSteps``
- ``CompanionRefreshPipeline``
- ``CompanionRefreshWiring``
- ``WidgetSnapshotPublication``

### Cycle, Journal & Private Data

- ``PrivateHubView``
- ``PrivateHubOpenCoordinator``
- ``SealedPriorEntryStore``
- ``SealedBackupRestoreHold``
- ``SealedBackupV2Engine``
- ``SealedBackupV2Adapter``
- ``CycleRecordBackupAdapter``
- ``IntimacyBackupAdapter``
- ``JournalBackupAdapter``
- ``JournalBackupSeamClosedError``
- ``SealedDeviceKeyRead``
- ``SealedBackupBookkeeping``
- ``SealedBackupAcceptedHead``
- ``SealedBackupHeadStamp``
- ``SealedBackupV2Envelope``
- ``SealedBackupV2EnvelopeHeader``
- ``SealedBackupV2Format``
- ``SealedBackupV2FormatError``
- ``SealedBackupWriterTag``
- ``SealedBackupSetTag``
- ``SealedBackupTrigger``
- ``SealedBackupV2Status``
- ``SealedBackupV2Phases``
- ``SealedBackupV2GateFailure``
- ``SealedBackupV2PassReport``
- ``SealedBackupChunkPage``
- ``SealedBackupMergeResult``
- ``SealedBackupBackgroundTaskAsserting``
- ``SealedBackupUIKitBackgroundTasks``
- ``PeriodBackupExportState``
- ``SealedBackupV2RowState``
- ``SealedBackupV2RowChoice``
- ``SealedBackupV2StatusRows``
- ``SealedBackupV2RowCopy``
- ``JournalSealingCoordinator``
- ``JournalSealingContext``
- ``JournalMemorySummarizing``
- ``OnDeviceJournalMemorySummarizer``
- ``WorryBoxService``
- ``SealedBackupCoordinator``
- ``SealedBackupService``
- ``SealedBackupCrypto``
- ``SealedBackupContext``
- ``SealedBackupRestoreOutcome``
- ``StressService``
- ``StressScoringContextProviding``
- ``AgeAssuranceStore``
- ``AgeAssuranceRequest``
- ``AgeGateNotice``
- ``CycleTrackerView``
- ``CycleDayDetailView``
- ``LogPeriodSheet``
- ``LogIntimacySheet``
- ``JournalView``
- ``FirstAidView``
- ``CrisisResources``
- ``CrisisResource``

### Onboarding, Settings & Shared UI

- ``OnboardingCoordinatorModel``
- ``OnboardingCoordinator``
- ``ExistingCloudDataDetecting``
- ``OnboardingStorageChoiceView``
- ``OnboardingLockSetupView``
- ``OnboardingIntimacyChoiceScreen``
- ``SettingsSheet``
- ``SettingsRoute``
- ``SettingsSearchIndex``
- ``NearbyFriendsSettingsView``
- ``PeriodSensitiveSettingsView``
- ``QuickLogShortcutsEditor``
- ``HealthAccessSettingsView``
- ``PrivacyDataSettingsView``
- ``AppLockSettingsView``
- ``DestructiveConfirmation``
- ``DeleteAllDataConfirmation``
- ``DeleteEverythingSheet``
- ``DeleteConfirmationWord``
- ``DeleteEverythingFlow``
- ``DeletingEverythingOverlay``
- ``FernletDataExport``
- ``PrivacyPolicyView``
- ``PhotoCaptureControl``
- ``MonthCalendarCard``

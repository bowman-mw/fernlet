# Privacy wipe coverage

**Contract:** every persistence surface in the app is accounted for below — either it is cleared by
"Delete everything" (`FernletStore.deleteAllData`), or it is a documented deliberate exception, or
(third table, added 2026-08-20) it is an **open gap**: something the wipe does not reach and nobody
decided should survive. The third table should always be empty; that it is not is the honest state
of the app, not a redefinition of the promise.
`Tests/FernletTests/PrivacyWipeCoverageTests.swift` enforces the first table
mechanically, in both directions: it scans the wipe path for one token per row, so removing a wipe
call (or adding a store without wiring + documenting it) fails the suite — and every row's token
must appear in the test's manifest (`everyDocumentedWipeRowIsEnforcedByTheManifest`), so a
documented-but-unenforced row fails too. **Adding a store = add its wipe call, a row here, and its
token in the test — in the same commit.**

The scan is bounded to the BODIES of the funnel and its numbered legs, with comments stripped. A
whole-file scan used to satisfy a row from an unrelated function — the same call spelled somewhere
else in the 4,000-line store — so a deleted wipe call could keep the suite green while the wipe was
broken. Since 2026-08-20 the scan also covers `ContentView.attachDeleteAllHooks` /
`attachCloudDeleteAllHooks`, because several real clears live inside those hook closures, and
`everyPrivateWipeHelperIsRegistered` requires every private helper the wipe path calls to be
registered — the bounding's own escape hatch was moving a banned call into an unscanned leg.

`Tests/FernletTests/PersistedSurfaceWipeBoundaryTests.swift` enforces the other direction for
`UserDefaults`: it **discovers** every defaults-backed surface from the shipping sources and fails
until each carries a disposition — cleared, kept, unreachable, or an honest open gap. See
"The UserDefaults discovery wall" below; it is the reason the third table is now enforced rather than
merely written down.

Every keychain service the app uses is named in one of the tables, so a `grep -r 'com\.fernlet\.'`
over the sources and the two tables below return the same set. **That sentence is true of keychain
SERVICES and of `UserDefaults` keys, and of nothing else** — see the warning immediately below.

Pattern borrowed from bitchat's `privacy-assessment.md` panic-wipe checklist (bitchat adoptions
Increment 1, Docs/Plan-Bitchat-Adoptions-2026-07-25.md).

> ### ⚠️ How much of that contract is mechanical — read this before trusting the tables
>
> **2026-08-20 doc-accuracy sweep, revised the same day by the Part 4.4 discovery wall.** The
> contract paragraph above used to over-promise badly, and a reader who trusted it would have
> concluded that anything absent from both tables does not exist. Half of the correction has since
> been mechanised; the rest has not, and the difference is worth understanding precisely.
>
> `PrivacyWipeCoverageTests` enforces **correspondence**, in both directions, over the *cleared-by*
> table only: every documented row names a token the manifest enforces, and every manifest token is
> documented. That is a strong check on the wipe not silently LOSING a call it already makes. It is
> not a check on the wipe COVERING everything, and it structurally cannot be — the scan is bounded
> to the bodies of `deleteAllData` and `resetAll`, and a surface the wipe never touches leaves no
> trace in those bodies for a scan to miss.
>
> That gap is real, and it cost: a new `UserDefaults`-backed store could ship, never be wiped, and
> never be documented, with the whole suite green. The 2026-08-20 sweep found **eight such keys in
> neither table**, four of them surfaces the wipe genuinely did not reach — and it found them by a
> human walk of the sources, because nothing in CI was looking.
>
> **Two discovery floors now exist, and they close different halves of it:**
>
> - **Keychain services** — `PrivacyWipeCoverageTests/everyKeychainServiceIsDocumented` walks the
>   sources for `…service`-bound `com.fernlet.*` literals and fails on any not named in this doc.
> - **`UserDefaults`-backed surfaces** — `PersistedSurfaceWipeBoundaryTests` (Part 4.4) discovers
>   every one from the shipping sources and requires each to carry a disposition. See
>   "The UserDefaults discovery wall" below for exactly what it proves and what it does not.
>
> **Everything else in the contract is still a human promise, kept by review.** Files on disk,
> keychain *accounts*, Core Data entities, HealthKit and CloudKit namespaces have no discovery at
> all. If you add a store of any of those kinds: wire its clear, add its row, add its token — and if
> you decide it should survive, say why in the exceptions table.

## What "cleared" honestly means for the sealed store

The sealed narratives (cycle, journal, intimacy, Worry Box) are the only rows in the app where
"deleted" needs qualifying, so the qualification lives here rather than in a comment nobody reads.

Deleting them is a **two-step contract**, both steps keyless so they work while the app is locked:

1. **Row-delete** (`periodDataDeleteHook`, `intimacyDataDeleteHook`, `journalDataDeleteHook`,
   `worryBoxResetHook`, and `PrivatePersistenceController.purgeEncryptedEntities()` on the reset
   path) drops the rows and prunes the persistent-history shadow tables. It does **not** checkpoint
   the WAL or vacuum the freelist — so on its own it leaves **class-key-protected, key-bound
   residue in `-wal` frames and freed pages until those pages are reused**. Ciphertext under a
   ThisDeviceOnly key, on a `FileProtection.complete` store that never leaves the device, but
   residue. Row-delete alone is not erasure and this doc will not call it that.
2. **Store rebuild** (`sealedStoreRebuildHook` → `PrivatePersistenceController.rebuildStore()`)
   destroys the store file itself — sqlite, `-wal`, `-shm`, plus the `.FernletPrivate_SUPPORT`
   external-blob directory — and re-adds an empty store with the same file protection and backup
   exclusion. **This is what removes the logical residue.** It cannot promise the physical flash
   blocks are gone (APFS copy-on-write and wear-levelling may keep them until overwritten; no
   user-space code on iOS can guarantee otherwise) — those blocks stay under the
   `FileProtection.complete` class key, which is evicted while the device is locked.

Order is row-delete → rebuild, deliberately: a rebuild that fails still leaves the rows gone. And a
failed rebuild never leaves the app **storeless** — a failed detach leaves the old store attached and
skips the file work, a failed destroy still re-adds, and a failed re-add retries once, logs, and is
healed by `reloadStoreIfNeeded()` on the next foreground. That matters for privacy, not just
reliability: with no sealed store every seal fails, and a failed journal seal deliberately keeps its
plaintext in the days blob, which mirrors to iCloud when sync is on.

**Only destroying the content key is an instant honest erase** of the logical content, whatever
physical residue survives. Hence two tiers of promise, and the wording each one is allowed:

| Path | Content key | Honest claim |
| --- | --- | --- |
| `FernletLockService.reset()` — Settings → "Reset app lock" | **Destroyed — all of them**: `KeychainItem.deleteAll(service:)` sweeps every generic password under `com.fernlet.lock`; `SecureEnclaveContentKeyWrap.deleteKey` removes the SE wrap outside that sweep; and the same `deleteAll` sweep runs over each of `sealedContentKeyServices` (`com.fernlet.journal`), taking the journal and Worry Box **device fallback keys** that seal those rows whenever the lock is closed. All three, because two of the four sealed entities are not always sealed under the content key — without the third sweep "crypto-erased" would be false for every row written while locked | **Fully honest** — crypto-erased *and* the file rebuilt. (One exception stays flagged, not fixed: the locked-note buffer key `com.fernlet.narrative-buffer` is not swept — owner call, see the deliberate-exceptions table) |
| `FernletStore.deleteAllData` — "Delete everything" | **Kept by design** (see the deliberate-exceptions table: losing your data must not silently un-lock the app) | **Bounded-honest** — no live ciphertext; any residue is class-key-protected and key-bound. **Not** "crypto-erased"; do not upgrade this wording |
| **Duress WIPE** (`DuressMode.silentWipe`) — entering the duress PIN on a device configured for the wipe response | **Destroyed — the same three sweeps as `reset()`, by an explicit list rather than a service-wide `deleteAll`**: `.salt`, `.verifier`, `.wrappedContentKey`, `.wrappedContentKeyRewrapStaging` (the Phase 2.5 re-wrap staging slot — a scrypt-openable copy of the content key whenever it exists), `.seWrappedContentKey`, `.biometricBypass`, `.biometricEnabledFlag`, every duress/recovery row, `SecureEnclaveContentKeyWrap.deleteKey`, a `deleteAll` over each of `sealedContentKeyServices` for the journal / Worry Box **device fallback keys**, and a `deleteAll` over each of `mediaKeychainServices` (`com.fernlet.private-media`) for the **private-media keys** — the own-photo key that seals progress (body) photos, meal and recipe photos and the sealed progress index, plus the friend-wall key. That fourth sweep is not optional to the claim: those photos are sealed bytes on this device under a key the app lock never holds and the delete funnel deliberately KEEPS, so without it "every key that can open a sealed byte here" was false until the asynchronous purge caught up — and false forever if the process was killed first. Synchronous, sub-second, and unconditional — it runs before anything is drawn. A throwaway empty lock is then re-minted under the duress PIN so the device still looks locked | **Fully honest for the KEYS** — every sealed byte on the device becomes unopenable immediately. The ciphertext ROWS and cloud copies are cleared afterwards, best-effort, by `duressPurgeHook` → `deleteAllData(includingHealthKitSamples: true)`; off-device copies (sealed iCloud backups, heart-drop dead-drops) exist as unopenable ciphertext until that purge or their own age-out reaches them |
| **Duress RECOVERY-LOCK** (`DuressMode.recoveryLock`) — entering the duress PIN on a device whose response is the recovery lock | **Destroyed: every LOCAL route only.** The same explicit list as the wipe *minus two deliberate omissions* — `.recoveryBlob` and the two custodian public keys are KEPT (they are the only way back), and neither `sealedContentKeyServices` nor `mediaKeychainServices` is swept, because the journal / Worry Box device fallback keys and the private-media photo keys are not in the recovery blob and destroying them would be loss no ceremony can undo. `.salt`, `.verifier`, `.wrappedContentKey`, `.wrappedContentKeyRewrapStaging` (the Phase 2.5 re-wrap staging slot — a scrypt-openable copy of the content key whenever it exists), `.seWrappedContentKey`, `.biometricBypass`, `.biometricEnabledFlag`, the duress rows and `SecureEnclaveContentKeyWrap.deleteKey` all go. No throwaway lock is re-minted and `duressPurgeHook` never fires — the corpus is being kept for the custodian, not deleted | **Not an erase at all, and must never be described as one** — it is a *deliberate lock-out*: the sealed corpus survives intact and is recoverable in person from the enrolled custodian device (`reestablishLocalUnlock`, which refuses any key that is not the one the blob seals). Its honest claim is "this phone can no longer open it, and neither can anyone holding this phone". The residual it accepts, in exchange for being recoverable: rows written while the lock was CLOSED stay sealed under the surviving device fallback keys — the same exposure an ordinary locked device carries, reachable only by forensic extraction |

## Cleared by Delete everything

Ordering matters — pending saves are cancelled first and re-cancelled after `resetAll()`, the
repository purge runs late, widget files after that, then the proximity identity, and the main
store's compaction last of all (before the preference reset, so the app's own preference-driven
container reload cannot race it). See the numbered commentary inside `deleteAllData`.

**One surface is deliberately absent from this table, and the auditor should know why: research §26
fix 1.9's food-search history profile.** It ranks the foods this person has logged above everything
else in the typed food search, so it looks like exactly the kind of per-user residue this document
tracks — and §26's own risk column assumed it would be a stored per-`foodItemId` usage ledger needing
a row here. It is not stored. `FoodSearchHistory` is DERIVED from `DiaryStore.recentMeals` — already
in the synced snapshot, already cleared by the day-rows/blob row below — and held only as an
in-memory snapshot inside the live `FoodCatalog`. There is no `UserDefaults` key, no field of its
own, nothing on disk, and therefore no independent clear call to register in `wipeManifest`. The
live in-memory copy is emptied by the `didSet` on `recentMeals`: `resetDiary()` assigns `[]`, which
re-derives and republishes the empty profile in the same statement, closing the same "deleted but
still there until relaunch" hazard the correction memory's explicit `setSearchAliases([:])` line
closes — without a second call site that could drift out of step with the first. Two tests hold that
shape: `FoodSearchHistoryStoreTests.aWipeCoolsTheCatalogInTheSameProcess` proves the live catalog
really does stop promoting after a wipe, and `historyIsDerivedNotStored` pins the derivation/publisher
topology plus the exact proposed `foodSearchHistory` defaults-key spelling. It is deliberately not a
general proof against arbitrarily renamed storage.

| Surface | Where it lives | Wiped by (token) |
| --- | --- | --- |
| Pending debounced snapshot saves | SnapshotSaveCoordinator | `snapshotSaveCoordinator.cancelPending` (start AND after purge) |
| Sealed iCloud backups (all payload types — sensitive notes, period, **journal narratives**, **intimacy logs**) | CloudKit private DB | `setSealedBackupEnabled` |
| Sealed-backup rollback high-water mark (chunked payloads **and** the own-photo corpora) — the keys `fernlet.sealedBackup.generation.*` and `fernlet.sealedPhoto.generation.*`, one per payload type / photo corpus | `SealedBackupGenerationStore` (UserDefaults, device-local) | `generationStore.reset` (the call site is two lines — construct, then `.reset()` — so the token is the variable's spelling; the type name never appears on the calling line. `reset()` walks BOTH `SealedBackupPayloadType.allCases` and `SealedPhotoCorpus.allCases`) |
| Own-photo escrow backup — every sealed photo body **and** its corpus manifest, for meal / recipe / progress; the same call also clears four device-local UserDefaults records, none of which holds bytes or captions: the upload ledger (`OwnPhotoUploadLedger`, `fernlet.sealedPhoto.uploadedIDs.*` — photo IDs only), so a torn-down backup leaves no claim of ownership behind; the restore-repair ledger (`OwnPhotoRestoreRepairLedger`, `fernlet.sealedPhoto.restoreRepairIDs.*` — photo IDs a partial restore still owed), because ids owed by a backup that no longer exists can never be fetched; the route's commit proof (`OwnPhotoEscrowCommitLedger`, `fernlet.sealedPhoto.routeCommitted` — one bit), which no longer evidences anything once the records are gone; and the hash-version migration latch (`SealedPhotoBackupMigrationLatch`, `fernlet.sealedPhoto.hashVersionMigrationComplete` — one bit, no content), because the manifests it makes a claim about are destroyed by the same call; contrast `ownPhotoKeyMigrationComplete`, kept because its subject — the re-sealed local files — survives the wipe. Clearing the proof does **not** un-bind an already-bound own-photos key (that is one-way by design, and the row itself deliberately survives the wipe — see below); it only stops a torn-down route from satisfying the binding gate for a device that has not bound yet | CloudKit private DB (`SealedPhotoRecord`) + UserDefaults | `deleteOwnPhotoEscrowBackups` (runs BEFORE the preference reset that would gate it off, and needs no escrow key — deletion is by record name, so it works while locked) |
| Kept cloud copy | CloudKit | `cloudCopyDeleteHook` |
| Legacy direct-CloudKit records — the bare-named `FernletDatabaseRecord`, `MealLogRecord`, `JournalLogRecord`, `WorkoutLogRecord`, `HygieneLogRecord`, `HydrationLogRecord`, `SleepRecord`, `SavedRecipeRecord`, `CustomItemRecord`, `CoinLedgerRecord`, `MilestoneLedgerRecord`, `DayRecord` and `MenstrualNarrative` written by builds that talked to CloudKit directly. Content, not metadata | CloudKit private DB | `legacyCloudRecordDeleteHook` → `CloudKitDataService.deleteLegacyDirectCloudKitRecords`. UNCONDITIONAL, unlike every other cloud leg, and that is the point: the row above runs only on "stop syncing, keep the copy", and a LIVE sync deletes the server copy by *propagating* the local row deletes — which `NSPersistentCloudKitContainer` can only do for the `CD_`-prefixed types it wrote itself. A bare-named record has no local row to propagate from, so on the commonest configuration of all these survived the wipe with nothing left able to name them. Never touches a `CD_` type (the mirror owns those) or either sealed-backup namespace (their own legs, gated on the user's enable flags). A missing iCloud account is reported as a clean sweep — there is no database to reach and nothing the user could act on |
| Cycle narratives (sealed rows) | Private stores | `periodDataDeleteHook` |
| Intimacy logs (sealed rows) | Private stores | `intimacyDataDeleteHook` |
| Journal narratives (sealed rows) | Private stores | `journalDataDeleteHook` |
| Sealed store FILE (sqlite + `-wal`/`-shm` + the `_SUPPORT` external-blob dir) — the residue the row deletes above leave behind | `FernletPrivate` store on disk | `sealedStoreRebuildHook` (runs LAST in `resetAll`, after every sealed-row delete; keyless, so it works while locked) |
| Main (synced) store FILE residue — the page images of the day / recipe / custom-item / coin / milestone rows deleted above. SQLite only marks their pages free, and in WAL mode the database file still holds the PRE-delete images until a checkpoint | `Fernlet` Core Data store on disk (sqlite + `-wal`/`-shm`) | `mainStoreRebuildHook` → `PersistenceController.compactStoreAfterWipe`. Deliberately NOT the sealed store's destroy-and-re-add: this file carries the CloudKit mirror's pending export queue in its persistent history, so destroying it would discard the deletes that have not shipped yet, strand the server copy with nothing left able to address it, and let the fresh empty store import it all back. It checkpoints (`journal_mode=DELETE`) and vacuums (`NSSQLiteManualVacuumOption`) through the ordinary reload instead, which preserves the queue and the mirror metadata. **Honest limits, read the residuals section:** this is the *logical* residue only, and it is weaker than the sealed rebuild |
| Locked-note pending buffer. No migration latch stands beside it any more: the crypto-standardization round's Phase 3 deleted this surface's legacy reader and, with it, the Phase 2.4 format migrator — and its completion latch key with it — that healed for it | PendingNarrativeBuffer | `pendingNarrativeBufferPurgeHook` |
| HealthKit samples (opt-in) | HealthKit | `healthKitSampleDeleteHook` (the leg is opt-in behind the `includingHealthKitSamples` parameter — but the parameter name appears on the funnel's own signature line, so it never worked as a token; the hook's spelling appears only at the real call site) |
| Meal photos | PrivateMediaStore | `mealPhotoStore.deleteAll` |
| Progress photos | PrivateMediaStore | `progressPhotoStore.deleteAll` |
| Recipe photos | PrivateMediaStore | `recipePhotoStore.deleteAll` |
| Share-extension import queue | App group | `sharedRecipeImportQueue.clear` |
| Messages review inboxes — the recipe and workout-plan records the Messages extension enqueued for review. A card received before the wipe puts its VALIDATED packet here and leaves it until the containing app presents the review, so leaving either queue behind resurrects a full recipe or training plan into the emptied store. Cleared as a PAIR: `FernletMessagesRecipeInboxCoordinator.clear()` empties both `FernletMessagesInboxStore` and `FernletMessagesWorkoutInboxStore`, and `MessagesInboxCoordinatorTests` pins that it is both and not just the recipe half the type is named after. The un-consumed deep-link request (row below) is cleared FIRST in the same helper, because it is a pointer INTO these queues — reversing the order would leave a request naming a record that no longer exists | App group (`…/Inbox`) | `FernletMessagesRecipeInboxCoordinator` `.clear()`, reached through the private `clearMessagesImportInboxes` helper. The token is the COORDINATOR and deliberately not the helper's own name: the helper is registered in `wipeFunctionSignatures`, so its declaration line is inside the scanned text and a token spelled after it would match itself (the P1b self-satisfying-token defect class) |
| Messages App Group catalog — the bounded document the app PUBLISHES for the Messages extension: prebuilt recipe and workout-plan packets with their picker metadata, up to 100 of each. It lives in the same App Group and is readable by a process Messages hosts, so a surviving catalog leaves the composer offering recipes from a store the user just emptied. Cleared in leg 10 alongside the widget mirror, and for the same ordering reason: it runs AFTER the funnel's second `cancelPending`, so no debounced save can re-publish it moments later. Conditional on `messagesCatalogPublisher` being non-nil — the publisher is activated by the loaded app, so an install that never opened Messages sharing has no catalog to clear rather than a missing leg | App group | `messagesCatalogPublisher.clear` (a failure appends "Messages catalog" to the incomplete-stores list, so a surviving file cannot leave the dialog claiming a complete wipe) |
| Un-consumed Messages deep-link request — `fernlet.messages.pendingInboxDestination`, `fernlet.messages.pendingInboxID` and the legacy `fernlet.messages.pendingRecipeInboxID`: which queue a shared card landed in and the record id inside it. `consume()` removes them once the review is presented; a request that arrived and was never consumed would otherwise outlive the record it points at and have the next launch open a review for deleted content | UserDefaults (`.standard`, device-local) | `FernletMessagesRecipeImportRequest.clearPendingRequest` |
| Data export files — the "export my data" dump (`Fernlet-data-*.json`) AND the trainer/nutritionist summary (`Fernlet-training-*.json`) | tmp/DataExports (+ legacy tmp/-root strays of both prefixes) | `purgeDataExports` |
| Connection-history export — the proximity peer-identity dossier (display names, advertised/confirmed fingerprints, signing keys, first/last-seen times) written as `Fernlet-connection-logs-*.json`; builds before this change wrote it flat as lowercase `fernlet-connection-logs-*.json` | tmp/DataExports (+ legacy tmp/-root stray of that lowercase prefix) | `purgeDataExports` |
| Friends' clothing catalogs (1 h window) | Memory | `clothingShop.clearAll` |
| Session temp messages | Memory (SessionMessageStore) | `sessionMessages.clear` |
| Presence radio + discovery state | PresenceManager | `presenceManager.stop` |
| Diary + connection session logs | Snapshot | `resetDiary` |
| Custom exercise catalog (imported from a coach plan) — the persisted rows AND the process-global registry the picker / safety filter / planning engine read. Two surfaces, one row: `resetDiary` clears `settings.customExercises`, but `WorkoutExerciseCatalog`'s registry is process-global, so without the re-publish a deleted exercise stays live and searchable until the app is relaunched | Snapshot (`settings.customExercises`) + `WorkoutExerciseCatalog` (in-process) | `syncCustomExerciseCatalog` |
| Saved recipes (per-row) | Core Data/CloudKit | `savedRecipeService.reset` |
| Legacy saved-recipes JSON file — the pre-Core-Data `SavedRecipes.json`: plaintext recipe names, ingredients, notes, macros and source URLs on any install predating the migration | Application Support/Fernlet (disk) | `LegacySavedRecipeJSONRepository().deleteFile` (a missing file counts as success; the migration latch that survives the wipe — see the deliberate-exceptions table — means nothing re-reads the file, but until this call nothing deleted it either) |
| Custom items + clothing designs (per-row) | Core Data/CloudKit | `customItemService.reset` |
| Coin ledger (per-row) | Core Data/CloudKit | `coinLedgerService.reset` |
| Milestone ledger — the dated rows recording THAT a journal entry, meal, workout, breathing session, worry release or hydration day happened (kind + dayKey + timestamp; never any content), i.e. metadata about the very entries this funnel destroys | Core Data `MilestoneLedgerRecord` + its CloudKit private-database mirror | `milestoneLedgerService.reset` (the funnel narrows the service's `persistedStore` to `MilestoneLedgerRepository` for the row delete the protocol does not carry; the delete is object-by-object through the view context, which is what propagates it to iCloud — a batch delete would leave the cloud copies. In-memory counts and the pending-append queue are dropped in the same call). Reverses the pre-2026-08-20 product decision that milestone counts outlive a reset: "we deleted your journal and kept the dates you journaled" is not a wipe. **Sync-safe since 2026-08-21**, by the coin ledger's mechanism: the same call appends a `resetBoundary` marker row after the delete, and `MilestoneEconomy` counts and awards only rows whose day is at or after the marker's day AND whose `createdAt` is strictly after its instant — so event rows a second signed-in device was holding while offline raise no lifetime count and re-mint no milestone coin when they sync back into the emptied store. Both halves are load-bearing: the instant catches a threshold crossed earlier on the wipe day, and the DAY catches rows re-derived from a day record that came back (day records keep no tombstones, and a re-derived row carries a fresh reconcile-time timestamp, so the instant alone could never void it — the reconcile also refuses to mint for pre-boundary days at all). The delete is what honors the wipe; the marker is what makes it stick. The marker itself is never counted, displayed or awarded, and an app version that predates it drops just that row at decode (the store's per-row `try?`), which leaves the wiped device's own aggregation unaffected. **Two residuals, both shared with the coin ledger — see "Known residuals"** |
| AI retry queue | Disk | `aiRetryQueueService.reset` |
| Proximity trust vault (friends/blocks) | Snapshot + memory | `proximityTrustVault.apply` |
| Stress scoring local state | Disk | `scrubStressLocalState` |
| Worry Box rows, **and** the lifetime release counter `worryBox.lifetimeLetGoCount` | Sealed store + UserDefaults | `worryBoxResetHook` (`releaseAll()` sets the count to zero and the property's `didSet` writes that through, so the key survives holding 0 rather than being removed — cleared in the sense the dialog promises) |
| Heart ledger | JSON sidecar | `heartLedger.clearAll` |
| Moderation ledger | Sidecar | `moderationLedger.clearAll` |
| Friend fuzzy-state cache | Sidecar | `friendStateCache.clearAll` |
| Closeness ledger | Sidecar | `closenessLedger.clearAll` |
| Barcode serving memory | UserDefaults `fernlet.barcodeLastServings.v1` | `BarcodeServingMemory.clearAll` |
| Log-activity "Recent" chips — the last five workout types picked | UserDefaults `fernlet.recentActivityTypes` (`RecentActivityTypeMemory`, device-local, never synced) | `RecentActivityTypeMemory.clearAll` (plain UserDefaults removal — no failure signal) |
| Recipe web-image one-attempt memory | UserDefaults `fernlet.recipeWebImageAttempts.v1` | `RecipeWebImageAttemptMemory.clearAll` |
| Local food-search correction memory — the searches the user corrected once (normalized query → the food id they picked in "Adjust meal"), research §26 fix 1.10 | UserDefaults `fernlet.foodSearchCorrections.v1` (`FoodSearchCorrectionMemory`, device-local: never in the synced snapshot and never in CloudKit, but — like the two `UserDefaults` sidecars above — it rides an encrypted device backup and returns with a restore of this device; capped at 200 entries ≈ 17 KB, oldest evicted first) | `FoodSearchCorrectionMemory.clearAll` (plain UserDefaults removal — no failure signal), immediately followed by `foodCatalog.setSearchAliases` with an empty map, because the live catalog holds an in-memory copy of this surface that would otherwise keep answering corrected searches until relaunch. It also has its OWN user-facing clear — "Forget corrected searches" in Privacy & data (`FernletStore.forgetAllFoodSearchCorrections`), added because a correction is invisible, permanent and individually unremovable, so "delete everything" used to be the only way to unlearn one |
| Workout tombstone ring — up to 200 UUIDs of removed workouts whose app-authored Health delete never confirmed | UserDefaults `fernlet.workout.tombstones` (`WorkoutTombstoneStore`) | `workoutTombstones.clearAll` (correct for both Health answers: the delete path already removed the samples, the keep path wants re-import — a surviving tombstone would delete a kept sample on the next re-enable) |
| Group-activity rosters (persisted) | Sidecar | `activities.clearAll` |
| Guided-workout run state + Live Activity | App group + ActivityKit | `guidedRunStateStore.clear` |
| Cooking run state + Live Activity | App group + ActivityKit | `cookingRunStateStore.clear` |
| Sensitive-visibility resolution | UserDefaults (`SensitiveVisibilityKeys`, device-local, non-synced): `sensitiveVisibilityResolved`, `sensitiveVisibilityResolvedPeriodVisible`, `sensitiveVisibilityResolvedIntimacyVisible` — the store's injectable `sensitiveVisibilityDefaults`, `.standard` in production. This column said "Memory" until 2026-08-20; it was wrong, and the difference matters — a memory-only resolution could not survive a wipe, and these keys can | `clearSensitiveVisibilityResolution` |
| Age determination (intimacy 16+, mesh chat 13+) | UserDefaults `ageAssuranceRecord` | `ageAssurance.clear` |
| Day rows + blob + tier-two memories inside the blob, the local JSON day-blob FILE, **including each meal component's bind score and the web-nutrition consent/revocation decision**, and the pre-database `LegacyKeys` UserDefaults corpus — `fernlet-settings`, `fernlet-recent-meals`, `fernlet-previous-journals`, `fernlet-memories`, `fernlet-goals`, `fernlet-workshop`, and every interpolated `fernlet-day-<yyyy-MM-dd>` row, which holds journal + memory JSON UNSEALED in the preferences plist | Core Data/CloudKit/disk + UserDefaults (`.standard`) | `repository.purgeAllPersistedData` → `LocalFernletRepository.clearLegacyUserDefaultsIfPresent()`, run BEFORE the file-existence guard so the shipping Core Data configuration (which reaches the local repository with no JSON file at all) still clears it. Left behind, those keys both survive the wipe as plaintext AND re-hydrate the store on the next launch, because an absent database file is indistinguishable from a first launch and routes straight through the legacy migration |
| Widget snapshot files | App group | `widgetSnapshotMirror` |
| Pending widget actions | App group | `pendingWidgetActionQueue.clear` |
| AI daily-call quota | UserDefaults `fernlet.ai.quota.pair` | `aiCallQuotaStore.reset` |
| AI audit log (file + in-memory) | Disk | `aiAuditLogStore.clear` |
| Health capabilities ever requested — the record of which `HealthCapability` prompts Fernlet has ever shown, including **`cycleTracking` and `intimateLogging`** | Keychain `com.fernlet.healthkit-anchors`, account `fernlet.healthkit.requested-capabilities` (after-first-unlock, this-device-only, so it never rides a device backup and is not readable with `defaults read`). Installs predating 2026-08-20 also carry a plaintext `UserDefaults` array under the same key; reading the ledger drains it into the keychain and removes it | `HealthCapabilityRequestLedger.clear` (also called by `HealthKitService.disableIntegration`, so "turn Health off" clears it too). Deletes the ACCOUNT, never the service — the anchor rows in the same slot survive by design, see the deliberate-exceptions table |
| Companion petting state — pets counted in the current rolling window, when that window opened, when the settled period ends, and which settle already showed its soft line | UserDefaults `fernlet.companionPets.count`, `fernlet.companionPets.windowStart`, `fernlet.companionPets.cooldownUntil`, `fernlet.companionPets.settledLineShownFor` (`PetInteractionGovernor`, device-local, never synced) | `PetInteractionGovernor.clearPersistentState` (the method already existed; until 2026-08-20 its only caller was a `#if DEBUG` UI-test seam, so RELEASE never cleared it). Plain UserDefaults removals — no failure signal |
| **Proximity identity keypairs + backup-escrow keychain rows** | Keychain `com.fernlet.identity` (survives reinstall) | `wipeIdentityForDeleteAll` ×3 (mesh, presence, recipe share — each also drops its in-memory key cache) |
| **MC peer-identity archive** — the device name (in practice the user's own first name) plus the stable `MCPeerID` the mesh and recipe-share radios advertise | `Application Support/FernletPeerID.archive` | `wipeIdentityForDeleteAll` (mesh leg, via `FileMCPeerIDStore.clearForDeleteAll()`; the next radio start mints a fresh peer id, and a refusing file system now throws instead of leaving the identifier behind) |
| **A duress recovery-custodian enrollment the identity wipe just invalidated** | Keychain `com.fernlet.lock` — `.recoveryBlob`, both custodian public keys, the recorded owner key | `identityRotatedHook` → `DuressRecoveryCoordinator.reconcileEnrollmentWithLocalIdentity()`, fired immediately after the row above. The blob is sealed with THIS device's key-agreement key mixed into the derivation and the custodian opens it with the live one, so rotating the identity makes it unopenable by anybody — while the app lock, the content key and the enrollment rows all survive this funnel by design. Retiring it is what stops `DuressMode.recoveryLock` staying armed over a dead blob (firing it would destroy every local unlock key for a ceremony that can only fail); an armed `.recoveryLock` is rewritten to the non-destructive `.decoy` at the same moment. Also run at launch, as the backstop for a wipe whose process died first |
| Moderation peer-ban records (30-day bans of OTHER designers, keyed to their identity fingerprints; the record's subject field embeds the fingerprint too) | Keychain — service `com.fernlet.moderation`, `peerBan:` accounts (survives reinstall) | `moderationBanStore.clearPeerBansForDeleteAll` — removes ONLY `peerBan:` rows; the self-ban row in the same service is a deliberate survivor (see the exceptions table, 2026-07-17 decision) |
| Journal device key | Keychain `com.fernlet.journal` | `deviceJournalKey` delete |
| Worry device key | Keychain `com.fernlet.journal` | `deviceWorryKey` delete |
| Private-media in-memory key caches (the emptied meal/progress/recipe stores) | Memory | `invalidateEncryptionKeyCache` per store |
| Storage preferences | Keychain `com.fernlet.storage-preferences` | `storagePreferencesResetHook` |
| Away-hearts drop records this device uploaded | CloudKit **public** DB | `heartDropService.purgeDeadDrop` (must run BEFORE the local wipe — the outbox holds the record names, and a public-DB record is creator-delete-only) |
| Away-hearts drop state: one-time + signed prekeys (keychain `com.fernlet.heartdrop`, incl. the `sidecarSealKey` sidecar seal key — `deleteAll` is by service, all accounts), peer bundle cache, outbox **and its `HeartDropOutbox.json.corrupt` quarantine file**, durable dedup, service identity cache | Keychain + sidecars | `heartDropService.wipeForDeleteAll` (each sidecar's `ProtectedSidecar.wipe()` removes primary + quarantine paths) |
| **Symbolic seam** `unresolved:key@App/Fernlet/PetInteractionGovernor.swift` — the governor's own parameter-keyed `date(forKey:)` / `set(_:forKey:)` wrappers. Not a distinct key: every caller passes one of the four literals in the petting-state row above, and the discovery wall records the seam so it cannot vanish unnoticed | UserDefaults (device-local) | `PetInteractionGovernor.clearPersistentState` — the same call removes all four |
| **Symbolic seams** `unresolved:key@FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift` and `unresolved:$0@FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift` — the parameter-keyed `loadLegacy(_:key:)` reader and the closure-shorthand removal loop beside it. Not distinct keys: they are the legacy `LegacyKeys` corpus in the row above, seen at seams whose key expression this wall cannot resolve | UserDefaults (`.standard`, legacy corpus) | `repository.purgeAllPersistedData` → `clearLegacyUserDefaultsIfPresent()`, which removes exactly that fixed set plus the `fernlet-day-` prefix sweep |

(The `heartsAwayDelivery` consent flag itself lives in FernletSettings inside the snapshot — the
repository purge takes it.)

## Deliberate exceptions — surfaces that survive Delete everything BY DESIGN

| Surface | Why it survives | Its own exit |
| --- | --- | --- |
| App-lock keychain (`com.fernlet.lock`) | Losing data must not silently un-lock the app | Settings → "Reset app lock" (`FernletLockService.reset`), **or the unlock overlay itself** — its reset-required card, and (hard-bound installs whose enclave key is gone) its "sealed data can't be opened on this device" card, both call the same `reset()`. The second route is load-bearing: that state is not a failed attempt, so the reset-required card never appears in it, and the Settings button sits behind an `.appLockSettings` gate. **One further exit, added by Phase 7: the duress responses.** `DuressMode.silentWipe` destroys these rows plus the SE key, inverting this survivor rule — but only on that seam; `DuressMode.recoveryLock` destroys the same rows EXCEPT `.recoveryBlob` and the two custodian public keys, which are what make it recoverable rather than an erase. It is unreachable from `deleteAllData`: the call runs one way (the lock fires `duressPurgeHook` INTO the funnel; the funnel never calls back into the lock), so no non-duress path can trigger it, and `PrivacyWipeCoverageTests` still pins that the ordinary funnel keeps `com.fernlet.lock` |
| Friend photo wall (`deleteAllSessionPhotos` NOT called) | Product decision documented above `deleteAllData`: friends' shared photos are the friends' social gift, not the user's records | Manual per-photo delete |
| **Friend photo-wall index** — `MeshPhotoCache.sealed` (sender names, fingerprints, times for the kept wall) | Kept with the wall it indexes. As of 2026-08-20 it is AES-256-GCM sealed under the friend-wall media key (`…private-media.contentKey`) instead of the plaintext `MeshPhotoCache.json` it replaces — read once, rewritten sealed, then deleted. Sealing changes only what a container copy discloses, never what survives the wipe | Dies with the wall: the last per-photo delete leaves an empty index |
| **Friend photo-wall preferences** — `MeshPhotoWallPreferences.json` (aggregated-session ids, cover + favorite photo ids) | UUID-only bookkeeping ABOUT photos this funnel deliberately keeps — no names, no bytes, no timestamps. Clearing it would degrade the kept wall (covers and hearts lost) for no privacy gain, exactly like the photowall rotation-history row below | Pruned to the live wall on every load and mutation (`prunePhotoWallPreferences`); dies with the wall and the app container |
| **Private-media content key, friend wall (at-rest)** — keychain `com.fernlet.private-media` / account `…contentKey` | The row the photo wall above is encrypted with. Deleting it does not orphan a key — it shreds the wall: the next `mediaKey()` finds no row, mints a fresh random one, and every retained photo decrypts to garbage, permanently and silently. A key whose other stores were just emptied protects nothing extra, so keeping it discloses nothing. **Do not re-add a `deleteKeychainRowForWipe()` call to the funnel** — `PrivacyWipeCoverageTests` fails if you do | Dies with the wall: the last per-photo delete leaves it protecting nothing. **The duress WIPE is the one exception** (Phase 7 review fix): it sweeps the whole `com.fernlet.private-media` service, because its promise is that no sealed byte on the device stays openable |
| **Private-media content key, own photos (at-rest)** — keychain `com.fernlet.private-media` / account `…ownContentKey` | Security-hardening Phase 5 split the one shared media key in two: this second row seals the user's OWN meal / recipe / progress photos and the sealed progress index. Its STORES are wiped by this funnel (the three `…PhotoStore.deleteAll` rows in the cleared table above), so the surviving key protects nothing. It is kept for the same reason as the friend row: deleting it re-opens the stale-cache hazard — a photo captured between the wipe and the next relaunch would seal under an in-memory key whose row no longer exists, and read back as garbage after relaunch. Owner decision, 2026-08-11 | Dies with its stores: after the wipe it opens nothing. **Destroyed outright by the duress WIPE**, which cannot afford the same latency: the photo files are still on disk when the decoy appears, so the key has to be gone before it, not after |
| **Own-photo device-binding consent** — `UserDefaults` `com.fernlet.private-media.ownPhotoDeviceBindingConsent` (device-local, non-synced) | One bit: "the user accepted that their own photos are locked to this device" (step 5c). Kept for the same reason the row above is: the wipe empties the photo stores but leaves the key, so clearing the consent would silently *widen* custody for everything captured after the wipe — the next launch would find the gate unsatisfied and photos would go back to being backup-restorable without anyone deciding that. It records a custody preference, never content: no timestamps, no counts, nothing about any photo. (It is also one-way by design — nothing in the app withdraws it, because un-binding is a security regression the user could trigger by accident.) The migration latch beside it, `com.fernlet.private-media.ownPhotoKeyMigrationComplete`, is kept for the mirror-image reason: the files it describes were re-sealed under the own key, and clearing it would only force a pointless re-scan | Dies with the app container on uninstall / device reset |
| **Media at-rest format-migration latch** — `UserDefaults` `com.fernlet.private-media.mediaAtRestFormatMigrationComplete` (device-local, non-synced) | *Added with crypto-standardization Phase 2.3.* One bit: "a full sweep of the eight-location media surface proved no bytes remain that only `gcmOpen`'s legacy-read branch can open" (`MediaAtRestFormatMigrationLatch`). Kept, but NOT on the cleared format latches' "subject destroyed" reasoning nor on `ownPhotoKeyMigrationComplete`'s "files are destroyed" clause — that premise is false for three of its eight locations, because the friend wall (photos, thumbnails, sealed index) deliberately survives this funnel (`deleteAllSessionPhotos` NOT called; the rows above). The sound basis: the own corpora ARE emptied by the wipe, the surviving wall corpus was proven all-current-format (or named residue) before the latch could set, and every post-wipe writer emits the current format — so the latch's claim stays true of everything the wipe leaves behind, and clearing it would only force a pointless re-scan. It records a format fact, never content: no counts, no timestamps, nothing about any photo. (Contrast `fernlet.sealedPhoto.hashVersionMigrationComplete`, cleared because its subject — the cloud manifests — dies in the same call) | Dies with the app container on uninstall / device reset |
| ModerationBanStore self-ban — keychain `com.fernlet.moderation`, account `selfBan.device` | 2026-07-17 decision: a device ban must survive a wipe or a wipe is a ban-evasion tool. The PEER bans co-located in the same service are cleared (cleared-by table above) — the clear is account-prefix-scoped for exactly this reason, so never "simplify" it into a service-wide `deleteAll` | — |
| Install-binding ID — keychain `com.fernlet.device-binding` | 16 cryptographically random bytes minted per install and used only as AEAD associated data on sealed-column writes (`ColumnCrypto` v2 / `DeviceBindingID`). It identifies the INSTALL, never the person, and every ciphertext bound with it was just purged — so the surviving row discloses nothing and protects nothing extra. Deleting it mid-wipe would recreate the exact hazard the durably-stored-before-trusted mint guards against: the in-memory cache could seal post-wipe rows under an AAD no longer in the keychain, making them unopenable after relaunch. Data logged after the wipe simply re-binds under the same install ID | — (ThisDeviceOnly, never synchronized; a device reset or keychain wipe replaces it and the next seal mints a fresh one) |
| HealthKit anchor cursors — keychain `com.fernlet.healthkit-anchors` | Opaque `HKQueryAnchor` sync cursors, not health data: they record how far Fernlet has read, never what it read. Keeping them is what makes the wipe STICK — a reset cursor makes the next anchored query replay Fernlet's entire Health history back into the just-emptied day store | Turning HealthKit off (`HealthKitService.disableIntegration` → `HealthKitAnchorKeychain.deleteAll`) |
| Locked-note buffer device key — keychain `com.fernlet.narrative-buffer` (plus the service-less legacy `com.fernlet.buffer.key` account) | The buffer FILE it decrypts is purged by `pendingNarrativeBufferPurgeHook`, so the surviving key opens nothing live; it is re-used for the next note written while locked. **Asymmetry, flagged owner call (Opus track §12):** the journal and Worry Box device keys ARE deleted in the same funnel, and under the crypto-erasure baseline the difference now matters — the sealed store gets its file rebuilt, but the buffer is a plain file whose deleted bytes get no equivalent treatment, so the surviving key is what would keep any file-system residue of it openable. Deleting it in the funnel is the symmetric fix; it is deliberately NOT done here pending the owner's call | — |
| **Sealed-store divergence latches** — `UserDefaults` (device-local, non-synced): `fernlet.menstrualNarrative.everStored`, `fernlet.journalNarrative.everStored`, `fernlet.intimacyLog.everStored` | One bit each: "this install held cycle / journal / intimacy rows at some point". They must OUTLIVE the wipe — that is the whole mechanism. Every sealed repository's `deleteAll()` SETS its latch, so after "delete everything" the store reads empty-**and**-diverged; a sealed-backup chunk that survived a failed delete then cannot be restored back onto the device at the next launch. Clearing them here would make the wipe undoable by a stale cloud copy. They hold no user content — one boolean, no timestamps, no counts — and a genuine reinstall clears them for free when iOS drops the app container, which is exactly the "never populated" state a real new device should have | Dies with the app container on uninstall / device reset |
| **Phase-6 prior-use marker** — `UserDefaults` `com.fernlet.launch.priorUseRecorded` (device-local, non-synced) | One bit: "Fernlet has run on this install before" — `FernletPriorUseMarker`, the fresh-vs-existing input to the backup-exclusion launch gate (`BackupExclusionLaunchGate`). It must OUTLIVE the wipe for the same reason the divergence latches above do: the wipe's preference reset clears `backupExclusionChoiceMade`, so the next launch re-runs the gate — and with the marker cleared, that launch would classify a wiped-but-reused device as FRESH and silently adopt the excluded default over it, the exact silent flip the gate exists to prevent. Kept, the post-wipe launch shows the honest one-time prompt again (pinned by `BackupExclusionLaunchGateTests/priorUseMarkerSurvivesPreferenceResetSoPostWipeLaunchPromptsInsteadOfSilentlyFlipping`). It is a trace-of-use bit — one boolean, no timestamps, no counts — in the same class as the divergence latches, and it discloses nothing the surviving `hasCompletedOnboarding` key (which the gate ORs in as its legacy evidence) does not already | Dies with the app container on uninstall / device reset |
| **One-time workout backfill latch** — `UserDefaults` `fernlet.healthkit.workoutBackfillCompleted` (device-local, non-synced) | *Added to this table 2026-08-20 — it was in neither table before, and keeping it is not merely defensible, it is load-bearing.* One bit: "the 30-day Health workout backfill has run on this install" (`HealthKitAnchorKeychain.shouldRunWorkoutBackfill`). Exactly the HealthKit-anchor argument two rows up: clearing it makes the next launch re-import the trailing 30 days of Health workouts straight back into the just-emptied day store, and with sync on, re-upload them. It records that Fernlet read, never what it read | Dies with the app container on uninstall / device reset |
| **Saved-recipe legacy-migration latch** — `UserDefaults` `com.fernlet.savedRecipeMigrationCompleted` (device-local, non-synced) | *Added 2026-08-20.* One bit gating `SavedRecipeRepository`'s one-time JSON→Core Data migration, which fires only when the Core Data store is empty **and** the bit is unset. A wipe leaves the store empty by definition, so clearing the bit would re-run the migration on the next launch and resurrect every recipe still in the legacy JSON file. Same class as the two latches above: keeping it is what makes the wipe stick. No content, one boolean | Dies with the app container on uninstall / device reset |
| **Home photowall rotation history** — `UserDefaults` `fernlet.homePhotowall.previousPhotoIDs` (device-local, non-synced) | *Added 2026-08-20.* The ids of the friend photos the wall showed last launch, so it rotates instead of resurfacing the same faces (`PhotowallPhotoSelector`). It holds ids of photos on the **friend photo wall — which this funnel keeps by design** (see that row above), so clearing it would delete bookkeeping about data that is still there: not a privacy gain, just a worse wall next launch. It carries ids only — no names, no bytes, no timestamps — and it is overwritten wholesale on each selection. If the kept-photo-wall decision is ever reversed, this row must be reversed with it | Overwritten each launch; dies with the wall and with the app container |
| **App Intent pending-sheet token** — `UserDefaults` `fernlet.intent.pendingSheet` | *Added 2026-08-20.* Which sheet a Siri/Shortcuts intent asked the app to open (`"meal"`, …) plus the request time. Self-clearing on the ReplayCache pattern: `consume()` removes it on read whether or not it is honored, and anything older than a 120-second expiry window is discarded. It names a screen, never content, and cannot outlive the next launch | Consumed on read; expires after 120 s |
| **Appearance and tool preferences** — `UserDefaults`: `fernletAppearanceMode`, `fernletDarkModeEnabled` (legacy), `fernletCustomLightBackgroundHex`, `fernletCustomDarkBackgroundHex`, `fernlet.breathing.presetID`, `fernlet.breathing.minutes`, `fernlet.breathing.haptics` | *Added 2026-08-20 as a class, not one-by-one; every key spelled in full since the discovery wall matches on the literal.* How the app should look and how the breathing timer should be configured. These are settings, not records: they describe the app's chrome, hold nothing about the user's days, and clearing them would only hand someone who just deleted their data a suddenly-unfamiliar app. Named here so the tables stay a complete inventory — the contract is that every surface is *accounted for*, not that every surface is data | Changed in Settings; dies with the app container |
| **Onboarding completion** — `UserDefaults` `hasCompletedOnboarding` (`OnboardingDefaults`) | *Added 2026-08-20 by the discovery wall, which found it in neither table.* One bit: the first-run flow has been completed on this install. It survives so a wipe does not replay onboarding at someone who has been using the app for a year — and the backup-exclusion launch gate above ORs it in as its **legacy evidence of prior use**, so clearing it would help misclassify a wiped-but-reused device as fresh. No content, no dates, no counts | Dies with the app container on uninstall / device reset |
| **Deferred lock setup** — `UserDefaults` `lockSetupDeferred` (`OnboardingDefaults`) | *Added 2026-08-20 by the discovery wall, which found it in neither table.* One bit: the user chose "not now" at the onboarding app-lock step, so lockable features may prompt later. The app lock itself survives this funnel **by design** (first row of this table), so clearing this bit would re-nag about setting up a lock the device may already have. It records a UI decision, never content | Cleared by actually setting up the lock; dies with the app container |
| ReplayCache | Memory-only, self-expiring (24 h); dies with the process | — |
| Identity in OTHER devices' trust vaults | Friends' devices hold the OLD public key; nothing this device can delete remotely. The wipe breaks the pairing (new identity ≠ vault row), and friends see a stranger until re-friending in person | — |

### Symbolic key seams — bindings the discovery wall cannot resolve to a literal

*Added 2026-08-20 with the discovery wall; token spelling widened 2026-08-21.*
`PersistedSurfaceWipeBoundaryTests` resolves a key symbol against declarations in the **same file**.
These bindings name a constant declared in another file, so the key resolves in neither direction and
the wall records the *seam* instead — a token of the shape `unresolved:<expression>@<file>`, which
requires a disposition exactly like a literal key would. Nothing here is a new surface: each one is a
second view of a key already in the table above, listed so the seam itself cannot disappear
unnoticed, and so nobody has to guess what the `unresolved:` rows in that suite mean.

**The token carries the whole key expression and the file, and deliberately not the line.** Not the
line, because a line-keyed table breaks on every unrelated edit and teaches people to renumber the
wall instead of reading it. The whole expression, because the first spelling used only the
expression's LAST identifier — so `unresolved:storageKey@SettingsSheet.swift` silently covered any
future write in that file whose key was also spelled `…storageKey`, and the new surface inherited
this row's "kept" disposition without anybody deciding. Each seam additionally declares **how many
call sites** it accounts for (`expectedSeamSites`), so the same expression appearing at a second,
new site fails too.

| Seam token | The key it really is | Why it survives |
| --- | --- | --- |
| `unresolved:FernletAppearanceMode.storageKey@App/Fernlet/FernletApp.swift` | `fernletAppearanceMode` (constant declared in `FernletNavigation.swift`) | Appearance preference — see the appearance/tool row above |
| `unresolved:FernletAppearanceMode.storageKey@App/Fernlet/SettingsSheet.swift` | `fernletAppearanceMode`, same constant | Appearance preference — see the appearance/tool row above |
| `unresolved:FernletThemeDefaults.customLightBackgroundKey@App/Fernlet/ContentView.swift` | `fernletCustomLightBackgroundHex` (constant declared in FernletKit's `FernletTheme.swift`) | Appearance preference — see the appearance/tool row above |
| `unresolved:FernletThemeDefaults.customLightBackgroundKey@App/Fernlet/SettingsSheet.swift` | `fernletCustomLightBackgroundHex`, same constant | Appearance preference — see the appearance/tool row above |
| `unresolved:FernletThemeDefaults.customDarkBackgroundKey@App/Fernlet/ContentView.swift` | `fernletCustomDarkBackgroundHex`, same source | Appearance preference — see the appearance/tool row above |
| `unresolved:FernletThemeDefaults.customDarkBackgroundKey@App/Fernlet/SettingsSheet.swift` | `fernletCustomDarkBackgroundHex`, same source | Appearance preference — see the appearance/tool row above |
| `unresolved:OnboardingDefaults.hasCompletedOnboardingKey@App/Fernlet/FernletApp.swift` | `hasCompletedOnboarding` (constant declared in `OnboardingCoordinator.swift`) | Onboarding completion — see its own row above |
| `unresolved:OnboardingDefaults.hasCompletedOnboardingKey@App/Fernlet/BackupExclusionLaunchGate.swift` | `hasCompletedOnboarding`, read-only (the launch gate's legacy prior-use evidence) | Nothing here writes a key, so there is no surface to clear — recorded as `unreachableByDesign` |
| `unresolved:key@FernletKit/Sources/FernletUI/FernletTheme.swift` | A ternary over the two custom-background keys, read-only | Nothing here writes a key — recorded as `unreachableByDesign`; both keys it reads have rows above |

Three further `unresolved:` seams exist and are **cleared**, not kept, so they live with the funnel
rather than here: the `PetInteractionGovernor` and `LocalFernletRepository` parameter-keyed wrappers
and the legacy-corpus removal loop. They have their own rows in the cleared-by table above, naming
the funnel tokens `PetInteractionGovernor.clearPersistentState` and
`repository.purgeAllPersistedData`.

## Open gaps — surfaces the wipe does NOT reach, and should (found 2026-08-20)

These are **not** deliberate exceptions and are deliberately not written into the table above. Each
is a `UserDefaults`-backed surface that survives "Delete everything" because nothing clears it, not
because someone decided it should survive. They are listed here so the inventory is honest while
they are open; each one should either gain a wipe call plus a cleared-by row, or an owner decision
plus an exceptions row.

**This section IS enforced now, as of 2026-08-20.** `PersistedSurfaceWipeBoundaryTests` gives each of
these an `.openGap` disposition, and an `.openGap` row fails unless its key appears in the table
below — a fourth disposition added precisely so an unfixed defect never has to be filed under a
heading that says "BY DESIGN" to get a row. Closing one means moving it to the cleared-by table (with
its funnel token) or to the exceptions table (with an owner decision), in the same commit as the
disposition change.

**Three of the original four were closed on 2026-08-20** and have moved to the cleared-by table with
their tokens: the Health capability ledger (which also left plaintext `UserDefaults` for a
device-only keychain row), the workout tombstone ring, and the companion petting state. The
discovery wall then found two more of the same class, which is what a discovery floor is for.

**A third generation, 2026-08-27.** Adding `App/FernletMessagesExtension` to `scanRoots` — it holds
shipping Swift and was outside the wall entirely — surfaced the composer's `FernletMessages.lastRecipeID`
below, and the same sweep closed the three `fernlet.messages.pending*` keys into the cleared-by
table. The lesson is the one the scan-root check already encodes: a whole target can be missing from
the inventory without a single row looking wrong.

| Surface | What actually survives | Why it matters | Severity |
| --- | --- | --- | --- |
| **Day-summary backfill day key** — `fernlet.daySummary.lastRunKey` (`LaunchPreparationService`) | One `yyyy-MM-dd` key: the last day the once-per-day summary backfill ran | A date the app was used, surviving the deletion of every day it describes. No content, and its functional effect post-wipe is benign (the backfill simply skips today). Listed for completeness, and because "one harmless date" is how every one of these starts | **Low** |
| **Past-day journal scrub latch** — `pastDayJournalScrubVersion` (`FernletStore`) | One integer: the version of the one-time historical journal scrub (WI-1) that has completed on this install | *Found 2026-08-20 by the discovery wall.* Unlike the migration latches in the exceptions table, keeping this one is **not** load-bearing: post-wipe the store is empty, so a re-run would scrub nothing and set the flag again. It survives because nothing clears it, which is the definition of this section rather than of "by design" | **Low** |
| **Past-day journal scrub attempts** — `pastDayJournalScrubAttempts` (`FernletStore`) | A small counter: launches on which the scrub ran but at least one day's seal failed | *Found 2026-08-20 by the discovery wall.* Usually absent — it is removed whenever the scrub reaches a terminal state — but while present it is a trace of app use (and of sealing trouble) that the wipe does not reach. Same class and same fix as the row above | **Low** |
| **iMessage composer's last recipe** — `FernletMessages.lastRecipeID` (`FernletMessagesViewController`) | One recipe UUID: the card the user last picked in the Messages composer, remembered so the composer re-selects it | *Found 2026-08-27, when `App/FernletMessagesExtension` was added to `scanRoots` — it had been shipping Swift outside the wall since the extension landed.* Different from every row above in KIND: it is written to the extension's own `UserDefaults.standard`, a separate defaults domain from the containing app's, so the funnel cannot reach it at all. Closing it means first moving the key into the shared App Group suite — a decision nobody has made, which is what puts it here rather than in the exceptions table. It is a pointer to a recipe the wipe deletes, not recipe content | **Low** |

Two notes on scope, so this section is not read as bigger or smaller than it is. **The sealed
corpus is not implicated:** none of these keys holds journal, cycle, intimacy, Worry Box or photo
content — the sealed stores are covered by the cleared-by table and its rebuild leg. And they all
**die with the app container** on uninstall or device reset, so a genuine fresh start clears them; it
is the in-place "delete everything" — the path the dialog makes promises about — that misses them.

## The UserDefaults discovery wall

`Tests/FernletTests/PersistedSurfaceWipeBoundaryTests.swift` (round 2026-08-20, Part 4.4) is the
discovery half of this document. It walks the shipping sources — `App/Fernlet`,
`App/FernletWidgets`, `App/FernletShareExtension`, `FernletKit/Sources`, excluding tests and DocC
catalogs — finds every `UserDefaults`-backed persisted surface, and requires each one to carry
exactly one disposition: `.cleared` (naming a funnel token that is also in the manifest),
`.kept` (with a reason and a row in the exceptions table), `.unreachableByDesign`, or `.openGap`
(with a row in the section above). **A new defaults-backed store fails CI until somebody decides, in
writing, which of those it is.**

How it finds them: it anchors on the *binding*, not on a key prefix — `@AppStorage(…)` attributes,
`UserDefaults` accessors carrying a `forKey:` argument, and the KVC `setValue(_:forKey:)` spelling on
any receiver that is not one of Core Data's three (`object`, `record`, `request`, which together
account for all 62 KVC sites here). A `fernlet.*` grep would instead drown in mesh wire tokens and
`Notification.Name`s. A key resolves as an inline literal, an interpolated literal contributing a
`prefix*` **family** row, or a symbol *declared* with a literal in the same file — a `let`/`var`, an
enum `case`'s raw value, an initializer default argument, or a single-expression
`func … -> String { "…" }`. Anything left over becomes an `unresolved:<expression>@<file>` token that
still requires a disposition. **No key is ever dropped for being unresolvable, and no key is ever
guessed at** — a dropped key is precisely the invisible surface this wall exists to remove, and a
wrongly-named one is worse, because the table then certifies a wipe for a key that does not exist.

`#if DEBUG` is stripped on **both** sides: a DEBUG-only writer is not a shipping surface, and — the
half that matters more — a DEBUG-only clear cannot satisfy a `.cleared` row. That is not
hypothetical: `PetInteractionGovernor.clearPersistentState()` sat behind a `#if DEBUG` UI-test seam
for months, so RELEASE never cleared the companion petting state while a naive token scan would have
called it clean. The condition is *parsed*, not string-compared, because Power-of-10 R9's ban on
nested `#if` is exactly what forces this tree's own `#if DEBUG && canImport(UIKit)` spelling, and an
exact `== "DEBUG"` test read 272 lines of DEBUG-only code as shipping source.

### What it does not prove — the honest ceiling

Six limits, in descending order of how much they should worry you. The first three are inherent to a
text wall; nothing in CI closes them and the mitigations are conventions, not checks.

**1. Reachability is invisible — only the compile-time trap is closed.** Stripping `#if DEBUG` closes
the *compile-time* form of the petting-state trap. A clear gated on a runtime condition is textually
identical to an unconditional one: `if ProcessInfo.processInfo.arguments.contains("-UITEST") { … }`,
`if false { … }`, a feature flag, or an early `guard … else { return }` that returns before the clear
on the common path. All of them leave the token present, unconditional, in a scanned body — and never
run for the user. A grep wall structurally cannot evaluate a branch condition. **`DeleteAllDataTests`
is the only thing that can catch this**, which is why every `.cleared` row on a privacy-material
surface deserves a behavioural assertion there, and why that suite is not optional coverage.

**2. `.cleared` is one hop deep.** The token names a call *in the funnel*; the callee's body is not
scanned. `FernletStore.deleteOwnPhotoEscrowBackups()` is a single line delegating to
`OwnPhotoBackupCoordinator.tearDownForDeleteAll()`, and it is the token for three sealed-photo rows.
Deleting the two ledger `reset()` calls inside that callee, two files away, leaves **both** halves of
this wall green: the token is still called, and the writers that make the keys discoverable are
untouched, so nothing goes stale either. The rows in this position today are the three sealed-photo
ones, `repository.purgeAllPersistedData` and `ageAssurance.clear`. What *is* mechanical:
`unscannedWipePathCallees` pins the set of such hops, so moving a clear into a new unscanned leg fails
— including a leg spelled `func` or `private nonisolated func`, which the access-level enumeration in
`PrivacyWipeCoverageTests` walks straight past.

**3. One hop of indirection hides an unlimited number of keys.** A generic helper —
`enum Defaults { static func write(_ v: Any, _ key: String) { UserDefaults.standard.set(v, forKey: key) } }`
— or a custom `@UserDefault("…")` property wrapper puts every literal at a call site that is not an
anchor, where nothing looks. The helper's own seam needs one row; after that, every key routed through
it needs nothing, is never named in any table, and inherits that row's disposition. Following the hop
needs call-graph analysis a same-file text matcher cannot do. Partial mitigation: each seam declares
its call-site count (`expectedSeamSites`), so a seam that starts carrying *more* sites fails even
though the wall still cannot read them. The real control is a house rule — **no generic defaults
setter; keys are literals at the call site.**

**4. A survivor's reason is a floor, not a judgement.** `.kept`, `.unreachableByDesign` and
`.openGap` each require a reason of at least 40 characters and 8 words that is not padding, plus a
backticked table row here. That filters one-word non-answers and nothing more. Whether a kept surface
*must* survive is decided in review, on this document, by a person.

**5. Same-file resolution can still shadow.** A dotted key (`SecretKeys.storageKey`) resolves only if
this file declares `SecretKeys`, and only against `let`/`var`/`case`/parameter declarations — so a
constant from another file becomes a seam rather than binding to a same-named local. A *bare* symbol
has no qualifier to check, so a file-local binding that coincidentally shares its name with a global
declared elsewhere can still resolve to the wrong literal. Over-reporting is the designed direction
(every candidate is emitted), but this one case can under-report.

**6. Class coverage is `UserDefaults`, first-party, and these four roots.** Files on disk
(`MeshPhotoWallPreferences.json`, the tmp export staging directory, the share-extension import
queue), keychain accounts, Core Data entities, HealthKit and CloudKit namespaces are all outside it —
covered the old way, by the tables above and by review. It also covers **first-party sources only**:
an SPM dependency that writes `UserDefaults` of its own is invisible here, and the control for that
is `NoTrackingBoundaryTests`' dependency allowlist, which at least makes adding one a deliberate act.
`NSUbiquitousKeyValueStore` *is* seen (it carries the same `.set(_:forKey:)` spelling). The `App/`
scan roots are derived rather than trusted, so a new target cannot ship outside the frame; a `Tests`
directory or a `.docc` catalog holding shipping Swift under a root throws rather than being skipped.

**What was hardened on 2026-08-21.** Four adversaries attacked this wall; every evasion they found
was re-verified against the real code, and the ones that are not inherent ceilings are closed with a
planted fixture each. The classes
worth knowing, because they are the classes a *future* change reopens: KVC and receiver-less
(`extension UserDefaults`) writes are now discovered, and the *bulk* writes that name no key at all
(`setPersistentDomain`, `setValuesForKeys`, `setVolatileDomain`, `CFPreferencesSetAppValue`) are
banned outright, because there is no honest way to give a keyless write a row; whitespace spellings
the compiler accepts
without a diagnostic (`.set (`, `forKey :`, a block comment before the paren) no longer drop the call
silently; comment stripping is source-level and string-aware, so a `/* … */` span can neither hide a
write nor certify a deleted clear; `.cleared` now matches its token as a **call** in a
literal-blanked wipe path, refuses a token satisfiable by a registered function's own declaration
line, and must be **paired with its key on one table row of this document**; a family row covers only
families beneath it, must have been minted by discovery, and cannot be a wildcard; and any
preprocessor conditional at all inside the wipe path throws.

## Known residuals

- **The MAIN store's residue pass is weaker than the sealed store's, deliberately.** The sealed
  store is destroyed and re-created; the synced store is only checkpointed and vacuumed
  (`compactStoreAfterWipe`). The difference is not thoroughness, it is that this file carries the
  CloudKit mirror's pending export queue in its persistent history — destroying it would strand the
  server copy of deletes that have not shipped yet and let the fresh, empty store import them back,
  which is a resurrection, not a wipe. What that costs, stated plainly: the vacuum rebuilds the
  database file so freed pages are not carried forward, and `journal_mode=DELETE` checkpoints and
  removes the `-wal`, but neither is a guarantee about the physical flash blocks (APFS
  copy-on-write and wear-levelling — the same limit the sealed rebuild carries), and rows still
  queued for export are preserved on purpose. A failed compaction is reported as "leftover traces
  in your local records"; the ROWS are gone either way, because the purge runs first.
- **A failed wipe-time dead-drop purge is unrepairable, by design.** `purgeDeadDrop` runs before
  `wipeForDeleteAll`, but if the remote delete fails (offline, iCloud unavailable), the wipe still
  clears the outbox — so the record names needed to delete those public-DB records are gone and no
  retry can reach them. Keeping them would mean keeping recipient signing keys and sealed hearts
  across a "delete everything", which is a worse trade. The records age out on their own at the
  14-day sender lifetime. The user is told at the time ("hearts parked in iCloud" in the incomplete
  list) and again on every retry within that process; a relaunch clears the latch, because by then
  there is nothing left to act on.
- **The two append-only ledgers' reset boundary has two residuals, and they are identical for coins
  and milestones** (the milestone marker landed 2026-08-21; the coin one has always worked this way).
  Neither leaves the user's data on the device — the rows really are deleted — so neither is named in
  the delete dialog; both are about how well the wipe resists a SECOND signed-in device syncing back.
  - **The wipe DAY itself stays countable and earnable.** Rows are voided when their day is before
    the marker's day (or when they predate its instant), so content from earlier on the wipe day that
    re-syncs from another device can re-derive and count on that one day. Voiding the wipe day
    instead would permanently lock out genuine post-wipe care on the day the user wiped — the same
    trade `CoinEconomy` documents for `earn:<resetDay>`, made the same way.
  - **Marker durability is best-effort.** If the marker row's own write fails it survives only in the
    service's in-memory pending queue and is retried on the next debounced flush; a process death
    before that flush loses the boundary silently, because the fresh-launch load path does not
    re-merge pending rows. The wipe's reported verdict deliberately covers the row DELETE only —
    reporting an incomplete wipe because a boundary marker did not persist would tell the user their
    data survived when it did not. Fixing this belongs to both ledgers at once; it is open, not done.
  - (Same family, no fix: a marker stamped by a badly future-set device clock voids events until that
    instant. Inherent to instant-based boundaries without a trusted clock.)
- The `invalidateCachedKey` calls are now hygiene, not a correctness requirement: with the shared
  key row kept, a provider holding a stale in-memory copy holds the SAME key the keychain still has,
  so a photo captured between wipe and relaunch stays readable either way. (They earned their keep
  when the funnel deleted the row: back then a slipped-through write encrypted under a key nothing
  could read again, surfacing as `.unreadable`.)
- iCloud keychain sync propagates the escrow-row deletion to the user's other devices; their sealed
  backups were already deleted account-wide in step 2, and the escrow reconcile flow (WS-3) re-mints
  non-silently on next enable, so nothing is stranded.

## Audit trail

- **2026-08-21 — the discovery wall was attacked and hardened (round Part 4.4, adversary pass).**
  Four independent adversaries wrote working evasions against the wall built the day before, and
  every one was re-verified against the real code before it was acted on. Everything that could be
  closed mechanically was, each with a
  planted fixture, and the three that cannot be — runtime-gated clears, the one-hop `.cleared`
  callee, and indirection through a generic defaults helper — are written down as ceilings in "What
  it does not prove" above rather than left implied. What changed in this document, as opposed to in
  the suite: every `.cleared` row now has to name its **key and its wipe token on the same table
  row** here, which is why ten rows in the cleared-by table gained the literal key they clear (and
  two rows were added for the cleared symbolic seams). Before that, `.cleared` was the only
  disposition with no key-side obligation at all — one line naming any of the 63 existing manifest
  tokens marked any brand-new surface as wiped. Two further doc-shaped holes closed with it: the
  `.kept` / `.openGap` documentation check was a substring search over 18 KB of prose (satisfied by
  any key that is a prefix of existing text, and by `*` in 134 places) and is now a backticked span
  on a real table row; and `.unreachableByDesign`, previously the cheapest cell on the board — no
  length floor, no doc row — now carries the same burden as `.kept`.
- **2026-08-20 — the `UserDefaults` discovery wall (round Part 4.4).** The enforcement hole the
  entry below describes is now closed for one whole class of surface.
  `Tests/FernletTests/PersistedSurfaceWipeBoundaryTests.swift` discovers every defaults-backed
  surface in the shipping sources (370 files, ~52 surfaces today) and requires a disposition for
  each. Details in "The UserDefaults discovery wall"; three things worth recording here:
  - **It is the first mechanical check that the wipe COVERS anything**, rather than that it has not
    lost a call it already makes. Both directions of the older check remain, and both walls resolve
    against one shared definition of the wipe path (`PrivacyWipeCoverageTests.wipePathSource()`), so
    they cannot certify different funnels.
  - **`#if DEBUG` is stripped on both sides**, which is what stops a DEBUG-only clear satisfying a
    "cleared" claim — the exact shape of the companion-petting defect fixed earlier the same day.
  - **Two new open gaps, found by the wall itself and NOT laundered.** `pastDayJournalScrubVersion`
    and `pastDayJournalScrubAttempts` were in neither table; both are Low and both are recorded in
    the Open gaps section rather than the exceptions table, because nobody has decided they should
    survive. Five surfaces that WERE by-design survivors gained proper exceptions rows in the same
    commit (onboarding completion, deferred lock setup, and the fully-spelled breathing/own-photo
    keys), plus the new symbolic-seam subsection for bindings whose key constant lives in another
    file.

- **2026-08-20 — coverage round (the fixes for the sweep below, plus four surfaces it did not
  reach).** Eleven new cleared-by rows and their tokens, in one commit with the calls:
  - **Three of the four open gaps closed.** The Health capability ledger (moved out of plaintext
    `UserDefaults` into a device-only keychain row and cleared by both the wipe and "turn Health
    off"), the workout tombstone ring, and the companion petting state.
  - **Four surfaces that were in neither table and that the wipe never reached.** The legacy
    `SavedRecipes.json` file (plaintext recipe text), the Log-activity Recent chips, the
    pre-database `LegacyKeys` `UserDefaults` corpus — which held unsealed journal and memory JSON
    in the preferences plist *and* re-hydrated the store on the next launch, so it survived the
    wipe twice over — and the moderation PEER bans (data about other people, keyed to fingerprints
    the wipe's identity rotation disowns; the self-ban beside them still survives by the 2026-07-17
    decision).
  - **Two product decisions reversed, both because the surviving data described the destroyed
    data.** The milestone ledger is now cleared: a dated trail of when you journaled is not a
    celebration once the journal is gone, and it mirrored to iCloud. And the legacy direct-CloudKit
    record types are now torn down UNCONDITIONALLY — the previous gating meant a user on live sync
    kept meal / journal / workout / hygiene / hydration / sleep records on the server forever,
    because `NSPersistentCloudKitContainer` can only propagate deletes for the `CD_`-prefixed types
    it wrote itself.
  - **The main store gained a residue pass** (`mainStoreRebuildHook` → `compactStoreAfterWipe`),
    the counterpart of the sealed store's rebuild, by checkpoint + vacuum rather than destroy — see
    "Known residuals" for why, and for exactly what it does and does not claim.
  - **Two enforcement gaps closed.** The token scan now also covers
    `ContentView.attachDeleteAllHooks` / `attachCloudDeleteAllHooks`, where several real clears
    live inside hook closures a `FernletStore`-bounded scan could never see; and
    `everyPrivateWipeHelperIsRegistered` requires every private helper the wipe path calls to be
    registered, which was the bounding's own escape hatch (move a banned call into an unregistered
    leg and `wipePathMakesNoBannedCall` never looks at it).
  - **One correction, not a change.** The "Sensitive-visibility resolution" row said its data lived
    in "Memory". It lives in three `UserDefaults` keys. The call was always right; the column was
    wrong, and wrong in the direction that understates what survives a wipe.

- **2026-08-20 — doc-accuracy sweep (documentation only; no code changed).** A full walk of every
  `UserDefaults`-backed surface in `App/` and `FernletKit/Sources/` against these tables found
  **eight keys/key-families in neither table**, which means the completeness contract as previously
  worded had quietly stopped being true. Four were genuine by-design survivors and are now rows in
  the deliberate-exceptions table with their reasons (the one-time workout-backfill latch, the
  saved-recipe legacy-migration latch, the photowall rotation history, the self-expiring App Intent
  sheet token), plus one class row covering the appearance/breathing preferences so the inventory is
  complete. **Four are real gaps** — the wipe does not reach them and nobody decided it shouldn't —
  and they are recorded in the new "Open gaps" section rather than absorbed into the exceptions
  table, because writing an unfixed defect into a table headed "BY DESIGN" is how a privacy doc
  starts lying. The most serious is `fernlet.healthkit.requested-capabilities`, which retains
  `cycleTracking` / `intimateLogging` markers in plaintext through both a full wipe and a HealthKit
  opt-out. The contract paragraph at the top of this document has been corrected: what the suite
  enforces is doc↔manifest correspondence over the cleared table, plus a discovery floor for
  keychain services only. There is no discovery floor for defaults keys, so this class of gap is
  invisible to CI — which is why it went unnoticed and why the correction is written at the top
  rather than buried here. *(Superseded the same day by the entry above: three of those four gaps —
  including `fernlet.healthkit.requested-capabilities` — are now closed and sit in the cleared-by
  table. This entry is left as written because it is the record of what was found, not a live
  description of the app.)*

- **2026-08-11 — security-hardening P6 (backup-exclusion launch gate).** One new device-local
  `UserDefaults` bit is added — `com.fernlet.launch.priorUseRecorded` (`FernletPriorUseMarker`) —
  and it joins the deliberate-exceptions table rather than the cleared table: it must survive
  "delete everything" so the next launch re-runs the gate as an EXISTING install and shows the
  honest one-time prompt, instead of silently re-adopting the excluded default over a
  wiped-but-reused device. No new wipe call, no new token, no manifest change, and no new keychain
  service (the gate reads the existing `com.fernlet.storage-preferences` blob — whose PRESENCE it
  also treats as prior-use evidence, so a keychain-surviving reinstall classifies as existing too).
  The delete dialog's "Kept on purpose" copy is deliberately unchanged: like the divergence
  latches and the binding-consent bit before it, the marker records no user data — this doc row is
  the disclosure. Enforcement note: the funnel-bounded token scan structurally cannot catch a KEPT
  key (a kept key never appears in the wipe bodies), and there is no discovery floor for
  UserDefaults keys the way there is for keychain services — so
  `PrivacyWipeCoverageTests/theWipeSurvivingPriorUseMarkerIsDocumentedAsADeliberateException` pins
  this row per-key.

- **2026-08-11 — security-hardening P5 (own-photo device binding, step 5c).** The own-photos key row
  is now re-bound to `AfterFirstUnlockThisDeviceOnly` once its gate holds. **No new wipe token, and
  that is deliberate:** the flip changes a keychain row's *accessibility*, not what exists, and the
  row itself was already a documented deliberate exception (it is kept, its stores are emptied). One
  new device-local `UserDefaults` bit is added — the binding consent — and it joins the
  deliberate-exceptions table rather than the cleared table, because clearing it would silently
  widen custody for photos captured after the wipe. Nothing in this step writes to iCloud; the
  own-photo escrow teardown from 5b is unchanged and still covered by `deleteOwnPhotoEscrowBackups`.

- **2026-08-11 — security-hardening P5 (own-photo escrow route, step 5b).** A new opt-in backup was
  added: one sealed CloudKit record per own photo (`SealedPhotoRecord`, names
  `sealed-photo.<corpus>.<photoId>`) plus a sealed manifest per corpus. It is deliberately NOT a
  `SealedBackupPayloadType` case — delete-all and the settings toggles iterate `allCases` and would
  route photos through the chunked-blob path — so it gets its OWN cleared-by row and its own token
  (`deleteOwnPhotoEscrowBackups`) rather than riding the "Sealed iCloud backups" row. Two more
  consequences, neither needing a new token: `SealedBackupGenerationStore.reset()` now also clears
  the photo-namespaced high-water marks (same `generationStore.reset` call site), and
  `StoragePreferences.hasSealedBackup` ORs in `sealedBackupOwnPhotosEnabled`, so the delete dialog
  may truthfully claim to remove the iCloud copy of a user who only turned the photo backup on. The
  LOCAL photo stores were already wiped (the three `…PhotoStore.deleteAll` rows) and are unchanged;
  the own-photo KEY row stays a documented deliberate exception, per the owner decision recorded in
  that table.

- **2026-08-10 — security-hardening P3 (backup coverage).** Two sealed-backup payload types were
  added (`journalNarratives`, `intimacyLogs`). The cleared-by table's "Sealed iCloud backups" row
  covers them without a new token: the wipe loops `SealedBackupPayloadType.allCases`, so
  `setSealedBackupEnabled(false, …)` reaches every payload the user enabled, and
  `SealedBackupGenerationStore.reset()` (row above it) clears every payload's high-water mark the same
  way — both verified by `SealedBackupRollbackTests` walking `allCases`. Two device-local
  `UserDefaults` divergence latches were added beside the existing menstrual one and are recorded in
  the deliberate-exceptions table: they must survive the wipe, and the reason is spelled out there.
  No new wipe call, no new token, no manifest change.

  **P3 review fixes (same day).** Two additions the wipe now makes, neither of which needs a manifest
  token: (a) the per-payload re-upload deferrals are cleared over `allCases` rather than period-only,
  so no payload keeps an obligation pointing at a backup the wipe deleted; (b) the intimacy un-hide
  settle joins the period one in the cancel-the-live-writers step, so a settle suspended in its
  CloudKit fetch cannot resume after the wipe and re-insert logs. Both covered by
  `DeleteAllDataTests`. Separately, the preference reset's `keepSealedBackupFlags` branch now copies
  every payload flag through `StoragePreferences.copySealedBackupFlags(from:)` — the open-coded copy
  in `ContentView` had silently dropped the two new flags, which would have abandoned their CKRecords
  after a failed delete (`hasSealedBackup` false → no retry, and no later wipe, ever finds them).

- **2026-08-10 — security-hardening P1b, against the post-P1a tree (merge `aaa4aac`).** Full walk of
  the comment-stripped `deleteAllData` + `resetAll` bodies — including the hooks they invoke and the
  P1a additions: `sealedStoreRebuildHook`, and `FernletLockService.reset()`'s
  `sealedContentKeyServices` sweep on its own path — against this doc's cleared-by table and the
  test's `wipeManifest`, in BOTH directions. Result: every funnel call that clears a user-data
  surface has a doc row and an enforced token; every row's token resolves to a real, reachable,
  production-wired call; and the deliberate-exceptions table cross-checks clean — each survivor
  (`com.fernlet.lock`, `com.fernlet.private-media`, `com.fernlet.moderation`,
  `com.fernlet.device-binding`, `com.fernlet.healthkit-anchors`, `com.fernlet.narrative-buffer`,
  MilestoneLedger, the friend photo wall) is present, justified, and genuinely untouched by the
  funnel bodies. *(2026-08-20 update: two of those survivors have since changed deliberately — the
  MilestoneLedger exception was reversed and the ledger is now cleared, and `com.fernlet.moderation`
  is now split: peer-ban rows are cleared, only the shop self-ban survives. The live cleared-by and
  exceptions tables above are authoritative; this paragraph records the P1a audit as it stood.)* Three gaps found and closed (the first two in the audit commit, the third — the
  same defect class, caught by a same-day review pass over the sign-off — in the review-fix commit):
  (1) the `SealedBackupGenerationStore` row's token had no manifest entry and could never have
  matched the two-line call site — re-tokened `generationStore.reset` and enforced; (2) the doc-sync
  test checked manifest→doc only, so a documented-but-unenforced row was invisible — the reverse
  direction is now enforced by `everyDocumentedWipeRowIsEnforcedByTheManifest`; (3) the HealthKit
  row's token `deleteHealthSamples` matched only the funnel's own signature/condition/audit-log
  lines — never the actual `healthKitSampleDeleteHook?()` call — so the row was unfalsifiable (no
  edit short of renaming the parameter could fail it); re-tokened `healthKitSampleDeleteHook`, whose
  spelling appears in the bounded bodies only at the real call site. Scope of this sign-off: doc ↔ funnel
  correspondence ONLY. What "cleared" means — and the tier of promise each path may claim — stays
  defined by the sections above; nothing here upgrades those claims.

# Privacy wipe coverage

**Contract:** every persistence surface in the app appears in exactly one of the two tables below —
either it is cleared by "Delete everything" (`FernletStore.deleteAllData`), or it is a documented
deliberate exception. `FernletTests/PrivacyWipeCoverageTests.swift` enforces the first table
mechanically: it scans the wipe path for one token per row, so removing a wipe call (or adding a
store without wiring + documenting it) fails the suite. **Adding a store = add its wipe call, a row
here, and its token in the test — in the same commit.**

The scan is bounded to the BODIES of `deleteAllData` and `resetAll` (the wipe's one delegated leg),
with comments stripped. A whole-file scan used to satisfy a row from an unrelated function — the
same call spelled somewhere else in the 4,000-line store — so a deleted wipe call could keep the
suite green while the wipe was broken.

Every keychain service the app uses is named in one of the tables, so a `grep -r 'com\.fernlet\.'`
over the sources and the two tables below return the same set.

Pattern borrowed from bitchat's `privacy-assessment.md` panic-wipe checklist (bitchat adoptions
Increment 1, Docs/Plan-Bitchat-Adoptions-2026-07-25.md).

## Cleared by Delete everything

Ordering matters — pending saves are cancelled first and re-cancelled after `resetAll()`, the
repository purge runs late, widget files last. See the numbered commentary inside `deleteAllData`.

| Surface | Where it lives | Wiped by (token) |
| --- | --- | --- |
| Pending debounced snapshot saves | SnapshotSaveCoordinator | `snapshotSaveCoordinator.cancelPending` (start AND after purge) |
| Sealed iCloud backups (all payload types) | CloudKit private DB | `setSealedBackupEnabled` |
| Kept cloud copy | CloudKit | `cloudCopyDeleteHook` |
| Cycle narratives (sealed rows) | Private stores | `periodDataDeleteHook` |
| Intimacy logs (sealed rows) | Private stores | `intimacyDataDeleteHook` |
| Journal narratives (sealed rows) | Private stores | `journalDataDeleteHook` |
| Locked-note pending buffer | PendingNarrativeBuffer | `pendingNarrativeBufferPurgeHook` |
| HealthKit samples (opt-in) | HealthKit | `deleteHealthSamples` |
| Meal photos | PrivateMediaStore | `mealPhotoStore.deleteAll` |
| Progress photos | PrivateMediaStore | `progressPhotoStore.deleteAll` |
| Recipe photos | PrivateMediaStore | `recipePhotoStore.deleteAll` |
| Share-extension import queue | App group | `sharedRecipeImportQueue.clear` |
| Data export files | Documents | `purgeDataExports` |
| Friends' clothing catalogs (1 h window) | Memory | `clothingShop.clearAll` |
| Session temp messages | Memory (SessionMessageStore) | `sessionMessages.clear` |
| Presence radio + discovery state | PresenceManager | `presenceManager.stop` |
| Diary + connection session logs | Snapshot | `resetDiary` |
| Saved recipes (per-row) | Core Data/CloudKit | `savedRecipeService.reset` |
| Custom items + clothing designs (per-row) | Core Data/CloudKit | `customItemService.reset` |
| Coin ledger (per-row) | Core Data/CloudKit | `coinLedgerService.reset` |
| AI retry queue | Disk | `aiRetryQueueService.reset` |
| Proximity trust vault (friends/blocks) | Snapshot + memory | `proximityTrustVault.apply` |
| Stress scoring local state | Disk | `scrubStressLocalState` |
| Worry Box rows | Sealed store | `worryBoxResetHook` |
| Heart ledger | JSON sidecar | `heartLedger.clearAll` |
| Moderation ledger | Sidecar | `moderationLedger.clearAll` |
| Friend fuzzy-state cache | Sidecar | `friendStateCache.clearAll` |
| Closeness ledger | Sidecar | `closenessLedger.clearAll` |
| Barcode serving memory | UserDefaults | `BarcodeServingMemory.clearAll` |
| Group-activity rosters (persisted) | Sidecar | `activities.clearAll` |
| Guided-workout run state + Live Activity | App group + ActivityKit | `guidedRunStateStore.clear` |
| Cooking run state + Live Activity | App group + ActivityKit | `cookingRunStateStore.clear` |
| Sensitive-visibility resolution | Memory | `clearSensitiveVisibilityResolution` |
| Day rows + blob + legacy JSON (+ tier-two memories inside the blob) | Core Data/CloudKit/disk | `repository.purgeAllPersistedData` |
| Widget snapshot files | App group | `widgetSnapshotMirror` |
| Pending widget actions | App group | `pendingWidgetActionQueue.clear` |
| AI daily-call quota | UserDefaults | `aiCallQuotaStore.reset` |
| AI audit log (file + in-memory) | Disk | `aiAuditLogStore.clear` |
| **Proximity identity keypairs + backup-escrow keychain rows** | Keychain `com.fernlet.identity` (survives reinstall) | `wipeIdentityForDeleteAll` ×3 (mesh, presence, recipe share — each also drops its in-memory key cache) |
| Journal device key | Keychain `com.fernlet.journal` | `deviceJournalKey` delete |
| Worry device key | Keychain `com.fernlet.journal` | `deviceWorryKey` delete |
| Private-media in-memory key caches (the emptied meal/progress/recipe stores) | Memory | `invalidateEncryptionKeyCache` per store |
| Storage preferences | Keychain `com.fernlet.storage-preferences` | `storagePreferencesResetHook` |
| Away-hearts drop records this device uploaded | CloudKit **public** DB | `heartDropService.purgeDeadDrop` (must run BEFORE the local wipe — the outbox holds the record names, and a public-DB record is creator-delete-only) |
| Away-hearts drop state: one-time prekeys (keychain `com.fernlet.heartdrop`), peer bundle cache, outbox, durable dedup, service identity cache | Keychain + sidecars | `heartDropService.wipeForDeleteAll` |

(The `heartsAwayDelivery` consent flag itself lives in FernletSettings inside the snapshot — the
repository purge takes it.)

## Deliberate exceptions — surfaces that survive Delete everything BY DESIGN

| Surface | Why it survives | Its own exit |
| --- | --- | --- |
| App-lock keychain (`com.fernlet.lock`) | Losing data must not silently un-lock the app | Settings → "Reset app lock" (`FernletLockService.reset`) |
| MilestoneLedger | Documented product decision at the `resetAll` comment — celebrations aren't "data about you" in the deletable sense; repository has no delete API | — |
| Friend photo wall (`deleteAllSessionPhotos` NOT called) | Product decision documented above `deleteAllData`: friends' shared photos are the friends' social gift, not the user's records | Manual per-photo delete |
| **Private-media content key (shared, at-rest)** — keychain `com.fernlet.private-media` | The row the photo wall above is encrypted with. It is ONE key behind every `PrivateMediaStore`, so deleting it does not orphan a key — it shreds the wall: the next `mediaKey()` finds no row, mints a fresh random one, and every retained photo decrypts to garbage, permanently and silently. A key whose other stores were just emptied protects nothing extra, so keeping it discloses nothing. **Do not re-add a `deleteKeychainRowForWipe()` call to the funnel** — `PrivacyWipeCoverageTests` fails if you do | Dies with the wall: the last per-photo delete leaves it protecting nothing |
| ModerationBanStore self-ban — keychain `com.fernlet.moderation` | 2026-07-17 decision: a device ban must survive a wipe or a wipe is a ban-evasion tool | — |
| HealthKit anchor cursors — keychain `com.fernlet.healthkit-anchors` | Opaque `HKQueryAnchor` sync cursors, not health data: they record how far Fernlet has read, never what it read. Keeping them is what makes the wipe STICK — a reset cursor makes the next anchored query replay Fernlet's entire Health history back into the just-emptied day store | Turning HealthKit off (`HealthKitService.disableIntegration` → `HealthKitAnchorKeychain.deleteAll`) |
| Locked-note buffer device key — keychain `com.fernlet.narrative-buffer` (plus the service-less legacy `com.fernlet.buffer.key` account) | The buffer FILE it decrypts is purged by `pendingNarrativeBufferPurgeHook`, so the surviving key opens nothing; it is re-used for the next note written while locked. Deleting it would be symmetric with the journal/worry device keys and is a fine follow-up, but nothing leaks while it stays | — |
| ReplayCache | Memory-only, self-expiring (24 h); dies with the process | — |
| Identity in OTHER devices' trust vaults | Friends' devices hold the OLD public key; nothing this device can delete remotely. The wipe breaks the pairing (new identity ≠ vault row), and friends see a stranger until re-friending in person | — |

## Known residuals

- **A failed wipe-time dead-drop purge is unrepairable, by design.** `purgeDeadDrop` runs before
  `wipeForDeleteAll`, but if the remote delete fails (offline, iCloud unavailable), the wipe still
  clears the outbox — so the record names needed to delete those public-DB records are gone and no
  retry can reach them. Keeping them would mean keeping recipient signing keys and sealed hearts
  across a "delete everything", which is a worse trade. The records age out on their own at the
  14-day sender lifetime. The user is told at the time ("hearts parked in iCloud" in the incomplete
  list) and again on every retry within that process; a relaunch clears the latch, because by then
  there is nothing left to act on.
- The `invalidateCachedKey` calls are now hygiene, not a correctness requirement: with the shared
  key row kept, a provider holding a stale in-memory copy holds the SAME key the keychain still has,
  so a photo captured between wipe and relaunch stays readable either way. (They earned their keep
  when the funnel deleted the row: back then a slipped-through write encrypted under a key nothing
  could read again, surfacing as `.unreadable`.)
- iCloud keychain sync propagates the escrow-row deletion to the user's other devices; their sealed
  backups were already deleted account-wide in step 2, and the escrow reconcile flow (WS-3) re-mints
  non-silently on next enable, so nothing is stranded.

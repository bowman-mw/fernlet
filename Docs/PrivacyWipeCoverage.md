# Privacy wipe coverage

**Contract:** every persistence surface in the app appears in exactly one of the two tables below —
either it is cleared by "Delete everything" (`FernletStore.deleteAllData`), or it is a documented
deliberate exception. `FernletTests/PrivacyWipeCoverageTests.swift` enforces the first table
mechanically: it scans the wipe path for one token per row, so removing a wipe call (or adding a
store without wiring + documenting it) fails the suite. **Adding a store = add its wipe call, a row
here, and its token in the test — in the same commit.**

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
| Private-media content key (shared, at-rest) | Keychain `com.fernlet.private-media` | `deleteKeychainRowForWipe` + `invalidateEncryptionKeyCache` per store |
| Storage preferences | Keychain | `storagePreferencesResetHook` |

Coming with bitchat adoptions Increment 3 (add tokens + rows in the same commit that lands the
stores): heart-drop one-time prekeys (keychain), heart-drop outbox (sealed sidecar), heart-drop
durable dedup (sidecar), `heartsAwayDelivery` consent setting.

## Deliberate exceptions — surfaces that survive Delete everything BY DESIGN

| Surface | Why it survives | Its own exit |
| --- | --- | --- |
| App-lock keychain (`com.fernlet.lock`) | Losing data must not silently un-lock the app | Settings → "Reset app lock" (`FernletLockService.reset`) |
| MilestoneLedger | Documented product decision at the `resetAll` comment — celebrations aren't "data about you" in the deletable sense; repository has no delete API | — |
| Friend photo wall (`deleteAllSessionPhotos` NOT called) | Product decision documented above `deleteAllData`: friends' shared photos are the friends' social gift, not the user's records | Manual per-photo delete |
| ModerationBanStore self-ban | 2026-07-17 decision: a device ban must survive a wipe or a wipe is a ban-evasion tool | — |
| ReplayCache | Memory-only, self-expiring (24 h); dies with the process | — |
| Identity in OTHER devices' trust vaults | Friends' devices hold the OLD public key; nothing this device can delete remotely. The wipe breaks the pairing (new identity ≠ vault row), and friends see a stranger until re-friending in person | — |

## Known residuals

- Between wipe and relaunch, a freshly captured photo could theoretically encrypt under a stale
  in-memory media key — mitigated by `invalidateCachedKey` on every live provider; a slipped-through
  write surfaces as `.unreadable`, never as plaintext.
- iCloud keychain sync propagates the escrow-row deletion to the user's other devices; their sealed
  backups were already deleted account-wide in step 2, and the escrow reconcile flow (WS-3) re-mints
  non-silently on next enable, so nothing is stranded.

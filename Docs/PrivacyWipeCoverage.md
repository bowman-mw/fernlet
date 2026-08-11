# Privacy wipe coverage

**Contract:** every persistence surface in the app appears in exactly one of the two tables below —
either it is cleared by "Delete everything" (`FernletStore.deleteAllData`), or it is a documented
deliberate exception. `FernletTests/PrivacyWipeCoverageTests.swift` enforces the first table
mechanically, in both directions: it scans the wipe path for one token per row, so removing a wipe
call (or adding a store without wiring + documenting it) fails the suite — and every row's token
must appear in the test's manifest (`everyDocumentedWipeRowIsEnforcedByTheManifest`), so a
documented-but-unenforced row fails too. **Adding a store = add its wipe call, a row here, and its
token in the test — in the same commit.**

The scan is bounded to the BODIES of `deleteAllData` and `resetAll` (the wipe's one delegated leg),
with comments stripped. A whole-file scan used to satisfy a row from an unrelated function — the
same call spelled somewhere else in the 4,000-line store — so a deleted wipe call could keep the
suite green while the wipe was broken.

Every keychain service the app uses is named in one of the tables, so a `grep -r 'com\.fernlet\.'`
over the sources and the two tables below return the same set.

Pattern borrowed from bitchat's `privacy-assessment.md` panic-wipe checklist (bitchat adoptions
Increment 1, Docs/Plan-Bitchat-Adoptions-2026-07-25.md).

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
| `FernletLockService.reset()` — Settings → "Reset app lock" (and the duress WIPE that reuses the same seam) | **Destroyed — all of them**: `KeychainItem.deleteAll(service:)` sweeps every generic password under `com.fernlet.lock`; `SecureEnclaveContentKeyWrap.deleteKey` removes the SE wrap outside that sweep; and the same `deleteAll` sweep runs over each of `sealedContentKeyServices` (`com.fernlet.journal`), taking the journal and Worry Box **device fallback keys** that seal those rows whenever the lock is closed. All three, because two of the four sealed entities are not always sealed under the content key — without the third sweep "crypto-erased" would be false for every row written while locked | **Fully honest** — crypto-erased *and* the file rebuilt. (One exception stays flagged, not fixed: the locked-note buffer key `com.fernlet.narrative-buffer` is not swept — owner call, see the deliberate-exceptions table) |
| `FernletStore.deleteAllData` — "Delete everything" | **Kept by design** (see the deliberate-exceptions table: losing your data must not silently un-lock the app) | **Bounded-honest** — no live ciphertext; any residue is class-key-protected and key-bound. **Not** "crypto-erased"; do not upgrade this wording |

## Cleared by Delete everything

Ordering matters — pending saves are cancelled first and re-cancelled after `resetAll()`, the
repository purge runs late, widget files last. See the numbered commentary inside `deleteAllData`.

| Surface | Where it lives | Wiped by (token) |
| --- | --- | --- |
| Pending debounced snapshot saves | SnapshotSaveCoordinator | `snapshotSaveCoordinator.cancelPending` (start AND after purge) |
| Sealed iCloud backups (all payload types — sensitive notes, period, **journal narratives**, **intimacy logs**) | CloudKit private DB | `setSealedBackupEnabled` |
| Sealed-backup rollback high-water mark | `SealedBackupGenerationStore` (UserDefaults, device-local) | `generationStore.reset` (the call site is two lines — construct, then `.reset()` — so the token is the variable's spelling; the type name never appears on the calling line) |
| Kept cloud copy | CloudKit | `cloudCopyDeleteHook` |
| Cycle narratives (sealed rows) | Private stores | `periodDataDeleteHook` |
| Intimacy logs (sealed rows) | Private stores | `intimacyDataDeleteHook` |
| Journal narratives (sealed rows) | Private stores | `journalDataDeleteHook` |
| Sealed store FILE (sqlite + `-wal`/`-shm` + the `_SUPPORT` external-blob dir) — the residue the row deletes above leave behind | `FernletPrivate` store on disk | `sealedStoreRebuildHook` (runs LAST in `resetAll`, after every sealed-row delete; keyless, so it works while locked) |
| Locked-note pending buffer | PendingNarrativeBuffer | `pendingNarrativeBufferPurgeHook` |
| HealthKit samples (opt-in) | HealthKit | `healthKitSampleDeleteHook` (the leg is opt-in behind the `includingHealthKitSamples` parameter — but the parameter name appears on the funnel's own signature line, so it never worked as a token; the hook's spelling appears only at the real call site) |
| Meal photos | PrivateMediaStore | `mealPhotoStore.deleteAll` |
| Progress photos | PrivateMediaStore | `progressPhotoStore.deleteAll` |
| Recipe photos | PrivateMediaStore | `recipePhotoStore.deleteAll` |
| Share-extension import queue | App group | `sharedRecipeImportQueue.clear` |
| Data export files — the "export my data" dump (`Fernlet-data-*.json`) AND the trainer/nutritionist summary (`Fernlet-training-*.json`) | tmp/DataExports (+ legacy tmp/-root strays of both prefixes) | `purgeDataExports` |
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
| Recipe web-image one-attempt memory | UserDefaults | `RecipeWebImageAttemptMemory.clearAll` |
| Group-activity rosters (persisted) | Sidecar | `activities.clearAll` |
| Guided-workout run state + Live Activity | App group + ActivityKit | `guidedRunStateStore.clear` |
| Cooking run state + Live Activity | App group + ActivityKit | `cookingRunStateStore.clear` |
| Sensitive-visibility resolution | Memory | `clearSensitiveVisibilityResolution` |
| Age determination (intimacy 16+, mesh chat 13+) | UserDefaults | `ageAssurance.clear` |
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
| Away-hearts drop state: one-time + signed prekeys (keychain `com.fernlet.heartdrop`, incl. the `sidecarSealKey` sidecar seal key — `deleteAll` is by service, all accounts), peer bundle cache, outbox **and its `HeartDropOutbox.json.corrupt` quarantine file**, durable dedup, service identity cache | Keychain + sidecars | `heartDropService.wipeForDeleteAll` (each sidecar's `ProtectedSidecar.wipe()` removes primary + quarantine paths) |

(The `heartsAwayDelivery` consent flag itself lives in FernletSettings inside the snapshot — the
repository purge takes it.)

## Deliberate exceptions — surfaces that survive Delete everything BY DESIGN

| Surface | Why it survives | Its own exit |
| --- | --- | --- |
| App-lock keychain (`com.fernlet.lock`) | Losing data must not silently un-lock the app | Settings → "Reset app lock" (`FernletLockService.reset`), **or the unlock overlay itself** — its reset-required card, and (hard-bound installs whose enclave key is gone) its "sealed data can't be opened on this device" card, both call the same `reset()`. The second route is load-bearing: that state is not a failed attempt, so the reset-required card never appears in it, and the Settings button sits behind an `.appLockSettings` gate |
| MilestoneLedger | Documented product decision at the `resetAll` comment — celebrations aren't "data about you" in the deletable sense; repository has no delete API | — |
| Friend photo wall (`deleteAllSessionPhotos` NOT called) | Product decision documented above `deleteAllData`: friends' shared photos are the friends' social gift, not the user's records | Manual per-photo delete |
| **Private-media content key, friend wall (at-rest)** — keychain `com.fernlet.private-media` / account `…contentKey` | The row the photo wall above is encrypted with. Deleting it does not orphan a key — it shreds the wall: the next `mediaKey()` finds no row, mints a fresh random one, and every retained photo decrypts to garbage, permanently and silently. A key whose other stores were just emptied protects nothing extra, so keeping it discloses nothing. **Do not re-add a `deleteKeychainRowForWipe()` call to the funnel** — `PrivacyWipeCoverageTests` fails if you do | Dies with the wall: the last per-photo delete leaves it protecting nothing |
| **Private-media content key, own photos (at-rest)** — keychain `com.fernlet.private-media` / account `…ownContentKey` | Security-hardening Phase 5 split the one shared media key in two: this second row seals the user's OWN meal / recipe / progress photos and the sealed progress index. Its STORES are wiped by this funnel (the three `…PhotoStore.deleteAll` rows in the cleared table above), so the surviving key protects nothing. It is kept for the same reason as the friend row: deleting it re-opens the stale-cache hazard — a photo captured between the wipe and the next relaunch would seal under an in-memory key whose row no longer exists, and read back as garbage after relaunch. Owner decision, 2026-08-11 | Dies with its stores: after the wipe it opens nothing |
| ModerationBanStore self-ban — keychain `com.fernlet.moderation` | 2026-07-17 decision: a device ban must survive a wipe or a wipe is a ban-evasion tool | — |
| Install-binding ID — keychain `com.fernlet.device-binding` | 16 cryptographically random bytes minted per install and used only as AEAD associated data on sealed-column writes (`ColumnCrypto` v2 / `DeviceBindingID`). It identifies the INSTALL, never the person, and every ciphertext bound with it was just purged — so the surviving row discloses nothing and protects nothing extra. Deleting it mid-wipe would recreate the exact hazard the durably-stored-before-trusted mint guards against: the in-memory cache could seal post-wipe rows under an AAD no longer in the keychain, making them unopenable after relaunch. Data logged after the wipe simply re-binds under the same install ID | — (ThisDeviceOnly, never synchronized; a device reset or keychain wipe replaces it and the next seal mints a fresh one) |
| HealthKit anchor cursors — keychain `com.fernlet.healthkit-anchors` | Opaque `HKQueryAnchor` sync cursors, not health data: they record how far Fernlet has read, never what it read. Keeping them is what makes the wipe STICK — a reset cursor makes the next anchored query replay Fernlet's entire Health history back into the just-emptied day store | Turning HealthKit off (`HealthKitService.disableIntegration` → `HealthKitAnchorKeychain.deleteAll`) |
| Locked-note buffer device key — keychain `com.fernlet.narrative-buffer` (plus the service-less legacy `com.fernlet.buffer.key` account) | The buffer FILE it decrypts is purged by `pendingNarrativeBufferPurgeHook`, so the surviving key opens nothing live; it is re-used for the next note written while locked. **Asymmetry, flagged owner call (Opus track §12):** the journal and Worry Box device keys ARE deleted in the same funnel, and under the crypto-erasure baseline the difference now matters — the sealed store gets its file rebuilt, but the buffer is a plain file whose deleted bytes get no equivalent treatment, so the surviving key is what would keep any file-system residue of it openable. Deleting it in the funnel is the symmetric fix; it is deliberately NOT done here pending the owner's call | — |
| **Sealed-store divergence latches** — `UserDefaults` (device-local, non-synced): `fernlet.menstrualNarrative.everStored`, `fernlet.journalNarrative.everStored`, `fernlet.intimacyLog.everStored` | One bit each: "this install held cycle / journal / intimacy rows at some point". They must OUTLIVE the wipe — that is the whole mechanism. Every sealed repository's `deleteAll()` SETS its latch, so after "delete everything" the store reads empty-**and**-diverged; a sealed-backup chunk that survived a failed delete then cannot be restored back onto the device at the next launch. Clearing them here would make the wipe undoable by a stale cloud copy. They hold no user content — one boolean, no timestamps, no counts — and a genuine reinstall clears them for free when iOS drops the app container, which is exactly the "never populated" state a real new device should have | Dies with the app container on uninstall / device reset |
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

## Audit trail

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
  funnel bodies. Three gaps found and closed (the first two in the audit commit, the third — the
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

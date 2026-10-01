# Period data in Fernlet — Option B design (2026-09-30, revision 2)

Status: DESIGN, read-only survey of `main` at `3c8c9313`. Nothing here is built. Revision 2 folds in the
two adversarial review rounds (R1: 10 findings, R2: 13 findings); §15 records, per finding, what was
verified in the code, what changed, and where this design disagrees. An implementer should be able to
build from this without re-deriving anything; every claim about today's code carries a `file:line`.
Paths are repo-relative.

## 0. The owner's words (verbatim, 2026-09-30)

> "B sounds like a better option. Up to the user if they want this password protected. Keep the unlock
> screen, but with only an unlock button. Makes showing this information have a little friction"

Also relayed in the same message: "Both phones running the most recent test flight releasse." There
are **two** owner iPhones with test data, both on the newest TestFlight build. That makes per-device
storage, and one iCloud backup slot shared by two phones, visible consequences (§9.10, §12).

Option B, as read from the task: **every period log is saved in Fernlet's own encrypted store,
whatever the Health switches say; Apple Health becomes an optional mirror.** A password is optional.
Without one, the Private tab still shows an unlock screen, but it has one button, **Unlock**. The tap
is friction, not security.

## 1. Goals and non-goals

Goals
1. A period log (flow, first day of cycle, intermenstrual bleeding, basal body temperature, cervical
   mucus, ovulation test, note, symptoms, custom symptom scales) always saves into Fernlet's sealed
   store, in both passcode modes and with Health sharing off (the default).
2. Apple Health gets a copy only while the user's cycle sharing is on. Every Health write stays behind
   `requireWriteSharing(.cycleTracking)`.
3. The passcode is optional. Without one the data is still encrypted at rest, under a key that never
   leaves this iPhone and needs no user input. The Private tab keeps an unlock screen with exactly
   one button.
4. Adding a passcode later protects the **same** content key. Removing it returns to the tap-only
   screen with no data lost. **Neither transition can strand the key**, even if the app dies or a
   keychain call fails at any step (§4.4–§4.6).
5. Nothing already on the owner's phones is orphaned. Fernlet-written HealthKit cycle samples and
   sealed `MenstrualNarrative` rows are imported, idempotently, in two separately tracked halves (§8).
6. Every existing wall still holds: the S3 wall, no-tracking, Power of 10, localization, doc
   coverage, the persisted-surface wipe wall, and fail-closed hiding at the decrypt seam.
7. **The Sealed backup keeps up with the store and survives the real migration paths**: it is
   re-exported after every change, restores on a new iPhone set up from a device backup, restores
   after an app-lock reset (behind a device-owner check), and is never overwritten by the other
   iPhone without the user choosing it (§9.10).

Non-goals, each deliberately left alone in this round
- Syncing cycle records between the owner's two iPhones. The store stays local-only. One iPhone owns
  the cycle backup slot at a time; replacing it is an explicit choice (§9.10, §12, Q9).
- Putting cycle data in "Export my data", widgets, AI or memory. All four stay excluded (§9, Q7).
- Retiring the existing plaintext `dayKey`/`eventDate`/`createdAt` columns on the journal and
  intimacy entities. The new entity does not add to that debt (§5.2).
- A one-shot backfill of past Fernlet-only entries into Health when sharing is turned on (Q2).
- Converting the **journal** and **intimacy** backups to the merge-restore / compare-and-swap model
  §9.10 gives period data. They get only the fixes they need to stay correct next to it (the
  backup-key provider, the reset and new-key handling of their latches). Their pre-existing
  two-phone overwrite and stale-snapshot limits are named in §12 and left to a follow-up.

## 2. Today's behaviour, traced

### 2.1 Write path
- `LogPeriodSheet.save()` (`App/Fernlet/LogPeriodSheet.swift:748`) builds a `UserLoggedCycleEvent`.
  It then refuses a notes-only entry when no lock exists (`unkeepableEntryProblem`, `:734`) and calls
  `periodStore.editEvent` or `periodStore.logEvent` (`:780–782`), passing
  `lockService.contentKey(for: .privateHub)`.
- `PeriodTrackerStore.logEvent` (`FernletKit/Sources/PrivateHealthStore/PeriodTrackerStore.swift:574`)
  runs these steps:
  - Gate G2 (`:579`).
  - `healthService.savePeriodEvent` first (`:581`). This is the only home of the clinical fields.
  - A narrative is built only when `event.hasNarrative` (`:582`). A flow-only log has no narrative.
  - Seals the narrative only when a key is live (`:592–595`).
  - **Drops the narrative when no lock is configured** (`:597–599` → `.savedWithDroppedNarrative`).
  - Otherwise buffers the narrative (`:601–608`).
- `HealthKitService.savePeriodEvent` (`FernletKit/Sources/HealthKitGateway/HealthKitService.swift:2759`)
  throws `sharingTurnedOff` via `requireWriteSharing(.cycleTracking)` (`:2762`, gate at `:1963–1969`)
  whenever the event has a clinical field. The rule (`isWriteSharingEnabled`, `:1925–1956`) needs both
  `healthKitMasterEnabled` and the cycle switch. Both default to **off**
  (`FernletKit/Sources/FernletFoundation/StoragePreferences.swift:119–120`).
- The net effect: a default user (no lock, no sharing) can save nothing. Yesterday's commits `2025cf39`
  and `89dd2857` made the sheet say so honestly (`lockWarning` `:296`, `healthNotice` `:326`,
  `refusalSentence` `:688`).
- Edit (`PeriodTrackerStore.swift:628–657`) is delete-then-recreate. It pre-checks the Health write
  (`:637`), deletes the Fernlet-owned samples (`:638–642`) and the narrative, then re-logs.
- Delete (`:663–690`) removes the Fernlet-owned samples **first**, then the narrative. A Health
  failure throws before the narrative is touched, so both halves survive (`CycleTrackerView.swift:331–343`
  then says "That day is still here").
- The pending buffer (`FernletKit/Sources/PrivateStoreCore/PendingNarrativeBuffer.swift`) holds
  `PendingNarrativePayload` (`:56–83`, narrative fields only). It caps at 50 entries (`:144`) and
  **silently evicts the oldest** (`:171–185`, audit line only). Its file is excluded from iOS backup
  (`:257`). Its key is loaded through a **collapsing** read and minted on any nil (`bufferKey()`
  `:278–281`, `loadBufferKey` `:285`, `createAndStoreBufferKey` `:351–365`).

### 2.2 Read path
- `loadEntries` (`PeriodTrackerStore.swift:474–522`):
  - Gate G1 comes before the HealthKit read (`:480`).
  - It reads all sources' samples for 240 days (`:487`) and rechecks visibility and the key after
    the await (`:493–500`).
  - It decrypts narratives by `dateKey IN` (`:501`) and joins them by `hkExternalUUID`, tolerating
    duplicate `hkExternalUUID` rows that a partial drain can produce (`:502–507`).
  - A prediction is computed only when a key was passed (`:511–515`).
- `HealthKitService.loadPeriodEvents` maps a never-requested cycle type to `[]`, not an error
  (`HealthKitService.swift:2811–2840`).
- Loads happen only while the hub is unlocked for `.privateHub` and the section is Cycle:
  `CycleTrackerView.loadPeriodIfUnlocked` (`App/Fernlet/CycleTrackerView.swift:571–593`, the
  contextual Health ask at `:577–584`, then drain, then load), started from a view `.task`
  (`:217–222`). Leaving the tab or section scrubs everything (`ContentView.swift:1324–1347`).
  `settlePeriodEntriesAfterLoad` (`:1401–1407`) exempts `.notConfigured` from its scrub.
- `PeriodContextBridge.buildObservations` sets `symptomLoad = entry.narrative.map {…}`
  (`FernletKit/Sources/PeriodContextBridge/PeriodContextBridge.swift:425`), so a day with no
  narrative (including every Fernlet flow-only day) contributes **no** symptom observation.
- The prediction, the bridge's softening and the Home outlook bubble (`HomeView.swift:880–883`) are
  live only during a Cycle-page hub session. This design keeps that.
- Home's `.logPeriod` and `.periodTracking` shortcut highlights read HealthKit only
  (`HomeView.swift:1428–1431`, `refreshRecentPeriodActivity` `:1512–1537`), through
  `allowedHealthCapabilities`, which drops cycle reads unless `.privateHub` is unlocked
  (`FernletStore.swift:2495–2509`).

### 2.3 Key custody and the lock
- `FernletLockState` (`FernletKit/Sources/FernletLock/FernletLockService.swift:115–134`) has three
  cases: `notConfigured`, `locked`, `unlocked(scope)`. `isLockConfigured` is `state != .notConfigured`
  (`:78`).
- `initialState` (`:1160–1175`) reads the salt only: absent → `.notConfigured`, found → `.locked`,
  unreadable → `.locked`. `refreshStateFromKeychain` (`:1182`) re-derives it.
- `contentKey(for:)` (`:3143`) releases the key only to `.privateHub` while unlocked. With no lock
  there is **no content key at all**.
- `configure` (`:1322`) refuses over an existing or unreadable salt (`:1330–1336`) and always **mints
  a fresh** key via `mintLockRecords` (`:1389`). `configure` has no rollback.
- `mintLockRecords` deletes `seWrappedContentKey`, the biometric rows and the duress rows **first**
  (`:1413–1422`), sweeps or keeps the recovery rows (`:1429–1451`), then writes `.salt` **first**
  (`:1453`), then verifier, kind, `wrappedContentKey` (`:1458`) and scryptN, with no rollback. It
  already accepts a supplied key (the custodian recovery). It refuses up front when recovery
  material is unreadable (`refuseIfRecoveryMaterialUnreadable` `:1476–1486`).
- `changeCredential` (`:1513`) preserves the key and has all-or-nothing rollback. Under a duress PIN
  it runs `performDuressResponse` and **returns normally** (`:1524–1527`).
- `unlock(passcode:for:)` (`:1684`) throws `.notConfigured` when salt or verifier is missing
  (`:1685–1688`). A duress PIN on `.appLockSettings` runs the response then throws `.invalidPasscode`
  (`:1702–1709`, `handleDuress` `:2600–2604`, `enterLockedDecoySession` `:2927`).
- Custody classification (`contentKeyCustody` `:3228–3244`): `wrappedContentKey` found → legacy;
  absent on enclave hardware → hard-bound, and a missing `seWrappedContentKey` there is **terminal**
  `.contentKeyUnrecoverable` (`secureEnclaveBoundContentKey` `:3260–3290`).
- `KeychainItem.delete(for:service:)` returns `Void` (`:713–715`); the status-returning form is
  `KeychainItem.deleteReportingStatus` (`FernletFoundation/KeychainHelpers.swift:305`). The atomic
  single-transaction replace `KeychainItem.updateReportingStatus` exists with no production caller
  (`:346`). The service's injectable seams are store / load / loadDistinguishing only (`:1117–1120`);
  there is no delete seam.
- `reset()` (`:1976`) sweeps `deleteAll(service:)` over the lock service, the SE key, the journal /
  Worry Box device keys, purges the buffer file and the sealed entities, and rebuilds the store. Its
  own doc names the buffer key (`com.fernlet.narrative-buffer`) as not swept (`:1968–1970`).
- `destroyLocalUnlockKeys` (`:2763–2851`, used by the silent-wipe and recovery-lock duress modes)
  sweeps the lock rows, the SE key, and (wipe only) `sealedContentKeyServices` and
  `mediaKeychainServices`. It never touches the buffer key or the buffer file.
- `hasRecoveryCustodian` (`:2187–2191`) is three **collapsing** reads. `isAwaitingCustodianRecovery`
  (`:2278–2280`) is `hasRecoveryCustodian && verifier == nil`.
- `reestablishLocalUnlock` (`:3102–3135`) re-mints the lock around a custodian-returned key.
- Secure Enclave wrap: `wrapVerified` returns nil on any failure
  (`FernletLock/SecureEnclaveContentKeyWrap.swift:68–82`); `loadOrCreateKey` creates a key on the
  collapsing `loadKey` (`:226–247`, `loadKey` `:182`), so a read error mints a second enclave key
  under the same tag; `loadKeyResult` returns one arbitrary match (`:202–220`).
- Lock keychain rows are `WhenUnlockedThisDeviceOnly` and never synchronizable (`:696–705`). The
  per-install `DeviceBindingID`, which every sealed column authenticates as AAD, is
  `AfterFirstUnlockThisDeviceOnly` (`FernletCrypto/DeviceBindingID.swift:7–15`).
- Journal and Worry Box seal with device keys (`com.fernlet.journal`) while no key is live, and fold
  those rows under the user key at unlock (`JournalSealingCoordinator.swift:168–220`, `:335–368`;
  `WorryBoxService.swift:228–245`).

### 2.4 The Private tab gate
- `PrivateHubView` applies `.fernletLockGate(scope: .privateHub, …)` (`App/Fernlet/PrivateHubView.swift:120`).
- With no lock, the gate paints the **"Set up app lock" CTA** (`FernletLockGate.swift:414–470`). The
  whole hub is unreachable.
- Settings › App lock is gated only while a lock exists (`SettingsSheet.swift:335`); with no lock it
  shows the setup card (`:2320–2328`).
- Intimacy with no lock: `LogIntimacySheet.save` passes a nil key (`:208`) and the insert throws
  `.locked`.

### 2.5 Backup, wipe, visibility
- The sealed backup `.periodData` payload is a `[MenstrualNarrative]` JSON array
  (`SealedBackupCoordinator.swift:564–583`), sealed under the **escrow** key.
- **The backup content key is the journal section's key, not the hub key.**
  `sealedBackupContentKey` is `journalSealingCoordinator.contentKey` (`FernletStore.swift:7118`).
  `updatePrivateDataActivation` calls `store.deactivateSealedJournals()` (`ContentView.swift:1330`,
  which sets it nil at `JournalSealingCoordinator.swift:159`) and returns early on the Cycle section
  (`ContentView.swift:1335`). The Cycle section's settle (`:1451–1466`, after the 300 ms wait at
  `:1435`) then runs the intimacy restore and the period / intimacy re-uploads with a **nil** key, so
  they defer as `.locked` (`SealedBackupCoordinator.swift:570`, `:1250`, `:1288`). This is a
  **pre-existing bug for intimacy today** and would break every period backup under Option B.
- Restore gates: fresh-install pass at launch (`:743`), targeted restore behind the divergence latch
  (`:945–983`, latch check `:967`), and the one no-clobber gate every restore passes,
  `count == 0 && !hasEverStored` (`:1314–1370`, period `:1347–1348`).
- The last restore outcome lives in an **in-memory** dictionary (`FernletStore.swift:3527`, written at
  `:7126`).
- The period export pages the store with no empty or unopenable-row guard (`:564–583`). The journal
  export probes page 1 only, refuses only when page 1 is empty, and **exports a partial set** with an
  audit line otherwise (`:599–640`, probe `:620`).
- `reconcileChunked` writes suffix chunks `n-1…1` first and the head last (`SealedBackupService.swift:301–331`).
  A restore rejects a generation below this device's high-water mark as terminal `.rolledBack`
  (`:408–417`, classification `SealedBackupCoordinator.swift:1139–1147`).
- Generations are minted from a **device-local** counter (`SealedBackupGenerationStore.swift:65–69`).
  Record names are **account-global**: `sealed-backup.<payload>[.chunk.N]`
  (`FernletKit/Sources/CloudKitSync/CloudKitDataService.swift:844–853`). Two phones exporting the
  same payload overwrite each other.
- The period backup is re-exported only on enable, deferral retry, escrow adopt and un-hide. The code
  calls the cloud copy "stale by construction" (`SealedBackupCoordinator.swift:960–962`).
- **The divergence latches travel with iOS device backups.** They live in standard `UserDefaults`
  (`MenstrualNarrativeRepository.swift:106–121`; journal `JournalNarrativeRepository.swift:150`;
  intimacy `IntimacyLogRepository.swift:139`). The sealed store is included in iOS backups by default
  (`PrivatePersistenceController.swift:112–120`, default `localBackupExcludedFromiOSBackup = false`,
  `StoragePreferences.swift:118`). The `Docs/PrivacyWipeCoverage.md` row for the latches says they
  "die with the app container". That is true for an uninstall and false for a new iPhone set up from
  an iCloud or Finder backup, which restores the container.
- The escrow key is minted `ThisDeviceOnly` and promoted to synchronizable only once a later launch
  confirms no conflicting synced key (`ProximityKit/Identity/IdentityService.swift:881–905`). It
  reaches a second iPhone only through iCloud Keychain.
- Delete-all: `stopWritersForWipe` cancels the debounced save, workout observation and the two
  un-hide settle tasks only (`FernletStore.swift:5698–5711`). `periodDataDeleteHook` is
  `MenstrualNarrativeRepository().deleteAll()` (`ContentView.swift:1487`). The lock keychain survives
  by design (`Docs/PrivacyWipeCoverage.md` deliberate-exceptions table). The generation marks reset
  (`FernletStore.swift:5769`).
- Visibility gate: `isPeriodTrackingVisible` (`FernletStore.swift:1095–1102`), derived from
  `periodTrackingVisible ?? sex == .female`, forced shut in a duress session, injected fail-closed
  (`PeriodTrackerStore.swift:412`, wired at `ContentView.swift:477`).
- Exports, widgets and AI exclude cycle data (`DataExportBuilder.swift:11–15`, `:271–275`;
  `TrainerExportBuilder.swift:14`; `WidgetSharedModels.swift:159`; `AIContextPayload.swift:40` ff).
- The private store is local-only (`PrivatePersistenceController.swift:97–98`), with a programmatic
  model and inferred lightweight migration. `purgeEncryptedEntities` hard-codes four entity names
  (`:171`).
- `ColumnCrypto` authenticates `purpose ‖ binding` only (`FernletCrypto/ColumnCrypto.swift:241–246`);
  it classifies open failures as `installBindingMissing`, `retiredFormat`, `emptyBlob`, a retryable
  `DeviceBindingID.ReadError`, or a CryptoKit authentication failure (`:71–92`, `openBlob` `:278–296`).
- The user-facing loss copy still says only notes are at risk and that cycle entries remain in
  Apple Health: `lock.disclosure.forgottenPasscode` (`FernletLockUI/FernletLockView.swift:261–264`),
  `lock.reset.required.body` (`:951–955`), `lock.reset.confirm.message` (`FernletLockGate.swift:54–58`),
  `lock.hardBinding.message` (`:81–86`), the Settings reset dialog literal
  (`App/Fernlet/SettingsSheet.swift:2343–2350`), the device-backup exclusion warning
  (`PrivacyDataSettingsView.swift:1873–1882`, "cycle notes"), and the Privacy Policy
  (`PrivacyPolicyView.swift:101`, "require Fernlet's app lock").
- Privacy & Data's fresh check is `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`
  (`PrivacyDataSettingsView.swift:1922–1937`), shown only when a lock exists (`:342–350`).

## 3. Design in one paragraph

One **hub content key K** exists per install whether or not a passcode does. Without a passcode, K
lives in a device-custody keychain row, Secure-Enclave-wrapped on every enclave device (a raw
`ThisDeviceOnly` row only where no enclave exists). A new lock state, `.openedWithoutPasscode`, is
entered by a deliberate tap and releases K through the one existing decrypt seam. Adding a passcode
wraps the same K (salt written last, so an interrupted setup falls back to the tap gate); removing
it hands K back to device custody (device row first, salt deleted as the commit point). When a fresh
K must be minted while the store still holds rows sealed under a key that no longer exists
anywhere, the user is shown those entries and removes them explicitly before Private opens. Period
data moves into a new sealed entity, `CycleRecord`: one ciphertext blob per row, no plaintext dates,
with a clinical block and a narrative block that merge deterministically. A save seals first, then
mirrors to Health only when cycle sharing is on. The Sealed backup carries whole records, is marked
dirty on every change and re-exported at the next hub session, restores by id-keyed merge until this
install has resolved its restore, and only replaces the cloud copy it last saw.

## 4. Key custody and the lock state machine (module `FernletLock`, UI in `FernletLockUI`)

### 4.1 State

```swift
public enum FernletLockState: Equatable {
    case notConfigured                                   // no passcode; every surface CLOSED
    case locked(cooldownDeadline: Date?)                 // passcode; closed
    case unlocked(scope: FernletLockScope)               // passcode; open for one surface
    /// NEW. No passcode; opened by a deliberate tap. Only ever `.privateHub`. Friction, not
    /// security: no credential was proven — anyone holding the unlocked iPhone can do this.
    case openedWithoutPasscode(scope: FernletLockScope)

    public var unlockedScope: FernletLockScope? { /* .unlocked(s), .openedWithoutPasscode(s) → s */ }
    public var isPasscodeConfigured: Bool { /* .locked, .unlocked → true */ }
    public func isUnlocked(for scope: FernletLockScope) -> Bool { unlockedScope == scope }
}
```

- `isLockConfigured` (`FernletLockService.swift:78`) becomes `state.isPasscodeConfigured`.
- Every raw `state != .notConfigured` / `== .notConfigured` site moves to `isLockConfigured`:
  `SettingsSheet.swift:335, :2320, :2498, :2698, :2708`; `PrivacyDataSettingsView.swift:1629`;
  `OnboardingLockSetupView.swift:86`; `LogPeriodSheet.swift:297`; `ContentView.swift:1388, :1403`;
  `FernletLockGate.swift:317, :484`. The compiler catches exhaustive switches but not `==`; grep for
  both before landing.
- Switches that gain the new case: `ProximityRecipeShareSheet.swift:466–469` (`allowsListening` is
  true), `WorryBoxService.swift:98–114`, `ContentView.applySealedJournalActivation`, the SettingsSheet
  status label and colour.

### 4.2 Device custody row (the no-passcode home of K)

- Account `LockKeychainKey.deviceContentKey = "com.fernlet.lock.deviceContentKey"` under the lock
  service `com.fernlet.lock`, written through `KeychainItem.store(_:for:service:)`
  (`WhenUnlockedThisDeviceOnly`, never synchronizable, `FernletLockService.swift:696–705`), verified
  by `storeVerified`. Added to `LockKeychainKey.allCases` (`:3697`).
- Value: a 4-byte marker then the body. At-rest format, frozen.
  - `FDS1` + an ECIES blob from the enclave wrap. **On hardware where
    `SecureEnclaveContentKeyWrap.isAvailable` is true, this is the only format ever written.** A
    wrap that returns nil (R1-F8) throws `.contentKeyTemporarilyUnavailable` and nothing is
    persisted; the code never falls through to `FDR1` on enclave hardware.
  - `FDR1` + the raw 32 bytes, written only where no enclave exists (simulator, SE-less hardware).
  - A reader that finds `FDR1` on enclave hardware (a simulator-to-device restore, or an old build)
    upgrades it in place: wrap, then `KeychainItem.updateReportingStatus` (one `SecItemUpdate`
    transaction, so a crash cannot leave the row absent), then re-read and prove it opens to K.
    Failure leaves `FDR1` (still valid) and is audited; the next open retries. This is the first
    production caller of `updateReportingStatus`; its update-only contract test stays.
  - An unknown marker is **retryable**, never terminal and never routed to reset (a downgrade reads a
    newer build's format).
- Reads are classified. Found and opens → K. `FDS1` goes through `unwrapResult`: `keyAbsent` or
  `blobRejected` is terminal, `unavailable` retryable. Absent means none exists. Unreadable is
  retryable, and the code never mints over it.
- `SecureEnclaveContentKeyWrap.loadOrCreateKey` (`:226`) changes to create only on
  `loadKeyResult == .absent`; `.unreadable` returns nil (the wrap then throws retryable). This
  closes the second-enclave-key-under-one-tag hole for the passcode custody too.
- The wrap is reached through a new internal seam, `DeviceContentKeyWrapping`
  (`wrapVerified`, `unwrapResult`, `isAvailable`), production = the enclave; tests inject a fake
  enclave so the `FDS1` classification runs in CI (R1-F8).
- Invariant: the row exists **only while no passcode is configured**, except in the named, harmless
  window between a verified passcode setup and the row's retirement (§4.4 step 7).

### 4.3 New and changed service operations

| API | Behaviour |
| --- | --- |
| `openWithoutPasscode(for scope: FernletLockScope, allowingMint: Bool) throws` | Refuses unless `state == .notConfigured`, `scope == .privateHub`, `!isDuressSessionActive` (throws `.locked`). Reads the device row. **Found** → open K (§4.2); `FDS1` terminal → `.contentKeyUnrecoverable`; transient or unknown marker → `.contentKeyTemporarilyUnavailable`. Then runs the interrupted-transition sweep if flagged (§4.6). **Unreadable** → `.contentKeyTemporarilyUnavailable`. **Absent** → mints only when `allowingMint` is true AND the mint-safety proof below passes; otherwise throws `.deviceKeyAbsent` (the app's open coordinator runs the prior-data check of §4.9 first). Then `retainContentKey(K, for: .privateHub)`, `state = .openedWithoutPasscode(.privateHub)`, audit `lock.openedWithoutPasscode` (scope only). |
| mint-safety proof (inside the above) | Every K-bearing lock row reads **definitively absent** with distinguishing reads: `.salt`, `.verifier`, `.wrappedContentKey`, `.wrappedContentKeyRewrapStaging`, `.seWrappedContentKey`, `.biometricEnabledFlag`, and `.biometricBypass` through an attributes-only presence probe (no data, no Face ID prompt; `errSecInteractionNotAllowed` counts as present-or-unknown). `refuseIfRecoveryMaterialUnreadable()` passes. `isAwaitingCustodianRecovery` is false, recomputed from distinguishing reads. Any found row throws `.deviceCustodyInconsistent` (audited, retry card); any unreadable one throws `.keychainFailure`. (R1-F6) |
| `lock(reason:)` (`:1925`) | The guard widens to both open cases. From `.openedWithoutPasscode` it returns to `.notConfigured` and scrubs K. |
| `revokeUnlockOutside` (`:1940`) | Unchanged code; works through `unlockedScope`. |
| `refreshStateFromKeychain` (`:1182`) | No-op while either open case holds; otherwise re-derives through §4.6. |
| `contentKey(for:)` (`:3143`) | Unchanged code; returns K whenever `state.isUnlocked(for: .privateHub)`, which now includes the tap case. |
| `configure(credential:grantingScope:acknowledgedPriorData:)` (`:1322`) | See §4.4. Adoption of device K (salt written last, rollback, owner check), or a fresh mint gated by the prior-data acknowledgement. |
| `mintLockRecords` (`:1389`) | **Writes `.salt` LAST for every caller** (configure, adoption, recovery re-establish, duress throwaway), and on any throw deletes every row this call wrote, newest first. The row SET is unchanged, so the throwaway lock stays byte-shaped like a real one; only the order moves. |
| `removeCredential(current: String) async throws` (NEW) | See §4.5. |
| `reestablishLocalUnlock` (`:3102`) | After the verified mint, also retires any device row (`deleteReportingStatus`, re-read absent). A device row can exist there only from an interrupted transition, and it holds the same K the custodian returned. (R1-F6 fix 3) |
| `reset()` (`:1976`) | Code unchanged: its service-wide sweep covers the device row, and it must (see §15 R1-F1 item 4). Its doc names the row. It fires the new `onResetCompleted` hook at the end, even when the rebuild failed, so the app can re-open the backup restore behind a device-owner check (§9.10). |
| `destroyLocalUnlockKeys` (`:2763`) | Adds `.deviceContentKey` to the base list (both modes). When `alsoDestroyingDeviceFallbackKeys` is true (silent wipe) it also sweeps the buffer key service (`PendingNarrativeStorageScope.keychainService`) and deletes the buffer file (`buffer.purge()`, retried once on failure, never audited: duress silence). (R1-F5) |
| `keychainDelete` seam (NEW init parameter) | `((LockKeychainKey, String) -> OSStatus)?`, default `KeychainItem.deleteReportingStatus`. Every delete in configure/adopt/remove/sweep/retire goes through it, so fault injection reaches deletes as well as writes (R1-F1 fix 5). |
| `onResetCompleted: (@MainActor () -> Void)?` (NEW) | Set by the app. Called by `reset()` only (never by a duress mode). |
| `PeriodLockContext.isLockConfigured` (`PeriodTrackerStore.swift:336`) | Removed from the seam; nothing is ever dropped (§6.3). |

There is **no** `destroyDeviceContentKey()`. Revision 1 had delete-all destroy the device row; this
revision keeps it (§9.11), so the operation has no caller.

### 4.4 Adding a passcode (`configure`), without stranding K

`configure(credential:grantingScope:acknowledgedPriorData:)`:
1. `credential.validate()`; salt must read `.absent` (today's guard, `:1330–1336`).
2. Read the device row with a distinguishing read.
   - **Unreadable** → refuse (`keychainFailure`). Never mint over a key that may still seal data.
   - **Found** → open K (§4.2). Terminal → refuse `.contentKeyUnrecoverable`; transient → refuse
     `.contentKeyTemporarilyUnavailable`. Go to step 3 (adoption).
   - **Absent** → if any sealed entity holds rows (keyless counts through
     `privatePersistenceController`) and `acknowledgedPriorData` is false, throw
     `.priorSealedDataPending`: the setup UI routes through the §4.9 coordinator, which classifies
     the rows and calls back with `true`. Otherwise mint fresh through `mintLockRecords` (today's
     behaviour, now salt-last) and continue at step 6.
3. **Owner check before adoption (R1-F3).** When the device row holds K and any sealed entity holds
   rows, run a fresh device-owner check through a new `DeviceOwnerVerifying` seam (production:
   `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`, the same policy Privacy & Data uses).
   Cancel or failure throws `.ownerVerificationFailed`; nothing is written.
   `LAError.passcodeNotSet` proceeds with audit `lock.adopt.noDeviceOwnerCheck`: on an iPhone with no
   passcode nothing can tell the owner from the holder, and the tap gate already shows everything.
   Onboarding on a fresh install has no rows, so no check.
4. `mintLockRecords(for: credential, contentKey: K)` with salt last: verifier, kind, scryptN,
   `wrappedContentKey`, then `.salt`. A throw rolls back every row it wrote; the device row is never
   touched, so K stays reachable and the state stays `.notConfigured`.
5. Retain K for `grantingScope`, `state = .unlocked(grantingScope)`, set the process flags (as today).
6. `maintainSecureEnclaveWrap` and `hardBindToSecureEnclaveIfVerified` (as today, `:1349–1352`).
7. `retireDeviceCustodyIfPasscodeVerified(K)`: re-read salt, verifier and custody; prove the passcode
   custody opens to K (hard-bound: `secureEnclaveBoundContentKey() == K`; legacy: unwrap the re-read
   `wrappedContentKey` with the derived key `mintLockRecords` returns privately, never persisted);
   then delete the device row through `keychainDelete` and re-read it `.absent`. A failure is
   audited and the row is retired at the next successful passcode unlock (the unlock tail checks for
   it). While it lingers it is not a way in: `openWithoutPasscode` requires `.notConfigured`, and
   §4.6 derives `.locked` whenever the passcode custody is complete.

A crash anywhere before step 4 writes the salt leaves `.notConfigured` with K in the device row; the
stray passcode rows are swept at the next tap (§4.6). A crash after the salt write leaves a complete
passcode lock plus the lingering row of step 7.

### 4.5 Removing the passcode (`removeCredential`), without data loss

1. Refuse while `isDuressSessionActive` (`.locked`). Load salt and verifier with distinguishing
   reads (absent → `.notConfigured`; unreadable → `keychainFailure`).
2. **Duress first.** A match runs `performDuressResponse(mode, scope: .appLockSettings)` (which enters
   the locked decoy session) and then **throws `.invalidPasscode`**. This is the `unlock` /
   `handleDuress` shape on `.appLockSettings` (`:1702–1709`, `:2600–2604`), deliberately NOT the
   `changeCredential` silent-success shape (`:1524–1527`): removal is observable (the status row
   would flip to "No passcode" and Private would open with a tap), so a reported success that
   removed nothing would be a tell, while `enterLockedDecoySession` already makes the refusal
   audit- and counter-identical to a mistype. Pinned in `DuressLockTests`. (R1-F10)
3. Honour `requiresReset` and the cooldown as `unlock` does. Verify (a wrong passcode takes the same
   attempt ladder). Recover K through `contentKeyCustody()`; undeterminable throws before any write.
4. Write the device row (§4.2; on enclave hardware a nil wrap throws retryable), re-read it, prove it
   opens to K. On failure delete it and stop. Nothing else has changed.
5. **Commit point.** Delete `.salt` through `keychainDelete`, then re-read it. It must read
   `.absent`; otherwise throw `keychainFailure("turn off passcode")` and stop. The passcode lock is
   fully intact at that point, and the leftover device row is retired at the next passcode unlock
   (§4.4 step 7). (R1-F1 fix 3)
6. Delete the recovery rows, **blob first**: `recoveryBlob`, `custodianSigningPublicKey`,
   `custodianKeyAgreementPublicKey`, `recoveryOwnerKeyAgreementPublicKey`, `recoveryBlobSuperseded`.
   They go **before the verifier**, so no crash can produce "custodian present, verifier absent",
   which `isAwaitingCustodianRecovery` would read as a recovery-locked device. (R1-F6 fix 1)
7. Delete the rest: the four duress rows, biometric bypass and flag, verifier, kind, scryptN,
   `wrappedContentKey`, rewrap staging, `seWrappedContentKey` (the blob, NOT the enclave key, which
   the device row's `FDS1` blob uses), cooldown and attempt rows, `requiresReset`,
   `hardBindingNoticePending`. Each failure is audited; §4.6's sweep finishes it.
8. `scrubContentKey()`, `state = .notConfigured`, clear `passcodeUnlockedThisProcess` and
   `passcodeVerifiedThisProcess`, audit `lock.passcodeRemoved`.

Face ID unlock, the duress code and any recovery device go with the passcode (Q8).

### 4.6 State derivation and interrupted transitions (R1-F1 fix 1)

`initialState` and `refreshStateFromKeychain` share one derivation:

| Salt | Passcode custody (verifier found AND (`wrappedContentKey` or `seWrappedContentKey` found)) | Device row | State |
| --- | --- | --- | --- |
| absent | any | any | `.notConfigured`; if any passcode row is found, flag `interruptedTransitionPending` |
| unreadable | — | — | `.locked` (today's fail-closed rule) |
| found | complete | any | `.locked` (a found device row is the step-7 leftover; retired at the next passcode unlock) |
| found | any read unreadable | — | `.locked` (fail closed) |
| found | definitively incomplete | found | `.notConfigured` + `interruptedTransitionPending` (audit `lock.interruptedTransition`) |
| found | definitively incomplete | absent / unreadable | `.locked` (today's behaviour; this pre-existing dead end is not reachable from any flow in this design) |

The **sweep** runs inside `openWithoutPasscode` after K has been opened from the device row, and only
then: delete `.salt` first (it is what makes a state read as configured), then the recovery rows
blob-first, then every remaining passcode row as in §4.5 step 7, each through `keychainDelete`.
Because it runs only once K is in hand from the device row, it can never delete the last route to K.

### 4.7 Edge states (all fail closed and are named)

- **Awaiting custodian recovery** (after `.recoveryLock`): the device row was destroyed. The mint-safety
  proof refuses. The gate shows today's setup/recovery CTA, and `configure` behaves as today.
- **Unreadable device row, or any K-bearing row present with the device row absent**: no mint. The
  gate shows "Fernlet can't open this right now. Try again in a moment." (a retry state that never
  mentions reset).
- **Device row absent, mint-safety proof passes, sealed rows exist**: the "entries this iPhone can't
  open" coordinator (§4.9). Nothing is deleted without the user's tap.
- **`FDS1` whose enclave key is gone** (the same iPhone erased and restored from an encrypted
  backup: the row and `DeviceBindingID` come back, the enclave key does not): `.contentKeyUnrecoverable`.
  The tap gate shows today's unrecoverable card with its reset route and the rewritten copy (§10.5).
  After the reset, the Sealed backup is restorable from Privacy & Data behind the device-owner check
  (§9.10).

### 4.8 Transition table

| From | Event | To | K |
| --- | --- | --- | --- |
| notConfigured | tap Unlock, device row found | openedWithoutPasscode(.privateHub) | opened, resident |
| notConfigured | tap Unlock, row absent, no sealed rows / after §4.9 | openedWithoutPasscode(.privateHub) | minted, resident |
| openedWithoutPasscode | lock(any reason) / scope change / background | notConfigured | scrubbed |
| notConfigured / opened… | configure(passcode) | unlocked(grantingScope) | adopted after owner check; device row retired after verify |
| locked / unlocked | removeCredential(correct) | notConfigured | device custody; passcode rows gone |
| locked / unlocked | removeCredential(duress PIN) | duress response, locked decoy, `.invalidPasscode` | unchanged |
| any | reset() | notConfigured | destroyed (all rows incl. device row, SE key, sealed rows purged); `onResetCompleted` fires |
| any passcode state | silentWipe | throwaway lock (as today) | device row, buffer key and buffer file also destroyed |
| any passcode state | recoveryLock | awaiting recovery (as today) | device row destroyed; buffer left (as today, §12) |
| any | delete-all | unchanged | **kept** (the lock keychain is the documented survivor, §9.11) |

### 4.9 "Entries this iPhone can't open" (the new-key coordinator)

A fresh K is minted only through `openWithoutPasscode(allowingMint: true)` or a fresh `configure`.
Both are reached through one app-side coordinator, `PrivateHubOpenCoordinator` (new, app target),
which runs before any mint:

1. **Detect** (all keyless or device-key-only, no K involved):
   - K-sealed row counts: `CycleRecord`, `IntimacyLog`, `MenstrualNarrative`. Every one of these rows
     was sealed under a K; with the device row absent and the mint-safety proof passing, no copy of
     that K exists, so every such row is provably unopenable.
   - Journal and Worry Box rows: each is sealed under K or under its device key. The coordinator
     tries each row under the device key (`JournalNarrativeRepository`/`WorryBoxService` pagers,
     bounded): opens → alive (folded under the new K at activation); terminal failure → dead;
     transient failure → stop and show the retry state.
   - The pending buffer: key absent while the file is non-empty → dead (§6.5).
   - Backup bookkeeping: any of the three divergence latches, the period restore marker (§5.3), the
     period compare-and-swap record (§9.10).
2. **No dead rows, no bookkeeping** → mint and open.
3. **Bookkeeping only** (a new iPhone from a device backup with the sealed store excluded, or an
   install that reset its lock before this build) → clear the latches, the period restore marker and
   the compare-and-swap record, audit `lock.newKeyOverPriorData` (counts by kind only), mint, open.
   Clearing them is bookkeeping, not deletion: they speak for a key that no longer exists.
4. **Dead rows** → the tap gate shows the card in §10.2 in place of the Unlock button. **"Remove them
   and open Private"** deletes exactly the dead rows (keyless deletes: the three K-sealed entities
   wholesale, the dead journal/worry ids, the dead buffer file), clears the bookkeeping as in step 3,
   then mints and opens. **"Not now"** leaves Private closed and deletes nothing.
5. Then the settle runs the period restore (§9.10), which is exactly what a new iPhone wants.

This replaces revision 1's "mint over unopenable rows and leave them". Leaving them made every
keyless count lie: the restore gate refused forever, and the export deferred forever (R1-F2, R2-F2).
It also fixes the same trap for today's passcode users on a new iPhone, whose lock rows never
migrate: they arrive `.notConfigured` and meet the same card.

### 4.10 The honesty statement (verbatim in the `FernletLockState` and `openWithoutPasscode` docs, and the FernletLock landing page)

- Without a passcode, the Private tab's Unlock button is **friction, not security**. It proves nothing
  about who is holding the phone. What it buys is that private entries are never shown by accident
  and are decrypted only while the page is deliberately open.
- The data stays encrypted at rest under a key that never leaves this iPhone. Where a Secure Enclave
  exists, the enclave wraps it.
- A passcode adds an app-enforced gate with a brute-force ladder over the same key. On enclave
  hardware the key's at-rest custody is identical either way; the passcode is what stops someone
  holding the unlocked phone.
- Neither mode protects the iCloud Sealed backup from someone who controls the Apple Account and a
  trusted device (true today). A restore after an app-lock reset asks for Face ID or the iPhone
  passcode (§9.10).
- User-facing copy never says "locked", "protected" or "secured" about the no-passcode state.

## 5. Data model

### 5.1 `CycleRecord` (new, `FernletKit/Sources/PrivateHealthStore/CycleRecord.swift`)

```swift
public nonisolated struct CycleRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID                        // random for new logs; deterministic for imports (§8)
    public var dayKey: String                  // yyyy-MM-dd of `loggedAt`, fixed at write — SEALED
    public var loggedAt: Date                  // the date/time the user picked — SEALED
    public var clinical: CycleClinicalFields?  // nil = UNKNOWN (a narrative-only legacy source); empty-but-present = "none"
    public var narrative: CycleNarrativeFields? // nil = UNKNOWN (a samples-only legacy source)
    public var origin: CycleRecordOrigin       // .logged | .importedLegacy | .restored | .adoptedFromHealth — frozen tokens
    public var createdAt: Date
    public var updatedAt: Date
}

public nonisolated struct CycleClinicalFields: Codable, Equatable, Sendable {
    public var flowLevel: PeriodFlowLevel?
    public var isCycleStart: Bool
    public var hasIntermenstrualBleeding: Bool
    public var basalBodyTemperature: Double?   // AS ENTERED; always travels with its unit
    public var temperatureUnit: PeriodTemperatureUnit
    public var cervicalMucusQuality: CervicalMucusQuality?
    public var ovulationTestResult: OvulationTestResult?
    public var updatedAt: Date
    public var isEmpty: Bool { /* no field set */ }
}

public nonisolated struct CycleNarrativeFields: Codable, Equatable, Sendable {
    public var note: String?                    // trimmed, ≤1000 chars
    public var symptomFlags: [PeriodSymptom]    // sorted
    public var customSymptomScales: [String: Int] // ≤40 keys, ≤40 chars
    public var updatedAt: Date
    public var isEmpty: Bool { /* no note, no flags, no scales */ }
}
```

- A record logged from the sheet has **both blocks known** (either may be empty). A record built from
  a v1 narrative (buffer, backup or legacy row) has `clinical == nil`. A record built from legacy
  samples alone has `narrative == nil`. A record with both blocks nil or both empty is never stored
  (an emptied edit deletes).
- `hasClinicalFields` = `clinical?.isEmpty == false`; `hasNarrative` = `narrative?.isEmpty == false`;
  `hasActualBleedingFlow` = `clinical?.flowLevel.map { $0 != .none } ?? false`.
- There is **no `healthMirrorExternalUUID` field** (R2-F11). Every mirror sample carries
  `HKMetadataKeyExternalUUID = id.uuidString`, and every legacy import uses `id = UUID(externalUUID)`,
  so the record id alone identifies Fernlet's copy.
- Codable uses **explicit, frozen `CodingKeys`** plus a schema field `"v": 2` (v1 was revision 1's
  unshipped shape; no v1 record exists anywhere). The same Codable is the sealed-column plaintext AND
  the backup chunk element.
- Decoding is tolerant per token: enums decode as `String` through `init(rawValue:)`; unknown values
  become nil or are dropped.
- New frozen tokens (localization wall): the raw values of `PeriodFlowLevel`, `CervicalMucusQuality`,
  `OvulationTestResult`, `PeriodTemperatureUnit`, `CycleRecordOrigin`, and every `CodingKeys` string.
- `CycleRecord.init(event:id:origin:now:)` applies the existing caps
  (`PeriodTrackerStore.swift:584–590`, `:615–621`) and always sets both blocks.

#### 5.1a Merge rules (one function, used by drain, import, restore, fill-on-read) (R2-F6)

`CycleRecord.merged(_ a: CycleRecord, _ b: CycleRecord) -> CycleRecord` for two records with the same id:
- **Per block**: both known → the block with the later block `updatedAt` wins whole (ties: `a`);
  one known → that one; neither → nil. A block is never mixed field by field, so a flag the user
  cleared cannot come back from an older copy, and BBT always travels with its unit.
- `loggedAt` and `dayKey`: from the side whose clinical block is known (sample start dates are
  exact); else the earlier `createdAt` side's.
- `origin`: `a`'s. `createdAt`: the earlier. `updatedAt`: the later.
- Commutative on content (tested with both argument orders) and idempotent (`merged(x, x) == x`).
- Every batch (drain, import, restore) is first reduced by id with `merged` (duplicate ids inside one
  batch, e.g. the duplicate `hkExternalUUID` narratives `:502–507` tolerates, collapse to one).

### 5.2 Core Data entity (model version 2 of `FernletPrivate`)

The `CycleRecord` entity has three attributes and no others:
- `id` (UUID, indexed)
- `schemaVersion` (Int16; plaintext; payload format only)
- `payloadCiphertext` (Binary; `allowsExternalBinaryDataStorage: false`; a record is under 4 KB)

- **No date, day key, timestamp or HealthKit UUID column.** A pinned test enumerates the attributes (I4).
- **No uniqueness constraint** (see §15 R2-F6): the shared view context's merge policy is
  property-object-trump (`PrivatePersistenceController.swift:125`), which would resolve a constraint
  conflict by silently overwriting the stored row with the in-memory one. Uniqueness is the
  repository's job instead: every write is a fetch-by-id upsert through `merged` (§6.1), and every
  reader reduces by id before use.
- **Row identity is checked after every decrypt (R1-F9).** `ColumnCrypto`'s AAD is
  `purpose ‖ binding` only, shared by every sealed column, so the id is not authenticated. The
  repository requires `decoded.id == row.id`; a mismatch is classified **dead** (skipped, one audit
  line per fetch, counted in the export pre-pass). Binding the id into the AAD would need a second
  `ColumnCrypto` format; the post-decrypt check gives the same guarantee without one.
- **Why no date index:** a load decrypts the table in pages of 500 under `performAndWait`, keeps the
  240-day window and drops the rest. The table is bounded by `maxStoredRecords = 20_000` (R3; past it
  an insert throws `.storeFull`, surfaced). Row count stays observable to local forensics, as the
  narrative table's is today.
- Sealing: `ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.cycleRecordV1)`, a new purpose
  `CryptographicPurpose("fernlet.cycle-record.v1")`. Registration (R1-F7), all in the same commit:
  - `FernletCrypto/CryptographicPurpose.swift`: the declaration.
  - `Tests/FernletTests/CryptographicDomainSeparationTests.swift:56`: a `Domain("KeyDerivation.cycleRecordV1", …)`
    line in `allDomains`, or `theInventoryCoversEveryDeclaredPurpose` (`:177`) fails.
  - `Tests/FernletTests/MeshRoutedItemSealTests.swift:517`: the registry tripwire goes from 76 to
    **78** (this purpose plus `Hash.sealedBackupWriterTagV1`, §9.10) with its acknowledgment comment.
  - `noPurposeIsAPrefixOfAnother` (`:578`): no registered spelling is a prefix of
    `fernlet.cycle-record.v1` or of `fernlet.sealed-backup.writer-tag.v1`, and neither is a prefix of
    another (checked against the current list: the nearest are `fernlet.sealed-backup.aad.v2` and
    `fernlet.sealed-photo.aad.v3`). The test stays the proof.
  - `CryptographicPurposeBoundaryTests`: its framing scan, as today.
- Every mutation prunes persistent history. `deleteAll()` routes through `PrivateRowPlumbing.deleteRows`.
- `purgeEncryptedEntities()` (`:171`) adds `"CycleRecord"`.
- `SealedColumnFormatCensus` (`:289–301`) adds `SealedEntityColumns(entityName: "CycleRecord", ciphertextAttributeNames: ["payloadCiphertext"])`.

**Model version and migration.**
- `makeManagedObjectModelV1()` is today's four entities, **moved verbatim and frozen**, with
  `versionIdentifiers = ["FernletPrivate.v1"]` and a test pinning its `versionChecksum`.
- `makeManagedObjectModel()` returns V2 = V1 + `CycleRecord`, `["FernletPrivate.v2"]`.
- Staged migration with in-memory references on the one store description (`:92–104`); `addStore`
  (`:381–391`) reuses `description.options`:
  ```swift
  let stage = NSCustomMigrationStage(
      migratingFrom: NSManagedObjectModelReference(model: v1, versionChecksum: v1.versionChecksum),
      to: NSManagedObjectModelReference(model: v2, versionChecksum: v2.versionChecksum))
  storeDesc.setOption(NSStagedMigrationManager([stage]), forKey: NSPersistentStoreStagedMigrationManagerOptionKey)
  ```
  Additive, so lightweight. **Verify on the simulator first**; if the staged manager rejects
  in-memory references, fall back to the inferred lightweight migration the synced store relies on
  (`CloudKitSync/Persistence.swift:384–385`, `:796–797`). The on-disk migration test decides.
- The store is **not** synced (`cloudKitContainerOptions = nil`, `:97–98`): no CloudKit schema deploy.
  The entity lives behind the S3 wall; run `Scripts/spm-wall-check.sh`.

### 5.3 Backup bookkeeping for period data (replaces revision 1's reuse of the latch)

- `fernlet.cycleRecord.periodRestoreResolved` (NEW, `UserDefaults`, `Bool`): "this install has
  finished pulling the period backup". While false, the ambient period restore runs (merge, §9.10);
  once true, it never runs ambiently again, which is what stops a stale cloud copy from resurrecting
  entries the user deleted. Set only by the backup coordinator (§9.10). Cleared by the §4.9 coordinator
  and by `onResetCompleted`. **Kept** across delete-all (a cloud copy that survived a failed cloud
  delete must not come back).
- `fernlet.menstrualNarrative.everStored` (existing, frozen spelling) is **read once** at cutover as
  the marker's migration source: set → `periodRestoreResolved = true` (an in-use install whose
  ambient restore was already closed keeps that behaviour). After that it is never written or read
  for period; it keeps its wipe row, and the §4.9 coordinator and `onResetCompleted` clear it.
- Why not keep a store-wide latch: the legacy import and the first log on a fresh install both make
  the store non-empty and latched before the restore can run, which closed the restore forever
  (R2-F5). The resolved marker is about the restore, not about the store.
- `fernlet.sealedBackup.restoreAwaitsOwner` (NEW, `UserDefaults`, `Bool`): set by `onResetCompleted`.
  While set, every ambient restore (launch pass, hub settle, un-hide) skips all payloads; the
  "Restore Sealed backup" action in Privacy & Data (behind its fresh device-owner check) runs them and
  clears it on a non-retryable outcome. Kept across delete-all.
- The journal and intimacy latches keep today's semantics, plus: the §4.9 coordinator and
  `onResetCompleted` clear them (their key is gone, so they can no longer speak for this install).
- Every new key has a row in `Docs/PrivacyWipeCoverage.md` and `PersistedSurfaceWipeBoundaryTests` in
  the commit that adds it, and the existing latch row's "dies with the app container" sentence is
  corrected (it travels in device backups; §4.9 is what handles that).

## 6. Stores and the write/read paths (module `PrivateHealthStore`)

### 6.1 `CycleRecordRepository` (nonisolated, `@unchecked Sendable`, all-`let`; mirrors `IntimacyLogRepository`)

- `upsertMerged(_ records: [CycleRecord], retiringNarrativeIDs: [UUID], contentKey:) -> UpsertResult`:
  **the one write path.** Reduces the batch by id (§5.1a); for each id fetches existing rows by id
  (indexed; more than one legacy duplicate are merged and the extras deleted); decrypts:
  - absent → insert;
  - present and opens → `merged(existing, incoming)`, written only when it changed;
  - present and **dead** (terminal open failure or id mismatch) → replaced by `incoming` (the dead
    ciphertext can never be read; replacing it with an openable copy of the same id loses nothing);
  - present and **transient** (`DeviceBindingID.ReadError`) → the whole call throws; nothing saved.
  Deletes the named `MenstrualNarrative` rows in the same save (both entities share the store and the
  view context, so it is atomic). Returns inserted / merged / replaced counts.
- `insert(_:contentKey:)` = `upsertMerged([record], retiringNarrativeIDs: [])` requiring absence.
- `update(_:contentKey:)`: replace in place by id (no merge: an edit is authoritative), keeps
  `createdAt`, bumps `updatedAt` and the edited blocks' `updatedAt`.
- `records(offset:limit:contentKey:) -> CycleRecordPage` (by id ascending, clamped to 500), where a
  page carries `records`, `deadIDs` and `transientCount`.
- `allRecords(contentKey:)` (paged, bounded by `maxStoredRecords`), `records(ids:contentKey:)`.
- `recordCount()` (keyless), `allIDs()` (keyless, sorted), `delete(ids:)` and `deleteAll()` (keyless).
- Key discipline as the other repositories: writes fail closed without a key, reads degrade to
  empty, a failed seal removes the half-built object (`MenstrualNarrativeRepository.swift:182–194`).
- No divergence latch (§5.3).

### 6.2 `CycleRecordStore` (NEW gated funnel, `@MainActor`; mirrors `IntimacyLogStore`)

- `isVisible: () -> Bool = { false }`, installed only through `attachVisibilityGate`.
- **Gated** (throw `PeriodTrackingHiddenError` or return empty, decrypt nothing): `allRecords`,
  `insert`, `update`, `upsertMerged`, `backupPrePass`, `backupChunk`, `restoreMerging`.
- **Ungated**: `delete(ids:)`, `deleteAll()`, `recordCount()`, `allIDs()`.
- **Mutation hook (R2-F3):** `onMutation: @MainActor () -> Void`, called after every successful
  insert, update, upsert (import, drain, restore, fill-on-read), delete and deleteAll, and a
  monotonically increasing in-memory `mutationCounter`. The app wires it to
  `store.markPeriodBackupDirtyIfEnabled()` (§9.10).
- `PeriodTrackerStore` composes one; `SealedBackupCoordinator` builds its own instance on the same
  derived gate and mutation hook (the intimacy pattern).
- Grep wall: the app target never constructs `CycleRecordRepository(` (beside
  `SensitiveSurfaceGateTests.appTargetNeverConstructsARawIntimacyLogRepository`, `:650`).

### 6.3 `PeriodTrackerStore` after cutover

**Save**: `logEvent(_ event:, unlockedContentKey:) async throws -> PeriodLogOutcome`.
1. G2: `guard isVisible()`, before any seal and any Health call.
2. `record = CycleRecord(event:, id: UUID(), origin: .logged)`.
3. **Seal first.** Key live → `recordStore.insert` → `.sealed`. No live key (hub closed, either mode)
   → `lockService.bufferPendingNarrative(PendingNarrativePayload(cycleRecordJSON: …))` →
   `.pendingUntilPrivateOpens`. **Nothing is ever dropped**; `.savedWithDroppedNarrative` is deleted.
   A seal or buffer failure throws, and nothing has been written to Health.
4. **Mirror second**, only when `healthService.isCycleMirrorEnabled()` and `record.hasClinicalFields`:
   `writeMirror(of: record)`. A throw becomes `.failed(reason)`; the record stays saved (the intimacy
   pattern, `LogIntimacySheet.swift:209–231`).

```swift
public nonisolated struct PeriodLogOutcome: Equatable {
    public enum Storage: Equatable { case sealed, pendingUntilPrivateOpens }
    public enum HealthCopy: Equatable { case notShared, written, removedStaleCopy, failed(HealthCopyFailure) }
    public enum HealthCopyFailure: Equatable { case healthDenied, healthUnavailable, other }
    public var storage: Storage
    public var healthCopy: HealthCopy
}
```

**Edit**: `editRecord(_ id: UUID, with event:, unlockedContentKey: SymmetricKey) async throws -> PeriodLogOutcome`.
- Needs a live key (edit is reachable only from the calendar). **Updated in place under the same id**;
  there is no delete-then-recreate of the source of truth (the `:629–637` hazard disappears).
- Mirror, after the seal: sharing on → `deleteMirror(recordID:)` then `writeMirror`; a write refused
  after the delete leaves Health without that day's copy, never a wrong one, and is reported. Sharing
  off → `deleteMirror(recordID:)`; the outcome is `.removedStaleCopy` **only when it deleted at least
  one sample** (R2-F11), else `.notShared`.
- An emptied edit (`LogPeriodSheet.isEmptiedEdit`) calls `deleteDay` for that record.

**Delete**: `deleteDay(_ entry: CycleDayEntry) async throws -> PeriodDeleteOutcome` (R2-F11).

```swift
public nonisolated struct PeriodDeleteOutcome: Equatable {
    public enum HealthCopy: Equatable { case none, removed, stillInHealth(HealthCopyFailure) }
    public var removedRecordCount: Int
    public var healthCopy: HealthCopy
}
```

- **Fernlet first, then Health.** Ungated and keyless for the rows: `recordStore.delete(ids:)` in one
  save. That save failing throws and nothing was deleted anywhere.
- Then Health, ungated, own source only: `deleteMirror(recordID:)` for each record, plus
  `deleteFernletAuthored(entry.fernletHealthSamples)` for Fernlet-authored samples on that day with no
  record (orphan copies from the other phone or an earlier install). Result: `.removed` (≥1 deleted),
  `.none` (nothing there), or `.stillInHealth(reason)` on a throw.
- The detail maps each outcome to a sentence (§10.4). After `.stillInHealth`, the day reloads as a
  Health-only Fernlet day, whose "Delete from Apple Health" retries the Health half (§7.3).
- Why Fernlet first (revision 1 order kept, with the outcome added): Health refusing a delete is often
  permanent (share access revoked in the Health app). Health-first would make such a day undeletable
  in Fernlet forever. The user asked to delete the entry; Fernlet's copy is the source of truth.
- Prediction recompute stays key-gated (`:680–688`).

**Load**: `loadEntries(unlockedContentKey:)`.
1. G1 before any read; a nil key scrubs and returns.
2. Health half, only when `healthService.isCycleHealthReadEnabled()`:
   `loadHealthCycleSamples(in: 240 days)`, capped at `maxLoadedSamples` (`:390`). Otherwise `[]`, no call.
3. Post-await recheck of visibility, the live key and the writer epoch (§8.4), unchanged in shape
   (`:493–500`).
4. `recordStore.allRecords(contentKey:)`, reduce by id (§5.1a), filter to the window.
5. **Match** each Fernlet-authored sample group to a record by id: `HKMetadataKeyExternalUUID` or
   `FernletCycleRecordID` equal to `record.id.uuidString` (or, for a sample with neither, the derived
   legacy id of §8.2).
6. **Fill-on-read (R2-F6):** a matched record whose clinical block is **unknown** gets it from the
   samples (`clinical.updatedAt` = the samples' latest end date) through `upsertMerged`, synchronously
   under the same checks as the import's write (§8.4). This completes a record; it can never create
   one or resurrect a deleted one.
7. **Dedupe:** hide a Fernlet-authored sample group only when its matched record's clinical block is
   **known** (the record is authoritative). Unmatched Fernlet samples and every other app's samples
   stay, read-only.
8. `buildEntries(records:healthSamples:range:)`, `currentPhase`, the prediction (key-gated).

`loadEntries` is split into read, match/fill, dedupe and build helpers (≤ 60 lines each).

**Drain**: `drainPendingBuffer(contentKey:)` stays G2-gated as a silent no-op. A v2 payload decodes
to a `CycleRecord`; a v1 payload becomes a narrative-only record (`clinical == nil`) with
`id = UUID(uuidString: hkExternalUUID) ?? UUID()` and `origin: .importedLegacy`. All go through **one**
`upsertMerged(…, retiringNarrativeIDs: [])`, so a partial drain re-drains without duplicates and a
v1 narrative merges with its legacy samples later (the case R2-F6 describes now keeps the cycle-start
and spotting flags, because the clinical block arrives whole from the samples). Purge only after the
save.

### 6.4 `CycleDayEntry` reshaped

```swift
public nonisolated struct CycleDayEntry: Identifiable, Equatable {
    public var id: String { dateKey }
    public var date: Date
    public var dateKey: String
    public var records: [CycleRecord]              // Fernlet-owned, newest updatedAt first
    public var fernletHealthSamples: [HKSample]    // Fernlet-authored samples with no matching record (read-only)
    public var otherHealthSamples: [HKSample]      // other apps' samples (read-only)
    public var phase: CyclePhase                   // .menstrual iff hasActualBleedingFlow
}
```

- Derived accessors (`flowLevel`, `isCycleStart`, `hasIntermenstrualBleeding`, `cervicalMucusQuality`,
  `ovulationTestResult`, `basalBodyTemperatureFahrenheit`, `hasActualBleedingFlow`) take the first
  record whose clinical block sets the field, then fall back to the Health sample decoders (`:242–299`).
- `notes`, `symptomFlags` (union, sorted), `customSymptomScales` (max per key), `primaryRecord`,
  `hasObservedEvent`, `hasNarrative` (any record's narrative block non-empty), `healthSourceNames`.
- `phase` fixes today's "any flow sample, even None, is menstrual" (`:757–759`).
- `CyclePredictionEngine` uses only `flowLevel`, `date` and `detectedPeriodStarts`
  (`CyclePredictionEngine.swift:186–188`). No change.
- **`PeriodContextBridge.buildObservations`** (`PeriodContextBridge.swift:425`) becomes
  `let symptomLoad = entry.hasNarrative ? Double(entry.symptomFlags.count) / Double(PeriodSymptom.allCases.count) : nil`.
  This is today's semantics exactly: today the load is nil unless a narrative exists, and a Fernlet
  flow-only day never had one. Keying on `records.isEmpty` (R2-F9's suggestion) would turn every
  flow-only day into a 0.0 observation. (R2-F9)

### 6.5 The pending buffer (`PrivateStoreCore/PendingNarrativeBuffer.swift`)

- `PendingNarrativePayload` gains `public let cycleRecordJSON: Data?` (optional, so v1 files decode).
  File name, keychain service, `FNB2` marker and AAD unchanged.
- The cap becomes **200 entries; append at the cap throws `PendingNarrativeBufferError.full`** instead
  of evicting (`:176–181`). Sheet copy in §10.4.
- **Key custody (R1-F5):** `bufferKey()` reads with `KeychainItem.loadDistinguishingAbsence`. It mints
  only on `.absent`, and only when the buffer file is absent or empty. `.unreadable` throws
  `.keyUnreadable` (append fails with the "couldn't save right now" error, nothing lost; drain retries
  at the next open). Key `.absent` while the file is non-empty throws `.bufferUnopenable`: the
  entries in it can never be opened, so the key is not re-minted over them. The log sheet says so
  (§10.4), and the §4.9 card offers to remove the file. The legacy service-less migration runs only on
  a v2 `.absent`.
- The silent wipe now destroys the buffer key and file (§4.3). Delete-all and reset purge the file
  (today). `KeyCustodyBoundaryTests` gains `bufferKeyIsNeverMintedOverAnUnreadableRow`, beside
  `deviceSealingKeyIsNeverMintedOverAnUnreadableRow`.

## 7. Apple Health mirror and reading other apps' data

### 7.1 The seam (`PeriodHealthKitServicing`, `PeriodTrackerStore.swift:307–327`, replaced)

```swift
public protocol PeriodHealthKitServicing: AnyObject {
    func isCycleMirrorEnabled() -> Bool                                  // isWriteSharingEnabled(for: .cycleTracking)
    func isCycleHealthReadEnabled() -> Bool                              // isCapabilityRequestedAndEnabled(.cycleTracking)
    func cycleReadAuthorizationDetermined() async -> Bool                // authorizationRequestStatus(for: .cycleTracking) == .unnecessary
    func writeMirror(of record: CycleRecord) async throws                // gated (requireWriteSharing + share grant)
    func deleteMirror(recordID: UUID) async throws -> Int                // UNGATED, own source only; returns samples deleted
    func deleteFernletAuthored(_ samples: [HKSample]) async throws -> Int // UNGATED, pre-filtered to own source
    func loadHealthCycleSamples(in range: DateInterval) async throws -> [HKSample] // [] where unreadable (today's rule)
    func loadLegacyFernletCycleSamples(limit: Int) async throws -> [HKSample]      // own source, NO marker, all time; THROWS on any error
}
```

- `checkPeriodEventWriteAllowed` and `savePeriodEvent` are retired.
- `HealthKitService.periodSamples(for:externalUUID:)` (`:2843`) stays the one sample builder, now
  taking `recordID:` and stamping `HKMetadataKeyExternalUUID = recordID.uuidString` and
  `FernletCycleRecordMirror.recordIDKey = "FernletCycleRecordID"` (a **frozen at-rest token in
  Health**; it is what tells a post-cutover mirror from a pre-cutover sample, §8).
- `deleteMirror` queries the five period types (`periodSampleTypes`, `:2874`) with
  `predicateForObjects(from: HKSource.default())` AND the external-UUID predicate, deletes, and returns
  the count. Audited by type only.
- `loadLegacyFernletCycleSamples` deliberately does **not** use the unrequested-type→`[]` rule
  (`isUnrequestedReadError`, `:2822`): an empty answer there must mean "none", never "not asked" (R2-F8).
- `HealthKitWriteGateTests` adds `writeMirror` to its scan.

### 7.2 Policy
- Write: only when cycle sharing is on (master plus Cycle).
- Read other sources: only when the cycle capability is requested and enabled. Otherwise the calendar
  is Fernlet-only and no HealthKit read happens.
- Health data is shown read-only, labelled "From Apple Health · <source name>". It counts for
  predictions and observed flow and is never imported ambiently (except §8), sealed, backed up or
  exported (Q3).
- Turning sharing on later is forward-only (Q2). Turning it off leaves existing copies in Health; an
  edit or delete of such a day removes Fernlet's stale copy (Q1).
- The contextual Health ask on the Cycle page and the log sheet (`CycleTrackerView.swift:577–584`,
  `LogPeriodSheet.swift:258–265`, `HealthAccessGrant.swift:32–46`) is removed (Q4). Cycle sharing is
  turned on only in Settings › Health, which requests read and share for the cycle types.

### 7.3 Health-only days that Fernlet wrote (R2-F8)

A day whose only data is `fernletHealthSamples` (Fernlet's copies with no record here: the other
iPhone's mirrors, an earlier install's, or a copy whose Health delete failed) offers two explicit
actions in the day detail:
- **Keep in Fernlet**: builds a record from the day's Fernlet samples (`id = UUID(externalUUID)`,
  clinical known, narrative unknown, `origin: .adoptedFromHealth`) through `upsertMerged`.
- **Delete from Apple Health**: `deleteFernletAuthored` for those samples, with the §10.4 copy
  ("This removes Fernlet's copy from Apple Health on all your devices").
Other apps' samples get neither (Fernlet cannot delete them and does not import them).

## 8. Migration of existing data (idempotent, two halves, re-runnable until done)

### 8.1 Trigger and ordering

`PeriodTrackerStore.runLegacyImportIfNeeded(contentKey:)`, awaited from
`CycleTrackerView.loadPeriodIfUnlocked` **after the drain and before the load**, when:
1. The period gate is visible (G2 semantics: a silent no-op while hidden).
2. A key is live (hub open, either mode), and no duress session.
3. At least one half is pending (§8.2, §8.3).

There is no "restore before import" condition any more. The restore is an id-keyed merge (§9.10), so
the import and the restore commute: whichever runs first, the other merges into it by deterministic
id. Revision 1's `legacyImportMayRun()` read an in-memory outcome that was nil in common states
(R2-F5) and is deleted.

### 8.2 Narrative half (`fernlet.cycleRecord.legacyImport.narratives`: absent = pending, `"done"`)

1. Page every `MenstrualNarrative` row under K (bounded: page count × 500). Classify each: opens →
   convert to a narrative-only record (`id = UUID(hkExternalUUID) ?? derived`, `clinical == nil`,
   `origin: .importedLegacy`, `dayKey` from the narrative, `loggedAt` = that day's midnight until a
   clinical block supplies an exact time); **transient** → stop, the half stays pending; **dead** →
   leave the row and count it.
2. `upsertMerged(converted, retiringNarrativeIDs: convertedIDs)`: one atomic save.
3. Done when `narrativeCount() == deadCount`. Dead rows are listed on the §4.9-style card inside the
   Cycle page ("N earlier cycle notes can't be opened on this iPhone", Remove / Not now); removing
   them is an explicit keyless delete. Marker set to `"done"` only then (R2-F8: a transient keychain
   failure can no longer finish the import with notes left behind).

### 8.3 Sample half (`fernlet.cycleRecord.legacyImport.samples`: absent = pending, `"done"`)

1. Runs only when `cycleReadAuthorizationDetermined()` is true (every cycle type has been requested,
   so an empty read is an honest "none"); otherwise it stays pending with no HealthKit call (R2-F8).
2. `loadLegacyFernletCycleSamples(limit: 20_000)`: own source, **unmarked** (no `FernletCycleRecordID`),
   all time. Any error → pending.
3. Group by `HKMetadataKeyExternalUUID`. A sample with none groups under
   `sha256("legacy|<startDate epoch>")` formatted as a UUID (defensive: every builder since the
   external UUID shipped stamps one; none is known to lack it).
4. Build one samples-only record per group (clinical known from the decoders moved out of
   `CycleDayEntry`, `loggedAt`/`dayKey` from the samples' start date, `narrative == nil`,
   `origin: .importedLegacy`) and `upsertMerged` them in one save. Existing records are completed,
   never overwritten (§5.1a).
5. Marker `"done"` after a clean pass.

Marked (post-cutover) mirrors are never imported ambiently: a marked sample with no record is either a
copy whose record the user deleted here, or another iPhone's entry. Both surface as Health-only
Fernlet days with explicit actions (§7.3).

### 8.4 Cancellation, ordering and delete-all (R2-F7)

- The import runs in `PeriodTrackerStore.legacyImportTask`, a held task. `cancelBackgroundWriters()`
  cancels it and bumps an in-memory `writerEpoch`. ContentView wires the funnel's new
  `periodWritersStopHook` to it, and `FernletStore.stopWritersForWipe` (`:5698–5711`) calls the hook
  beside `periodBackupSettleTask?.cancel()`.
- Inside the task the order is fixed: (1) the HealthKit read (the only await); (2) recheck
  `isVisible()`, `isContentKeyStillLive(K)` (`:531`), `writerEpoch` unchanged, not cancelled;
  (3) decrypt the narratives (synchronous); (4) build; (5) `Task.checkCancellation()` and the epoch
  check again, then `upsertMerged` synchronously under `performAndWait`. Nothing awaits between (3)
  and (5). Fill-on-read (§6.3 step 6) uses the same checks.
- **Delete-all and reset set both halves to `"done"`.** A pending sample half would otherwise
  re-import, at the next hub open, the Health copies the user chose to keep while deleting their
  Fernlet data. Both keys are new persisted surfaces: rows in `Docs/PrivacyWipeCoverage.md` and
  `PersistedSurfaceWipeBoundaryTests` ("set to done by delete-all and reset; cleared by uninstall").

Properties: running either half N times equals running it once (deterministic ids, `upsertMerged`);
the HealthKit samples stay in Health as the mirror of the imported records; the v1 buffer entries go
through the drain with the same ids; after both halves are done `MenstrualNarrativeRepository` holds
only dead rows, if any. Keep the type as a legacy reader and keep its `deleteAll()` in the delete-all
funnel; a later round removes the entity in a V3 model.

Assumption to verify on device: HealthKit returns an app's own samples when read access was denied
after being requested (Apple's documented behaviour). An empty read with a non-empty narrative half
simply leaves narrative-only records, which fill-on-read or "Keep in Fernlet" can complete later.

## 9. Every seam this touches

| # | Seam | Change |
| --- | --- | --- |
| 9.1 | **Calendar** `CycleTrackerView` + `MonthCalendarCard` | Day tint and flow from `entry.flowLevel`. `entry(for:)` (`:640–647`) builds the new empty entry. "Recent events" (`:540–556`) reads `entry.symptomFlags`. Remove the contextual Health ask (Q4). Order after unlock: drain → `runLegacyImportIfNeeded` → load. `deleteDay` (`:331–343`) maps `PeriodDeleteOutcome` (§10.4). |
| 9.2 | **Day detail** `CycleDayDetailView` | "Your entry" (records' fields, note, symptoms), "From Apple Health · Fernlet" rows for `fernletHealthSamples` with **Keep in Fernlet** and **Delete from Apple Health** (§7.3), and "From Apple Health · <source>" rows for other apps (read-only). `hasCycleLog = !entry.records.isEmpty`; a day with no record offers **Log this day**. Delete copy in §10.4. |
| 9.3 | **Log sheet** `LogPeriodSheet` | `editingEntry` → `editingRecord: CycleRecord?` (seeded losslessly from the blocks). Delete `lockWarning`, `unkeepableEntryProblem`, the sharing-off/noLock refusal arms. `present(_:)` maps `PeriodLogOutcome` (§10.4). Keep capture protection, the draft guard, freeze-on-caveat and single-flight. |
| 9.4 | **Predictions** `CyclePredictionEngine` | No code change; fixtures build `CycleRecord`s. |
| 9.5 | **Scoring softening** `PeriodContextBridge` / `FernletStore.periodAdjustment` | `refreshPeriodContext(unlocked:)` reads `isUnlocked(for: .privateHub)`, so a tap session gets the same softening a passcode session does; still hub-session-only. `buildObservations` keys `symptomLoad` on `entry.hasNarrative` (§6.4). |
| 9.6 | **Home / widgets** | **Deliberately unchanged, and now said so (R2-F13).** The `.logPeriod` highlight (`HomeView.swift:1428–1431`, `refreshRecentPeriodActivity` `:1512–1537`) and `.periodTracking` (`healthContext.cycle`) stay HealthKit-only behind `allowedHealthCapabilities`, which drops cycle reads unless `.privateHub` is unlocked (`FernletStore.swift:2495–2509`). Home is never on screen during a hub session (leaving the tab scrubs, `ContentView.swift:1324–1347`), so for every user, in both passcode modes, these two highlights are dark on Home today and stay dark. Lighting them from Fernlet records would need K outside the hub, or a persisted "bled in the last 30 days" bit readable from Home; both are exactly the ambient exposure the hub gate exists to prevent. `homePeriodPrediction` stays hub-session-only. Widgets carry no cycle data. Q11. |
| 9.7 | **AI / memory** | Unchanged and pinned (spm-wall; `AIContextPayload` forbids period data). |
| 9.8 | **Exports** | Unchanged allowlists (Q7). |
| 9.9 | **Health context in the day blob** | Unchanged: HealthKit-derived, stripped from synced rows, never populated from the sealed store. |
| 9.10 | **Sealed iCloud backup** | See §9.10 below. |
| 9.11 | **Delete-all** `FernletStore.deleteAllData` + `ContentView.attachDeleteAllHooks` | `periodDataDeleteHook` → `recordStore.deleteAll()` AND `MenstrualNarrativeRepository().deleteAll()` (both keyless; report either failure). New `periodWritersStopHook` in `stopWritersForWipe` (§8.4). Both import halves set to `"done"`. `periodRestoreResolved` and `restoreAwaitsOwner` kept. The period compare-and-swap record is cleared with the generation marks (`generationStore.reset()`, `:5769`). **The device row is kept**: the lock keychain is delete-all's documented survivor, and a no-passcode K is lock custody exactly as a passcode user's K is. Keeping it is also what keeps the resolved marker meaningful, since the next open reuses the same K. Revision 1's `deviceContentKeyDestroyHook` is dropped. Buffer purge, store rebuild and the HealthKit authored-sample delete are unchanged. Confirm copy names "your cycle history" with the existing Health choice. |
| 9.12 | **Duress** | `destroyLocalUnlockKeys` gains `.deviceContentKey`, and in silent-wipe mode the buffer key and file (§4.3). The decoy is keyless → period store inert. `duressPurgeHook` → `deleteAllData` inherits 9.11. Duress modes never fire `onResetCompleted`. |
| 9.13 | **Visibility gate** (derived `periodTrackingVisible ?? sex == .female`) | Enforced in `CycleRecordStore` (reads, writes, upserts, drain, import, backup pre-pass/chunk/restore) and before every HealthKit cycle read in `PeriodTrackerStore`. Scrubs stay keyed to the derived VALUE (`ContentView.swift:137–145`). Never wired to `sealedBackupPeriodEnabled`. |
| 9.14 | **Scoped unlocks** | The tap grants `.privateHub` only; `revokeUnlockOutside` on appear works through `unlockedScope`. Progress-photo and App-lock-settings gates stay `active: lockService.isLockConfigured`. Settings › App lock with no passcode is reachable ungated (as today), which is why adoption carries its own owner check (§4.4 step 3). |
| 9.15 | **Capture protection** | `FernletLockGateOcclusion.overlayIsUp` (`FernletLockGate.swift:482–486`) is true for the closed tap gate and for the §4.9 card, false once opened; `CaptureOcclusionGatingTests` gains both states. |
| 9.16 | **Intimacy** | `LogIntimacySheet` passes `contentKey(for: .privateHub)`, now K in a tap session, so intimacy entries save without a passcode. Its "seal first, Health second" shape is §6.3's template. |
| 9.17 | **Journal / Worry Box** | The tap state activates them like `.unlocked(.privateHub)`. `.notConfigured` now means CLOSED → deactivate (device keys stay the write fallback while closed). `activateNoLockJournals` and `JournalActivationMode.noLock` are deleted. `JournalNarrativeRepository.reencryptAll(from:to:)` (bounded paging; opens under the device key, re-seals under K, skips rows that do not open under it) replaces the window-only fold, so older journal entries written from Home are readable in the hub. Worry: the new state maps to `.unlocked` + fold. |
| 9.18 | **Privacy & Data** | With no passcode, enter through the existing fresh check (`freshVerificationGate`, `.deviceOwnerAuthentication`) instead of `lockSetupInterstitial` (Q5). New "Restore Sealed backup" action (shown while `restoreAwaitsOwner` is set, and as the explicit restore in the "held by another iPhone" state). New period-backup status rows (§10.6). |
| 9.19 | **Settings › App lock** `SettingsSheet` | No-passcode status: "No passcode. Private opens with a tap." Passcode: **Turn off passcode** in the Manage card → confirmation (§10.3) → current-passcode entry → `removeCredential`. "Set up passcode" with existing data runs the owner check (§4.4). Searchable via `SettingsSearchIndex`. |
| 9.20 | **Onboarding** `OnboardingLockSetupView` | "You can skip this. Without a passcode, Private opens with a tap." Logic uses `isLockConfigured`. |
| 9.21 | **Reset funnel** (NEW, app) | `lockService.onResetCompleted` → clear the three latches and `periodRestoreResolved`, clear the period compare-and-swap record, set `restoreAwaitsOwner`, set both import halves `"done"`. Wired once in ContentView, so both reset entry points (`FernletLockGate` and `SettingsSheet.resetAppLock`) get it. |

### 9.10 Sealed backup, in detail

**Key (R2-F1).** `SealedBackupContext.sealedBackupContentKey` stops reading the journal coordinator.
`FernletStore` gains an injected `hubContentKeyProvider: (() -> SymmetricKey?)?`, which ContentView
sets to `{ [lockService] in lockService.contentKey(for: .privateHub) }`, and
`sealedBackupContentKey` returns `hubContentKeyProvider?()`. The coordinator already reads the key at
each write point after the CloudKit awaits (`SealedBackupCoordinator.swift:570`, `:1250`, `:1267`,
`:1288`); the export reads it once at the start of a pass and passes it down (as today). This fixes
the period and intimacy settles on the Cycle section for both passcode modes, including today's
intimacy bug. Pinned by a ContentView-level test: unlock on the Cycle section with a period export and
a targeted intimacy restore pending; assert both run with a non-nil key.

**Payload.** `SealedBackupPayloadType.periodData` keeps its raw value (record name and AAD, frozen).
Record crypto and chunking are unchanged. Chunk plaintexts become:
- head (chunk 0): `{"v":2,"writer":"<32 hex>","total":N,"records":[CycleRecord…]}`
- chunks 1…n−1: `{"v":2,"records":[CycleRecord…]}`

`writer` = the first 16 bytes of `SHA256(Hash.sealedBackupWriterTagV1.data ‖ DeviceBindingID.current())`,
hex. A new registered purpose, `CryptographicPurpose("fernlet.sealed-backup.writer-tag.v1")` (§5.2).
It names the install that wrote the set; it is inside the escrow-sealed plaintext, so it adds no
plaintext field to CloudKit. An unavailable binding defers the export (transient).

**Restore = id-keyed merge (R2-F5, R1-F2, R2-F2).** `CycleRecordStore.restoreMerging(records, contentKey:)`
(gated, atomic, one `upsertMerged`): inserts ids absent here, completes present ones by §5.1a,
replaces dead ones, never deletes an openable local record and never overwrites a newer block. Both
shapes restore: v2 decodes directly; a bare JSON array is v1 `[MenstrualNarrative]`, converted to
narrative-only records with deterministic ids and `origin: .restored`. The period arm of
`isEmptyStoreForRestore` (`:1347–1348`) and the targeted restore's latch guard (`:967`) are replaced
by the resolved marker:
- **Ambient** (launch pass `:743`, the Cycle settle, un-hide): runs while
  `!periodRestoreResolved && !restoreAwaitsOwner`, with iCloud sync on, period backup on, visible,
  and K live. Not live → `.deferredLocked`, retried at the next hub settle.
- **Explicit** (Retry, "Restore it here", Privacy & Data "Restore Sealed backup"): always allowed. The
  confirmation says entries deleted on this iPhone since that backup may come back.
- `periodRestoreResolved = true` after a non-retryable outcome (`.restored`, `.nothingToRestore`), or at
  a hub settle when there is nothing to restore from on this install (iCloud sync off, or period backup
  off). `.notRecognized` and `.rolledBack` stay unresolved and keep today's needs-attention status.
- After any successful restore, record the compare-and-swap pair (below) as the set just merged.

**Export guards, in order.** `reconcilePeriodBackup` runs only when all hold:
- **E1 restore first**: `periodRestoreResolved`. A fresh install cannot export over the cloud copy
  before pulling it (replaces the empty-store guard; an empty store after resolution is a real
  "everything was deleted" and exports as such).
- **E2 compare-and-swap (R2-F4)**: fetch the cloud head (chunk 0; generation and writer need one
  open). Allowed when there is no head, or when the head's `(writer, generation)` equals
  `fernlet.sealedBackup.periodAcceptedHead` (NEW `UserDefaults` string `"<writer>:<generation>"` in
  the generation store's namespace, set after every successful own export and every successful
  restore; a v1 head uses writer `"v1"`). Otherwise refuse with the named state
  `.heldByAnotherDevice` (§10.6). A head that will not open refuses with today's needs-attention
  status. One-time seed for the update: a v1 head whose generation equals this device's
  `lastSeen(.periodData)` is treated as this device's own last write.
- **E3 full pre-pass (R2-F12)**: before the first write, take a keyless id snapshot (`allIDs()`), then
  decrypt every record once, classifying opens / dead / transient. Any transient → defer (retry at the
  next settle). Any dead → refuse with the named state "N entries can't be opened" (after §4.9 this is
  only tampering or corruption) and nothing is written. Only when every snapshot id opens does
  `reconcileChunked` run, and its chunk closure fetches chunk *i* as `records(ids: snapshot[i·250 ..< (i+1)·250])`,
  so a page can never shift under a concurrent edit. A record deleted mid-export is simply absent from
  its chunk; one added mid-export is left for the next export (its mutation re-marked the backup dirty).
- **E4** visible (G5), K live at the start of the pass.
- **Generation floor**: the set is minted at `max(lastSeen(.periodData), head.generation) + 1`
  (`reconcileChunked` gains `generationFloor:`), so a device whose own counter is behind never writes a
  set another device's restore would reject as `.rolledBack`.

**Dirty re-export (R2-F3).** `store.markPeriodBackupDirtyIfEnabled()` (the `CycleRecordStore` mutation
hook) sets the existing persisted `sealedBackupPeriodReuploadDeferred` when `sealedBackupPeriodEnabled`
is on. It never touches `sealedBackupPeriodEnabled`. The Cycle settle's
`retryDeferredSealedPeriodBackupIfNeeded` then exports behind E1–E4 at the next hub session. The flag is
cleared only when the export succeeded AND `mutationCounter` did not move since the pre-pass; a relaunch
re-exports once, which is harmless. Invariant I29: after any mutation followed by a hub session with the
guards satisfied, the cloud record count equals the local count.

**Replacing the other iPhone's copy (explicit).** In the `.heldByAnotherDevice` state Privacy & Data
offers "Restore it here" (explicit merge; afterwards E2 passes because this install has now seen that
head) and "Replace it with this iPhone's history" (confirmation in §10.6; exports with E2 waived, still
behind E1, E3, E4 and the generation floor). Nothing overwrites another device's set silently. The
compare-and-swap is read-then-write, not atomic in CloudKit: two phones exporting within the same second
can still race, as today. Stated in §12.

**Stated consequences.**
1. **Cross-device restore needs iCloud Keychain.** The backup is sealed under the escrow key, minted
   `ThisDeviceOnly` and promoted to synchronizable only after a later launch confirms no conflict
   (`IdentityService.swift:881–905`). On a new iPhone without iCloud Keychain, or before promotion,
   the restore reports `.deferredKeyNotSynced` (today's status) and waits.
2. **A new iPhone set up from an iCloud or Finder device backup** brings the sealed store file and the
   bookkeeping but never K, the enclave key or `DeviceBindingID`. The first open meets §4.9 (the dead
   rows are named and removed on the user's tap, the bookkeeping is cleared), then the ambient merge
   restore brings the history back, re-sealed under this iPhone's own K.
3. **The same iPhone erased and restored** gets the unrecoverable card (§4.7). After the reset, the
   restore waits for the explicit, device-owner-checked "Restore Sealed backup" (§5.3).
4. **Without Sealed backup, cycle history is lost with the iPhone** (erase, loss, replacement), except
   Fernlet's Health copies made while sharing was on, which a new install shows as Health-only Fernlet
   days with "Keep in Fernlet" (§7.3).
5. **The passcode never protected the cloud copy** (true today). Whoever controls the Apple Account and
   a trusted device can restore it into Fernlet; after an app-lock reset that path now asks for Face ID
   or the iPhone passcode first (Q14).
6. **Two iPhones, one period slot** (§12, Q9).
7. **The device backup exclusion toggle** is unchanged (Q13). On every enclave iPhone the sealed store
   inside a device backup can never be opened on other hardware or after an erase, and §4.9 is what
   makes its arrival harmless.

## 10. UI, copy, localization, accessibility

User-facing copy follows the plain voice rule: no em dashes, no "locked/protected/secured" for the
no-passcode state.

### 10.1 The tap gate (FernletLockUI)

In `FernletLockGateModifier`, when `isNotConfigured` and not awaiting recovery, replace
`setupCTAOverlay` with `tapGateOverlay`. The setup CTA stays for the awaiting-recovery state only.

**The only interactive control is one button, "Unlock".** Layout, top to bottom: a decorative
`lock.open` symbol (`accessibilityHidden`); the heading "Private"; the body "Your journal, cycle and
worry entries are here."; the honest line (Q6) in `.bodySmall` slate: "No passcode is set, so anyone
using your unlocked iPhone can open this page. Your entries stay encrypted on this iPhone. You can add
a passcode in Settings."; the Unlock button.

The button calls the app's `PrivateHubOpenCoordinator.open()` (§4.9), passed into the gate as a
closure so FernletLockUI gains no app dependency. Errors: `.contentKeyTemporarilyUnavailable`,
`.keychainFailure` and `.deviceCustodyInconsistent` show "Fernlet can't open this right now. Try again
in a moment." with the button kept; `.contentKeyUnrecoverable` shows the unrecoverable card.

All strings go through a new `GateCopy.Tap` enum with `String(localized:…, bundle: .module, comment:)`
in `FernletLockUI/Localizable.xcstrings`.

Accessibility: `.isModal`, content `accessibilityHidden(overlayIsUp)`, the ScreenChanged post on the
rising edge (`FernletLockGate.swift:177–192, :220–229`); the button ≥ 44 pt (`fernletTapTarget`),
label "Unlock", hint "Opens your private entries. No passcode is needed."; `fernletWrappingText`;
identifier `lock.tapGate.unlock`; nothing automatic on appear.

### 10.2 "Some entries can't be opened here" (the §4.9 card)

- Heading: "Some entries can't be opened here"
- Body: "This iPhone has entries that were encrypted on another iPhone, or before this iPhone was
  erased. The key that opened them never leaves the iPhone it was made on, so no one can open them
  now." Then the counts by kind ("12 cycle entries, 3 intimacy entries, 5 journal entries").
- When period, journal or intimacy backup is on: "Your Sealed backup will be restored after you
  continue."
- Buttons: "Remove them and open Private" (destructive role) and "Not now".
- Identifiers `lock.unopenable.remove`, `lock.unopenable.notNow`. Strings in `GateCopy.Unopenable`.
- The Cycle page's narrative-half variant (§8.2) uses the same component with "earlier cycle notes".

### 10.3 Settings › App lock

- Status: `.notConfigured` and `.openedWithoutPasscode` read "No passcode" with the subtitle "Private
  opens with a tap."
- **Turn off passcode** confirmation: "Turn off the passcode? Private will open with a tap instead.
  Your entries stay encrypted on this iPhone and nothing is deleted. Face ID unlock, your duress code
  and any recovery device are removed." Buttons "Turn off passcode" / "Cancel" (not destructive-red).
  Then the current-passcode entry (reusing the `FernletLockChangePasscodeView` component).
  `.invalidPasscode` reads as a mistype (duress included, §4.5).
- Setting a passcode with existing data first shows the system Face ID / iPhone passcode prompt
  ("Confirm it's you before setting a passcode.").

### 10.4 Log sheet and day detail outcome copy (app catalog; `LocalizedStringKey` / `String(localized:)`)

- Health notice while sharing is off (replaces both variants at `:326–341`, identifier
  `logPeriod.healthNotice` kept): "Saved privately in Fernlet. Fernlet isn't copying cycle entries to
  Apple Health. You can turn that on in Settings › Health."

| Storage | HealthCopy | Sheet | Sentence |
| --- | --- | --- | --- |
| sealed | notShared / written | dismiss | none |
| pendingUntilPrivateOpens | notShared / written | freeze + Done, `.success` | no passcode: "Saved. It will be on your calendar the next time you open Private."; passcode: "Saved. It will be on your calendar the next time you unlock Private." |
| any | failed (log) | freeze + Done, `.success` | "Saved in Fernlet, but Apple Health didn't get a copy: …" |
| any | failed (edit) | freeze + Done, `.success` | "Saved in Fernlet. Apple Health no longer has a copy of this day: …" |
| any | removedStaleCopy | freeze + Done, `.status` | "Saved. Cycle sharing is off, so Fernlet removed its older copy of this day from Apple Health." |

- Errors (nothing saved; the sheet stays open, the draft is kept): hidden ("Period tracking was just
  hidden in Settings, so this entry wasn't saved…"); `bindingUnavailable` / `keyUnreadable` ("This
  iPhone couldn't encrypt your entry just now, so nothing was saved. Your entry is still here. Try
  again in a moment."); buffer full ("Fernlet is holding your recent entries until you next open
  Private. Open Private once, then save this again."); buffer unopenable ("Fernlet can't add to the
  entries it's holding for Private. Open Private to sort this out."); store full ("Fernlet's cycle
  history is full on this iPhone.").
- Delete outcomes (day detail): `.removed` / `.none` → the detail pops, no sentence;
  `.stillInHealth` → "Removed from Fernlet. Apple Health still has Fernlet's copy of this day because
  Fernlet can't change it right now. You can delete it in the Health app, or here later." (the detail
  pops to the calendar, where the day shows as a Health-only Fernlet day). A thrown Fernlet-half
  failure keeps today's "That day is still here. Try again in a moment."
- Day delete confirmation: "This removes the entries Fernlet saved for <date> and Fernlet's copies of
  them in Apple Health. Entries from other apps stay in Apple Health. It can't be undone."
- Health-only Fernlet day: "Keep in Fernlet" / "Delete from Apple Health"; the latter confirms "This
  removes Fernlet's copy of this day from Apple Health on all your devices."
- Every sentence is announced once via `FernletAnnouncer`, never containing the note
  (`LogPeriodSheet.swift:~866–882`).
- Retire `logPeriod.refusal.sharingOff*`, `logPeriod.refusal.notesNeedLock`,
  `logPeriod.refusal.healthDenied*`; prune with `Scripts/sync-string-catalogs.sh`. **Catalog commit
  last**: another session holds uncommitted `App/Fernlet/Localizable.xcstrings` in the primary checkout.

### 10.5 Loss copy rewritten (R1-F4, R2-F10)

The meaning of each string changes, so each gets a **new key** and the old key is retired (a changed
meaning under an old key would keep any translation of the old promise). Unconditional wording is used
on purpose: FernletLockUI cannot see the Health switches, and "anything Fernlet copied to Apple Health
stays there" is true whether or not sharing was ever on.

| Old key (retired) | New key | New text |
| --- | --- | --- |
| `lock.disclosure.forgottenPasscode` (`FernletLockView.swift:261–264`) | `lock.disclosure.forgottenPasscode.v2` | "If you forget your passcode, your journal, cycle history and intimacy entries saved in Fernlet can't be opened again. Anything Fernlet copied to Apple Health stays there. Sealed backup in Privacy & Data keeps an encrypted copy you can restore." |
| `lock.reset.required.body` (`:951–955`) | `lock.reset.required.body.v2` | "You must reset app lock to continue. Your journal, cycle history and intimacy entries saved in Fernlet will be deleted." |
| `lock.reset.confirm.message` (`FernletLockGate.swift:54–58`) | `lock.reset.confirm.message.v2` | "Your journal, cycle history and intimacy entries saved in Fernlet will be permanently deleted. Anything Fernlet copied to Apple Health stays there. If Sealed backup is on, you can restore it afterwards from Privacy & Data." |
| `lock.hardBinding.message` (`:81–86`) | `lock.hardBinding.message.v2` | same text with "sealed journal, cycle history and intimacy entries" |
| Settings reset dialog literal (`SettingsSheet.swift:2343–2350`) | app catalog key of the same text as `lock.reset.confirm.message.v2` | |
| Exclusion warning (`PrivacyDataSettingsView.swift:1873–1882`) | same site | "…your journals, intimate logs and cycle history won't be in any iPhone backup…" |
| Privacy & Data backup copy | same site | "cycle history", no longer "cycle notes" |

`Docs/PrivacyWipeCoverage.md` and the no-passcode erase consequence (§12) name the expanded loss mode.
`LocalizationBoundaryTests` canaries add the new keys and assert the retired keys are gone from both
catalogs. The Privacy Policy (`PrivacyPolicyView.swift:101`) drops "require Fernlet's app lock" and says
the period, journal and intimacy backups work with or without a passcode (light touch, public-copy voice).

### 10.6 Privacy & Data period-backup states

- `.heldByAnotherDevice`: "Your cycle backup was saved from another iPhone. Backing up this iPhone would
  replace it." Buttons "Restore it here" and "Replace it with this iPhone's history". The replace
  confirmation: "Replace the cycle backup? Entries that exist only on your other iPhone won't be in the
  backup anymore. Your other iPhone keeps its own entries."
- `restoreAwaitsOwner`: "Your app lock was reset. Restore your Sealed backup?" with "Restore".
- Dead rows in the pre-pass: "Some cycle entries can't be opened, so the backup is paused." with a link
  to Private.

### 10.7 Frozen tokens (`LocalizationBoundaryTests` canaries)

Raw values of `PeriodFlowLevel`, `CervicalMucusQuality`, `OvulationTestResult`, `PeriodTemperatureUnit`,
`CycleRecordOrigin`; every `CycleRecord`, `CycleClinicalFields`, `CycleNarrativeFields` `CodingKeys`
string and the v2 envelope keys (`v`, `writer`, `total`, `records`); the HealthKit metadata key
`FernletCycleRecordID`; `LockKeychainKey.deviceContentKey` and the `FDS1`/`FDR1` markers; the new
defaults keys (`fernlet.cycleRecord.periodRestoreResolved`, `fernlet.cycleRecord.legacyImport.narratives`,
`fernlet.cycleRecord.legacyImport.samples`, `fernlet.sealedBackup.restoreAwaitsOwner`,
`fernlet.sealedBackup.periodAcceptedHead`) and their values. Display always goes through the existing
`displayName` forks (`CycleTrackerView.swift:~20–110`).

## 11. Invariants (each testable; the test home in brackets)

| # | Invariant | Test home |
| --- | --- | --- |
| I1 | No cycle value reaches HealthKit unless `isWriteSharingEnabled(.cycleTracking)` is true at write time; every mirror write passes `requireWriteSharing` and the share-grant check. | `HealthKitWriteGateTests`, `PeriodTrackerTests` |
| I2 | With sharing off and no passcode, a log with every field set is sealed or buffered and never throws a sharing error. | `PeriodTrackerTests`, `PeriodLogSharingOffTests`, UI test |
| I3 | Seal before mirror: a seal/buffer failure performs no HealthKit call. | `PeriodTrackerTests` |
| I4 | `CycleRecord` entity attributes are exactly {id, schemaVersion, payloadCiphertext}; no uniqueness constraint. | `CycleRecordRepositoryTests` |
| I5 | K leaves `FernletLockService` only via `contentKey(for: .privateHub)` while `isUnlocked(for: .privateHub)`; the tap state is `.privateHub` only; every `lock(reason:)` and backgrounding closes it. | `FernletLockServiceTests`, `FernletLockScopeTests` |
| I6 | **At every step of adoption, removal and the sweep, at least one copy of K is REACHABLE from the state the §4.6 derivation produces at the next launch**: fault-inject every keychain write AND delete (through the new seam) at each step, and simulate a process death after each, then assert the derived state opens K by its own path (tap or passcode). A mutation test that swaps salt-last for salt-first, or blob-first for verifier-first, goes red. (R1-F1) | `FernletLockServiceTests` |
| I7 | The device row is `WhenUnlockedThisDeviceOnly`, never synchronizable, under `com.fernlet.lock`; `FDR1` is never written when the (injected) enclave is available; an `FDR1` found there is upgraded only after the `FDS1` value is verified. | `KeyCustodyBoundaryTests`, `FernletLockServiceTests` |
| I8 | Never mint over an unreadable device row, an unreadable or present K-bearing lock row, unreadable recovery material, or while awaiting custodian recovery; never mint without `allowingMint`. | `FernletLockServiceTests`, `DuressLockTests` |
| I9 | Adding then removing a passcode keeps K: a record sealed before opens after each step. | `FernletLockServiceTests` + `CycleRecordRepositoryTests` |
| I10 | Hidden ⇒ inert at the decrypt seam: reads empty, writes/upserts/import/drain/backup pre-pass/chunk/restore refuse, no HealthKit cycle read; deletes and counts work hidden and closed. | `PeriodTrackerTests`, `SensitiveSurfaceGateTests` |
| I11 | No decrypted cycle state survives a closed hub in either mode (`settlePeriodEntriesAfterLoad` no longer exempts `.notConfigured`). | `PeriodTrackerTests`, ContentView-level test |
| I12 | Health-sourced samples are never sealed, backed up or exported; a Fernlet sample group is hidden only when its matched record's clinical block is known. | `PeriodTrackerTests`, `SealedBackupPayloadCoverageTests` |
| I13 | Each import half is idempotent (2 runs ≡ 1), atomic with narrative retirement, gated, never imports a marked mirror, completes (never overwrites) existing records, and is marked done only as §8.2/§8.3 define. | `CycleLegacyImportTests` |
| I14 | Every delete path is keyless and works hidden and closed; delete-all removes CycleRecord rows, legacy narratives and the buffer, keeps the device row, cancels the import, and sets both import halves done. | `DeleteAllDataTests`, `PrivacyWipeCoverageTests` |
| I15 | The period ambient restore runs iff `!periodRestoreResolved && !restoreAwaitsOwner`; the marker is set only on a non-retryable outcome or "nothing to restore from"; the §4.9 coordinator and `onResetCompleted` clear it; delete-all keeps it. | `SealedBackupRestoreTests` |
| I16 | Export never runs before E1–E4 hold; the pre-pass refuses before the first chunk write on any dead or transient row; chunks are built from the pre-pass id snapshot; v1 and v2 chunks both restore; restore is a merge that never deletes or regresses an openable local record. | `SealedBackupChunkTests`, `SealedBackupRestoreTests` |
| I17 | Frozen tokens unchanged (§10.7). | `LocalizationBoundaryTests` |
| I18 | Walls: `AIProviders`/`CloudKitSync` import no sealed module; the app never constructs `CycleRecordRepository(`. | `Scripts/spm-wall-check.sh`, `S3BoundaryTests`, `SensitiveSurfaceGateTests` |
| I19 | Exports, widgets and AI payloads contain no cycle data. | existing exclusion tests |
| I20 | The tap gate has exactly one interactive element, no credential field, no "locked/protected/secured" wording. | `LockGateAccessibilityBoundaryTests`, UI test |
| I21 | The pending buffer never evicts (append at cap throws `.full`), never mints its key over an unreadable read or over a non-empty file. | `PendingNarrativeBufferTests`, `KeyCustodyBoundaryTests` |
| I22 | The V1 model's `versionChecksum` is pinned; a V1 on-disk store opens under V2 with rows intact. | `PrivateStoreModelMigrationTests` |
| I23 | `removeCredential` under a duress PIN runs the armed response and throws `.invalidPasscode`, leaving every lock row as the response left it. | `DuressLockTests` |
| I24 | Adoption over existing sealed rows requires a successful owner check (injected verifier); cancel writes nothing; `passcodeNotSet` proceeds with the audit line. | `FernletLockServiceTests` |
| I25 | The silent wipe destroys the device row, the buffer key and the buffer file in the same synchronous pass as the lock rows. | `DuressDecoyAndWipeTests` |
| I26 | `CycleRecord.merged` is content-commutative and idempotent; a block is taken whole; a cleared flag never returns from an older block; batches are reduced by id before writing. | `CycleRecordMergeTests` |
| I27 | A decrypted record whose id differs from its row's id is dead: skipped by pagers, counted by the pre-pass. | `CycleRecordRepositoryTests` |
| I28 | The backup key is the hub key: on the Cycle section of either mode, the period export and the intimacy restore receive a non-nil key. | ContentView-level test, `SealedBackupCoordinatorTests` |
| I29 | After a mutation plus a hub session with E1–E4 satisfied, the cloud record count equals the local count; the dirty flag clears only when `mutationCounter` did not move. | `SealedBackupChunkTests` (mock CloudKit) |
| I30 | E2: an export never replaces a head whose `(writer, generation)` this install has not accepted, except through the explicit replace; every set is minted above the head's generation. | `SealedBackupChunkTests` |
| I31 | `symptomLoad` is nil for a day with no narrative block (a flow-only Fernlet day and an unlogged predicted-phase day alike). | `PeriodContextBridgeTests` |
| I32 | `deleteDay` deletes Fernlet's rows before Health; a Health failure yields `.stillInHealth` with the rows gone; `.removedStaleCopy` only when `deleteMirror` returned > 0. | `PeriodTrackerTests` |
| I33 | The §4.9 coordinator never deletes a row without the "Remove" tap, never mints before it on dead rows, and clears only the named bookkeeping. | `PrivateHubOpenCoordinatorTests` |

The FDS1 half of I6–I9 also runs as a **device-run gate** on the owner's phone (an enclave iPhone)
before unit 1 is called done; CI covers it through the injected enclave (R1-F8).

## 12. Consequences, stated plainly

- **Per iPhone.** Each of the owner's two iPhones has its own sealed store. An entry logged on one does
  not appear on the other, except as a read-only "From Apple Health · Fernlet" day while cycle sharing
  and cycle read are on for both (Q3), which "Keep in Fernlet" can adopt deliberately.
- **Two iPhones, one period backup slot (Q9).** The slot belongs to whichever iPhone last exported a
  set the other has not seen. The second iPhone shows "Your cycle backup was saved from another iPhone"
  and backs up only if the user chooses "Replace". Merging both phones' histories into one backup, with
  deletions carried across, is a separate project. The compare-and-swap is not atomic in CloudKit.
- **Journal and intimacy backups** keep today's model: one slot per account (last writer wins between
  two phones) and a snapshot refreshed only on enable, retry, adopt and un-hide. Their restore is still
  empty-store-only, so on the same iPhone erased and restored, device-key journal rows that survived
  block the journal restore of K-sealed ones. Pre-existing; now also reachable for no-passcode users.
  Named here, left to a follow-up.
- **After a reinstall without Sealed backup**, Fernlet's Health copies show as Health-only Fernlet
  days with "Keep in Fernlet". Notes and symptoms were never in Health.
- **The no-passcode posture** is at-rest encryption plus a deliberate tap. It adds nothing against
  someone who has the unlocked phone in hand.
- **With no passcode and sharing off (the default), the cycle history lives only in Fernlet on this
  iPhone** (plus Sealed backup if on). Erasing or losing the iPhone loses it; so does a forgotten
  passcode reset for a passcode user (§10.5).
- **Recovery-lock** (a duress mode) leaves the pending buffer readable by the app, as it leaves the
  journal device-key rows today: nothing in the recovery blob can give those keys back. The buffer now
  holds clinical fields as well as notes. The silent wipe does destroy it.
- **Legacy import across two phones.** Each phone imports every unmarked Fernlet-authored sample it
  can read, including samples its twin wrote before the cutover (iCloud Health sync; HealthKit cannot
  tell the two phones' copies apart). Acceptable on test data.

## 13. Staged implementation plan (5 units; each lands green on its own)

Build and verify each unit in a detached worktree with its own `-derivedDataPath`. Never build in the
primary checkout. Enum cases and stored properties on package types want a **clean** build. Run test
suites one at a time, never the full suite (owner rule); check the exit code and that `Test case`
lines appear. Every unit runs `Scripts/power-of-10-scan.py`, `Scripts/doc-coverage-scan.py`,
`Scripts/spm-wall-check.sh` and `Scripts/sync-string-catalogs.sh --check`, and updates the touched
modules' DocC landing pages, `Docs/FileIndex.md` and `Docs/StoreRepositoryFunctionIndex.md`.

### Unit 1: custody core (FernletLock only; no user-visible change)
- `FernletLock/FernletLockService.swift`: the state case; the device row and its `FDS1`/`FDR1`
  handling and upgrade; `openWithoutPasscode(for:allowingMint:)` with the mint-safety proof; §4.6
  derivation and the sweep; `mintLockRecords` salt-last with rollback; adoption with the
  `DeviceOwnerVerifying` seam and `acknowledgedPriorData`; `removeCredential` in §4.5 order;
  `keychainDelete` seam; `reestablishLocalUnlock` retires the row; `destroyLocalUnlockKeys` with the
  device row, buffer key and file; `onResetCompleted`; `allCases`; `PeriodLockContext` trim.
- `FernletLock/SecureEnclaveContentKeyWrap.swift`: create only on `.absent`; the
  `DeviceContentKeyWrapping` seam.
- `FernletLock/LockWrapFormatCensus.swift`: classify `FDS1`/`FDR1`.
- `PrivateStoreCore/PendingNarrativeBuffer.swift`: distinguishing key read, no mint over unreadable or
  over a non-empty file.
- App: only what the new enum case forces to compile (map it like `.notConfigured`; nothing produces it
  yet).
- Tests: `FernletLockServiceTests` (I5–I9, I24, fault injection over writes, deletes and process death),
  `DuressLockTests` (I23), `DuressDecoyAndWipeTests` (I25), `KeyCustodyBoundaryTests` (I7, I21's key half),
  `SecureEnclaveWrapTests` (create-only-on-absent), `PendingNarrativeBufferTests`.
- Risks: this is the key-custody unit. The mutation tests (salt-first, verifier-before-blob, drop the
  owner check) must go red. The FDS1 device-run gate is part of done.

### Unit 2: tap gate, coordinator and app wiring
- `FernletLockUI/FernletLockGate.swift` (tap overlay, the §10.2 card, occlusion), `FernletLockView.swift`,
  `FernletLockUI/Localizable.xcstrings` (§10.1, §10.2, §10.5 lock keys).
- App: `PrivateHubOpenCoordinator` (new, §4.9); `ContentView.swift` (journal/worry mapping, the settle
  scrub, `hubContentKeyProvider`, `onResetCompleted` wiring §9.21); `FernletStore.swift`
  (`sealedBackupContentKey` from the provider, R2-F1); `JournalSealingCoordinator.swift` (delete
  noLock; `reencryptAll` fold); `WorryBoxService.swift`; `SettingsSheet.swift` (status, Turn off
  passcode, owner-checked setup, reset literal); `SettingsSearchIndex.swift`;
  `PrivacyDataSettingsView.swift` (`isLockConfigured` only; Q5 lands in unit 5);
  `OnboardingLockSetupView.swift`; `Proximity/UI/ProximityRecipeShareSheet.swift`; `LogPeriodSheet.swift`
  (notes now always keep; buffer-unopenable error).
- `PrivateMemoryStore/JournalNarrativeRepository.swift`: `reencryptAll`.
- `PrivateHealthStore/PeriodTrackerStore.swift`: buffer instead of drop; `.savedWithDroppedNarrative` removed.
- `Docs/PrivacyWipeCoverage.md`: device-row row (kept by delete-all, destroyed by reset and both
  duress modes), latch row correction, reset/duress wording.
- Tests: `PrivateHubOpenCoordinatorTests` (I33), `CaptureOcclusionGatingTests`,
  `LockGateAccessibilityBoundaryTests` (I20), `FernletLockScopeTests`, `SensitiveSurfaceGateTests`
  (`:135` rewritten), `JournalNarrativeRepositoryTests`, `PeriodTrackerTests` (no drop),
  `LocalizationBoundaryTests` (retired/new lock keys), ContentView-level I28 test, UI:
  `LockGateObservabilityUITests` and a new `PrivateTapGateUITests` (one button; tap opens; background
  re-closes; the unopenable card).
- Risks: a missed `!= .notConfigured` site; the journal full fold is O(rows) on first open (bounded,
  paged).

### Unit 3: sealed storage layer (inert)
- `PrivateStoreCore/PrivatePersistenceController.swift` (V1 frozen, V2, staged migration, purge list,
  test seam `init(inMemory:storeURL:model:)`), `SealedColumnFormatCensus.swift`,
  `FernletCrypto/CryptographicPurpose.swift` (`cycleRecordV1`, `sealedBackupWriterTagV1`),
  `PrivateHealthStore/CycleRecord.swift` (+ merge), `CycleRecordRepository.swift`, `CycleRecordStore.swift`,
  `PendingNarrativeBuffer.swift` (`cycleRecordJSON`, throw at cap), the app delete hook extension,
  the §4.9 coordinator's CycleRecord count, docs.
- Tests: `PrivateStoreModelMigrationTests` (I22), `CycleRecordRepositoryTests` (I4, I27, round trip,
  wrong key, tolerant decode, bound, total order, keyless delete, upsert classes), `CycleRecordMergeTests`
  (I26), `SealedColumnFormatCensusTests`, `CryptographicDomainSeparationTests` (two new `Domain` lines),
  `MeshRoutedItemSealTests` (pin 78), `CryptographicPurposeBoundaryTests`, `SealedStoreConfigTests`,
  `PendingNarrativeBufferFormatCensusTests` + cap tests (I21), `DeleteAllDataTests`, `LocalizationBoundaryTests`.
- Risks: the staged migration with in-memory references is the one unverified API; do not touch
  `PeriodSymptom` raw values.

### Unit 4: cutover (records become the source of truth; mirror; import; UI)
- `PrivateHealthStore/PeriodTrackerStore.swift` (§6.3–6.4, outcomes, fill-on-read, the import task and
  epoch), `HealthKitGateway/HealthKitService.swift` (seam, marker metadata, `deleteMirror` count, the
  throwing legacy read, retire `savePeriodEvent`/`checkPeriodEventWriteAllowed`),
  `PeriodContextBridge/PeriodContextBridge.swift` (`hasNarrative`), app: `LogPeriodSheet.swift`,
  `CycleDayDetailView.swift` (Health-only actions), `CycleTrackerView.swift`, `ContentView.swift`
  (`periodWritersStopHook`), `FernletStore.swift` (the hook in `stopWritersForWipe`, import halves
  done on delete-all), `FernletNavigation.swift` (`.logPeriod(targetDate:editingRecord:)`),
  `UITestSupport.swift`.
- **Temporary backup freeze:** `reconcilePeriodBackup` and the `.periodData` restore arm throw the
  existing `.emptyLocalStore` / `.deferredTransient` until unit 5 (non-destructive deferrals, so the old
  export can never write an empty chunk over the cloud copy after the import empties the narrative
  table). The import no longer waits for the restore (§8.1), so the freeze no longer blocks it.
- Tests: `PeriodTrackerTests` (I1–I3, I10–I12, I32, edit in place, dedupe, fill-on-read, no Health read
  when off), `CycleLegacyImportTests` (I13, cancellation, epoch), `PeriodContextBridgeTests` (I31),
  `CyclePredictionEngineTests`, `CyclePhaseResolverTests`, `PeriodAwareScoringTests`,
  `PeriodLogSharingOffTests`, `HealthKitWriteGateTests`, `LocalizationBoundaryTests`,
  `PersistedSurfaceWipeBoundaryTests` (import-half rows), `DeleteAllDataTests` (I14);
  UI: `PeriodLogHealthSharingOffUITests` ("Save succeeds and the day shows"), `PeriodPredictionUITests`.
- Risks: the biggest unit; keep functions ≤ 60 lines; the own-sample-read-with-denied-access check is
  device-only; `menstrualFlowCountReferenceIsRestrictedToAllowedFiles` (`PeriodTrackerTests.swift:657`)
  stays green.

### Unit 5: backup v2, Privacy & Data without a passcode, doc sweep
- `SealedBackupCoordinator.swift` (§9.10: merge restore, resolved marker and `restoreAwaitsOwner` in
  every ambient path, E1–E4, the pre-pass and id snapshot, the writer tag, compare-and-swap,
  `.heldByAnotherDevice`, the explicit replace; lift the unit-4 freeze), `SealedBackupService.swift`
  (`generationFloor:`, head fetch), `SealedBackupGenerationStore.swift` (`periodAcceptedHead`, cleared by
  `reset()`), `FernletStore.swift` (`markPeriodBackupDirtyIfEnabled`), `PrivacyDataSettingsView.swift`
  (Q5, §10.5 copy, §10.6 states, "Restore Sealed backup"), `PrivacyPolicyView.swift` (§10.5),
  `Docs/FernletSpecificationV3.md` (§2 lines 71–74, 172, 210, 290), `Docs/Verifiability.md` §6.2,
  `Docs/PrivacyWipeCoverage.md` (marker, accepted-head and awaits-owner rows). Coordinate the spec edits
  with the other session's uncommitted edits (merge, never clobber).
- Tests: `SealedBackupChunkTests` (I16, I29, I30), `SealedBackupRestoreTests` (I15, v1/v2, merge,
  new-iPhone scenario end to end: dead rows → card → restore), `SealedBackupRestoreOutcomeTests`,
  `SealedBackupPayloadCoverageTests`, `SealedBackupFormatPinTests` (record format unchanged),
  `PersistedSurfaceWipeBoundaryTests`, UI test for Privacy & Data with no passcode via the mocked fresh
  verification.
- Risks: restore-before-reupload ordering (memory: sealed-period-restore-on-unhide). Grep every
  re-upload site (`SealedBackupCoordinator.swift:343–362`, `:482–521`, `:833–916`) and put each behind
  E1–E4.

## 14. Owner questions (implementation proceeds on the recommended default)

1. **Q1: stale Health copies when sharing is off.** Remove Fernlet's own old copy from Health when such
   a day is edited or deleted? Default: **yes**, and the sheet says so only when a copy was actually
   removed.
2. **Q2: backfill when sharing is turned on.** Copy earlier Fernlet-only entries to Health? Default:
   **no, forward-only.**
3. **Q3: other apps' cycle data.** With cycle sharing on, show other apps' (and the other iPhone's
   Fernlet) cycle data read-only and count it toward predictions? Default: **yes**, labelled "From Apple
   Health"; the other iPhone's Fernlet days also offer "Keep in Fernlet".
4. **Q4: the automatic Health prompt** on opening the Cycle page or the log sheet. Default: **remove
   it**; cycle sharing is turned on only in Settings › Health.
5. **Q5: Privacy & Data without a passcode** opens through the fresh Face ID / iPhone passcode check.
   Default: **yes.**
6. **Q6: the honest sentence on the tap screen.** Default: **yes, include it** (text, not a button).
7. **Q7: "Export my data" and cycle history.** Default: **not this round.**
8. **Q8: what "Turn off passcode" removes** (Face ID unlock, duress code, recovery device). Default:
   **yes**, named in the confirmation.
9. **Q9: two iPhones and one cycle backup.** One iPhone's cycle history is backed up at a time; the
   other shows "saved from another iPhone" and replaces it only if you choose. Default: **yes**. The
   alternative, merging both phones into one backup with deletions carried across, is a larger project.
10. **Q10: entries this iPhone can't open.** When an iPhone holds entries it can never open (moved from
    another iPhone, or erased), Private shows them and asks you to remove them before it opens.
    Default: **yes, an explicit "Remove them" button**; nothing is removed automatically.
11. **Q11: Home's period shortcuts.** The "Log period" and "Period tracking" highlights on Home stay
    tied to Apple Health data read during a Private session, which means they stay unlit on Home, as
    today. Default: **keep as is.**
12. **Q12: setting a passcode over existing entries** asks for Face ID or the iPhone passcode first.
    Default: **yes.**
13. **Q13: iPhone backups and the sealed store.** On every Face ID iPhone the encrypted store inside an
    iPhone backup can't be opened on another iPhone or after an erase. Should Fernlet leave it out of
    iPhone backups automatically? Default: **no change this round**; your existing "exclude from device
    backups" switch stays yours, and §4.9 handles its arrival on a new iPhone.
14. **Q14: restoring after an app-lock reset.** After a reset, the Sealed backup restores only from
    Privacy & Data after Face ID or the iPhone passcode, not automatically. Default: **yes.**

## 15. Review resolution

Every finding was checked against `main` at `3c8c9313`. Verdicts: **Confirmed** (the finding is right
and the design changed as it suggests), **Confirmed, different fix** (right about the defect; the
design fixes it another way, with the reason), **Partly rebutted** (part of it is kept as designed,
with evidence).

| Finding | Verdict | What was verified | What changed |
| --- | --- | --- | --- |
| R1-F1 custody transitions can strand K | Confirmed; item 4 partly rebutted | `mintLockRecords` deletes `seWrappedContentKey` first (`:1413`), writes `.salt` first (`:1453`) and `wrappedContentKey` later (`:1458`), no rollback; `configure` no rollback; salt found ⇒ `.locked` (`:1160–1175`); missing verifier ⇒ `.notConfigured` throw (`:1685–1688`); hard-bound with no blob is terminal (`:3228–3290`); `KeychainItem.delete` is `Void` (`:713–715`); no delete seam (`:1117–1120`). | Salt written LAST in every mint, with rollback (§4.3, §4.4); removal deletes salt via `deleteReportingStatus` + absent re-read as the commit point (§4.5); §4.6 derives an interrupted transition from salt + incomplete custody + device row to `.notConfigured`, and the sweep runs only after K is opened from the device row; `keychainDelete` seam; I6 restated as "reachable from the state derived at the next launch" with write, delete and process-death injection. **Kept:** `reset()` still sweeps the device row. A device row lingering beside a passcode is a way to K that needs no passcode; sparing it from the one erase a user runs after forgetting the passcode would turn reset into a bypass. The fix in this design makes the stranding impossible, so reset is no longer the exit from it; the reset copy now names the cycle-history loss (§10.5). |
| R1-F2 new-iPhone restore frozen by latch and dead rows | Confirmed, different fix | Sealed store in iOS backup by default (`PrivatePersistenceController.swift:112–120`, `StoragePreferences.swift:118`); latch in standard defaults, never cleared (`MenstrualNarrativeRepository.swift:106–148`); gate `count == 0 && !everStored` (`SealedBackupCoordinator.swift:1347–1348`); escrow minted ThisDeviceOnly (`IdentityService.swift:881–905`). | §4.9 coordinator: dead rows are named and removed on the user's tap before any fresh K is minted, and the latches, the period marker and the compare-and-swap record are cleared at that event and at reset. The period restore is gated by `periodRestoreResolved` (§5.3), not the store-wide latch. §9.10 states the iCloud Keychain requirement. Generation-tagging the latch was considered; it needs a K-derived tag in `UserDefaults`, a registry entry, and still leaves dead rows in every keyless count, which the explicit removal clears once. Excluding the sealed store from backups is Q13 (owner's setting). |
| R1-F3 anyone can take custody of K by setting a passcode | Confirmed | App lock settings ungated with no lock (`SettingsSheet.swift:335`, `:2320–2328`); `configure` has no owner check (`:1322–1356`). | §4.4 step 3: adoption over existing sealed rows needs a fresh `.deviceOwnerAuthentication` through an injectable seam; `passcodeNotSet` proceeds with an audit line (stated why); I24; Q12. |
| R1-F4 loss copy becomes false | Confirmed | `FernletLockView.swift:261–264`, `:951–955`; `FernletLockGate.swift:54–58`, `:81–86`; `SettingsSheet.swift:2343–2350`. | §10.5: new keys with honest, unconditional wording; old keys retired; canaries; §12 names the expanded loss. |
| R1-F5 buffer survives the silent wipe; key minted over unreadable read | Confirmed | `destroyLocalUnlockKeys` never touches `com.fernlet.narrative-buffer` (`:2763–2851`); reset doc says so (`:1968–1970`); `bufferKey()` collapsing load then mint (`PendingNarrativeBuffer.swift:278–365`). | §4.3: the silent wipe destroys the buffer key and file; §6.5: distinguishing read, mint only on absent and only over an absent or empty file, `.bufferUnopenable` routed to the §4.9 card; I21, I25, `bufferKeyIsNeverMintedOverAnUnreadableRow`. Recovery-lock keeps the buffer (stated in §12). |
| R1-F6 awaiting-recovery misread; mint on collapsing reads | Confirmed | `hasRecoveryCustodian` three collapsing reads (`:2187–2191`); awaiting = custodian && verifier nil (`:2278–2280`); `mintLockRecords` already refuses unreadable recovery rows (`:1476–1486`). | §4.5: recovery rows (blob first) are deleted before the verifier; §4.3 mint-safety proof (distinguishing reads of every K-bearing row, attributes-only biometric probe, `refuseIfRecoveryMaterialUnreadable`); `reestablishLocalUnlock` retires any device row; I8. |
| R1-F7 purpose registered in the wrong suite | Confirmed | `allDomains` (`CryptographicDomainSeparationTests.swift:56`), inventory scan (`:177`), prefix test (`:578`), pin 76 (`MeshRoutedItemSealTests.swift:517`), AAD `purpose ‖ binding` (`ColumnCrypto.swift:241–246`). | §5.2 lists every registration site; two new purposes (cycle record, backup writer tag) take the pin to 78; the prefix check was run against the current spellings. |
| R1-F8 enclave-wrap failure could fall back to FDR1; second enclave key | Confirmed | `wrapVerified` nil on any failure (`SecureEnclaveContentKeyWrap.swift:68–82`); `loadOrCreateKey` on collapsing `loadKey` (`:226–247`); `loadKeyResult` one match (`:202–220`); tests branch on `isAvailable`. | §4.2: FDR1 never written on enclave hardware (nil wrap throws retryable); FDR1 found there is upgraded via `updateReportingStatus` after verification; create only on `.absent`; `DeviceContentKeyWrapping` seam for CI; device-run gate for the FDS1 half of I6–I9. |
| R1-F9 seal does not bind the row id | Confirmed, different fix | AAD is `purpose ‖ binding` (`ColumnCrypto.swift:241–246`). | §5.2: post-decrypt `decoded.id == row.id`, mismatch classified dead (skipped, audited, counted by the pre-pass); I27. Binding the id into the AAD would need a second ColumnCrypto format for one entity. |
| R1-F10 duress behaviour of removeCredential ambiguous | Confirmed | `changeCredential` returns normally after the response (`:1524–1527`); `unlock` on `.appLockSettings` throws `.invalidPasscode` (`:1702–1709`, `:2600–2604`). | §4.5 step 2 picks throw `.invalidPasscode`, with the reason (removal is observable, so a silent success would be a tell); I23. |
| R2-F1 backup key is the journal section key | Confirmed (also a live bug for intimacy today) | `sealedBackupContentKey` = journal coordinator key (`FernletStore.swift:7118`); deactivated at `ContentView.swift:1330`, nil at `JournalSealingCoordinator.swift:159`, early return on Cycle (`ContentView.swift:1335`); the Cycle settle (`:1451–1466`) hits `.locked` at `SealedBackupCoordinator.swift:570`, `:1250`, `:1288`. | §9.10 Key: an injected `hubContentKeyProvider` returning `contentKey(for: .privateHub)`; lands in unit 2 so it fixes intimacy on its own; I28 ContentView-level test. |
| R2-F2 new iPhone from a device backup blocks the restore | Confirmed, different fix | As R1-F2, plus the pagers' silent skip and the latch surviving delete-all. | Same resolution as R1-F2 (§4.9, §5.3); the dead-row removal is explicit (owner rule: deletion is a separate explicit action); the §9.10 consequences are rewritten (items 1–3). |
| R2-F3 period backup is a stale snapshot | Confirmed | Callers of `setSealedBackupEnabled(true, .periodData)` only (`SealedBackupCoordinator.swift:385–519`, `:849–866`; `FernletStore.swift:1193`); "stale by construction" (`:960–962`). | `CycleRecordStore` mutation hook → persisted `sealedBackupPeriodReuploadDeferred` (never the enabled pref) → export at the next hub settle; the flag clears only when no mutation moved the counter since the pre-pass; I29. |
| R2-F4 two phones share one backup slot | Confirmed, different fix | Record names account-global (`CloudKitDataService.swift:844–853`); device-local counters (`SealedBackupGenerationStore.swift:65–69`); stale generation is terminal `.rolledBack` (`SealedBackupService.swift:408–417`). | Neither per-device slots (needs a CloudKit schema field and a slot index) nor merge-on-export (needs tombstones to stop resurrection, a new keyless persisted surface). Chosen: a writer tag in the sealed head, a compare-and-swap on `(writer, generation)` against the last set this install accepted, the named `.heldByAnotherDevice` state with explicit "Restore it here" / "Replace", and every set minted above the head's generation (fixes the false `.rolledBack`). I30, Q9, §12. |
| R2-F5 the import closes the restore | Confirmed; the tombstone half not adopted | In-memory outcome (`FernletStore.swift:3527`, `:7126`); launch skip while hidden (`:743`); view task vs 300 ms settle (`CycleTrackerView.swift:217–222`, `ContentView.swift:1435`). | The period restore is an id-keyed merge (§9.10) and its ambient runs are gated by the persisted `periodRestoreResolved` marker, so the import and the restore commute and `legacyImportMayRun` is deleted. **Not adopted:** per-id tombstones for resurrection protection. They would be a new keyless persisted surface; the resolved marker gives the same protection (the restore stops ambiently once resolved, and deletions reach the cloud through R2-F3's re-export). |
| R2-F6 fill-only merge and id dedupe lose clinical data | Confirmed; the uniqueness constraint rebutted | Non-optional booleans in revision 1's record; duplicate `hkExternalUUID` rows (`PeriodTrackerStore.swift:502–507`). | §5.1: clinical and narrative blocks with "unknown" (nil) distinct from "empty"; §5.1a block-level merge (newest block whole, unknown filled), batch reduction by id; §6.3 dedupe hides only groups whose record's clinical block is known; fill-on-read completes the rest; I12, I26. **Rebutted:** a Core Data uniqueness constraint. The shared view context uses property-object-trump (`PrivatePersistenceController.swift:125`), which turns a constraint conflict into a silent overwrite of the stored row. Uniqueness is the repository's `upsertMerged` plus reader-side reduction instead. |
| R2-F7 import and marker survive delete-all | Confirmed | `stopWritersForWipe` cancels only the settle tasks (`FernletStore.swift:5698–5711`). | §8.4: held import task, `periodWritersStopHook`, writer epoch, fixed order (HealthKit await, then recheck, then synchronous decrypt and write); delete-all and reset set both halves done. The device row is now kept by delete-all (§9.11), which makes the cancellation load-bearing, and it is. |
| R2-F8 the import can finish without its data | Confirmed | Unrequested type → `[]` (`HealthKitService.swift:2811–2840`, `:2822`); Q4 removes the only in-context request (`CycleTrackerView.swift:577–584`); pagers skip undecryptable rows (`MenstrualNarrativeRepository.swift:362–378`). | §8.2/§8.3: two halves tracked separately; the sample half waits for determined authorization and uses a read that throws; the narrative half is done only when every row is retired or named dead; §7.3 "Keep in Fernlet" / "Delete from Apple Health" for Fernlet-authored Health-only days; I13. |
| R2-F9 symptomLoad regression | Confirmed, refined fix | `PeriodContextBridge.swift:425` reads `entry.narrative.map`. | §6.4 keys on `entry.hasNarrative`, not on `records.isEmpty`: the suggested formula would still turn every Fernlet flow-only day (no narrative today, `PeriodTrackerStore.swift:582`) into a 0.0 observation. I31. |
| R2-F10 reset and exclusion copy become false | Confirmed | `FernletLockGate.swift:54–58`; `PrivacyDataSettingsView.swift:1873–1882`. | Merged with R1-F4 (§10.5). The wording is unconditional because FernletLockUI cannot see the Health switches, and the sentence is true either way. |
| R2-F11 delete order and false Health copy outcomes | Confirmed; the order partly rebutted | Today Health first (`PeriodTrackerStore.swift:663–678`); "That day is still here" (`CycleTrackerView.swift:331–343`). | `PeriodDeleteOutcome` with the Health copy's state and a sentence for each (§6.3, §10.4); `.removedStaleCopy` from `deleteMirror`'s count; `healthMirrorExternalUUID` removed (dedupe and delete on the record id). **Kept:** Fernlet first. Health-first makes a day undeletable in Fernlet forever once Health share access is revoked; the Health half is retryable from the Health-only day (§7.3). I32. |
| R2-F12 export refusal must be a pre-pass | Confirmed | Journal rule probes page 1 and exports partial sets (`SealedBackupCoordinator.swift:599–640`); suffix chunks first (`SealedBackupService.swift:301–331`). | §9.10 E3: full decrypt pre-pass before the first write, then chunks built from the pre-pass's id snapshot; I16. |
| R2-F13 Home shortcuts ignore Fernlet records | Confirmed, option (a) | `HomeView.swift:1428–1431`, `:1512–1537`; `allowedHealthCapabilities` drops cycle unless the hub is unlocked (`FernletStore.swift:2495–2509`). | §9.6 states they stay Health-only and hub-gated, why, and that they are dark on Home for everyone today; Q11. |

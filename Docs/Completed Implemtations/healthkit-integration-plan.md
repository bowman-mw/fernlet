# Fernlet — HealthKit Integration & Data Storage Implementation Plan

**Purpose:** Reference document for AI coding assistants and human contributors. Specifies the target architecture for HealthKit integration, period data storage, and HIPAA-model privacy controls. Implementations should adapt to the current codebase (esp. `PeriodContextBridge`) while honoring the contracts defined here.

**Compliance posture:** Fernlet is a consumer iOS app and is NOT a HIPAA covered entity. We voluntarily adopt HIPAA Security Rule and Privacy Rule *principles* as a privacy stance. Where this document says "HIPAA-equivalent," we mean *modeled on* the rule, not legally compliant with it.

---

## Table of Contents

1. Architecture Overview
2. Storage Layer Specifications
3. Data Type Catalog
4. HealthKit Service Specification
5. PeriodContextBridge Specification
6. Sensitive Memory Tier Specification
7. Security Architecture
8. Audit Log Specification
9. Privacy Manifest Configuration
10. Implementation Phases
11. Testing Strategy
12. Open Decisions

---

## 1. Architecture Overview

### 1.1 Layered design

```
┌─────────────────────────────────────────────────────────────┐
│ UI Layer (SwiftUI Views, Pet animation, Journal UI)         │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ Domain Layer                                                │
│   • PetStateEngine                                          │
│   • CycleInferenceEngine                                    │
│   • JournalService                                          │
│   • OnDeviceMLService (FoundationModels, Core ML)           │
└─────┬─────────────────┬─────────────────┬───────────────────┘
      │                 │                 │
┌─────▼─────┐   ┌───────▼────────┐   ┌────▼─────────────────┐
│ Period    │   │ HealthKit      │   │ SecureStore          │
│ Context   │   │ Service        │   │ (app-private)        │
│ Bridge    │◄──┤                │   │                      │
└─────┬─────┘   └───────┬────────┘   └────┬─────────────────┘
      │                 │                 │
      │         ┌───────▼────────┐   ┌────▼─────────────────┐
      │         │ Apple          │   │ CryptoKit + Keychain │
      │         │ HealthKit      │   │ + Secure Enclave     │
      │         │ (HKHealthStore)│   │ + CoreData (SQLite)  │
      │         └────────────────┘   └──────────────────────┘
      │
┌─────▼───────────────────────────────────────────────────────┐
│ AuditLog (cross-cutting, append-only)                       │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Storage decision principle

For every piece of data, ask in order:
1. Is it a **standard health observation** that other apps or Apple Health legitimately consume? → **HealthKit**
2. Is it **app-specific interpretation, narrative, or pet state**? → **SecureStore (app-private)**
3. Is it **highly sensitive memory or content** the user explicitly marked private? → **Sensitive tier (Secure Enclave–wrapped)**
4. Is it **device/preference state**? → **UserDefaults (non-sensitive only)**

Never write inferences back to HealthKit. HealthKit is for observations and user-logged events only.

### 1.3 Module boundaries

| Module | Responsibility | Knows about |
|---|---|---|
| `HealthKitService` | All `HKHealthStore` interactions, authorization, anchored queries, background delivery | HealthKit types only |
| `SecureStore` | CryptoKit-encrypted SQLite for journal, symptoms, pet state | Encryption keys, schema versions |
| `SensitiveMemoryStore` | Highest-tier encrypted store with Secure Enclave key wrapping | Biometric context |
| `PeriodContextBridge` | Joins HK menstrual data + SecureStore context, computes phase, resolves source conflicts | Both stores via protocols |
| `AuditLog` | Append-only event log | All other modules (cross-cutting) |
| `CycleInferenceEngine` | ML predictions from features | Bridge (read only); writes to SecureStore |

Each module exposes a protocol (e.g., `HealthKitServicing`) for testability and mocking.

---

## 2. Storage Layer Specifications

### 2.1 HealthKit (canonical clinical data)

**Use for:** Standard health observations, menstrual events, mindful sessions logged in-app, state of mind check-ins.

**Properties:**
- Excluded from regular iCloud Backup; syncs via Apple's E2EE HealthKit channel if user has iCloud Health enabled.
- Survives app uninstall. User retains data even after revoking Fernlet access.
- Apple terms forbid using HealthKit data for advertising; requires usage description strings.
- Portable: user can export from Health app, share with other apps under their control.

**Read/write conventions in code:**
- Read via `HKAnchoredObjectQuery` for incremental sync. Persist anchor in keychain (NOT UserDefaults; anchors can leak sample counts).
- Write via `HKHealthStore.save(_:)` with metadata indicating source (`HKMetadataKeyExternalUUID = Fernlet's local entity UUID`).
- Always set `HKDevice.local()` as the source device.

### 2.2 SecureStore (app-private encrypted SQLite)

**Use for:** Journal entries, custom symptom scales, mood narrative, pet state, ML inference outputs, cached HealthKit values for offline UI.

**Implementation:**
- SQLite via Core Data with `NSPersistentStoreFileProtectionKey = .completeFileProtection`.
- Additional column-level encryption for sensitive text fields using CryptoKit `ChaChaPoly`.
- Encryption key: derived per-install, stored in keychain with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
- Excluded from iCloud Backup via `URLResourceKey.isExcludedFromBackupKey = true`.
- Optional CloudKit private DB sync for non-sensitive subsets (pet state, preferences) — explicitly opt-in.

**Schema versioning:**
- Use Core Data lightweight migration for additive changes.
- For breaking schema changes, ship a versioned migration that re-encrypts under a new key derivation if required.

### 2.3 SensitiveMemoryStore (Secure Enclave-wrapped)

**Use for:** Memories the user explicitly tags as sensitive, free-text reflections, anything in the "sensitive memory tier" already established in the Fernlet spec.

**Implementation:**
- Separate SQLite file at `~/Library/Application Support/Fernlet/sensitive.sqlite`.
- File protection: `.completeFileProtection`.
- Data encrypted with a content key (CryptoKit `ChaChaPoly` symmetric key).
- Content key wrapped by a Secure Enclave P-256 private key using ECIES (CryptoKit `SecureEnclave.P256.KeyAgreement`).
- Access gated by `LAContext` biometric evaluation with `.biometryCurrentSet` policy. New biometric enrollment invalidates and forces re-auth.
- Excluded from backups. Excluded from any analytics. No CloudKit sync, ever.

**Loss model:** Device loss = data loss. This is the correct tradeoff for this tier. Surface this clearly to the user during onboarding and offer an opt-in encrypted export.

### 2.4 UserDefaults

**Use for:** Non-sensitive preferences only.
- App appearance, notification preferences, pet name, last-opened tab.
- **Never** any health data, dates of cycle events, mood values, or anything inferable from those.

### 2.5 Keychain (key material only)

**Use for:**
- SecureStore master encryption key
- HealthKit anchor tokens (per data type)
- HMAC keys for journal integrity verification
- Secure Enclave key references

**Access attributes:**
- App-private keys: `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`
- Keys that must survive device migration (rare): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- **Never** use `kSecAttrAccessible…` variants without `ThisDeviceOnly` — that allows iCloud Keychain sync, which leaks keys across devices.

---

## 3. Data Type Catalog

For each data type: identifier, direction, storage, query strategy, and rationale.

### 3.1 Read-only from HealthKit (passive signals for pet state)

#### Heart Rate Variability (SDNN)
- **Type:** `HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)`
- **Unit:** `HKUnit.secondUnit(with: .milli)` (milliseconds)
- **Direction:** Read only
- **Storage:** HealthKit canonical; latest value cached in SecureStore (`HKValueCache` table) for offline pet animation.
- **Query:** `HKAnchoredObjectQuery` with `predicateForSamples(withStart: 7daysAgo, end: nil)`. Background delivery `.hourly`.
- **Use:** Recovery signal; lower HRV → pet appears tired/empathetic.
- **Note:** Apple Watch–derived only; iPhone won't produce these.

#### Resting Heart Rate
- **Type:** `HKQuantityType.quantityType(forIdentifier: .restingHeartRate)`
- **Unit:** `HKUnit.count().unitDivided(by: .minute())`
- **Direction:** Read only
- **Storage:** HealthKit canonical; latest value cached.
- **Query:** Anchored, background `.hourly`.
- **Use:** Baseline shift detection (cycle phase signal; elevated RHR in luteal phase is well-documented).

#### Sleep Analysis
- **Type:** `HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)`
- **Direction:** Read only
- **Storage:** HealthKit canonical; nightly summary computed and cached in SecureStore `SleepSummary` table.
- **Query:** Anchored. Compute "sleep night" as samples between 6 PM and 11 AM next day. Sum durations by `HKCategoryValueSleepAnalysis` value (asleep core, deep, REM, awake, in-bed).
- **Use:** Sleep debt feeds pet energy state.
- **Note:** Multiple sources possible (Watch, iPhone, third-party). Deduplicate by overlapping time ranges, prefer source with highest `HKMetadataKeyDeviceManufacturerName` priority (configurable user preference).

#### Step Count
- **Type:** `HKQuantityType.quantityType(forIdentifier: .stepCount)`
- **Unit:** `.count()`
- **Direction:** Read only
- **Storage:** HealthKit canonical; daily totals cached.
- **Query:** `HKStatisticsCollectionQuery` with daily interval, anchored to local midnight.
- **Use:** Activity signal; pet appearance reacts to active vs sedentary days.

#### Active Energy Burned
- **Type:** `HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)`
- **Unit:** `.kilocalorie()`
- **Direction:** Read only
- **Storage:** HealthKit canonical; daily totals cached.
- **Query:** Daily statistics collection.
- **Use:** Activity signal alongside steps.

#### Apple Exercise Time
- **Type:** `HKQuantityType.quantityType(forIdentifier: .appleExerciseTime)`
- **Unit:** `.minute()`
- **Direction:** Read only
- **Storage:** Cached daily.
- **Use:** Optional pet praise behavior for exercise minutes.

### 3.2 Bidirectional with HealthKit (user logs in Fernlet, syncs to Health)

#### Menstrual Flow
- **Type:** `HKCategoryType.categoryType(forIdentifier: .menstrualFlow)`
- **Values:** `HKCategoryValueVaginalBleeding` (`.unspecified`, `.light`, `.medium`, `.heavy`, `.none`)
- **Direction:** Read AND write
- **Storage:** HealthKit canonical. Local mirror in `SecureStore.MenstrualLog` with `hkExternalUUID` foreign key for joining narrative context.
- **Metadata to write:**
  - `HKMetadataKeyMenstrualCycleStart`: `true` for first day of period
  - `HKMetadataKeyExternalUUID`: Fernlet's local entity UUID for join with SecureStore context
- **Metadata to read on incoming samples:**
  - `HKMenstrualFlowPredicted` (Bool) — DO NOT overwrite predicted samples with our predictions; only with user-logged data.
- **Source conflict resolution:** If multiple sources logged the same date, prefer most recent `endDate` from any source. Surface conflicts in UI as "Fernlet sees a Cycle Tracking entry for this day — keep it, replace it, or merge?"
- **Query:** Anchored. Background delivery `.immediate` (period start is time-sensitive for pet behavior).

#### Basal Body Temperature
- **Type:** `HKQuantityType.quantityType(forIdentifier: .basalBodyTemperature)`
- **Unit:** `.degreeCelsius()` (convert for display per locale)
- **Direction:** Read AND write
- **Storage:** HealthKit canonical; local mirror.
- **Use:** Optional ovulation detection if user logs BBT.

#### Cervical Mucus Quality
- **Type:** `HKCategoryType.categoryType(forIdentifier: .cervicalMucusQuality)`
- **Direction:** Read AND write
- **Storage:** HealthKit canonical; local mirror.

#### Intermenstrual Bleeding
- **Type:** `HKCategoryType.categoryType(forIdentifier: .intermenstrualBleeding)`
- **Direction:** Read AND write
- **Storage:** HealthKit canonical.

#### Ovulation Test Result
- **Type:** `HKCategoryType.categoryType(forIdentifier: .ovulationTestResult)`
- **Direction:** Read AND write
- **Storage:** HealthKit canonical.

#### Sexual Activity
- **Type:** `HKCategoryType.categoryType(forIdentifier: .sexualActivity)`
- **Direction:** Read AND write (only if user enables this; OFF by default)
- **Storage:** HealthKit canonical, no local mirror (extra sensitivity).
- **Permission strategy:** Separate authorization request triggered only when user enables the feature in settings.

### 3.3 Write-only or write-primary to HealthKit (Fernlet logs to Health)

#### Mindful Session
- **Type:** `HKCategoryType.categoryType(forIdentifier: .mindfulSession)`
- **Direction:** Write primary
- **Storage:** Write to HealthKit on session completion. Local copy in SecureStore for in-app history.
- **Use:** Any breathing exercises, pet-led calming sessions, journal-prompted mindfulness.

#### State of Mind (iOS 18+)
- **Type:** `HKStateOfMindType` (iOS 18+)
- **Direction:** Read AND write
- **Storage:** HealthKit canonical for the structured `valence` and `labels`. SecureStore holds the "why" — free-text reflection, pet context, sensitive memories tied to the entry.
- **Versioning:** Wrap in `if #available(iOS 18.0, *)` guards; pre-iOS 18 fallback uses SecureStore-only mood entries.

### 3.4 App-private only (never written to HealthKit)

| Data | Storage | Encryption tier |
|---|---|---|
| Free-text journal entries | SecureStore | Column-encrypted (ChaChaPoly) |
| Sensitive memories | SensitiveMemoryStore | Secure Enclave-wrapped key |
| Custom symptom scales (e.g., cramp 1–10, location, type) | SecureStore | Standard |
| Pet state (mood, hunger, relationship level) | SecureStore | Standard |
| Pet relationship memory & dialogue history | SecureStore | Standard, with sensitive items in SensitiveMemoryStore |
| Cycle phase predictions (model output) | SecureStore | Standard |
| Inference confidence & feature importance | SecureStore | Standard |
| HealthKit value cache (offline UI) | SecureStore | Standard |
| Audit log | SecureStore (append-only table) | Standard, HMAC-signed rows |
| Onboarding answers (preferences, goals) | SecureStore | Standard |

---

## 4. HealthKit Service Specification

### 4.1 Protocol

```swift
protocol HealthKitServicing {
    func isHealthDataAvailable() -> Bool
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot

    func startObserving<S: HKSampleType>(_ type: S, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws
    func enableBackgroundDelivery(for type: HKObjectType, frequency: HKUpdateFrequency) async throws

    func save<S: HKObject>(_ samples: [S]) async throws
    func delete(_ samples: [HKSample]) async throws

    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics]
}
```

### 4.2 Authorization grouping

Permissions are requested per-capability, not all at once. Each capability bundles the minimum set of types it needs.

```swift
enum HealthCapability {
    case cycleTracking         // .menstrualFlow, .basalBodyTemperature, .cervicalMucusQuality,
                               // .intermenstrualBleeding, .ovulationTestResult
    case bodyContext           // .heartRateVariabilitySDNN, .restingHeartRate, .sleepAnalysis
    case activityContext       // .stepCount, .activeEnergyBurned, .appleExerciseTime
    case mindfulness           // .mindfulSession (write), .stateOfMind (read/write iOS 18+)
    case intimateLogging       // .sexualActivity (off by default)
}
```

### 4.3 Just-in-time request triggers

| Trigger | Capability requested |
|---|---|
| User taps "Log period" for first time | `.cycleTracking` |
| User opens cycle phase view for first time | `.cycleTracking` + `.bodyContext` |
| Pet first reacts to sleep/HRV | `.bodyContext` |
| User views activity badge | `.activityContext` |
| User starts in-app breathing | `.mindfulness` (write) |
| User opens mood reflection | `.mindfulness` (read/write) |
| User toggles "log intimacy" in settings | `.intimateLogging` |

### 4.4 Status handling pattern

```swift
// Apple deliberately conceals read denial. Always handle no-data as normal.
struct AuthorizationOutcome {
    let writeStatuses: [HKObjectType: HKAuthorizationStatus]
    // Note: no readStatuses — Apple does not expose this for privacy reasons.
}

// In feature code:
// 1. Request authorization
// 2. Attempt query
// 3. If empty: prompt user with "We couldn't see any data — if you'd like Fernlet to use this,
//    open Settings > Privacy > Health > Fernlet"
// 4. Never assert "you denied permission" — we can't know that
```

### 4.5 Anchor persistence

```swift
// One anchor per (sampleType, predicateHash) tuple
struct AnchorKey: Hashable {
    let sampleTypeIdentifier: String
    let predicateHash: String  // SHA256 of predicate description
}

// Stored in keychain as Data (HKQueryAnchor archived with NSKeyedArchiver)
// Key path: "com.fernlet.healthkit.anchor.\(identifier).\(predicateHash)"
// Access: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
```

### 4.6 Background delivery setup

Call once at app launch after authorization:

```swift
// HRV, RHR, sleep: hourly is sufficient
try await enableBackgroundDelivery(for: .hrvType, frequency: .hourly)
try await enableBackgroundDelivery(for: .rhrType, frequency: .hourly)
try await enableBackgroundDelivery(for: .sleepType, frequency: .hourly)

// Menstrual flow: immediate (period start drives pet behavior)
try await enableBackgroundDelivery(for: .menstrualFlowType, frequency: .immediate)

// Activity: daily is fine for pet state
try await enableBackgroundDelivery(for: .stepCountType, frequency: .daily)
```

Background delivery requires the `HealthKit` background mode capability in `Info.plist`.

---

## 5. PeriodContextBridge Specification

### 5.1 Purpose

Single source of truth for "what cycle phase is the user in, and what do we know about how she feels in it?" Joins HealthKit menstrual data with SecureStore narrative context. Read-mostly from the domain layer's perspective.

### 5.2 Protocol

```swift
protocol PeriodContextBridging {
    /// Current best-estimate phase given all available signals
    func currentPhase() async -> CyclePhase

    /// Phase on a given date
    func phase(on date: Date) async -> CyclePhase

    /// Joined view: HK structured event + SecureStore narrative for a date
    func entry(for date: Date) async -> CycleDayEntry?

    /// Date range query
    func entries(in range: DateInterval) async -> [CycleDayEntry]

    /// Write a user-logged event: persists to HK + SecureStore atomically
    func logEvent(_ event: UserLoggedCycleEvent) async throws

    /// Source conflict resolution
    func resolveConflict(on date: Date, resolution: ConflictResolution) async throws
}

struct CycleDayEntry {
    let date: Date
    let hkEvents: [HKCategorySample]     // raw HK samples for this day
    let narrative: NarrativeContext?      // from SecureStore: notes, symptoms, mood
    let phase: CyclePhase                 // computed
    let phaseSource: PhaseSource          // .apple, .fernletModel, .userOverride
    let confidence: Double                // 0.0 to 1.0
}

enum CyclePhase {
    case menstrual
    case follicular
    case ovulatory
    case luteal
    case unknown
}

enum PhaseSource {
    case apple              // Apple Health prediction
    case fernletModel       // CycleInferenceEngine output
    case userOverride       // User explicitly set
    case observed           // Logged menstrual flow
}
```

### 5.3 Phase computation precedence

When multiple sources disagree:

1. **Observed events win.** A user-logged `menstrualFlow` sample makes the day `.menstrual`, period.
2. **User override beats predictions.** If the user manually set phase, respect it until next observed event.
3. **Fernlet model beats Apple predictions** if confidence > 0.7, otherwise defer to Apple.
4. **Apple predictions** for unobserved dates with low Fernlet confidence.
5. **`.unknown`** if nothing applies (e.g., first install, no history).

### 5.4 Source conflict resolution

When multiple HealthKit sources log to the same date:

```swift
enum ConflictResolution {
    case keepMine           // Replace others with Fernlet's entry
    case keepTheirs(sourceUUID: UUID)  // Keep specified source
    case keepMostRecent     // Default; whichever has latest endDate wins
    case mergeAdditive      // Keep all, treat as independent observations
}
```

Default for new conflicts: `.keepMostRecent`. Surface in UI when a conflict is detected so user can override.

### 5.5 Caching

- In-memory LRU cache of last 60 days of `CycleDayEntry`, invalidated on:
  - HealthKit change notification (from anchored query handler)
  - SecureStore write to narrative tables
  - User explicit refresh
- Cache key: `dateInterval.start.timeIntervalSince1970 + dateInterval.duration`.
- Never cache to disk — recompute on launch.

### 5.6 Write path: `logEvent`

User logs a period event from the UI:

1. Construct `HKCategorySample` with metadata.
2. Generate `entityUUID = UUID()`.
3. Set `HKMetadataKeyExternalUUID = entityUUID.uuidString`.
4. Begin transaction:
   - `HKHealthStore.save([sample])`
   - SecureStore: insert `NarrativeContext` row with `hkExternalUUID = entityUUID`, plus any notes/symptoms/mood.
5. If HK save fails: abort, do not write SecureStore narrative.
6. If SecureStore write fails after HK save: log audit event, retry SecureStore once; if still fails, surface error but keep HK sample (HK is canonical).
7. Audit log: `cycleEventLogged` event with date and entityUUID (not contents).

### 5.7 Inference outputs — strict rule

`CycleInferenceEngine` writes its predictions to `SecureStore.PhasePrediction` table only. **Never write predictions to HealthKit.** This keeps HealthKit clean as an observation store and prevents our model's drift from polluting other apps' views.

---

## 6. Sensitive Memory Tier Specification

### 6.1 What goes here

- Free-text reflections the user explicitly tags as private
- Memories the pet "remembers" that touch on sensitive topics (relationship, body image, trauma references, health worries)
- Any entry where the user toggles "extra privacy" at write time

### 6.2 Cryptographic design

```
Per-entry:
  contentKey: SymmetricKey (256-bit, generated per entry with SystemRandomNumberGenerator)
  ciphertext: ChaChaPoly.seal(plaintext, using: contentKey).combined

Per-install:
  enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey
    — stored in Secure Enclave, not exportable
    — created on first sensitive write
    — protected by .biometryCurrentSet access control

Per-entry storage:
  wrappedContentKey: data = ECIES-wrap(contentKey, enclaveKey.publicKey)
  ciphertext: data
  createdAt, updatedAt: timestamps
  hmac: signature over (ciphertext || wrappedContentKey || createdAt) using
        a separate keychain-stored HMAC key
```

### 6.3 Access flow

1. User attempts to view sensitive memories.
2. `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, …)`.
3. On success: unwrap content keys via `enclaveKey.sharedSecretFromKeyAgreement(…)`.
4. Decrypt each requested entry; verify HMAC.
5. Surface plaintext to UI within a transient view; never log, never include in crash reports.
6. Re-lock after configurable idle (default 60s) or backgrounding.

### 6.4 Biometric invalidation policy

Use `.biometryCurrentSet`, not `.biometryAny`. If the user adds a new Face ID enrollment or fingerprint, the Secure Enclave key becomes inaccessible — by design. Surface a recovery flow: "We detected new biometric enrollment. For your safety, sensitive memories require re-confirmation. [Confirm with passcode]" → on success, re-wrap content keys under a fresh enclave key.

### 6.5 Export & deletion

- Export: only via biometric-gated flow → produces encrypted archive (user-supplied passphrase, PBKDF2 → AES-GCM).
- Delete: hard delete with overwrite of the SQLite page; vacuum after deletion to actually reclaim pages. Audit log records deletion timestamp but never content.

---

## 7. Security Architecture

### 7.1 Key hierarchy

```
Hardware
└── Secure Enclave
    └── enclaveKey (P-256, .biometryCurrentSet, never exported)
        └── wraps → sensitiveContentKeys (per-entry, in SensitiveMemoryStore)

Keychain (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly)
├── secureStoreMasterKey (SymmetricKey, 256-bit)
│   └── derives → column encryption keys via HKDF
├── auditLogHmacKey (SymmetricKey, 256-bit)
└── healthKitAnchors[type] (Data, archived HKQueryAnchor)
```

All keychain items use `kSecUseDataProtectionKeychain = true` (modern keychain, file-backed, per-app).

### 7.2 App lock behavior

- Lock trigger: app backgrounded for > N seconds (default 60, range 0–600 in settings, 0 = lock immediately).
- Lock trigger: device locked (observe `UIApplication.protectedDataWillBecomeUnavailableNotification`).
- Unlock: `LAContext` biometric → fallback to device passcode.
- Hard sections always require fresh biometric regardless of app lock state: sensitive memories, export, delete-all, settings > privacy.
- On lock, scrub in-memory plaintext caches via `Data.resetBytes(in:)`.

### 7.3 Encryption at rest summary

| Tier | Cipher | Key location | Backup excluded? | iCloud sync? |
|---|---|---|---|---|
| HealthKit | Managed by Apple (E2EE if user has iCloud Health) | iOS keystore | Yes (HK-managed) | Via HealthKit E2EE channel |
| SecureStore (standard) | NSFileProtectionComplete + per-column ChaChaPoly | Keychain | Yes | No |
| SensitiveMemoryStore | NSFileProtectionComplete + ChaChaPoly + Secure Enclave wrap | Secure Enclave | Yes | No |
| UserDefaults | NSFileProtectionCompleteUntilFirstUserAuthentication (default) | N/A | No, but contains no sensitive data | Yes (NOT used for any health data) |

### 7.4 Transmission

- No first-party network calls for health data. Period.
- If telemetry is added: declare in Privacy Manifest; never include health data, dates of cycle events, mood values, or any inferable field.
- If a backend is added (e.g., for cross-device sync): TLS 1.3 only, certificate pinning, no PII in URLs or query params, all bodies encrypted with E2EE keys the server cannot decrypt.

### 7.5 Crash reporting & analytics

- Use Apple's MetricKit only. No Crashlytics, no Sentry, no third-party SDKs that phone home.
- Crash logs scrubbed: install a `NSExceptionHandler` and signal handlers that purge any thread-local data before letting the crash propagate to MetricKit.
- Never log health values to OSLog at any level. Use `.private` redaction on any string that could contain user data.

---

## 8. Audit Log Specification

### 8.1 Schema

```swift
struct AuditLogEntry {
    let id: UUID                   // primary key
    let timestamp: Date            // wall-clock
    let monotonicSequence: UInt64  // strictly increasing, survives clock changes
    let category: AuditCategory
    let event: String              // controlled vocabulary, see below
    let context: [String: String]  // free-form metadata; NEVER includes health values
    let hmac: Data                 // HMAC-SHA256 over canonical encoding of prior fields
}

enum AuditCategory {
    case authorization     // HealthKit perms granted/denied/revoked
    case healthKitRead     // anchored query batch processed (counts only, no values)
    case healthKitWrite    // sample saved (entityUUID, type — no values)
    case journalAccess     // journal entry viewed
    case sensitiveAccess   // sensitive memory unlock
    case export            // user export action
    case delete            // user deletion action
    case keyManagement     // key rotation, biometric invalidation handled
    case appLock           // lock/unlock events
}
```

### 8.2 Event vocabulary (excerpt)

| Event | Category | Context fields |
|---|---|---|
| `auth.requested` | authorization | capability |
| `auth.outcome` | authorization | capability, writeStatuses |
| `hk.read.batch` | healthKitRead | type, sampleCount, deletedCount |
| `hk.write.saved` | healthKitWrite | type, entityUUID |
| `hk.write.deleted` | healthKitWrite | type, entityUUID |
| `journal.opened` | journalAccess | entryId |
| `sensitive.unlock` | sensitiveAccess | (none) |
| `sensitive.viewed` | sensitiveAccess | entryId |
| `export.created` | export | scope, sizeBytes |
| `delete.entry` | delete | entryId, type |
| `delete.all` | delete | confirmed |
| `key.biometric.invalidated` | keyManagement | (none) |
| `lock.engaged` | appLock | reason |
| `lock.released` | appLock | method |

### 8.3 Integrity

Each row's HMAC covers the previous row's HMAC (chain). Tampering with any row breaks subsequent verification. Surface integrity check failures in Settings > Privacy > Audit Log.

### 8.4 User-facing view

Settings > Privacy > Activity Log:
- Filter by category, date range.
- Export as CSV (signed).
- Cannot be cleared by user (immutable) — only deletable via "delete all data" which wipes everything.

### 8.5 Retention

Default: forever. Add a setting "Trim audit log entries older than [30 / 90 / 365 / never] days." Default never. Trimming logs the trim event itself as the new first row.

---

## 9. Privacy Manifest Configuration

### 9.1 `PrivacyInfo.xcprivacy`

```xml
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <!-- Health data is processed entirely on-device and never linked to user identity -->
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeHealth</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
    </array>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>  <!-- App functionality only -->
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
            </array>
        </dict>
    </array>
</dict>
```

### 9.2 `Info.plist` strings

```xml
<key>NSHealthShareUsageDescription</key>
<string>Fernlet uses your Health data to gently respond to your body's rhythms. Everything stays on this device.</string>

<key>NSHealthUpdateUsageDescription</key>
<string>Fernlet writes period logs, mindful minutes, and mood reflections to Apple Health so your data stays in one place under your control.</string>

<key>NSFaceIDUsageDescription</key>
<string>Fernlet uses Face ID to keep your journal and sensitive memories private to you.</string>

<key>UIBackgroundModes</key>
<array>
    <string>processing</string>
</array>
```

### 9.3 Capabilities required

- HealthKit (Background Delivery enabled)
- Keychain Sharing: NOT enabled (we don't share keys across apps)
- App Groups: only if a Watch extension is added; otherwise off

---

## 10. Implementation Phases

Ordered so each phase produces something testable and usable.

### Phase 0 — Foundations (1 week target)

- `HealthKitServicing` protocol + concrete `HealthKitService`
- `SecureStore` with master key in keychain, Core Data + NSFileProtectionComplete
- `AuditLog` skeleton with HMAC chain
- `Info.plist` usage strings, `PrivacyInfo.xcprivacy`
- Unit tests with mocked `HKHealthStore`

### Phase 1 — Read-side observability (1 week)

- Authorization for `.bodyContext` capability
- Anchored queries for HRV, RHR, sleep, steps, active energy
- Anchor persistence in keychain
- Background delivery enable
- Daily statistics computation for sleep summary
- `HKValueCache` table populated; UI reads cache

### Phase 2 — Cycle write path & bridge (2 weeks)

- Authorization for `.cycleTracking` capability
- `PeriodContextBridge` protocol + concrete implementation
- `MenstrualLog` SecureStore table with HK external UUID join
- Write path: `logEvent` with HK + SecureStore atomic semantics
- Read path: `currentPhase`, `entry(for:)` with source precedence
- Source conflict detection + UI surface
- Apple prediction integration via `HKMenstrualFlowPredicted`

### Phase 3 — Inference engine integration (1–2 weeks)

- `CycleInferenceEngine` reads from bridge, writes predictions to SecureStore only
- Phase precedence rules in `PeriodContextBridge.phase(on:)`
- Confidence surfacing in UI

### Phase 4 — Sensitive memory tier (1–2 weeks)

- Secure Enclave key generation with biometric ACL
- `SensitiveMemoryStore` with per-entry content keys, ECIES wrapping
- HMAC integrity over each row
- Biometric-gated UI flows
- App lock infrastructure with foreground/background hooks
- Biometric invalidation recovery flow

### Phase 5 — Mindfulness & state of mind (1 week)

- Authorization for `.mindfulness`
- Mindful session write on in-app exercise completion
- `HKStateOfMindType` integration (iOS 18+) with fallback to SecureStore-only
- Mood reflection UI joins HK state-of-mind + SecureStore narrative

### Phase 6 — Audit log UI & user controls (1 week)

- Settings > Privacy > Activity Log view
- CSV export of audit log
- Export all data (encrypted archive)
- Delete all data flow
- Audit log retention setting

### Phase 7 — Sexual activity (optional, off by default)

- Per-capability authorization triggered only on setting toggle
- Write-only path; no local mirror
- No analytics, no audit log context beyond timestamp

---

## 11. Testing Strategy

### 11.1 Unit tests

- Mock `HKHealthStore` via protocol. Inject `HealthKitServicing` mock.
- Test authorization outcomes including the no-read-status case.
- Test anchored query handler with synthetic samples + deletions.
- Test source conflict resolution permutations.
- Test phase precedence: observed > override > Fernlet model > Apple > unknown.
- Test crypto: round-trip seal/open, HMAC verify, wrap/unwrap.

### 11.2 Integration tests

- Use `HKHealthStore` test instance on simulator with seeded data via `HealthKitTestData` helper.
- Test background delivery wakeups in test harness (not real BGTask, but the handler logic).
- Test SecureStore migration paths.

### 11.3 Security tests

- Verify keychain items have correct accessibility attributes (`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`).
- Verify Secure Enclave key is `.biometryCurrentSet` (test by adding mock biometric → expect re-prompt).
- Verify NSFileProtectionComplete on all sensitive files (file attributes check).
- Audit log tamper test: modify a row, verify next-row HMAC fails.

### 11.4 Manual / device tests

- Real device with multiple HealthKit sources (Apple Cycle Tracking + Fernlet) to verify deduplication.
- Real biometric enrollment change to verify invalidation flow.
- Background app refresh tests with real HRV/sleep data overnight.
- Watch companion tests if/when added.

---

## 12. Open Decisions

Items requiring product input or further design work:

1. **CloudKit private DB sync for pet state.** Pro: cross-device continuity. Con: surface area increase. Recommend: opt-in, disabled by default, pet state only (never narrative or sensitive).
2. **Audit log default retention.** Current spec: forever. Alternative: rolling 1 year with explicit user opt-in for forever. Decide based on storage growth profile.
3. **Sleep source priority UI.** When multiple sleep sources exist, do we expose a "preferred source" picker, or auto-resolve? Current spec: auto-resolve with manual override available.
4. **Fernlet model vs Apple prediction confidence threshold.** Current spec: 0.7. Validate against held-out data once enough users have logged real cycles.
5. **Sexual activity feature.** Confirm feature is desired before implementation. If not, omit from Phase 7 entirely (better than having an unused permission scope).
6. **Watch app scope.** Out of scope for this plan; revisit when iPhone implementation is stable.

---

## Appendix A — Quick reference: capability ↔ types

| Capability | Read types | Write types |
|---|---|---|
| `.cycleTracking` | `.menstrualFlow`, `.basalBodyTemperature`, `.cervicalMucusQuality`, `.intermenstrualBleeding`, `.ovulationTestResult` | same |
| `.bodyContext` | `.heartRateVariabilitySDNN`, `.restingHeartRate`, `.sleepAnalysis` | none |
| `.activityContext` | `.stepCount`, `.activeEnergyBurned`, `.appleExerciseTime` | none |
| `.mindfulness` | `.stateOfMind` (iOS 18+) | `.mindfulSession`, `.stateOfMind` (iOS 18+) |
| `.intimateLogging` | `.sexualActivity` | `.sexualActivity` |

## Appendix B — File locations on device

```
Bundle Container/
  Fernlet.app/                          (read-only)

Data Container/
  Documents/                            (avoid; iCloud-backed unless excluded)
  Library/
    Application Support/
      Fernlet/
        secure.sqlite                   (SecureStore, .completeFileProtection, excluded from backup)
        sensitive.sqlite                (SensitiveMemoryStore, .completeFileProtection, excluded from backup)
        audit.sqlite                    (AuditLog, .completeFileProtection, excluded from backup)
    Caches/                             (volatile, do not store anything important)
  tmp/                                  (volatile)

Keychain (per-app)/
  com.fernlet.securestore.masterkey
  com.fernlet.auditlog.hmackey
  com.fernlet.healthkit.anchor.<type>.<predicate-hash>  (one per data type)

Secure Enclave/
  com.fernlet.sensitive.enclavekey      (P-256, .biometryCurrentSet)
```

## Appendix C — Glossary

- **Anchored query:** `HKAnchoredObjectQuery`. Returns only samples added/deleted since the previous anchor; lets you sync incrementally without re-reading the world.
- **Background delivery:** Tells HealthKit to wake the app when new data arrives. Frequencies: `.immediate`, `.hourly`, `.daily`, `.weekly`.
- **ECIES:** Elliptic Curve Integrated Encryption Scheme; how we wrap symmetric content keys with the Secure Enclave's asymmetric key.
- **External UUID:** HealthKit metadata key (`HKMetadataKeyExternalUUID`) used to correlate a HK sample with our SecureStore row.
- **HMAC chain:** Each audit log row's HMAC covers the previous row's HMAC, making tampering with old rows detectable.
- **Predicted sample:** A HealthKit sample with `HKMenstrualFlowPredicted = true`; Apple's prediction, not user-logged. Never overwrite with our predictions.

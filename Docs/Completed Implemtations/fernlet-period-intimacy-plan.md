# Fernlet — Period & Intimacy Tracking Implementation Plan

**Purpose:** Companion document to `healthkit-integration-plan.md` and `FernletSpecificationV3.md`. Specifies how period and intimacy tracking get implemented in the current prototype, with the new addition of a Fernlet-set passcode gate.

**Relationship to existing docs:**
- `healthkit-integration-plan.md` §5 (PeriodContextBridge) and §3.2 (Menstrual Flow, Sexual Activity) define the storage model — this doc inherits those.
- `FernletSpecificationV3.md` §4 (Period Context Bridge) and §5.1 (Intimate Tracking Placeholder) define the privacy boundary — this doc inherits those.
- The new piece: **FernletLock**, a user-set passcode that gates *viewing* history but never blocks logging.

---

## 1. Scope

**In scope (v1):**
- Fernlet-set passcode (4-digit PIN, 6-digit PIN, or alphanumeric — user chooses at setup) that gates the period and intimacy *viewing* surfaces.
- Period write path: log menstrual flow, basal body temp, cervical mucus, intermenstrual bleeding, ovulation test results to HealthKit.
- Period UI: calendar view, recent events list, current-phase indicator, day detail view. All gated.
- Period log sheet: quick entry form. **Not gated.** Reachable from anywhere.
- Intimacy write path: log sexual activity events to HealthKit.
- Intimacy UI: minimal event list (date-only rows) and detail view. All gated.
- Intimacy log sheet: quick entry form. **Not gated** (still age-gated to 18+).
- `PeriodContextBridge` with abstract signals only.
- Module boundary tests proving raw period and intimacy types cannot be imported by AI providers, scoring, export bundles, or memory extraction.

**Out of scope (v1):**
- `CycleInferenceEngine` ML predictions. Phase computation is observation-based only in v1.
- Period health trend analysis by phase (defer until 3+ cycles logged, as in spec).
- Intimacy analytics or bridge signals of any kind. v1 = write-only sealed; no read path outside the intimacy tab.
- Encrypted sealed backup to CloudKit (defer to dedicated backup phase).
- Watch companion.

---

## 2. FernletLock — new privacy gate

### 2.1 Why it exists, separate from device passcode

The device passcode and Face ID / Touch ID protect the device. They do not protect against:
- An intimate partner who knows the device passcode.
- Someone the user briefly hands the phone to.
- Face ID being triggered by holding the phone up to the user's face.

FernletLock is a **second factor inside the app** that the user sets independently. Period and intimacy *history and counts* are not viewable without it. New events can still be logged without it — the privacy guarantee is about reading existing data, not preventing the user from quickly recording new events.

### 2.2 Credential design

At setup, the user picks one of:
- **4-digit numeric PIN** — fast, lowest friction, lower entropy.
- **6-digit numeric PIN** — iOS norm, recommended default option in the picker.
- **Alphanumeric password** — minimum 8 characters, maximum 64.

PIN choice is persisted; the user can change it later in Settings → Privacy → App Lock, which is itself behind the existing lock.

**Optional biometric convenience.** A Face ID / Touch ID toggle. When on, the unlock screen prompts biometric first; if it fails or is cancelled, falls back to PIN. Turning biometric on requires entering the current PIN. Turning it off does not.

### 2.3 Cryptographic design

```
Per-install (created on first PIN setup):
  salt: 16 random bytes, Keychain
  argonParams: t=3 iterations, m=64 MiB memory, p=1 parallelism (Argon2id)
  verifier: Argon2id(passcode || salt, argonParams) → 32 bytes, Keychain
  
  contentKey: SymmetricKey, 256-bit, generated via SystemRandomNumberGenerator
  wrappedContentKey: ChaChaPoly.seal(contentKey, key: Argon2id(passcode, salt))
                     Keychain
  
  biometricBypassKey (when biometric toggle on):
    copy of contentKey, wrapped by a Keychain item whose access control is
    SecAccessControlCreateWithFlags(.biometryCurrentSet)
    Keychain
```

**Argon2id is the only KDF.** No PBKDF2 fallback path. Pull in a maintained Swift Argon2 package — recommended: [`tmthecoder/Argon2Swift`](https://github.com/tmthecoder/Argon2Swift) or `jedisct1/swift-sodium` (libsodium has Argon2id). Pin the version in `Package.swift`.

The `contentKey` wraps a master row-encryption key used for column encryption of the period mirror tables in SecureStore. Without the passcode (or biometric bypass), the wrapped key is opaque bytes in Keychain and the rows in SecureStore remain ciphertext.

### 2.4 Lock state machine

States:
- `notConfigured` — user has never set a passcode. Period and intimacy *viewing* surfaces show a setup CTA; *logging* still works freely.
- `locked` — passcode set, content key not in memory.
- `unlocked` — content key in memory. **No timestamp, no expiry timer.**

Unlock is tied to the lifecycle of the gated view:

```
View.onAppear → if locked, present unlock screen → on success, mark unlocked
View.onDisappear → scrub content key from memory, mark locked
```

Every entry into a gated view re-prompts. There is no "unlocked for the next N seconds" carry-over. If the user taps the period tab, unlocks, leaves, and comes back, they unlock again.

Within a single unlock, navigation between child views (calendar → day detail → back) does not re-prompt. The unlock belongs to the gated section's lifetime, not to each child route.

**Forced re-lock triggers (in addition to view disappear):**
- App backgrounded — relock immediately, no grace period.
- Device locks (`UIApplication.protectedDataWillBecomeUnavailableNotification`).
- User taps "Lock now" in settings.

**Failed-attempt cooldown.** After **4 consecutive failed passcode attempts**, an exponential cooldown engages. Cooldown levels and per-level attempt allowance:

| Failed attempts before cooldown | Cooldown duration | After cooldown |
|---|---|---|
| 4 | 1 minute | 4 more attempts allowed |
| 4 | 15 minutes | 4 more attempts allowed |
| 4 | 1 hour | 4 more attempts allowed |
| 4 | 4 hours | After this, passcode reset is the only option |

Failed-attempt count resets to zero on a successful unlock. The cooldown clock survives app restarts (cooldown deadline stored in Keychain). Biometric unlock attempts do not count toward the failure budget; only passcode attempts do.

**Cooldown clock integrity.** The wall-clock deadline remains the primary persisted record so cooldowns survive reboot. A monotonic-uptime anchor (`ProcessInfo.processInfo.systemUptime`) and the cooldown duration are written beside it. The effective remaining cooldown is `max(wallClockRemaining, monotonicRemaining)`. Within a single boot session, advancing the device clock cannot shorten the cooldown; if wall-clock says the cooldown expired but monotonic uptime disagrees, Fernlet emits `lock.cooldownClockRegression`. Across a reboot, the monotonic anchor is no longer comparable and wall-clock becomes the sole signal; Fernlet emits `lock.cooldownMonotonicResetByReboot`. This reboot plus clock-change combination is the only remaining surface where a determined attacker who also controls the device passcode could theoretically shorten the defense-in-depth cooldown, and it is acceptable for the threat model because the verifier remains protected by the Scrypt-derived credential flow.

On lock, scrub the in-memory content key via `Data.resetBytes(in:)`. Any decrypted plaintext currently displayed is dismissed.

### 2.5 Recovery

There is no recovery path. Forgetting the passcode means the user can reset FernletLock — this **wipes** the wrapped key and all encrypted local mirror rows in SecureStore. HealthKit data is unaffected (it lives in Apple Health, not in our wrapped store).

After reset, the user sets a new passcode and the period view lazily rebuilds a mirror by reading HK on next unlock and re-encrypting any new narrative entries under the new key. Old encrypted narratives (notes, custom symptom scales) cannot be recovered.

This loss model is disclosed at passcode setup with a confirm dialog.

### 2.6 What FernletLock gates

| Surface | Gated? |
|---|---|
| Period tab viewing surface (calendar, history, day detail) | **Yes — every visit** |
| Intimacy tab viewing surface (event list, event detail) | **Yes — every visit** |
| Journal viewing surface (calendar, entries, day detail) | **Yes — every visit** |
| Period log sheet (entry form, no history shown) | No |
| Intimacy log sheet (entry form, no history shown) | No |
| Period/intimacy export action | Yes |
| Settings → Health → Cycle tracking row (capability toggle) | No |
| Settings → Health → Intimate logging row (capability toggle) | No |
| Settings → Privacy → App Lock (manage passcode, biometric, reset) | Yes (after first setup) |
| `HealthCycleContext.menstrualFlowEventCount` shown anywhere outside the gated view | No — count is suppressed |
| `HealthIntimateContext.eventCount` shown anywhere outside the gated view | No — count is suppressed |
| All other tabs (food, move, etc.) | No |

Journal viewing is gated by the PrivateHubView outer lock gate, but journal data on disk is currently still protected only by iOS file protection, not by the FernletLock content key. Aligning journal at-rest encryption with the period-narrative model is tracked as part of the planned storage revamp.

Because viewing surfaces require fresh unlock and log sheets do not, the log sheets must show **only** the entry form — never a recent-history list, never a count, never a "last logged X days ago" hint.

### 2.7 Audit

Every lock state transition writes to the audit log (extending §8 of `healthkit-integration-plan.md`):
- `lock.configured` — passcode set for first time, with credential kind (`pin4`, `pin6`, `alphanumeric`).
- `lock.kindChanged` — credential kind changed.
- `lock.engaged` — moved to `locked`, with reason (`viewDisappeared`, `background`, `protectedDataUnavailable`, `manual`, `failedAttempts`).
- `lock.released` — moved to `unlocked`, with method (`passcode`, `biometric`).
- `lock.failedAttempt` — incorrect passcode, with current cooldown level (0–4).
- `lock.cooldownStarted` — cooldown level entered, with duration.
- `lock.cooldownClockRegression` — wall-clock claims the cooldown expired, but monotonic clock disagrees. Context: `monotonicRemainingSeconds`. Never includes plaintext.
- `lock.cooldownMonotonicResetByReboot` — monotonic anchor is from a previous boot session and cannot cross-check. Wall-clock is now the only signal. No context payload beyond the event name.
- `lock.reset` — passcode reset, mirror rows wiped (count of rows logged, never contents).

Contexts include zero plaintext. Never log the passcode, derived key, or any decrypted content.

---

## 3. Period tracking

### 3.1 Authorization

`.cycleTracking` capability already exists in `HealthCapability`. Triggered just-in-time on first entry into the period **viewing** surface (after unlock). If the user has not yet configured FernletLock, the viewing surface shows the lock-setup CTA, and `.cycleTracking` authorization is not requested. The log sheet, when used independently, requests `.cycleTracking` authorization on first use as well.

### 3.2 Write path (log sheet — ungated)

The log sheet is reachable from:
- A quick-log shortcut on Home (new `.logPeriod` case in `FernletShortcut`).
- A "+" button inside the gated viewing surface (which still works because logging is already passed through to the same sheet).
- The header action on the period `PersonalScreenView` (existing in `ContentView`).

The sheet shows **only the entry form**: flow level, basal body temp, cervical mucus quality, ovulation test result, intermenstrual bleeding toggle, free-text note, "first day of cycle" toggle. **No recent history, no count, no calendar peek.**

Per §5.6 of `healthkit-integration-plan.md`:

```
1. Sheet presents the entry form.
2. On save:
   a. entityUUID = UUID()
   b. For each non-empty observation, build the matching HKCategorySample or HKQuantitySample
      with HKMetadataKeyExternalUUID = entityUUID.uuidString
      and HKMetadataKeyMenstrualCycleStart if "first day" toggled.
   c. healthStore.save(samples)
   d. If a note or custom symptom scales are present AND FernletLock is configured:
      ⚠ The content key is not in memory because the log sheet is ungated.
      The narrative bytes are queued in a pending-narrative buffer (encrypted at rest
      with an ephemeral wrap that the next unlock can re-wrap properly).
      On next unlock, the buffer is drained: each pending narrative is sealed with the
      real column key and inserted into SecureStore.MenstrualNarrative, then removed
      from the buffer.
   e. If FernletLock is not configured:
      ⚠ Narrative bytes are dropped — the user has chosen no protection, and we will
      not store narrative until they configure a passcode. Show a brief banner:
      "Notes will be saved once you set up app lock in Settings."
   f. Audit log: hk.write.saved with type and entityUUID (no values).
3. If HK save fails: surface error, drop the pending narrative.
```

The pending-narrative buffer is a tiny encrypted file in the app container, sealed with a salt-derived key tied to a Keychain-only item (NOT the FernletLock content key). It cannot reveal plaintext without device unlock plus first-unlock-after-boot, and it is automatically purged once drained. It exists so that quick logging does not silently lose the note field.

### 3.3 Read path (viewing surface — gated)

```
1. Period tab loads.
2. LockGate runs: present unlock screen. On success, mark unlocked, load content key.
3. Drain pending-narrative buffer using the now-available content key.
4. Query HKAnchoredObjectQuery for menstrual flow, BBT, mucus, ovulation,
   intermenstrual bleeding over the last 90 days (configurable).
5. Join each sample's metadata externalUUID to SecureStore.MenstrualNarrative.
6. Build CycleDayEntry per §5.2 of healthkit-integration-plan.md.
7. Compute current phase using observed events only (no ML in v1).
8. Render calendar with phase coloring, day cells tap into a day detail view.
9. On view disappear, scrub content key and any decrypted narratives from memory.
```

### 3.4 Local mirror schema

`MenstrualNarrative` (Core Data, in the existing SecureStore stack, with column encryption):
- `id: UUID` (primary key)
- `hkExternalUUID: String` (foreign key to HK sample metadata)
- `dateKey: String` (yyyy-MM-dd for indexing)
- `noteCiphertext: Data` (ChaChaPoly sealed under FernletLock-derived column key)
- `symptomFlagsCiphertext: Data` (encrypted bitfield: cramps, headache, breast tenderness, mood swings, fatigue, bloating, acne, back pain, food cravings)
- `customSymptomScalesCiphertext: Data` (encrypted JSON: cramp intensity 1–10, etc.)
- `createdAt: Date`
- `updatedAt: Date`

No raw `notes` column. The encrypted columns are opaque when the wrapped content key cannot be unwrapped.

### 3.5 Predictions

No phase predictions affect anything in the app until **3+ completed cycles** have been logged. Until then:
- The bridge returns `.unknown` for `PeriodPhaseSignal` unless an observed event places the user in `.menstrual`.
- The scoring engine does not apply any period-aware adjustment.
- The UI shows observed days only — no predicted next-period highlight, no fertile window estimate.

Once 3 cycles are present, calendar math (rolling mean + standard deviation) per `FernletSpecificationV3.md` §4 produces a next-period estimate. ML-based inference is deferred to a later phase.

---

## 4. Intimacy tracking

### 4.1 Authorization

Triggered just-in-time on first use of either:
- The intimacy log sheet (ungated, but age-gated to 18+).
- The intimacy viewing surface (gated, after unlock).

`.intimateLogging` capability requests `HKCategoryTypeIdentifier.sexualActivity`. Age-gate check (existing `FernletStore.isIntimateLoggingAllowed`) runs before authorization is requested. The same age gate also hides the intimacy section from `PrivateHubView` and removes intimacy shortcuts from Home and the quick-log picker when the user is under 18.

### 4.2 Write path (log sheet — ungated)

Reachable from:
- A quick-log shortcut on Home (new `.logIntimacy` case in `FernletShortcut`, hidden when age-gate fails).
- A "+" button inside the gated viewing surface.

```
1. Sheet checks age-gate. If under 18, show "available for adults" message and dismiss.
2. Sheet presents:
   a. Date/time picker (default: now)
   b. Optional "protection used" toggle (HKCategoryValueProtectionUsed)
   c. No notes, no partner identification, no free text.
3. On save:
   a. Build HKCategorySample with HKMetadataKeySexualActivityProtectionUsed when applicable.
   b. healthStore.save([sample])
   c. Audit log: hk.write.saved with type only (no date in context, no metadata).
4. No local mirror. HK is canonical and the only store.
5. No pending-narrative buffer needed — there is no narrative to defer.
```

### 4.3 Read path (viewing surface — gated)

```
1. Intimacy tab loads.
2. LockGate runs: present unlock screen. On success, mark unlocked.
3. Query HKSampleQuery for sexual activity over the last 30 days.
4. Render: "<N> events in the last 30 days" header, then a list of date-only rows.
5. Tap a row to view detail (date, protection-used flag) and optionally delete.
6. On view disappear, mark locked. No content keys to scrub since no decryption happened.
```

### 4.4 No bridge signals in v1

The intimacy tab cannot expose anything to the rest of the app. No event count, no last-event date, no abstract signal. Other parts of the app behave exactly as if the feature did not exist.

To enforce this:
- `HealthIntimateContext.eventCount` is suppressed in any view outside the intimacy viewing surface and outside the log sheet. The intimacy summary cards on Home show "Tap to view" rather than counts.
- The intimacy tab does not produce any `DerivedSignal`.
- The intimacy types live in a separate Swift module that `OHTTPProvider`, `MemoryExtractionContext`, `ContextBuilder`, `ScoreEngine`, and export bundle code cannot import.

### 4.5 Future analytics (out of v1)

If/when intimacy signals are added later, they must:
- Be added through a dedicated `IntimacyBridge` (parallel to `PeriodContextBridge`), with its own opt-in toggle in settings, default off.
- Expose only abstract booleans like `recentActivity: Bool` over a coarse 7-day window — never counts, never dates.
- Pass the same module boundary tests.

This is explicitly deferred.

---

## 5. PeriodContextBridge — restricted egress

### 5.1 Public protocol

```swift
public protocol PeriodContextBridging {
    /// Current phase as an opaque enum. No dates, no counts.
    func currentPhaseSignal() async -> PeriodPhaseSignal

    /// Position within current cycle as a coarse band.
    func currentPhaseBand() async -> PeriodPhaseBand

    /// Abstract nutrition hint, never a specific value.
    func nutritionSignal() async -> PeriodNutritionSignal

    /// Abstract exercise hint, never a specific value.
    func exerciseSignal() async -> PeriodExerciseSignal
}

public enum PeriodPhaseSignal {
    case menstrual, follicular, ovulatory, luteal, unknown
}

public enum PeriodPhaseBand {
    case menstruating, early, mid, late, unknown
}

public enum PeriodNutritionSignal {
    case iron(Strength)            // suggest iron-rich foods during menstruation
    case complexCarbs(Strength)    // mid-luteal energy
    case omega3(Strength)
    case noData
    public enum Strength { case suggested, none }
}

public enum PeriodExerciseSignal {
    case gentleness(Strength)       // suggest gentler workouts during menstruation
    case strengthFriendly(Strength) // follicular window
    case noData
    public enum Strength { case suggested, none }
}
```

### 5.2 What the bridge MUST NOT expose

Hard rules — these would fail the module boundary tests:
- No `Date` values of any kind. No "days until next period," no "started 3 days ago."
- No counts. No "logged 5 cycles." No "12 events in last 6 months."
- No raw HK sample references. No `HKCategorySample`. No `UUID` of any HK row.
- No symptom details. The bridge sees them; the bridge never re-exposes them.
- No intimacy data of any kind, ever.
- No predicted dates from Apple's `HKMenstrualFlowPredicted`.
- No confidence values from any inference model.

### 5.3 Recompute, don't cache

Bridge signals are computed on demand from the read path described in §3.3. They are not stored independently in SecureStore. Deleting period data immediately causes signals to return `.unknown` / `.noData`.

This is a deliberate forgetfulness property: a user who wipes period data has no residue elsewhere in the app.

**Locked-state behavior.** When FernletLock is locked, the bridge cannot read the local mirror narratives. It can still read HK sample dates/values (HK auth lives at the OS level), so phase computation still works from observed events. The bridge degrades gracefully: it returns phase and band based on HK events alone, and `noData` for nutrition/exercise signals that depend on user-marked symptom severity. Most v1 callers never hit this branch because they call the bridge only from inside already-unlocked contexts (scoring, food/move suggestions running on the user-visible day).

### 5.4 Who can call the bridge

| Caller | Allowed? |
|---|---|
| `ScoreEngine` | Yes — phase signal feeds period-aware scoring adjustments (only after 3 cycles) |
| Home companion thought generator | Yes — but only phase and band, never nutrition/exercise signal directly |
| Food tab daily suggestion | Yes — nutrition signal |
| Move tab daily suggestion | Yes — exercise signal |
| `OHTTPProvider` | **No.** Cloud AI providers do not receive period bridge signals. |
| `MemoryExtractionContext` | **No.** AI memory extraction does not see period state. |
| Foundation Models prompts (on-device) | Yes, conditionally — only the phase enum may be included, never nutrition/exercise hints. |
| Export bundles (trainer/nutritionist) | **No.** Period state is excluded from any export. |
| Friend visibility / sharing | **No.** Period state is never shareable. |
| Activity rosters | **No.** |

### 5.5 Module structure

Enforce the table above at compile time by isolating period and intimacy types in dedicated Swift packages or local SPM modules:

```
PrivateHealthStore/        <- raw period types, MenstrualNarrative, HK sample handling
  PeriodEntry
  MenstrualNarrative
  CycleInferenceEngine (future)

PrivateIntimacyStore/      <- intimacy types
  IntimacyEvent

PeriodContextBridge/       <- depends on PrivateHealthStore (read-only)
  PeriodPhaseSignal
  PeriodPhaseBand
  PeriodNutritionSignal
  PeriodExerciseSignal
  PeriodContextBridging

# Module rules (verified by tests):
ContextBuilder/            <- MUST NOT import PrivateHealthStore, PrivateIntimacyStore
AIProviders/OHTTPProvider/ <- MUST NOT import PrivateHealthStore, PrivateIntimacyStore, PeriodContextBridge
MemoryExtractionContext/   <- MUST NOT import PrivateHealthStore, PrivateIntimacyStore, PeriodContextBridge
ExportBundles/             <- MUST NOT import PrivateHealthStore, PrivateIntimacyStore
FriendSharing/             <- MUST NOT import PrivateHealthStore, PrivateIntimacyStore, PeriodContextBridge
```

If the codebase is still a single module, enforce the same rules with:
- A `BoundaryTests` test target that scans source files for forbidden imports/type references.
- A build phase script that fails the build when forbidden symbols appear in disallowed files.

The boundary test approach is acceptable as a stopgap and is what the codex prompt below targets.

---

## 6. Implementation phases (one PR per phase)

### Phase A — FernletLock infrastructure (Sonnet)

Foundation. Everything else blocks on this.

- `FernletLockService` protocol + concrete implementation.
- Argon2id verifier + content key wrapping in Keychain (no PBKDF2 fallback).
- Lock state machine: `notConfigured`, `locked`, `unlocked`. No timestamps, no expiry.
- View-lifecycle gating: a `LockGate` view modifier that:
  - On `onAppear`, presents an unlock sheet if locked.
  - On `onDisappear`, scrubs content key and marks locked.
- `FernletLockView` with PIN entry pad and biometric prompt branch.
- `FernletLockSetupView` for first-time setup with the 4-digit / 6-digit / alphanumeric picker.
- Settings → Privacy → App Lock section: enable/disable, change passcode, change kind, biometric toggle, reset (with destructive confirm). This section itself sits behind the lock once configured.
- App lifecycle hooks: relock on background, on protected-data-unavailable, on manual lock.
- Pending-narrative buffer infrastructure (encrypted at rest, drained on unlock, used only by period log sheet — Phase B fills the consumer side).
- Failed-attempt cooldown with exponential progression (1m, 15m, 1h, 4h, then reset-only). Cooldown deadline survives app restart.
- Audit log entries.
- Unit tests: passcode verify for all three credential kinds, content key wrap/unwrap round-trip, cooldown progression, attempt counter reset on success, reset wipes wrapped key.

**Exit criteria:** Period and intimacy viewing surfaces show the lock-setup CTA if not configured, the unlock screen if locked, a "you're in" placeholder when unlocked. Log sheets work without unlock. No HealthKit writes yet.

### Phase B — Period write path + UI (Codex)

Depends on Phase A.

- `PeriodTrackerStore` (MainActor `ObservableObject`).
- HealthKit write path for cycle types per §3.2, callable from anywhere (no unlock required).
- `MenstrualNarrative` Core Data entity + repository with column encryption using FernletLock-derived key (only accessible inside the gated view).
- Pending-narrative buffer producer: when the log sheet runs without FernletLock unlocked, narrative bytes are written to the buffer instead of `MenstrualNarrative` directly.
- Pending-narrative buffer consumer: on every successful unlock, drain the buffer into encrypted rows.
- `LogPeriodSheet` (ungated, no historical UI inside it).
- New `FernletShortcut.logPeriod` quick-log entry on Home.
- Period viewing surface (`PeriodTrackerView`): calendar with phase coloring, day detail view, "+" button that opens `LogPeriodSheet`. Wrapped in `LockGate`.
- Just-in-time `.cycleTracking` authorization request on first use of either log sheet or viewing surface.
- Suppress `HealthCycleContext.menstrualFlowEventCount` from any view outside the period viewing surface.
- Audit log entries.
- Tests: HK write round-trip with mock store, pending-narrative buffer drain round-trip, calendar view rendering with sample data, count suppression on Home.

**Exit criteria:** User can quick-log a period day without unlocking. After unlocking the period tab, the entry appears on the calendar with the note attached (if the note was written before unlock, it was drained from the buffer). HK Health app reflects the same entry.

### Phase C — Intimacy write path + UI (Codex)

Depends on Phase A. Ships in parallel with Phase B.

- `IntimacyTrackerStore` (MainActor `ObservableObject`).
- HealthKit write path for sexual activity per §4.2, callable from anywhere (no unlock required, but age-gated).
- `LogIntimacySheet` (ungated, no historical UI inside it).
- New `FernletShortcut.logIntimacy` quick-log entry on Home, hidden when age-gate fails.
- Intimacy viewing surface (`IntimacyTrackerView`): event list with date-only rows, detail view, "+" button. Wrapped in `LockGate`.
- Just-in-time `.intimateLogging` authorization request on first use.
- **No local mirror.** No pending-narrative buffer.
- Suppress `HealthIntimateContext.eventCount` from any view outside the intimacy viewing surface and the log sheet.
- Audit log entries (minimal context per §4.4 of `healthkit-integration-plan.md`).
- Tests: HK write round-trip, age-gate behavior, hidden-when-locked behavior of count, no leakage into `DerivedSignal` records.

**Exit criteria:** User can quick-log an intimacy event without unlocking. After unlocking the intimacy tab, the entry appears in the list. HK Health app reflects the same entry. No event count or any other intimacy signal appears anywhere else in the app.

### Phase D — PeriodContextBridge + boundary tests (Sonnet)

Depends on Phase B.

- `PeriodContextBridging` protocol + concrete implementation per §5.
- Phase computation from observed HK events only (no ML in v1).
- Nutrition + exercise signal mappers from phase.
- 3-cycle gate before phase-aware behavior turns on: until then, `currentPhaseSignal()` returns `.unknown` unless a same-day observed flow event overrides.
- Locked-state degradation behavior per §5.3.
- Wire bridge into:
  - `ScoreEngine` for phase-aware adjustments (gated behind the 3-cycle threshold and user opt-in toggle in settings).
  - Food daily suggestion (nutrition signal).
  - Move daily suggestion (exercise signal).
- `BoundaryTests` test target proving:
  - `OHTTPProvider`, `MemoryExtractionContext`, `ContextBuilder`, export bundle code, and friend-sharing code do not import `PrivateHealthStore`, `PrivateIntimacyStore`, or (for the cloud/AI/sharing surfaces) `PeriodContextBridge`.
  - `HealthIntimateContext` does not appear anywhere outside the intimacy viewing surface and log sheet.
- Tests: bridge returns `.unknown` after wiping period data, returns degraded signals when locked, returns full signals when unlocked.

**Exit criteria:** Bridge signals work in scoring and suggestions (after 3 cycles), boundary tests pass, raw types are unreachable from forbidden modules.

---

## 7. Privacy manifest & usage description updates

`Info.plist`:
- `NSHealthShareUsageDescription`: must explicitly mention cycle and (when feature enabled) sexual activity reads.
- `NSHealthUpdateUsageDescription`: same.
- `NSFaceIDUsageDescription`: required when biometric unlock is enabled. Copy: "Fernlet uses Face ID to unlock the period and intimacy sections."

`PrivacyInfo.xcprivacy`:
- Health & Fitness data category for cycle tracking.
- User Content for any encrypted local mirror.
- No tracking domains, no advertising identifiers.

App Store nutrition labels (review with legal before shipping):
- Cycle data: Health & Fitness, Linked to You (because of HK association with Apple ID, even though Fernlet itself never sees it outside HK).
- Sexual activity: Health & Fitness, Not Collected (Fernlet never reads it back into its own storage outside HK).

---

## 8. Open decisions

1. **Wipe-on-PIN-reset surfacing.** Resolved: wipe local mirror on reset; show a "re-link to existing Health data" toast on next unlock that explains old notes are gone but HK observations remain.
2. **Period-aware scoring default.** Resolved: gated behind 3+ logged cycles AND a settings opt-in toggle. Default off until both conditions are met.
3. **Pending-narrative buffer eviction.** If the buffer accumulates more than N (say 50) entries without an unlock, evict the oldest. Decide N before Phase B starts. Recommend 50.
4. **Argon2id parameters.** Spec proposes t=3, m=64 MiB, p=1. Validate on the lowest supported device that unlock takes < 500 ms. Tune memory cost downward if needed (never below m=32 MiB).
5. **Biometric on alphanumeric.** Biometric bypass should work the same way regardless of credential kind. Confirm UX: should the bypass be offered when credential kind is alphanumeric, or only for PINs? Recommend: offer for all kinds.

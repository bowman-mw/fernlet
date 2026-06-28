# Security Hardening Plan — S3 Wall Review Follow-ups (2026-06-27)

> **Handoff doc.** This plan is self-contained. A fresh session should be able to execute it
> with only this file + the repo. It captures the actionable follow-ups from the security review
> of the SPM "S3 privacy wall" carve-up.

---

## 0. Context for a fresh session

**What was reviewed.** The ~250-file "SPM module carve-up" (commits `0fc138c`..`HEAD`, i.e. diff range
`9b176de..HEAD`) carved the app into the local `FernletKit` Swift package. Its security purpose is the
**S3 wall**: the two "walled consumer" modules — `AIProviders` (on-device Foundation-model inference)
and `CloudKitSync` (iCloud sync) — must be *structurally incapable* of reaching the sealed `Private*`
stores (journal text, cycle/intimacy, sealed photos). Sealed data may only egress as the de-identified
typed payloads in `AIContext`.

**Verdict of the review (already done — do NOT re-litigate):**
- The wall itself is **correctly implemented and proven load-bearing**. A positive build under
  `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` succeeds; injecting a forbidden
  `import PrivateHealthStore` into an `AIProviders` file produces `error: 'AIProviders' is missing a
  dependency on 'PrivateHealthStore'` (exit 65, build fails). The dependency DAG, at-rest sealing crypto,
  iCloud container exclusion, AI egress de-identification, and the Proximity signing/replay surface all
  moved without regression.
- The items below are the **gaps the wall does not cover** plus a pre-existing leak in the same privacy
  invariant. **None of these block the conclusion that the carve-up's security feature works** — they
  harden it and close one real leak.

**Key files (orientation):**
| Area | File |
| --- | --- |
| The wall (DAG) | `FernletKit/Package.swift` |
| Compiler-wall runner | `Scripts/spm-wall-check.sh` |
| Grep-wall backstop | `FernletTests/S3BoundaryTests.swift` |
| Sanctioned AI egress | `FernletKit/Sources/AIContext/{AIContextPayload,MemoryAgent,AIAuditLog}.swift` |
| Cloud-snapshot sanitizer | `FernletKit/Sources/FernletPersistence/FernletSnapshot.swift` (`forStorage`) |
| Journal sealing | `Fernlet/JournalSealingCoordinator.swift` + `Fernlet/FernletStore.swift` (`addJournal`/`updateJournal`/`currentSnapshot`) |

**Build / test / verify commands:**
```bash
# Build
xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
# Targeted tests (run in batches — full FernletTests is ~7min; lock suite is slow)
xcodebuild test-without-building -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests/<Suite>
# S3 compiler-wall check (this is the empirical wall verification)
FERNLET_DESTINATION='platform=iOS Simulator,name=iPhone 17' Scripts/spm-wall-check.sh   # expect exit 0
```
Simulator present: `iPhone 17` (and `iPhone 17 Pro`/`Pro Max`/`17e`). Xcode 26.5.

**Wall negative-test technique (use to validate WI-3):** temporarily add `import PrivateHealthStore` to
any `FernletKit/Sources/AIProviders/*.swift`, run the wall check, confirm it fails with exit 65 and
`is missing a dependency on`, then revert.

---

## 1. Priority & sequencing

| ID | Pri | Sev | Title | Carve-up origin |
| --- | --- | --- | --- | --- |
| **WI-1** | P0 | HIGH | Past-day journal add/edit writes plaintext into the iCloud-synced blob | pre-existing, preserved |
| **WI-2** | P1 | MED | HealthKit cache-clearer silently no-ops → opt-out clinical data may persist in sync | this change (new seam) |
| **WI-3** | P1 | MED | Wall enforcement flag runs in no CI / no everyday build | this change |
| **WI-4** | P1 | MED | Grep-wall omits 2 app-resident AI files + cycle/photo/import tokens | this change |
| **WI-5** | P1 | MED | Period-restore no-clobber guard duplicates sealed history | this change |
| **WI-6** | P2 | MED (roadmap) | Mesh canonical signing encoder not cross-platform byte-stable | pre-existing; blocks Android port |
| **WI-7** | P2 | LOW | Over-broad public API surface (`TierTwoMemoryRecord.text`, lock crypto) | this change |
| **WI-8** | P2 | LOW | `FriendSessionTrustPolicy` blanket-trust — pin with a test | this change |
| **WI-9** | P2 | LOW | ProximityKit `MainActor` isolation forces off-main decode under `.v5` | this change |
| **WI-10** | P2 | LOW | Robustness: DiaryStore rewire-hook no-op risk + `commitResolution` recipe loss | mixed |
| **WI-Q** | P3 | — | Quality/duplication cluster (non-security) | this change |

**Recommended order:** WI-1 first (only item that moves real user data today), then WI-2/WI-3/WI-4/WI-5
(enforcement + backstop hardening), then the P2/P3 batch as capacity allows. WI-1, WI-2, WI-5, WI-8, WI-10
each want a regression test; WI-6 and WI-9 are larger/architectural — scope them deliberately.

---

## 1a. Implementation status (updated 2026-06-27, branch `claude/adoring-hoover-3c0a22`)

| ID | Status | Notes |
| --- | --- | --- |
| **WI-1** | ✅ Done | Core past-day strip (`strippedIfSealed` + `mutatePastDay` hook) + one-time run-once scrub migration for already-leaked history (`scrubbedLeakedPastDayJournals` + `scrubLeakedPastDayJournalsIfNeeded`). **WI1-1 follow-up (2026-06-28):** the run-once version flag is now advanced **only** on a zero-failure pass — a day whose seal fails keeps its plaintext (no data loss) and the flag stays unset so a later launch retries it; a bounded `pastDayJournalScrubAttemptsKey`/`pastDayJournalScrubMaxAttempts` (3) counter caps the retries so a permanently-failing entry can't loop forever (after the cap the flag is set + an audit line logged). `scrubbedLeakedPastDayJournals` now returns `PastDayScrubOutcome` (changed days + `unsealedFailureCount`); the coordinator depends on a new `JournalNarrativeStoring` seam so the regression can inject a failing seal. Tests: `PastDayJournalSealingTests` (4) + `PastDayJournalScrubMigrationTests` (4 — added `scrub_retriesDayWhoseSealFailsOnce_thenSealsItOnNextRun`, `scrub_givesUpAfterMaxAttempts_withoutLoopingUnbounded`). |
| **WI-2** | ✅ Done | `disableIntegration()` fails closed (`cacheClearerUnavailable` + audit) when no clearer installed; `defaultCacheClearer`/`cacheCleaner` now optional. Test: `HealthKitDisableTests.disableFailsClosedWhenNoCacheClearerInstalled`. |
| **WI-3** | ✅ Done | `.github/workflows/s3-wall.yml` + `Scripts/git-hooks/pre-push` + `Scripts/install-git-hooks.sh` + `Scripts/spm-wall-selftest.sh` (automated negative test) + CLAUDE.md ritual. |
| **WI-4** | ✅ Done | `S3BoundaryTests` now discovers AI-facing files dynamically + hard floor (incl. `FoundationDishDecomposition`/`FoodProductWebImporter`); forbidden tokens expanded incl. the four `import Private*` + sealed value types; `Package.swift` comment corrected; planted-token fixture added. |
| **WI-5** | ✅ Done | Period-restore `.periodData` guard now gates on `MenstrualNarrativeRepository.narrativeCount()`. Tests: `SealedBackupRestoreTests` (2). |
| **WI-6** | ✅ Done | Replaced the `JSONEncoder(.sortedKeys)` signing encoder with `CanonicalSignatureSerializer` — a positional, length-prefixed binary format (fixed big-endian ints, whole-second dates, byte-lexicographic map order) reproducible byte-for-byte off-Apple. Compatibility-safe: envelopes bump to `currentSchemaVersion = 2` (signed v2; `verify` accepts BOTH v1-legacy + v2); admission tokens (no version field) dual-verify new-or-legacy bytes. Legacy `.sortedKeys`/`.iso8601` encoder retained for in-field-peer verify only. Tests: `FernletIdentityEnvelopeTests` (8 new — golden vectors envelope+token, map-order independence, sign/verify-new round-trip, dual-verify legacy+new ×2, tamper-reject ×2). Verified: 33 envelope + 94 proximity/mesh + S3BoundaryTests pass; wall-check exit 0; wall-selftest passes. |
| **WI-7** | ✅ Done | **7a:** `FernletLockCrypto` narrowed `public`→internal (`@testable` for its two test files). **7b:** added `TierTwoMemoryRecord` to the `S3BoundaryTests` grep-wall forbidden tokens with a per-file *sanctioned-gate exemption* (`sanctionedGateExemptions["MemoryAgent.swift"] = ["TierTwoMemoryRecord"]`). Verified the only grep-wall-covered file naming the raw type is the `MemoryAgent` de-id gate itself (`AIContextPayload`/`LaunchPreparationService` and the other floor/AI-facing files do **not** name it — `LaunchPreparationService` passes `store.tierTwoMemories` + the de-identified String), so the exemption keeps the gate green while any NEW AI-facing builder reaching a raw `[TierTwoMemoryRecord]` is flagged. The token-scoped exemption can't be used to smuggle a different sealed-store token (e.g. `import PrivateHealthStore` still trips on `MemoryAgent`). No `public→package` narrowing: the walled consumers are *inside* the `FernletKit` package, so `package` gives zero wall benefit and `internal` breaks the legit in-package readers (MemoryAgent, TierTwoMemoryEngine, repositories) + the app. Test: `S3BoundaryTests.tierTwoMemoryRecordTokenIsGatedToMemoryAgentOnly`. |
| **WI-8** | ✅ Done | `FriendSessionTrustPolicy` revoked/blocked-rejection test added. |
| **WI-9** | ✅ Done | Marked the ProximityKit wire `Codable` value types, the WI-6 canonical signing serializer, and the pure `IdentityService` crypto statics (`verify`/`fingerprint`/`fingerprintsMatch`) `nonisolated` (+ `Sendable` on the wire types) — so untrusted MCSession bytes decode + signature-verify off the main actor without relying on `.v5` leniency. `verify`/`signed` that touch the `@MainActor` IdentityService/ReplayCache pinned `@MainActor`; `MeshAdmissionToken.verify` (pure) is `nonisolated`. **`.v5` deliberately KEPT:** with the annotations in place a Swift-6 build of ProximityKit reduces to EXACTLY two remaining errors, both in `Ranging/NIRangingSession.swift` (`:87` sending `[NINearbyObject]`, `:98` sending `NISession` across the delegate→`Task{@MainActor}` hop) — the sole `.v5` blocker, documented in `Package.swift` with the clean-fix sketch. Dropping `.v5` needs only those two UWB-delegate bodies reworked; left as a focused follow-up (the UWB hardware-callback path can't be exercised in the simulator). Tests: `ProximityWireOffMainDecodeTests` (5 — compile-time `Sendable` guard + off-main decode/verify of envelope & token, positive + tamper). Verified: Swift-6 re-probe shows only the 2 NIRangingSession errors; `.v5` clean build green; WI-9 + WI-6 + 12 proximity/mesh suites + `S3BoundaryTests` pass; wall-check exit 0; wall-selftest passes. |
| **WI-10** | ✅ Done | DiaryStore `hooksRewired` assert + `commitResolution` persists created recipes even with no meals. Test: `CommitResolutionPersistenceTests`. |
| **WI-Q** | ✅ Resolved | Done: `goodProteinThreshold` single-sourced on `Macros`; `removePlannedWorkout` delegates to `deletePlannedWorkout`; `setSleep` implicit-today now delegates to the explicit-date overload (operation-for-equivalent via `mutateDay(date: todayKey)`). Remaining four examined and **left as-is by design** (each would change behavior or is already deduped — see WI-Q detail): scoring-input marshalling is *intentionally divergent* (facade injects derived-signal `nutrientGaps`, per-day path omits them → unifying alters live + persisted scores); `mutateDay` is already a thin facade delegator and collapsing `batchSnapshotPersistence` only adds a weak-closure hop + wider assert on a hot save path; the `CoreDataHealthKitCacheCleaner` fold would *regress* WI-2 (repo scopes to the "primary" record, has save-latches, per-day rebuilds → biases toward clearing too little on the opt-out path); `upsertWorkout` is a `WorkoutSyncContext` protocol seam called cross-module by `reconcileWorkouts`, not a removable facade duplicate. |

---

## 2. Work items

### WI-1 — [P0/HIGH] Past-day journal text leaks plaintext into the iCloud blob

**Problem (verified end-to-end).** Adding or editing a journal on a **past** calendar day writes the raw
journal `text` into the iCloud-synced CoreData blob in cleartext. Reachable through normal UI (calendar →
`DayDetailView`/`DayEditSheet` → `JournalView.swift:1357` / `:385` / `:61`).

**The exact path:**
- `Fernlet/FernletStore.swift:911 addJournal(text:tag:date:)` builds `JournalEntry(text:tag:)`, calls
  `journalSealingCoordinator.seal(entry, dayKey: date)` (seals text into the encrypted narrative store and
  adds the id to `sealedJournalIDs`, but **does not blank the in-memory entry**), then
  `diary.mutateDay(date: date) { $0.journals.append(entry) }`.
- `updateJournal` (`:926`) is the same shape (`targetDay.journals[index] = updatedEntry` with plaintext).
- For `date == todayKey`: the in-memory `day` keeps plaintext for display; the strip happens later in
  `currentSnapshot()` → `FernletSnapshot.forStorage(..., sealedJournalIDs:)` (`FernletStore.swift:1297`,
  `FernletSnapshot.swift:95`), which blanks sealed-journal text before persistence. **Safe.**
- For `date != todayKey`: `DiaryStore.mutateDay` (`DiaryStore.swift:787`) routes to `mutatePastDay`
  (`:797`) → `repository.updateDay(targetDay,…)`. **Both** `CoreDataFernletRepository.updateDay`
  (`CloudKitSync/CoreDataFernletRepository.swift:115`) and `LocalFernletRepository.updateDay`
  (`LocalPersistence/LocalFernletRepository.swift:115`) just do `database.days[dateKey] = day;
  saveDatabase(database)` with **no strip**. `saveDatabase` JSON-encodes the full day into
  `FernletDatabaseRecord.payloadData`, which is the `NSPersistentCloudKitContainer`-mirrored blob
  (`CloudKitSync/Persistence.swift:150,182,342`) and is **not otherwise encrypted**. → plaintext to iCloud.

**Why `forStorage` doesn't catch it:** `forStorage` is only invoked on the *snapshot* path
(`currentSnapshot` → `scheduleSnapshotSave`), which only ever re-strips `days[todayKey]` + `previousJournals`.
The `days[pastKey]` entry written by `updateDay` is never run back through it.

**Note:** this is **not a carve-up regression** — pre-carve-up `updateDay`/`mutatePastDay` behaved identically
(`git show 9b176de:Fernlet/CoreDataFernletRepository.swift`). The move faithfully preserved both the strip
logic and this hole. Fix it anyway: it defeats the core "sealed text never reaches iCloud" promise.

**Recommended fix (surgical, mirrors existing logic — lowest risk):**
Strip at the facade write sites, because that is the only layer that holds both the entry and the sealing
state (`journalSealingCoordinator.sealedJournalIDs`). `DiaryStore`/the repositories are portable layers
below the wall and do **not** know which entries are sealed.

1. Add a helper in `Fernlet/FernletStore.swift`:
   ```swift
   /// A journal entry safe to persist into the days blob. Mirrors FernletSnapshot.forStorage:
   /// a sealed entry's text lives in the encrypted narrative store and must never enter the blob.
   /// Today's in-memory copy keeps plaintext for display (forStorage strips it at snapshot time);
   /// past days persist straight through updateDay with NO forStorage pass, so strip here. Past-day
   /// display re-hydrates via loadDayWithDecryptedJournals → hydratingDecryptedJournals.
   private func journalEntryForPersistedDay(_ entry: JournalEntry, date: String) -> JournalEntry {
       guard date != todayKey, journalSealingCoordinator.isSealed(entry.id) else { return entry }
       return JournalEntry(id: entry.id, text: "", tag: entry.tag, date: entry.date, emotions: [])
   }
   ```
2. In `addJournal`, append `journalEntryForPersistedDay(entry, date: date)` instead of `entry`.
3. In `updateJournal`, assign `targetDay.journals[index] = journalEntryForPersistedDay(updatedEntry, date: date)`.
   (`seal`/`updateSealedNarrative` already ran, so the text is in the sealed store before it's blanked.)

   - Keep the `previousJournals` in-memory updates as-is — they are stripped by `forStorage` on the next
     snapshot save. Only the `days[pastKey]` write needed the fix.
   - **Decision point — edit-while-locked:** `updateSealedNarrative` is a no-op when the lock is locked
     (no active key). Confirm whether the edit UI is reachable while locked (it likely isn't — locked
     journal text is scrubbed/undisplayed). If it *is* reachable, gate the strip so you never blank an
     entry whose new text failed to re-seal (mirror the "no data loss" priority in `seal()`'s catch at
     `JournalSealingCoordinator.swift:109-119`).

**One-time migration for already-leaked history (required).** Past-day plaintext already written before this
fix persists in `database.days[pastKey]` and is never re-stripped (the existing
`migrateExistingJournalsToSealedStore` only scans `previousJournals` + today). Add a one-time scrub, gated by
a preference flag (e.g. `pastDayJournalScrubVersion`), run from `activateNoLockJournals` /
`activateSealedJournals` where a key is available:
- `repository.loadAllDays()`; for each day, for each journal with non-empty text: ensure it's sealed (insert
  into `JournalNarrativeRepository` + add to `sealedJournalIDs`, reusing the existing seal logic), blank the
  text, then `repository.updateDay(strippedDay,…)`.
- Be mindful of volume — it's a single pass, gated to run once.

**Alternative (defense-in-depth, more invasive — optional):** thread a `sealedJournalIDs` provider closure
into `DiaryStore` (it already uses the injected-closure pattern for `scheduleSnapshotSave`/`periodAdjustment`)
and strip inside `mutatePastDay` before `updateDay`. This guarantees *every* past-day write path is covered,
not just the two journal sites. Heavier; the surgical fix already closes the only known sensitive-text vectors.

**Tests (`FernletTests`):**
- Add a journal on a past date with sync semantics; assert the persisted `payloadData` (decode the
  `FernletDatabaseRecord`/`LocalFernletDatabase`) has empty journal `text` for that day, and that the sealed
  `JournalNarrativeRepository` holds the ciphertext.
- Edit a past-date journal; same assertion.
- Migration test: seed a DB with a plaintext past-day journal, run the scrub, assert blanked-in-blob +
  sealed-in-store + hydratable via `loadDayWithDecryptedJournals`.

---

### WI-2 — [P1/MED] HealthKit cache-clearer silently no-ops

**Problem.** `FernletKit/Sources/HealthKitGateway/HealthKitService.swift:301`:
```swift
public static var defaultCacheClearer: HealthKitCacheClearing = NoopHealthKitCacheClearer()
```
The concrete `CoreDataHealthKitCacheCleaner` lives in the app (it needs `CloudKitSync` + `LocalPersistence`,
which the gateway module must not depend on), so the app installs the real clearer at
`Fernlet/FernletApp.swift:26`. `init` (`:319`) captures `cacheCleaner ?? Self.defaultCacheClearer` **at
construction time**. Any `HealthKitService()` built before `FernletApp.init` (a `#Preview`, a unit test, the
share extension, or a future early-launch path) captures the no-op; `disableIntegration()` (`:716`) then
calls `try cacheCleaner.clearHealthKitCachedValues()` (`:728`) which is `{}` (`:242`) — so the purge of
cached HealthKit-derived clinical values silently doesn't run, leaving opted-out clinical data in the
local/synced store. The current shipping launch path is correctly ordered, but the invariant rests on global
mutable state + construction order. **This seam is carve-up-introduced.**

**Recommended fix (fail-closed):** make the absence of a real clearer a hard, audited failure instead of a
silent skip.
- Change the default to express "not installed": `public static var defaultCacheClearer: HealthKitCacheClearing? = nil`
  and store `cacheCleaner: HealthKitCacheClearing?`.
- In `disableIntegration()`, `guard let cacheCleaner else { FernletAuditLog.log("healthkit.disable.failed",
  context: ["error": "cache clearer not installed"]); throw HealthKitError.cacheClearerUnavailable }` before
  the rest of the teardown (so disable cannot "succeed" without clearing).
- Keep `NoopHealthKitCacheClearer` for explicit injection in tests where clearing genuinely isn't needed.
- (Optional belt-and-suspenders: `assertionFailure` in a debug-only no-op path so a real invocation is caught
  in dev/test.)

**Decision point:** confirm `FernletApp.swift:26` runs before *every* production `HealthKitService`
construction (it does for the main app). The fail-closed throw makes any future violation loud instead of silent.

**Test:** construct a `HealthKitService` with no clearer installed, call `disableIntegration()`, assert it
throws and audit-logs; with a mock clearer, assert `clearHealthKitCachedValues()` is invoked exactly once.

---

### WI-3 — [P1/MED] Enforce the wall flag in CI / a pre-push hook

**Problem.** `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` (what turns a forbidden cross-wall import into
a hard error) is applied **only** by the manually-run `Scripts/spm-wall-check.sh`. There is no `.github` CI,
no git hook, and no build phase running it; the documented everyday commands omit it. The flag also does
**not** propagate from the pbxproj to the synthesized SwiftPM targets (so baking it into xcconfig is *not*
reliable — per `Scripts/spm-wall-check.sh:21-27`, it must be on the build *command*). The wall is intact at
HEAD but operationally advisory: a future `import PrivateHealthStore` in a walled module would compile green.

**Recommended fix:**
- Add `.github/workflows/s3-wall.yml` running `Scripts/spm-wall-check.sh` on push/PR, and make it a required
  status check. **Caveat:** this needs a macOS runner with Xcode 26.5 + iOS 26 simulator — verify
  GitHub-hosted runner availability; if not yet available, use a self-hosted runner.
- As an always-available complement (no CI dependency), add a git **pre-push hook** that runs the script, and
  document the wall check in `CLAUDE.md` as part of the pre-merge ritual.
- Validate the enforcement itself with the negative-test technique in §0 (inject a forbidden import → expect
  exit 65 → revert). Consider committing a tiny "enforcement self-test" script that does this automatically.

---

### WI-4 — [P1/MED] Make the grep-wall complete

**Problem.** `FernletTests/S3BoundaryTests.swift` is the *only* possible backstop for the AI prompt-builders
that live in the app target (outside the package, so the compiler wall can't reach them). It is incomplete:
- `aiFacingFiles` (`:6-12`) lists 5 files but omits `Fernlet/FoundationDishDecomposition.swift` and
  `Fernlet/FoodProductWebImporter.swift` — both build real `LanguageModelSession` prompts and are
  app-resident. `Package.swift:181-183` even *claims* these are grep-covered (they aren't).
- `forbiddenPrivateStoreTokens` (`:14-22`) lists 7 plumbing names but omits the sensitive value types
  (`CyclePhase`, `CycleDayEntry`, `UserLoggedCycleEvent`, `PeriodTrackerStore`, `PrivateMediaStore`,
  `MealPhotoStore`, `PendingNarrativeBuffer`/`PendingNarrativePayload`) and any bare `import Private*`.
- `locate()` fail-soft: a renamed/moved listed file yields `Issue.record` + `continue` rather than scanning
  its successor.

**Recommended fix:**
- Replace the hardcoded `aiFacingFiles` with **dynamic discovery**: enumerate `./Fernlet/**/*.swift` plus
  `FernletKit/Sources/{AIProviders,AIContext}/**/*.swift`, and include any file referencing
  `LanguageModelSession` / `SystemLanguageModel` / `@Generable` / `import FoundationModels`. New AI call
  sites are then auto-covered. Keep the two named files as an explicit floor.
- Expand `forbiddenPrivateStoreTokens` with the types above. **Highest-value single addition:** the four
  `import PrivateHealthStore` / `import PrivateMemoryStore` / `import PrivateMediaStore` /
  `import PrivateStoreCore` statements — that fails any direct reach into a sealed module regardless of which
  type is named.
- Make a missing expected file a hard test failure (not fail-soft).
- Correct the misleading comment at `Package.swift:181-183`.

**Test:** the suite itself is the test; add a fixture asserting a planted forbidden token in a temp AI-facing
file would be caught (or at least assert the discovery set is non-empty and includes the two named files).

---

### WI-5 — [P1/MED] Period-restore no-clobber guard ignores the narrative store

**Problem.** `Fernlet/SealedBackupCoordinator.swift`: `isEmptyStoreForRestore(.periodData)` (`:224-230`)
returns true whenever `isFreshInstallForRestore()` (`:234-241`) is true, but the latter inspects only
day/journal/meal/memory content — never `narrativeRepository.narrativeCount()`. Period narratives live in the
separate `PrivateHealthStore` and are written independently (`PeriodTrackerStore.logEvent`), so a device can
hold N sealed narratives while still looking "fresh". `applyRestoredChunks(.periodData)` (`:203-217`) then
`insert`s with no upsert, and restore runs every launch → duplicated (re-duplicated) sealed cycle/intimacy
history. (The `.sensitiveNotes` branch is correctly guarded; `.periodData` is not.) This is a
**data-integrity** defect, not a confidentiality leak (the data stays sealed).

**Recommended fix:** gate `.periodData` on the narrative store itself, e.g.
`case .periodData: return (try? MenstrualNarrativeRepository().narrativeCount()) == 0` (a cheap count, no
decryption) — **or** make `narrativeRepository.insert` an idempotent upsert keyed on `hkExternalUUID`/`dateKey`
so re-restore is a no-op.

**Test:** seed sealed narratives, run `restoreSealedBackupsIfNeeded` twice, assert `narrativeCount` does not
grow.

---

### WI-6 — [P2/MED, roadmap] Replace the cross-platform canonical signing encoder

**Problem.** `FernletKit/Sources/ProximityKit/Wire/FernletIdentityEnvelope.swift:62`
`makeCanonicalSignatureEncoder()` returns a Foundation `JSONEncoder` with `.sortedKeys,
.withoutEscapingSlashes` (and `.iso8601` dates). `.sortedKeys` is stable *within* one Foundation version, but
Apple sorts by UTF-16 code units and does not guarantee byte-identical number/string encoding across
Foundation implementations. A peer on a different Foundation version — or the **planned Android port** —
could produce different canonical bytes → `signatureInvalid` for legitimately-signed envelopes/admission
tokens. **Not a carve-up regression** (preserved as-is), but a known load-bearing fix before any cross-stack
signatures (see memory `cross-platform-direction-2026-06`).

**Recommended fix (do deliberately, not casually):** replace with a deterministic canonical serializer you
control on both stacks — explicit field ordering, fixed numeric formatting (no locale/precision drift),
explicit string escaping, explicit date format. **Compatibility:** changing the encoder changes the signed
bytes, so it must be gated behind a `schemaVersion` bump (envelopes already carry `schemaVersion`; verify
both old and new during a transition) to avoid breaking existing Apple-to-Apple signatures. No live
cross-platform peers exist today, so this is not urgent — but it must precede the Android port. Used by both
`FernletIdentityEnvelope` (`:74`) and `MeshAdmissionToken` (`MeshPayloads.swift:299`).

**Implemented (2026-06-27).** New file `FernletKit/Sources/ProximityKit/Wire/CanonicalSignatureSerializer.swift`
holds `CanonicalByteWriter` + `canonicalBytes(for:)` (v2) + `legacyCanonicalBytes(for:)` + the retained
legacy Foundation encoder. The v2 format is documented in that file's header (the byte layout an Android
implementer reproduces). Deliberate decisions, recorded here so they are conscious choices:
- **Binary, not canonical-JSON.** A positional length-prefixed binary stream eliminates the JSON
  string-escaping / number-formatting / key-ordering edge cases that are the root of the drift. Ed25519
  signs arbitrary bytes, so JSON-ness was never required.
- **Whole-second dates.** Matches the legacy `.iso8601` precision AND the wire — envelopes transit as JSON
  and `verify` re-derives canonical bytes from the *decoded* date, so the canonical granularity must be no
  finer than what survives transport. The seconds→Int64 conversion saturates (never traps) because `verify`
  runs over untrusted bytes.
- **Map order** is byte-lexicographic on the key's raw UTF-8 (not Foundation's UTF-16 `.sortedKeys`).
- **Rollout tradeoff (accepted):** signing flips to v2 immediately (`currentSchemaVersion`, a one-line flip
  point). Updated devices keep verifying v1 (no in-field peer is cut off — the WI-6 priority). The reverse —
  a not-yet-updated v1-only device verifying a v2 envelope — fails `schemaVersionUnsupported` until it
  updates. Acceptable: proximity sessions are ephemeral and co-present, peers are typically on the same app
  era, this is pre-release, and there are no cross-platform peers yet. If a phased rollout is ever wanted,
  set `currentSchemaVersion = 1` for a release (verify already accepts both) then flip to 2 later.
- **Golden vectors** in `FernletIdentityEnvelopeTests` (`goldenEnvelopeHex`/`goldenTokenHex`) are the
  cross-stack contract the Android port must reproduce byte-for-byte.

---

### WI-7 — [P2/LOW] Narrow over-broad public API surface

**Problem (defense-in-depth, no live leak).** The carve-up widened visibility past least-privilege in two
spots reachable from the shared layer:
- `FernletKit/Sources/FernletDomainModel/TierTwoMemoryRecord.swift:13` exposes `public var text/state/
  evidence`. `FernletDomainModel` is a direct dep of both walled consumers, so the `MemoryAgent.filteredContext`
  de-identification gate is enforced by convention, not the type system. (No leak today: the only memory→AI
  path, `LaunchPreparationService.swift:295`, routes through `MemoryAgent`.)
- `FernletKit/Sources/FernletLock/FernletLockService.swift:123` widened `FernletLockCrypto`
  key-wrapping/derivation primitives `internal`→`public` with no app-target callers.

**Recommended fix:** for the lock crypto, narrow back to `package`/`internal` (use `@testable` for tests);
**keep `contentKey()` public** (it has a real caller). For `TierTwoMemoryRecord`, prefer a filtered boundary
projection exposed to AI rather than raw `.text`; at minimum add `TierTwoMemoryRecord`/`.text` to the
grep-wall tokens (WI-4), scoped so legitimate non-AI uses don't false-positive. Verify "no callers" with a
build under enforcement after narrowing.

**Resolution (done).** *7a* — `FernletLockCrypto` narrowed `public`→`internal` (`@testable` for its two test
files); `contentKey()` kept public.

*7b* — implemented as the **grep-wall token + scoped exemption**, not a visibility narrow. The filtered
boundary projection the plan prefers **already exists and is already the only path used**:
`MemoryAgent.filteredContext(from:destinedFor:…)` returns a recency/confidence/diagnostic-filtered,
char-capped **String**, and the sole memory→AI site (`LaunchPreparationService.swift:295`) consumes only that
String. The remaining gap was purely structural — nothing *stopped* a future AI-facing builder from reaching a
raw `[TierTwoMemoryRecord]` and reading `.text` itself. A type-system narrow can't close it: both walled
consumers (`AIProviders`, `CloudKitSync`) are **inside** the `FernletKit` package, so `package` access is
visible to them (zero wall benefit) and `internal`-to-`FernletDomainModel` would break every legitimate
in-package reader (`MemoryAgent` in AIContext, `TierTwoMemoryEngine` in LocalPersistence, the repositories) plus
the app target. So the grep-wall is the correct mechanism. Changes (test-only, no app/library code):
- Added `"TierTwoMemoryRecord"` to `S3BoundaryTests.forbiddenPrivateStoreTokens`.
- Added `sanctionedGateExemptions: [String: Set<String>] = ["MemoryAgent.swift": ["TierTwoMemoryRecord"]]` and
  applied it in the scan loop — the gate may name the raw type it gates on; **every other** forbidden token
  still applies to it (it still can't `import PrivateHealthStore`).
- Empirically verified the *only* grep-wall-covered file naming the raw type is `MemoryAgent.swift`
  (`AIContextPayload`/`AIAuditLog`/`FoundationFoodSelection`/`LaunchPreparationService`/`FoundationDishDecomposition`/`FoodProductWebImporter`
  and the AIProviders module do **not** name it). `tierTwoMemories` (the accessor) was deliberately **not**
  tokenized — it would false-positive on the sanctioned `LaunchPreparationService` caller. `.text` was not
  tokenized either (far too noisy — SwiftUI `.text`, etc.).
- New test `S3BoundaryTests.tierTwoMemoryRecordTokenIsGatedToMemoryAgentOnly` pins all four properties: the
  matcher flags the raw type, the gate exemption clears it for `MemoryAgent` only, any other file is still
  flagged, and the exemption can't smuggle a different sealed-store token.

---

### WI-8 — [P2/LOW] Pin `FriendSessionTrustPolicy` blanket-trust with a test

**Problem.** `FernletKit/Sources/ProximityKit/Trust/FriendSessionTrustPolicy.swift:20`
`isTrustedProximityPeer(...) -> Bool { true }`. This is **by design** (friend sessions authorize via the
proximity gate; remembered trust isn't required) and is safely bounded — `isRevoked`/`isBlocked` are still
forwarded to the vault (`:11-17`), so revoked/blocked keys are rejected. The risk is a future refactor
silently dropping the gate and leaving blanket trust.

**Recommended fix:** add a unit test asserting a revoked key and a blocked key are rejected by
`FriendSessionTrustPolicy` even though `isTrustedProximityPeer` returns true. Optionally collapse the
3-method pass-through into a vault flag/closure to shrink the maintained surface.

---

### WI-9 — [P2/LOW] ProximityKit `MainActor` isolation forces off-main decode under `.v5`

**Problem.** `FernletKit/Package.swift:299` sets `.defaultIsolation(MainActor.self)` for `ProximityKit`,
making the moved mesh `Codable` conformances and `sign`/`verify` free functions `MainActor`-isolated; this
only compiles because of `.swiftLanguageMode(.v5)`. Off-main decode of incoming `MCSession` data (untrusted
bytes) compiles with a warning today; a Swift 6 / strict-concurrency migration would fail.

**Recommended fix (incremental):** mark the wire `Codable` conformances and the
`sign`/`verify`/`makeCanonicalSignatureEncoder` free functions `nonisolated`, working toward dropping the
`.v5` escape hatch for this target. Scope deliberately — it's a concurrency-correctness cleanup, not a live
hole.

**Implemented (2026-06-27).** Annotations landed; `.v5` deliberately retained (the plan's "leave a note on
what still blocks it" outcome). Empirical scoping drove the decisions — recorded here so they are conscious
choices:
- **The wire layer is now `nonisolated, Sendable`.** Every ProximityKit wire `Codable` value type
  (`FernletIdentityEnvelope`; all `MeshPayloads.swift` types incl. `MeshAdmissionToken`;
  `RecipeSharePayloads.swift` types; the two private mesh-plaintext payloads `IdentityRangingPayload`/
  `SessionHeartbeatPayload`) is `nonisolated, Sendable`, matching the existing FernletDomainModel wire
  precedent (`PayloadType`/`PayloadSummary`). The `FernletDomainModel` wire types decoded from peer bytes
  gained `Sendable` so the whole peer-wire surface is uniform: `SharedRecipePayload`/`SharedRecipeIngredient`
  (so the recipe payloads can be `Sendable`) and the friend-photo family (`FriendPhotoPayload`,
  `FriendPhotoManifestPayload`, `FriendPhotoRequestPayload`, `FriendPhotoSessionMetadata`,
  `FriendPhotoSessionParticipant`, `FriendPhotoManifestEntry`). All are pure value types — sound and free.
  (FernletDomainModel has no `.defaultIsolation(MainActor.self)`, so these need only `Sendable`, not
  `nonisolated`.)
- **The signing path is `nonisolated`.** `CanonicalSignatureSerializer.swift` in full (the WI-6
  `canonicalBytes`/`legacyCanonicalBytes`, `CanonicalByteWriter`, `canonicalUTF8Ordered`, the domain-tag
  constants, `makeLegacyCanonicalSignatureEncoder`) plus the pure `IdentityService` statics
  `verify`/`fingerprint`/`fingerprintsMatch`. This is what lets a signature be verified off the main actor.
- **Isolation split on the verify/sign methods.** `FernletIdentityEnvelope.verify`/`.signed` and
  `MeshAdmissionToken.signed` are pinned `@MainActor` (they read `@MainActor` `IdentityService` private-key
  state / `@MainActor` `ReplayCache`) — behavior-identical to before. `MeshAdmissionToken.verify` is
  `nonisolated` because it is pure signature math (static crypto + `canonicalBytes`), so a token verifies
  off-main.
- **`.v5` kept — sole remaining blocker isolated (accepted).** With these annotations, building ProximityKit
  WITHOUT `.v5` (i.e. Swift-6 language mode; tools-version is 6.2) reduces to EXACTLY two errors, both in
  `Ranging/NIRangingSession.swift`: `:87` `sending 'nearbyObjects'` (the `[NINearbyObject]` delegate arg)
  and `:98` `sending 'session'` (the `NISession`, for the `=== niSession` identity check) — both captured
  into the `nonisolated`-delegate→`Task { @MainActor }` hop. The wire/serializer/crypto surface itself is
  Swift-6 clean. Dropping `.v5` therefore needs ONLY those two UWB-delegate bodies reworked to extract the
  Sendable values (`distance`/`direction`; `ObjectIdentifier(session)`) BEFORE the hop. Left as a focused
  follow-up rather than bundled here: it touches the NearbyInteraction hardware-callback path, which the
  simulator cannot exercise, and `HealthKitGateway` independently uses the same `.v5` stance. The blocker +
  fix sketch is documented inline in `Package.swift`.
- **Tests.** `ProximityWireOffMainDecodeTests` (5): a compile-time `T: Sendable` guard over the wire types
  (hard-fails in any language mode on regression) + four runtime tests that decode and signature-verify a
  `FernletIdentityEnvelope` and a `MeshAdmissionToken` inside `Task.detached` (genuinely off-main),
  positive + tamper-reject. Under Swift-6/CI these would also fail to compile if the annotations regressed.

---

### WI-10 — [P2/LOW] Robustness / data-integrity

- **DiaryStore rewire-hook can silently no-op saves** — `FernletKit/Sources/DiaryStore/DiaryStore.swift:69`.
  `DiaryStore` is built with a `{ }` `scheduleSnapshotSave` then `rewireHooks` re-points the mutable hook
  after construction. A future constructor copying the pattern but omitting the rewire drops every save
  silently. **Fix:** make the persistence hook a required init parameter, or assert it's been rewired before
  the first mutation.
- **`commitResolution` can lose a created recipe** — `Fernlet/FernletStore.swift:500`. Inserts
  `createdRecipes` via raw `diary.recipes.insert` with no `scheduleSnapshotSave`, relying on a subsequent
  `appendMeal` to persist; a resolution with recipes but no meals loses the recipe on next reload
  (pre-existing/latent). **Fix:** `scheduleSnapshotSave()` after the insert (or route through a persisting
  method).

---

### WI-Q — [P3] Quality / duplication cluster (non-security; optional)

Real maintenance hazards, no wall/security impact. **Disposition after item-by-item equivalence analysis**
(line numbers below are the original plan's; the cluster was re-located against current HEAD):
- ✅ **Done** — `goodProteinThreshold = 25` copied 4× (`DiaryStore.swift:43` + MealBuilder + facade + a FoodView
  literal) → single source of truth on `Macros.goodProteinThreshold`.
- ✅ **Done** — Two `setSleep` overloads duplicated construction/trimming (`DiaryStore.swift:470`). The
  implicit-today overload now delegates to the explicit-date one: `setSleep(…, date: todayKey)`. Equivalent
  because `mutateDay(date: todayKey)` takes the today-key branch (`day.sleep = …; scheduleSnapshotSave()`) —
  operation-for-operation identical to the old inline body, same trim, same single save. (A `date = todayKey`
  default param is impossible: Swift default-arg expressions can't reference `self`.)
- ✅ **Done** — `removePlannedWorkout` byte-identical to `deletePlannedWorkout` → delegates.
- ⛔ **Left as-is (would change behavior)** — Scoring-input marshalling in two modules
  (`DiaryStore.scoreBreakdown(for:)` vs the facade live-`score` path). **Not** true duplication: the facade path
  passes `nutrientGaps: dedupedNutrientGaps(from: derivedSignals…)`; the per-day path deliberately omits them
  (defaults `[]`). `computeBreakdown` applies a `micronutrientModifier` from those gaps (up to ±~0.05 on the meal
  sub-score). Any single builder forces one side to gain/lose the modifier → changes the **live home-screen
  score** or the **persisted `DailyHealthScore`** history. Divergence is intentional and documented at
  `DiaryStore.swift` (the live `score`/`companionState` stay facade-side because they read `derivedSignals`,
  owned by the facade's snapshot-wired `DerivedSignalsService`). No security value; do not unify.
- ⛔ **Left as-is (already deduped / net-negative)** — `batchSnapshotPersistence`/`mutateDay`. `mutateDay` is
  *already* a one-line facade delegator to the single body in `DiaryStore` — nothing to collapse. The
  `batchSnapshotPersistence` pair is a deliberate 4-line facade seam (direct `snapshotSaveCoordinator.schedule()`
  vs the DiaryStore copy's `scheduleSnapshotSaveHook` weak-closure hop + `hooksRewired` assert); collapsing it
  saves ~3 lines while adding a weak hop + wider assert surface on a hot save path, for zero gain.
- ⛔ **Left as-is (would regress WI-2)** — `CoreDataHealthKitCacheCleaner` load/mutate/save loop. Folding onto
  `CoreDataFernletRepository.loadAllDays`/`updateDay` is **not** equivalence-safe on the fail-closed clearing
  path: the repo routes through `fetchRecordResult` (scopes to `recordID == "primary"`, **deletes** rather than
  scrubs duplicates), enforces read-only save-latches that would silently refuse the purge (and the cleaner
  ignores the `Bool`), runs per-day `rebuildDerivedTables` (re-runs inference N× + bumps `updatedAt`), and is
  store-selection-dependent. Each biases toward clearing **too little** of opted-out clinical data — the exact
  property WI-2 depends on. (The codec premise is moot: the cleaner's `JSONEncoder([.sortedKeys], .iso8601)` is
  already byte-identical to the repo's; only the codec *factory* is safely shareable and it's low-value.) The
  cleaner's all-records, latch-free, single-store, single-rebuild scrub is the correctness behavior — leave it.
- ⛔ **Left as-is (premise stale)** — `upsertWorkout` is **not** a redundant facade entry point: it's a
  `WorkoutSyncContext` protocol requirement (`HealthKitGateway/WorkoutHealthKitSync.swift:12`), implemented at
  `FernletStore.swift` and called only by `reconcileWorkouts` across the module wall — which **cannot** reach
  the app-target `addWorkout`. It also routes to the pure `diary.appendWorkout` *without depending on*
  `addWorkout`'s nil-UUID guard (NOTE J), a stronger guarantee than the guard. Removing/repointing it is a
  compile break + a behavior change. Leave as-is.

---

## 3. Final verification checklist (run before declaring done)

1. `Scripts/spm-wall-check.sh` → exit 0 (wall still honest after changes).
2. Wall negative test (inject forbidden import → exit 65 → revert) — especially after WI-3/WI-4/WI-7.
3. New regression tests pass: WI-1 (past-day journal strip + migration), WI-2 (disable fail-closed), WI-5
   (no duplicate narratives), WI-8 (revoked/blocked rejected).
4. `S3BoundaryTests` passes and now discovers `FoundationDishDecomposition` + `FoodProductWebImporter`.
5. Targeted `FernletTests` suites green (batch the runs; lock suite is slow).
6. Confirm WI-1 didn't break journal display: today entries still show immediately; past-day entries still
   hydrate via `loadDayWithDecryptedJournals`.

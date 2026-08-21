# Next round — working prompt (2026-08-20)

Everything below the line is a self-contained prompt. Paste it into a fresh session. It assumes
nothing from the conversation that produced it; every claim carries a `path:line` anchor that was
true on 2026-08-20 and should be re-grepped rather than trusted.

Scope: **four cheap defect fixes, two features whose infrastructure is already finished, the
CODEOWNERS repair, and delete-everything coverage.** Backlog context is in
[`RemainingWork-2026-08-20.md`](RemainingWork-2026-08-20.md).

Part 4 was added after a dedicated audit and is the one part that touches a *published* promise —
read its opening before deciding what order to work in.

---

Work on Fernlet at `/Users/michaelbowman/Desktop/Fernlet 5-18/Fernlet`. Read `CLAUDE.md` first —
the walls it describes (S3, no-tracking, Power-of-10, localization) are enforced by CI and by
zero-violation scanners, and they are not negotiable.

Branch off `main` (currently at the localization Phase 1 merge). Line numbers below WILL have
drifted — grep for the code, don't seek to the line.

## Ground rules

- **Verify before fixing.** Each item names its evidence. Confirm the defect still exists before
  changing anything; several items in the previous tracker turned out to be already fixed.
- **Run `Scripts/power-of-10-scan.py` and `Scripts/doc-coverage-scan.py` before every commit.**
  Both have a zero baseline. New types need `///` doc comments; no function or SwiftUI `body` over
  60 lines; no force unwraps, `try!`, `as!`, or `fatalError`.
- **A `String` parameter silently opts a call site out of localization.** Display text is
  `LocalizedStringKey`; inside an SPM module, `String(localized:)` and `LocalizedStringKey` both
  resolve against `Bundle.main` unless `bundle: .module` is passed, and getting it wrong fails
  silently. `Tests/FernletTests/LocalizationBoundaryTests` enforces this.
- **Any change under `FernletKit/Sources/FernletDomainModel/` needs a CLEAN build before you trust
  a test run.** An incremental build after enum/struct changes there produces nonsense failures
  like *expected error ".malformedRecord" of type SealedBackupError, but ".malformedRecord" of
  type SealedBackupError was thrown instead*. That shape means stale artifacts, not a real bug.
- Test in batches, not one giant run: the full `FernletTests` suite is ~9 minutes. Check the exit
  code and the "Test run with N tests … passed" banner, not a naïve grep.
- Several sessions may share this working tree. If you see changes you didn't make, leave them
  alone and commit only your own hunks.

---

## Part 1 — Four cheap fixes

Each is hours, not days. Do them first; they are what an outside tester hits.

### 1.1 Disposable camera "Develop → Save selected" can never succeed

`App/Fernlet/DisposableCameraView.swift:1298` passes `manager.sessionPhotos.filter { … }` straight
to `FriendPhotoLibrarySaver.save`. But `MeshNetworkManager.swift:2917` stores
`cachedPhoto.withoutImageData()` into `sessionPhotos` — for own captures *and* peers' — so every
payload has `imageData == nil`. `FriendPhotoReviewSheet.swift:236` skips nil-imageData payloads and
`:249` throws `NothingSavedError`. And because `manager.finishSessionPhotos(keeping:)` runs only
after a successful save (`DisposableCameraView.swift:1301`), the throw also means **the photos are
never kept on the in-app wall**. This is the end-of-session flow of a flagship social feature.

Fix: wrap in `manager.hydratedPhotos(…)`, matching the two sibling call sites that do it correctly
(`App/Fernlet/ConnectView.swift:152` and `:868`; helper defined at
`FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift:2953`).

While you are here, take UI/UX finding FRND-12: the saver requests `PHPhotoLibrary` add-only
authorization *first* (`FriendPhotoReviewSheet.swift:225`) and throws `userCancelled` on denial, so
denying the Photos prompt currently also costs the user their in-app photos. Make **Keep** the
primary action and "Also save to Photos" secondary, so the two outcomes are independent.

**No test covers this path** (grep `saveSelected` / `NothingSavedError` in `Tests/` — nothing).
Add one.

### 1.2 Settings → Health tells every new user their device can't do Health

`App/Fernlet/SettingsSheet.swift:1122` renders
`EmptyState("Health data is not available on this device.", systemImage: "heart.slash")` whenever
`healthKit.snapshot.isAvailable` is false. That flag is **not** device capability:
`HealthKitService.swift:757` sets `isAvailable: isIntegrationEnabled`, and the doc comment at
`:230` says so outright. The master toggle defaults to **off**
(`FernletFoundation/StoragePreferences.swift:112`, decode fallback at `:159`) and lives on a
different screen entirely (`PrivacyDataSettingsView.swift:1638`).

So on every fresh install, the gateway screen for a headline feature states the wrong cause and
offers no way out.

Fix: split the branch. The service already exposes both facts separately —
`HKHealthStore.isHealthDataAvailable()` at `HealthKitService.swift:655` versus
`isIntegrationEnabled`. Device-unavailable keeps the current message; integration-off gets
"Health is switched off for Fernlet" plus an inline enable control or a link to Privacy & Data.

### 1.3 Recipe web-image decompression bomb

`FernletKit/Sources/PrivateMediaStore/MealPhotoStore.swift:337` guards only
`width <= maxSourcePixelDimension, height <= maxSourcePixelDimension` (20,000, at `:56`) with **no
area clause** — so a declared 20000×20000 (400 MP) image passes. A solid-colour PNG that size is a
few hundred KB on the wire and ~1.6 GB decoded.

The correct predicate already exists and is tested two files away:
`PrivateMediaStore.isWithinSafePixelBounds` (`PrivateMediaStore.swift:249`) enforces dimension
**and** `maxImagePixelCount = 24_000_000`. `MealPhotoStore` already calls it on the *restore* path
(`:183`) but not on `save` (`:105`, `:120`).

Reachable from a shared recipe link: `App/Fernlet/FernletStore.swift:4126`
(`fetchRecipeWebImageIfNeeded`) and `:4294` (share-extension import) feed page-declared `og:image`
bytes straight into `saveRecipePhoto(data:)`, and `RecipeWebImporter.downloadImage`
(`AIProviders/RecipeWebImporter.swift:460`) caps *bytes* only.

Fix: reuse the existing predicate at the two `save` sites. Add a test with a declared-huge,
small-on-disk image.

### 1.4 Ship iPhone-only

`App/Fernlet.xcodeproj/project.pbxproj:555` and `:612` set `TARGETED_DEVICE_FAMILY = "1,2,7"` on
the app target — iPad *and* visionOS — while `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`
(`:552`) and the whole app target contains exactly one mention of iPad (a comment in
`DisposableCameraView.swift:389`). `README.md:38` and `Site/index.html:46` both say "iPhone".

Fix: set `TARGETED_DEVICE_FAMILY = "1"` on all four targets (the widget and share extension are
currently `"1,2"`). Keeping family 2 commits you to 13" iPad screenshots in App Store Connect and
an App Review pass of an iPhone-only layout on an iPad — a routine Guideline 4.0 rejection.

**Verify by building**, and note that this is a project-file change: confirm nothing else in the
pbxproj moved.

---

## Part 2 — Two features whose infrastructure already exists

Both are cases of finished, tested code with no consumer. Neither needs new architecture.

### 2.1 Per-exercise progress — the highest-value unbuilt thing for a user

Fernlet ships a guided workout runner, a Live Activity, a plan approver and a logger, and cannot
answer **"what did I lift last time?"**

`App/Fernlet/TrainerExportBuilder.swift:587` (`rollUpExerciseHistory(days:)`) already computes, per
exercise: sessions, total sets, first/last logged, last sets/reps/weight, best weight, best-weight
reps, an Epley `estimatedOneRepMax`, and the weight unit (struct at `:308`). Its **only** production
caller is the trainer export at `:366`. Grep `estimatedOneRepMax` / `bestWeight` outside
`TrainerExportBuilder` and you find one prompt string and nothing in any view. Move's only history
surface is a week strip (`MoveView.swift:2677`).

Build it in two increments:

1. **A "last time" line in the exercise row editor** — e.g. `last time: 3×8 @ 135` — driven by the
   existing parser. Hours.
2. **A Move sub-screen** listing exercises by recency with last / best / frequency. Days.

The parse-and-rollup half is covered by `Tests/FernletTests/CoachPlanExchangeTests.swift:349` —
reuse it rather than re-deriving.

Design constraint worth honoring: spec §12 says ambient surfaces avoid charts and grades. Move is
not an ambient surface, and factual recall of what you lifted is not a score — but keep it factual,
not congratulatory, and don't add streaks.

### 2.2 The AI audit log screen — "what left my device"

The log is finished: `FernletKit/Sources/AIContext/AIAuditLog.swift:234` is an actor with a
500-entry ring (`:241`), an `outcome` field (`:81`) with a documented dispatch-then-update
discipline (`:291`), tolerant enum decode with parked tokens (`:149`), and an injectable sink
(`:206`) implemented by `App/Fernlet/FileAIAuditLogStore.swift:21` and wired at
`App/Fernlet/FernletStore.swift:825`. Four live writers
(`LaunchPreparationService.swift:480/489/543/553`, `FoodView.swift:3041` + `:3097`,
`FoodProductWebImporter.swift:779/788`, `FoundationDishDecomposition.swift:63/72`), and delete-all
clears it (`FernletStore.swift:4938`).

And `AIAuditLog.shared.entries` is read by **nobody**. `AIAuditLog.swift:92` already spells out the
display contract for the screen that does not exist — including how to render parked tokens.

Build a Settings screen listing every AI call this device made: what kind, where it went (on-device
model vs. a walled provider), when, and how it turned out. For a privacy-first app this is the
strongest available proof point, and it is a day or two of view code over data that is already
persisted.

Follow the parked-token display rule at `:92`. Respect the existing Settings navigation idiom and
the `SectionLabel` / `FernletScrollSection` components (pass `LocalizedStringKey`, not `String`).

---

## Part 3 — Repair CODEOWNERS after the repo restructure

`.github/CODEOWNERS` still uses pre-restructure roots, so **11 of 26 paths match nothing** —
including *all seven* wall and crypto test files:

- `/FernletTests/{NoTracking,S3,KeyCustody}BoundaryTests.swift`,
  `/FernletTests/ColumnCryptoDeviceBindingTests.swift`,
  `/FernletTests/SealedBackupFormatPinTests.swift`, `/FernletTests/SecureEnclaveWrapTests.swift`,
  `/FernletTests/FernletLockCryptoTests.swift` — all now under `Tests/FernletTests/`.
- `/Fernlet/PrivacyPolicyView.swift` — now `App/Fernlet/PrivacyPolicyView.swift`.
- All three `PrivacyInfo.xcprivacy` manifests — now under `App/`.

Two documents and one source comment currently assert a protection that is false:
`Docs/Release-Process.md` §1 ("no change to a wall file merges without the owner's explicit
approval") and `Tests/FernletTests/KeyCustodyBoundaryTests.swift:197` ("fails here… on a
CODEOWNERS-protected tripwire").

Also never added at all: `.github/workflows/power-of-10.yml`,
`Tests/FernletTests/PowerOfTenBoundaryTests.swift`,
`Tests/FernletTests/LocalizationBoundaryTests.swift`.

Fix the paths, add the three missing ones — **and add a check that every CODEOWNERS path resolves
to an existing file**, so the next restructure fails loudly instead of silently unprotecting the
walls. A test in the boundary-suite style is the natural home; make it fail with the offending
paths named. Be careful to model CODEOWNERS' own path semantics (a leading `/` anchors to the repo
root; a trailing `/` means a directory) rather than treating each entry as a literal file path.

---

## Part 4 — Delete-everything coverage

**Read this part before deciding the order of the rest.** "Delete your data" is the app's central
privacy promise and it is published at <https://fernlet.com/privacy/>. A four-track audit on
2026-08-20 enumerated every persisted surface in the tree and checked each against the wipe funnel
(`FernletStore.deleteAllData` :4648 + its nine legs, `resetAll` :5039, and the hook closures in
`ContentView.attachDeleteAllHooks` :957). It found **~20 surfaces the wipe does not clear**, five of
them serious. Every claim below was proven by reading the funnel and showing the token is absent —
but line numbers drift, so re-verify before you change anything.

The reason these accumulated is structural and is item 4.4: the existing wall can only check
correspondence between three human-written artifacts. It has no discovery, so a surface nobody
wrote down is invisible to it by construction.

### 4.1 Fix first — the five that matter

**a. A wiped phone still says the user enabled intimate logging.**
`fernlet.healthkit.requested-capabilities` (written `HealthKitService.swift:2000`, key at `:2003`)
is a plaintext string array of every `HealthCapability` ever prompted for — including
`intimateLogging` and `cycleTracking`. It is not ciphertext, it rides an unencrypted device backup,
and it is readable with `defaults read`. All four auditors found it independently. It also survives
`disableIntegration()` (`:1332`), so "delete everything **and** turn Health off" still leaves it.
There are only three references in the whole tree, so there is no clear function being missed —
one was never written. Add a clear, call it from `clearDeviceLocalLedgers` (`:4908`) *and* from
`disableIntegration()`, and consider moving the key to the keychain (ThisDeviceOnly) so it never
rides a backup at all.

**b. The wipe leaves plaintext journal text — and the next launch puts it back.**
The pre-database `LegacyKeys` corpus (`LocalFernletRepository.swift:489`) —
`fernlet-previous-journals`, `fernlet-memories`, `fernlet-settings`, `fernlet-recent-meals`,
`fernlet-goals`, `fernlet-workshop`, `fernlet-day-<yyyy-MM-dd>` — holds `[JournalEntry]` and
`[MemoryNote]` as unsealed JSON in the preferences plist. Every other journal surface in the app is
sealed; this one is not.

Worse than residue, it is a **resurrection source**. `purgeAllPersistedData()` removes only the file
(`:363`); `loadDatabase` treats a missing file as first launch and calls `migratedDatabase(todayKey:)`
(`:325`), which re-reads all seven key families and re-hydrates the store (`:432`) — and with sync on,
re-uploads them. I verified each link. The wipe funnel mentions `LegacyKeys` zero times.

Scope honestly: only installs that still carry these keys are affected — a fresh install never
writes them ("New code must never write these keys"). But this repo has fixed resurrection-after-wipe
once before, for four other writers, so treat it as a known class rather than a surprise.
Clear the keys in the wipe, and make `purgeAllPersistedData()` clear them too so no path can
resurrect.

**c. The most privacy-conscious user gets the least deletion.**
`DeleteEverythingFlow.swift:48` passes `canDeleteHealthSamples: preferences.healthKitMasterEnabled`,
and `DeleteAllDataConfirmation.swift:44` offers the "Delete, and from Health" button only when that
is true. So a user who turned the Health toggle **off** is never offered the option, the wipe runs
with `includingHealthKitSamples: false`, and the sexual-activity and menstrual-flow samples Fernlet
wrote stay in Apple Health with no in-app route to remove them. The privacy policy is honest about
this ("remove those in the Health app if you wish"), so it is the flow that is wrong, not the copy.
Offer the choice whenever Fernlet has ever written samples — which `requested-capabilities` from
(a) already knows.

**d. Sealed photos in CloudKit are deleted by enumerating a record type that may not exist.**
`CloudKitDataService.swift:652` tears down sealed photos by enumerating `SealedPhotoRecord`. That
type has never been promoted to the **Production** CloudKit schema (see
[`CloudKit-Schema-Deploy.md`](CloudKit-Schema-Deploy.md) and `RemainingWork-2026-08-20.md` §1). A
type absent from Production is never enumerated and therefore never deleted — silently. This is the
same owner action already on the release checklist; what is new is that skipping it does not merely
break restore, it makes the wipe incomplete. Verify in the console, then keep the preflight.

**e. A plaintext recipe file nobody clears.** `Application Support/Fernlet/SavedRecipes.json`
(`SavedRecipe.swift:510`) is a pretty-printed copy of saved recipes — names, ingredients, notes,
macros, source URLs — for any install that predates the Core Data migration.

### 4.2 Then these

- `fernlet.recentActivityTypes` (`ActivityPickerSection.swift:199`) — the last five workout types,
  and **visible in the UI**: open Log activity on a wiped phone and the previous owner's "Recent"
  chips are there. The only finding a user would notice without a debugger.
- `fernlet.workout.tombstones` (`WorkoutTombstoneStore.swift:30`) — up to 200 UUIDs of deleted
  workouts. Also the one possible **over-reach**: a surviving tombstone can make
  `WorkoutHealthKitSync` delete Apple Health samples after a wipe in which the user chose *keep*.
  Auditors disagreed on how reachable that second-order path is — one called it real but narrower
  than first described, another found no over-reach in the funnel at all. **Resolve it before
  fixing**; do not take my summary or theirs on faith.
- Moderation **peer bans** in the keychain (`ModerationBanStore.swift:107`) — 30-day records naming
  another person's identity fingerprint, surviving a wipe whose own dialog promises "a brand-new
  Fernlet identity".
- The **milestone ledger** (`MilestoneLedgerRepository.swift:33`) — a dated record that journal
  entries and Worry Box releases happened, in Core Data *and* the user's CloudKit database. The two
  sealed features whose content the wipe just destroyed.
- `MeshPhotoCache.json` (`PrivateMediaStore.swift:143`) — the friend photo-wall index is plaintext
  beside GCM-sealed bytes, carrying `senderName`, `senderFingerprint` and `addedAt`. Its subject is
  kept by design; the metadata being unsealed is the defect.
- `FernletPeerID.archive` (`MultipeerPeer.swift:89`) — the device name (in practice the user's own
  first name) plus the stable `MCPeerID` the mesh advertises. Same "brand-new identity" problem.
- The main Core Data store is **row-deleted, not rebuilt** — no WAL checkpoint, no vacuum, no file
  destroy. The *sealed* store does get a genuine rebuild (`sealedStoreRebuildHook`), so the two
  stores are inconsistent about what a wipe means.
- Legacy direct-CloudKit record types (incl. `JournalLogRecord`) are cleared only on a gated path
  (`FernletStore.swift:4804`, reached only when sync is off).

### 4.3 Low, but they belong in the table

Companion petting state (`PetInteractionGovernor.swift:72` — a correct `clearPersistentState(in:)`
exists whose **only** caller is inside `#if DEBUG`), `fernlet.daySummary.lastRunKey`,
`hasCompletedOnboarding` / `lockSetupDeferred`, `pastDayJournalScrubVersion` / `…Attempts`,
`MeshPhotoWallPreferences.json`, `tmp/*.fernlet-sealed-{backup,photo}` staging files whose cleanup
is best-effort, and the share-extension queue which is blanked (`save([])`) rather than removed.

One doc fix while you are here: `PrivacyWipeCoverage.md`'s cleared-by row "Sensitive-visibility
resolution | Memory" is wrong — it is three UserDefaults keys (`FernletStore.swift:630`), not
memory. It *is* cleared, so the promise holds; only the "Where it lives" column is false.

### 4.4 Close the discovery gap — `PersistedSurfaceWipeBoundaryTests`

`PrivacyWipeCoverageTests` checks correspondence between the funnel body, a hand-written manifest,
and the doc. It has exactly one discovery mechanism (keychain *services*), so any surface in neither
the funnel nor the manifest is invisible. That is why all of the above accumulated while the suite
stayed green.

Build a wall that **discovers surfaces from source** and requires each to be declared:

```swift
enum Disposition {
    case cleared(token: String)              // must appear in the wipe path AND in wipeManifest
    case kept(reason: String)                // >= 40 chars, and documented under "Deliberate exceptions"
    case unreachableByDesign(reason: String)
}
```

Design notes that matter, from the audit:

- **Anchor discovery on the binding, not a prefix.** A naive `fernlet.*` grep is useless — ~120 such
  literals are mesh wire types or `Notification.Name`s. Anchor on the accessor
  (`UserDefaults…set/removeObject/object/…forKey:`) and on `@AppStorage`. That is what excludes the
  ~45 Core Data `setValue(_:forKey:)` hits. It is the same lesson the keychain check already encodes.
- **Resolve symbolic keys** (the common form here: `Key.petCount`, `Self.defaultsKey`) by looking up
  the literal in the same file. Record interpolated keys as a family (`fernlet-day-*`).
- **Never drop an unresolvable key** — emit `unresolved:<symbol>@<file>:<line>` and require a table
  row anyway. A runtime-computed key becomes a *declared* surface instead of an invisible one. This
  is the single most important anti-fail-soft rule.
- **Strip `#if DEBUG` on both sides.** A DEBUG-only writer is not a shipping surface, and a
  DEBUG-only clear must not count as a clear — which is exactly the petting-state trap.
- **Four floors against a vacuous pass**: files scanned ≥ 300 and every root non-empty; discovered
  count ≥ 45; a `knownSurfaces` floor set that must always be rediscovered; and planted-fixture
  matcher tests (a new key IS found, `setValue(forKey: "payloadData")` is NOT, a DEBUG-only clear
  does NOT satisfy a `.cleared` row).
- **Reuse** `PrivacyWipeCoverageTests.functionBody` / `strippingComments` / `wipeManifest` rather
  than reimplementing, so the two walls cannot disagree about what the wipe path is — and extend the
  extracted path to include `ContentView.attachDeleteAllHooks`, which delivers five real clears the
  current scan cannot see.

Cheap fix worth landing in the same commit: assert that every private funnel helper is registered in
`wipeFunctionSignatures`, or `wipePathMakesNoBannedCall` is evadable by moving a banned call into an
unregistered leg.

Be honest in the doc about the ceiling: this proves a *call is present*, not that it *works*, and it
cannot see a key assembled across files. Keychain accounts, Core Data entities, HealthKit and
CloudKit namespaces stay outside its class coverage. `DeleteAllDataTests` remains the complement —
any `.cleared` row whose failure would be silent deserves a behavioural test too.

---

## Definition of done

- Clean build; `FernletTests` green in batches (clean build first if you touched
  `FernletDomainModel`).
- `Scripts/power-of-10-scan.py` → 0 violations; `Scripts/doc-coverage-scan.py` → 0 undocumented.
- `Scripts/spm-wall-check.sh` passes.
- `Scripts/sync-string-catalogs.sh` run and the catalog diff committed alongside any new user-facing
  string.
- New tests for 1.1 and 1.3 specifically — both are currently uncovered paths.
- Update [`RemainingWork-2026-08-20.md`](RemainingWork-2026-08-20.md) as items land: strike what
  shipped, and say so in the same commit. That document exists because its predecessor was allowed
  to drift for a month.

# Next round — working prompt (2026-08-20)

Everything below the line is a self-contained prompt. Paste it into a fresh session. It assumes
nothing from the conversation that produced it; every claim carries a `path:line` anchor that was
true on 2026-08-20 and should be re-grepped rather than trusted.

Scope: **four cheap defect fixes, two features whose infrastructure is already finished, and the
CODEOWNERS repair.** Backlog context is in
[`RemainingWork-2026-08-20.md`](RemainingWork-2026-08-20.md).

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

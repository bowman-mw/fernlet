# Fernlet

Fernlet is a privacy-first, "tamagotchi-of-yourself" iOS health & self-care app — it emphasizes
gentle, consistent care over optimization and streaks. A companion creature reflects the user's
daily wellbeing, computed from food, movement, sleep, cycle, journaling, and hygiene signals.

**Stack:** SwiftUI, iOS 26+, Swift. HealthKit for activity/cycle/intimate data, on-device AI
(Apple Foundation Models) with deterministic fallbacks, Core Data + CloudKit for storage, and a
UWB/MultipeerConnectivity proximity mesh for in-person social features (recipe sharing, friend photos).

**Architecture (the short version):**
- `FernletStore` is the central observable app state; mutations are persisted via `SnapshotSaveCoordinator`.
- Data goes through `FernletRepository` implementations — `CoreDataFernletRepository` (Core Data + iCloud)
  and `LocalFernletRepository` (local JSON), selected by `StoragePreferences`.
- Sensitive data (journal text, cycle narratives, intimate-activity notes) is **sealed/encrypted**
  out of the synced blob via `ColumnCrypto` + the narrative repositories and `FernletLockService`
  (keychain-backed lock). HealthKit holds the clinical samples; the encrypted store holds the notes.
- The `Proximity/` subtree is a self-contained signed/sealed peer-to-peer subsystem (identity
  envelopes, mesh transport, trust vault, ranging, recipe-share + friend-photo flows).

**Build / test:**
```
xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
```
Targets: `Fernlet` (app), `FernletTests` (unit), `FernletUITests`, `FernletShareExtension` (recipe share).

**SPM "S3 wall" enforcement:** the on-device source is being carved into the `FernletKit` local
package (see [Docs/SPM-Module-Carveup-Plan.md](Docs/SPM-Module-Carveup-Plan.md)). The walled AI
(`AIProviders`) and iCloud-sync (`CloudKitSync`) modules must never reach the sealed `Private*`
stores. This is a **hard build error**, enforced by building with
`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` (a forbidden cross-wall `import` then fails with
`error: '<module>' is missing a dependency on '<sealed module>'`). Run the check — and use it in CI —
with `Scripts/spm-wall-check.sh`. The flag must be on the build command (it does not reach the
synthesized SwiftPM targets from the pbxproj). `FernletTests/S3BoundaryTests` is the complementary
grep-wall.

**No-tracking wall:** a second, independent boundary — no advertising/attribution/analytics SDK
anywhere, and an **exact allowlist of outbound network destinations**. Unlike the S3 wall it has *no
compiler half* (a tracking SDK is an honest new dependency, so the DAG compiles clean), so
`FernletTests/NoTrackingBoundaryTests` is the whole enforcement. Adding a network endpoint or an SPM
dependency fails CI until it is deliberately allowlisted there **and** documented in
[Docs/No-Tracking-Wall.md](Docs/No-Tracking-Wall.md), in the same commit. All outbound fetching goes
through `WebScrapingKit`'s `EphemeralWebSession` — a private-tab `URLSession` with no cookie jar,
cache, or credential store — and `URLSession.shared` / `.default` are banned outright in shipping
code (§2a).

**Pre-merge ritual (enforce the wall):**
- Once per clone, install the git hooks: `Scripts/install-git-hooks.sh` (points `core.hooksPath` at
  `Scripts/git-hooks`). The committed `pre-push` hook then runs `Scripts/spm-wall-check.sh` whenever a
  push touches wall-relevant files; bypass a single push with `SKIP_S3_WALL_CHECK=1 git push`.
- CI runs `.github/workflows/s3-wall.yml` on push/PR to `main` — the enforcement self-test plus the
  grep-wall. Make it a **required status check** in branch protection. The workflow needs a macOS
  runner carrying the **iOS 26.5 SDK or newer** (`runs-on: macos-26`; macos-15 tops out at the
  26.3 SDK). The job selects the newest Xcode 26+ on the image and fails fast if either floor —
  Swift tools 6.2 or the 26.5 SDK — is unmet, rather than pinning a minor version (pinning 26.5
  silently fell back to Xcode 16.4 and broke every run). Keep `IPHONEOS_DEPLOYMENT_TARGET` at the
  claimed floor, 26.0: a deployment target above the runner's SDK is a hard build error.
- `Scripts/spm-wall-selftest.sh` is the automated negative test: it plants a forbidden
  `import PrivateHealthStore` in the walled `AIProviders` target, asserts the build fails with
  `is missing a dependency on`, reverts, and re-confirms the clean tree passes. Run it after any change
  to the wall (the `Package.swift` dependency DAG, the enforcement flag, or the walled modules).

## Framework documentation (start here)

Every framework has an Apple-style DocC landing page, and **every struct/class/protocol/enum/actor
in the codebase has a `///` doc comment** (load-bearing types document members, invariants, and
concurrency too). **Before changing a module, read its landing page first** — it explains the
module's purpose, key types, invariants, and its position relative to the S3 wall:

- `FernletKit/Sources/<Module>/Documentation.docc/<Module>.md` — one per SPM module (24 modules:
  the domain/persistence/crypto core, the sealed `Private*` stores, the walled `AIProviders` +
  `CloudKitSync`, `ProximityKit`, UI kits, and services).
- [Fernlet/Documentation.docc/Fernlet.md](Fernlet/Documentation.docc/Fernlet.md) — the app target
  (composition root): FernletStore, the tab surfaces, and how the six feature areas hang together.
- [FernletWidgets/Documentation.docc/FernletWidgets.md](FernletWidgets/Documentation.docc/FernletWidgets.md),
  [FernletShareExtension/Documentation.docc/FernletShareExtension.md](FernletShareExtension/Documentation.docc/FernletShareExtension.md)
  — the extension targets.

Browse rendered docs in Xcode via Product → Build Documentation. **Maintenance rule:** new or
changed types must keep their doc comments accurate — run `Scripts/doc-coverage-scan.py` (zero
undocumented type declarations is the enforced baseline) and update the module's landing page when
its public surface or invariants change.

## Index & reference files

The DocC pages above are the orientation layer; these indexes are the fine-grained lookup layer.
Consult them before adding code so existing behavior is reused, not duplicated:

| File | What it covers |
| --- | --- |
| [Docs/FileIndex.md](Docs/FileIndex.md) | Map of every main source file to its responsibility, grouped by feature area. |
| [Docs/StoreRepositoryFunctionIndex.md](Docs/StoreRepositoryFunctionIndex.md) | Store / repository / persistence / derived-signals function index + duplication hotspots. Read before any data-mutation, save/load, or storage-preference work. |
| [Docs/ProximityFunctionIndex.md](Docs/ProximityFunctionIndex.md) | Proximity & mesh subsystem function index (identity, transport, trust, recipe-share, friend-photo) + duplication hotspots. |
| [Docs/No-Tracking-Wall.md](Docs/No-Tracking-Wall.md) | The no-tracking wall: no user data reaches the developer or any third party for advertising/analytics. Permitted-destination allowlist + what is enforced mechanically. Read before adding any network call or SPM dependency. |
| [Docs/FernletSpecificationV3.md](Docs/FernletSpecificationV3.md) | Canonical product & architecture spec (privacy-first, module-enforced boundaries). The source of truth for intended behavior. |
| [Docs/ImplementationPlan.md](Docs/ImplementationPlan.md) | Phased implementation plan and planning assumptions (iOS 26, AI fallbacks, privacy-before-features). |
| [Docs/Completed Implemtations/CODE_REVIEW_2026-06-12.md](Docs/Completed%20Implemtations/CODE_REVIEW_2026-06-12.md) | Archived multi-agent code review: 195 findings, 186 fixed. The 9 survivors live on the tracker (RemainingWork §9), so read this for resolutions and author design decisions, not for open work. |
| `Docs/Completed Implemtations/` | Per-feature implementation plans that have already shipped (HealthKit, mesh, period/intimacy, startup/biometric, etc.). |

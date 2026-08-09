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

**Pre-merge ritual (enforce the wall):**
- Once per clone, install the git hooks: `Scripts/install-git-hooks.sh` (points `core.hooksPath` at
  `Scripts/git-hooks`). The committed `pre-push` hook then runs `Scripts/spm-wall-check.sh` whenever a
  push touches wall-relevant files; bypass a single push with `SKIP_S3_WALL_CHECK=1 git push`.
- CI runs `.github/workflows/s3-wall.yml` on push/PR to `main` — the enforcement self-test plus the
  grep-wall. Make it a **required status check** in branch protection. The workflow needs a macOS
  runner with Xcode 26.5 + an iOS 26 simulator (use a self-hosted runner if hosted ones lack them).
- `Scripts/spm-wall-selftest.sh` is the automated negative test: it plants a forbidden
  `import PrivateHealthStore` in the walled `AIProviders` target, asserts the build fails with
  `is missing a dependency on`, reverts, and re-confirms the clean tree passes. Run it after any change
  to the wall (the `Package.swift` dependency DAG, the enforcement flag, or the walled modules).

## Index & reference files

Consult these before adding code so existing behavior is reused, not duplicated:

| File | What it covers |
| --- | --- |
| [Docs/FileIndex.md](Docs/FileIndex.md) | Map of every main source file to its responsibility, grouped by feature area. Start here for orientation. |
| [Docs/StoreRepositoryFunctionIndex.md](Docs/StoreRepositoryFunctionIndex.md) | Store / repository / persistence / derived-signals function index + duplication hotspots. Read before any data-mutation, save/load, or storage-preference work. |
| [Docs/ProximityFunctionIndex.md](Docs/ProximityFunctionIndex.md) | Proximity & mesh subsystem function index (identity, transport, trust, recipe-share, friend-photo) + duplication hotspots. |
| [Docs/FernletSpecificationV3.md](Docs/FernletSpecificationV3.md) | Canonical product & architecture spec (privacy-first, module-enforced boundaries). The source of truth for intended behavior. |
| [Docs/ImplementationPlan.md](Docs/ImplementationPlan.md) | Phased implementation plan and planning assumptions (iOS 26, AI fallbacks, privacy-before-features). |
| [Docs/Completed Implemtations/CODE_REVIEW_2026-06-12.md](Docs/Completed%20Implemtations/CODE_REVIEW_2026-06-12.md) | Archived multi-agent code review: 195 findings, 185 fixed. The 10 survivors live on the tracker (RemainingWork §9), so read this for resolutions and author design decisions, not for open work. |
| `Docs/Completed Implemtations/` | Per-feature implementation plans that have already shipped (HealthKit, mesh, period/intimacy, startup/biometric, etc.). |
